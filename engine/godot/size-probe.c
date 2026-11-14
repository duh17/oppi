// Links every OppiGodot entry point, so the linker keeps what a host needs:
// build.sh links it with -dead_strip and strips it to measure the engine's
// linked size.
#include "OppiGodot/OppiGodot.h"
#include <stddef.h>
int main(int argc, char **argv) {
	OppiGodotConfig config = {0};
	config.pack_path = argv[0];
	oppigodot_set_log_callback(NULL, NULL);
	oppigodot_set_layer(NULL);
	oppigodot_resize(1, 1, 1);
	if (!oppigodot_start(&config)) return 1;
	while (oppigodot_iterate()) {
		oppigodot_touch(0, OPPIGODOT_TOUCH_BEGAN, 0, 0, 0, 0, 0, false);
		oppigodot_key(4, "a", "a", 0, true);
		oppigodot_key_named("Space", true);
		oppigodot_action("ui_accept", true, 1);
		oppigodot_mount_pack(argv[0], true);
		oppigodot_reload_scripts(NULL, 0);
		oppigodot_swap_pack(argv[0], NULL);
		oppigodot_reload_scene();
		uint8_t *png = NULL;
		oppigodot_capture_png(&png);
		oppigodot_free(png);
		OppiGodotPerf perf;
		oppigodot_perf(&perf);
		oppigodot_pause();
		oppigodot_resume();
		oppigodot_focus(true);
		oppigodot_set_muted(false);
		if (!oppigodot_is_running()) break;
	}
	oppigodot_stop();
	return 0;
}
