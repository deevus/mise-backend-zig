local build = require("lib.build")

local function reader(env)
    return function(name)
        return env[name]
    end
end

describe("lib.build.resolve_opts", function()
    it("returns defaults when nothing is set", function()
        local opts = build.resolve_opts(nil, reader({}))
        assert.is_nil(opts.zig_version)
        assert.is_nil(opts.optimize)
        assert.are.same({}, opts.build_args)
        assert.is_true(opts.auto_install_zig)
        assert.are.equal("bin", opts.bin_path)
        assert.are.same({}, opts.filter_bins)
    end)

    it("reads scalars from env vars", function()
        local opts = build.resolve_opts(
            nil,
            reader({
                MISE_ZIG_BACKEND_ZIG_VERSION = "0.14.0",
                MISE_ZIG_BACKEND_OPTIMIZE = "ReleaseFast",
                MISE_ZIG_BACKEND_BIN_PATH = "tools",
            })
        )
        assert.are.equal("0.14.0", opts.zig_version)
        assert.are.equal("ReleaseFast", opts.optimize)
        assert.are.equal("tools", opts.bin_path)
    end)

    it("whitespace-splits array env vars", function()
        local opts = build.resolve_opts(
            nil,
            reader({
                MISE_ZIG_BACKEND_BUILD_ARGS = "-Dstrip=true -Dcpu=native",
                MISE_ZIG_BACKEND_FILTER_BINS = "myapp helper",
            })
        )
        assert.are.same({ "-Dstrip=true", "-Dcpu=native" }, opts.build_args)
        assert.are.same({ "myapp", "helper" }, opts.filter_bins)
    end)

    it("reads scalars from ctx.options", function()
        local opts =
            build.resolve_opts({ zig_version = "0.13.0", optimize = "ReleaseSafe", bin_path = "out" }, reader({}))
        assert.are.equal("0.13.0", opts.zig_version)
        assert.are.equal("ReleaseSafe", opts.optimize)
        assert.are.equal("out", opts.bin_path)
    end)

    it("reads array opts from ctx.options as Lua sequences", function()
        local opts = build.resolve_opts(
            { build_args = { "-Dfoo=bar", "-Dpath=/some path" }, filter_bins = { "myapp" } },
            reader({})
        )
        assert.are.same({ "-Dfoo=bar", "-Dpath=/some path" }, opts.build_args)
        assert.are.same({ "myapp" }, opts.filter_bins)
    end)

    it("ctx.options wins over env vars (scalars and arrays)", function()
        local opts = build.resolve_opts(
            { zig_version = "0.14.0", build_args = { "-Dfoo=bar" } },
            reader({
                MISE_ZIG_BACKEND_ZIG_VERSION = "0.13.0",
                MISE_ZIG_BACKEND_BUILD_ARGS = "-Dignored=true",
            })
        )
        assert.are.equal("0.14.0", opts.zig_version)
        assert.are.same({ "-Dfoo=bar" }, opts.build_args)
    end)

    it("env fills in for keys missing from ctx.options", function()
        local opts =
            build.resolve_opts({ zig_version = "0.14.0" }, reader({ MISE_ZIG_BACKEND_OPTIMIZE = "ReleaseFast" }))
        assert.are.equal("0.14.0", opts.zig_version)
        assert.are.equal("ReleaseFast", opts.optimize)
    end)

    it("disables auto_install_zig via ctx.options boolean", function()
        local opts = build.resolve_opts({ auto_install_zig = false }, reader({}))
        assert.is_false(opts.auto_install_zig)
    end)

    it("disables auto_install_zig via env '0' or 'false'", function()
        local a = build.resolve_opts(nil, reader({ MISE_ZIG_BACKEND_AUTO_INSTALL_ZIG = "0" }))
        local b = build.resolve_opts(nil, reader({ MISE_ZIG_BACKEND_AUTO_INSTALL_ZIG = "false" }))
        assert.is_false(a.auto_install_zig)
        assert.is_false(b.auto_install_zig)
    end)

    -- Regression: TOML can present booleans/numbers as native Lua types, not strings.
    -- Earlier impl crashed on `v:lower()` when v was a number.
    it("handles numeric 0/1 for auto_install_zig without crashing", function()
        local zero = build.resolve_opts({ auto_install_zig = 0 }, reader({}))
        local one = build.resolve_opts({ auto_install_zig = 1 }, reader({}))
        assert.is_false(zero.auto_install_zig)
        assert.is_true(one.auto_install_zig)
    end)

    it("trust_mise_toml defaults to false", function()
        local opts = build.resolve_opts(nil, reader({}))
        assert.is_false(opts.trust_mise_toml)
    end)

    it("trust_mise_toml accepts boolean from ctx.options", function()
        local enabled = build.resolve_opts({ trust_mise_toml = true }, reader({}))
        assert.is_true(enabled.trust_mise_toml)
    end)

    it("trust_mise_toml reads from env var", function()
        local opts = build.resolve_opts(nil, reader({ MISE_ZIG_BACKEND_TRUST_MISE_TOML = "1" }))
        assert.is_true(opts.trust_mise_toml)
    end)
end)
