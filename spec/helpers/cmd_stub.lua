local M = {}

--- Replace the global `require("cmd")` with a stub that records calls
--- and returns canned output.
--- @param canned table<integer|string, string|{fail: boolean}> Optional canned outputs keyed by command substring.
--- @return { calls: string[], restore: fun() }
function M.install(canned)
    canned = canned or {}
    local recorder = { calls = {} }
    local stub = {
        exec = function(command)
            table.insert(recorder.calls, command)
            for pat, out in pairs(canned) do
                if type(pat) == "string" and command:find(pat, 1, true) then
                    if type(out) == "table" and out.fail then
                        error("stubbed cmd.exec failure: " .. command)
                    end
                    return out
                end
            end
            return ""
        end,
    }
    local saved = package.loaded["cmd"]
    package.loaded["cmd"] = stub
    recorder.restore = function() package.loaded["cmd"] = saved end
    return recorder
end

return M
