local build = require("lib.build")

describe("lib.build.resolve_zig_version", function()
    it("prefers opts.zig_version over zon", function()
        local v = build.resolve_zig_version(
            { zig_version = "0.14.0" },
            "spec/fixtures/zon/has_min.zon"
        )
        assert.are.equal("0.14.0", v)
    end)

    it("falls back to minimum_zig_version from zon", function()
        local v = build.resolve_zig_version({}, "spec/fixtures/zon/has_min.zon")
        assert.are.equal("0.13.0", v)
    end)

    it("returns nil when neither is available (active-zig tier)", function()
        local v = build.resolve_zig_version({}, "spec/fixtures/zon/no_min.zon")
        assert.is_nil(v)
    end)

    it("returns nil when zon file does not exist", function()
        local v = build.resolve_zig_version({}, "/nonexistent/build.zig.zon")
        assert.is_nil(v)
    end)
end)
