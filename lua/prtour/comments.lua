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
    comments[#comments + 1] = {
      path = path,
      side = side,
      line = end_line,
      start_line = start_line ~= end_line and start_line or nil,
      body = body,
    }
    pcall(vim.api.nvim_buf_set_extmark, target_buf, ns, end_line - 1, 0, {
      virt_text = { { ' 💬 ' .. vim.split(body, '\n')[1]:sub(1, 48), 'Comment' } },
      virt_text_pos = 'eol',
    })
    vim.notify(('prtour: comment queued (%d pending)'):format(#comments))
  end, { buffer = buf })
  vim.cmd 'startinsert'
end

--- Submit all queued comments as one PR review.
---@param opts {pr: integer, sha: string, event: string|nil, body: string|nil}
---@param cb fun(ok: boolean, err: string|nil)
function M.submit(opts, cb)
  local payload = { commit_id = opts.sha, body = opts.body or '', comments = {} }
  if opts.event then
    payload.event = opts.event
  end
  for _, c in ipairs(comments) do
    local item = { path = c.path, body = c.body, line = c.line, side = c.side }
    if c.start_line then
      item.start_line = c.start_line
      item.start_side = c.side
    end
    payload.comments[#payload.comments + 1] = item
  end
  vim.system(
    { 'gh', 'api', ('repos/{owner}/{repo}/pulls/%d/reviews'):format(opts.pr), '--method', 'POST', '--input', '-' },
    { text = true, stdin = vim.json.encode(payload) },
    function(out)
      vim.schedule(function()
        if out.code ~= 0 then
          return cb(false, vim.trim(out.stderr or 'gh api failed'))
        end
        M.reset()
        cb(true)
      end)
    end
  )
end

return M
