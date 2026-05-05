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

return M
