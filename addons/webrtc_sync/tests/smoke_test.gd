extends SceneTree
## End-to-end smoke test: two sessions in one process, real WebRTC between them.
##   godot --headless --path <project> -s res://addons/webrtc_sync/tests/smoke_test.gd

const Server := preload("res://addons/webrtc_sync/signaling_server.gd")
const Lobby := preload("res://addons/webrtc_sync/lobby.gd")
const PORT := 9181
const TIMEOUT_MS := 20000

var clients: Array[Dictionary] = []
var started_ms := 0
var stage := "connect"


func _initialize() -> void:
	var server: Node = Server.new()
	root.add_child(server)
	assert(server.listen(PORT) == OK)
	for i in 2:
		clients.append(_make_client())
	started_ms = Time.get_ticks_msec()


func _make_client() -> Dictionary:
	var c := {"connected": [], "messages": [], "shared": {}}
	var world := Node2D.new()
	root.add_child(world)
	var session := RtcSession.new()
	session.sync_root = world
	world.add_child(session)
	var lobby: Node = Lobby.new()
	lobby.session = session
	world.add_child(lobby)
	for id in [1, 2]:
		var player := Node2D.new()
		var sync := RtcSync.new()
		sync.net_id = "p%d" % id
		sync.owner_peer = id
		sync.interpolate = false
		player.add_child(sync)
		world.add_child(player)
		c["p%d" % id] = player
	session.peer_connected.connect(func(id): c.connected.append(id))
	session.message_received.connect(func(from, ch, data): c.messages.append([from, ch, data]))
	session.shared_var_changed.connect(func(k, v, _w): c.shared[k] = v)
	c.session = session
	lobby.join("ws://127.0.0.1:%d" % PORT)
	return c


func _process(_delta: float) -> bool:
	if Time.get_ticks_msec() - started_ms > TIMEOUT_MS:
		printerr("FAIL: timed out in stage '%s'" % stage)
		quit(1)
		return false

	var a: Dictionary = clients[0]
	var b: Dictionary = clients[1]
	match stage:
		"connect":
			if a.connected.size() == 1 and b.connected.size() == 1:
				var id_a: int = a.session.get_local_id()
				print("connected: %d <-> %d" % [id_a, b.session.get_local_id()])
				a["p%d" % id_a].position = Vector2(100, 50)
				a.session.set_shared("score", 42)
				a.session.send_message(0, "chat", {"text": "hi"}, true)
				stage = "replicate"
		"replicate":
			var id_a: int = a.session.get_local_id()
			var pos: Vector2 = b["p%d" % id_a].position
			if pos.is_equal_approx(Vector2(100, 50)) and b.shared.get("score") == 42 and b.messages.size() == 1:
				print("message: ", b.messages[0])
				print("PASS")
				quit(0)
	return false
