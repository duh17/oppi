// OppiGodot: the whole surface Oppi's thin host uses to run one Godot game
// inside a UIKit view. Everything runs on the main thread unless noted.
//
// One engine at a time: oppigodot_stop ends it, and oppigodot_start may make
// the next one, on any game (patch 0005 resets what stock Godot 4.7 keeps in
// statics). A new build of the running game swaps packs inside it
// (oppigodot_swap_pack); another game, or a change to project settings or
// autoloads, stops the engine and starts it again.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
	OPPIGODOT_LOG_PRINT = 0, // print() and engine info lines
	OPPIGODOT_LOG_ERROR = 1,
	OPPIGODOT_LOG_WARNING = 2,
	OPPIGODOT_LOG_SCRIPT = 3, // runtime script error
	OPPIGODOT_LOG_SHADER = 4,
} OppiGodotLogKind;

typedef struct {
	OppiGodotLogKind kind;
	const char *message;
	// Where the error was raised. For script errors this is the script
	// (res://...); for push_error it is the engine's own source, and the
	// script location is the first backtrace frame.
	const char *file;
	int32_t line;
	const char *function;
	// First script frame, when the error carried a script backtrace.
	const char *script_file;
	int32_t script_line;
	const char *script_function;
	// The full formatted backtrace, or "".
	const char *backtrace;
} OppiGodotLogEntry;

// Called on whichever thread logged; strings live only for the call.
typedef void (*OppiGodotLogCallback)(const OppiGodotLogEntry *entry, void *context);
void oppigodot_set_log_callback(OppiGodotLogCallback callback, void *context);

typedef struct {
	const char *pack_path; // the base pack (PCK or ZIP)
	const char *user_dir; // user:// for this project; created if missing
	// The engine's own cache, shared by every game (the shader cache lives
	// in its shader_cache folder); created if missing. NULL: no shader cache.
	const char *cache_dir;
	const char *const *extra_args; // passed to Godot after the pack, may be NULL
	int32_t extra_arg_count;
	// Folders outside user_dir and cache_dir the game may read but never
	// write (fonts, the folder holding the packs).
	const char *const *readable_dirs;
	int32_t readable_dir_count;
	bool allow_network; // false: sockets and DNS refuse
} OppiGodotConfig;

// The container layer the engine draws into: it adds its own rendering
// sublayer at the top left, at the size `oppigodot_resize` last gave (the
// container's bounds until then). Set before start; it stays retained
// until stop.
void oppigodot_set_layer(void *container_layer);

// The size the game draws at, in points, and its scale: the one size its
// layer, drawable and window take, also across a stop and start. Call
// before start and on every settled size change.
void oppigodot_resize(double width, double height, double scale);

bool oppigodot_start(const OppiGodotConfig *config);
// One engine frame. Returns false once the game asked to quit.
bool oppigodot_iterate(void);
void oppigodot_stop(void);
bool oppigodot_is_running(void);
void oppigodot_pause(void);
void oppigodot_resume(void);
// Focus out also releases held keys and ignores controllers until focus
// comes back, so a controller drives the game only while its pane has focus.
void oppigodot_focus(bool focused);
// Silences the master bus; the engine keeps running.
void oppigodot_set_muted(bool muted);

// Mounts a pack over the running game; replace_files lets it shadow files
// from earlier packs.
bool oppigodot_mount_pack(const char *path, bool replace_files);

// Reloads the named scripts (res:// paths) from the mounted packs, keeping
// instance state. NULL or count 0 reloads every loaded script. Returns the
// number reloaded, or -1 when the engine has no script reload (release builds).
int32_t oppigodot_reload_scripts(const char *const *paths, int32_t count);
// The in-engine pack swap: mounts the pack over the running game, reloads
// scripts, and changes to `scene` (NULL: the project's main scene) loaded
// past the cache. Project settings and autoloads keep the first pack's values.
bool oppigodot_swap_pack(const char *path, const char *scene);

// Reloads the current scene from the mounted packs. While a scene change is
// pending (a paused game runs no frame to finish a swap or a reload), it
// reloads the scene that change asked for.
bool oppigodot_reload_scene(void);

typedef enum {
	OPPIGODOT_TOUCH_BEGAN = 0,
	OPPIGODOT_TOUCH_MOVED = 1,
	OPPIGODOT_TOUCH_ENDED = 2,
	OPPIGODOT_TOUCH_CANCELLED = 3,
} OppiGodotTouchPhase;

// Positions in points inside the container; the engine scales them to the
// viewport's pixels. `index` is the finger, stable from began to ended.
void oppigodot_touch(int32_t index, OppiGodotTouchPhase phase, double x, double y, double previous_x, double previous_y, float pressure, bool double_tap);

// A hardware key: the UIKey's HID usage (keyCode), its characters, its
// characters ignoring modifiers, and modifierFlags.
void oppigodot_key(int64_t hid_usage, const char *characters, const char *characters_ignoring_modifiers, int64_t modifier_flags, bool pressed);

// A key by Godot's name for it ("Space", "Enter", "Left", "A", "F1"), as
// agents and tests send input. False for a name Godot does not know.
bool oppigodot_key_named(const char *name, bool pressed);

// An input action the project defines, pressed with `strength` (0..1) or
// released. False when the project has no such action.
bool oppigodot_action(const char *name, bool pressed, float strength);

// The current frame of the root viewport as PNG: its length, with the bytes
// in *out_png for the caller to release with oppigodot_free; 0 on failure.
size_t oppigodot_capture_png(uint8_t **out_png);
void oppigodot_free(void *pointer);

// The current scene's file (res://…) as a NUL-terminated UTF-8 string for
// the caller to release with oppigodot_free; NULL while no game runs or its
// current scene was not loaded from a file.
char *oppigodot_current_scene(void);

typedef struct {
	double fps;
	double process_ms;
	double physics_ms;
	int64_t draw_calls;
	int64_t nodes;
	int64_t static_memory_bytes;
	int64_t frames_drawn;
} OppiGodotPerf;
void oppigodot_perf(OppiGodotPerf *out);

#ifdef __cplusplus
}
#endif
