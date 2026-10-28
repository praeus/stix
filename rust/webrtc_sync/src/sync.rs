//! `RtcSync`: replicates properties of its parent node through an `RtcSession`.
//!
//! Add it as a child of e.g. a player, list the properties to sync, and set
//! `owner_peer` to the peer that controls that player. The owner sends deltas
//! at the session's `sync_rate`; everyone else applies them, optionally
//! interpolating numeric/vector properties for smooth motion.

use std::collections::HashMap;

use godot::classes::{INode, Node};
use godot::prelude::*;

pub const SYNC_GROUP: &str = "rtc_sync";

#[derive(GodotClass)]
#[class(base=Node)]
pub struct RtcSync {
    /// Property paths on the parent, e.g. `position`, `velocity`, `modulate:a`.
    #[export]
    properties: PackedStringArray,
    /// Identifier shared by all peers for this object. Defaults to the parent's
    /// scene path, so it must be set explicitly for nodes spawned at runtime
    /// with non-deterministic names.
    #[export]
    net_id: GString,
    /// Peer id that owns (sends) this state. Every other peer receives it.
    #[export]
    owner_peer: i64,
    /// Send over the reliable channel instead of the unreliable one.
    #[export]
    reliable: bool,
    /// Smoothly approach received float/Vector2/Vector3 values instead of snapping.
    #[export]
    interpolate: bool,
    /// Higher is snappier. Roughly "1 / seconds to close most of the gap".
    #[export]
    interpolation_speed: f64,
    /// Snap instead of interpolating when the error exceeds this distance (0 = never).
    #[export]
    snap_distance: f64,

    local_peer: i64,
    send_seq: i64,
    last_recv_seq: i64,
    last_sent: HashMap<String, Variant>,
    targets: HashMap<String, Variant>,

    base: Base<Node>,
}

#[godot_api]
impl INode for RtcSync {
    fn init(base: Base<Node>) -> Self {
        Self {
            properties: PackedStringArray::from(&[GString::from("position")]),
            net_id: GString::new(),
            owner_peer: 1,
            reliable: false,
            interpolate: true,
            interpolation_speed: 15.0,
            snap_distance: 0.0,
            local_peer: 0,
            send_seq: 0,
            last_recv_seq: -1,
            last_sent: HashMap::new(),
            targets: HashMap::new(),
            base,
        }
    }

    fn ready(&mut self) {
        if self.net_id.is_empty()
            && let Some(parent) = self.base().get_parent()
        {
            self.net_id = GString::from(&parent.get_path().to_string());
        }
        self.base_mut().add_to_group(SYNC_GROUP);
    }

    fn process(&mut self, delta: f64) {
        if self.is_authority() || !self.interpolate || self.targets.is_empty() {
            return;
        }
        let Some(mut parent) = self.base().get_parent() else {
            return;
        };
        let weight = 1.0 - (-self.interpolation_speed * delta).exp();
        let snap = self.snap_distance;
        self.targets.retain(|prop, target| {
            let path = NodePath::from(prop.as_str());
            let current = parent.get_indexed(&path);
            match step_toward(&current, target, weight, snap) {
                Some((value, done)) => {
                    parent.set_indexed(&path, &value);
                    !done
                }
                None => {
                    parent.set_indexed(&path, &*target);
                    false
                }
            }
        });
    }
}

#[godot_api]
impl RtcSync {
    /// True when this peer owns the state (or no session has started yet).
    #[func]
    fn is_authority(&self) -> bool {
        self.local_peer == 0 || self.local_peer == self.owner_peer
    }
}

/// Session-facing API.
impl RtcSync {
    pub fn set_local_peer(&mut self, id: i64) {
        self.local_peer = id;
    }

    pub fn net_id_string(&self) -> String {
        self.net_id.to_string()
    }

    pub fn owner_peer(&self) -> i64 {
        self.owner_peer
    }

    pub fn is_reliable(&self) -> bool {
        self.reliable
    }

    /// Forget sequence tracking, e.g. when peers join and senders may restart.
    pub fn reset_remote_state(&mut self) {
        self.last_recv_seq = -1;
        self.last_sent.clear();
    }

    /// Changed properties since the last call (all of them when `full`), or
    /// `None` when nothing changed.
    pub fn collect_local_state(&mut self, full: bool) -> Option<(i64, VarDictionary)> {
        let parent = self.base().get_parent()?;
        let mut props = VarDictionary::new();
        for prop in self.properties.as_slice() {
            let key = prop.to_string();
            let value = parent.get_indexed(&NodePath::from(prop));
            if full || self.last_sent.get(&key) != Some(&value) {
                props.set(prop, &value);
                self.last_sent.insert(key, value);
            }
        }
        if props.is_empty() {
            return None;
        }
        self.send_seq += 1;
        Some((self.send_seq, props))
    }

    pub fn apply_remote_state(&mut self, seq: i64, full: bool, props: &VarDictionary) {
        // Unreliable packets can arrive out of order; drop stale deltas.
        // Full snapshots are always taken so a restarted sender recovers.
        if seq <= self.last_recv_seq && !full {
            return;
        }
        self.last_recv_seq = seq;

        let Some(mut parent) = self.base().get_parent() else {
            return;
        };
        for (key, value) in props.iter_shared() {
            let Ok(prop) = key.try_to::<GString>() else {
                continue;
            };
            if self.interpolate && is_interpolatable(&value) {
                self.targets.insert(prop.to_string(), value);
            } else {
                parent.set_indexed(&NodePath::from(&prop), &value);
            }
        }
    }
}

fn is_interpolatable(v: &Variant) -> bool {
    matches!(
        v.get_type(),
        VariantType::FLOAT | VariantType::VECTOR2 | VariantType::VECTOR3
    )
}

/// One interpolation step. Returns the new value and whether the target was
/// reached, or `None` if the types don't match (caller snaps).
fn step_toward(current: &Variant, target: &Variant, weight: f64, snap: f64) -> Option<(Variant, bool)> {
    const EPS: f64 = 1e-3;
    match target.get_type() {
        VariantType::FLOAT => {
            let (a, b) = (current.try_to::<f64>().ok()?, target.try_to::<f64>().ok()?);
            if (b - a).abs() < EPS || (snap > 0.0 && (b - a).abs() > snap) {
                return Some((b.to_variant(), true));
            }
            Some(((a + (b - a) * weight).to_variant(), false))
        }
        VariantType::VECTOR2 => {
            let (a, b) = (current.try_to::<Vector2>().ok()?, target.try_to::<Vector2>().ok()?);
            let dist = f64::from(a.distance_to(b));
            if dist < EPS || (snap > 0.0 && dist > snap) {
                return Some((b.to_variant(), true));
            }
            Some((a.lerp(b, weight as real).to_variant(), false))
        }
        VariantType::VECTOR3 => {
            let (a, b) = (current.try_to::<Vector3>().ok()?, target.try_to::<Vector3>().ok()?);
            let dist = f64::from(a.distance_to(b));
            if dist < EPS || (snap > 0.0 && dist > snap) {
                return Some((b.to_variant(), true));
            }
            Some((a.lerp(b, weight as real).to_variant(), false))
        }
        _ => None,
    }
}
