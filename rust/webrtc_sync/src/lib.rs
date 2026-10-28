//! WebRTC multiplayer for Godot 4, built on `webrtc` (webrtc-rs) and godot-rust.
//!
//! Classes exposed to GDScript:
//! * `RtcPeer` / `RtcChannel` – thin wrappers over a peer connection and its data channels.
//! * `RtcSession` – mesh of peers with signaling helpers, messages and shared variables.
//! * `RtcSync` – child node that replicates properties of its parent through an `RtcSession`.

use godot::prelude::*;

mod core;
mod peer;
mod protocol;
mod session;
mod sync;

struct WebRtcSyncExtension;

#[gdextension]
unsafe impl ExtensionLibrary for WebRtcSyncExtension {}
