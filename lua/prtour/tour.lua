-- The active review tour: ordered hunk queue, navigation, progress tracking.
local M = {}

local state = nil

local hud = { buf = nil, win = nil }
local ns = vim.api.nvim_create_namespace 'prtour'

---@param text string
---@param width integer
---@return string[]
local function wrap_text(text, width)
  local lines, line = {}, ''
  local function flush()
    if line ~= '' then
      lines[#lines + 1] = line
      line = ''
    end
  end
  for word in text:gmatch '%S+' do
    -- Hard-break words wider than the panel; a soft-wrapped buffer line
    -- would push the last HUD row out of the float.
    while vim.fn.strdisplaywidth(word) > width do
      flush()
      lines[#lines + 1] = vim.fn.strcharpart(word, 0, width)
      word = vim.fn.strcharpart(word, width)
    end
    if line == '' then
      line = word
    elseif vim.fn.strdisplaywidth(line .. ' ' .. word) <= width then
      line = line .. ' ' .. word
    else
      flush()
      line = word
    end
  end
  flush()
  return lines
end

local function progress_path(key)
  local dir = vim.fn.stdpath 'cache' .. '/prtour'
  vim.fn.mkdir(dir, 'p')
  return ('%s/progress-%s.json'):format(dir, key)
end

local function save_progress()
  if not (state and state.key) then
    return
  end
  local seen = vim.tbl_keys(state.seen)
  table.sort(seen)
  local f = io.open(progress_path(state.key), 'w')
  if f then
    f:write(vim.json.encode {
      pos = state.pos,
      sha = state.sha,
      seen = seen,
      label = state.label,
      total = #state.flat,
      resume = state.resume,
    })
    f:close()
  end
end

local function load_progress(key)
  local f = io.open(progress_path(key), 'r')
  if not f then
    return nil
  end
  local ok, saved = pcall(vim.json.decode, f:read '*a')
  f:close()
  return ok and type(saved) == 'table' and saved or nil
end

local function close_hud()
  if hud.win and vim.api.nvim_win_is_valid(hud.win) then
    vim.api.nvim_win_close(hud.win, true)
  end
  hud.win = nil
end

local function fg_of(group)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  return ok and h.fg or nil
end

local function leader_disp()
  local l = vim.g.mapleader
  return (l == nil or l == '') and '\\' or l == ' ' and '␣' or l
end

--- HUD palette, derived from the active colorscheme.
local function define_hls()
  vim.api.nvim_set_hl(0, 'PrtourKicker', { fg = fg_of 'Comment' })
  vim.api.nvim_set_hl(0, 'PrtourTitle', { fg = fg_of 'Function', bold = true })
  vim.api.nvim_set_hl(0, 'PrtourDim', { fg = fg_of 'NonText' })
  vim.api.nvim_set_hl(0, 'PrtourKey', { fg = fg_of 'Special', bold = true })
  vim.api.nvim_set_hl(0, 'PrtourNext', { fg = fg_of 'Comment', italic = true })
  vim.api.nvim_set_hl(0, 'PrtourAdded', { fg = fg_of 'Added' or fg_of 'String', bold = true })
  vim.api.nvim_set_hl(0, 'PrtourRemoved', { fg = fg_of 'Removed' or fg_of 'Error', bold = true })
  vim.api.nvim_set_hl(0, 'PrtourFlash', { link = 'IncSearch' })
end

local saved_maps = {}
local update_hud_side
local refresh_threads

--- Run `action`, except in buffers where the key has a real job (quickfix,
--- cmdline window, terminals...) — there, replay the key unmapped.
local function unless_special(action, key)
  return function()
    local bt = vim.bo.buftype
    if vim.fn.getcmdwintype() ~= '' or bt == 'quickfix' or bt == 'prompt' or bt == 'terminal' or bt == 'help' then
      local raw = vim.api.nvim_replace_termcodes(key, true, false, true)
      return vim.api.nvim_feedkeys(raw, 'n', false)
    end
    action()
  end
end

local function gitsigns()
  local ok, gs = pcall(require, 'gitsigns')
  return ok and gs or nil
end

--- Side-by-side vimdiff of the current file against the tour base.
local function open_split(retries)
  local gs = gitsigns()
  if not (gs and state) then
    return
  end
  local h = state.pos >= 1 and state.by_id[state.flat[state.pos].id] or nil
  if h and h.added then
    return vim.notify('prtour: file is new in this PR — no base version to diff against', vim.log.levels.INFO)
  end
  -- diffthis silently fails until gitsigns has attached AND computed the
  -- base-revision text (async after our change_base); retry until it's ready.
  local buf = vim.api.nvim_get_current_buf()
  local ok, cache = pcall(require, 'gitsigns.cache')
  local bcache = ok and cache.cache[buf] or nil
  if ok and not (bcache and bcache.compare_text) then
    retries = retries or 0
    if retries >= 25 then
      return vim.notify('prtour: gitsigns could not load this file (not tracked at the base?)', vim.log.levels.WARN)
    end
    return vim.defer_fn(function()
      if state and vim.api.nvim_get_current_buf() == buf then
        open_split(retries + 1)
      end
    end, 200)
  end
  gs.diffthis(state.base)
end

--- Close the gitsigns base-version window; diff mode resets automatically.
local function close_split()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
    if name:match '^gitsigns://' then
      vim.api.nvim_win_close(w, true)
      return
    end
  end
  vim.cmd 'diffoff!'
end

local function in_split()
  return vim.wo.diff
end

local function toggle_split()
  if in_split() then
    close_split()
  else
    open_split()
  end
end

---@param opts {pr: integer, pr_id: string|nil, base: string, hunks: prtour.Hunk[], steps: prtour.Step[], mark_viewed: boolean}
function M.start(opts)
  local by_id, flat, per_file_left = {}, {}, {}
  for _, h in ipairs(opts.hunks) do
    by_id[h.id] = h
    per_file_left[h.file] = (per_file_left[h.file] or 0) + 1
  end
  local step_start = {}
  for si, step in ipairs(opts.steps) do
    for _, id in ipairs(step.hunks) do
      flat[#flat + 1] = { id = id, step = si }
      step_start[si] = step_start[si] or #flat
    end
  end
  state = {
    pr = opts.pr,
    pr_id = opts.pr_id,
    key = opts.key or tostring(opts.pr),
    label = opts.label or ('PR #' .. tostring(opts.pr)),
    resume = opts.resume,
    sha = opts.sha,
    seen = {},
    base = opts.base,
    steps = opts.steps,
    mark_viewed = opts.mark_viewed,
    by_id = by_id,
    flat = flat,
    per_file_left = per_file_left,
    pos = 0,
    visited = {},
    pending_viewed = {},
    step_start = step_start,
    started_at = os.time(),
    beaten = {},
  }
  local gs = gitsigns()
  if gs then
    gs.change_base(opts.base, true)
    pcall(gs.toggle_deleted, true)
    pcall(gs.toggle_word_diff, true)
  end
  saved_maps = {}
  for _, lhs in ipairs { '<CR>', '<BS>' } do
    local existing = vim.fn.maparg(lhs, 'n', false, true)
    if existing.lhs then
      saved_maps[#saved_maps + 1] = existing
    end
  end
  vim.keymap.set('n', ']f', M.next, { desc = 'prtour: next hunk in tour' })
  vim.keymap.set('n', '[f', M.prev, { desc = 'prtour: previous hunk in tour' })
  vim.keymap.set('n', ']u', function()
    M.next_unseen(1)
  end, { desc = 'prtour: next unseen hunk' })
  vim.keymap.set('n', '[u', function()
    M.next_unseen(-1)
  end, { desc = 'prtour: previous unseen hunk' })
  vim.keymap.set('n', '<CR>', unless_special(M.next, '<CR>'), { desc = 'prtour: next hunk in tour' })
  vim.keymap.set('n', '<BS>', unless_special(M.prev, '<BS>'), { desc = 'prtour: previous hunk in tour' })
  vim.keymap.set('n', '<leader>gc', function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    require('prtour.comments').add(line, line)
  end, { desc = 'prtour: [C]omment on line' })
  vim.keymap.set('x', '<leader>gc', function()
    local s, e = vim.fn.line 'v', vim.fn.line '.'
    if s > e then
      s, e = e, s
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
    require('prtour.comments').add(s, e)
  end, { desc = 'prtour: [C]omment on selection' })
  vim.keymap.set('n', '<leader>gr', function()
    require('prtour.threads').reply_at_cursor(opts.pr)
  end, { desc = 'prtour: [R]eply to thread at cursor' })
  vim.keymap.set('n', '<leader>go', M.outline, { desc = 'prtour: tour [O]utline' })
  vim.keymap.set('n', '<leader>ge', function()
    if require('prtour.comments').edit_at_cursor() then
      return
    end
    if not require('prtour.threads').edit_own_at_cursor() then
      vim.notify('prtour: no comment of yours at this line', vim.log.levels.WARN)
    end
  end, { desc = 'prtour: [E]dit/delete your comment at cursor' })
  vim.keymap.set('n', '<leader>gd', toggle_split, { desc = 'prtour: toggle side-by-side [D]iff' })
  if not opts.preserve_comments then
    require('prtour.comments').reset()
  end
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = vim.api.nvim_create_augroup('prtour-tour', { clear = true }),
    callback = function()
      update_hud_side()
    end,
  })
  if opts.pr then
    require('prtour.gh').review_threads(opts.pr, function(list)
    if not (list and state and state.pr == opts.pr) then
      return
    end
    require('prtour.threads').set(list)
    -- Decorate the buffer we're already sitting in.
    if state.pos >= 1 then
      local h = state.by_id[state.flat[state.pos].id]
      if h and not h.deleted then
        require('prtour.threads').decorate(vim.api.nvim_get_current_buf(), h.file)
      end
    end
    end)
  end
  local function absorb_visited(id)
    local h = by_id[id]
    if h and not state.visited[id] then
      state.visited[id] = true
      state.per_file_left[h.file] = state.per_file_left[h.file] - 1
    end
  end
  -- Files already ticked as viewed on GitHub count as visited, but stay in the tour.
  state.github_viewed = {}
  for _, path in ipairs(opts.viewed_files or {}) do
    state.github_viewed[path] = true
  end
  for _, h in ipairs(opts.hunks) do
    if state.github_viewed[h.file] then
      absorb_visited(h.id)
    end
  end
  -- Resume: seen-state is content-hashed, so it survives pushes, rebases
  -- and unrelated edits — only genuinely changed hunks come back unseen.
  local saved = load_progress(state.key)
  if saved and type(saved.seen) == 'table' and #saved.seen < 20000 then
    for _, hash in ipairs(saved.seen) do
      state.seen[hash] = true
    end
    for _, h in ipairs(opts.hunks) do
      if state.seen[h.hash] then
        absorb_visited(h.id)
      end
    end
  end
  -- Exact position only resumes for the same diff; otherwise the frontier rule applies.
  local pos = saved and saved.sha == opts.sha and tonumber(saved.pos) or nil
  if not pos then
    -- No local progress: start on the last seen hunk, so <CR> enters new territory.
    local first_unvisited
    for i, entry in ipairs(flat) do
      if not state.visited[entry.id] then
        first_unvisited = i
        break
      end
    end
    if not first_unvisited then
      pos = #flat -- everything seen; start at the end rather than replaying
    elseif first_unvisited > 1 then
      pos = first_unvisited - 1
    end
  end
  if pos and pos >= 1 and pos <= #flat then
    state.pos = pos - 1
    if pos > 1 then
      vim.notify(('prtour: resuming at hunk %d/%d'):format(pos, #flat))
    end
  end
  M.next()
end

local EVENTS = { approve = 'APPROVE', comment = 'COMMENT', ['request-changes'] = 'REQUEST_CHANGES', pending = nil }

--- Local mode "submit": batch queued comments into one message to a Claude pane.
---@param on_done fun()|nil
local function local_send_comments(on_done)
  local comments = require('prtour.comments')
  if comments.count() == 0 then
    return vim.notify('prtour: no queued comments to send', vim.log.levels.WARN)
  end
  comments.refresh_positions()
  local parts = { ('Review feedback on %s:'):format(state.label), '' }
  for i, c in ipairs(comments.all()) do
    local loc = c.start_line and ('%d-%d'):format(c.start_line, c.line) or tostring(c.line)
    parts[#parts + 1] = ('%d. %s:%s'):format(i, c.path, loc)
    for _, bl in ipairs(vim.split(c.body, '\n')) do
      parts[#parts + 1] = '   ' .. bl
    end
    parts[#parts + 1] = ''
  end
  parts[#parts + 1] = 'Please address these points on this branch.'
  require('prtour.claude').dispatch(table.concat(parts, '\n'), function(ok, err, label)
    if not ok then
      return vim.notify('prtour: ' .. err, vim.log.levels.ERROR)
    end
    comments.reset()
    vim.notify('prtour: feedback sent to Claude in ' .. label)
    if on_done then
      on_done()
    else
      M.refresh()
    end
  end)
end

local function teardown(quiet)
  pcall(vim.keymap.del, 'n', ']f')
  pcall(vim.keymap.del, 'n', '[f')
  pcall(vim.keymap.del, 'n', ']u')
  pcall(vim.keymap.del, 'n', '[u')
  pcall(vim.keymap.del, 'n', '<CR>')
  pcall(vim.keymap.del, 'n', '<BS>')
  pcall(vim.keymap.del, 'n', '<leader>gc')
  pcall(vim.keymap.del, 'x', '<leader>gc')
  pcall(vim.keymap.del, 'n', '<leader>gr')
  pcall(vim.keymap.del, 'n', '<leader>go')
  pcall(vim.keymap.del, 'n', '<leader>gd')
  pcall(vim.keymap.del, 'n', '<leader>ge')
  require('prtour.threads').clear()
  for _, m in ipairs(saved_maps) do
    pcall(vim.fn.mapset, 'n', false, m)
  end
  saved_maps = {}
  pcall(vim.api.nvim_del_augroup_by_name, 'prtour-tour')
  if state.badge_buf and vim.api.nvim_buf_is_valid(state.badge_buf) then
    vim.api.nvim_buf_clear_namespace(state.badge_buf, ns, 0, -1)
  end
  close_hud()
  local gs = gitsigns()
  if gs then
    gs.reset_base(true)
    pcall(gs.toggle_deleted, false)
    pcall(gs.toggle_word_diff, false)
  end
  state = nil
  if not quiet then
    vim.notify 'prtour: tour ended'
  end
end

function M.stop()
  if not state then
    return
  end
  local comments = require('prtour.comments')
  local n = comments.count()
  if n == 0 then
    return teardown()
  end
  local pr, pr_id = state.pr, state.pr_id
  local noun = n == 1 and '1 unsubmitted comment' or (n .. ' unsubmitted comments')
  vim.ui.select({
    pr and 'Upload to GitHub as a pending review (finalize later)' or 'Send the comments to a Claude pane',
    'Discard the comments',
    'Cancel — keep reviewing',
  }, { prompt = ('End tour: you have %s'):format(noun) }, function(_, idx)
    if idx == 1 then
      if not pr then
        return local_send_comments(teardown)
      end
      comments.submit({ pr = pr, pr_id = pr_id }, function(ok, err)
        if not ok then
          return vim.notify('prtour: upload failed, tour kept open: ' .. err, vim.log.levels.ERROR)
        end
        vim.notify(('prtour: %s uploaded as a pending review'):format(noun))
        teardown()
      end)
    elseif idx == 2 then
      comments.reset()
      teardown()
    end
  end)
end

--- Never render a hunk into a float or terminal (e.g. an open fzf window);
--- move to a normal window first.
local function ensure_normal_window()
  local function normal(w)
    return vim.api.nvim_win_get_config(w).relative == '' and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == ''
  end
  if normal(vim.api.nvim_get_current_win()) then
    return
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if normal(w) then
      return vim.api.nvim_set_current_win(w)
    end
  end
end

---@param h prtour.Hunk
local function open_hunk(h)
  ensure_normal_window()
  if h.deleted then
    -- No local file; show the base version read-only.
    local name = 'prtour://deleted/' .. h.file
    local buf = vim.fn.bufnr(name)
    if buf == -1 then
      local out = vim.system({ 'git', 'show', state.base .. ':' .. h.file }, { text = true }):wait()
      buf = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(buf, name)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(out.stdout or '', '\n'))
      vim.bo[buf].modifiable = false
      vim.bo[buf].filetype = vim.filetype.match { filename = h.file } or ''
    end
    vim.api.nvim_win_set_buf(0, buf)
  else
    vim.cmd.edit(vim.fn.fnameescape(h.file))
  end
  local last = vim.api.nvim_buf_line_count(0)
  local target = math.min(h.change_line or h.start_line, last)
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd 'normal! zz'
  require('prtour.threads').decorate(vim.api.nvim_get_current_buf(), h.file)
  -- Transient arrival badges at the hunk's first line; cleared on next jump.
  if state.badge_buf and vim.api.nvim_buf_is_valid(state.badge_buf) then
    vim.api.nvim_buf_clear_namespace(state.badge_buf, ns, 0, -1)
  end
  state.badge_buf = nil
  local badges = {}
  if h.added then
    badges[#badges + 1] = { '  new file ', 'PrtourAdded' }
  elseif h.deleted then
    badges[#badges + 1] = { '  deleted ', 'PrtourRemoved' }
  end
  if state.github_viewed and state.github_viewed[h.file] then
    badges[#badges + 1] = { ' ✓ viewed ', 'PrtourDim' }
  end
  if #badges > 0 then
    define_hls()
    local buf = vim.api.nvim_get_current_buf()
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, target - 1, 0, {
      virt_text = badges,
      virt_text_pos = 'eol',
    })
    state.badge_buf = buf
  end
end

local function send_viewed(file)
  require('prtour.gh').mark_viewed(state.pr_id, file, function(ok, err)
    if not ok then
      vim.notify('prtour: could not mark viewed on GitHub: ' .. (err or '?'), vim.log.levels.WARN)
    end
  end)
end

--- Late-arriving PR node id; flush files that completed in the meantime.
---@param id string
function M.set_pr_id(id)
  if not state then
    return
  end
  state.pr_id = id
  for _, file in ipairs(state.pending_viewed) do
    send_viewed(file)
  end
  state.pending_viewed = {}
end

---@param h prtour.Hunk
local function track_visited(h)
  if state.visited[h.id] then
    return
  end
  state.visited[h.id] = true
  state.seen[h.hash] = true
  state.per_file_left[h.file] = state.per_file_left[h.file] - 1
  if state.per_file_left[h.file] == 0 and state.mark_viewed then
    if state.pr_id then
      send_viewed(h.file)
    else
      table.insert(state.pending_viewed, h.file)
    end
  end
end

local function show_position()
  local entry = state.flat[state.pos]
  local step = state.steps[entry.step]
  define_hls()
  local width, wrapw = 58, 54
  local rows = {}
  local function add(segs)
    rows[#rows + 1] = segs
  end
  local in_step = state.pos - state.step_start[entry.step] + 1
  local pct = ('%d%%'):format(math.floor(vim.tbl_count(state.visited) / #state.flat * 100 + 0.5))
  local queued = require('prtour.comments').count()
  local kicker = (' STEP %d/%d · HUNK %d/%d%s'):format(
    entry.step, #state.steps, in_step, #step.hunks,
    queued > 0 and (' · 💬 %d'):format(queued) or ''
  )
  add { { '' } }
  add {
    { kicker, 'PrtourKicker' },
    { (' '):rep(math.max(1, width - vim.fn.strdisplaywidth(kicker) - #pct - 1)) },
    { pct, 'PrtourKicker' },
  }
  add { { '' } }
  local title_hl = state.step_flash and 'PrtourFlash' or 'PrtourTitle'
  for _, l in ipairs(wrap_text(step.title, wrapw)) do
    add { { ' ' .. l, title_hl } }
  end
  if step.note and step.note ~= '' then
    for _, l in ipairs(wrap_text(step.note, wrapw)) do
      add { { ' ' .. l } }
    end
  end
  add { { '' } }
  local next_step = state.steps[entry.step + 1]
  if next_step then
    add { { vim.fn.strcharpart((' next → %s'):format(next_step.title), 0, width - 1), 'PrtourNext' } }
  end
  add { { ' ' .. ('─'):rep(width - 2), 'PrtourDim' } }
  local segs = {}
  for _, d in ipairs { { '⏎', 'next' }, { '⌫', 'prev' }, { '\\', 'actions' } } do
    segs[#segs + 1] = { ' ' .. d[1], 'PrtourKey' }
    segs[#segs + 1] = { ' ' .. d[2] .. ' ', 'PrtourDim' }
  end
  add(segs)
  if not (hud.buf and vim.api.nvim_buf_is_valid(hud.buf)) then
    hud.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[hud.buf].bufhidden = 'hide'
  end
  local lines, marks = {}, {}
  for i, segs in ipairs(rows) do
    local text = ''
    for _, s in ipairs(segs) do
      local from = #text
      text = text .. s[1]
      if s[2] then
        marks[#marks + 1] = { i - 1, from, #text, s[2] }
      end
    end
    lines[i] = text
  end
  vim.api.nvim_buf_set_lines(hud.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(hud.buf, ns, 0, -1)
  local hl = vim.hl or vim.highlight
  for _, m in ipairs(marks) do
    hl.range(hud.buf, ns, m[4], { m[1], m[2] }, { m[1], m[3] })
  end
  hud.w, hud.h = width, #lines
  local cfg = {
    relative = 'editor',
    anchor = 'NE',
    row = 0,
    col = vim.o.columns,
    width = width,
    height = #lines,
    style = 'minimal',
    border = 'rounded',
    focusable = false,
    zindex = 60,
    title = (' %s '):format(state.label),
    title_pos = 'left',
  }
  if hud.win and vim.api.nvim_win_is_valid(hud.win) then
    vim.api.nvim_win_set_config(hud.win, cfg)
  else
    hud.win = vim.api.nvim_open_win(hud.buf, false, cfg)
  end
  vim.wo[hud.win].wrap = false
  -- On a step change, light up the whole panel, not just the title.
  vim.wo[hud.win].winhighlight = state.step_flash and 'NormalFloat:PrtourFlash,Normal:PrtourFlash,FloatBorder:PrtourFlash' or ''
end

local function step_complete(si)
  for _, id in ipairs(state.steps[si].hunks) do
    if not state.visited[id] then
      return false
    end
  end
  return true
end

local function steps_cleared()
  local n = 0
  for si in ipairs(state.steps) do
    n = n + (step_complete(si) and 1 or 0)
  end
  return n
end

local function show_summary()
  local elapsed = os.time() - (state.started_at or os.time())
  local files = {}
  for id in pairs(state.visited) do
    files[state.by_id[id].file] = true
  end
  local lines = {
    ('  Tour complete — %s'):format(state.label),
    '',
    ('  steps cleared    %d/%d'):format(steps_cleared(), #state.steps),
    ('  hunks read       %d/%d'):format(vim.tbl_count(state.visited), #state.flat),
    ('  files seen       %d'):format(vim.tbl_count(files)),
    ('  comments queued  %d'):format(require('prtour.comments').count()),
    ('  session time     %dm %02ds'):format(math.floor(elapsed / 60), elapsed % 60),
    '',
    '  (s)ubmit review · (q) close',
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local width = 40
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(1, math.floor((vim.o.lines - #lines) / 2) - 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = #lines,
    style = 'minimal',
    border = 'rounded',
    title = ' prtour ',
    title_pos = 'center',
  })
  local hl = vim.hl or vim.highlight
  hl.range(buf, ns, 'Title', { 0, 0 }, { 0, -1 })
  hl.range(buf, ns, 'NonText', { #lines - 1, 0 }, { #lines - 1, -1 })
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set('n', 'q', close, { buffer = buf })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf })
  vim.keymap.set('n', 's', function()
    close()
    if not state.pr then
      return M.submit()
    end
    vim.ui.select({ 'comment', 'approve', 'request-changes', 'pending' }, { prompt = 'Submit review as' }, function(kind)
      if kind then
        M.submit(kind)
      end
    end)
  end, { buffer = buf })
end

local function goto_pos(pos)
  if not state then
    return vim.notify('prtour: no active tour', vim.log.levels.WARN)
  end
  if pos < 1 then
    return
  end
  if pos > #state.flat then
    return show_summary()
  end
  local left = state.pos >= 1 and state.flat[state.pos].step or nil
  state.pos = pos
  local h = state.by_id[state.flat[pos].id]
  -- Flash the HUD title when crossing a step boundary, so the chapter
  -- change registers even while eyes are on the code.
  if left and state.flat[pos].step ~= left then
    state.step_flash = true
    vim.defer_fn(function()
      if state and state.pos == pos and state.step_flash then
        state.step_flash = false
        show_position()
      end
    end, 1500)
  else
    state.step_flash = false
  end
  open_hunk(h)
  track_visited(h)
  show_position()
  save_progress()
  -- Completion beat when moving forward out of a fully-read step.
  local entered = state.flat[pos].step
  if left and entered > left and not state.beaten[left] and step_complete(left) then
    state.beaten[left] = true
    vim.notify(('prtour: ✓ %s — %d/%d steps cleared'):format(state.steps[left].title, steps_cleared(), #state.steps))
  end
end

function M.next()
  goto_pos((state and state.pos or 0) + 1)
end

--- Jump to the nearest unseen hunk in the given direction.
---@param dir 1|-1
function M.next_unseen(dir)
  if not state then
    return
  end
  local i = state.pos + dir
  while i >= 1 and i <= #state.flat do
    if not state.visited[state.flat[i].id] then
      return goto_pos(i)
    end
    i = i + dir
  end
  vim.notify('prtour: no unseen hunks ' .. (dir > 0 and 'ahead' or 'behind'))
end

function M.prev()
  goto_pos((state and state.pos or 2) - 1)
end

function M.active()
  return state ~= nil
end

--- Screen rectangle the HUD currently occupies (nil when closed/hidden).
function M.hud_rect()
  if not (state and hud.win and vim.api.nvim_win_is_valid(hud.win) and hud.w) then
    return nil
  end
  return { top = 0, bottom = hud.h + 1, left = vim.o.columns - hud.w - 2 }
end

--- Hide the HUD while the cursor is under it; bring it back when clear.
update_hud_side = function()
  if not (state and hud.w) or state.pos < 1 then
    return
  end
  local sp = vim.fn.screenpos(0, vim.fn.line '.', vim.fn.col '.')
  if sp.row == 0 then
    return
  end
  local margin = 2
  local inside = sp.row <= hud.h + 1 + margin and sp.col >= vim.o.columns - hud.w - 2 - margin
  local visible = hud.win and vim.api.nvim_win_is_valid(hud.win)
  if inside and visible then
    close_hud()
  elseif not inside and not visible then
    show_position()
  end
end

--- Re-render the HUD (e.g. after the comment queue changes).
function M.refresh()
  if state and state.pos >= 1 then
    show_position()
  end
end

--- Context menu: only the actions that apply at the cursor.
function M.actions()
  if not state then
    return
  end
  local comments = require('prtour.comments')
  local threads = require('prtour.threads')
  local ld = leader_disp()
  local items = {}
  if comments.has_at_cursor() then
    items[#items + 1] = {
      label = 'edit / delete queued comment',
      hint = ld .. 'ge',
      fn = function()
        comments.edit_at_cursor()
      end,
    }
  end
  local at = threads.at_cursor_info()
  if at.own then
    items[#items + 1] = {
      label = 'edit / delete your GitHub comment',
      fn = function()
        threads.edit_own_at_cursor()
      end,
    }
  end
  if at.thread then
    items[#items + 1] = {
      label = 'reply to thread',
      hint = ld .. 'gr',
      fn = function()
        threads.reply_at_cursor(state.pr)
      end,
    }
  end
  if not comments.has_at_cursor() then
    items[#items + 1] = {
      label = 'comment on this line',
      hint = ld .. 'gc',
      fn = function()
        local line = vim.api.nvim_win_get_cursor(0)[1]
        comments.add(line, line)
      end,
    }
  end
  if in_split() then
    items[#items + 1] = { label = 'close side-by-side diff', hint = ld .. 'gd', fn = close_split }
  else
    items[#items + 1] = { label = 'side-by-side diff', hint = ld .. 'gd', fn = open_split }
  end
  if comments.count() > 0 then
    local noun = ('%d queued comment%s'):format(comments.count(), comments.count() == 1 and '' or 's')
    if state.pr then
      items[#items + 1] = {
        label = 'save ' .. noun .. ' to GitHub',
        fn = function()
          comments.submit({ pr = state.pr, pr_id = state.pr_id }, function(ok, err)
            if not ok then
              return vim.notify('prtour: save failed: ' .. err, vim.log.levels.ERROR)
            end
            vim.notify 'prtour: comments saved to pending review'
            M.refresh()
            refresh_threads()
          end)
        end,
      }
    end
    -- Own-PR reviews: the queue can also go straight to the Claude
    -- session working on the branch, instead of GitHub.
    items[#items + 1] = { label = 'send ' .. noun .. ' to Claude', fn = local_send_comments }
  end
  local h = state.pos >= 1 and state.by_id[state.flat[state.pos].id] or nil
  if h then
    items[#items + 1] = {
      label = 'ask Claude about this hunk…',
      fn = function()
        require('prtour.claude').ask_flow {
          pr = state.pr,
          label = state.label,
          file = h.file,
          start_line = h.start_line,
          line_count = h.line_count,
          diff = table.concat(h.lines, '\n'),
        }
      end,
    }
    items[#items + 1] = {
      label = 'send to Claude for changes…',
      fn = function()
        vim.ui.input({ prompt = 'Tell Claude what to change: ' }, function(req)
          if not req or req == '' then
            return
          end
          local claude = require('prtour.claude')
          local msg = ('Reviewer feedback from a code review (%s):\n\nFile: %s (around line %d)\nRequest: %s\n\nHunk under discussion:\n%s\n\nPlease address this on this branch.'):format(
            state.label, h.file, h.start_line, req, table.concat(h.lines, '\n')
          )
          claude.dispatch(msg, function(ok, err, label)
            if not ok then
              return vim.notify('prtour: ' .. err, vim.log.levels.ERROR)
            end
            vim.notify('prtour: sent to Claude in ' .. label)
          end)
        end)
      end,
    }
  end
  items[#items + 1] = { label = 'tour outline', hint = ld .. 'go', fn = M.outline }
  items[#items + 1] = {
    label = 'jump to next unseen hunk',
    hint = ']u',
    fn = function()
      M.next_unseen(1)
    end,
  }
  if state.pr then
    items[#items + 1] = {
      label = 'show PR description',
      fn = function()
        if state.pr_desc then
          return require('prtour.claude').show_answer(state.pr_desc.title, state.pr_desc.body)
        end
        require('prtour.gh').pr_view(state.pr, function(d, err)
          if not d then
            return vim.notify('prtour: ' .. (err or '?'), vim.log.levels.ERROR)
          end
          local body = d.body
          body = (body == vim.NIL or body == nil or body == '') and '(no description)' or tostring(body):gsub('\r', '')
          d.body = body
          if state then
            state.pr_desc = d
          end
          require('prtour.claude').show_answer(d.title, body)
        end)
      end,
    }
  else
    items[#items + 1] = {
      label = 'refresh — re-scan local changes',
      fn = function()
        local base_arg = state.resume and state.resume.base_arg or nil
        teardown(true)
        require('prtour').start_local(base_arg, { preserve_comments = true })
      end,
    }
  end
  if state.pr and comments.count() > 0 then
    items[#items + 1] = {
      label = 'draft summary with Claude & submit…',
      fn = function()
        local p = require('prtour.progress').start 'Claude'
        p:report 'drafting review summary from your comments'
        local clines = {}
        for _, c in ipairs(comments.all()) do
          clines[#clines + 1] = ('%s:%d — %s'):format(c.path, c.line, c.body)
        end
        require('prtour.claude').draft_summary(state.label, table.concat(clines, '\n'), function(draft, err)
          if not draft then
            return p:fail('draft failed: ' .. err)
          end
          p:finish()
          local buf = vim.api.nvim_create_buf(false, true)
          vim.bo[buf].filetype = 'markdown'
          vim.bo[buf].bufhidden = 'wipe'
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(draft, '\n'))
          local width, height = 72, 12
          local win = vim.api.nvim_open_win(buf, true, {
            relative = 'editor',
            row = math.floor((vim.o.lines - height) / 2),
            col = math.floor((vim.o.columns - width) / 2),
            width = width,
            height = height,
            style = 'minimal',
            border = 'rounded',
            title = ' review summary · edit freely · <CR> submit · q discard ',
            title_pos = 'center',
          })
          vim.wo[win].wrap = true
          vim.wo[win].linebreak = true
          local function close()
            if vim.api.nvim_win_is_valid(win) then
              vim.api.nvim_win_close(win, true)
            end
          end
          vim.keymap.set('n', 'q', close, { buffer = buf })
          vim.keymap.set('n', '<CR>', function()
            local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
            close()
            vim.ui.select({ 'comment', 'approve', 'request-changes', 'pending' }, { prompt = 'Submit review as' }, function(kind)
              if not kind then
                return
              end
              comments.submit({ pr = state.pr, pr_id = state.pr_id, event = EVENTS[kind], body = body }, function(ok, err2)
                if not ok then
                  return vim.notify('prtour: review submit failed: ' .. err2, vim.log.levels.ERROR)
                end
                vim.notify(('prtour: review submitted (%s)'):format(kind))
                M.refresh()
                refresh_threads()
              end)
            end)
          end, { buffer = buf })
        end)
      end,
    }
  end
  if state.pr then
    items[#items + 1] = {
      label = 'submit review…',
      fn = function()
        vim.ui.select({ 'comment', 'approve', 'request-changes', 'pending' }, { prompt = 'Submit review as' }, function(kind)
          if kind then
            M.submit(kind)
          end
        end)
      end,
    }
  end
  items[#items + 1] = { label = 'quit tour', hint = ld .. 'gq', fn = M.stop }
  require('prtour.menu').open(items)
end

--- Table of contents: jump to any step.
function M.outline()
  if not state then
    return vim.notify('prtour: no active tour', vim.log.levels.WARN)
  end
  local current = state.pos >= 1 and state.flat[state.pos].step or nil
  local labels = {}
  for si, step in ipairs(state.steps) do
    local started = false
    for _, id in ipairs(step.hunks) do
      if state.visited[id] then
        started = true
        break
      end
    end
    local status = si == current and '▶' or step_complete(si) and '✓' or started and '◐' or '·'
    labels[#labels + 1] = ('%s %2d. %s  (%d hunks)'):format(status, si, step.title, #step.hunks)
  end
  vim.ui.select(labels, { prompt = 'PR tour outline — jump to step' }, function(_, idx)
    if idx then
      goto_pos(state.step_start[idx])
    end
  end)
end

--- Refetch GitHub threads and re-render them at the current hunk, so
--- freshly uploaded comments reappear inline as pending thread comments.
refresh_threads = function()
  if not (state and state.pr) then
    return
  end
  local pr = state.pr
  require('prtour.gh').review_threads(pr, function(list)
    if not (list and state and state.pr == pr) then
      return
    end
    require('prtour.threads').set(list)
    if state.pos >= 1 then
      local h = state.by_id[state.flat[state.pos].id]
      if h and not h.deleted then
        require('prtour.threads').decorate(vim.api.nvim_get_current_buf(), h.file)
      end
    end
  end)
end

--- Submit queued comments (and verdict) as one GitHub review.
---@param kind string|nil approve | comment | request-changes | pending (default comment)
function M.submit(kind)
  if not state then
    return vim.notify('prtour: no active tour', vim.log.levels.WARN)
  end
  if not state.pr then
    return local_send_comments()
  end
  kind = kind and kind ~= '' and kind or 'comment'
  if kind ~= 'pending' and EVENTS[kind] == nil and kind ~= 'comment' then
    return vim.notify('prtour: unknown review kind: ' .. kind, vim.log.levels.ERROR)
  end
  local comments = require('prtour.comments')
  vim.ui.input({ prompt = ('Review summary (%s, %d comments): '):format(kind, comments.count()) }, function(body)
    if body == nil then
      return
    end
    comments.submit({ pr = state.pr, pr_id = state.pr_id, event = EVENTS[kind], body = body }, function(ok, err)
      if not ok then
        return vim.notify('prtour: review submit failed: ' .. err, vim.log.levels.ERROR)
      end
      vim.notify(('prtour: review submitted (%s)'):format(kind))
      M.refresh()
      refresh_threads()
    end)
  end)
end

return M
