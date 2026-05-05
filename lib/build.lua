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
