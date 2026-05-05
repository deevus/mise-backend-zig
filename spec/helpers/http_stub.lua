local M = {}

function M.install(handlers, head_handlers)
    handlers = handlers or {}
    head_handlers = head_handlers or {}
    local recorder = { downloads = {}, heads = {} }
    local function record_download(opts, path)
        table.insert(recorder.downloads, { url = opts.url, path = path })
        local writer = handlers[opts.url]
        if writer then
            writer(path)
        end
    end
    local stub = {
        download_file = record_download,
        try_download_file = function(opts, path)
            record_download(opts, path)
            return true, nil
        end,
        get = function()
            error("http.get not stubbed")
        end,
        head = function()
            error("http.head not stubbed")
        end,
        -- Production code uses try_head (the error-returning variant) because
        -- mise's async http.head can't be pcall'd. Returns canned resp or nil+err.
        try_head = function(opts)
            table.insert(recorder.heads, { url = opts.url })
            local resp = head_handlers[opts.url]
            if resp == nil then
                return nil, "no canned head response for " .. tostring(opts.url)
            end
            return resp, nil
        end,
    }
    local saved = package.loaded["http"]
    package.loaded["http"] = stub
    recorder.restore = function()
        package.loaded["http"] = saved
    end
    return recorder
end

return M
