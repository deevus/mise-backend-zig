local build = require("lib.build")

describe("lib.build.empty_bin_error", function()
    local msg = build.empty_bin_error("/tmp/install/bin")

    it("includes the offending path", function()
        assert.is_truthy(msg:find("/tmp/install/bin", 1, true))
    end)

    it("mentions bin_path as a remediation", function()
        assert.is_truthy(msg:find("bin_path", 1, true))
    end)

    it("mentions installArtifact as a remediation", function()
        assert.is_truthy(msg:find("installArtifact", 1, true))
    end)
end)
