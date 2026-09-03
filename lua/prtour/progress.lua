-- Progress indicator: fidget.nvim spinner when available, vim.notify fallback.
local M = {}

---@class prtour.Progress
---@field report fun(self, msg: string)
---@field finish fun(self, msg: string|nil)
---@field fail fun(self, msg: string)

---@param title string
---@return prtour.Progress
function M.start(title)
  local ok, fidget = pcall(require, 'fidget.progress')
  if ok then
    local handle = fidget.handle.create { title = title, lsp_client = { name = 'prtour' } }
    return {
      report = function(_, msg)
        handle:report { message = msg }
      end,
      finish = function(_, msg)
        if msg then
          handle:report { message = msg }
        end
        handle:finish()
      end,
      fail = function(_, msg)
        handle:cancel()
        vim.notify('prtour: ' .. msg, vim.log.levels.ERROR)
      end,
    }
  end
  vim.notify('prtour: ' .. title .. '…')
  return {
    -- Without fidget, show live status on the command line — transient (kept
    -- out of :messages) so a streaming step's ticking updates don't pile up.
    report = function(_, msg)
      vim.api.nvim_echo({ { 'prtour: ' .. msg } }, false, {})
    end,
    finish = function(_, msg)
      if msg then
        vim.notify('prtour: ' .. msg)
      end
    end,
    fail = function(_, msg)
      vim.notify('prtour: ' .. msg, vim.log.levels.ERROR)
    end,
  }
end

return M
