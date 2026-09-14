use crate::topology::{DeviceIdx, ResolvedMotionTarget};
use std::collections::BTreeSet;
use std::time::Instant;

#[derive(Debug, Clone)]
pub struct MotionSession {
    pub slot: String,
    pub target: ResolvedMotionTarget,
    pub claimed: BTreeSet<DeviceIdx>,
}

#[derive(Debug, Clone, Default)]
pub struct MotionRuleState {
    pub session: Option<MotionSession>,
    pub last_motion_off_at: Option<Instant>,
}
