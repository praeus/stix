//! Wire format used by [`RtcSession`](crate::session::RtcSession) on top of its
//! data channels.
//!
//! Every packet is a Godot `Array` serialized with `var_to_bytes`, whose first
//! element is a message tag. This keeps the scaffold simple and lets any
//! non-Object Variant be synced. A hand-rolled binary format (quantized floats,
//! property indices instead of names) is the obvious optimization later.

use godot::global::{bytes_to_var, var_to_bytes};
use godot::prelude::*;

const TAG_STATE: i64 = 0;
const TAG_USER: i64 = 1;
const TAG_SHARED: i64 = 2;

pub enum Msg {
    /// Property snapshot (full) or delta for one synchronized node.
    State {
        net_id: GString,
        seq: i64,
        full: bool,
        props: VarDictionary,
    },
    /// Arbitrary user message on a named channel.
    User { channel: GString, data: Variant },
    /// Replicated key/value store entry, resolved last-writer-wins by
    /// (Lamport clock, writer id).
    Shared {
        key: GString,
        value: Variant,
        clock: i64,
        writer: i64,
    },
}

impl Msg {
    pub fn encode(&self) -> Vec<u8> {
        let arr: VarArray = match self {
            Msg::State {
                net_id,
                seq,
                full,
                props,
            } => varray![TAG_STATE, net_id, *seq, *full, props],
            Msg::User { channel, data } => varray![TAG_USER, channel, data],
            Msg::Shared {
                key,
                value,
                clock,
                writer,
            } => varray![TAG_SHARED, key, value, *clock, *writer],
        };
        var_to_bytes(&arr.to_variant()).to_vec()
    }

    pub fn decode(bytes: &[u8]) -> Option<Msg> {
        let arr = bytes_to_var(&PackedByteArray::from(bytes)).try_to::<VarArray>().ok()?;
        let tag = arr.get(0)?.try_to::<i64>().ok()?;
        let at = |i: usize| arr.get(i);
        Some(match tag {
            TAG_STATE => Msg::State {
                net_id: at(1)?.try_to().ok()?,
                seq: at(2)?.try_to().ok()?,
                full: at(3)?.try_to().ok()?,
                props: at(4)?.try_to().ok()?,
            },
            TAG_USER => Msg::User {
                channel: at(1)?.try_to().ok()?,
                data: at(2)?,
            },
            TAG_SHARED => Msg::Shared {
                key: at(1)?.try_to().ok()?,
                value: at(2)?,
                clock: at(3)?.try_to().ok()?,
                writer: at(4)?.try_to().ok()?,
            },
            _ => return None,
        })
    }
}
