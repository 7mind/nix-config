"""
Matter → MQTT bridge.

Connects to python-matter-server over its WebSocket API, subscribes to
node/attribute events, and republishes every state change to the local
MQTT broker.

Topic layout:
  matter/<node_id>/available          "online" | "offline"
  matter/<node_id>/attributes/<path>  JSON value
  matter/<node_id>/all                Full attribute snapshot

Resilience features:
  * Independent reconnect loops for Matter Server and MQTT with exponential
    backoff (1s → 2s → 5s → 10s → 15s cap) plus jitter.
  * Watchdog pokes the Matter Server every 30s; forces reconnect on timeout.
  * Event handlers are firewalled from the listener loop so one bad
    attribute or callback does not crash the bridge.
  * MQTT publishes go through an asyncio Queue so a dead broker does not
    block Matter callbacks.
  * On graceful shutdown, ``offline`` is published for every known node.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import logging
import os
import random
import signal
import sys
import time
from typing import Any

import aiomqtt
import aiohttp
from matter_server.client.client import MatterClient
from matter_server.common.models import EventType

LOG = logging.getLogger("matter_mqtt_bridge")

ATTR_TOPIC_FMT = "{base}/{node_id}/attributes/{path}"
ALL_TOPIC_FMT = "{base}/{node_id}/all"
AVAIL_TOPIC_FMT = "{base}/{node_id}/available"

_BACKOFF_DELAYS = (1, 2, 5, 10, 15)
_WATCHDOG_INTERVAL = 30.0
_WATCHDOG_TIMEOUT = 10.0
_MQTT_QUEUE_MAX = 1000


def _backoff_iter():
    """Yield reconnect delays with jitter."""
    while True:
        for d in _BACKOFF_DELAYS:
            yield d + random.uniform(0, 0.5)
        while True:
            yield _BACKOFF_DELAYS[-1] + random.uniform(0, 0.5)


def safe_attr_path(path: str) -> str:
    """Replace '/' in Matter attribute paths so they become legal MQTT topic segments."""
    return path.replace("/", "_")


def flatten_node_attrs(node) -> dict[str, Any]:
    """Return a flat dict of {attr_path: value} for the given node."""
    raw_attrs = getattr(node, "node_data", node).attributes
    if raw_attrs is None:
        return {}
    return {k: _serialisable(v) for k, v in raw_attrs.items()}


def _serialisable(obj: Any) -> Any:
    """Best-effort JSON-safe deep conversion."""
    if isinstance(obj, (str, int, float, bool, type(None))):
        return obj
    if isinstance(obj, bytes):
        return obj.hex()
    if isinstance(obj, (list, tuple)):
        return [_serialisable(x) for x in obj]
    if isinstance(obj, dict):
        return {k: _serialisable(v) for k, v in obj.items()}
    if hasattr(obj, "__dict__"):
        return _serialisable(obj.__dict__)
    return str(obj)


class MatterMqttBridge:
    """Reconciles Matter Server state into MQTT with independent reconnect loops."""

    def __init__(
        self,
        *,
        matter_url: str,
        mqtt_host: str,
        mqtt_port: int,
        mqtt_user: str,
        mqtt_password: str,
        base_topic: str = "matter",
    ) -> None:
        self.matter_url = matter_url
        self.mqtt_host = mqtt_host
        self.mqtt_port = mqtt_port
        self.mqtt_user = mqtt_user
        self.mqtt_password = mqtt_password
        self.base_topic = base_topic

        self.shutdown_event = asyncio.Event()
        self.mqtt_queue: asyncio.Queue[tuple[str, Any]] = asyncio.Queue(maxsize=_MQTT_QUEUE_MAX)
        self._matter_client: MatterClient | None = None
        self._matter_session: aiohttp.ClientSession | None = None
        self._matter_listen_task: asyncio.Task | None = None
        self._last_matter_event_time = 0.0
        self._known_nodes: set[int] = set()
        self._last_attrs: dict[int, dict[str, Any]] = {}

    # ------------------------------------------------------------------ #
    #  public entrypoint
    # ------------------------------------------------------------------ #

    async def run(self) -> None:
        matter_task = asyncio.create_task(self._matter_loop(), name="matter-loop")
        mqtt_task = asyncio.create_task(self._mqtt_loop(), name="mqtt-loop")
        watchdog_task = asyncio.create_task(self._watchdog_loop(), name="watchdog")

        try:
            await self.shutdown_event.wait()
        finally:
            LOG.info("Shutting down bridge...")
            matter_task.cancel()
            watchdog_task.cancel()
            try:
                await asyncio.gather(matter_task, watchdog_task, return_exceptions=True)
            except asyncio.CancelledError:
                pass
            await self._publish_offline_all()
            mqtt_task.cancel()
            try:
                await asyncio.gather(mqtt_task, return_exceptions=True)
            except asyncio.CancelledError:
                pass
            LOG.info("Bridge stopped.")

    # ------------------------------------------------------------------ #
    #  Matter loop
    # ------------------------------------------------------------------ #

    async def _matter_loop(self) -> None:
        for delay in _backoff_iter():
            if self.shutdown_event.is_set():
                break
            try:
                await self._matter_connect_and_listen()
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                LOG.error("Matter error: %s", exc)
            finally:
                await self._matter_disconnect()

            if self.shutdown_event.is_set():
                break
            LOG.info("Reconnecting to Matter Server in %.1fs...", delay)
            if await self._wait_or_shutdown(delay):
                break

    async def _matter_connect_and_listen(self) -> None:
        session = aiohttp.ClientSession()
        self._matter_session = session
        matter = MatterClient(self.matter_url, session)
        await matter.connect()
        self._matter_client = matter

        schema = matter.server_info.schema_version if matter.server_info else "?"
        LOG.info("Matter connected (schema v%s)", schema)

        init_ready = asyncio.Event()
        unsubscribe = matter.subscribe_events(self._safe_event_handler)

        listen_task = asyncio.create_task(matter.start_listening(init_ready), name="matter-listen")
        self._matter_listen_task = listen_task
        try:
            await init_ready.wait()
            self._last_matter_event_time = time.monotonic()
            for node in matter.get_nodes():
                self._known_nodes.add(node.node_id)
                await self._publish_node_delta(node)
            LOG.info(
                "Matter initial sync complete (%s node%s)",
                len(matter.get_nodes()),
                "s" if len(matter.get_nodes()) != 1 else "",
            )
            await listen_task
        finally:
            self._matter_listen_task = None
            unsubscribe()
            try:
                await matter.disconnect()
            except Exception:
                pass
            self._matter_client = None

    async def _matter_disconnect(self) -> None:
        if self._matter_listen_task and not self._matter_listen_task.done():
            self._matter_listen_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._matter_listen_task
        if self._matter_client is not None:
            with contextlib.suppress(Exception):
                await self._matter_client.disconnect()
            self._matter_client = None
        if self._matter_session is not None:
            with contextlib.suppress(Exception):
                await self._matter_session.close()
            self._matter_session = None

    # ------------------------------------------------------------------ #
    #  MQTT loop
    # ------------------------------------------------------------------ #

    async def _mqtt_loop(self) -> None:
        for delay in _backoff_iter():
            if self.shutdown_event.is_set():
                break
            try:
                async with aiomqtt.Client(
                    hostname=self.mqtt_host,
                    port=self.mqtt_port,
                    username=self.mqtt_user,
                    password=self.mqtt_password,
                    identifier="matter-mqtt-bridge",
                ) as mqtt_client:
                    LOG.info("MQTT connected to %s:%s", self.mqtt_host, self.mqtt_port)
                    # Drain any queued messages from a previous outage.
                    await self._mqtt_drain(mqtt_client)
                    # Forward new messages.
                    while True:
                        if self.shutdown_event.is_set() and self.mqtt_queue.empty():
                            break
                        try:
                            topic, payload = await asyncio.wait_for(
                                self.mqtt_queue.get(), timeout=1.0
                            )
                        except asyncio.TimeoutError:
                            continue
                        try:
                            await mqtt_client.publish(
                                topic, json.dumps(payload, default=str).encode()
                            )
                        except Exception as exc:
                            LOG.warning("MQTT publish failed: %s (re-queueing)", exc)
                            self._mqtt_requeue(topic, payload)
                            raise
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                LOG.error("MQTT error: %s", exc)

            if self.shutdown_event.is_set():
                break
            LOG.info("Reconnecting to MQTT in %.1fs...", delay)
            if await self._wait_or_shutdown(delay):
                break

    async def _mqtt_drain(self, client: aiomqtt.Client) -> None:
        while not self.mqtt_queue.empty():
            topic, payload = self.mqtt_queue.get_nowait()
            try:
                await client.publish(topic, json.dumps(payload, default=str).encode())
            except Exception as exc:
                LOG.warning("MQTT drain failed: %s (re-queueing)", exc)
                self._mqtt_requeue(topic, payload)
                raise

    def _mqtt_requeue(self, topic: str, payload: Any) -> None:
        try:
            self.mqtt_queue.put_nowait((topic, payload))
        except asyncio.QueueFull:
            try:
                dropped = self.mqtt_queue.get_nowait()
            except asyncio.QueueEmpty:
                dropped = None
            try:
                self.mqtt_queue.put_nowait((topic, payload))
            except asyncio.QueueFull:
                pass
            if dropped:
                LOG.warning("Dropped oldest MQTT message: %s", dropped[0])

    # ------------------------------------------------------------------ #
    #  Watchdog
    # ------------------------------------------------------------------ #

    async def _watchdog_loop(self) -> None:
        while True:
            try:
                await asyncio.wait_for(self.shutdown_event.wait(), timeout=_WATCHDOG_INTERVAL)
                break
            except asyncio.TimeoutError:
                pass
            if self._matter_client is None:
                continue
            # Force a lightweight server interaction to confirm the pipe is alive.
            try:
                await asyncio.wait_for(self._matter_client.get_diagnostics(), timeout=_WATCHDOG_TIMEOUT)
                LOG.debug("Watchdog OK")
            except asyncio.TimeoutError:
                LOG.error("Matter Server watchdog timeout — forcing reconnect")
                if self._matter_listen_task and not self._matter_listen_task.done():
                    self._matter_listen_task.cancel()
            except Exception as exc:
                LOG.warning("Watchdog ping failed: %s", exc)

    # ------------------------------------------------------------------ #
    #  Event handling
    # ------------------------------------------------------------------ #

    def _safe_event_handler(self, event: EventType, data: Any) -> None:
        try:
            task = asyncio.create_task(self._event_handler(event, data))
            task.add_done_callback(self._log_event_handler_result)
        except Exception:
            LOG.exception("Event handler failed for %s", event)

    def _log_event_handler_result(self, task: asyncio.Task) -> None:
        try:
            task.result()
        except asyncio.CancelledError:
            return
        except Exception:
            LOG.exception("Event handler task failed")

    async def _event_handler(self, event: EventType, data: Any) -> None:
        self._last_matter_event_time = time.monotonic()

        if event in (EventType.NODE_ADDED, EventType.NODE_UPDATED):
            node = data
            LOG.debug("Node %s %s", node.node_id, event.value)
            self._known_nodes.add(node.node_id)
            await self._publish_node_delta(node)
            return

        if event == EventType.NODE_REMOVED:
            node_id = data
            LOG.debug("Node removed: %s", node_id)
            self._known_nodes.discard(node_id)
            self._last_attrs.pop(node_id, None)
            self._enqueue(AVAIL_TOPIC_FMT.format(base=self.base_topic, node_id=node_id), "offline")
            return

        if event == EventType.ATTRIBUTE_UPDATED:
            # data == new value; node_id and attribute_path are NOT passed
            # by the generic callback. Scan all nodes to find the delta.
            LOG.debug("Attribute updated (scanning nodes for delta)")
            if self._matter_client is not None:
                for node in self._matter_client.get_nodes():
                    self._known_nodes.add(node.node_id)
                    await self._publish_node_delta(node)
            return

        LOG.debug("Unhandled event: %s", event.value)

    # ------------------------------------------------------------------ #
    #  Publishing helpers
    # ------------------------------------------------------------------ #

    async def _publish_node_delta(self, node) -> None:
        nid = node.node_id
        current = flatten_node_attrs(node)
        previous = self._last_attrs.get(nid, {})
        deltas = {k: v for k, v in current.items() if previous.get(k) != v}
        if deltas:
            for path, value in deltas.items():
                topic = ATTR_TOPIC_FMT.format(base=self.base_topic, node_id=nid, path=safe_attr_path(path))
                self._enqueue(topic, value)
            self._enqueue(ALL_TOPIC_FMT.format(base=self.base_topic, node_id=nid), current)
            LOG.debug("Published %s delta(s) for node %s", len(deltas), nid)
        avail = "online" if getattr(node, "available", True) else "offline"
        self._enqueue(AVAIL_TOPIC_FMT.format(base=self.base_topic, node_id=nid), avail)
        self._last_attrs[nid] = current

    def _enqueue(self, topic: str, payload: Any) -> None:
        try:
            self.mqtt_queue.put_nowait((topic, payload))
        except asyncio.QueueFull:
            try:
                dropped = self.mqtt_queue.get_nowait()
            except asyncio.QueueEmpty:
                dropped = None
            try:
                self.mqtt_queue.put_nowait((topic, payload))
            except asyncio.QueueFull:
                pass
            if dropped is not None:
                LOG.warning("Dropped oldest MQTT message: %s", dropped[0])

    async def _publish_offline_all(self) -> None:
        LOG.info("Publishing offline for %s known node(s)", len(self._known_nodes))
        for nid in self._known_nodes:
            self._enqueue(AVAIL_TOPIC_FMT.format(base=self.base_topic, node_id=nid), "offline")
        # Give the MQTT loop a few seconds to flush.
        for _ in range(10):
            if self.mqtt_queue.empty():
                break
            await asyncio.sleep(0.5)

    async def _wait_or_shutdown(self, timeout: float) -> bool:
        """Sleep *timeout* seconds, but return True early if shutdown was requested."""
        try:
            await asyncio.wait_for(self.shutdown_event.wait(), timeout=timeout)
            return True
        except asyncio.TimeoutError:
            return False


async def main() -> None:
    parser = argparse.ArgumentParser(description="Matter → MQTT bridge")
    parser.add_argument("--matter-url", default=os.environ.get("MATTER_URL", "ws://localhost:5580/ws"))
    parser.add_argument("--mqtt-host", default=os.environ.get("MQTT_HOST", "localhost"))
    parser.add_argument("--mqtt-port", type=int, default=int(os.environ.get("MQTT_PORT", "1883")))
    parser.add_argument("--mqtt-user", default=os.environ.get("MQTT_USER", "mqtt"))
    parser.add_argument("--mqtt-password", default=os.environ.get("MQTT_PASSWORD", ""), help="Or set MQTT_PASSWORD env")
    parser.add_argument("--base-topic", default=os.environ.get("BASE_TOPIC", "matter"))
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    )

    password = args.mqtt_password or os.environ.get("MQTT_PASSWORD", "")
    if not password:
        LOG.error("MQTT password required. Provide via --mqtt-password or MQTT_PASSWORD.")
        sys.exit(1)

    bridge = MatterMqttBridge(
        matter_url=args.matter_url,
        mqtt_host=args.mqtt_host,
        mqtt_port=args.mqtt_port,
        mqtt_user=args.mqtt_user,
        mqtt_password=password,
        base_topic=args.base_topic,
    )

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, bridge.shutdown_event.set)

    await bridge.run()


if __name__ == "__main__":
    asyncio.run(main())
