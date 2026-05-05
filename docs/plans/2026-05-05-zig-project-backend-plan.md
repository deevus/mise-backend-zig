# Zig Project Backend Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the unmodified `mise-backend-plugin-template` content with a working `zig:` backend that builds and installs Zig projects (anything with `build.zig` + `build.zig.zon`) from git URLs or pristine tarballs, automatically selecting the right `zig` compiler via mise.

**Architecture:** Three thin Lua hooks (`backend_list_versions`, `backend_install`, `backend_exec_env`) dispatch to shared helpers under `lib/` (spec parsing, source fetching, build orchestration). Logic lives in pure-Lua modules unit-tested with `busted`; the integration layer (`mise-tasks/test`) drives the linked plugin against a vendored Zig fixture.

**Tech Stack:** Lua **5.1** (vfox embeds gopher-lua = 5.1; the template's `lua = "5.4"` is wrong and gets fixed in Task 1), vfox-style mise plugin runtime (`cmd`, `http`, `file`, `json` modules), busted (unit tests), luarocks, jj VCS, GitHub Actions CI on Ubuntu + macOS.

**Avoid Lua 5.4-only features** in plugin code: no `<const>`, no `//` integer division, no bitwise operators, no `goto`. Stick to 5.1-compatible syntax. The current code in this plan already conforms.

**Reference design:** `docs/plans/2026-05-05-zig-project-backend-design.md` — re-read before each task; this plan is the executable form of that design.

**Note on `ctx.options`:** the bundled type defs at `types/mise-plugin.lua:107-117` omit `options` from the Backend*Ctx classes, but the live mise docs (https://mise.jdx.dev/backend-plugin-development.html#backendexecenv) show it *is* present on backend hooks. Treat it as authoritative; one of the tasks below updates the type defs to match. Precedence chain stays as designed: `ctx.options[key]` > `MISE_ZIG_BACKEND_<KEY>` env var > auto-detect (zon) > default.

**Decisions from the grilling pass (2026-05-05):**

| Topic | Decision |
|---|---|
| **Git refs** | Try `--branch <ref>`, fall back to `--branch v<ref>` on failure. Detect SHA-shaped refs (`^[0-9a-f]{7,40}$`) and use `git clone <url> <dst> && git -C <dst> checkout <sha>`. Treat `HEAD` as default-branch clone (no `--branch`). |
| **TOFU** | Verify hash if user supplies `@<hash>`; compute and accept silently otherwise. **No mise.lock pin** — backend plugins can't populate `mise.lock` today (`vfox.rs:73-77, 240-245`). Filed as upstream gap to track via mise GitHub **Discussions** (jdx prefers Discussions over Issues). |
| **Custom backends are experimental** | Gated by `Settings::get().ensure_experimental("custom backends")?` in `vfox.rs:96, 138`. Users must `mise settings set experimental true` (or `MISE_EXPERIMENTAL=1`). Documented in README and added to CI setup. |
| **No version validation on install** | `vfox.rs:135-148` passes `tv.version` straight through to `BackendInstall`. Tarball flow returning `["latest"]` from `BackendListVersions` works regardless of what version the user passes on install. |
| **Output UX** | Tier 3 fallback prints one stderr line: `zig backend: no minimum_zig_version declared and no zig_version opt; using active zig (zig X.Y.Z)`. `zig build` output passed through verbatim. |
| **`build_args`** | Renamed from `build_flags`. `ctx.options.build_args` is a Lua sequence (array of argv tokens). Each token POSIX-quoted (`'...'` with internal `'` escaped as `'\''`) when constructing the shell command. Env-var fallback `MISE_ZIG_BACKEND_BUILD_ARGS` whitespace-splits (documented limitation: no spaces in args via env vars). |
| **`bin_path` + `filter_bins`** | Match GitHub backend convention (`github.rs:849, 1360`). `bin_path` (string, default `"bin"`) names the directory under `install_path` where binaries live. `filter_bins` (array, optional) names which binaries to expose; when set, symlinks just those into `<install_path>/.mise-bins/` and PATH points there instead of `bin_path`. **Missing or empty bin dir is a hard error** (not a warning). |

**Conventions for every task:**
- Tests use `busted`. Run with `mise run test:unit`.
- Modules are required as `require("lib.spec")` etc. The plugin root is on `package.path` because vfox sets it.
- All commits use `jj commit -m "<msg>"`. Do not co-author. After each task, the working copy is empty and a fresh change starts.
- After each commit, optionally `jj log -r '@-' --no-graph -T 'description.first_line() ++ "\n"'` to confirm.
- If a step's expected output diverges, stop and investigate before proceeding.

---

## Task 1: Test infrastructure (busted + mise tasks)

**Goal:** Get `mise run test:unit` working with a placeholder spec that passes, so subsequent tasks have a runnable test target from the first RED step.

**Files:**
- Modify: `mise.toml`
- Create: `spec/_smoke_spec.lua`
- Create: `.luacheckrc` (if not already present — add `spec` dir to allowed globals)

**Step 1: Fix Lua version, add luarocks, add unit-test task to `mise.toml`**

Edit `mise.toml`. Change `lua = "5.4"` to `lua = "5.1"` (matches the gopher-lua runtime mise actually uses for plugins). Under `[tools]`, add `luarocks = "latest"`. Add two new task blocks at the bottom:

```toml
[tasks."test:unit"]
description = "Run busted unit tests"
run = "busted spec/"

[tasks."test:setup"]
description = "Install busted into project lua_modules"
run = "luarocks install --tree=lua_modules busted"
```

The existing `[tasks.ci]` block needs `test:unit` added to its `depends`:

```toml
[tasks.ci]
description = "Run all CI checks"
depends = ["lint", "test:unit", "test"]
```

**Step 2: Trust new mise config and install luarocks**

Run: `mise trust && mise install`
Expected: luarocks installs cleanly. If it fails to find a Lua 5.4 dev header, install via system pkg manager (`brew install luarocks` on macOS) and re-run — flag this in the README.

**Step 3: Bootstrap busted into the project**

Run: `mise run test:setup`
Expected: `lua_modules/bin/busted` exists. The lua_modules tree is project-local.

Append to `.gitignore` (create the file if it doesn't exist):

```
lua_modules/
.luarocks/
Injection.lua
```

(`Injection.lua` is auto-generated by the vfox runtime at install time per the docs.)

Commit-stage doesn't run yet — see step 6.

**Step 4: Write a smoke test that passes**

Create `spec/_smoke_spec.lua`:

```lua
describe("test infrastructure", function()
    it("runs busted", function()
        assert.are.equal(2, 1 + 1)
    end)
end)
```

**Step 5: Verify the test runner works**

Run: `eval "$(mise env)" && lua_modules/bin/busted spec/`
Expected output ends with `1 success / 0 failures / 0 errors / 0 pending`.

If the `busted` binary needs explicit `LUA_PATH`/`LUA_CPATH` to find its modules, the simplest fix is to wrap the call in a shim. Update the `test:unit` task in `mise.toml` to:

```toml
[tasks."test:unit"]
description = "Run busted unit tests"
run = '''
eval "$(luarocks --tree=lua_modules path)"
exec lua_modules/bin/busted spec/
'''
```

Re-run `mise run test:unit` to confirm it passes via the task wrapper.

**Step 6: Commit**

```bash
jj commit -m "test: bootstrap busted unit-test infrastructure"
```

Verify: `jj log -r '@-' --no-graph -T 'description.first_line() ++ "\n"'` prints the message.

---

## Task 2: `lib/spec.lua` — parse tool spec strings

**Goal:** Pure parser: takes the raw `ctx.tool` string, returns a normalized table describing the source. No I/O.

**Files:**
- Create: `lib/spec.lua`
- Create: `spec/spec_spec.lua`

**Step 1: Write the failing tests**

Create `spec/spec_spec.lua`:

```lua
local spec = require("lib.spec")

describe("lib.spec.parse", function()
    it("parses explicit git+ prefix", function()
        local s = spec.parse("git+https://github.com/foo/bar")
        assert.are.equal("git", s.kind)
        assert.are.equal("https://github.com/foo/bar", s.url)
        assert.is_nil(s.hash)
    end)

    it("parses explicit tar+ prefix", function()
        local s = spec.parse("tar+https://example.com/foo.tar.gz")
        assert.are.equal("tarball", s.kind)
        assert.are.equal("https://example.com/foo.tar.gz", s.url)
    end)

    it("auto-detects tarball by suffix", function()
        for _, suffix in ipairs({ ".tar.gz", ".tar.xz", ".tar.zst", ".tgz" }) do
            local s = spec.parse("https://example.com/foo" .. suffix)
            assert.are.equal("tarball", s.kind, "suffix " .. suffix)
        end
    end)

    it("auto-detects git for non-tarball urls", function()
        local s = spec.parse("https://github.com/foo/bar")
        assert.are.equal("git", s.kind)
    end)

    it("rejects malformed input", function()
        assert.has_error(function() spec.parse("") end)
        assert.has_error(function() spec.parse(nil) end)
        assert.has_error(function() spec.parse("not-a-url") end)
    end)
end)
```

**Step 2: Run test to verify it fails**

Run: `mise run test:unit`
Expected: `module 'lib.spec' not found` errors on every test. This is the RED state.

**Step 3: Write minimal implementation**

Create `lib/spec.lua`:

```lua
local M = {}

local TARBALL_SUFFIXES = { "%.tar%.gz$", "%.tar%.xz$", "%.tar%.zst$", "%.tgz$" }

local function looks_like_tarball(url)
    for _, pat in ipairs(TARBALL_SUFFIXES) do
        if url:match(pat) then return true end
    end
    return false
end

local function looks_like_url(s)
    return s:match("^https?://") ~= nil or s:match("^git@") ~= nil
end

--- Parse a mise tool spec string into a normalized source descriptor.
--- @param tool string The raw `ctx.tool` value (without `zig:` prefix).
--- @return { kind: "git"|"tarball", url: string, hash: string|nil }
function M.parse(tool)
    if type(tool) ~= "string" or tool == "" then
        error("Invalid zig backend spec: empty input")
    end

    local prefix, rest = tool:match("^(git%+)(.+)$")
    if prefix then
        return { kind = "git", url = rest, hash = nil }
    end

    prefix, rest = tool:match("^(tar%+)(.+)$")
    if prefix then
        return { kind = "tarball", url = rest, hash = nil }
    end

    if not looks_like_url(tool) then
        error("Invalid zig backend spec: '" .. tool .. "'. Expected git+<url>, tar+<url>, or a URL.")
    end

    if looks_like_tarball(tool) then
        return { kind = "tarball", url = tool, hash = nil }
    end
    return { kind = "git", url = tool, hash = nil }
end

return M
```

Note: `hash` is always `nil` at parse time — it'll be populated by the install hook from `ctx.version` when the version field is recognized as a Zig multibase hash. This keeps the parser pure.

**Step 4: Run test to verify it passes**

Run: `mise run test:unit`
Expected: `6 successes / 0 failures` (5 tests + 1 smoke). If any fail, fix the implementation, do not modify the tests.

**Step 5: Commit**

```bash
jj commit -m "lib: add tool-spec parser (git+/tar+/auto-detect)"
```

---

## Task 3: `lib/build.lua` — `read_min_zig`

**Goal:** Extract `minimum_zig_version` from a `build.zig.zon` file via regex. Returns the version string or nil if absent.

**Files:**
- Create: `lib/build.lua`
- Create: `spec/build_read_min_zig_spec.lua`
- Create: `spec/fixtures/zon/has_min.zon`
- Create: `spec/fixtures/zon/no_min.zon`
- Create: `spec/fixtures/zon/multiple.zon`

**Step 1: Create fixtures**

`spec/fixtures/zon/has_min.zon`:
```zig
.{
    .name = .hello,
    .version = "0.1.0",
    .minimum_zig_version = "0.13.0",
    .dependencies = .{},
    .paths = .{""},
}
```

`spec/fixtures/zon/no_min.zon`:
```zig
.{
    .name = .hello,
    .version = "0.1.0",
    .dependencies = .{},
    .paths = .{""},
}
```

`spec/fixtures/zon/multiple.zon`:
```zig
.{
    .minimum_zig_version = "0.13.0",
    .extra = "minimum_zig_version = oops",
    .also = .{ .minimum_zig_version = "0.99.0" },
}
```

**Step 2: Write the failing tests**

Create `spec/build_read_min_zig_spec.lua`:

```lua
local build = require("lib.build")

describe("lib.build.read_min_zig", function()
    it("extracts the version when present", function()
        assert.are.equal("0.13.0", build.read_min_zig("spec/fixtures/zon/has_min.zon"))
    end)

    it("returns nil when field is absent", function()
        assert.is_nil(build.read_min_zig("spec/fixtures/zon/no_min.zon"))
    end)

    it("returns nil when file does not exist", function()
        assert.is_nil(build.read_min_zig("spec/fixtures/zon/nope.zon"))
    end)

    it("returns the first match on multiple occurrences", function()
        assert.are.equal("0.13.0", build.read_min_zig("spec/fixtures/zon/multiple.zon"))
    end)
end)
```

**Step 3: Run tests — expect RED**

Run: `mise run test:unit`
Expected: errors about `module 'lib.build' not found`.

**Step 4: Implement**

Create `lib/build.lua`:

```lua
local M = {}

--- Read minimum_zig_version from a build.zig.zon file via regex.
--- @param path string Path to build.zig.zon
--- @return string|nil The version string, or nil if absent or file missing.
function M.read_min_zig(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content:match('%.minimum_zig_version%s*=%s*"([^"]+)"')
end

return M
```

**Step 5: Run tests — expect GREEN**

Run: `mise run test:unit`
Expected: `10 successes / 0 failures`.

**Step 6: Commit**

```bash
jj commit -m "lib: add read_min_zig regex extractor"
```

---

## Task 4: `lib/build.lua` — `resolve_opts`

**Goal:** Merge `ctx.options` (from mise.toml) with `MISE_ZIG_BACKEND_*` env vars into a normalized opts table. mise.toml wins over env, env wins over defaults.

**Files:**
- Modify: `lib/build.lua` (append `resolve_opts`)
- Create: `spec/build_resolve_opts_spec.lua`

**Step 1: Write the failing tests**

Create `spec/build_resolve_opts_spec.lua`:

```lua
local build = require("lib.build")

local function reader(env)
    return function(name) return env[name] end
end

describe("lib.build.resolve_opts", function()
    it("returns defaults when nothing is set", function()
        local opts = build.resolve_opts(nil, reader({}))
        assert.is_nil(opts.zig_version)
        assert.is_nil(opts.optimize)
        assert.are.same({}, opts.build_args)
        assert.is_true(opts.auto_install_zig)
        assert.are.equal("bin", opts.bin_path)
        assert.are.same({}, opts.filter_bins)
    end)

    it("reads scalars from env vars", function()
        local opts = build.resolve_opts(nil, reader({
            MISE_ZIG_BACKEND_ZIG_VERSION = "0.14.0",
            MISE_ZIG_BACKEND_OPTIMIZE    = "ReleaseFast",
            MISE_ZIG_BACKEND_BIN_PATH    = "tools",
        }))
        assert.are.equal("0.14.0",     opts.zig_version)
        assert.are.equal("ReleaseFast", opts.optimize)
        assert.are.equal("tools",      opts.bin_path)
    end)

    it("whitespace-splits array env vars", function()
        local opts = build.resolve_opts(nil, reader({
            MISE_ZIG_BACKEND_BUILD_ARGS  = "-Dstrip=true -Dcpu=native",
            MISE_ZIG_BACKEND_FILTER_BINS = "myapp helper",
        }))
        assert.are.same({ "-Dstrip=true", "-Dcpu=native" }, opts.build_args)
        assert.are.same({ "myapp", "helper" }, opts.filter_bins)
    end)

    it("reads scalars from ctx.options", function()
        local opts = build.resolve_opts(
            { zig_version = "0.13.0", optimize = "ReleaseSafe", bin_path = "out" },
            reader({})
        )
        assert.are.equal("0.13.0",     opts.zig_version)
        assert.are.equal("ReleaseSafe", opts.optimize)
        assert.are.equal("out",        opts.bin_path)
    end)

    it("reads array opts from ctx.options as Lua sequences", function()
        local opts = build.resolve_opts(
            { build_args = { "-Dfoo=bar", "-Dpath=/some path" }, filter_bins = { "myapp" } },
            reader({})
        )
        assert.are.same({ "-Dfoo=bar", "-Dpath=/some path" }, opts.build_args)
        assert.are.same({ "myapp" }, opts.filter_bins)
    end)

    it("ctx.options wins over env vars (scalars and arrays)", function()
        local opts = build.resolve_opts(
            { zig_version = "0.14.0", build_args = { "-Dfoo=bar" } },
            reader({
                MISE_ZIG_BACKEND_ZIG_VERSION = "0.13.0",
                MISE_ZIG_BACKEND_BUILD_ARGS  = "-Dignored=true",
            })
        )
        assert.are.equal("0.14.0", opts.zig_version)
        assert.are.same({ "-Dfoo=bar" }, opts.build_args)
    end)

    it("env fills in for keys missing from ctx.options", function()
        local opts = build.resolve_opts(
            { zig_version = "0.14.0" },
            reader({ MISE_ZIG_BACKEND_OPTIMIZE = "ReleaseFast" })
        )
        assert.are.equal("0.14.0",     opts.zig_version)
        assert.are.equal("ReleaseFast", opts.optimize)
    end)

    it("disables auto_install_zig via ctx.options boolean", function()
        local opts = build.resolve_opts({ auto_install_zig = false }, reader({}))
        assert.is_false(opts.auto_install_zig)
    end)

    it("disables auto_install_zig via env '0' or 'false'", function()
        local a = build.resolve_opts(nil, reader({ MISE_ZIG_BACKEND_AUTO_INSTALL_ZIG = "0" }))
        local b = build.resolve_opts(nil, reader({ MISE_ZIG_BACKEND_AUTO_INSTALL_ZIG = "false" }))
        assert.is_false(a.auto_install_zig)
        assert.is_false(b.auto_install_zig)
    end)
end)
```

**Step 2: Run tests — expect RED**

Run: `mise run test:unit`
Expected: failures complaining `attempt to call a nil value (field 'resolve_opts')`.

**Step 3: Implement**

Append to `lib/build.lua` (above the trailing `return M`):

```lua
--- Resolve backend options. Precedence: ctx.options > env var > default.
--- @param ctx_options table|nil The `ctx.options` table from a backend hook (may be nil).
--- @param getenv? fun(name: string): string|nil Optional env reader (defaults to os.getenv) for testability.
--- @return table Normalized opts with keys: zig_version, optimize, build_args, auto_install_zig, bin_path, filter_bins
function M.resolve_opts(ctx_options, getenv)
    getenv = getenv or os.getenv
    local opts = ctx_options or {}

    local function pick_string(key, env_name, default)
        local v = opts[key]
        if v ~= nil and v ~= "" then return v end
        local e = getenv(env_name)
        if e ~= nil and e ~= "" then return e end
        return default
    end

    local function pick_bool(key, env_name, default)
        local v = opts[key]
        if v ~= nil then
            if type(v) == "boolean" then return v end
            if v == "0" or v:lower() == "false" or v == "" then return false end
            return true
        end
        local e = getenv(env_name)
        if e == nil then return default end
        if e == "0" or e:lower() == "false" or e == "" then return false end
        return true
    end

    --- Read an array opt: ctx.options gives a Lua sequence; env var falls back
    --- to whitespace-split (limitation: no spaces in elements via env).
    local function pick_array(key, env_name)
        local v = opts[key]
        if type(v) == "table" then
            local out = {}
            for _, item in ipairs(v) do table.insert(out, tostring(item)) end
            return out
        end
        local e = getenv(env_name)
        local out = {}
        if e ~= nil then
            for token in e:gmatch("%S+") do table.insert(out, token) end
        end
        return out
    end

    return {
        zig_version      = pick_string("zig_version",   "MISE_ZIG_BACKEND_ZIG_VERSION", nil),
        optimize         = pick_string("optimize",      "MISE_ZIG_BACKEND_OPTIMIZE",    nil),
        build_args       = pick_array("build_args",     "MISE_ZIG_BACKEND_BUILD_ARGS"),
        auto_install_zig = pick_bool("auto_install_zig", "MISE_ZIG_BACKEND_AUTO_INSTALL_ZIG", true),
        bin_path         = pick_string("bin_path",      "MISE_ZIG_BACKEND_BIN_PATH",    "bin"),
        filter_bins      = pick_array("filter_bins",    "MISE_ZIG_BACKEND_FILTER_BINS"),
    }
end
```

**Step 4: Run tests — expect GREEN**

Run: `mise run test:unit`
Expected: `19 successes / 0 failures`.

**Step 5: Commit**

```bash
jj commit -m "lib: add resolve_opts (scalars, arrays, bin_path, filter_bins)"
```

---

## Task 5: `lib/build.lua` — `resolve_zig_version`

**Goal:** Tier traversal — opts.zig_version → minimum_zig_version → nil (active zig). Returns the version string or nil.

**Files:**
- Modify: `lib/build.lua` (append `resolve_zig_version`)
- Create: `spec/build_resolve_zig_version_spec.lua`

**Step 1: Write the failing tests**

Create `spec/build_resolve_zig_version_spec.lua`:

```lua
local build = require("lib.build")

describe("lib.build.resolve_zig_version", function()
    it("prefers opts.zig_version over zon", function()
        local v = build.resolve_zig_version(
            { zig_version = "0.14.0" },
            "spec/fixtures/zon/has_min.zon"
        )
        assert.are.equal("0.14.0", v)
    end)

    it("falls back to minimum_zig_version from zon", function()
        local v = build.resolve_zig_version({}, "spec/fixtures/zon/has_min.zon")
        assert.are.equal("0.13.0", v)
    end)

    it("returns nil when neither is available (active-zig tier)", function()
        local v = build.resolve_zig_version({}, "spec/fixtures/zon/no_min.zon")
        assert.is_nil(v)
    end)

    it("returns nil when zon file does not exist", function()
        local v = build.resolve_zig_version({}, "/nonexistent/build.zig.zon")
        assert.is_nil(v)
    end)
end)
```

**Step 2: Run tests — expect RED**

Run: `mise run test:unit`
Expected: `attempt to call a nil value (field 'resolve_zig_version')`.

**Step 3: Implement**

Append to `lib/build.lua`:

```lua
--- Resolve which zig version to use, per the design's tier rules.
--- @param opts { zig_version: string|nil }
--- @param zon_path string Path to build.zig.zon
--- @return string|nil version string, or nil meaning "use the user's active zig"
function M.resolve_zig_version(opts, zon_path)
    if opts.zig_version and opts.zig_version ~= "" then
        return opts.zig_version
    end
    return M.read_min_zig(zon_path)
end
```

**Step 4: Run tests — expect GREEN**

Run: `mise run test:unit`
Expected: `21 successes / 0 failures`.

**Step 5: Commit**

```bash
jj commit -m "lib: add resolve_zig_version tier traversal"
```

---

## Task 6: `lib/source.lua` — git fetch

**Goal:** Clone a git repo at a specific ref into a destination directory. Wraps `cmd.exec` so it's stubbable.

**Files:**
- Create: `lib/source.lua`
- Create: `spec/source_git_spec.lua`
- Create: `spec/helpers/cmd_stub.lua`

**Step 1: Create the cmd stub helper (reusable across source/build tests)**

Create `spec/helpers/cmd_stub.lua`:

```lua
local M = {}

--- Replace the global `require("cmd")` with a stub that records calls
--- and returns canned output.
--- @param canned table<integer|string, string> Optional canned outputs keyed by command substring.
--- @return { calls: string[], restore: fun() }
function M.install(canned)
    canned = canned or {}
    local recorder = { calls = {} }
    local stub = {
        exec = function(command)
            table.insert(recorder.calls, command)
            for pat, out in pairs(canned) do
                if type(pat) == "string" and command:find(pat, 1, true) then
                    return out
                end
            end
            return ""
        end,
    }
    local saved = package.loaded["cmd"]
    package.loaded["cmd"] = stub
    recorder.restore = function() package.loaded["cmd"] = saved end
    return recorder
end

return M
```

**Step 2: Write the failing tests**

Create `spec/source_git_spec.lua`:

```lua
local source = require("lib.source")
local cmd_stub = require("spec.helpers.cmd_stub")

describe("lib.source.fetch_git", function()
    local rec
    before_each(function() rec = cmd_stub.install({
        -- shasum stub not relevant here; cmd_stub returns "" by default.
        -- For ref-fallback tests, the first --branch attempt errors — see below.
    }) end)
    after_each(function() rec.restore() end)

    it("clones with --depth 1 --branch <ref> for tag-shaped refs", function()
        source.fetch_git("https://github.com/foo/bar", "v1.2.3", "/tmp/srcdir")
        local c = rec.calls[#rec.calls]
        assert.is_truthy(c:find("git clone", 1, true))
        assert.is_truthy(c:find("--depth 1", 1, true))
        assert.is_truthy(c:find("--branch v1.2.3", 1, true))
        assert.is_truthy(c:find("https://github.com/foo/bar", 1, true))
        assert.is_truthy(c:find("/tmp/srcdir", 1, true))
    end)

    it("falls back to --branch v<ref> on first attempt failure", function()
        rec.restore()
        rec = cmd_stub.install({
            -- Make the first call (no v-prefix) fail; subsequent calls succeed.
            ["--branch 1.2.3"] = { fail = true },
        })
        source.fetch_git("https://github.com/foo/bar", "1.2.3", "/tmp/srcdir")
        -- Two clone attempts: first --branch 1.2.3 (fails), then --branch v1.2.3 (succeeds).
        assert.are.equal(2, #rec.calls)
        assert.is_truthy(rec.calls[1]:find("--branch 1.2.3", 1, true))
        assert.is_truthy(rec.calls[2]:find("--branch v1.2.3", 1, true))
    end)

    it("clone-then-checkout for SHA-shaped refs", function()
        source.fetch_git("https://github.com/foo/bar", "abc1234567890def1234567890abcdef12345678", "/tmp/srcdir")
        -- Two calls: clone (no --branch) + checkout.
        assert.are.equal(2, #rec.calls)
        assert.is_truthy(rec.calls[1]:find("git clone", 1, true))
        assert.is_falsy (rec.calls[1]:find("--branch", 1, true))
        assert.is_truthy(rec.calls[2]:find("git -C /tmp/srcdir checkout abc1234", 1, true))
    end)

    it("plain clone (no --branch) for HEAD", function()
        source.fetch_git("https://github.com/foo/bar", "HEAD", "/tmp/srcdir")
        local c = rec.calls[#rec.calls]
        assert.is_truthy(c:find("git clone", 1, true))
        assert.is_falsy(c:find("--branch", 1, true))
    end)
end)
```

The `cmd_stub.install` helper now needs to support a `{ fail = true }` value — when matched, `cmd.exec` raises an error so callers can test fallback paths. Update `spec/helpers/cmd_stub.lua` accordingly:

```lua
function M.install(canned)
    canned = canned or {}
    local recorder = { calls = {} }
    local stub = {
        exec = function(command)
            table.insert(recorder.calls, command)
            for pat, out in pairs(canned) do
                if type(pat) == "string" and command:find(pat, 1, true) then
                    if type(out) == "table" and out.fail then
                        error("stubbed cmd.exec failure: " .. command)
                    end
                    return out
                end
            end
            return ""
        end,
    }
    -- ... (rest unchanged)
end
```

**Step 3: Run tests — expect RED**

Run: `mise run test:unit`
Expected: `module 'lib.source' not found`.

**Step 4: Implement**

Create `lib/source.lua`:

```lua
local M = {}

local function is_sha_ref(s)
    return s:match("^[0-9a-f]+$") ~= nil and #s >= 7 and #s <= 40
end

local function try_clone_branch(url, ref, destdir)
    local cmd = require("cmd")
    local ok, err = pcall(function()
        cmd.exec(string.format("git clone --depth 1 --branch %s %s %s", ref, url, destdir))
    end)
    return ok, err
end

--- Clone a git repo at a specific ref into destdir.
--- Handles three cases:
---   * SHA-shaped ref → plain clone + checkout
---   * "HEAD"          → plain clone (default branch)
---   * tag/branch ref  → --branch <ref>, fall back to --branch v<ref>
--- @param url string git URL
--- @param ref string tag, branch, or sha
--- @param destdir string destination directory
function M.fetch_git(url, ref, destdir)
    local cmd = require("cmd")

    if is_sha_ref(ref) then
        cmd.exec(string.format("git clone %s %s", url, destdir))
        cmd.exec(string.format("git -C %s checkout %s", destdir, ref))
        return
    end

    if ref == "HEAD" then
        cmd.exec(string.format("git clone %s %s", url, destdir))
        return
    end

    local ok = try_clone_branch(url, ref, destdir)
    if ok then return end

    -- Fall back to v-prefixed tag (Zig projects commonly tag as `v0.1.0`).
    cmd.exec("rm -rf " .. destdir)  -- partial clone may have run; clean up
    cmd.exec(string.format("git clone --depth 1 --branch v%s %s %s", ref, url, destdir))
end

return M
```

**Step 5: Run tests — expect GREEN**

Run: `mise run test:unit`
Expected: `27 successes / 0 failures` (added: SHA-checkout, tag-prefix fallback, HEAD plain-clone).

**Step 6: Commit**

```bash
jj commit -m "lib: git fetch handles tags, v-prefix fallback, SHAs, HEAD"
```

---

## Task 7: `lib/source.lua` — tarball fetch + hash verify

**Goal:** Download a tarball, optionally verify its sha256 against an expected hash, extract into destdir.

**Files:**
- Modify: `lib/source.lua` (append `fetch_tarball`)
- Create: `spec/source_tarball_spec.lua`
- Create: `spec/helpers/http_stub.lua`

**Step 1: Create the http stub helper**

Create `spec/helpers/http_stub.lua`:

```lua
local M = {}

function M.install(handlers)
    handlers = handlers or {}
    local recorder = { downloads = {} }
    local stub = {
        download_file = function(opts, path)
            table.insert(recorder.downloads, { url = opts.url, path = path })
            local writer = handlers[opts.url]
            if writer then writer(path) end
        end,
        get  = function() error("http.get not stubbed") end,
        head = function() error("http.head not stubbed") end,
    }
    local saved = package.loaded["http"]
    package.loaded["http"] = stub
    recorder.restore = function() package.loaded["http"] = saved end
    return recorder
end

return M
```

**Step 2: Write the failing tests**

Create `spec/source_tarball_spec.lua`:

```lua
local source    = require("lib.source")
local cmd_stub  = require("spec.helpers.cmd_stub")
local http_stub = require("spec.helpers.http_stub")

local KNOWN_TEXT = "hello tarball"
-- sha256("hello tarball") = precomputed below
local KNOWN_SHA  = "82bf8a4a9ef0d4c2c5a7e6c5b8b8b6c0a7f7e6d5c4b3a2918171615141312111"
-- ^ placeholder; the implementer will compute the real hash with `shasum -a 256` and update both this constant and the test.

describe("lib.source.fetch_tarball", function()
    local rec_cmd, rec_http
    before_each(function()
        rec_cmd  = cmd_stub.install()
        rec_http = http_stub.install({
            ["https://example.com/ok.tar.gz"] = function(path)
                local f = io.open(path, "w"); f:write(KNOWN_TEXT); f:close()
            end,
        })
    end)
    after_each(function() rec_cmd.restore(); rec_http.restore() end)

    it("downloads, computes hash, and extracts", function()
        local result = source.fetch_tarball("https://example.com/ok.tar.gz", nil, "/tmp/destdir")
        assert.are.equal(1, #rec_http.downloads)
        assert.are.equal(KNOWN_SHA, result.actual_hash)
        local extract_cmd = rec_cmd.calls[#rec_cmd.calls]
        assert.is_truthy(extract_cmd:find("tar -xf", 1, true))
        assert.is_truthy(extract_cmd:find("/tmp/destdir", 1, true))
    end)

    it("verifies expected hash when provided", function()
        local result = source.fetch_tarball("https://example.com/ok.tar.gz", KNOWN_SHA, "/tmp/destdir")
        assert.are.equal(KNOWN_SHA, result.actual_hash)
    end)

    it("errors on hash mismatch", function()
        assert.has_error(function()
            source.fetch_tarball("https://example.com/ok.tar.gz", "deadbeef", "/tmp/destdir")
        end)
    end)
end)
```

Before running, replace the `KNOWN_SHA` placeholder with the real value:

```bash
printf '%s' 'hello tarball' | shasum -a 256
# Expected: <actual hash>  -
```

Update both the constant in the test file and re-save.

**Step 3: Run tests — expect RED**

Run: `mise run test:unit`
Expected: failures about `attempt to call a nil value (field 'fetch_tarball')`.

**Step 4: Implement**

Append to `lib/source.lua`:

```lua
local function sha256_of(path)
    local cmd = require("cmd")
    -- shasum is on macOS by default and ships with coreutils on Linux. CI runs both.
    local out = cmd.exec("shasum -a 256 " .. path)
    return out:match("^(%x+)")
end

--- Download a tarball, verify its hash if expected is given, extract into destdir.
--- @param url string
--- @param expected_hash string|nil sha256 hex (lowercase) or nil for TOFU
--- @param destdir string
--- @return { actual_hash: string }
function M.fetch_tarball(url, expected_hash, destdir)
    local http = require("http")
    local cmd  = require("cmd")

    cmd.exec("mkdir -p " .. destdir)
    local tmpfile = destdir .. "/source.tar"
    http.download_file({ url = url }, tmpfile)

    local actual = sha256_of(tmpfile)
    if expected_hash and expected_hash ~= actual then
        error(string.format(
            "Hash mismatch for %s: expected %s, got %s. If intentional, update or remove the pin.",
            url, expected_hash, actual
        ))
    end

    cmd.exec("tar -xf " .. tmpfile .. " -C " .. destdir .. " --strip-components=1")
    cmd.exec("rm -f " .. tmpfile)

    return { actual_hash = actual }
end
```

The cmd stub returns `""` by default for `shasum`, so the test's `KNOWN_SHA` matching depends on the stub returning the real hash. Update `cmd_stub.install` calls in the test to pre-can the shasum response — see the test setup.

(Adjustment: update `spec/source_tarball_spec.lua`'s `before_each` to install the cmd stub with a canned response keyed on `"shasum -a 256"` returning `KNOWN_SHA .. "  -"`. The stub helper supports keyed canned outputs by substring match.)

**Step 5: Run tests — expect GREEN**

Run: `mise run test:unit`
Expected: `30 successes / 0 failures`.

**Step 6: Commit**

```bash
jj commit -m "lib: add tarball fetch with hash verify (TOFU)"
```

---

## Task 8: Wire up the three hooks + replace placeholders

**Goal:** Replace the three template hook files with thin dispatchers calling into `lib/`. Replace `<BACKEND>` and friends in `metadata.lua`. No new unit tests — these are glue that the integration test (Task 9) covers.

**Files:**
- Modify: `metadata.lua`
- Rewrite: `hooks/backend_list_versions.lua`
- Rewrite: `hooks/backend_install.lua`
- Rewrite: `hooks/backend_exec_env.lua`
- Modify: `types/mise-plugin.lua` (add `options` field to `BackendListVersionsCtx`, `BackendInstallCtx`, `BackendExecEnvCtx`)

**Step 1: Update `metadata.lua`**

Set the placeholders. Final file:

```lua
PLUGIN = { -- luacheck: ignore
    name        = "zig",
    version     = "0.1.0",
    description = "mise backend for building and installing Zig projects from git or tarballs",
    author      = "simonhartcher",
    homepage    = "https://github.com/simonhartcher/mise-backend-zig",
    license     = "MIT",
    notes = {
        "Requires a working Zig toolchain available via mise (e.g. `mise install zig@0.13.0`).",
        "Builds projects with `zig build install --prefix <install_path>`.",
        "Reads minimum_zig_version from build.zig.zon to pick the compiler.",
    },
}
```

**Step 2: Rewrite `hooks/backend_list_versions.lua`**

```lua
local spec = require("lib.spec")

function PLUGIN:BackendListVersions(ctx)
    local s = spec.parse(ctx.tool)

    if s.kind == "tarball" then
        return { versions = { "latest" } }
    end

    local cmd = require("cmd")
    local out = cmd.exec("git ls-remote --tags " .. s.url)
    local versions = {}
    for ref in out:gmatch("refs/tags/([^%s%^]+)") do
        if ref:match("^v?%d+%.%d+%.%d+") then
            table.insert(versions, ref)
        end
    end
    if #versions == 0 then
        table.insert(versions, "HEAD")  -- escape hatch for repos without tags
    end
    -- mise requires ascending semver order (oldest -> newest); see backend-plugin docs.
    table.sort(versions, function(a, b)
        local function nums(s)
            local maj, min, pat = s:match("^v?(%d+)%.(%d+)%.(%d+)")
            return tonumber(maj or 0), tonumber(min or 0), tonumber(pat or 0)
        end
        local am, an, ap = nums(a)
        local bm, bn, bp = nums(b)
        if am ~= bm then return am < bm end
        if an ~= bn then return an < bn end
        return ap < bp
    end)
    return { versions = versions }
end
```

**Step 3: Rewrite `hooks/backend_install.lua`**

```lua
local spec   = require("lib.spec")
local source = require("lib.source")
local build  = require("lib.build")

local function looks_like_zig_hash(s)
    -- Zig multibase hashes start with "1220" (sha256 multihash prefix), 68 hex chars total.
    return s and s:match("^1220%x+$") and #s == 68
end

--- POSIX-shell-quote a single token: wrap in single quotes, escape internal '.
local function shquote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function dir_has_entries(path)
    -- Cheap probe via shell: ls returns non-zero if path is missing.
    local cmd = require("cmd")
    local ok, out = pcall(cmd.exec, "ls -1 " .. shquote(path))
    if not ok then return false end
    return out:match("%S") ~= nil
end

function PLUGIN:BackendInstall(ctx)
    local s    = spec.parse(ctx.tool)
    local opts = build.resolve_opts(ctx.options)
    local cmd  = require("cmd")
    local srcdir = ctx.download_path  -- mise creates and cleans this for us

    cmd.exec("mkdir -p " .. shquote(srcdir))

    -- Fetch source
    if s.kind == "git" then
        source.fetch_git(s.url, ctx.version, srcdir)
    else
        local expected = looks_like_zig_hash(ctx.version) and ctx.version or nil
        source.fetch_tarball(s.url, expected, srcdir)
    end

    -- Resolve which zig to use
    local ver = build.resolve_zig_version(opts, srcdir .. "/build.zig.zon")
    local zig_argv_prefix
    if ver == nil then
        -- Tier 3: emit a one-line stderr note so users aren't surprised by which zig was used.
        local active = cmd.exec("mise exec zig -- zig version 2>/dev/null"):match("[%d%.]+") or "?"
        io.stderr:write(string.format(
            "zig backend: no minimum_zig_version declared and no zig_version opt; using active zig (%s)\n",
            active))
        zig_argv_prefix = "mise exec zig -- "
    else
        if not opts.auto_install_zig then
            cmd.exec("mise which zig@" .. shquote(ver))  -- errors if not installed
        end
        zig_argv_prefix = "mise exec zig@" .. shquote(ver) .. " -- "
    end

    -- Build the zig argv (each token POSIX-quoted)
    local parts = { "cd", shquote(srcdir), "&&", zig_argv_prefix,
                    "zig", "build", "install", "--prefix", shquote(ctx.install_path) }
    if opts.optimize and opts.optimize ~= "" then
        table.insert(parts, "-Doptimize=" .. opts.optimize)
    end
    for _, arg in ipairs(opts.build_args) do
        table.insert(parts, shquote(arg))
    end
    cmd.exec(table.concat(parts, " "))

    -- Verify bin_path exists and is non-empty
    local bin_dir = ctx.install_path .. "/" .. opts.bin_path
    if not dir_has_entries(bin_dir) then
        error(string.format(
            "Build succeeded but no binaries found in %s. " ..
            "Set the `bin_path` opt if your project installs to a non-standard location, " ..
            "or check that build.zig calls b.installArtifact() for your executables.",
            bin_dir))
    end

    -- Optional: filter_bins symlinks
    if #opts.filter_bins > 0 then
        local mise_bins = ctx.install_path .. "/.mise-bins"
        cmd.exec("rm -rf " .. shquote(mise_bins))
        cmd.exec("mkdir -p " .. shquote(mise_bins))
        for _, bname in ipairs(opts.filter_bins) do
            local src = bin_dir .. "/" .. bname
            local dst = mise_bins .. "/" .. bname
            local ok = pcall(cmd.exec, "test -e " .. shquote(src))
            if not ok then
                error(string.format("filter_bins: %s not found in %s", bname, bin_dir))
            end
            cmd.exec(string.format("ln -sf %s %s", shquote(src), shquote(dst)))
        end
    end

    return {}
end
```

**Step 4: Rewrite `hooks/backend_exec_env.lua`**

```lua
local build = require("lib.build")

function PLUGIN:BackendExecEnv(ctx)
    local opts = build.resolve_opts(ctx.options)
    local path
    if #opts.filter_bins > 0 then
        path = ctx.install_path .. "/.mise-bins"
    else
        path = ctx.install_path .. "/" .. opts.bin_path
    end
    return {
        env_vars = {
            { key = "PATH", value = path },
        },
    }
end
```

**Step 5: Update the Backend*Ctx type defs**

In `types/mise-plugin.lua`, add `---@field options table Plugin options from mise.toml` to each of the three Backend*Ctx classes (lines ~101-117). Keeps IDE autocompletion accurate now that we read from `ctx.options`.

**Step 6: Sanity-check Lua loads**

Run: `mise run lint`
Expected: stylua + luacheck + actionlint all pass. If luacheck flags `require("cmd")` as undefined, add it (and `http`, `file`) to `.luacheckrc`'s globals. The template should already permit them — flag if not.

**Step 7: Commit**

```bash
jj commit -m "hooks: wire backend hooks to lib modules; finalize metadata"
```

---

## Task 9: Vendored Zig fixture + integration test rewrite

**Goal:** Real end-to-end smoke through `mise plugin link` against a tiny vendored Zig project, exercising both source kinds.

**Files:**
- Create: `test/fixtures/hello/build.zig`
- Create: `test/fixtures/hello/build.zig.zon`
- Create: `test/fixtures/hello/src/main.zig`
- Create: `test/fixtures/hello.tar.gz` (built artifact)
- Rewrite: `mise-tasks/test`

**Step 1: Create the fixture project**

`test/fixtures/hello/build.zig`:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "hello",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
}
```

`test/fixtures/hello/build.zig.zon`:
```zig
.{
    .name = .hello,
    .version = "0.1.0",
    .minimum_zig_version = "0.13.0",
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

`test/fixtures/hello/src/main.zig`:
```zig
const std = @import("std");
pub fn main() !void {
    try std.io.getStdOut().writer().print("hello from mise-backend-zig\n", .{});
}
```

**Step 2: Build the tarball fixture**

Run from the repo root:

```bash
tar -czf test/fixtures/hello.tar.gz -C test/fixtures hello
```

Verify: `tar -tzf test/fixtures/hello.tar.gz | head` shows `hello/build.zig` etc.

**Step 3: Rewrite `mise-tasks/test`**

```bash
#!/usr/bin/env bash
#MISE description="Integration test: link plugin and exercise hooks against fixture"
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_TGZ="$REPO_ROOT/test/fixtures/hello.tar.gz"

mise plugin link --force zig "$REPO_ROOT"
mise cache clear || true

echo "==> tarball: install + run"
SPEC="zig:tar+file://$FIXTURE_TGZ"
mise install "${SPEC}@0.1.0"
mise exec "${SPEC}@0.1.0" -- hello

echo "==> tarball: hash mismatch must fail"
if mise install "${SPEC}@1220deadbeef0000000000000000000000000000000000000000000000000000000000" 2>/dev/null; then
    echo "expected hash mismatch error"; exit 1
fi
echo "    OK (rejected as expected)"

# git path is exercised manually unless a network-safe public repo with tags is chosen.
echo "==> all integration assertions passed"
```

The git-path test is omitted from CI to avoid network flakiness. If a stable, tiny Zig project with semver tags is available (e.g. one we control under `simonhartcher/`), add a third block; otherwise document this as a manual test in the README.

`chmod +x mise-tasks/test`.

**Step 4: Smoke-run locally (assumes a `zig@0.13.0` is installable in this env)**

Run: `mise run test`
Expected: prints `hello from mise-backend-zig` and `OK (rejected as expected)`.

If this fails because no `zig@0.13.0` is installed and `auto_install_zig` is on, mise should fetch it. If the fetch itself fails, that's an upstream issue with the asdf-zig plugin — flag in the README rather than working around.

**Step 5: Commit**

```bash
jj commit -m "test: vendored Zig fixture and integration test driving real install"
```

---

## Task 10: CI matrix + README rewrite

**Goal:** CI exercises both unit and integration tests on Ubuntu and macOS. README replaces the template prose with backend-specific docs.

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md`

**Step 1: Update CI workflow**

`.github/workflows/ci.yml` already runs `mise run ci` on a Ubuntu+macOS matrix. The only change needed is to ensure luarocks/busted are bootstrapped before `mise run ci`. Add a setup step:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  ci:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v2
      - name: Bootstrap test deps
        run: mise run test:setup
      - name: Run CI
        run: mise run ci
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

If `luarocks` itself fails to install via mise on either platform, fall back to `apt-get install -y luarocks` (Ubuntu) or `brew install luarocks` (macOS) in conditional steps. Document which path was used in the commit message.

**Step 2: Rewrite `README.md`**

Replace the template body with a backend-specific README. Keep it focused: what the backend does, install/usage examples, options table, troubleshooting. Reference the design doc and this plan for deeper details. Roughly 100–150 lines is appropriate.

Sections to include:
- **What it does** — one paragraph mirroring the plan's Goal.
- **Install** — `mise plugin install zig https://github.com/simonhartcher/mise-backend-zig`
- **Usage** — concrete `mise install zig:git+https://...@v1.0.0` and `mise install zig:tar+...@<hash>` examples
- **Options table** — all six opts (`zig_version`, `optimize`, `build_args`, `auto_install_zig`, `bin_path`, `filter_bins`) with both `mise.toml` and `MISE_ZIG_BACKEND_*` env-var forms
- **Troubleshooting** — "no Zig installed" message → run `mise install zig@<ver>`; "hash mismatch" → check if upstream re-released; busted setup needing system luarocks.
- **Development** — `mise run test:setup`, `mise run test:unit`, `mise run test`, `mise run ci`.
- **Status** — link to `docs/plans/2026-05-05-zig-project-backend-design.md`.

**Step 3: Run the full local suite**

Run: `mise run ci`
Expected: lint passes, all unit tests pass, integration test passes.

**Step 4: Commit**

```bash
jj commit -m "ci+docs: matrix bootstrap busted; rewrite README for zig backend"
```

---

## Final verification

After all tasks complete:

1. `jj log -r 'main..@-' --no-graph -T 'description.first_line() ++ "\n"'` — should show 10 commits in the order above.
2. `mise run ci` — green locally on macOS.
3. Push the branch (or `jj git push`) and confirm the GitHub Actions matrix passes both Ubuntu and macOS.
4. Re-read the design doc's "Open questions" section. Two of three (`ctx.opts` field name, source cache) are now resolved by the implementation — update the design doc with a `## Resolution` section noting what was found.
