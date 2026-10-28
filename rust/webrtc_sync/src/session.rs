//! `RtcSession`: a full-mesh multiplayer session over WebRTC data channels.
//!
//! Responsibilities:
//! * Create/negotiate one connection per remote peer. Signaling transport is
//!   left to the game: forward `signaling_message` to the remote peer and feed
//!   what arrives into `handle_signaling_message()`.
//! * Two data channels per peer: `reliable` (ordered) and `unreliable`
//!   (unordered, no retransmits) for high-frequency state.
//! * Tick every `RtcSync` node in the scene tree at `sync_rate` Hz.
//! * User messages (`send_message`) and a replicated key/value store (`set_shared`).

use std::collections::{HashMap, HashSet};

use godot::classes::{INode, Node};
use godot::prelude::*;

use crate::core::{ChannelEvent, ChannelHandle, ChannelOptions, ConnectionState, IceServer, PeerEvent, PeerHandle};
use crate::protocol::Msg;
use crate::sync::{RtcSync, SYNC_GROUP};

pub const SESSION_GROUP: &str = "rtc_session";
const RELIABLE_LABEL: &str = "reliable";
const UNRELIABLE_LABEL: &str = "unreliable";

/// Broadcast target for `send_message`.
const ALL_PEERS: i64 = 0;

struct Remote {
    handle: PeerHandle,
    reliable: Option<ChannelHandle>,
    unreliable: Option<ChannelHandle>,
    announced: bool,
}

impl Remote {
    fn is_ready(&self) -> bool {
        self.reliable.as_ref().is_some_and(|c| c.is_open())
            && self.unreliable.as_ref().is_some_and(|c| c.is_open())
    }

    fn send(&self, bytes: Vec<u8>, reliable: bool) {
        let chan = if reliable { &self.reliable } else { &self.unreliable };
        if let Some(chan) = chan {
            chan.send(bytes);
        }
    }
}

struct SharedEntry {
    value: Variant,
    clock: i64,
    writer: i64,
}

/// Signals are queued while state is being mutated and emitted at the end of
/// `poll()`, so handlers always observe a consistent session.
enum Emit {
    Signaling(i64, VarDictionary),
    Connected(i64),
    Disconnected(i64),
    Message(i64, GString, Variant),
    Shared(GString, Variant, i64),
    MissingSync(GString, i64),
}

#[derive(GodotClass)]
#[class(base=Node)]
pub struct RtcSession {
    /// STUN/TURN URLs, e.g. "stun:stun.l.google.com:19302" or "turn:turn.example.com:3478".
    #[export]
    ice_urls: PackedStringArray,
    /// Credentials applied to every `turn:`/`turns:` URL in `ice_urls`.
    #[export]
    turn_username: GString,
    #[export]
    turn_credential: GString,
    /// State updates sent per second for each owned `RtcSync`.
    #[export]
    sync_rate: f64,
    /// Seconds between full snapshots (deltas are sent in between). Full
    /// snapshots repair state lost on the unreliable channel.
    #[export]
    keyframe_interval: f64,
    /// Poll automatically from `_process`. Disable to call `poll()` yourself.
    #[export]
    auto_poll: bool,
    /// Only `RtcSync` nodes under this node take part. Empty = the whole tree.
    #[export]
    sync_root: Option<Gd<Node>>,

    local_id: i64,
    peers: HashMap<i64, Remote>,
    shared: HashMap<String, SharedEntry>,
    clock: i64,
    sync_accum: f64,
    keyframe_accum: f64,
    force_keyframe: bool,
    missing_reported: HashSet<String>,
    pending: Vec<Emit>,

    base: Base<Node>,
}

#[godot_api]
impl INode for RtcSession {
    fn init(base: Base<Node>) -> Self {
        Self {
            ice_urls: PackedStringArray::from(&[GString::from("stun:stun.l.google.com:19302")]),
            turn_username: GString::new(),
            turn_credential: GString::new(),
            sync_rate: 20.0,
            keyframe_interval: 1.0,
            auto_poll: true,
            sync_root: None,
            local_id: 0,
            peers: HashMap::new(),
            shared: HashMap::new(),
            clock: 0,
            sync_accum: 0.0,
            keyframe_accum: 0.0,
            force_keyframe: false,
            missing_reported: HashSet::new(),
            pending: Vec::new(),
            base,
        }
    }

    fn ready(&mut self) {
        self.base_mut().add_to_group(SESSION_GROUP);
    }

    fn process(&mut self, delta: f64) {
        if self.auto_poll {
            self.tick(delta);
        }
    }

    fn exit_tree(&mut self) {
        self.close();
    }
}

