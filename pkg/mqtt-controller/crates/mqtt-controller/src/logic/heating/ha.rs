//! Home Assistant MQTT discovery + state-update emission. Publishes
//! one retained discovery message per zone/TRV the first time the
//! daemon ticks, then dedup-publishes the derived state strings each
//! time they change.

use std::time::Instant;

use crate::config::heating::HeatingConfig;
use crate::domain::action::Action;
use crate::domain::ha_discovery;
use crate::logic::EventProcessor;

impl EventProcessor {
    pub(super) fn emit_ha_updates(
        &mut self,
        heating_config: &HeatingConfig,
        now: Instant,
    ) -> Vec<Action> {
        let mut actions = Vec::new();

        if !self.ha_discovery_published {
            self.ha_discovery_published = true;
            for zone in &heating_config.zones {
                actions.push(ha_discovery::zone_discovery_action(&zone.name));
                for zt in &zone.trvs {
                    actions.push(ha_discovery::trv_discovery_action(&zt.device));
                }
            }
        }

        let (md, mdf) = self.min_demand();
        let min_pause = heating_config.heat_pump.min_pause_seconds;
        for zone_cfg in &heating_config.zones {
            // Zone state
            let zone_derived = {
                let hz = self.world.heating_zones.get(&zone_cfg.name);
                hz.map(|hz| ha_discovery::derive_zone_state_from_tass(
                    hz, self, now, md, mdf, min_pause,
                )).unwrap_or(ha_discovery::ZoneDerivedState::Unknown)
            };
            let topic = ha_discovery::state_topic("zone", &zone_cfg.name);
            let state_str = zone_derived.as_str();
            if self.ha_last_published.get(&topic).map_or(true, |prev| prev != state_str) {
                let hz = self.world.heating_zones.get(&zone_cfg.name);
                tracing::info!(
                    zone = %zone_cfg.name,
                    from = self.ha_last_published.get(&topic).map(String::as_str).unwrap_or("(none)"),
                    to = state_str,
                    relay_on = hz.is_some_and(|h| h.is_relay_on()),
                    relay_state_known = hz.map_or(false, |h| h.relay_state_known),
                    "HA zone state transition"
                );
                actions.push(ha_discovery::state_update_action("zone", &zone_cfg.name, state_str));
                self.ha_last_published.insert(topic, state_str.to_string());
            }

            // TRV states
            for zt in &zone_cfg.trvs {
                let trv_derived = self.world.trvs.get(&zt.device)
                    .map(|trv| ha_discovery::derive_trv_state_from_tass(trv, now, md, mdf))
                    .unwrap_or(ha_discovery::TrvDerivedState::Unknown);
                let topic = ha_discovery::state_topic("trv", &zt.device);
                let state_str = trv_derived.as_str();
                if self.ha_last_published.get(&topic).map_or(true, |prev| prev != state_str) {
                    actions.push(ha_discovery::state_update_action("trv", &zt.device, state_str));
                    self.ha_last_published.insert(topic, state_str.to_string());
                }
            }
        }
        actions
    }
}
