// OppiGodot: the flat C API behind OppiGodot.h, plus the sandbox and log
// hooks. Lives inside the engine as a module so it can call engine C++
// directly; nothing here is visible to game scripts.

#include "OppiGodot.h"

#include "register_types.h"

#include "core/config/engine.h"
#include "core/config/project_settings.h"
#include "core/extension/godot_instance.h"
#include "core/extension/libgodot.h"
#include "core/input/input.h"
#include "core/input/input_map.h"
#include "core/io/image.h"
#include "core/io/logger.h"
#include "core/io/resource_loader.h"
#include "core/object/script_backtrace.h"
#include "core/object/script_language.h"
#include "core/os/keyboard.h"
#include "drivers/apple_embedded/display_server_apple_embedded.h"
#include "drivers/apple_embedded/key_mapping_apple_embedded.h"
#include "drivers/apple_embedded/os_apple_embedded.h"
#include "drivers/coreaudio/audio_driver_coreaudio.h"
#include "drivers/unix/dir_access_unix.h"
#include "drivers/unix/file_access_unix.h"
#include "drivers/unix/net_socket_unix.h"
#include "main/performance.h"
#include "scene/main/scene_tree.h"
#include "scene/main/window.h"
#include "scene/resources/packed_scene.h"
#include "servers/audio/audio_server.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <stdlib.h>

// MARK: - State

static GodotInstance *instance = nullptr;
static CALayer *container_layer = nil;
static void *rendering_layer = nullptr; // +1 retained CALayer from libgodot
static double view_width = 0, view_height = 0, view_scale = 1;
static bool muted = false;
// The scene the host last asked for (a swap or a reload). Until the next
// frame it is only pending: the tree has no current scene then.
static String requested_scene;

static OppiGodotLogCallback log_callback = nullptr;
static void *log_context = nullptr;

// Sandbox configuration for the running game, read by the hooks below. Every
// path is resolved (realpath), so /var and /private/var name one folder.
static Vector<String> sandbox_writable; // user:// and the engine's cache
static Vector<String> sandbox_readable; // the packs' folder, fonts
static String sandbox_cache_dir;
static bool sandbox_configured = false;
static bool sandbox_network = false;

// The real path of `p_path`, or the path itself when it does not exist yet.
static String resolved_path(const char *p_path) {
	if (!p_path || !p_path[0]) {
		return String();
	}
	char buffer[PATH_MAX];
	const char *real = realpath(p_path, buffer);
	return String::utf8(real ? real : p_path).simplify_path();
}

