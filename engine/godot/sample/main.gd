extends Node2D
## The Godot pane's sample, all drawn in code so the pack needs no imported
## assets. Drag anywhere to move the ring (it follows the finger by how far
## it moved, so a drag never jumps); tap to add a ball where the finger
## landed, which shows the touch mapping; arrow keys and WASD move the ring
## too. VERSION and BALL_COLOR are what a reload test edits; `taps` and the
## ring's place are the state script reload must keep. MODE_3D adds 400 lit
## cubes, for measuring a heavier scene.

const VERSION := "sample"
const MODE_3D := false
const BALL_COLOR := Color(0.6, 1.0, 0.4)

var taps := 0
var balls: Array[Dictionary] = []
var label: Label
var ring := Vector2(180, 360)
## Fingers down now, and how far each has moved since it went down.
var travel: Dictionary = {}
const TAP_SLOP := 12.0
const KEY_SPEED := 320.0

func _ready() -> void:
	label = Label.new()
	label.position = Vector2(16, 16)
	label.add_theme_font_size_override("font_size", 22)
	add_child(label)
	for i in 6:
		_spawn(Vector2(60 + i * 40, 120 + i * 30))
	if MODE_3D:
		_build_3d()
	print("sample ready ", VERSION)
	if "--probe" in OS.get_cmdline_user_args():
		Probe.run(self)

func _spawn(at: Vector2) -> void:
	balls.append({"p": at, "v": Vector2(randf_range(-220, 220), randf_range(-220, 220))})

func _process(delta: float) -> void:
	var size := get_viewport_rect().size
	for b in balls:
		b.p += b.v * delta
		if b.p.x < 16 or b.p.x > size.x - 16:
			b.v.x = -b.v.x
		if b.p.y < 16 or b.p.y > size.y - 16:
			b.v.y = -b.v.y
		b.p = b.p.clamp(Vector2(16, 16), size - Vector2(16, 16))
	var keys := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if Input.is_physical_key_pressed(KEY_A): keys.x -= 1
	if Input.is_physical_key_pressed(KEY_D): keys.x += 1
	if Input.is_physical_key_pressed(KEY_W): keys.y -= 1
	if Input.is_physical_key_pressed(KEY_S): keys.y += 1
	ring = (ring + keys.limit_length(1) * KEY_SPEED * delta).clamp(Vector2(24, 24), size - Vector2(24, 24))
	label.text = "%s  taps %d  balls %d  %d fps" % [VERSION, taps, balls.size(), Engine.get_frames_per_second()]
	queue_redraw()

func _draw() -> void:
	if not MODE_3D:
		draw_rect(get_viewport_rect(), Color(0.08, 0.1, 0.16))
	for b in balls:
		draw_circle(b.p, 16, BALL_COLOR)
	draw_arc(ring, 24, 0, TAU, 48, Color.WHITE, 4)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			travel[event.index] = 0.0
		elif travel.get(event.index, TAP_SLOP) < TAP_SLOP:
			taps += 1
			_spawn(event.position)
		if not event.pressed:
			travel.erase(event.index)
	elif event is InputEventScreenDrag:
		travel[event.index] = travel.get(event.index, 0.0) + event.relative.length()
		ring = (ring + event.relative).clamp(Vector2(24, 24), get_viewport_rect().size - Vector2(24, 24))
	elif event is InputEventKey and event.pressed and not event.echo:
		taps += 1
		print("key ", OS.get_keycode_string(event.keycode))

## The 3D footprint sample: 400 lit, spinning cubes.
var cubes: Node3D

func _build_3d() -> void:
	cubes = Node3D.new()
	add_child(cubes)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 0, 28)
	cubes.add_child(camera)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	light.shadow_enabled = true
	cubes.add_child(light)
	var mesh := BoxMesh.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = BALL_COLOR
	mesh.material = material
	for i in 400:
		var cube := MeshInstance3D.new()
		cube.mesh = mesh
		cube.position = Vector3((i % 20) - 9.5, (i / 20) - 9.5, randf_range(-6, 0)) * 1.4
		cubes.add_child(cube)

func _physics_process(delta: float) -> void:
	if cubes:
		for cube in cubes.get_children():
			if cube is MeshInstance3D:
				cube.rotate_y(delta * 1.5)
				cube.rotate_x(delta * 0.7)
