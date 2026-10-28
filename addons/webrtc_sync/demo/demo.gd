extends Node2D
## WebRTC multiplayer demo.
##
## Run two (or more) instances: click "Host" in one, then "Join" in the others
## with the host's address. Move with the arrow keys, press C to pick a new
## color (shared variable), P to ping everyone (message).

const PORT := 9080
const PlayerScript := preload("res://addons/webrtc_sync/demo/demo_player.gd")

@onready var session: RtcSession = $RtcSession
@onready var lobby: RtcLobby = $RtcLobby
@onready var server: RtcSignalingServer = $RtcSignalingServer
@onready var address: LineEdit = %Address
@onready var status: Label = %Status

var _players: Dictionary[int, Node2D] = {}


func _ready() -> void:
	%Host.pressed.connect(_on_host)
	%Join.pressed.connect(func(): _join(address.text))
	lobby.joined.connect(_on_joined)
	lobby.left.connect(func(): _log("Left lobby"))
	session.peer_connected.connect(_on_peer_connected)
	session.peer_disconnected.connect(_on_peer_disconnected)
	session.shared_var_changed.connect(_on_shared_var_changed)
	session.message_received.connect(_on_message)


func _unhandled_input(event: InputEvent) -> void:
	if not session.is_started() or not event is InputEventKey or not event.pressed:
		return
	match event.keycode:
		KEY_C:
			var key := "color_%d" % session.get_local_id()
			session.set_shared(key, Color.from_hsv(randf(), 0.7, 0.95))
		KEY_P:
			session.send_message(0, "ping", Time.get_ticks_msec(), true)


func _on_host() -> void:
	var err := server.listen(PORT)
	if err != OK:
		_log("Could not listen on %d: %s" % [PORT, error_string(err)])
		return
	_join("ws://127.0.0.1:%d" % PORT)


func _join(url: String) -> void:
	var err := lobby.join(url)
	_log("Connecting to %s..." % url if err == OK else "Join failed: %s" % error_string(err))


func _on_joined(id: int) -> void:
	_log("Joined as peer %d" % id)
	_spawn(id).position = get_viewport_rect().size / 2.0


func _on_peer_connected(id: int) -> void:
	_log("Peer %d connected" % id)
	_spawn(id)


func _on_peer_disconnected(id: int) -> void:
	_log("Peer %d disconnected" % id)
	if _players.has(id):
		_players[id].queue_free()
		_players.erase(id)


func _on_shared_var_changed(key: String, value: Variant, _writer: int) -> void:
	if key.begins_with("color_"):
		var id := int(key.trim_prefix("color_"))
		if _players.has(id):
			_players[id].color = value


func _on_message(from: int, channel: String, data: Variant) -> void:
	match channel:
		"ping":
			session.send_message(from, "pong", data, true)
		"pong":
			_log("Pong from %d: %d ms" % [from, Time.get_ticks_msec() - int(data)])


func _spawn(id: int) -> Node2D:
	if _players.has(id):
		return _players[id]
	var player := Node2D.new()
	player.set_script(PlayerScript)
	player.setup(id)
	player.color = session.get_shared("color_%d" % id, Color.WHITE)
	add_child(player)
	_players[id] = player
	return player


func _log(text: String) -> void:
	print(text)
	status.text = text
