local sh = require("lib.sh")
local shq = sh.shquote

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
        cmd.exec("git clone " .. shq(url) .. " " .. shq(destdir))
        cmd.exec("git -C " .. shq(destdir) .. " checkout " .. shq(ref))
        return
    end

    if ref == "HEAD" then
        cmd.exec("git clone " .. shq(url) .. " " .. shq(destdir))
        return
    end

    -- try --branch <ref>, fall back to --branch v<ref>
    local ok, _ = pcall(function()
        cmd.exec("git clone --depth 1 --branch " .. shq(ref) .. " " .. shq(url) .. " " .. shq(destdir))
    end)
    if ok then
        return
    end

    -- Fall back to v-prefixed tag (Zig projects commonly tag as `v0.1.0`).
    cmd.exec("rm -rf " .. shq(destdir))
    cmd.exec("git clone --depth 1 --branch " .. shq("v" .. ref) .. " " .. shq(url) .. " " .. shq(destdir))
end

local function sha256_of(path)
    local cmd = require("cmd")
    -- shasum is on macOS by default and ships with coreutils on Linux. CI runs both.
    local out = cmd.exec("shasum -a 256 " .. shq(path))
    return out:match("^(%x+)")
end

--- Download a tarball, verify its hash if expected is given, extract into destdir.
--- @param url string
--- @param expected_hash string|nil sha256 hex (lowercase) or nil for TOFU
--- @param destdir string
--- @return { actual_hash: string }
function M.fetch_tarball(url, expected_hash, destdir)
    local http = require("http")
    local cmd = require("cmd")

    cmd.exec("mkdir -p " .. shq(destdir))
    local tmpfile = destdir .. "/source.tar"

    -- Handle file:// URLs directly (local tarballs)
    if url:match("^file://") then
        local local_path = url:gsub("^file://", "")
        cmd.exec("cp " .. shq(local_path) .. " " .. shq(tmpfile))
    else
        http.download_file({ url = url }, tmpfile)
    end

    local actual = sha256_of(tmpfile)
    if expected_hash and expected_hash ~= actual then
        error(
            string.format(
                "Hash mismatch for %s: expected %s, got %s. If intentional, update or remove the pin.",
                url,
                expected_hash,
                actual
            )
        )
    end

    cmd.exec("tar -xf " .. shq(tmpfile) .. " -C " .. shq(destdir) .. " --strip-components=1")
    cmd.exec("rm -f " .. shq(tmpfile))

    return { actual_hash = actual }
end

return M
