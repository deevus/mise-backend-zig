local M = {}

function M.install(handlers)
    handlers = handlers or {}
    local recorder = { downloads = {} }
    local stub = {
        download_file = function(opts, path)
            table.insert(recorder.downloads, { url = opts.url, path = path })
            local writer = handlers[opts.url]
            if writer then writer(path) end
        end,
        get  = function() error("http.get not stubbed") end,
        head = function() error("http.head not stubbed") end,
    }
    local saved = package.loaded["http"]
    package.loaded["http"] = stub
    recorder.restore = function() package.loaded["http"] = saved end
    return recorder
end

return M