static void make_folder(const String &p_path) {
	if (p_path.is_empty()) {
		return;
	}
	NSString *path = [NSString stringWithUTF8String:p_path.utf8().get_data()];
	[[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
}

// MARK: - Logging

class OppiLogger : public Logger {
	static void emit(const OppiGodotLogEntry &p_entry) {
		if (log_callback) {
			log_callback(&p_entry, log_context);
		}
	}

public:
	void logv(const char *p_format, va_list p_list, bool p_err) override {
		if (!log_callback || !should_log(p_err)) {
			return;
		}
		char buffer[2048];
		vsnprintf(buffer, sizeof(buffer), p_format, p_list);
		size_t length = strlen(buffer);
		while (length > 0 && buffer[length - 1] == '\n') {
			buffer[--length] = 0;
		}
		OppiGodotLogEntry entry = {};
		entry.kind = p_err ? OPPIGODOT_LOG_ERROR : OPPIGODOT_LOG_PRINT;
		entry.message = buffer;
		entry.file = entry.function = entry.script_file = entry.script_function = entry.backtrace = "";
		emit(entry);
	}

	void log_error(const char *p_function, const char *p_file, int p_line, const char *p_code, const char *p_rationale, bool p_editor_notify, ErrorType p_type, const Vector<Ref<ScriptBacktrace>> &p_script_backtraces) override {
		if (!log_callback || !should_log(true)) {
			return;
		}
		OppiGodotLogEntry entry = {};
		switch (p_type) {
			case ERR_WARNING:
				entry.kind = OPPIGODOT_LOG_WARNING;
				break;
			case ERR_SCRIPT:
				entry.kind = OPPIGODOT_LOG_SCRIPT;
				break;
			case ERR_SHADER:
				entry.kind = OPPIGODOT_LOG_SHADER;
				break;
			default:
				entry.kind = OPPIGODOT_LOG_ERROR;
		}
		entry.message = (p_rationale && p_rationale[0]) ? p_rationale : p_code;
		entry.file = p_file ? p_file : "";
		entry.line = p_line;
		entry.function = p_function ? p_function : "";

		CharString script_file, script_function, backtrace;
		String formatted;
		for (const Ref<ScriptBacktrace> &bt : p_script_backtraces) {
			if (bt.is_null() || bt->is_empty()) {
				continue;
			}
			if (script_file.length() == 0 && bt->get_frame_count() > 0) {
				script_file = bt->get_frame_file(0).utf8();
				script_function = bt->get_frame_function(0).utf8();
				entry.script_line = bt->get_frame_line(0);
			}
			formatted += bt->format();
		}
		backtrace = formatted.utf8();
		entry.script_file = script_file.get_data() ? script_file.get_data() : "";
		entry.script_function = script_function.get_data() ? script_function.get_data() : "";
		entry.backtrace = backtrace.get_data() ? backtrace.get_data() : "";
		emit(entry);
	}
};

// MARK: - Sandbox

// user:// is the game's own folder (libgodot_ios_set_user_data_dir). The
// hooks below refuse paths outside the allow lists: reads outside
// user://, the engine's cache, the packs' folder and fonts, and writes
// outside user:// and the cache. res:// comes from the packs (PackedData);
// only what falls through to the file system meets these hooks.
static bool path_within(const String &p_path, const Vector<String> &p_dirs) {
	for (const String &dir : p_dirs) {
		if (p_path == dir || p_path.begins_with(dir + "/")) {
			return true;
		}
	}
	return false;
}

// Where an absolute path really leads: its deepest existing ancestor resolved
// by the system (symlinks and ".." included), with the part that does not
// exist yet appended. Comparing text alone would let a link inside an
// allowed folder lead out of it.
static String real_path(const String &p_absolute) {
	String head = p_absolute;
	String rest;
	while (!head.is_empty()) {
		char buffer[PATH_MAX];
		if (realpath(head.utf8().get_data(), buffer)) {
			String real = String::utf8(buffer);
			return (rest.is_empty() ? real : real.path_join(rest)).simplify_path();
		}
		if (head == "/") {
			break;
		}
		rest = rest.is_empty() ? head.get_file() : head.get_file().path_join(rest);
		head = head.get_base_dir();
	}
	return p_absolute.simplify_path();
}

static bool sandbox_allows(const String &p_absolute, bool p_write) {
	if (!sandbox_configured) {
		return true; // engine startup before start() configured it
	}
	if (!p_absolute.is_absolute_path()) {
		return false;
	}
	String path = real_path(p_absolute);
	if (path_within(path, sandbox_writable)) {
		return true;
	}
	return !p_write && path_within(path, sandbox_readable);
}

class FileAccessOppi : public FileAccessUnix {
	GDSOFTCLASS(FileAccessOppi, FileAccessUnix);

	bool refuses(const String &p_path, bool p_write, const char *p_what) const {
		if (sandbox_allows(fix_path(p_path), p_write)) {
			return false;
		}
		// res:// reads that miss the packs fall through to the app bundle;
		// refuse those quietly, as a file the pack does not have.
		if (get_access_type() != ACCESS_RESOURCES || p_write) {
			ERR_PRINT(vformat("Sandbox refused %s: %s", p_what, p_path));
		}
		return true;
	}

	// Existence and attribute probes outside the allow list answer as for a
	// file that is not there, without a log line each.
	bool hidden(const String &p_path) const {
		return !sandbox_allows(fix_path(p_path), false);
	}

public:
	bool file_exists(const String &p_path) override {
		return !hidden(p_path) && FileAccessUnix::file_exists(p_path);
	}

	uint64_t _get_modified_time(const String &p_file) override {
		return hidden(p_file) ? 0 : FileAccessUnix::_get_modified_time(p_file);
	}

	uint64_t _get_access_time(const String &p_file) override {
		return hidden(p_file) ? 0 : FileAccessUnix::_get_access_time(p_file);
	}

	int64_t _get_size(const String &p_file) override {
		return hidden(p_file) ? -1 : FileAccessUnix::_get_size(p_file);
	}

	BitField<FileAccess::UnixPermissionFlags> _get_unix_permissions(const String &p_file) override {
		return hidden(p_file) ? BitField<FileAccess::UnixPermissionFlags>() : FileAccessUnix::_get_unix_permissions(p_file);
	}

	bool _get_hidden_attribute(const String &p_file) override {
		return !hidden(p_file) && FileAccessUnix::_get_hidden_attribute(p_file);
	}

	bool _get_read_only_attribute(const String &p_file) override {
		return !hidden(p_file) && FileAccessUnix::_get_read_only_attribute(p_file);
	}

	PackedByteArray _get_extended_attribute(const String &p_file, const String &p_attribute_name) override {
		return hidden(p_file) ? PackedByteArray() : FileAccessUnix::_get_extended_attribute(p_file, p_attribute_name);
	}

	PackedStringArray _get_extended_attributes_list(const String &p_file) override {
		return hidden(p_file) ? PackedStringArray() : FileAccessUnix::_get_extended_attributes_list(p_file);
	}

	Error open_internal(const String &p_path, int p_mode_flags) override {
		if (refuses(p_path, p_mode_flags != READ, "file access")) {
			return ERR_FILE_NO_PERMISSION;
		}
		return FileAccessUnix::open_internal(p_path, p_mode_flags);
	}

	Error _set_unix_permissions(const String &p_file, BitField<FileAccess::UnixPermissionFlags> p_permissions) override {
		return refuses(p_file, true, "permission change") ? ERR_FILE_NO_PERMISSION : FileAccessUnix::_set_unix_permissions(p_file, p_permissions);
	}

	Error _set_hidden_attribute(const String &p_file, bool p_hidden) override {
		return refuses(p_file, true, "attribute change") ? ERR_FILE_NO_PERMISSION : FileAccessUnix::_set_hidden_attribute(p_file, p_hidden);
	}

	Error _set_read_only_attribute(const String &p_file, bool p_ro) override {
		return refuses(p_file, true, "attribute change") ? ERR_FILE_NO_PERMISSION : FileAccessUnix::_set_read_only_attribute(p_file, p_ro);
	}

	Error _set_extended_attribute(const String &p_file, const String &p_attribute_name, const PackedByteArray &p_data) override {
		return refuses(p_file, true, "attribute change") ? ERR_FILE_NO_PERMISSION : FileAccessUnix::_set_extended_attribute(p_file, p_attribute_name, p_data);
	}

	Error _remove_extended_attribute(const String &p_file, const String &p_attribute_name) override {
		return refuses(p_file, true, "attribute change") ? ERR_FILE_NO_PERMISSION : FileAccessUnix::_remove_extended_attribute(p_file, p_attribute_name);
	}

	static void install() {
		make_default<FileAccessOppi>(ACCESS_RESOURCES);
		make_default<FileAccessOppi>(ACCESS_USERDATA);
		make_default<FileAccessOppi>(ACCESS_FILESYSTEM);
	}
};

class DirAccessOppi : public DirAccessUnix {
	GDSOFTCLASS(DirAccessOppi, DirAccessUnix);

	String absolute(const String &p_path) const {
		return fix_path(p_path.is_relative_path() ? get_current_dir().path_join(p_path) : p_path);
	}

	bool refuses(const String &p_path, bool p_write, const char *p_what) const {
		if (sandbox_allows(absolute(p_path), p_write)) {
			return false;
		}
		if (get_access_type() != ACCESS_RESOURCES || p_write) {
			ERR_PRINT(vformat("Sandbox refused %s: %s", p_what, p_path));
		}
		return true;
	}

	// Probes outside the allow list answer as for nothing there, quietly.
	bool hidden(const String &p_path) const {
		return !sandbox_allows(absolute(p_path), false);
	}

public:
	bool file_exists(String p_file) override {
		return !hidden(p_file) && DirAccessUnix::file_exists(p_file);
	}

	bool dir_exists(String p_dir) override {
		return !hidden(p_dir) && DirAccessUnix::dir_exists(p_dir);
	}

	bool is_readable(String p_dir) override {
		return !hidden(p_dir) && DirAccessUnix::is_readable(p_dir);
	}

	bool is_writable(String p_dir) override {
		return sandbox_allows(absolute(p_dir), true) && DirAccessUnix::is_writable(p_dir);
	}

	uint64_t get_modified_time(String p_file) override {
		return hidden(p_file) ? 0 : DirAccessUnix::get_modified_time(p_file);
	}

	bool is_link(String p_file) override {
		return !hidden(p_file) && DirAccessUnix::is_link(p_file);
	}

	String read_link(String p_file) override {
		return hidden(p_file) ? String() : DirAccessUnix::read_link(p_file);
	}

	// Opening a folder outside the allow list fails, not only listing it.
	Error change_dir(String p_dir) override {
		if (refuses(p_dir, false, "folder access")) {
			return ERR_FILE_NO_PERMISSION;
		}
		return DirAccessUnix::change_dir(p_dir);
	}

	Error list_dir_begin() override {
		if (refuses(get_current_dir(), false, "directory listing")) {
			return ERR_FILE_NO_PERMISSION;
		}
		return DirAccessUnix::list_dir_begin();
	}

	Error make_dir(String p_dir) override {
		return refuses(p_dir, true, "new folder") ? ERR_FILE_NO_PERMISSION : DirAccessUnix::make_dir(p_dir);
	}

	Error rename(String p_path, String p_new_path) override {
		if (refuses(p_path, true, "rename") || refuses(p_new_path, true, "rename")) {
			return ERR_FILE_NO_PERMISSION;
		}
		return DirAccessUnix::rename(p_path, p_new_path);
	}

	Error remove(String p_path) override {
		return refuses(p_path, true, "removal") ? ERR_FILE_NO_PERMISSION : DirAccessUnix::remove(p_path);
	}

	// A game makes no links: one inside its own folder could lead anywhere.
	Error create_link(String p_source, String p_target) override {
		ERR_PRINT(vformat("Sandbox refused a link: %s", p_target));
		return ERR_FILE_NO_PERMISSION;
	}

	static void install() {
		make_default<DirAccessOppi>(ACCESS_RESOURCES);
		make_default<DirAccessOppi>(ACCESS_USERDATA);
		make_default<DirAccessOppi>(ACCESS_FILESYSTEM);
	}
};

class NetSocketOppi : public NetSocketUnix {
	GDSOFTCLASS(NetSocketOppi, NetSocketUnix);

	static Ref<NetSocket> _create_oppi() {
		Ref<NetSocketOppi> socket;
		socket.instantiate();
		return socket;
	}

public:
	Error open(Family p_family, Type p_type, IP::Type &r_ip_type) override {
		if (!sandbox_network) {
			ERR_PRINT("Sandbox refused a socket: network is off for this game.");
			return ERR_UNAUTHORIZED;
		}
		return NetSocketUnix::open(p_family, p_type, r_ip_type);
	}

	static void install() { _create = _create_oppi; }
};

// Stands in for the core IP singleton (IPUnix, whose resolver is private):
// refuses lookups unless the game may use the network, else asks the
// singleton it replaced.
class IPOppi : public IP {
	GDSOFTCLASS(IPOppi, IP);

	static inline IP *replaced = nullptr;
	static inline IPOppi *current = nullptr;

	void _resolve_hostname(List<IPAddress> &r_addresses, const String &p_hostname, Type p_type) const override {
		if (!sandbox_network) {
			ERR_PRINT(vformat("Sandbox refused DNS lookup: %s", p_hostname));
			return;
		}
		for (const String &address : replaced->resolve_hostname_addresses(p_hostname, p_type)) {
			r_addresses.push_back(IPAddress(address));
		}
	}

public:
	void get_local_interfaces(HashMap<String, Interface_Info> *r_interfaces) const override {
		replaced->get_local_interfaces(r_interfaces);
	}

	// The core singleton exists before modules load; stand in for it until
	// the module unloads, then hand it back for core to delete.
	static void install() {
		replaced = singleton;
		current = memnew(IPOppi);
	}

	static void uninstall() {
		if (current) {
			memdelete(current);
			current = nullptr;
			singleton = replaced;
		}
	}
};

// MARK: - Module registration

// Core modules initialise after the project's settings load and before
// setup2 makes the servers, so the overrides here win over the project's.
void initialize_oppigodot_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_CORE) {
		return;
	}
	FileAccessOppi::install();
	DirAccessOppi::install();
	NetSocketOppi::install();
	IPOppi::install();

	ProjectSettings *settings = ProjectSettings::get_singleton();
	// No microphone, whatever the project asks for: the app owns it.
	settings->set_setting("audio/driver/enable_input", false);
	// A controller drives the game only while its pane has focus.
	settings->set_setting("input_devices/joypads/ignore_joypad_on_unfocused_application", true);
	// The shader cache goes to the engine's own folder, outside the game's
	// user://, so one game's compiled shaders serve every later launch.
	if (!sandbox_cache_dir.is_empty()) {
		Engine::get_singleton()->set_shader_cache_path(sandbox_cache_dir);
	}
}

