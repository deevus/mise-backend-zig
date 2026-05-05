# Zig Project Backend — Design

**Status:** **executed** — implementation shipped 2026-05-05; CI green on Ubuntu + macOS at https://github.com/deevus/mise-zig.
**Date (designed):** 2026-05-05
**Scope:** Replace the unmodified `mise-backend-plugin-template` content with a working `zig:` backend that builds & installs Zig projects (anything with `build.zig` + `build.zig.zon`) from git repos or pristine tarballs, automatically selecting the right `zig` compiler.

## Execution summary

The design was implemented in full and shipped. The user-facing behavior matches the design's intent. The following changes were made during implementation as the design met reality — recorded here for future readers, not as separate ADRs:

- **Lua 5.1** confirmed (mise's vfox embeds `mlua` with the `lua51` feature). The `mise.toml` `lua = "5.1"` was added explicitly so dev environment matches runtime.
- **`build_flags` (string) → `build_args` (Lua array)** — to handle paths containing spaces. Each token is POSIX-quoted at build-command-construction time. Env-var fallback whitespace-splits with a documented limitation.
- **`bin_path` + `filter_bins` opts added** — match the GitHub backend's vocabulary and semantics. `filter_bins` symlinks selected executables into `<install_path>/.mise-bins/`. Missing/empty bin dir is a hard error.
- **`trust_mise_toml` opt added** — handles real-world Zig projects that ship their own `mise.toml`. Default `false` deletes the project's mise config from the source tree before building (so mise commands don't trip over untrusted config). Opt-in `true` runs `mise trust <srcdir>` and inserts a new resolution tier (project's mise.toml zig pin) between `opts.zig_version` and `minimum_zig_version`.
- **Resolution chain is now four tiers** (was three in the original design): `opts.zig_version` > project's `mise.toml` (when trusted) > `build.zig.zon` `minimum_zig_version` > active zig.
- **vfox built-ins used directly** wherever possible: `file.exists`, `file.symlink`, `file.join_path`, `semver.sort`, `log.info`, `http.try_download_file`. Avoided reinventing.
- **Build output surfacing** — uses `cmd.exec` (captures, gives zig a non-TTY pipe so its progress bar doesn't fight mise's progress UI) plus `io.stderr:write` of the captured output, which writes direct to the user's terminal (bypasses mise's logger). Default `--summary new` is appended to the zig build command unless the user already specified `--summary` in `build_args`.
- **Plan file** at [`docs/plans/2026-05-05-zig-project-backend-plan.md`](2026-05-05-zig-project-backend-plan.md) drove the initial implementation. Two parallel implementations (in `jj` workspaces named `pi` and `dirac`) were merged into the default workspace; subsequent fix-up commits hardened shell-quoting, replaced reinvented helpers with vfox built-ins, fixed git tag deduplication, surfaced build output, and added the trust-mise.toml feature.

The rest of this document is the original design as-written. Read it for the rationale; consult the source for current behavior.

## Purpose

Ship a mise backend plugin that does for Zig projects what the cargo backend does for Rust crates: a single `mise install zig:<source>@<version>` builds and installs an arbitrary Zig project's binaries into the user's mise-managed environment.

The key adaptation: Zig has no central registry, so the tool spec encodes a git URL or tarball URL directly. The plugin reads `minimum_zig_version` from `build.zig.zon` to pick a compiler, then runs `zig build install --prefix <install_path>`.

## Non-goals (v1)

- GitHub shorthand (`zig:user/repo@…`) — stretch goal.
- Persistent source cache.
- Multi-output projects, non-`install` build steps, `zig build run` semantics.
- Windows CI (deferred; design should not exclude it).
- Hash verification against real-world tarball endpoints in CI.

## Tool spec syntax

