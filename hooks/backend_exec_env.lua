local build = require("lib.build")

function PLUGIN:BackendExecEnv(ctx)
    local opts = build.resolve_opts(ctx.options)
    local path
    if #opts.filter_bins > 0 then
        path = ctx.install_path .. "/.mise-bins"
    else
        path = ctx.install_path .. "/" .. opts.bin_path
    end
    return {
        env_vars = {
            { key = "PATH", value = path },
        },
    }
end
