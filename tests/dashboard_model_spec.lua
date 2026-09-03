-- Exercises the pure dashboard model builder (prtour.dashboard.model) through
-- its only seam: given decoded progress records, an open-PR list, and git
-- facts, assert on the returned model. Tests observe the model only — never
-- private helpers, buffers, or IO.
local model = require 'prtour.dashboard.model'

local SLUG = 'prtour-ab12'

--- A decoded progress record for this repo, with sensible defaults.
local function record(over)
  local r = {
    key = SLUG .. '-pr-1',
    label = 'PR #1',
    resume = { kind = 'pr', pr = 1 },
    seen = {},
    total = 4,
    pos = 0,
    last_touched = 1000,
  }
  for k, v in pairs(over or {}) do
    r[k] = v
  end
  return r
end

--- Build a model with this-repo defaults; `over` replaces top-level inputs
--- (records/prs/git/slug) so each test states only what it exercises.
local function build(over)
  local inputs = {
    slug = SLUG,
    git = { dirty = false, default_base = 'origin/main' },
    prs = {},
    records = {},
  }
  for k, v in pairs(over or {}) do
    inputs[k] = v
  end
  return model.build(inputs)
end

--- Find a resume entry by key (order-independent lookups where order is not
--- what's under test).
local function by_key(resume, key)
  for _, e in ipairs(resume) do
    if e.key == key then
      return e
    end
  end
end

describe('dashboard model — resume list', function()
  it('includes only this repo\'s unfinished tours', function()
    local m = build {
      records = {
        record { key = SLUG .. '-pr-1', seen = { 'a', 'b' }, total = 4 }, -- unfinished
        record { key = SLUG .. '-pr-2', seen = { 'a', 'b', 'c', 'd' }, total = 4 }, -- complete
        record { key = 'other-repo-99-pr-3', seen = {}, total = 4 }, -- different repo
      },
    }
    eq(#m.resume, 1)
    eq(m.resume[1].key, SLUG .. '-pr-1')
  end)

  it('orders entries most-recently-worked-first', function()
    local m = build {
      records = {
        record { key = SLUG .. '-pr-1', seen = { 'a' }, last_touched = 100 },
        record { key = SLUG .. '-pr-2', seen = { 'a' }, last_touched = 300 },
        record { key = SLUG .. '-pr-3', seen = { 'a' }, last_touched = 200 },
      },
    }
    eq({ m.resume[1].key, m.resume[2].key, m.resume[3].key }, {
      SLUG .. '-pr-2', SLUG .. '-pr-3', SLUG .. '-pr-1',
    })
  end)

  it('caps the list at roughly ten most-recent entries', function()
    local records = {}
    for i = 1, 15 do
      records[i] = record { key = SLUG .. '-pr-' .. i, seen = { 'a' }, last_touched = i }
    end
    local m = build { records = records }
    eq(#m.resume, 10)
    -- The ten kept are the most recent (last_touched 15..6).
    eq(m.resume[1].key, SLUG .. '-pr-15')
    eq(m.resume[10].key, SLUG .. '-pr-6')
  end)

  it('exposes badge, progress figures, and last-touched per entry', function()
    local m = build {
      records = {
        record { key = SLUG .. '-pr-7', label = 'PR #7', resume = { kind = 'pr', pr = 7 }, seen = { 'a', 'b' }, total = 5, last_touched = 42 },
        record { key = SLUG .. '-local-feat', label = 'feat (local)', resume = { kind = 'local', base_arg = nil }, seen = { 'x' }, total = 3, last_touched = 43 },
      },
    }
    local pr = by_key(m.resume, SLUG .. '-pr-7')
    eq(pr.badge, 'PR')
    eq(pr.walked, 2)
    eq(pr.total, 5)
    eq(pr.last_touched, 42)
    eq(pr.resume, { kind = 'pr', pr = 7 })

    local loc = by_key(m.resume, SLUG .. '-local-feat')
    eq(loc.badge, 'local')
    eq(loc.walked, 1)
    eq(loc.total, 3)
  end)

  it('drops malformed records rather than crashing', function()
    local m = build {
      records = {
        { key = SLUG .. '-pr-1' }, -- no resume/label/total
        record { key = SLUG .. '-pr-2', seen = { 'a' }, total = 3 },
      },
    }
    eq(#m.resume, 1)
    eq(m.resume[1].key, SLUG .. '-pr-2')
  end)
end)

describe('dashboard model — start section', function()
  it('passes the open-PR list straight through', function()
    local prs = {
      { number = 3, title = 'Add widget', author = { login = 'ann' } },
      { number = 5, title = 'Fix bug', author = { login = 'bob' } },
    }
    local m = build { prs = prs }
    eq(m.start.prs, prs)
    eq(m.loading, false)
  end)

  it('reports loading and an empty PR list before the fetch returns', function()
    -- `prs` omitted entirely (not yet fetched) — call the builder directly,
    -- since a nil override can't survive the defaults helper's `pairs` merge.
    local m = model.build {
      slug = SLUG,
      git = { dirty = false, default_base = 'origin/main' },
      records = {},
    }
    eq(m.loading, true)
    eq(m.start.prs, {})
  end)

  it('bases the local card on HEAD when the tree is dirty', function()
    local m = build { git = { dirty = true, default_base = 'origin/main' } }
    eq(m.start.local_card.base, 'HEAD')
    eq(m.start.local_card.dirty, true)
  end)

  it('bases the local card on the default branch when the tree is clean', function()
    local m = build { git = { dirty = false, default_base = 'origin/main' } }
    eq(m.start.local_card.base, 'origin/main')
    eq(m.start.local_card.base_arg, 'origin/main')
    eq(m.start.local_card.dirty, false)
  end)
end)
