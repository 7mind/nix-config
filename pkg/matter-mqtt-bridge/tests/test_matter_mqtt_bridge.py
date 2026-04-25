"""Regression tests for `matter_mqtt_bridge.py`.

These tests stub the external Matter and MQTT dependencies so they can run
with the stdlib alone and exercise the bridge's control flow directly.
"""

from __future__ import annotations

import asyncio
import enum
import importlib.util
import pathlib
import sys
import types
import unittest
from typing import Any


_ROOT = pathlib.Path(__file__).resolve().parents[1]
_MODULE_PATH = _ROOT / "matter_mqtt_bridge.py"


class _EventType(enum.Enum):
    NODE_ADDED = "node_added"
    NODE_UPDATED = "node_updated"
    NODE_REMOVED = "node_removed"
    ATTRIBUTE_UPDATED = "attribute_updated"


def _install_stubs() -> None:
    aiomqtt = types.ModuleType("aiomqtt")

    class _Client:
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            del args
            del kwargs

        async def __aenter__(self) -> "_Client":
            return self

        async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
            del exc_type
            del exc
            del tb

        async def publish(self, topic: str, payload: bytes, retain: bool = False) -> None:
            del topic
            del payload
            del retain

    aiomqtt.Client = _Client
    sys.modules["aiomqtt"] = aiomqtt

    aiohttp = types.ModuleType("aiohttp")

    class _ClientSession:
        async def close(self) -> None:
            return None

    aiohttp.ClientSession = _ClientSession
    sys.modules["aiohttp"] = aiohttp

    matter_server = types.ModuleType("matter_server")
    matter_server_client = types.ModuleType("matter_server.client")
    matter_server_client_client = types.ModuleType("matter_server.client.client")
    matter_server_common = types.ModuleType("matter_server.common")
    matter_server_common_models = types.ModuleType("matter_server.common.models")

    class _MatterClient:
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            del args
            del kwargs

        async def connect(self) -> None:
            return None

        async def disconnect(self) -> None:
            return None

    matter_server_client_client.MatterClient = _MatterClient
    matter_server_common_models.EventType = _EventType

    sys.modules["matter_server"] = matter_server
    sys.modules["matter_server.client"] = matter_server_client
    sys.modules["matter_server.client.client"] = matter_server_client_client
    sys.modules["matter_server.common"] = matter_server_common
    sys.modules["matter_server.common.models"] = matter_server_common_models


def _load_bridge_module():
    _install_stubs()
    spec = importlib.util.spec_from_file_location("matter_mqtt_bridge_under_test", _MODULE_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MatterMqttBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = _load_bridge_module()
        cls.event_type = _EventType

    def _bridge(self):
        return self.module.MatterMqttBridge(
            matter_url="ws://matter",
            mqtt_host="mqtt",
            mqtt_port=1883,
            mqtt_user="user",
            mqtt_password="pass",
            base_topic="matter",
        )

    def test_node_removed_enqueues_offline_without_crashing(self) -> None:
        async def run() -> None:
            bridge = self._bridge()
            await bridge._event_handler(self.event_type.NODE_REMOVED, 7)
            self.assertEqual(
                bridge.mqtt_queue.get_nowait(),
                ("matter/7/available", "offline"),
            )

        asyncio.run(run())

    def test_mqtt_loop_keeps_connection_open_while_idle(self) -> None:
        async def run() -> None:
            bridge = self._bridge()
            enter_count = 0

            class FakeClient:
                def __init__(self, *args: Any, **kwargs: Any) -> None:
                    del args
                    del kwargs

                async def __aenter__(self) -> "FakeClient":
                    nonlocal enter_count
                    enter_count += 1
                    if enter_count >= 2:
                        bridge.shutdown_event.set()
                    return self

                async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
                    del exc_type
                    del exc
                    del tb

                async def publish(self, topic: str, payload: bytes, retain: bool = False) -> None:
                    del topic
                    del payload
                    del retain

            original_client = self.module.aiomqtt.Client
            original_backoff_iter = self.module._backoff_iter
            self.module.aiomqtt.Client = FakeClient
            self.module._backoff_iter = lambda: iter(int(0) for _ in range(100))
            stop_task = asyncio.create_task(self._set_shutdown_later(bridge, 1.2))

            try:
                await bridge._mqtt_loop()
            finally:
                self.module.aiomqtt.Client = original_client
                self.module._backoff_iter = original_backoff_iter
                await stop_task

            self.assertEqual(enter_count, 1)

        asyncio.run(run())

    async def _set_shutdown_later(self, bridge: Any, delay: float) -> None:
        await asyncio.sleep(delay)
        bridge.shutdown_event.set()

    def test_mqtt_loop_publishes_retained_state_updates(self) -> None:
        async def run() -> None:
            bridge = self._bridge()
            published: list[tuple[str, bytes, bool]] = []

            class FakeClient:
                def __init__(self, *args: Any, **kwargs: Any) -> None:
                    del args
                    del kwargs

                async def __aenter__(self) -> "FakeClient":
                    return self

                async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
                    del exc_type
                    del exc
                    del tb

                async def publish(self, topic: str, payload: bytes, retain: bool = False) -> None:
                    published.append((topic, payload, retain))
                    bridge.shutdown_event.set()

            original_client = self.module.aiomqtt.Client
            self.module.aiomqtt.Client = FakeClient
            bridge._enqueue("matter/1/all", {"temperature": 21})

            try:
                await bridge._mqtt_loop()
            finally:
                self.module.aiomqtt.Client = original_client

            self.assertEqual(
                published,
                [("matter/1/all", b'{"temperature": 21}', True)],
            )

        asyncio.run(run())

    def test_run_flushes_offline_messages_before_stopping_mqtt(self) -> None:
        async def run() -> None:
            bridge = self._bridge()
            bridge._known_nodes.add(9)
            published: list[tuple[str, Any]] = []

            async def fake_matter_loop() -> None:
                await asyncio.Future()

            async def fake_watchdog_loop() -> None:
                await asyncio.Future()

            async def fake_mqtt_loop() -> None:
                while True:
                    topic, payload = await bridge.mqtt_queue.get()
                    published.append((topic, payload))

            async def fake_publish_offline_all() -> None:
                for node_id in bridge._known_nodes:
                    bridge._enqueue(f"matter/{node_id}/available", "offline")
                await asyncio.sleep(0)

            bridge._matter_loop = fake_matter_loop
            bridge._watchdog_loop = fake_watchdog_loop
            bridge._mqtt_loop = fake_mqtt_loop
            bridge._publish_offline_all = fake_publish_offline_all

            async def trigger_shutdown() -> None:
                await asyncio.sleep(0.05)
                bridge.shutdown_event.set()

            trigger_task = asyncio.create_task(trigger_shutdown())
            await bridge.run()
            await trigger_task

            self.assertIn(("matter/9/available", "offline"), published)
            self.assertTrue(bridge.mqtt_queue.empty())

        asyncio.run(run())


if __name__ == "__main__":
    unittest.main()
