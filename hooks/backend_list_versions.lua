local spec = require("lib.spec")
local sh = require("lib.sh")

function PLUGIN:BackendListVersions(ctx)
    local s = spec.parse(ctx.tool)

    if s.kind == "tarball" then
        return { versions = { "latest" } }
    end

    local cmd = require("cmd")
    local out = cmd.exec("git ls-remote --tags " .. sh.shquote(s.url))
    local versions = {}
    for ref in out:gmatch("refs/tags/([^%s%^]+)") do
        if ref:match("^v?%d+%.%d+%.%d+") then
            table.insert(versions, ref)
        end
    end
    if #versions == 0 then
        table.insert(versions, "HEAD") -- escape hatch for repos without tags
    end
    -- mise requires ascending semver order (oldest -> newest); see backend-plugin docs.
    table.sort(versions, function(a, b)
        local function nums(s)
            local maj, min, pat = s:match("^v?(%d+)%.(%d+)%.(%d+)")
            return tonumber(maj or 0), tonumber(min or 0), tonumber(pat or 0)
        end
        local am, an, ap = nums(a)
        local bm, bn, bp = nums(b)
        if am ~= bm then
            return am < bm
        end
        if an ~= bn then
            return an < bn
        end
        return ap < bp
    end)
    return { versions = versions }
end
