mod common;

use futures_util::{SinkExt, StreamExt};
use mqtt_controller::{
    mqtt::MqttConfig,
    time::FakeClock,
    web::{
        history::HeatingHistory,
        server::{WebHandle, WsCommand, bind_and_start_web_server},
    },
};
use mqtt_controller_wire::{ControlCommand, FullStateSnapshot, ServerMessage};
use std::{sync::Arc, time::Duration};
use tokio::sync::{broadcast, mpsc};
use tokio_tungstenite::{connect_async, tungstenite::Message};

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn next_message(socket: &mut Socket) -> ServerMessage {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match socket
                .next()
                .await
                .expect("socket ended")
                .expect("socket error")
            {
                Message::Text(text) => {
                    return serde_json::from_str(&text).expect("server protocol");
                }
                Message::Ping(payload) => socket.send(Message::Pong(payload)).await.unwrap(),
                other => panic!("unexpected frame: {other:?}"),
            }
        }
    })
    .await
    .expect("server response timed out")
}

async fn command(socket: &mut Socket, request: &str, command: ControlCommand) -> Option<String> {
    socket
        .send(Message::text(
            serde_json::to_string(&mqtt_controller_wire::ClientMessage::Command {
                request_id: request.into(),
                command,
            })
            .unwrap(),
        ))
        .await
        .unwrap();
    loop {
        if let ServerMessage::CommandResult { request_id, error } = next_message(socket).await {
            assert_eq!(request_id, request);
            return error;
        }
    }
}

#[tokio::test]
async fn websocket_controls_reach_mqtt_and_reject_unknown_entities() {
    let broker = common::TestBroker::start().await;
    let mqtt = common::TestClient::connect(&broker, "web-control-observer").await;
    let topic = "zigbee2mqtt/hue-lz-kitchen-cooker/set";
    mqtt.subscribe(topic).await;
    let mut config = common::fixtures::kitchen_config();
    config.devices.insert("test-plug".into(), serde_json::from_value(serde_json::json!({
        "kind": "plug", "ieee_address": "0x0000000000000099", "variant": "sonoff-power", "capabilities": ["power"]
    })).unwrap());
    mqtt.subscribe("zigbee2mqtt/test-plug/set").await;
    let (commands, command_rx) = mpsc::channel(64);
    let (updates, _) = broadcast::channel(256);
    let directory = tempfile::tempdir().unwrap();
    let history = HeatingHistory::open(&directory.path().join("history.db"))
        .await
        .unwrap();
    let (address, server) = bind_and_start_web_server(
        "127.0.0.1:0".parse().unwrap(),
        commands,
        updates.clone(),
        directory.path().into(),
        None,
        history,
    )
    .await
    .unwrap();
    let daemon = tokio::spawn(mqtt_controller::daemon::run(
        config,
        MqttConfig::new("127.0.0.1", broker.port, "test", "", "web-controller"),
        None,
        None,
        Arc::new(FakeClock::new(12)),
        Some(WebHandle {
            ws_cmd_rx: command_rx,
            broadcast_tx: updates,
            audit_writer: None,
        }),
    ));
    let (mut socket, _) = connect_async(format!("ws://{address}/ws")).await.unwrap();
    assert!(matches!(
        next_message(&mut socket).await,
        ServerMessage::StateSnapshot(_)
    ));
    assert_eq!(
        command(
            &mut socket,
            "off-1",
            ControlCommand::SetRoomOff {
                room: "kitchen-cooker".into()
            }
        )
        .await,
        None
    );
    let messages = mqtt.inbox.wait_for(topic, 1, Duration::from_secs(3)).await;
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&messages[0]).unwrap()["state"],
        "OFF"
    );
    assert_eq!(
        command(
            &mut socket,
            "scene-2",
            ControlCommand::RecallScene {
                room: "kitchen-cooker".into(),
                scene_id: 2
            }
        )
        .await,
        None
    );
    let messages = mqtt.inbox.wait_for(topic, 2, Duration::from_secs(3)).await;
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&messages[1]).unwrap()["scene_recall"],
        2
    );
    for (request, on) in [
        ("plug-off", false),
        ("plug-on", true),
        ("plug-on-again", true),
    ] {
        assert_eq!(
            command(
                &mut socket,
                request,
                ControlCommand::SetPlugPower {
                    device: "test-plug".into(),
                    on
                }
            )
            .await,
            None
        );
    }
    let messages = mqtt
        .inbox
        .wait_for("zigbee2mqtt/test-plug/set", 3, Duration::from_secs(3))
        .await;
    let states: Vec<_> = messages
        .iter()
        .map(|message| {
            serde_json::from_slice::<serde_json::Value>(message).unwrap()["state"].clone()
        })
        .collect();
    assert_eq!(states, vec!["OFF", "ON", "ON"]);
    assert!(
        command(
            &mut socket,
            "bad-room",
            ControlCommand::SetRoomOff {
                room: "missing".into()
            }
        )
        .await
        .unwrap()
        .contains("Unknown light group")
    );
    assert!(
        command(
            &mut socket,
            "bad-scene",
            ControlCommand::RecallScene {
                room: "kitchen-cooker".into(),
                scene_id: 99
            }
        )
        .await
        .unwrap()
        .contains("Unknown scene")
    );
    socket.close(None).await.unwrap();
    daemon.abort();
    server.abort();
}

