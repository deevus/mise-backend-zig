# mise-backend-zig-build

A [mise](https://mise.jdx.dev) backend plugin for building and installing Zig projects from git or tarballs.

Given a `build.zig` + `build.zig.zon` project, this backend:
1. Fetches source from a git URL or tarball
2. Resolves which Zig compiler version to use
3. Runs `zig build install --prefix <install_path>`
4. Exposes the built executables on `PATH`

## Prerequisites

- **mise** with experimental backends enabled: `mise settings set experimental true` or `MISE_EXPERIMENTAL=1`
- **Zig is auto-installed** when the project supplies a version. Specifically, the backend installs zig for you if any of these are present:
  - `minimum_zig_version` in the project's `build.zig.zon`
  - `zig_version` opt (in `mise.toml` or `MISE_ZIG_BACKEND_ZIG_VERSION`)
  - the project's own `mise.toml` pinning zig, when `trust_mise_toml = true`
- **You only need to pre-install zig yourself** if none of the above apply — i.e. the project doesn't declare a version anywhere. In that case the backend falls back to your active zig (anything installed via `mise install zig@<ver>` is sufficient — it doesn't need to be globally activated, just installed).

## Install

```bash
mise plugin install zig-build https://github.com/deevus/mise-zig-build
```

## Usage

### From a git repository

```bash
# Use a tagged release
mise install zig-build:git+https://github.com/zigzap/zap@v0.1.0

# Run a tool from the project
mise exec zig-build:git+https://github.com/zigzap/zap@v0.1.0 -- myapp --help
```

Omitting the `git+` prefix also works for non-tarball URLs:

```bash
mise install zig-build:https://github.com/zigzap/zap@v0.1.0
```

### From a tarball (with TOFU hash verification)

```bash
# Install without hash verification
mise install zig-build:tar+https://example.com/myapp-1.0.0.tar.gz@0.1.0

# Install with Zig multibase hash verification
mise install zig-build:tar+https://example.com/myapp-1.0.0.tar.gz@1220abc123...def
```

When a Zig multibase hash (`1220` + 64 hex chars) is provided as the version, the downloaded tarball's SHA-256 is verified against it. Without a hash, the download is accepted on first use (TOFU).

### In mise.toml

```toml
[tools]
"zig-build:git+https://github.com/zigzap/zap" = "v0.1.0"
```

## Options

Options can be set via `mise.toml` tool-specific config or environment variables. Precedence: `ctx.options` > env var > default.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `zig_version` | string | `nil` (auto-detect) | Zig compiler version to use. Overrides `minimum_zig_version` from `build.zig.zon`. |
| `optimize` | string | `nil` | Build optimization mode (e.g. `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`). Passed as `-Doptimize=<value>`. |
| `build_args` | array | `[]` | Additional arguments passed to `zig build install`. Use array syntax in mise.toml. |
| `auto_install_zig` | bool | `true` | Automatically install the resolved Zig version if not already present. |
| `bin_path` | string | `"bin"` | Directory under install path containing executables. |
| `filter_bins` | array | `[]` | When set, only symlink these specific executables into `<install_path>/.mise-bins/` instead of exposing the entire `bin_path`. |

### mise.toml example

```toml
[tools]
"zig-build:git+https://github.com/user/project" = "v1.0.0"

[tools."zig-build:git+https://github.com/user/project".options]
zig_version = "0.14.0"
optimize = "ReleaseFast"
build_args = ["-Dstrip=true"]
bin_path = "bin"
filter_bins = ["myapp"]
```

### Environment variable equivalents

```
MISE_ZIG_BACKEND_ZIG_VERSION=0.14.0
MISE_ZIG_BACKEND_OPTIMIZE=ReleaseFast
MISE_ZIG_BACKEND_BUILD_ARGS="-Dstrip=true -Dcpu=native"
MISE_ZIG_BACKEND_AUTO_INSTALL_ZIG=false
MISE_ZIG_BACKEND_BIN_PATH=bin
MISE_ZIG_BACKEND_FILTER_BINS="myapp helper"
```

Note: array env vars are whitespace-split, which means elements cannot contain spaces.

## How it works

The backend implements three hooks:

- **`BackendListVersions`**: For git sources, lists tags matching semver (`v?X.Y.Z`) via `git ls-remote --tags`. For tarballs, returns `["latest"]`.
- **`BackendInstall`**: Fetches source, resolves Zig version, builds and installs. Zig version resolution follows a tiered approach (first match wins):
  1. `zig_version` opt (`ctx.options` or `MISE_ZIG_BACKEND_ZIG_VERSION`)
  2. The project's own `mise.toml` zig pin — only when `trust_mise_toml = true` (default `false`). Otherwise the project's `mise.toml` is removed before building.
  3. `minimum_zig_version` from `build.zig.zon`
  4. Your active zig (resolved via `mise current zig` from a neutral cwd)

  Tiers 1–3 trigger auto-install of the named zig version (unless `auto_install_zig = false`). Tier 4 uses whatever you already have configured.
- **`BackendExecEnv`**: Exposes the binary directory on `PATH`, respecting `bin_path` and `filter_bins`.

### Ref resolution

Git refs try `--branch <ref>` first, falling back to `--branch v<ref>` for projects that tag as `vX.Y.Z` but are referenced without the `v` prefix. SHA-shaped refs use plain clone + checkout. `HEAD` clones the default branch.

## Development

```bash
# Bootstrap test dependencies
mise run test:setup

# Run unit tests
mise run test:unit

# Run integration test (links plugin, builds vendored fixture)
mise run test

# Format code
mise run format

# Run all CI checks
mise run ci
```

### Debugging

```bash
mise --debug install zig-build:tar+file://./test/fixtures/hello.tar.gz@0.1.0
```

### Troubleshooting

- **"no minimum_zig_version declared"**: The backend will use your active zig. Pin a specific version with the `zig_version` opt, add `minimum_zig_version` to your `build.zig.zon`, or set `trust_mise_toml = true` if the project's `mise.toml` already pins zig.
- **"Hash mismatch"**: The tarball content changed since the hash was recorded (TOFU pin changed). Update the version hash or remove the hash pin.
- **"No binaries found"**: The build succeeded but no files were installed to `bin_path`. Set `bin_path` if your project installs to a different location, or check that your `build.zig` calls `b.installArtifact()`.
- **Installation fails on macOS/Linux**: Ensure the Zig compiler version you need is available via mise: `mise install zig@<version>`.

## Status

This is a **work-in-progress** custom backend for mise. Custom backends are experimental in mise — enable them with `mise settings set experimental true` or `MISE_EXPERIMENTAL=1`.

See [docs/plans/2026-05-05-zig-project-backend-design.md](docs/plans/2026-05-05-zig-project-backend-design.md) for the design document.

## License

MIT