#[godot_api]
impl RtcSession {
    /// Ask the game to deliver `message` to `peer_id` through your signaling server.
    #[signal]
    fn signaling_message(peer_id: i64, message: VarDictionary);
    #[signal]
    fn peer_connected(peer_id: i64);
    #[signal]
    fn peer_disconnected(peer_id: i64);
    #[signal]
    fn message_received(from_peer: i64, channel: GString, data: Variant);
    #[signal]
    fn shared_var_changed(key: GString, value: Variant, writer: i64);
    /// State arrived for a `net_id` with no matching `RtcSync` – a good hook
    /// for spawning remote players on demand. Emitted once per `net_id`.
    #[signal]
    fn sync_target_missing(net_id: GString, from_peer: i64);

    /// Begin the session with the id your signaling server assigned to this client.
    /// Ids must be unique and non-zero.
    #[func]
    fn start(&mut self, local_id: i64) {
        assert!(local_id != 0, "RtcSession: local id 0 is reserved");
        self.local_id = local_id;
        self.clock = 0;
    }

    #[func]
    fn get_local_id(&self) -> i64 {
        self.local_id
    }

    #[func]
    fn is_started(&self) -> bool {
        self.local_id != 0
    }

    /// Connect to a remote peer. Call on both sides when the signaling server
    /// announces a peer; the side with the lower id sends the offer.
    #[func]
    fn add_peer(&mut self, peer_id: i64) {
        if self.local_id == 0 || peer_id == self.local_id || self.peers.contains_key(&peer_id) {
            return;
        }
        let handle = match PeerHandle::new(self.ice_servers()) {
            Ok(h) => h,
            Err(e) => {
                godot_error!("RtcSession: failed to create connection to {peer_id}: {e}");
                return;
            }
        };

        let mut remote = Remote {
            handle,
            reliable: None,
            unreliable: None,
            announced: false,
        };
        if self.local_id < peer_id {
            remote.reliable = Some(remote.handle.create_data_channel(RELIABLE_LABEL, ChannelOptions::RELIABLE));
            remote.unreliable = Some(remote.handle.create_data_channel(UNRELIABLE_LABEL, ChannelOptions::UNRELIABLE));
            remote.handle.create_offer();
        }
        self.peers.insert(peer_id, remote);
    }

    #[func]
    fn remove_peer(&mut self, peer_id: i64) {
        if let Some(remote) = self.peers.remove(&peer_id)
            && remote.announced
        {
            self.signals().peer_disconnected().emit(peer_id);
        }
    }

    /// Feed a message produced by the remote peer's `signaling_message` signal.
    #[func]
    fn handle_signaling_message(&mut self, from_peer: i64, message: VarDictionary) {
        let text = |key: &str| {
            message
                .get(key)
                .and_then(|v| v.try_to::<GString>().ok())
                .map(|s| s.to_string())
                .unwrap_or_default()
        };
        let kind = text("type");

        // An offer may arrive before our own signaling told us about the peer.
        if kind == "offer" && !self.peers.contains_key(&from_peer) {
            self.add_peer(from_peer);
        }
        let Some(remote) = self.peers.get(&from_peer) else {
            godot_warn!("RtcSession: signaling message from unknown peer {from_peer}");
            return;
        };

        match kind.as_str() {
            "offer" | "answer" => remote.handle.set_remote_description(kind, text("sdp")),
            "candidate" => {
                let index = message
                    .get("sdp_mline_index")
                    .and_then(|v| v.try_to::<i64>().ok())
                    .unwrap_or(0);
                remote
                    .handle
                    .add_ice_candidate(text("candidate"), text("sdp_mid"), index);
            }
            other => godot_warn!("RtcSession: unknown signaling message type '{other}'"),
        }
    }

    /// Send `data` (any non-Object Variant) on a named logical channel.
    /// `to_peer` = 0 broadcasts to every connected peer.
    #[func]
    fn send_message(&self, to_peer: i64, channel: GString, data: Variant, reliable: bool) {
        let bytes = Msg::User { channel, data }.encode();
        self.send_to(to_peer, bytes, reliable);
    }

    /// Set a replicated variable. Conflicts resolve last-writer-wins.
    #[func]
    fn set_shared(&mut self, key: GString, value: Variant) {
        self.clock += 1;
        let entry = SharedEntry {
            value: value.clone(),
            clock: self.clock,
            writer: self.local_id,
        };
        self.shared.insert(key.to_string(), entry);
        let bytes = Msg::Shared {
            key: key.clone(),
            value: value.clone(),
            clock: self.clock,
            writer: self.local_id,
        }
        .encode();
        self.send_to(ALL_PEERS, bytes, true);
        let writer = self.local_id;
        self.signals().shared_var_changed().emit(&key, &value, writer);
    }

    #[func]
    fn get_shared(&self, key: GString, default: Variant) -> Variant {
        self.shared
            .get(&key.to_string())
            .map_or(default, |e| e.value.clone())
    }

