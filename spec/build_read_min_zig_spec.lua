local build = require("lib.build")

describe("lib.build.read_min_zig", function()
    it("extracts the version when present", function()
        assert.are.equal("0.13.0", build.read_min_zig("spec/fixtures/zon/has_min.zon"))
    end)

    it("returns nil when field is absent", function()
        assert.is_nil(build.read_min_zig("spec/fixtures/zon/no_min.zon"))
    end)

    it("returns nil when file does not exist", function()
        assert.is_nil(build.read_min_zig("spec/fixtures/zon/nope.zon"))
    end)

    it("returns the first match on multiple occurrences", function()
        assert.are.equal("0.13.0", build.read_min_zig("spec/fixtures/zon/multiple.zon"))
    end)
end)
