local M = {}

local TARBALL_SUFFIXES = { "%.tar%.gz$", "%.tar%.xz$", "%.tar%.zst$", "%.tgz$" }

local function looks_like_tarball(url)
    for _, pat in ipairs(TARBALL_SUFFIXES) do
        if url:match(pat) then
            return true
        end
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
