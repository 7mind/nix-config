//! Pure domain types: events flowing INTO the controller, effects flowing
//! OUT, and the in-memory state the controller holds.
//!
//! Nothing in this module touches MQTT, async, or the clock — it's all
//! plain data + plain functions, the easy bit to test.

pub mod action;
pub mod effect;
pub mod event;
pub mod ha_discovery;

pub use effect::Effect;
