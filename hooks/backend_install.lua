local spec = require("lib.spec")
local source = require("lib.source")
local build = require("lib.build")
local sh = require("lib.sh")
local shquote = sh.shquote

local function looks_like_zig_hash(s)
    -- Zig multibase hashes start with "1220" (sha256 multihash prefix), 68 hex chars total.
    return s and s:match("^1220%x+$") and #s == 68
end

local function dir_has_entries(path)
    -- No vfox built-in for "directory non-empty" — fall back to ls. Use 2>/dev/null
    -- so a missing path doesn't throw on cmd.exec implementations that raise on non-zero.
    local cmd = require("cmd")
    local ok, out = pcall(cmd.exec, "ls -1 " .. shquote(path) .. " 2>/dev/null")
    if not ok then
        return false
    end
    return out:match("%S") ~= nil
end

function PLUGIN:BackendInstall(ctx)
    local s = spec.parse(ctx.tool)
    local opts = build.resolve_opts(ctx.options)
    local cmd = require("cmd")
    local file = require("file")
    local log = require("lib.log") -- timestamped wrapper around vfox's log
    local srcdir = ctx.download_path -- mise creates and cleans this for us

    cmd.exec("mkdir -p " .. shquote(srcdir))

    -- Fetch source
    if s.kind == "git" then
        source.fetch_git(s.url, ctx.version, srcdir)
    else
        local expected = looks_like_zig_hash(ctx.version) and ctx.version or nil
        source.fetch_tarball(s.url, expected, srcdir)
    end

    -- Many real Zig projects ship a `mise.toml`. Without explicit handling, our
    -- subsequent `mise exec zig@<ver> -- zig build ...` invocations would try
    -- to evaluate that untrusted config and abort the build before zig runs.
    -- Default: physically remove the project's mise config files so mise sees
    -- nothing project-local. Opt-in (`trust_mise_toml = true`) trusts the file
    -- and uses mise's resolution (which incorporates the project's pin) as a
    -- new resolution tier between opts.zig_version and minimum_zig_version.
    if opts.trust_mise_toml then
        cmd.exec("mise trust " .. shquote(srcdir))
    else
        for _, name in ipairs({ "mise.toml", ".mise.toml", "mise.local.toml", ".mise.local.toml" }) do
            cmd.exec("rm -f " .. shquote(file.join_path(srcdir, name)))
        end
    end

    -- Resolve which zig to use. Inline the tier traversal here (rather than
    -- calling build.resolve_zig_version) because Tier 2 is conditional on the
    -- trust opt and requires I/O (mise current zig) which doesn't belong in a
    -- pure helper.
    local ver = nil
    if opts.zig_version and opts.zig_version ~= "" then
        ver = opts.zig_version -- Tier 1
    elseif opts.trust_mise_toml then
        -- Tier 2: ask mise what zig is resolved when the project's mise.toml is in scope.
        local ok, out = pcall(cmd.exec, "mise current zig", { cwd = srcdir })
        if ok and out then
            local v = out:match("[%w%.%-]+")
            if v and v ~= "" then
                ver = v
            end
        end
    end
    if ver == nil then
        ver = build.read_min_zig(file.join_path(srcdir, "build.zig.zon")) -- Tier 3
    end
    local zig_argv_prefix
    if ver == nil then
        -- Tier 3: probe the active zig. If none is installed at all, surface an actionable error.
        local ok, ver_out = pcall(cmd.exec, "mise exec zig -- zig version 2>/dev/null")
        if not ok then
            error(
                "No Zig installed and the project's build.zig.zon does not declare minimum_zig_version. "
                    .. "Install one with: mise install zig@<version>, or set the `zig_version` opt."
            )
        end
        local active = ver_out:match("[%d%.]+") or "?"
        log.info(string.format("no minimum_zig_version declared and no zig_version opt; using active zig (%s)", active))
        zig_argv_prefix = "mise exec zig -- "
    else
        if not opts.auto_install_zig then
            local ok = pcall(cmd.exec, "mise which zig@" .. shquote(ver))
            if not ok then
                error(
                    string.format(
                        "Zig %s not installed and auto_install_zig is disabled. Install with: mise install zig@%s",
                        ver,
                        ver
                    )
                )
            end
        end
        zig_argv_prefix = "mise exec zig@" .. shquote(ver) .. " -- "
    end

    -- Build the zig argv (each token POSIX-quoted)
    local parts = {
        "cd",
        shquote(srcdir),
        "&&",
        zig_argv_prefix,
        "zig",
        "build",
        "install",
        "--prefix",
        shquote(ctx.install_path),
    }
    if opts.optimize and opts.optimize ~= "" then
        table.insert(parts, "-Doptimize=" .. opts.optimize)
    end
    -- Default to `--summary new` so users see what zig actually built (cached
    -- re-installs stay quiet; fresh installs show every step). Skip if the user
    -- has already chosen a --summary mode in build_args.
    local user_set_summary = false
    for _, arg in ipairs(opts.build_args) do
        if arg == "--summary" or arg:match("^%-%-summary=") or arg:match("^%-%-summary$") then
            user_set_summary = true
            break
        end
    end
    if not user_set_summary then
        table.insert(parts, "--summary")
        table.insert(parts, "new")
    end
    for _, arg in ipairs(opts.build_args) do
        table.insert(parts, shquote(arg))
    end
    -- Use cmd.exec (not os.execute) for the build:
    --   1. zig's progress display detects TTY and uses ANSI cursor control to
    --      redraw a status line. That fights mise's own progress UI in non-verbose
    --      mode, producing visible flashing.
    --   2. cmd.exec gives the subprocess a non-TTY pipe, so zig disables its
    --      progress bar and only emits real content (warnings, errors, --summary).
    --   3. We surface the captured output once via io.stderr:write — direct write
    --      bypasses mise's logger and goes straight to the user's terminal, so
    --      it's visible in both verbose and non-verbose mode (unlike log.info,
    --      which is filtered out by default).
    -- Append `2>&1` so cmd.exec's capture sees stderr too (zig emits
    -- warnings, errors, and --summary output to stderr).
    local build_cmd = table.concat(parts, " ") .. " 2>&1"
    log.info(string.format("building with %szig (in %s)", zig_argv_prefix, srcdir))
    local ok, build_out = pcall(cmd.exec, build_cmd)
    if build_out and type(build_out) == "string" and build_out:match("%S") then
        io.stderr:write(build_out)
        if not build_out:match("\n$") then
            io.stderr:write("\n")
        end
    end
    if not ok then
        -- pcall returns the error message in build_out on failure; cmd.exec
        -- already includes the captured stderr there, but we've also surfaced
        -- the captured output above for the success path. Surface a concise
        -- error so mise's wrapper doesn't double-print zig's output.
        error("zig build failed")
    end

    -- Verify bin_path exists and is non-empty
    local bin_dir = file.join_path(ctx.install_path, opts.bin_path)
    if not dir_has_entries(bin_dir) then
        error(build.empty_bin_error(bin_dir))
    end

    -- Optional: filter_bins symlinks
    if #opts.filter_bins > 0 then
        local mise_bins = file.join_path(ctx.install_path, ".mise-bins")
        cmd.exec("rm -rf " .. shquote(mise_bins))
        cmd.exec("mkdir -p " .. shquote(mise_bins))
        for _, bname in ipairs(opts.filter_bins) do
            local src = file.join_path(bin_dir, bname)
            local dst = file.join_path(mise_bins, bname)
            if not file.exists(src) then
                error(string.format("filter_bins: %s not found in %s", bname, bin_dir))
            end
            file.symlink(src, dst)
        end
    end

    return {}
end
