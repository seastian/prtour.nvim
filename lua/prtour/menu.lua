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
  -- Dodge the HUD: shift left of it, or drop below it, never overlap.
  local row_off, col_off = 1, 0
  local ok_tour, tour = pcall(require, 'prtour.tour')
  local rect = ok_tour and tour.hud_rect and tour.hud_rect() or nil
  if rect then
    local sp = vim.fn.screenpos(0, vim.fn.line '.', vim.fn.col '.')
    local top = sp.row + row_off
    local bottom = top + #items + 1
    local left = sp.col - 1
    local right = left + width + 1
    if bottom >= rect.top - 1 and top <= rect.bottom + 1 and right >= rect.left then
      col_off = rect.left - right - 1
      if left + col_off < 0 then
        -- No room to the left; open below the HUD instead.
        col_off = 0
        row_off = rect.bottom + 2 - sp.row
      end
    end
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = row_off,
    col = col_off,
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
