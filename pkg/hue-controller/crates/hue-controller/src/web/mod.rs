//! WebSocket API and web dashboard server.
//!
//! This module provides a WebSocket-based API that runs alongside the
//! MQTT event loop, allowing browser clients to observe the controller's
//! state and decisions in real time and to issue manual commands.

pub mod decision_capture;
pub mod server;
pub mod snapshot;

pub use server::{WebHandle, WsCommand, start_web_server};
