local M = {}

-- Visible only with --verbose. log.info goes through vfox's log module which
-- mise filters out at default verbosity, keeping the spinner UI clean.
-- pcall'd because specs require lib code without the vfox runtime present.
-- Timestamp prefix lets users diagnose where time is going across HEAD, GET,
-- shasum, tar, and zig build — minute-scale waits are easy to spot when each
-- line is dated.
function M.info(msg)
    local ok, log = pcall(require, "log")
    if ok and log and log.info then
        log.info(string.format("[%s] %s", os.date("%H:%M:%S"), msg))
    end
end

return M
