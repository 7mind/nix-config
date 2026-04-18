//! Tests for `event`. Split out so `event.rs` stays focused on
//! production code. See `event.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;

#[test]
fn button_press_event_roundtrip() {
    let event = Event::ButtonPress {
        device: "hue-s-kitchen".into(),
        button: "on".into(),
        gesture: Gesture::Press,
        ts: Instant::now(),
    };
    match event {
        Event::ButtonPress { device, button, gesture, .. } => {
            assert_eq!(device, "hue-s-kitchen");
            assert_eq!(button, "on");
            assert_eq!(gesture, Gesture::Press);
        }
        _ => panic!("expected ButtonPress"),
    }
}
