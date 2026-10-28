# webrtc_sync

Peer-to-peer WebRTC multiplayer for Godot 4, written in Rust on top of
[`webrtc`](https://crates.io/crates/webrtc) 0.21 (webrtc-rs) and
[godot-rust](https://godot-rust.github.io/) 0.5.

```
addons/webrtc_sync/
  webrtc_sync.gdextension   points Godot at the compiled library
  lobby.gd                  RtcLobby: WebSocket signaling client for RtcSession
  signaling_server.gd       RtcSignalingServer: tiny relay server (GDScript)
  demo/                     two-player demo + headless signaling server scene
  tests/smoke_test.gd       end-to-end test (two sessions, one process)
rust/
  webrtc_sync/src/
    core.rs       async bridge: tokio runtime, per-connection command queue
    peer.rs       RtcPeer / RtcChannel (low-level API)
    session.rs    RtcSession (mesh, messages, shared vars, sync ticking)
    sync.rs       RtcSync (property replication + interpolation)
    protocol.rs   wire format (var_to_bytes arrays)
```

## Build

```bash
cd rust && cargo build            # debug, loaded by the editor
cd rust && cargo build --release  # for exports
```

`rust/.gdignore` hides the crate from the Godot importer. After rebuilding,
the editor hot-reloads the library (`reloadable = true`).

Tests:

```bash
cd rust && cargo test   # two in-process peers over real WebRTC
godot --headless --path . -s res://addons/webrtc_sync/tests/smoke_test.gd
```

## Demo

Open `demo/demo.tscn` and run two instances (Debug → Customize Run Instances).
Click **Host** in one, **Join** in the other. Arrow keys move, **C** changes
your color (shared variable), **P** pings every peer (message).

## Architecture

WebRTC needs a *signaling* channel to exchange SDP offers/answers and ICE
candidates before peers can talk directly. The extension does not care how
that happens; `RtcLobby` + `RtcSignalingServer` are one simple option.

```
RtcSignalingServer (WebSocket, relays only)
     ▲          ▲
 RtcLobby    RtcLobby
     │          │
 RtcSession ◄──────► RtcSession     WebRTC data channels, full mesh
  RtcSync ...         RtcSync ...
```

Each pair of peers shares two data channels: `reliable` (ordered) and
`unreliable` (unordered, 0 retransmits). The peer with the lower id sends the
offer. All network I/O runs on a background tokio runtime; events are queued
and delivered on the main thread in `_process`, so every signal fires on the
game thread.

## High-level API

### RtcSession (Node)

| Member | |
|---|---|
| `ice_urls`, `turn_username`, `turn_credential` | STUN/TURN servers |
| `sync_rate` (20) | state updates per second |
| `keyframe_interval` (1.0) | seconds between full snapshots (deltas in between) |
| `sync_root` | only `RtcSync` nodes under this node are used (default: whole tree) |
| `start(local_id)` / `close()` | begin / end the session |
| `add_peer(id)` / `remove_peer(id)` | connect / disconnect a peer |
| `handle_signaling_message(from, msg)` | feed incoming signaling |
| `send_message(to, channel, data, reliable)` | any non-Object Variant; `to = 0` broadcasts |
| `set_shared(key, value)` / `get_shared(key, default)` | replicated key/value store, last-writer-wins |
| `get_peer_ids()`, `get_peer_state(id)`, `get_local_id()` | |
| signals | `signaling_message`, `peer_connected`, `peer_disconnected`, `message_received`, `shared_var_changed`, `sync_target_missing` |

### RtcSync (Node)

Add as a child of the node to replicate.

| Member | |
|---|---|
| `properties` | property paths on the parent: `position`, `velocity`, `modulate:a` |
| `net_id` | same on every peer; defaults to the parent's scene path |
| `owner_peer` | the peer that sends this state; everyone else receives |
| `reliable` | use the reliable channel (default: unreliable) |
| `interpolate`, `interpolation_speed`, `snap_distance` | smoothing for float / Vector2 / Vector3 |
| `is_authority()` | true on the owning peer |

Only changed properties are sent, with sequence numbers so stale unreliable
packets are dropped. Updates are accepted only from `owner_peer`.

## Low-level API

`RtcPeer` (RefCounted) mirrors the browser API: `initialize(config)`,
`create_offer()`, `set_remote_description(type, sdp)` (answers offers
automatically), `add_ice_candidate(...)`, `create_data_channel(label, options)`,
`poll()`, and signals `session_description_created`, `ice_candidate_created`,
`connection_state_changed`, `data_channel_received`, `error`.

`RtcChannel`: `send(bytes)`, `send_text(str)`, `send_var(value)`, `is_open()`,
`close()`, signals `opened`, `closed`, `message_received(data, is_string)`.

## Known limitations / next steps

- **Exports**: the `.gdextension` paths point into `rust/target`. For shipping,
  copy the release library into `addons/webrtc_sync/bin/` and update the paths.
- **No TURN by default**: peers behind symmetric NATs need a TURN server in `ice_urls`.
- **Wire format** is `var_to_bytes` arrays with property names. Quantization and
  property indices would cut bandwidth a lot.
- **No spawning helper**: spawn remote objects yourself (`peer_connected`,
  messages, or `sync_target_missing`).
- **Signaling server is for development**: no rooms, auth or rate limiting.
- **Web export**: webrtc-rs does not target WASM; a web build would need Godot's
  built-in WebRTC classes there.
