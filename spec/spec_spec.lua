local spec = require("lib.spec")

describe("lib.spec.parse", function()
    it("parses explicit git+ prefix", function()
        local s = spec.parse("git+https://github.com/foo/bar")
        assert.are.equal("git", s.kind)
        assert.are.equal("https://github.com/foo/bar", s.url)
        assert.is_nil(s.hash)
    end)

    it("parses explicit tar+ prefix", function()
        local s = spec.parse("tar+https://example.com/foo.tar.gz")
        assert.are.equal("tarball", s.kind)
        assert.are.equal("https://example.com/foo.tar.gz", s.url)
    end)

    it("auto-detects tarball by suffix", function()
        for _, suffix in ipairs({ ".tar.gz", ".tar.xz", ".tar.zst", ".tgz" }) do
            local s = spec.parse("https://example.com/foo" .. suffix)
            assert.are.equal("tarball", s.kind, "suffix " .. suffix)
        end
    end)

    it("auto-detects git for non-tarball urls", function()
        local s = spec.parse("https://github.com/foo/bar")
        assert.are.equal("git", s.kind)
    end)

    it("rejects malformed input", function()
        assert.has_error(function() spec.parse("") end)
        assert.has_error(function() spec.parse(nil) end)
        assert.has_error(function() spec.parse("not-a-url") end)
    end)
end)