| Spec | Source | `@version` field |
|---|---|---|
| `zig:git+https://github.com/foo/bar@v1.2.3` | git, explicit | tag/branch/sha |
| `zig:tar+https://example.com/foo.tar.gz@1220ab…` | tarball, explicit, hash-pinned | Zig multibase hash |
| `zig:tar+https://example.com/foo-1.2.3.tar.gz@1.2.3` | tarball, explicit, TOFU | human label |
| `zig:https://github.com/foo/bar@v1.2.3` | auto-detect → git | tag |
| `zig:https://example.com/foo.tar.gz@1.2.3` | auto-detect → tarball | human label |

**Auto-detect rule:** URL ends in `.tar.gz` / `.tar.xz` / `.tar.zst` / `.tgz` → tarball; otherwise → git. Explicit `git+` / `tar+` prefix always wins.

**Tarball integrity:** if `@version` parses as a Zig multibase hash, treat it as the expected hash and verify after download. Otherwise the version is a human label, and the actual sha256 is computed and accepted on first install (TOFU). `mise.lock` pins the hash so subsequent installs verify against it.

## Architecture

Three Lua hooks (the vfox-style backend ABI) plus shared `lib/` modules. Hooks stay thin; logic lives in `lib/` so it's testable without going through the mise CLI.

```
mise CLI ─────────────────────────────────────────┐
                                                   │
  ls-remote  zig:<spec>           ┌────────────────▼────────────┐
  install    zig:<spec>@<ver>     │  hooks/backend_*.lua        │
  exec       zig:<spec>@<ver>     │  (thin entry points only)   │
                                  └────────────────┬────────────┘
                                                   │
                          ┌────────────────────────┼────────────────────────┐
                          ▼                        ▼                        ▼
                   lib/spec.lua             lib/source.lua           lib/build.lua
                   parse(tool_str)          fetch_git(...)           read_min_zig(zon)
                   → {kind, url, hash}      fetch_tarball(...)       resolve_opts(ctx, env)
                                            verify_hash(...)         resolve_zig_version(...)
                                                   │                  run_zig_build(...)
                                                   ▼
                                         lib/cmd.lua  (cmd/http/file shims,
                                                       error wrapping, logging)
```

### `lib/spec.lua::parse(tool_str) → spec`

```lua
{ kind = "git" | "tarball",
  url  = "<canonical url, scheme prefix stripped>",
  hash = "<expected hash or nil>"   -- tarball only
}
```

### `lib/build.lua::resolve_opts(ctx, env) → opts`

Reads from (in precedence order): `ctx.opts` table (mise.toml `[tools]` entry — exact field name to be verified against current vfox runtime; expected `ctx.opts`), then `MISE_ZIG_BACKEND_*` env vars, then defaults.

| Opt | Type | Default | Effect |
|---|---|---|---|
| `zig_version` | string | (auto-detect, see below) | Forces `mise exec zig@<ver>` for the build |
| `optimize` | enum | unset | Appends `-Doptimize=<value>`. Values: `Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall` |
| `build_flags` | string | `""` | Whitespace-split, appended to `zig build` argv |
| `auto_install_zig` | bool | `true` | If `false`, gate `mise exec zig@<ver>` behind a `mise which zig@<ver>` pre-check and error if missing |

Env-var names: `MISE_ZIG_BACKEND_ZIG_VERSION`, `MISE_ZIG_BACKEND_OPTIMIZE`, `MISE_ZIG_BACKEND_BUILD_FLAGS`, `MISE_ZIG_BACKEND_AUTO_INSTALL_ZIG`.

### `lib/build.lua::resolve_zig_version(opts, srcdir) → string|nil`

