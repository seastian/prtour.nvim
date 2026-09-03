-- Out-of-editor pings for slow async work finishing while the user is
-- in another tmux window or app.
local M = {}

---@param msg string
function M.ping(msg)
  -- Terminal bell: tmux flags the window (monitor-bell), terminals may bounce.
  pcall(vim.fn.chansend, vim.v.stderr, '\a')
  if vim.env.TMUX and vim.fn.executable 'tmux' == 1 then
    vim.system { 'tmux', 'display-message', 'prtour: ' .. msg }
  end
end

return M