void uninitialize_oppigodot_module(ModuleInitializationLevel p_level) {
	if (p_level == MODULE_INITIALIZATION_LEVEL_CORE) {
		IPOppi::uninstall();
	}
}

// Runs before setup reads the project, so setup's own errors reach the host.
static void add_host_logger() {
	OS::get_singleton()->add_logger(memnew(OppiLogger));
}

// MARK: - Host init (libgodot wants a GDExtension entry; the host adds none)

static void host_init_level(void *, GDExtensionInitializationLevel) {}

static GDExtensionBool host_init(GDExtensionInterfaceGetProcAddress, GDExtensionClassLibraryPtr, GDExtensionInitialization *r_init) {
	r_init->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
	r_init->userdata = nullptr;
	r_init->initialize = host_init_level;
	r_init->deinitialize = host_init_level;
	return true;
}

// MARK: - C API

// The host's size (oppigodot_resize) is the one size the game draws at: its
// layer's frame, the drawable and the display server's window all follow it.
// The container may be larger or smaller for a while (a divider drag, where
// the host stretches this layer to it); a game started then still draws at
// the host's size, which that stretch expects. Before the host gives a size,
// the container's bounds.
static CGRect rendering_frame() {
	if (view_width > 0 && view_height > 0) {
		return CGRectMake(0, 0, view_width, view_height);
	}
	return container_layer.bounds;
}

