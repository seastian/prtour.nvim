-- The dashboard: the full-window buffer `\` opens outside a tour, replacing
-- the old cursor-anchored launcher menu. This module is the feature's thin
-- impure shell — it reads progress files, queries git facts, and fetches open
-- PRs, feeds them to the pure model builder (prtour.dashboard.model), draws the
-- resulting model via the pure view (prtour.dashboard.view), and wires the
-- keymaps. It holds no feature logic: every decision comes from the model, and
-- selecting a row just dispatches back into prtour's existing tour entry points.
--
-- Resume and the local card render instantly from disk + git; the open-PR list
-- is fetched asynchronously and streams in under a spinner (ADR: parent #1).
local M = {}

local model = require 'prtour.dashboard.model'
local view = require 'prtour.dashboard.view'

local ns = vim.api.nvim_create_namespace 'prtour-dashboard'
local SPINNER = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

-- One dashboard at a time; `D` holds the open instance's live state.
local D = nil

--- The dashboard can open before any tour has defined the Prtour* groups.
local function ensure_hls()
  local function fg(group)
    local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    return ok and h.fg or nil
  end
  local defaults = {
    PrtourKicker = { fg = fg 'Comment' },
    PrtourTitle = { fg = fg 'Function', bold = true },
    PrtourDim = { fg = fg 'NonText' },
    PrtourKey = { fg = fg 'Special', bold = true },
  }
  for group, spec in pairs(defaults) do
    if vim.fn.hlexists(group) == 0 then
      vim.api.nvim_set_hl(0, group, spec)
    end
  end
end

--- Git facts for the model, gathered synchronously — all of these are local
--- git queries, so the dashboard still opens instantly.
local function git_facts()
  local function first_line(cmd)
    local out = vim.trim(vim.fn.system(cmd))
    return vim.v.shell_error == 0 and out ~= '' and out or nil
  end
  local branch = first_line { 'git', 'branch', '--show-current' } or 'detached'
  local status = vim.fn.system { 'git', 'status', '--porcelain' }
  local dirty = vim.v.shell_error == 0 and vim.trim(status) ~= ''
  local default_base = first_line { 'git', 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD' }
  return { branch = branch, dirty = dirty, default_base = default_base }
end

--- This repo's decoded progress records, each enriched with the fields the
--- model reads but the on-disk record doesn't store: its cache `key` (from the
--- filename) and `last_touched` (the file's mtime).
local function read_records(slug)
  local dir = vim.fn.stdpath 'cache' .. '/prtour'
  local records = {}
  for _, path in ipairs(vim.fn.glob(('%s/progress-%s-*.json'):format(dir, slug), false, true)) do
    local f = io.open(path, 'r')
    if f then
      local ok, saved = pcall(vim.json.decode, f:read '*a')
      f:close()
      if ok and type(saved) == 'table' then
        saved.key = vim.fn.fnamemodify(path, ':t'):gsub('^progress%-', ''):gsub('%.json$', '')
        saved.last_touched = vim.fn.getftime(path)
        records[#records + 1] = saved
      end
    end
  end
  return records
end

--- Rebuild the model from the current inputs and redraw the buffer.
local function render()
  if not (D and vim.api.nvim_buf_is_valid(D.buf)) then
    return
  end
  local m = model.build {
    slug = D.slug,
    records = D.records,
    prs = D.prs,
    git = D.git,
  }
  local v = view.render(m, {
    repo = D.repo,
    now = os.time(),
    spinner = SPINNER[D.frame],
  })
  D.entries = v.entries
  D.entry_by_line = {}
  for _, e in ipairs(v.entries) do
    D.entry_by_line[e.line] = e
  end
  vim.bo[D.buf].modifiable = true
  vim.api.nvim_buf_set_lines(D.buf, 0, -1, false, v.lines)
  vim.bo[D.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(D.buf, ns, 0, -1)
  local hl = vim.hl or vim.highlight
  for _, h in ipairs(v.hls) do
    hl.range(D.buf, ns, h.group, { h.line, h.col_start }, { h.line, h.col_end })
  end
  -- Park the cursor on the first selectable row (or keep it in range).
  if vim.api.nvim_win_is_valid(D.win) and #v.entries > 0 then
    local cur = vim.api.nvim_win_get_cursor(D.win)[1]
    if not D.entry_by_line[cur] then
      vim.api.nvim_win_set_cursor(D.win, { v.entries[1].line, 0 })
    end
  end
end

--- Advance the spinner while the PR fetch is in flight.
local function tick_spinner()
  if not D then
    return
  end
  D.frame = D.frame % #SPINNER + 1
  render()
end

local function stop_spinner()
  if D and D.timer then
    D.timer:stop()
    D.timer:close()
    D.timer = nil
  end
end

--- Kick off (or restart) the async open-PR fetch, spinning until it returns.
local function fetch_prs()
  D.prs = nil
  D.frame = 1
  stop_spinner()
  D.timer = vim.uv.new_timer()
  D.timer:start(120, 120, vim.schedule_wrap(tick_spinner))
  local token = {}
  D.token = token
  require('prtour.gh').list_prs(function(prs, err)
    -- Ignore a fetch that a refresh/close has already superseded.
    if not D or D.token ~= token then
      return
    end
    stop_spinner()
    D.prs = prs or {}
    if err then
      vim.notify('prtour: could not list PRs — ' .. err, vim.log.levels.WARN)
    end
    render()
  end)
end

local function close()
  stop_spinner()
  if D and vim.api.nvim_win_is_valid(D.win) then
    vim.api.nvim_win_close(D.win, true)
  end
  D = nil
end

--- Act on a selected row by dispatching into prtour's existing entry points.
local function dispatch(select)
  local prtour = require 'prtour'
  close()
  vim.schedule(function()
    if select.action == 'resume' then
      local r = select.resume
      if r.kind == 'pr' then
        prtour.start(r.pr)
      else
        prtour.start_local(r.base_arg)
      end
    elseif select.action == 'start_local' then
      prtour.start_local(select.base_arg)
    elseif select.action == 'start_pr' then
      prtour.start(select.number)
    end
  end)
end

--- Select the entry at the cursor line, if any.
local function choose_at_cursor()
  if not D then
    return
  end
  local e = D.entry_by_line[vim.api.nvim_win_get_cursor(D.win)[1]]
  if e then
    dispatch(e.select)
  end
end

--- Move the cursor to the next/prev selectable row (clamped at the ends).
local function move(dir)
  if not (D and #D.entries > 0) then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(D.win)[1]
  local idx
  for i, e in ipairs(D.entries) do
    if e.line == cur then
      idx = i
      break
    end
  end
  local target
  if not idx then
    target = D.entries[1]
  else
    target = D.entries[math.max(1, math.min(#D.entries, idx + dir))]
  end
  vim.api.nvim_win_set_cursor(D.win, { target.line, 0 })
end

--- Re-scan local state and re-fetch PRs, then redraw.
local function refresh()
  if not D then
    return
  end
  D.git = git_facts()
  D.records = read_records(D.slug)
  render()
  fetch_prs()
end

--- Open the dashboard for the current repo.
function M.open()
  if D then
    close()
  end
  ensure_hls()
  local prtour = require 'prtour'
  local top = vim.trim(vim.fn.system { 'git', 'rev-parse', '--show-toplevel' })
  local repo = (vim.v.shell_error == 0 and top ~= '') and vim.fn.fnamemodify(top, ':t') or 'this repo'

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'prtour-dashboard'
  -- A full-window buffer, not a cursor-anchored popup: fill the editor (minus
  -- the command line) so the dashboard reads as a screen, not a menu. The
  -- in-buffer "prtour — <repo>" header stands in for a window title.
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = math.max(1, vim.o.lines - vim.o.cmdheight - 1),
    style = 'minimal',
    border = 'none',
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  D = {
    buf = buf,
    win = win,
    repo = repo,
    slug = prtour.repo_slug(),
    git = git_facts(),
    records = nil,
    prs = nil,
    frame = 1,
    entries = {},
    entry_by_line = {},
  }
  D.records = read_records(D.slug)

  for i = 1, 9 do
    vim.keymap.set('n', tostring(i), function()
      local e = D and D.entries[i]
      if e then
        dispatch(e.select)
      end
    end, { buffer = buf })
  end
  vim.keymap.set('n', 'j', function()
    move(1)
  end, { buffer = buf })
  vim.keymap.set('n', 'k', function()
    move(-1)
  end, { buffer = buf })
  vim.keymap.set('n', '<CR>', choose_at_cursor, { buffer = buf })
  vim.keymap.set('n', 'r', refresh, { buffer = buf })
  for _, k in ipairs { 'q', '<Esc>', '\\' } do
    vim.keymap.set('n', k, close, { buffer = buf })
  end
  vim.api.nvim_create_autocmd('WinLeave', { buffer = buf, once = true, callback = close })

  render()
  fetch_prs()
end

return M
