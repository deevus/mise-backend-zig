local git = require("lib.git")

describe("lib.git.parse_tag_refs", function()
    it("returns empty list for empty input", function()
        assert.are.same({}, git.parse_tag_refs(""))
    end)

    it("dedups annotated-tag peeled refs (regression: github.com/neurosnap/zmx)", function()
        -- Real `git ls-remote --tags` output shape: every annotated tag appears
        -- twice, once as the tag ref and once as `<ref>^{}` for the commit it
        -- points at. Lightweight tags appear once.
        local out = table.concat({
            "abc123\trefs/tags/v0.0.1", -- lightweight: one line
            "def456\trefs/tags/v0.0.2", -- annotated: two lines
            "789aaa\trefs/tags/v0.0.2^{}",
            "fff111\trefs/tags/v0.1.0",
            "fff112\trefs/tags/v0.1.0^{}",
        }, "\n") .. "\n"
        assert.are.same({ "v0.0.1", "v0.0.2", "v0.1.0" }, git.parse_tag_refs(out))
    end)

    it("filters non-semver tag names", function()
        local out = table.concat({
            "aaa\trefs/tags/release-2024",
            "bbb\trefs/tags/v1.2.3",
            "ccc\trefs/tags/nightly",
            "ddd\trefs/tags/1.0.0",
        }, "\n")
        assert.are.same({ "v1.2.3", "1.0.0" }, git.parse_tag_refs(out))
    end)

    it("preserves source order (semver.sort handles ordering separately)", function()
        local out = table.concat({
            "a\trefs/tags/v2.0.0",
            "b\trefs/tags/v1.0.0",
            "c\trefs/tags/v3.0.0",
        }, "\n")
        assert.are.same({ "v2.0.0", "v1.0.0", "v3.0.0" }, git.parse_tag_refs(out))
    end)
end)
