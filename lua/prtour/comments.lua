-- Local review comments, batched into one GitHub review on submit.
local M = {}

local ns = vim.api.nvim_create_namespace 'prtour-comments'
local comments = {}

function M.reset()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  comments = {}
end

function M.count()
  return #comments
end

function M.all()
  return comments
end

--- Re-resolve comment lines from their extmarks: buffer edits made after
--- queueing move the visible mark, and the stored line must follow it.
function M.refresh_positions()
  for _, c in ipairs(comments) do
    if c.extmark_id and c.bufnr and vim.api.nvim_buf_is_valid(c.bufnr) then
      local pos = vim.api.nvim_buf_get_extmark_by_id(c.bufnr, ns, c.extmark_id, {})
      if pos and pos[1] then
        local new_line = pos[1] + 1
        if c.start_line then
          c.start_line = c.start_line + (new_line - c.line)
        end
        c.line = new_line
      end
    end
  end
end

local function repo_relative(name)
  local top = vim.trim(vim.fn.system { 'git', 'rev-parse', '--show-toplevel' })
  if vim.startswith(name, top .. '/') then
    return name:sub(#top + 2)
  end
  return vim.fn.fnamemodify(name, ':.')
end

--- Comment target of the current buffer: repo path + diff side.
local function target_for_current_buf()
  local name = vim.api.nvim_buf_get_name(0)
  local deleted = name:match '^prtour://deleted/(.+)$'
  if deleted then
    return deleted, 'LEFT'
  end
  return repo_relative(name), 'RIGHT'
end

--- Render (or re-render) a queued comment's inline preview.
---@param c table
local function place_mark(c)
  if not (c.bufnr and vim.api.nvim_buf_is_valid(c.bufnr)) then
    return
  end
  local virt = {}
  for bi, bl in ipairs(vim.split(c.body, '\n')) do
    virt[#virt + 1] = { { (bi == 1 and '┃ 💬 queued: ' or '┃ ') .. bl, 'DiagnosticVirtualTextWarn' } }
  end
  -- virt_lines above line 1 render off-screen; put them below instead.
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, c.bufnr, ns, c.line - 1, 0, {
    id = c.extmark_id,
    virt_lines = virt,
    virt_lines_above = c.line > 1,
  })
  if ok then
    c.extmark_id = id
  end
end

--- Open an input float to comment on a line range of the current buffer.
---@param start_line integer
---@param end_line integer
function M.add(start_line, end_line)
  local path, side = target_for_current_buf()
  local target_buf = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].bufhidden = 'wipe'
  local loc = start_line == end_line and tostring(end_line) or (start_line .. '-' .. end_line)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = 72,
    height = 6,
    style = 'minimal',
    border = 'rounded',
    title = (' comment %s:%s · <CR> queue · q discard '):format(vim.fn.fnamemodify(path, ':t'), loc),
    title_pos = 'center',
  })
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
    local c = {
      path = path,
      side = side,
      line = end_line,
      start_line = start_line ~= end_line and start_line or nil,
      body = body,
      bufnr = target_buf,
    }
    comments[#comments + 1] = c
    place_mark(c)
    vim.notify(('prtour: comment queued (%d pending)'):format(#comments))
    pcall(function()
      require('prtour.tour').refresh()
    end)
  end, { buffer = buf })
  vim.cmd 'startinsert'
end

---@return integer|nil idx, table|nil comment
local function find_at_cursor()
  local path = target_for_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local idx, c
  for i, cc in ipairs(comments) do
    if cc.path == path and lnum >= (cc.start_line or cc.line) and lnum <= cc.line then
      idx, c = i, cc
    end
  end
  return idx, c
end

function M.has_at_cursor()
  return (find_at_cursor()) ~= nil
end

--- Edit or delete the queued comment under the cursor.
---@return boolean handled false when no queued comment is here
function M.edit_at_cursor()
  local idx, c = find_at_cursor()
  if not c then
    return false
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(c.body, '\n'))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = 72,
    height = 6,
    style = 'minimal',
    border = 'rounded',
    title = ' edit queued comment · <CR> save · D delete · q cancel ',
    title_pos = 'center',
  })
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
    c.body = body
    place_mark(c)
    vim.notify 'prtour: comment updated'
  end, { buffer = buf })
  vim.keymap.set('n', 'D', function()
    close()
    table.remove(comments, idx)
    if c.extmark_id and c.bufnr and vim.api.nvim_buf_is_valid(c.bufnr) then
      vim.api.nvim_buf_del_extmark(c.bufnr, ns, c.extmark_id)
    end
    vim.notify(('prtour: comment deleted (%d pending)'):format(#comments))
    pcall(function()
      require('prtour.tour').refresh()
    end)
  end, { buffer = buf })
  return true
end

--- Upload queued comments into the viewer's pending review (creating one if
--- needed), then finalize it when an event is given. Repeat calls with no
--- event keep appending to the same pending review ("save as you go").
---@param opts {pr: integer, pr_id: string|nil, event: string|nil, body: string|nil}
---@param cb fun(ok: boolean, err: string|nil)
function M.submit(opts, cb)
  M.refresh_positions()
  local gh = require('prtour.gh')
  local function with_review(review_id)
    local i = 0
    local function send_next()
      i = i + 1
      local c = comments[i]
      if not c then
        if opts.event then
          return gh.submit_review(review_id, opts.event, opts.body, function(ok, err)
            if not ok then
              return cb(false, 'review submit failed: ' .. err)
            end
            M.reset()
            cb(true)
          end)
        end
        M.reset()
        return cb(true)
      end
      gh.add_review_thread(review_id, c, function(ok, err)
        if not ok then
          -- Keep the unsent tail so nothing written is lost.
          local rest = {}
          for j = i, #comments do
            rest[#rest + 1] = comments[j]
          end
          comments = rest
          return cb(false, ('comment %d failed: %s — %d unsent comments kept'):format(i, err, #rest))
        end
        send_next()
      end)
    end
    send_next()
  end
  gh.pending_review_id(opts.pr, function(rid, err)
    if err then
      return cb(false, err)
    end
    if rid then
      return with_review(rid)
    end
    local function create(pr_node_id)
      gh.create_pending_review(pr_node_id, function(id, err2)
        if not id then
          return cb(false, 'could not open a pending review: ' .. (err2 or '?'))
        end
        with_review(id)
      end)
    end
    if opts.pr_id then
      return create(opts.pr_id)
    end
    gh.pr_meta(opts.pr, function(meta, err2)
      if not meta then
        return cb(false, err2)
      end
      create(meta.id)
    end)
  end)
end

return M
