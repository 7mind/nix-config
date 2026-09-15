use std::collections::BTreeMap;
use std::sync::Mutex;

use super::*;

#[derive(Default)]
struct MemoryHistory(Mutex<BTreeMap<(String, i64), ValveHistoryPoint>>);

impl HistoryRepository for MemoryHistory {
    async fn record(&self, samples: &[ValveSample], now_ms: i64) -> anyhow::Result<()> {
        let mut rows = self.0.lock().unwrap();
        for sample in samples {
            rows.insert(
                (sample.device.clone(), sample.point.timestamp_epoch_ms),
                sample.point.clone(),
            );
        }
        rows.retain(|(_, timestamp), _| *timestamp >= now_ms - HISTORY_WINDOW_MS);
        Ok(())
    }
    async fn fetch(&self, device: &str, now_ms: i64) -> anyhow::Result<Vec<ValveHistoryPoint>> {
        Ok(self
            .0
            .lock()
            .unwrap()
            .iter()
            .filter(|((name, timestamp), _)| {
                name == device && *timestamp >= now_ms - HISTORY_WINDOW_MS && *timestamp <= now_ms
            })
            .map(|(_, point)| point.clone())
            .collect())
    }
}

fn sample(device: &str, timestamp: i64, temperature: Option<f64>) -> ValveSample {
    ValveSample {
        device: device.into(),
        point: ValveHistoryPoint {
            timestamp_epoch_ms: timestamp,
            observed_at_epoch_ms: temperature.map(|_| timestamp - 1000),
            local_temperature: temperature,
            reported_setpoint: Some(20.0),
            target: Some(mqtt_controller_wire::TrvTargetValue::Setpoint { temperature: 21.0 }),
            heating_demand: Some(40),
            battery: Some(80),
            freshness: "fresh".into(),
        },
    }
}

async fn history_contract(repository: &impl HistoryRepository) {
    let now = HISTORY_WINDOW_MS * 2;
    repository
        .record(
            &[
                sample("bathroom", now - HISTORY_WINDOW_MS - 1, Some(18.0)),
                sample("bathroom", now - HISTORY_WINDOW_MS, Some(19.0)),
                sample("bedroom", now, Some(17.0)),
                sample("bathroom", now, None),
                sample("bathroom", now + 1000, Some(30.0)),
            ],
            now,
        )
        .await
        .unwrap();
    let rows = repository.fetch("bathroom", now).await.unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].local_temperature, Some(19.0));
    assert_eq!(rows[1].local_temperature, None);
    assert_eq!(
        rows[1].target,
        Some(mqtt_controller_wire::TrvTargetValue::Setpoint { temperature: 21.0 })
    );
    assert_eq!(repository.fetch("missing", now).await.unwrap(), []);
    repository
        .record(&[sample("bathroom", now, Some(22.0))], now)
        .await
        .unwrap();
    let rows = repository.fetch("bathroom", now).await.unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[1].local_temperature, Some(22.0));
    repository
        .record(&[], now + HISTORY_WINDOW_MS + 1001)
        .await
        .unwrap();
    assert!(
        repository
            .fetch("bathroom", now + HISTORY_WINDOW_MS + 1001)
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn memory_history_contract() {
    history_contract(&MemoryHistory::default()).await;
}

#[tokio::test]
async fn sqlite_history_contract() {
    let directory = tempfile::tempdir().unwrap();
    let repository = SqliteHistory::open(&directory.path().join("history.db"))
        .await
        .unwrap();
    history_contract(&repository).await;
}

#[tokio::test]
async fn history_survives_reopen() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("history.db");
    let point = sample("valve", HISTORY_WINDOW_MS, Some(21.5));
    {
        let repository = SqliteHistory::open(&path).await.unwrap();
        repository
            .record(&[point.clone()], HISTORY_WINDOW_MS)
            .await
            .unwrap();
    }
    let repository = SqliteHistory::open(&path).await.unwrap();
    assert_eq!(
        repository.fetch("valve", HISTORY_WINDOW_MS).await.unwrap(),
        [point.point]
    );
}

fn snapshot(timestamp: u64) -> FullStateSnapshot {
    serde_json::from_value(serde_json::json!({
        "timestamp_epoch_ms": timestamp, "rooms": [], "plugs": [],
        "heating_zones": [{
            "name": "upstairs", "relay_device": "relay", "relay_on": false,
            "relay_state_known": false, "relay_temperature": null,
            "trvs": [{
                "device": "ensuite", "local_temperature": null, "setpoint": 18.0,
                "pi_heating_demand": 0, "battery": 0, "running_state": "idle", "inhibited": false,
                "target_value": { "kind": "setpoint", "temperature": 21.0 },
                "actual": { "freshness": "stale", "since_ago_ms": 3600000 }
            }]
        }]
    }))
    .unwrap()
}

#[test]
fn sampling_keeps_target_actual_zero_and_observation_time_distinct() {
    let now = HISTORY_WINDOW_MS as u64 + 23_000;
    let points = samples(snapshot(now));
    assert_eq!(points.len(), 1);
    let point = &points[0].point;
    assert_eq!(point.timestamp_epoch_ms, HISTORY_WINDOW_MS);
    assert_eq!(point.observed_at_epoch_ms, Some(now as i64 - 3_600_000));
    assert_eq!(point.local_temperature, None);
    assert_eq!(point.reported_setpoint, Some(18.0));
    assert_eq!(
        point.target,
        Some(mqtt_controller_wire::TrvTargetValue::Setpoint { temperature: 21.0 })
    );
    assert_eq!(point.battery, Some(0));
    assert_eq!(point.heating_demand, Some(0));
    assert_eq!(point.freshness, "stale");
}

#[tokio::test]
async fn sampler_records_a_controller_snapshot_and_clears_startup_status() {
    let directory = tempfile::tempdir().unwrap();
    let history = HeatingHistory::open(&directory.path().join("history.db"))
        .await
        .unwrap();
    let (commands, mut requests) = mpsc::channel(1);
    let sampler = history.spawn_sampler(commands);
    let request = tokio::time::timeout(Duration::from_secs(1), requests.recv())
        .await
        .unwrap()
        .unwrap();
    let WsCommand::RequestSnapshot { reply } = request else {
        panic!("expected a snapshot request")
    };
    reply.send(snapshot(HISTORY_WINDOW_MS as u64)).unwrap();
    let points = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let (points, error) = history.fetch("ensuite", HISTORY_WINDOW_MS).await.unwrap();
            if error.is_none() {
                break points;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert_eq!(
        points,
        samples(snapshot(HISTORY_WINDOW_MS as u64))
            .into_iter()
            .map(|sample| sample.point)
            .collect::<Vec<_>>()
    );
    sampler.abort();
}

#[tokio::test]
async fn sampler_reports_timeout_when_the_controller_queue_is_full() {
    let directory = tempfile::tempdir().unwrap();
    let history = HeatingHistory::open(&directory.path().join("history.db"))
        .await
        .unwrap();
    let (commands, _requests) = mpsc::channel(1);
    let (reply, _response) = oneshot::channel();
    commands
        .send(WsCommand::RequestSnapshot { reply })
        .await
        .unwrap();
    let sampler = history.spawn_sampler(commands);
    tokio::time::sleep(Duration::from_millis(5200)).await;
    let (_, error) = history.fetch("ensuite", HISTORY_WINDOW_MS).await.unwrap();
    sampler.abort();
    assert!(
        error.unwrap().contains("deadline"),
        "a full queue must surface a sampling timeout"
    );
}
