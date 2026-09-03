-- Existing GitHub review threads: inline display and replies.
local M = {}

local ns = vim.api.nvim_create_namespace 'prtour-threads'
local by_path = {}

---@param threads table[] as returned by gh.review_threads
function M.set(threads)
  by_path = {}
  for _, t in ipairs(threads) do
    if not t.is_resolved and t.line and #t.comments > 0 then
      by_path[t.path] = by_path[t.path] or {}
      table.insert(by_path[t.path], t)
    end
  end
end

function M.clear()
  by_path = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
end

--- Render this file's unresolved threads as virtual lines above their anchor.
---@param buf integer
---@param path string repo-relative path
function M.decorate(buf, path)
  local util = require('prtour.util')
  local width = util.annotation_width()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, t in ipairs(by_path[path] or {}) do
    local virt = {}
    for ci, c in ipairs(t.comments) do
      local tag = c.pending and ' · pending' or ''
      if ci == 1 and t.start_line then
        tag = tag .. (' (lines %d–%d)'):format(t.start_line, t.line)
      end
      local hl = c.pending and 'DiagnosticVirtualTextWarn' or 'DiagnosticVirtualTextInfo'
      for bi, bl in ipairs(util.wrap(c.body, width)) do
        local prefix = bi == 1 and ('┃ 💬 %s%s: '):format(c.author, tag) or '┃ '
        virt[#virt + 1] = { { prefix .. bl, hl } }
      end
    end
    if t.start_line then
      -- Continue the block's ┃ inline through the covered lines.
      local bar_hl = t.comments[1] and t.comments[1].pending and 'DiagnosticVirtualTextWarn' or 'DiagnosticVirtualTextInfo'
      local last = math.min(t.line, vim.api.nvim_buf_line_count(buf))
      for ln = t.start_line, last do
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, ln - 1, 0, {
          virt_text = { { '┃ ', bar_hl } },
          virt_text_pos = 'inline',
        })
      end
    end
    if t.is_outdated then
      virt[#virt + 1] = { { '┃ (outdated — code has changed since)', 'NonText' } }
    end
    local lnum = math.min(t.line, vim.api.nvim_buf_line_count(buf)) - 1
    -- virt_lines above line 1 render off-screen; put them below instead.
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum, 0, { virt_lines = virt, virt_lines_above = lnum > 0 })
  end
end

--- Thread anchored at (or nearest above) the cursor line.
---@return table|nil thread, string path, string bufname
local function thread_at_cursor()
  local name = vim.api.nvim_buf_get_name(0)
  local path = name:match '^prtour://deleted/(.+)$'
  if not path then
    local top = vim.trim(vim.fn.system { 'git', 'rev-parse', '--show-toplevel' })
    path = vim.startswith(name, top .. '/') and name:sub(#top + 2) or vim.fn.fnamemodify(name, ':.')
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local best
  for _, t in ipairs(by_path[path] or {}) do
    if t.line <= lnum and (not best or t.line > best.line) then
      best = t
    end
  end
  return best, path, name
end

--- What exists at the cursor line: a thread, and any comment of the viewer's.
---@return {thread: boolean, own: boolean}
function M.at_cursor_info()
  local best = thread_at_cursor()
  local own = false
  if best then
    for _, c in ipairs(best.comments) do
      if c.mine and c.id then
        own = true
        break
      end
    end
  end
  return { thread = best ~= nil, own = own }
end

--- Edit or delete the viewer's own comment in the thread at the cursor.
---@return boolean handled false when no own comment is here
function M.edit_own_at_cursor()
  local best, path, bufname = thread_at_cursor()
  if not best then
    return false
  end
  local target
  for i = #best.comments, 1, -1 do
    if best.comments[i].mine and best.comments[i].id then
      target = best.comments[i]
      break
    end
  end
  if not target then
    return false
  end
  local gh = require('prtour.gh')
  local target_buf = vim.fn.bufnr(bufname)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(target.body, '\n'))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = 72,
    height = 6,
    style = 'minimal',
    border = 'rounded',
    title = ' edit GitHub comment · <CR> save · D delete · q cancel ',
    title_pos = 'center',
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local function redraw()
    if target_buf ~= -1 then
      M.decorate(target_buf, path)
    end
  end
  vim.keymap.set('n', 'q', close, { buffer = buf })
  vim.keymap.set('n', '<CR>', function()
    local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
    close()
    if body == '' then
      return
    end
    gh.update_review_comment(target.id, body, function(ok, err)
      if not ok then
        return vim.notify('prtour: edit failed: ' .. err, vim.log.levels.ERROR)
      end
      target.body = body
      redraw()
      vim.notify 'prtour: comment updated on GitHub'
    end)
  end, { buffer = buf })
  vim.keymap.set('n', 'D', function()
    close()
    gh.delete_review_comment(target.id, function(ok, err)
      if not ok then
        return vim.notify('prtour: delete failed: ' .. err, vim.log.levels.ERROR)
      end
      for i, c in ipairs(best.comments) do
        if c == target then
          table.remove(best.comments, i)
          break
        end
      end
      if #best.comments == 0 then
        for i, t in ipairs(by_path[path] or {}) do
          if t == best then
            table.remove(by_path[path], i)
            break
          end
        end
      end
      redraw()
      vim.notify 'prtour: comment deleted on GitHub'
    end)
  end, { buffer = buf })
  return true
end

--- Reply to the thread anchored at (or nearest above) the cursor line.
---@param pr integer
function M.reply_at_cursor(pr)
  local best, path, name = thread_at_cursor()
  if not best then
    return vim.notify('prtour: no thread at or above this line', vim.log.levels.WARN)
  end
  local target
  for _, c in ipairs(best.comments) do
    if c.database_id and not c.pending then
      target = c
      break
    end
  end
  if not target then
    return vim.notify('prtour: thread only has your pending comment — nothing to reply to yet', vim.log.levels.WARN)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].bufhidden = 'wipe'
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = 72,
    height = 6,
    style = 'minimal',
    border = 'rounded',
    title = (' reply to %s · <CR> send · q discard '):format(target.author),
    title_pos = 'center',
  })
  local target_buf = vim.fn.bufnr(name)
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set('n', 'q', close, { buffer = buf })
  vim.keymap.set('n', '<CR>', function()
    local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
    close()
    if body == '' then
      return
    end
    require('prtour.gh').reply(pr, target.database_id, body, function(ok, err)
      if not ok then
        return vim.notify('prtour: reply failed: ' .. err, vim.log.levels.ERROR)
      end
      table.insert(best.comments, { author = 'you', body = body, pending = false })
      if target_buf ~= -1 then
        M.decorate(target_buf, path)
      end
      vim.notify 'prtour: reply posted'
    end)
  end, { buffer = buf })
  vim.cmd 'startinsert'
end

return M
