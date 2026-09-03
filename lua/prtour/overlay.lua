-- Cross-tour "reviewed-earlier" overlay (ADR-0001). Pure: no `vim.*`, no IO, so
-- the harness exercises it directly.
--
-- A hunk's seen-identity is sha256(path + body), so identical content shares a
-- hash across same-repo tours. "Reviewed-earlier" for a tour is the content some
-- OTHER same-repo tour has walked that this tour has not walked itself:
-- `union(other tours' seen) − (this tour's own seen)`. It is derived, never
-- stored — the tour's own `seen` set stays walked-here only — and recomputed on
-- every load, so a later review widens coverage next time with no migration.
local M = {}

--- Reviewed-earlier hash set for a tour.
---@param records { key: string, seen: string[] }[]|nil same-repo progress records
---@param this_key string  the tour's own cache key, excluded from the union
---@param own_seen table<string, boolean>|nil  hashes this tour has walked here
---@return table<string, boolean>  reviewed-earlier hash set
function M.reviewed_earlier(records, this_key, own_seen)
  own_seen = own_seen or {}
  local overlay = {}
  for _, r in ipairs(records or {}) do
    if type(r) == 'table' and r.key ~= this_key and type(r.seen) == 'table' then
      for _, hash in ipairs(r.seen) do
        if type(hash) == 'string' and not own_seen[hash] then
          overlay[hash] = true
        end
      end
    end
  end
  return overlay
end

return M