    #[func]
    fn get_shared_keys(&self) -> PackedStringArray {
        self.shared.keys().map(GString::from).collect()
    }

    /// Ids of peers whose data channels are open.
    #[func]
    fn get_peer_ids(&self) -> PackedInt64Array {
        self.peers
            .iter()
            .filter(|(_, r)| r.announced)
            .map(|(id, _)| *id)
            .collect()
    }

    #[func]
    fn get_peer_state(&self, peer_id: i64) -> GString {
        self.peers
            .get(&peer_id)
            .map_or("closed", |r| r.handle.state().as_str())
            .into()
    }

    /// Disconnect from everyone and reset the session.
    #[func]
    fn close(&mut self) {
        let ids: Vec<i64> = self.peers.keys().copied().collect();
        for id in ids {
            self.remove_peer(id);
        }
        self.local_id = 0;
        self.shared.clear();
        self.missing_reported.clear();
    }

    /// Process network events and send state updates. Called automatically
    /// from `_process` when `auto_poll` is enabled.
    #[func]
    fn poll(&mut self, delta: f64) {
        self.tick(delta);
    }
}

impl RtcSession {
    fn ice_servers(&self) -> Vec<IceServer> {
        self.ice_urls
            .as_slice()
            .iter()
            .map(|url| {
                let url = url.to_string();
                let is_turn = url.starts_with("turn:") || url.starts_with("turns:");
                IceServer {
                    urls: vec![url],
                    username: if is_turn { self.turn_username.to_string() } else { String::new() },
                    credential: if is_turn { self.turn_credential.to_string() } else { String::new() },
                }
            })
            .collect()
    }

    fn send_to(&self, to_peer: i64, bytes: Vec<u8>, reliable: bool) {
        if to_peer == ALL_PEERS {
            for remote in self.peers.values().filter(|r| r.announced) {
                remote.send(bytes.clone(), reliable);
            }
        } else if let Some(remote) = self.peers.get(&to_peer) {
            remote.send(bytes, reliable);
        }
    }

    fn tick(&mut self, delta: f64) {
        if self.local_id == 0 {
            return;
        }
        let syncs = self.collect_syncs();
        self.pump_network(&syncs);
        self.send_state(&syncs, delta);
        self.flush_signals();
    }

    /// Every `RtcSync` in the tree, keyed by net id. Rebuilt each tick so nodes
    /// can come and go freely without explicit registration.
    fn collect_syncs(&self) -> HashMap<String, Gd<RtcSync>> {
        let tree = self.base().get_tree();
        let mut map = HashMap::new();
        for node in tree.get_nodes_in_group(SYNC_GROUP).iter_shared() {
            if let Some(root) = &self.sync_root
                && !root.is_ancestor_of(&node)
            {
                continue;
            }
            if let Ok(mut sync) = node.try_cast::<RtcSync>() {
                let net_id = {
                    let mut s = sync.bind_mut();
                    s.set_local_peer(self.local_id);
                    s.net_id_string()
                };
                map.insert(net_id, sync);
            }
        }
        map
    }

    fn pump_network(&mut self, syncs: &HashMap<String, Gd<RtcSync>>) {
        let mut dead = Vec::new();
        let mut inbox: Vec<(i64, Vec<u8>)> = Vec::new();
        let mut newly_ready = Vec::new();

        for (&id, remote) in self.peers.iter_mut() {
            for event in remote.handle.drain() {
                match event {
                    PeerEvent::LocalDescription { sdp_type, sdp } => {
                        let msg = vdict! { "type" => sdp_type, "sdp" => sdp };
                        self.pending.push(Emit::Signaling(id, msg));
                    }
                    PeerEvent::IceCandidate {
                        candidate,
                        sdp_mid,
                        sdp_mline_index,
                    } => {
                        let msg = vdict! {
                            "type" => "candidate",
                            "candidate" => candidate,
                            "sdp_mid" => sdp_mid,
                            "sdp_mline_index" => sdp_mline_index,
                        };
                        self.pending.push(Emit::Signaling(id, msg));
                    }
                    PeerEvent::ConnectionState(ConnectionState::Failed | ConnectionState::Closed) => {
                        dead.push(id);
                    }
                    PeerEvent::ConnectionState(_) => {}
                    PeerEvent::DataChannel(chan) => match chan.label() {
                        RELIABLE_LABEL => remote.reliable = Some(chan),
                        UNRELIABLE_LABEL => remote.unreliable = Some(chan),
                        other => godot_warn!("RtcSession: ignoring unexpected channel '{other}'"),
                    },
                    PeerEvent::Error(e) => godot_warn!("RtcSession: peer {id}: {e}"),
                }
            }

            for chan in [&mut remote.reliable, &mut remote.unreliable].into_iter().flatten() {
                for event in chan.drain() {
                    match event {
                        ChannelEvent::Message { data, .. } => inbox.push((id, data)),
                        ChannelEvent::Closed if remote.announced => dead.push(id),
                        ChannelEvent::Error(e) => godot_warn!("RtcSession: peer {id} channel: {e}"),
                        _ => {}
                    }
                }
            }

            if !remote.announced && remote.is_ready() {
                remote.announced = true;
                newly_ready.push(id);
            }
        }

        for id in newly_ready {
            self.on_peer_ready(id, syncs);
        }
        for (from, bytes) in inbox {
            self.dispatch(from, &bytes, syncs);
        }
        dead.sort_unstable();
        dead.dedup();
        for id in dead {
            if let Some(remote) = self.peers.remove(&id)
                && remote.announced
            {
                self.pending.push(Emit::Disconnected(id));
            }
        }
    }

