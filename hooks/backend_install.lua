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
    -- Probe via shell: ls returns nothing for missing/empty dirs. Use 2>/dev/null
    -- so a missing path doesn't throw on cmd.exec implementations that raise on non-zero.
    local cmd = require("cmd")
    local ok, out = pcall(cmd.exec, "ls -1 " .. shquote(path) .. " 2>/dev/null")
    if not ok then
        return false
    end
    return out:match("%S") ~= nil
end

local function path_exists(path)
    -- Robust existence check that doesn't depend on cmd.exec's non-zero-exit behavior.
    local cmd = require("cmd")
    local ok, out = pcall(cmd.exec, "ls -d " .. shquote(path) .. " 2>/dev/null")
    if not ok then
        return false
    end
    return out:match("%S") ~= nil
end

function PLUGIN:BackendInstall(ctx)
    local s = spec.parse(ctx.tool)
    local opts = build.resolve_opts(ctx.options)
    local cmd = require("cmd")
    local srcdir = ctx.download_path -- mise creates and cleans this for us

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
        io.stderr:write(
            string.format(
                "zig backend: no minimum_zig_version declared and no zig_version opt; using active zig (%s)\n",
                active
            )
        )
        zig_argv_prefix = "mise exec zig -- "
    else
        if not opts.auto_install_zig then
            cmd.exec("mise which zig@" .. shquote(ver)) -- errors if not installed
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
    for _, arg in ipairs(opts.build_args) do
        table.insert(parts, shquote(arg))
    end
    cmd.exec(table.concat(parts, " "))

    -- Verify bin_path exists and is non-empty
    local bin_dir = ctx.install_path .. "/" .. opts.bin_path
    if not dir_has_entries(bin_dir) then
        error(build.empty_bin_error(bin_dir))
    end

    -- Optional: filter_bins symlinks
    if #opts.filter_bins > 0 then
        local mise_bins = ctx.install_path .. "/.mise-bins"
        cmd.exec("rm -rf " .. shquote(mise_bins))
        cmd.exec("mkdir -p " .. shquote(mise_bins))
        for _, bname in ipairs(opts.filter_bins) do
            local src = bin_dir .. "/" .. bname
            local dst = mise_bins .. "/" .. bname
            if not path_exists(src) then
                error(string.format("filter_bins: %s not found in %s", bname, bin_dir))
            end
            cmd.exec(string.format("ln -sf %s %s", shquote(src), shquote(dst)))
        end
    end

    return {}
end
