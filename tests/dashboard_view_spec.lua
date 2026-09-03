-- Exercises the pure dashboard view (prtour.dashboard.view): given a built
-- model, it returns the buffer's lines, the ordered selectable entries with
-- their action descriptors, and highlight spans. Like the model spec, this
-- runs under plain Lua — the view calls no `vim.*` and holds no feature logic
-- (all decisions come from the model builder), only presentation.
local view = require 'prtour.dashboard.view'

--- A built model with sensible defaults; `over` replaces top-level keys.
local function model(over)
  local m = {
    loading = false,
    resume = {},
    start = {
      prs = {},
      local_card = { base = 'origin/main', base_arg = 'origin/main', dirty = false },
    },
  }
  for k, v in pairs(over or {}) do
    m[k] = v
  end
  return m
end

--- A resume entry as the model builder emits it.
local function resume_entry(over)
  local e = {
    key = 'prtour-ab12-pr-7',
    kind = 'pr',
    badge = 'PR',
    label = 'PR #7',
    walked = 2,
    total = 5,
    last_touched = 1000,
    resume = { kind = 'pr', pr = 7 },
  }
  for k, v in pairs(over or {}) do
    e[k] = v
  end
  return e
end

local function render(m)
  return view.render(m, { repo = 'prtour.nvim', now = 1000, spinner = '⠋' })
end

--- Whole-buffer text, for substring assertions.
local function text(r)
  return table.concat(r.lines, '\n')
end

--- True if any line contains `needle`.
local function has_line(r, needle)
  return text(r):find(needle, 1, true) ~= nil
end

--- The selectable entry whose descriptor matches (action[, extra key/value]).
local function entry_for(r, action)
  for _, e in ipairs(r.entries) do
    if e.select.action == action then
      return e
    end
  end
end