    fn on_peer_ready(&mut self, id: i64, syncs: &HashMap<String, Gd<RtcSync>>) {
        // Bring the newcomer up to date: shared vars now, full sync state next tick.
        if let Some(remote) = self.peers.get(&id) {
            for (key, entry) in &self.shared {
                let bytes = Msg::Shared {
                    key: GString::from(key),
                    value: entry.value.clone(),
                    clock: entry.clock,
                    writer: entry.writer,
                }
                .encode();
                remote.send(bytes, true);
            }
        }
        for sync in syncs.values() {
            sync.clone().bind_mut().reset_remote_state();
        }
        self.force_keyframe = true;
        self.pending.push(Emit::Connected(id));
    }

    fn dispatch(&mut self, from: i64, bytes: &[u8], syncs: &HashMap<String, Gd<RtcSync>>) {
        let Some(msg) = Msg::decode(bytes) else {
            godot_warn!("RtcSession: dropped malformed packet from {from}");
            return;
        };
        match msg {
            Msg::State {
                net_id,
                seq,
                full,
                props,
            } => {
                let key = net_id.to_string();
                match syncs.get(&key) {
                    Some(sync) => {
                        let mut sync = sync.clone();
                        let mut s = sync.bind_mut();
                        // Only the owner may drive a node's state.
                        if s.owner_peer() == from && from != self.local_id {
                            s.apply_remote_state(seq, full, &props);
                        }
                    }
                    None => {
                        if self.missing_reported.insert(key) {
                            self.pending.push(Emit::MissingSync(net_id, from));
                        }
                    }
                }
            }
            Msg::User { channel, data } => self.pending.push(Emit::Message(from, channel, data)),
            Msg::Shared {
                key,
                value,
                clock,
                writer,
            } => {
                self.clock = self.clock.max(clock);
                let k = key.to_string();
                let newer = self
                    .shared
                    .get(&k)
                    .is_none_or(|e| (clock, writer) > (e.clock, e.writer));
                if newer {
                    self.shared.insert(
                        k,
                        SharedEntry {
                            value: value.clone(),
                            clock,
                            writer,
                        },
                    );
                    self.pending.push(Emit::Shared(key, value, writer));
                }
            }
        }
    }

    fn send_state(&mut self, syncs: &HashMap<String, Gd<RtcSync>>, delta: f64) {
        if self.sync_rate <= 0.0 {
            return;
        }
        self.sync_accum += delta;
        self.keyframe_accum += delta;
        let interval = 1.0 / self.sync_rate;
        if self.sync_accum < interval {
            return;
        }
        self.sync_accum %= interval;

        let full = self.force_keyframe || self.keyframe_accum >= self.keyframe_interval;
        if full {
            self.keyframe_accum = 0.0;
            self.force_keyframe = false;
        }

        if !self.peers.values().any(|r| r.announced) {
            return;
        }
        for (net_id, sync) in syncs {
            let mut sync = sync.clone();
            let mut s = sync.bind_mut();
            if s.owner_peer() != self.local_id {
                continue;
            }
            if let Some((seq, props)) = s.collect_local_state(full) {
                let bytes = Msg::State {
                    net_id: GString::from(net_id),
                    seq,
                    full,
                    props,
                }
                .encode();
                self.send_to(ALL_PEERS, bytes, s.is_reliable());
            }
        }
    }

    fn flush_signals(&mut self) {
        for emit in std::mem::take(&mut self.pending) {
            match emit {
                Emit::Signaling(id, msg) => self.signals().signaling_message().emit(id, &msg),
                Emit::Connected(id) => self.signals().peer_connected().emit(id),
                Emit::Disconnected(id) => self.signals().peer_disconnected().emit(id),
                Emit::Message(from, chan, data) => {
                    self.signals().message_received().emit(from, &chan, &data)
                }
                Emit::Shared(key, value, writer) => {
                    self.signals().shared_var_changed().emit(&key, &value, writer)
                }
                Emit::MissingSync(net_id, from) => {
                    self.signals().sync_target_missing().emit(&net_id, from)
                }
            }
        }
    }
}
