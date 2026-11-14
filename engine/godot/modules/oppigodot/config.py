# The Oppi host module: the C API in include/OppiGodot.h, the sandbox and the
# log hook. iOS only; it adds no class a game script can see.
def can_build(env, platform):
    return platform == "ios" and env["library_type"] != "executable"


def configure(env):
    pass
