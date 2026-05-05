local spec = require("lib.spec")
local sh = require("lib.sh")
local git = require("lib.git")

function PLUGIN:BackendListVersions(ctx)
    local s = spec.parse(ctx.tool)

    if s.kind == "tarball" then
        return { versions = { "latest" } }
    end

    local cmd = require("cmd")
    local semver = require("semver")
    local out = cmd.exec("git ls-remote --tags " .. sh.shquote(s.url))
    local versions = git.parse_tag_refs(out)
    if #versions == 0 then
        -- escape hatch for repos without semver tags; do not run semver.sort on it
        return { versions = { "HEAD" } }
    end
    -- mise requires ascending semver order (oldest -> newest); semver.sort handles
    -- v-prefix and numeric comparison correctly (10.0.0 > 9.6.24).
    return { versions = semver.sort(versions) }
end
