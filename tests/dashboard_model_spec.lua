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

  it('shows the stored PR title and author on the resume line', function()
    local m = build {
      records = {
        record {
          key = SLUG .. '-pr-7',
          label = 'PR #7',
          title = 'Add dark mode',
          author = 'alice',
          resume = { kind = 'pr', pr = 7 },
          seen = { 'a' },
        },
      },
    }
    eq(m.resume[1].label, 'Add dark mode  ·  alice')
  end)

  it('shows just the title when a PR record stored no author', function()
    local m = build {
      records = {
        record { key = SLUG .. '-pr-7', label = 'PR #7', title = 'Add dark mode', seen = { 'a' } },
      },
    }
    eq(m.resume[1].label, 'Add dark mode')
  end)

  it('falls back to #number for records predating title enrichment', function()
    local m = build {
      records = {
        record { key = SLUG .. '-pr-7', label = 'PR #7', resume = { kind = 'pr', pr = 7 }, seen = { 'a' } },
      },
    }
    eq(m.resume[1].label, 'PR #7')
  end)

  it('never enriches a local review with a stray stored title', function()
    -- A local record could carry a title field from a future change; the
    -- headline stays the branch label regardless.
    local m = build {
      records = {
        record { key = SLUG .. '-local-feat', label = 'feat (local)', title = 'nope', resume = { kind = 'local' }, seen = { 'a' } },
      },
    }
    eq(m.resume[1].label, 'feat (local)')
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
  it('carries the open PRs\' display fields through, unflagged by default', function()
    local prs = {
      { number = 3, title = 'Add widget', author = { login = 'ann' }, additions = 3, deletions = 1 },
      { number = 5, title = 'Fix bug', author = { login = 'bob' }, additions = 2, deletions = 0 },
    }
    local m = build { prs = prs }
    eq(#m.start.prs, 2)
    eq(m.start.prs[1].number, 3)
    eq(m.start.prs[1].title, 'Add widget')
    eq(m.start.prs[1].author, { login = 'ann' })
    -- A clean tree with no matching local review leaves both flags off.
    eq(m.start.prs[1].reviewed_locally, false)
    eq(m.start.prs[1].disabled, false)
    eq(m.start.prs[1].hint, nil)
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

describe('dashboard model — Start polish (dedupe, tags, dirty)', function()
  --- A `gh`-shaped open PR with sensible defaults.
  local function pr(over)
    local p = {
      number = 3,
      title = 'Add widget',
      author = { login = 'ann' },
      headRefName = 'feat/widget',
      additions = 3,
      deletions = 1,
    }
    for k, v in pairs(over or {}) do
      p[k] = v
    end
    return p
  end

  --- The start PR entry for a given number, or nil.
  local function start_pr(m, number)
    for _, e in ipairs(m.start.prs) do
      if e.number == number then
        return e
      end
    end
  end

  it('dedupes a PR that already has an unfinished tour out of Start', function()
    -- PR #3 has an unfinished tour (in Resume); PR #5 does not.
    local m = build {
      records = { record { key = SLUG .. '-pr-3', resume = { kind = 'pr', pr = 3 }, seen = { 'a' }, total = 4 } },
      prs = { pr { number = 3 }, pr { number = 5 } },
    }
    -- It still resumes, but no longer offers a fresh start for #3.
    eq(by_key(m.resume, SLUG .. '-pr-3').resume, { kind = 'pr', pr = 3 })
    ok(start_pr(m, 3) == nil, 'resumed PR #3 dropped from Start')
    ok(start_pr(m, 5) ~= nil, 'PR #5 without a tour stays in Start')
  end)

  it('dedupes a PR whose unfinished tour has aged past the Resume cap', function()
    -- Ten fresher unfinished local tours push PR #3's older tour off the capped
    -- Resume display, but it's still in flight — Start must not re-offer it.
    local records = { record { key = SLUG .. '-pr-3', resume = { kind = 'pr', pr = 3 }, seen = { 'a' }, total = 4, last_touched = 1 } }
    for i = 1, 10 do
      records[#records + 1] = record {
        key = SLUG .. '-local-branch' .. i,
        resume = { kind = 'local' },
        seen = { 'a' },
        total = 4,
        last_touched = 100 + i,
      }
    end
    local m = build { records = records, prs = { pr { number = 3 } } }
    eq(#m.resume, 10) -- PR #3's tour aged out of the displayed list
    ok(by_key(m.resume, SLUG .. '-pr-3') == nil, 'PR #3 not shown in Resume (capped)')
    ok(start_pr(m, 3) == nil, 'yet still deduped out of Start')
  end)

  it('keeps a PR in Start once its tour is complete (not in Resume)', function()
    -- PR #3's tour is fully walked, so it isn't in Resume; Start should show it.
    local m = build {
      records = { record { key = SLUG .. '-pr-3', resume = { kind = 'pr', pr = 3 }, seen = { 'a', 'b', 'c', 'd' }, total = 4 } },
      prs = { pr { number = 3 } },
    }
    eq(#m.resume, 0)
    ok(start_pr(m, 3) ~= nil, 'a completed PR tour still appears in Start')
  end)

  it('tags a PR whose head branch matches a prior local review', function()
    -- A local review of branch `feat/widget` was saved under the sanitized key.
    local m = build {
      records = { record { key = SLUG .. '-local-feat-widget', label = 'feat/widget (local)', resume = { kind = 'local' }, seen = { 'x' }, total = 3 } },
      prs = { pr { number = 3, headRefName = 'feat/widget' } },
    }
    eq(start_pr(m, 3).reviewed_locally, true)
  end)

  it('does not tag a PR with no matching local review', function()
    local m = build {
      records = { record { key = SLUG .. '-local-something-else', resume = { kind = 'local' }, seen = { 'x' }, total = 3 } },
      prs = { pr { number = 3, headRefName = 'feat/widget' } },
    }
    eq(start_pr(m, 3).reviewed_locally, false)
  end)

  it('matches even a completed local review (any prior review counts)', function()
    local m = build {
      records = { record { key = SLUG .. '-local-feat-widget', resume = { kind = 'local' }, seen = { 'x', 'y', 'z' }, total = 3 } },
      prs = { pr { number = 3, headRefName = 'feat/widget' } },
    }
    eq(start_pr(m, 3).reviewed_locally, true)
  end)

  it('disables every PR when the working tree is dirty, with a hint', function()
    local m = build {
      git = { dirty = true, default_base = 'origin/main' },
      prs = { pr { number = 3 }, pr { number = 5 } },
    }
    eq(start_pr(m, 3).disabled, true)
    ok(type(start_pr(m, 3).hint) == 'string' and start_pr(m, 3).hint ~= '', 'a hint explains why')
    eq(start_pr(m, 5).disabled, true)
    -- The local card is unaffected by the dirty tree — it's still offered.
    eq(m.start.local_card.dirty, true)
    eq(m.start.local_card.base, 'HEAD')
  end)

  it('leaves PRs enabled with no hint when the tree is clean', function()
    local m = build {
      git = { dirty = false, default_base = 'origin/main' },
      prs = { pr { number = 3 } },
    }
    eq(start_pr(m, 3).disabled, false)
    eq(start_pr(m, 3).hint, nil)
  end)
end)
