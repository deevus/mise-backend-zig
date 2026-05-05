local M = {}

--- POSIX-shell-quote a single token: wrap in single quotes, escape internal '.
function M.shquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

return M
