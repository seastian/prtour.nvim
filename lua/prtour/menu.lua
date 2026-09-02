-- Tiny cursor-anchored action menu: number keys or <CR> select, q/Esc/\ close.
local M = {}

local ns = vim.api.nvim_create_namespace 'prtour-menu'

--- The menu can open before any tour has defined the Prtour* groups.
local function ensure_hls()
  local function fg(group)
    local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    return ok and h.fg or nil
  end
  if vim.fn.hlexists 'PrtourKey' == 0 then
    vim.api.nvim_set_hl(0, 'PrtourKey', { fg = fg 'Special', bold = true })
  end
  if vim.fn.hlexists 'PrtourDim' == 0 then
    vim.api.nvim_set_hl(0, 'PrtourDim', { fg = fg 'NonText' })
  end
end

---@param items {label: string, hint: string|nil, fn: function}[]
function M.open(items)
  if #items == 0 then
    return
  end
  ensure_hls()
  local width = 30
  local rows = {}
  for i, it in ipairs(items) do
    rows[i] = { left = (' %d  %s'):format(i, it.label), hint = it.hint or '' }
    width = math.max(width, vim.fn.strdisplaywidth(rows[i].left) + vim.fn.strdisplaywidth(rows[i].hint) + 3)
  end
  local lines = {}
  for i, r in ipairs(rows) do
    local pad = width - vim.fn.strdisplaywidth(r.left) - vim.fn.strdisplaywidth(r.hint) - 1
    lines[i] = r.left .. (' '):rep(pad) .. r.hint .. ' '
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local hl = vim.hl or vim.highlight
  for i, r in ipairs(rows) do
    hl.range(buf, ns, 'PrtourKey', { i - 1, 0 }, { i - 1, 3 })
    if r.hint ~= '' then
      hl.range(buf, ns, 'PrtourDim', { i - 1, #lines[i] - #r.hint - 1 }, { i - 1, -1 })
    end
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = #items,
    style = 'minimal',
    border = 'rounded',
    title = ' actions ',
    title_pos = 'center',
  })
  vim.wo[win].cursorline = true
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local function choose(i)
    local it = items[i]
    close()
    if it then
      vim.schedule(it.fn)
    end
  end
  for i = 1, math.min(#items, 9) do
    vim.keymap.set('n', tostring(i), function()
      choose(i)
    end, { buffer = buf })
  end
  vim.keymap.set('n', '<CR>', function()
    choose(vim.api.nvim_win_get_cursor(0)[1])
  end, { buffer = buf })
  for _, k in ipairs { 'q', '<Esc>', '\\' } do
    vim.keymap.set('n', k, close, { buffer = buf })
  end
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = close,
  })
end

return M
