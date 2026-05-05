PLUGIN = { -- luacheck: ignore
    name = "zig",
    version = "0.1.0",
    description = "mise backend for building and installing Zig projects from git or tarballs",
    author = "deevus",
    homepage = "https://github.com/deevus/mise-backend-zig",
    license = "MIT",
    notes = {
        "Requires a working Zig toolchain available via mise (e.g. `mise install zig@0.13.0`).",
        "Builds projects with `zig build install --prefix <install_path>`.",
        "Reads minimum_zig_version from build.zig.zon to pick the compiler.",
    },
}
