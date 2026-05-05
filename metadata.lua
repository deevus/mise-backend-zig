PLUGIN = { -- luacheck: ignore
    name = "zig-build",
    version = "0.1.0",
    description = "mise backend for building and installing Zig projects from git or tarballs",
    author = "deevus",
    homepage = "https://github.com/deevus/mise-zig-build",
    license = "MIT",
    notes = {
        "Auto-installs zig when the project declares a version (build.zig.zon's minimum_zig_version, the zig_version opt, or — with trust_mise_toml=true — the project's mise.toml).",
        "Falls back to your active zig only when no version is declared anywhere.",
        "Builds projects with `zig build install --prefix <install_path>`.",
    },
}
