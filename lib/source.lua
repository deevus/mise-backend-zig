local M = {}

local function is_sha_ref(s)
    return s:match("^[0-9a-f]+$") ~= nil and #s >= 7 and #s <= 40
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

    -- try --branch <ref>, fall back to --branch v<ref>
    local ok, _ = pcall(function()
        cmd.exec(string.format("git clone --depth 1 --branch %s %s %s", ref, url, destdir))
    end)
    if ok then return end

    -- Fall back to v-prefixed tag (Zig projects commonly tag as `v0.1.0`).
    cmd.exec("rm -rf " .. destdir)
    cmd.exec(string.format("git clone --depth 1 --branch v%s %s %s", ref, url, destdir))
end

local function sha256_of(path)
    local cmd = require("cmd")
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

return M
