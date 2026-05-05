local source    = require("lib.source")
local cmd_stub  = require("spec.helpers.cmd_stub")
local http_stub = require("spec.helpers.http_stub")

local KNOWN_TEXT = "hello tarball"
local KNOWN_SHA  = "497951f4b3b69f43be3d0622217da228c77f3125a1e20b397724de4ec61ea4fb"

describe("lib.source.fetch_tarball", function()
    local rec_cmd, rec_http
    before_each(function()
        os.execute("mkdir -p /tmp/destdir")
        rec_cmd  = cmd_stub.install({
            ["shasum -a 256"] = KNOWN_SHA .. "  -",
        })
        rec_http = http_stub.install({
            ["https://example.com/ok.tar.gz"] = function(path)
                local f = io.open(path, "w"); f:write(KNOWN_TEXT); f:close()
            end,
        })
    end)
    after_each(function() rec_cmd.restore(); rec_http.restore() end)

    it("downloads, computes hash, and extracts", function()
        local result = source.fetch_tarball("https://example.com/ok.tar.gz", nil, "/tmp/destdir")
        assert.are.equal(1, #rec_http.downloads)
        assert.are.equal(KNOWN_SHA, result.actual_hash)
        local tar_cmd = rec_cmd.calls[#rec_cmd.calls - 1]
        assert.is_truthy(tar_cmd:find("tar -xf", 1, true))
        assert.is_truthy(tar_cmd:find("/tmp/destdir", 1, true))
    end)

    it("verifies expected hash when provided", function()
        local result = source.fetch_tarball("https://example.com/ok.tar.gz", KNOWN_SHA, "/tmp/destdir")
        assert.are.equal(KNOWN_SHA, result.actual_hash)
    end)

    it("errors on hash mismatch", function()
        assert.has_error(function()
            source.fetch_tarball("https://example.com/ok.tar.gz", "deadbeef", "/tmp/destdir")
        end)
    end)
end)
