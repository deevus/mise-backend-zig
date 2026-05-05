local spec = require("lib.spec")
local sh = require("lib.sh")

function PLUGIN:BackendListVersions(ctx)
    local s = spec.parse(ctx.tool)

    if s.kind == "tarball" then
        return { versions = { "latest" } }
    end

    local cmd = require("cmd")
    local semver = require("semver")
    local out = cmd.exec("git ls-remote --tags " .. sh.shquote(s.url))
    local versions = {}
    for ref in out:gmatch("refs/tags/([^%s%^]+)") do
        if ref:match("^v?%d+%.%d+%.%d+") then
            table.insert(versions, ref)
        end
    end
    if #versions == 0 then
        -- escape hatch for repos without semver tags; do not run semver.sort on it
        return { versions = { "HEAD" } }
    end
    -- mise requires ascending semver order (oldest -> newest); semver.sort handles
    -- v-prefix and numeric comparison correctly (10.0.0 > 9.6.24).
    return { versions = semver.sort(versions) }
end
