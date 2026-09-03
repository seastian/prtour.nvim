-- The dashboard's single pure seam: turn injected inputs into the whole
-- dashboard as plain data. It calls no `vim.*`, does no IO, and makes no
-- network calls, so it loads and runs under plain Lua and is the one place the
-- feature's decisions are tested.
--
-- Inputs (all injected by the thin impure shells):
--   slug            string  this repo's cache-key prefix (scopes records/PRs)
--   records         table[] decoded progress records for the cache dir, each
--                           { key, label, resume, seen (string[]), total,
--                             pos, last_touched (epoch) }
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

--- Shape one record into a Resume entry: a `PR`/`local` badge, the two progress
--- figures, when it was last touched, and the descriptor to resume it.
local function resume_entry(record)
  local kind = record.resume.kind
  return {
    key = record.key,
    kind = kind,
    badge = kind == 'pr' and 'PR' or 'local',
    label = record.label,
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
  local resume = {}
  for _, r in ipairs(records) do
    if is_valid(r) and in_repo(r, slug) and walked(r) < tonumber(r.total) then
      resume[#resume + 1] = resume_entry(r)
    end
  end
  table.sort(resume, function(a, b)
    return (a.last_touched or 0) > (b.last_touched or 0)
  end)
  for i = #resume, RESUME_CAP + 1, -1 do
    resume[i] = nil
  end

  -- Start: open PRs pass straight through (empty until the fetch returns); the
  -- local card adapts to the working tree — HEAD when dirty, else the default
  -- branch.
  local local_card = {
    base = git.dirty and 'HEAD' or git.default_base,
    base_arg = git.dirty and nil or git.default_base,
    dirty = git.dirty or false,
  }

  return {
    loading = inputs.prs == nil,
    resume = resume,
    start = {
      prs = inputs.prs or {},
      local_card = local_card,
    },
  }
end

return M
