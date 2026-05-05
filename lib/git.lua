local M = {}

--- Parse `git ls-remote --tags <url>` output into a deduped list of semver-shaped tags.
--- Annotated tags produce both `refs/tags/v1.2.3` AND `refs/tags/v1.2.3^{}` (the
--- dereferenced commit ref). Both lines yield the same captured value, so we dedup.
--- Lightweight tags only produce one line.
--- @param ls_remote_output string Raw stdout from `git ls-remote --tags`
--- @return string[] Unique semver-shaped tags in source order
function M.parse_tag_refs(ls_remote_output)
    local versions = {}
    local seen = {}
    for ref in ls_remote_output:gmatch("refs/tags/([^%s%^]+)") do
        if ref:match("^v?%d+%.%d+%.%d+") and not seen[ref] then
            seen[ref] = true
            table.insert(versions, ref)
        end
    end
    return versions
end

return M