#[tokio::test]
async fn lost_broadcasts_close_the_connection_to_require_a_fresh_snapshot() {
    let (commands, mut command_rx) = mpsc::channel(1);
    let (updates, _) = broadcast::channel(1);
    let directory = tempfile::tempdir().unwrap();
    let history = HeatingHistory::open(&directory.path().join("history.db"))
        .await
        .unwrap();
    let (address, server) = bind_and_start_web_server(
        "127.0.0.1:0".parse().unwrap(),
        commands,
        updates.clone(),
        directory.path().into(),
        None,
        history,
    )
    .await
    .unwrap();
    let (mut socket, _) = connect_async(format!("ws://{address}/ws")).await.unwrap();
    let WsCommand::RequestSnapshot { reply } = command_rx.recv().await.unwrap() else {
        panic!("expected snapshot request")
    };
    let snapshot: FullStateSnapshot = serde_json::from_value(
        serde_json::json!({ "timestamp_epoch_ms": 0, "rooms": [], "plugs": [] }),
    )
    .unwrap();
    for _ in 0..8 {
        updates
            .send(ServerMessage::StateSnapshot(snapshot.clone()))
            .unwrap();
    }
    reply.send(snapshot).unwrap();
    assert!(matches!(
        next_message(&mut socket).await,
        ServerMessage::StateSnapshot(_)
    ));
    let frame = tokio::time::timeout(Duration::from_secs(2), socket.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(
        matches!(frame, Message::Close(Some(ref close)) if u16::from(close.code) == 1013),
        "expected resync close, got {frame:?}"
    );
    server.abort();
}

#[tokio::test]
async fn heartbeats_are_not_blocked_by_a_pending_controller_command() {
    let (commands, mut command_rx) = mpsc::channel(2);
    let (updates, _) = broadcast::channel(16);
    let directory = tempfile::tempdir().unwrap();
    let history = HeatingHistory::open(&directory.path().join("history.db"))
        .await
        .unwrap();
    let (address, server) = bind_and_start_web_server(
        "127.0.0.1:0".parse().unwrap(),
        commands,
        updates,
        directory.path().into(),
        None,
        history,
    )
    .await
    .unwrap();
    let (mut socket, _) = connect_async(format!("ws://{address}/ws")).await.unwrap();
    let WsCommand::RequestSnapshot { reply } = command_rx.recv().await.unwrap() else {
        panic!("expected snapshot request")
    };
    reply
        .send(
            serde_json::from_value(
                serde_json::json!({ "timestamp_epoch_ms": 0, "rooms": [], "plugs": [] }),
            )
            .unwrap(),
        )
        .unwrap();
    next_message(&mut socket).await;
    socket.send(Message::text(r#"{"type":"Command","request_id":"pending","command":{"kind":"SetRoomOff","room":"kitchen"}}"#)).await.unwrap();
    let pending_command = command_rx.recv().await.unwrap();
    socket
        .send(Message::text(
            r#"{"type":"Ping","nonce":"probe","client_ts_ms":123}"#,
        ))
        .await
        .unwrap();
    let response = tokio::time::timeout(Duration::from_millis(500), next_message(&mut socket))
        .await
        .expect("heartbeat was blocked waiting for a controller command");
    assert!(
        matches!(response, ServerMessage::Pong { nonce, client_ts_ms: 123, .. } if nonce == "probe")
    );
    drop(pending_command);
    socket.close(None).await.unwrap();
    server.abort();
}
