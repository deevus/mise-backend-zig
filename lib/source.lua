local sh = require("lib.sh")
local shq = sh.shquote
local log_info = require("lib.log").info

local M = {}

local function file_size(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local size = f:seek("end")
    f:close()
    return size
end

local function format_bytes(n)
    if not n or n < 0 then
        return nil
    end
    if n < 1024 then
        return string.format("%d B", n)
    end
    if n < 1024 * 1024 then
        return string.format("%.1f KiB", n / 1024)
    end
    if n < 1024 * 1024 * 1024 then
        return string.format("%.1f MiB", n / (1024 * 1024))
    end
    return string.format("%.2f GiB", n / (1024 * 1024 * 1024))
end

-- Probe Content-Length via HEAD before downloading. Pure http module, no deps.
-- Notes:
--   * Uses http.try_head (returns nil,err on failure) rather than http.head
--     because http.head is an async Rust function that can't yield across a
--     pcall — wrapping it raises "attempt to yield across metamethod/C-call
--     boundary". try_head is the error-returning variant designed for this.
--   * mise's Rust port doesn't set resp.content_length (only the Go upstream
--     does); we read it from the lowercased headers table.
--   * Best-effort: many archive endpoints (codeberg /archive/, codeload.github)
--     stream dynamically generated tarballs without Content-Length, in which
--     case we just skip the size announcement.
local function probe_content_length(http, url)
    if type(http.try_head) ~= "function" then
        return nil
    end
    local resp, err = http.try_head({ url = url })
    if err or type(resp) ~= "table" then
        return nil
    end
    if type(resp.status_code) == "number" and resp.status_code >= 400 then
        return nil
    end
    local headers = resp.headers
    if type(headers) ~= "table" then
        return nil
    end
    local cl = headers["content-length"] or headers["Content-Length"]
    local n = tonumber(cl)
    if not n or n <= 0 then
        return nil
    end
    return n
end

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
        log_info(string.format("cloning %s (commit %s)", url, ref))
        cmd.exec("git clone " .. shq(url) .. " " .. shq(destdir))
        cmd.exec("git -C " .. shq(destdir) .. " checkout " .. shq(ref))
        return
    end

    if ref == "HEAD" then
        log_info(string.format("cloning %s (HEAD)", url))
        cmd.exec("git clone " .. shq(url) .. " " .. shq(destdir))
        return
    end

    -- try --branch <ref>, fall back to --branch v<ref>
    log_info(string.format("cloning %s @ %s (--depth 1)", url, ref))
    local ok, _ = pcall(function()
        cmd.exec("git clone --depth 1 --branch " .. shq(ref) .. " " .. shq(url) .. " " .. shq(destdir))
    end)
    if ok then
        return
    end

    -- Fall back to v-prefixed tag (Zig projects commonly tag as `v0.1.0`).
    log_info(string.format("ref %s not found; retrying as v%s", ref, ref))
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
    local cmd = require("cmd")
    cmd.exec("mkdir -p " .. shq(destdir))

    -- For file:// URLs, extract directly from the local path (no copy, no tmpfile).
    -- For http(s) URLs, download to a tmpfile first.
    local source_path
    local downloaded_tmpfile = nil
    if url:match("^file://") then
        source_path = url:gsub("^file://", "")
        log_info("using local tarball " .. source_path)
    else
        local http = require("http")
        downloaded_tmpfile = destdir .. "/source.tar"
        log_info("probing HEAD " .. url)
        local expected = probe_content_length(http, url)
        if expected then
            log_info(string.format("downloading %s (%s)", url, format_bytes(expected)))
        else
            log_info("downloading " .. url .. " (HEAD did not return content-length)")
        end
        local _, err = http.try_download_file({ url = url }, downloaded_tmpfile)
        if err then
            error("Download failed for " .. url .. ": " .. err)
        end
        local size = file_size(downloaded_tmpfile)
        if size then
            log_info(string.format("downloaded %s from %s", format_bytes(size) or (size .. " B"), url))
        else
            log_info("downloaded " .. url)
        end
        source_path = downloaded_tmpfile
    end

    local actual = sha256_of(source_path)
    log_info("sha256 " .. (actual or "?"))
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

    cmd.exec("tar -xf " .. shq(source_path) .. " -C " .. shq(destdir) .. " --strip-components=1")
    if downloaded_tmpfile then
        cmd.exec("rm -f " .. shq(downloaded_tmpfile))
    end

    return { actual_hash = actual }
end

return M
