-- The dashboard's single pure seam: turn injected inputs into the whole
-- dashboard as plain data. It calls no `vim.*`, does no IO, and makes no
-- network calls, so it loads and runs under plain Lua and is the one place the
-- feature's decisions are tested.
--
-- Inputs (all injected by the thin impure shells):
--   slug            string  this repo's cache-key prefix (scopes records/PRs)
--   records         table[] decoded progress records for the cache dir, each
--                           { key, label, resume, seen (string[]), total,
--                             pos, last_touched (epoch), and for PR tours
--                             title/author (ticket #4; absent on older records) }
--   prs             table[] open PRs as `gh` returns them, or nil while the
--                           async fetch is still in flight
--   git             table   { branch, dirty (bool), default_base (e.g.
--                           'origin/main') }
--
-- Output: { loading, resume, start = { prs, local_card } }. See CONTEXT.md for
-- the Resume/Start vocabulary; covered == walked-here until the cross-tour
-- overlay lands (ADR-0001, ticket #6).
local M = {}

-- Keep the Resume list scannable; stale entries age out via the cache pruner.
local RESUME_CAP = 10

--- Hunks walked in this tour = the size of its own `seen` set.
local function walked(record)
  return type(record.seen) == 'table' and #record.seen or 0
end

--- A record is usable only if it carries the fields Resume renders and acts on.
local function is_valid(record)
  return type(record) == 'table'
    and type(record.key) == 'string'
    and type(record.resume) == 'table'
    and type(record.label) == 'string'
    and tonumber(record.total) ~= nil
end

--- Progress keys are `<slug>-pr-<n>` / `<slug>-local-<branch>`, so a record
--- belongs to this repo exactly when the slug is its prefix.
local function in_repo(record, slug)
  local prefix = slug .. '-'
  return record.key:sub(1, #prefix) == prefix
end

--- The hint shown on a PR that a dirty tree makes un-startable, so it's clear
--- the entry is dimmed on purpose and how to make it selectable again.
local DIRTY_HINT = 'working tree dirty — checkout blocked'

--- Sanitize a branch name into the token used inside `-local-<branch>` progress
--- keys. MUST match the mapping the tour writer applies (prtour.init), so a PR
--- head branch and a prior local review of the same branch collide on the same
--- token — that collision is exactly what the "reviewed locally" match is.
local function branch_token(branch)
  return (branch:gsub('[^%w%-_]', '-'))
end

--- The Resume line's headline. A PR tour enriched at start with the PR title
--- (ticket #4) reads as "<title>  ·  <author>", so a review is recognisable
--- without opening it — from local data only, no network on dashboard open.
--- Records predating the enrichment (no stored title) and local reviews fall
--- back to the record's own label (e.g. `PR #7`).
local function headline(record)
  if record.resume.kind ~= 'pr' or type(record.title) ~= 'string' or record.title == '' then
    return record.label
  end
  local author = type(record.author) == 'string' and record.author ~= '' and record.author or nil
  return author and (record.title .. '  ·  ' .. author) or record.title
end

--- Shape one record into a Resume entry: a `PR`/`local` badge, the two progress
--- figures, when it was last touched, and the descriptor to resume it.
local function resume_entry(record)
  local kind = record.resume.kind
  return {
    key = record.key,
    kind = kind,
    badge = kind == 'pr' and 'PR' or 'local',
    label = headline(record),
    walked = walked(record),
    total = tonumber(record.total),
    last_touched = record.last_touched,
    resume = record.resume,
  }
end

--- Build the dashboard model from injected inputs.
---@param inputs table
---@return table model
function M.build(inputs)
  local slug = inputs.slug or ''
  local git = inputs.git or {}
  local records = inputs.records or {}

  -- Resume: this repo's unfinished tours, most-recently-worked-first, capped.
  -- Unfinished == not yet covered; covered is walked-here for now, so a tour
  -- drops off once its walked set reaches its hunk total.
  --
  -- `resumed_pr` records every unfinished PR tour's number as we go — sourced
  -- from the full record set, not the capped/sorted display list below, so a PR
  -- with an in-flight tour is deduped out of Start even when its tour has aged
  -- past RESUME_CAP. Otherwise it would reappear in Start offering a *fresh*
  -- start that discards its progress — the conflicting affordance ticket #5
  -- exists to remove.
  local resume = {}
  local resumed_pr = {}
  for _, r in ipairs(records) do
    if is_valid(r) and in_repo(r, slug) and walked(r) < tonumber(r.total) then
      resume[#resume + 1] = resume_entry(r)
      if r.resume.kind == 'pr' and r.resume.pr then
        resumed_pr[r.resume.pr] = true
      end
    end
  end
  table.sort(resume, function(a, b)
    return (a.last_touched or 0) > (b.last_touched or 0)
  end)
  for i = #resume, RESUME_CAP + 1, -1 do
    resume[i] = nil
  end

  -- `reviewed_branch`: branch tokens with any prior local review (finished or
  -- not) — the source of the "reviewed locally" tag. (`resumed_pr`, the other
  -- Start-PR input, is gathered with the Resume loop above.)
  local reviewed_branch = {}
  local local_prefix = slug .. '-local-'
  for _, r in ipairs(records) do
    if type(r) == 'table' and type(r.key) == 'string' and r.key:sub(1, #local_prefix) == local_prefix then
      reviewed_branch[r.key:sub(#local_prefix + 1)] = true
    end
  end

  -- Start: shape each open PR (empty until the fetch returns) into a display
  -- record plus the two decision flags the buffer only renders. A dirty tree
  -- can't check a branch out over local changes, so every PR is disabled with a
  -- hint; the local card below is unaffected and stays selectable.
  local start_prs = {}
  for _, p in ipairs(inputs.prs or {}) do
    if not (p.number and resumed_pr[p.number]) then
      local entry = {}
      for k, v in pairs(p) do
        entry[k] = v
      end
      local token = type(p.headRefName) == 'string' and branch_token(p.headRefName) or nil
      entry.reviewed_locally = token ~= nil and reviewed_branch[token] == true
      entry.disabled = git.dirty or false
      entry.hint = git.dirty and DIRTY_HINT or nil
      start_prs[#start_prs + 1] = entry
    end
  end

  -- The local card adapts to the working tree — HEAD when dirty, else the
  -- default branch — and is always selectable.
  local local_card = {
    base = git.dirty and 'HEAD' or git.default_base,
    base_arg = git.dirty and nil or git.default_base,
    dirty = git.dirty or false,
  }

  return {
    loading = inputs.prs == nil,
    resume = resume,
    start = {
      prs = start_prs,
      local_card = local_card,
    },
  }
end

return M
