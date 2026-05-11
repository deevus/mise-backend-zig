local source = require("lib.source")
local cmd_stub = require("spec.helpers.cmd_stub")

describe("lib.source.fetch_git", function()
    local rec
    before_each(function()
        rec = cmd_stub.install({})
    end)
    after_each(function()
        rec.restore()
    end)

    it("clones with --depth 1 --branch <ref> for tag-shaped refs (POSIX-quoted)", function()
        source.fetch_git("https://github.com/foo/bar", "v1.2.3", "/tmp/srcdir")
        local c = rec.calls[#rec.calls]
        assert.is_truthy(c:find("git clone", 1, true))
        assert.is_truthy(c:find("--depth 1", 1, true))
        assert.is_truthy(c:find("--branch 'v1.2.3'", 1, true))
        assert.is_truthy(c:find("'https://github.com/foo/bar'", 1, true))
        assert.is_truthy(c:find("'/tmp/srcdir'", 1, true))
    end)

    it("falls back to --branch v<ref> on first attempt failure", function()
        rec.restore()
        rec = cmd_stub.install({
            ["--branch '1.2.3'"] = { fail = true },
        })
        source.fetch_git("https://github.com/foo/bar", "1.2.3", "/tmp/srcdir")
        -- 3 calls: failed clone, rm -rf cleanup, retry clone with v-prefix
        assert.are.equal(3, #rec.calls)
        assert.is_truthy(rec.calls[1]:find("--branch '1.2.3'", 1, true))
        assert.is_truthy(rec.calls[2]:find("rm -rf", 1, true))
        assert.is_truthy(rec.calls[3]:find("--branch 'v1.2.3'", 1, true))
    end)

    it("does not add a second v-prefix when a v-prefixed ref is missing", function()
        rec.restore()
        rec = cmd_stub.install({
            ["--branch 'v1.2.3'"] = { fail = true },
        })
        assert.has_error(function()
            source.fetch_git("https://github.com/foo/bar", "v1.2.3", "/tmp/srcdir")
        end)
        assert.are.equal(1, #rec.calls)
        assert.is_truthy(rec.calls[1]:find("--branch 'v1.2.3'", 1, true))
    end)

    it("clone-then-checkout for SHA-shaped refs", function()
        source.fetch_git("https://github.com/foo/bar", "abc1234567890def1234567890abcdef12345678", "/tmp/srcdir")
        assert.are.equal(2, #rec.calls)
        assert.is_truthy(rec.calls[1]:find("git clone", 1, true))
        assert.is_falsy(rec.calls[1]:find("--branch", 1, true))
        assert.is_truthy(rec.calls[2]:find("git -C '/tmp/srcdir' checkout 'abc1234", 1, true))
    end)

    it("plain clone (no --branch) for HEAD", function()
        source.fetch_git("https://github.com/foo/bar", "HEAD", "/tmp/srcdir")
        local c = rec.calls[#rec.calls]
        assert.is_truthy(c:find("git clone", 1, true))
        assert.is_falsy(c:find("--branch", 1, true))
    end)

    -- Regression: refs with shell metacharacters must be quoted, not interpolated raw.
    it("quotes refs containing shell metacharacters", function()
        source.fetch_git("https://example.com/x", "ref;with;semicolons", "/tmp/srcdir")
        local c = rec.calls[#rec.calls]
        assert.is_truthy(c:find("--branch 'ref;with;semicolons'", 1, true))
    end)
end)