describe('dashboard view — sections', function()
  it('omits the Resume header when there are no unfinished tours', function()
    local r = render(model())
    ok(not has_line(r, 'Resume'), 'Resume header should be omitted when empty')
    ok(has_line(r, 'Start'), 'Start is always shown for the local card')
  end)

  it('shows the Resume header and one line per unfinished tour', function()
    local r = render(model {
      resume = {
        resume_entry { key = 'k1', label = 'PR #7' },
        resume_entry { key = 'k2', label = 'feat (local)', kind = 'local', badge = 'local', resume = { kind = 'local', base_arg = nil } },
      },
    })
    ok(has_line(r, 'Resume'), 'Resume header present')
    ok(has_line(r, 'PR #7'), 'first resume label rendered')
    ok(has_line(r, 'feat (local)'), 'second resume label rendered')
  end)

  it('always renders the local-review card in Start', function()
    local dirty = render(model { start = { prs = {}, local_card = { base = 'HEAD', base_arg = nil, dirty = true } } })
    ok(has_line(dirty, 'working tree'), 'dirty card mentions the working tree')

    local clean = render(model())
    ok(has_line(clean, 'origin/main'), 'clean card names the default branch')
  end)

  it('degrades the clean card rather than crashing when the base is unknown', function()
    -- No `origin/HEAD` → the model passes a nil base straight through; the
    -- view must still render (LuaJIT's string.format('%s', nil) would error).
    local r = render(model { start = { prs = {}, local_card = { base = nil, base_arg = nil, dirty = false } } })
    ok(has_line(r, 'local'), 'local card still drawn with an unknown base')
    ok(entry_for(r, 'start_local'), 'and stays selectable')
  end)
end)

describe('dashboard view — selectable entries', function()
  it('numbers entries sequentially across Resume then Start', function()
    local r = render(model {
      resume = { resume_entry { key = 'k1' }, resume_entry { key = 'k2' } },
      start = {
        prs = { { number = 12, title = 'Add widget', author = { login = 'ann' }, additions = 3, deletions = 1 } },
        local_card = { base = 'origin/main', base_arg = 'origin/main', dirty = false },
      },
    })
    -- Two resume entries, then the local card, then one PR: n = 1..4.
    eq(#r.entries, 4)
    for i, e in ipairs(r.entries) do
      eq(e.n, i)
    end
    eq(r.entries[1].select.action, 'resume')
    eq(r.entries[2].select.action, 'resume')
    eq(r.entries[3].select.action, 'start_local')
    eq(r.entries[4].select.action, 'start_pr')
  end)

  it('carries the resume descriptor through untouched', function()
    local r = render(model { resume = { resume_entry { resume = { kind = 'pr', pr = 7 } } } })
    local e = entry_for(r, 'resume')
    eq(e.select.resume, { kind = 'pr', pr = 7 })
  end)

  it('carries the local card base_arg for start_local', function()
    local r = render(model { start = { prs = {}, local_card = { base = 'origin/main', base_arg = 'origin/main', dirty = false } } })
    eq(entry_for(r, 'start_local').select.base_arg, 'origin/main')

    local dirty = render(model { start = { prs = {}, local_card = { base = 'HEAD', base_arg = nil, dirty = true } } })
    eq(entry_for(dirty, 'start_local').select.base_arg, nil)
  end)

  it('carries the PR number for start_pr', function()
    local r = render(model {
      start = {
        prs = { { number = 15, title = 'Fix bug', author = { login = 'bob' }, additions = 2, deletions = 1 } },
        local_card = { base = 'origin/main', base_arg = 'origin/main', dirty = false },
      },
    })
    eq(entry_for(r, 'start_pr').select.number, 15)
  end)

  it('points every entry at a real line', function()
    local r = render(model { resume = { resume_entry {} } })
    for _, e in ipairs(r.entries) do
      ok(e.line >= 1 and e.line <= #r.lines, 'entry line in range')
      ok(r.lines[e.line]:find(tostring(e.n), 1, true), 'entry line shows its number')
    end
  end)

  it('only the first nine rows show a quick-select number', function()
    -- Ten resume entries: the tenth is still selectable (via j/k) but carries
    -- no number, since only 1–9 are bound to a key.
    local resume = {}
    for i = 1, 10 do
      resume[i] = resume_entry { key = 'k' .. i, last_touched = 2000 - i }
    end
    local r = render(model { resume = resume, start = { prs = {}, local_card = { base = 'origin/main', base_arg = 'origin/main', dirty = false } } })
    eq(#r.entries, 11) -- 10 resume + local card
    eq(r.entries[10].n, 10)
    ok(not r.lines[r.entries[10].line]:find('10', 1, true), 'the tenth row shows no number')
    -- No highlight is emitted for the unnumbered row.
    for _, h in ipairs(r.hls) do
      ok(not (h.group == 'PrtourKey' and h.line == r.entries[10].line - 1), 'no key highlight past nine')
    end
  end)
end)

describe('dashboard view — async PR loading', function()
  it('shows a spinner row and no PR entries while loading', function()
    local r = render(model { loading = true, start = { prs = {}, local_card = { base = 'origin/main', base_arg = 'origin/main', dirty = false } } })
    ok(has_line(r, '⠋'), 'spinner frame is drawn')
    ok(not entry_for(r, 'start_pr'), 'no PR is selectable yet')
    -- The local card is local data and stays selectable while PRs load.
    ok(entry_for(r, 'start_local'), 'local card selectable during load')
  end)

  it('shows a dim "reviewed locally" tag on a matching PR, still selectable', function()
    local r = render(model {
      start = {
        prs = { { number = 12, title = 'Add widget', author = { login = 'ann' }, additions = 3, deletions = 1, reviewed_locally = true, disabled = false } },
        local_card = { base = 'origin/main', base_arg = 'origin/main', dirty = false },
      },
    })
    ok(has_line(r, 'reviewed locally'), 'the tag is rendered')
    ok(entry_for(r, 'start_pr'), 'a reviewed-locally PR is still selectable')
    -- The tag text is dim.
    local tagged
    for _, e in ipairs(r.entries) do
      if e.select.action == 'start_pr' then
        tagged = r.lines[e.line]
      end
    end
    local dim_covers_tag = false
    for _, h in ipairs(r.hls) do
      if h.group == 'PrtourDim' and tagged:sub(h.col_start + 1, h.col_end):find('reviewed locally', 1, true) then
        dim_covers_tag = true
      end
    end
    ok(dim_covers_tag, 'the tag is highlighted dim')
  end)

  it('renders a dirty-disabled PR as a dim, non-selectable row with a hint', function()
    local r = render(model {
      start = {
        prs = { { number = 12, title = 'Add widget', author = { login = 'ann' }, additions = 3, deletions = 1, disabled = true, hint = 'working tree dirty — checkout blocked' } },
        local_card = { base = 'HEAD', base_arg = nil, dirty = true },
      },
    })
    ok(has_line(r, '#12'), 'the disabled PR is still shown')
    ok(has_line(r, 'working tree dirty'), 'its hint explains why it is disabled')
    ok(not entry_for(r, 'start_pr'), 'a disabled PR is not selectable')
    -- The local card stays selectable even when every PR is disabled.
    ok(entry_for(r, 'start_local'), 'the local card remains selectable')
    -- The disabled row carries no quick-select number highlight.
    local disabled_line
    for i, l in ipairs(r.lines) do
      if l:find('#12', 1, true) then
        disabled_line = i
      end
    end
    for _, h in ipairs(r.hls) do
      ok(not (h.group == 'PrtourKey' and h.line == disabled_line - 1), 'no key highlight on a disabled row')
    end
  end)

  it('drops the spinner and lists PRs once loaded', function()
    local r = render(model {
      loading = false,
      start = {
        prs = { { number = 12, title = 'Add widget', author = { login = 'ann' }, additions = 3, deletions = 1 } },
        local_card = { base = 'origin/main', base_arg = 'origin/main', dirty = false },
      },
    })
    ok(not has_line(r, '⠋'), 'no spinner once loaded')
    ok(has_line(r, '#12'), 'PR number rendered')
    ok(has_line(r, 'Add widget'), 'PR title rendered')
    ok(has_line(r, 'ann'), 'PR author rendered')
  end)
end)