Tiered fallback. Returns either a version string (build with `mise exec zig@<ver>`) or `nil` (build with the user's currently active zig via `mise exec zig`).

1. `opts.zig_version` → return as-is.
2. `read_min_zig(srcdir/build.zig.zon)` → return matched value.
3. Both unavailable → return `nil` (use active zig).
4. (Tier 4: no zig at all is detected at exec time, not here.)

### `lib/build.lua::read_min_zig(zon_path) → string|nil`

Pure-Lua regex: `%.minimum_zig_version%s*=%s*"([^"]+)"`. First match wins. Returns `nil` if file absent or field missing. Documented limitation: doesn't handle multi-line strings or comments-before-equals — neither pattern occurs in real `build.zig.zon` files.

## Per-hook flow

### `BackendListVersions(ctx)`

```
spec = parse(ctx.tool)
if spec.kind == "git":
    out = cmd.exec("git ls-remote --tags " .. spec.url)
    versions = parse_tags(out), filter to semver-shaped, sort desc
    return { versions = versions }
else:  -- tarball
    return { versions = { "latest" } }
```

Uses `git ls-remote` rather than the GitHub API for auth/redirect/HTTPS robustness.

### `BackendInstall(ctx)`

```
spec   = parse(ctx.tool)
opts   = resolve_opts(ctx, env)
srcdir = mktemp()                          -- ephemeral

-- fetch
if spec.kind == "git":
    cmd.exec("git clone --depth 1 --branch " .. ctx.version .. " " .. spec.url .. " " .. srcdir)
else:
    tmpfile = srcdir .. "/source.tar"
    http.download({ url = spec.url, output = tmpfile })
    expected = spec.hash               -- nil if TOFU
    actual   = sha256(tmpfile)         -- always compute
    if expected and expected ~= actual:
        error("Hash mismatch for " .. spec.url .. ": expected " .. expected .. ", got " .. actual)
    cmd.exec("tar -xf " .. tmpfile .. " -C " .. srcdir .. " --strip-components=1")
    -- actual hash flows into mise.lock via mise's normal lockfile mechanism

-- pick compiler
ver = resolve_zig_version(opts, srcdir)

-- build argv
if ver == nil then
    zig_argv = { "mise", "exec", "zig", "--", "zig", "build", "install", "--prefix", install_path }
else
    if not opts.auto_install_zig then
        cmd.exec("mise which zig@" .. ver)   -- gate; errors if not installed
    end
    zig_argv = { "mise", "exec", "zig@" .. ver, "--", "zig", "build", "install", "--prefix", install_path }
end

if opts.optimize    then append "-Doptimize=" .. opts.optimize end
if opts.build_flags then append (split on whitespace) opts.build_flags end

cmd.exec(zig_argv)                     -- non-zero → error with captured stderr
cmd.exec("rm -rf " .. srcdir)
return {}
```

### `BackendExecEnv(ctx)`

Unchanged from template default:

```lua
return { env_vars = { { key = "PATH", value = ctx.install_path .. "/bin" } } }
```

Zig's `install` step writes binaries to `<prefix>/bin` by convention, matching cargo's `--root`.

## Error model

All errors call Lua `error()` with formatted messages; mise renders them as red CLI output.

| Class | Trigger | Message shape |
|---|---|---|
| **Spec parse** | malformed tool string, unknown scheme | `Invalid zig backend spec: '<input>'. Expected git+<url>, tar+<url>, or auto-detected URL.` |
| **Source fetch** | `git clone` / `http.download` non-zero | `Failed to fetch <url>: <stderr>` (preserves underlying error verbatim) |
| **Hash mismatch** | tarball expected ≠ actual | `Hash mismatch for <url>: expected <e>, got <a>. If intentional, update or remove the pin.` |
| **Zon parse** | file present but unreadable | warn + treat as field-absent (don't fail; fall through tiers) |
| **Auto-install gated** | `auto_install_zig=false` + missing zig version | `Zig <ver> not installed and auto_install_zig is disabled. Install with: mise install zig@<ver>` |
| **No zig at all** | `mise exec zig` fails with no zig configured | `No Zig installed. Install one first with: mise install zig@<ver>` |
| **Zig too old** | `zig build` exits with version-mismatch error | re-emit zig's own message with hint: `The project requires zig >= X. You're using Y.` |
| **Build failure** | `zig build install` non-zero, not version-related | `zig build failed:\n<last 50 lines of stderr>` (truncated to keep mise output usable) |
| **Empty bin dir** | build OK but `install_path/<bin_path>` missing or empty | hard error: `Build succeeded but no binaries found in <dir>. Set the \`bin_path\` opt if your project installs to a non-standard location, or check that build.zig calls b.installArtifact() for your executables.` |
| **filter_bins missing target** | `filter_bins` names a binary that wasn't built | hard error: `filter_bins: <name> not found in <bin_dir>` |

No silent fallbacks except the zon-parse case.

## Testing

Three layers, smallest blast radius first.

### (a) Pure-Lua unit tests via `busted`

Covers parsers and resolvers (no I/O):

- `lib/spec.lua`: parse all five tool-spec shapes (git+, tar+, auto-detect git, auto-detect tar, malformed) → assert `{kind, url, hash}` shape.
- `lib/build.lua::read_min_zig`: feed fixture `.zon` strings (present, absent, multiple matches, malformed) → assert version or nil.
- `lib/build.lua::resolve_opts`: stub `ctx.opts` and `os.getenv`; assert precedence (opt > env > zon > default) for all four options.
- `lib/build.lua::resolve_zig_version`: stub the "is zig@X installed" check; assert tier traversal + auto-install gating.

Run via `busted spec/`. Add `mise run test:unit`. Fast (<1s). No mise CLI involvement.

### (b) Hook-level integration via `mise-tasks/test`

Rewrite the existing stub to:

1. `mise plugin link --force zig .`
2. Use a vendored fixture under `test/fixtures/hello/` with minimal `build.zig` + `build.zig.zon`. Tar it into `test/fixtures/hello.tar.gz` for the tarball path. Use a stable known-tag URL for the git path.
3. Drive each hook in turn (`ls-remote`, `install`, `exec`); assert exit codes and that `bin/<exe>` exists post-install.

### (c) CI

`.github/workflows/ci.yml` runs `mise run ci` (lint + both test layers) on push. Matrix over Ubuntu and macOS. Windows deferred but design should not preclude it.

**Deliberately untested:** real-world hash verification (covered by synthetic data in unit tests); "zig too old" (would require two zig versions in CI — keep manual).

## Open questions

1. ~~**`ctx.opts` field name**~~ — **Resolved**: it's `ctx.options`. `types/mise-plugin.lua` updated during implementation.
2. ~~**Tarball "version" listing**~~ — **Shipped as designed**: returns `["latest"]`. mise's install path doesn't validate `ctx.version` against the list (verified in `crates/vfox/src/backend/vfox.rs`), so any `@<anything>` works for tarballs. Versioned aliases remain out of scope.
3. **Source-cache opt-in** — still open. Repeated installs of the same git ref re-clone every time. No `MISE_ZIG_BACKEND_CACHE_DIR` opt added yet; revisit if it becomes a friction point.

### New open questions surfaced during execution

4. **Backend lockfile support** — `mise.lock` doesn't currently store backend-plugin tarball hashes (verified in mise source: `vfox.rs::supports_lockfile_url()` returns `false` for backend plugins). The TOFU pin promise is honest only at install-time; subsequent installs re-compute the hash but don't compare against a persisted value. Upstream has a `TODO: expose a plugin hook (e.g. BackendLockInfo)` comment. Track via mise GitHub Discussions.
5. **Strict project-mise.toml zig pin** — when `trust_mise_toml = true`, Tier 2 uses `mise current zig` from srcdir. If the project's mise.toml doesn't pin zig but the user's global config does, the global value wins over `minimum_zig_version`. To strictly use only the project's literal pin, we'd need to TOML-parse the project's mise.toml ourselves. Acceptable trade-off for v1.

## Implementation order

1. `lib/spec.lua` + busted tests for parse.
2. `lib/build.lua::read_min_zig` + `resolve_opts` + tests.
3. `lib/build.lua::resolve_zig_version` with stubbed exec + tests.
4. `lib/source.lua` (git clone, tarball download, hash verify).
5. Wire up the three hooks; replace `<BACKEND>`/`<TEST_TOOL>` placeholders in `metadata.lua`, `mise-tasks/test`, etc.
6. Vendor test fixtures, rewrite `mise-tasks/test`.
7. Update `.github/workflows/ci.yml` matrix and `mise.toml` to include `busted` and a `test:unit` task.
8. Update `README.md` to describe the new backend (replacing the template prose).