static void layout_rendering_layer() {
	if (!rendering_layer || !container_layer) {
		return;
	}
	CALayer *layer = (__bridge CALayer *)rendering_layer;
	CGRect frame = rendering_frame();
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	layer.frame = frame;
	layer.contentsScale = view_scale;
	if ([layer isKindOfClass:[CAMetalLayer class]]) {
		((CAMetalLayer *)layer).drawableSize = CGSizeMake(frame.size.width * view_scale, frame.size.height * view_scale);
	}
	[CATransaction commit];
	libgodot_ios_layout_rendering_layer(rendering_layer);
}

static void apply_mute() {
	AudioServer *audio = AudioServer::get_singleton();
	if (instance && audio && audio->get_bus_count() > 0) {
		audio->set_bus_mute(0, muted);
	}
}

extern "C" {

void oppigodot_set_log_callback(OppiGodotLogCallback callback, void *context) {
	log_callback = callback;
	log_context = context;
}

void oppigodot_set_layer(void *p_container_layer) {
	container_layer = (__bridge CALayer *)p_container_layer;
}

void oppigodot_resize(double width, double height, double scale) {
	view_width = width;
	view_height = height;
	view_scale = scale > 0 ? scale : 1;
	if (!instance) {
		return;
	}
	layout_rendering_layer();
	if (DisplayServerAppleEmbedded::get_singleton()) {
		DisplayServerAppleEmbedded::get_singleton()->resize_window(CGSizeMake(width, height));
	}
}

bool oppigodot_start(const OppiGodotConfig *config) {
	ERR_FAIL_COND_V_MSG(instance != nullptr, false, "A game is already running.");
	ERR_FAIL_NULL_V(config, false);
	ERR_FAIL_NULL_V(config->pack_path, false);
	ERR_FAIL_COND_V_MSG(container_layer == nil, false, "Set the container layer before start.");

	// Folders first, so each resolves to its real path.
	// The game's own folder is what the sandbox allows: no folder, no game.
	ERR_FAIL_COND_V_MSG(!config->user_dir || !config->user_dir[0], false, "A game needs its own user:// folder.");
	String user_dir = resolved_path(config->user_dir);
	make_folder(user_dir);
	user_dir = resolved_path(config->user_dir);
	String cache_dir;
	if (config->cache_dir && config->cache_dir[0]) {
		// Godot looks for shader_cache inside it and makes it only through
		// DirAccess; made here, the first launch caches too.
		make_folder(resolved_path(config->cache_dir).path_join("shader_cache"));
		cache_dir = resolved_path(config->cache_dir);
	}
	String pack_path = resolved_path(config->pack_path);

	// Arguments: Godot reads argv[1...]. The pack is the only project source.
	Vector<CharString> args;
	args.push_back(CharString("oppi"));
	args.push_back(CharString("--main-pack"));
	args.push_back(pack_path.utf8());
	for (int i = 0; i < config->extra_arg_count; i++) {
		args.push_back(String::utf8(config->extra_args[i]).utf8());
	}
	Vector<char *> argv;
	for (CharString &arg : args) {
		argv.push_back(arg.ptrw());
	}
	argv.push_back(nullptr);

	// The sandbox hooks and the core module read these inside setup.
	sandbox_writable.clear();
	sandbox_readable.clear();
	if (!user_dir.is_empty()) {
		sandbox_writable.push_back(user_dir);
	}
	if (!cache_dir.is_empty()) {
		sandbox_writable.push_back(cache_dir);
	}
	sandbox_readable.push_back(pack_path.get_base_dir());
	for (int i = 0; i < config->readable_dir_count; i++) {
		String dir = resolved_path(config->readable_dirs[i]);
		if (!dir.is_empty()) {
			sandbox_readable.push_back(dir);
		}
	}
	sandbox_cache_dir = cache_dir;
	sandbox_network = config->allow_network;
	sandbox_configured = true;

	libgodot_ios_set_os_created_callback(add_host_logger);
	CharString user_dir_utf8 = user_dir.utf8();
	libgodot_ios_set_user_data_dir(user_dir_utf8.get_data());
	instance = (GodotInstance *)libgodot_create_godot_instance(args.size(), argv.ptrw(), host_init);
	if (!instance) {
		return false;
	}

	String driver = OS::get_singleton()->get_current_rendering_driver_name();
	rendering_layer = libgodot_ios_create_rendering_layer(driver.utf8().get_data());
	if (!rendering_layer) {
		ERR_PRINT(vformat("No rendering layer for driver %s.", driver));
		libgodot_destroy_godot_instance((GDExtensionObjectPtr)instance);
		instance = nullptr;
		return false;
	}
	CALayer *layer = (__bridge CALayer *)rendering_layer;
	layer.frame = rendering_frame();
	layer.contentsScale = view_scale;
	[container_layer addSublayer:layer];
	libgodot_ios_initialize_rendering_layer(rendering_layer);
	layout_rendering_layer();
	DisplayServerAppleEmbedded::set_host_layer(rendering_layer);

	if (!instance->start()) {
		oppigodot_stop();
		return false;
	}
	apply_mute();
	return true;
}

bool oppigodot_iterate(void) {
	if (!instance || !instance->is_started()) {
		return false;
	}
	libgodot_ios_start_rendering_layer(rendering_layer);
	// The OS's iterate also pumps SDL joypads, which GodotInstance skips.
	bool quit = OS_AppleEmbedded::get_singleton()->iterate();
	libgodot_ios_stop_rendering_layer(rendering_layer);
	// A script's AudioServer.set_bus_mute(0, false) never outlasts the
	// host's mute (the person's, or a microphone in use).
	AudioServer *audio = AudioServer::get_singleton();
	if (muted && audio && audio->get_bus_count() > 0 && !audio->is_bus_mute(0)) {
		audio->set_bus_mute(0, true);
	}
	return !quit;
}

void oppigodot_stop(void) {
	if (instance) {
		libgodot_destroy_godot_instance((GDExtensionObjectPtr)instance);
		instance = nullptr;
	}
	DisplayServerAppleEmbedded::set_host_layer(nullptr);
	if (rendering_layer) {
		CALayer *layer = (__bridge_transfer CALayer *)rendering_layer;
		[layer removeFromSuperlayer];
		rendering_layer = nullptr;
	}
	sandbox_writable.clear();
	sandbox_readable.clear();
	sandbox_configured = false;
	requested_scene = String();
}

bool oppigodot_is_running(void) {
	return instance != nullptr && instance->is_started();
}

// The audio output stops with the game, as Godot's own app stops it when it
// loses focus; the output unit keeps playing its buffers otherwise.
static AudioDriverCoreAudio *core_audio() {
	AudioDriver *driver = AudioDriver::get_singleton();
	return driver && String(driver->get_name()) == "CoreAudio" ? static_cast<AudioDriverCoreAudio *>(driver) : nullptr;
}

void oppigodot_pause(void) {
	if (instance) {
		instance->pause();
		if (AudioDriverCoreAudio *audio = core_audio()) {
			audio->stop();
		}
	}
}

void oppigodot_resume(void) {
	if (instance) {
		if (AudioDriverCoreAudio *audio = core_audio()) {
			audio->start();
		}
		instance->resume();
	}
}

void oppigodot_focus(bool focused) {
	if (!instance) {
		return;
	}
	if (focused) {
		instance->focus_in();
	} else {
		instance->focus_out();
	}
}

void oppigodot_set_muted(bool p_muted) {
	muted = p_muted;
	apply_mute();
}

bool oppigodot_mount_pack(const char *path, bool replace_files) {
	ERR_FAIL_COND_V(!instance, false);
	// load_resource_pack is protected in C++; the scripting binding is the public door.
	return ProjectSettings::get_singleton()->call("load_resource_pack", resolved_path(path), replace_files, 0);
}

int32_t oppigodot_reload_scripts(const char *const *paths, int32_t count) {
	ERR_FAIL_COND_V(!instance, -1);
#ifdef DEBUG_ENABLED
	Array scripts;
	if (paths && count > 0) {
		for (int i = 0; i < count; i++) {
			String path = String::utf8(paths[i]);
			Ref<Script> script = ResourceCache::get_ref(path);
			if (script.is_valid()) {
				scripts.push_back(script);
			}
		}
	} else {
		List<Ref<Resource>> cached;
		ResourceCache::get_cached_resources(&cached);
		for (const Ref<Resource> &resource : cached) {
			Ref<Script> script = resource;
			if (script.is_valid() && script->get_path().is_resource_file()) {
				scripts.push_back(script);
			}
		}
	}
	for (int i = 0; i < ScriptServer::get_language_count(); i++) {
		ScriptServer::get_language(i)->reload_scripts(scripts, true);
	}
	return scripts.size();
#else
	return -1;
#endif
}

bool oppigodot_swap_pack(const char *path, const char *scene) {
	ERR_FAIL_COND_V(!instance, false);
	if (!oppigodot_mount_pack(path, true)) {
		return false;
	}
	// Scripts first, keeping the instances that survive; then the scene,
	// loaded past the cache so changed scenes and resources come from the
	// new pack. Project settings and autoloads keep the first pack's values.
	oppigodot_reload_scripts(nullptr, 0);
	String scene_path = (scene && scene[0]) ? String::utf8(scene) : String(GLOBAL_GET("application/run/main_scene"));
	Ref<PackedScene> packed = ResourceLoader::load(scene_path, "PackedScene", ResourceFormatLoader::CACHE_MODE_REPLACE_DEEP);
	ERR_FAIL_COND_V_MSG(packed.is_null(), false, vformat("Cannot load %s from the new pack.", scene_path));
	if (SceneTree::get_singleton()->change_scene_to_packed(packed) != OK) {
		return false;
	}
	requested_scene = scene_path;
	return true;
}

bool oppigodot_reload_scene(void) {
	ERR_FAIL_COND_V(!instance, false);
	SceneTree *tree = SceneTree::get_singleton();
	ERR_FAIL_NULL_V(tree, false);
	// A scene change (a swap, an earlier reload) leaves no current scene
	// until the next frame runs, and a paused game runs none: reload the
	// scene that change asked for. SceneTree::reload_current_scene would
	// fail there. Else the current scene's file, else the main scene.
	Node *current = tree->get_current_scene();
	String path = current ? current->get_scene_file_path() : requested_scene;
	if (path.is_empty()) {
		path = GLOBAL_GET("application/run/main_scene");
	}
	if (tree->change_scene_to_file(path) != OK) {
		return false;
	}
	requested_scene = path;
	return true;
}

void oppigodot_touch(int32_t index, OppiGodotTouchPhase phase, double x, double y, double previous_x, double previous_y, float pressure, bool double_tap) {
	DisplayServerAppleEmbedded *ds = DisplayServerAppleEmbedded::get_singleton();
	if (!instance || !ds) {
		return;
	}
	// The window's pixels are the layer's points at the screen's scale
	// (window_get_size), which is the scale the host resizes with.
	const double s = view_scale;
	switch (phase) {
		case OPPIGODOT_TOUCH_BEGAN:
			ds->touch_press(index, x * s, y * s, true, double_tap);
			break;
		case OPPIGODOT_TOUCH_MOVED:
			ds->touch_drag(index, previous_x * s, previous_y * s, x * s, y * s, pressure, Vector2());
			break;
		case OPPIGODOT_TOUCH_ENDED:
			ds->touch_press(index, x * s, y * s, false, false);
			break;
		case OPPIGODOT_TOUCH_CANCELLED:
			ds->touches_canceled(index);
			break;
	}
}

void oppigodot_key(int64_t hid_usage, const char *characters, const char *characters_ignoring_modifiers, int64_t modifier_flags, bool pressed) {
	DisplayServerAppleEmbedded *ds = DisplayServerAppleEmbedded::get_singleton();
	if (!instance || !ds) {
		return;
	}
	// Mirrors GDTViewController's pressesBegan/pressesEnded.
	String text = characters ? String::utf8(characters) : String();
	String label = characters_ignoring_modifiers ? String::utf8(characters_ignoring_modifiers) : String();
	Key key = KeyMappingAppleEmbedded::remap_key(hid_usage);
	if (hid_usage == 0 && text.is_empty() && label.is_empty()) {
		return;
	}
	char32_t unshifted = 0;
	if (!label.is_empty() && !label.begins_with("UIKey")) {
		unshifted = label[0];
	}
	KeyLocation location = KeyMappingAppleEmbedded::key_location(hid_usage);
	if (pressed && !text.is_empty() && !text.begins_with("UIKey")) {
		for (int i = 0; i < text.length(); i++) {
			ds->key(fix_keycode(unshifted, key), text[i], fix_key_label(unshifted, key), key, modifier_flags, true, location);
		}
	} else {
		ds->key(fix_keycode(unshifted, key), 0, fix_key_label(unshifted, key), key, modifier_flags, pressed, location);
	}
}

bool oppigodot_key_named(const char *name, bool pressed) {
	ERR_FAIL_COND_V(!instance || !name, false);
	Key key = find_keycode(String::utf8(name));
	if (key == Key::NONE) {
		return false;
	}
	Ref<InputEventKey> event;
	event.instantiate();
	event->set_keycode(key);
	event->set_physical_keycode(key);
	event->set_key_label(key);
	event->set_pressed(pressed);
	String text = String::utf8(name);
	if (pressed && text.length() == 1) {
		event->set_unicode(text.to_lower()[0]);
	}
	Input::get_singleton()->parse_input_event(event);
	return true;
}

bool oppigodot_action(const char *name, bool pressed, float strength) {
	ERR_FAIL_COND_V(!instance || !name, false);
	StringName action = String::utf8(name);
	if (!InputMap::get_singleton()->has_action(action)) {
		return false;
	}
	if (pressed) {
		Input::get_singleton()->action_press(action, strength);
	} else {
		Input::get_singleton()->action_release(action);
	}
	return true;
}

size_t oppigodot_capture_png(uint8_t **out_png) {
	ERR_FAIL_NULL_V(out_png, 0);
	*out_png = nullptr;
	ERR_FAIL_COND_V(!instance, 0);
	SceneTree *tree = SceneTree::get_singleton();
	ERR_FAIL_NULL_V(tree, 0);
	Ref<Image> image = tree->get_root()->get_texture()->get_image();
	ERR_FAIL_COND_V(image.is_null(), 0);
	// Encoded in memory: the host writes it where it likes, outside the
	// game's sandbox, without the sandbox stepping aside.
	Vector<uint8_t> png = image->save_png_to_buffer();
	if (png.is_empty()) {
		return 0;
	}
	uint8_t *bytes = (uint8_t *)malloc(png.size());
	ERR_FAIL_NULL_V(bytes, 0);
	memcpy(bytes, png.ptr(), png.size());
	*out_png = bytes;
	return png.size();
}

void oppigodot_free(void *pointer) {
	free(pointer);
}

char *oppigodot_current_scene(void) {
	SceneTree *tree = instance ? SceneTree::get_singleton() : nullptr;
	Node *scene = tree ? tree->get_current_scene() : nullptr;
	if (!scene || scene->get_scene_file_path().is_empty()) {
		return nullptr;
	}
	CharString path = scene->get_scene_file_path().utf8();
	char *out = (char *)malloc(path.length() + 1);
	ERR_FAIL_NULL_V(out, nullptr);
	memcpy(out, path.get_data(), path.length() + 1);
	return out;
}

void oppigodot_perf(OppiGodotPerf *out) {
	ERR_FAIL_NULL(out);
	*out = {};
	Performance *performance = Performance::get_singleton();
	if (!instance || !performance) {
		return;
	}
	out->fps = performance->get_monitor(Performance::TIME_FPS);
	out->process_ms = performance->get_monitor(Performance::TIME_PROCESS) * 1000.0;
	out->physics_ms = performance->get_monitor(Performance::TIME_PHYSICS_PROCESS) * 1000.0;
	out->draw_calls = (int64_t)performance->get_monitor(Performance::RENDER_TOTAL_DRAW_CALLS_IN_FRAME);
	out->nodes = (int64_t)performance->get_monitor(Performance::OBJECT_NODE_COUNT);
	out->static_memory_bytes = (int64_t)performance->get_monitor(Performance::MEMORY_STATIC);
	out->frames_drawn = (int64_t)Engine::get_singleton()->get_frames_drawn();
}

} // extern "C"
