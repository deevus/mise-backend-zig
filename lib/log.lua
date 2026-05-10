local M = {}

-- pcall'd because specs require lib code without the vfox runtime present.
-- Timestamp prefix lets users diagnose where time is going across HEAD, GET,
-- shasum, tar, and zig build — minute-scale waits are easy to spot when each
-- line is dated.
local function emit(level, msg)
    local ok, log = pcall(require, "log")
    if ok and log and log[level] then
        log[level](string.format("[%s] %s", os.date("%H:%M:%S"), msg))
    end
end

function M.info(msg)
    emit("info", msg)
end

function M.error(msg)
    emit("error", msg)
end

return M
