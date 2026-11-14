class_name Probe
## Sandbox probes, run with `-- --probe`: the log hook (print, warning,
## error, runtime error with backtrace) and the sandbox (files, network,
## DNS, microphone). Each line starts "probe <name>:" for the host to grep.

static func run(node: Node) -> void:
	print("probe print: hello from GDScript")
	push_warning("probe warning")
	push_error("probe push_error")
	_runtime_error()

	var f := FileAccess.open("/etc/hosts", FileAccess.READ)
	print("probe abs-read /etc/hosts: ", "OPEN" if f else "refused %d" % FileAccess.get_open_error())
	var exe := OS.get_executable_path()
	f = FileAccess.open(exe, FileAccess.READ)
	print("probe abs-read executable: ", "OPEN" if f else "refused %d" % FileAccess.get_open_error())
	var godot_user := OS.get_user_data_dir()
	var d := DirAccess.open(godot_user)
	print("probe list default user dir ", godot_user, ": ", "OPEN %s" % [d.get_files()] if d else "refused %d" % DirAccess.get_open_error())
	var container := godot_user.get_base_dir() + "/Library/Preferences"
	d = DirAccess.open(container)
	print("probe list container ", container, ": ", "OPEN %s" % [d.get_files()] if d else "refused %d" % DirAccess.get_open_error())

	f = FileAccess.open("user://probe.txt", FileAccess.WRITE)
	if f:
		f.store_string("hello")
		f.close()
	f = FileAccess.open("user://probe.txt", FileAccess.READ)
	print("probe user:// roundtrip: ", f.get_as_text() if f else "failed %d" % FileAccess.get_open_error())

	var tcp := StreamPeerTCP.new()
	print("probe tcp connect 1.1.1.1:80: ", error_string(tcp.connect_to_host("1.1.1.1", 80)))
	var udp := PacketPeerUDP.new()
	print("probe udp bind: ", error_string(udp.bind(0)))
	print("probe dns example.com: '", IP.resolve_hostname("example.com"), "'")

	print("probe mic enable_input: ", ProjectSettings.get_setting("audio/driver/enable_input"), " inputs ", AudioServer.get_input_device_list())
	_links(12)
	print("probe done")

# Last, so its refusal is the error the pane shows (GamePaneUITests): a link
# inside user:// to the app's container. Making one is refused, and listing
# through one made by anything else (the debug harness plants one) is too.
# Run a dozen calls deep, so the error carries a long backtrace.
static func _links(depth: int) -> void:
	if depth > 0:
		_links(depth - 1)
		return
	var user_dir := DirAccess.open("user://")
	print("probe symlink: ", error_string(user_dir.create_link("../../../../..", "user://escape")) if user_dir else "no user dir")
	var d := DirAccess.open("user://escape/Library")
	print("probe list through link: ", "OPEN %s" % [d.get_directories()] if d else "refused %d" % DirAccess.get_open_error())

static func _runtime_error() -> void:
	var nothing: Variant = null
	nothing.call("explode")
