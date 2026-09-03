-- Read this repo's decoded progress records from the cache dir. Impure (globs
-- files, decodes JSON); shared by the dashboard shell and the tour's cross-tour
-- overlay so both see records enriched with the fields only the filename, mtime,
-- and sibling manifest carry: its cache `key`, `last_touched`, and `hunks`.
local M = {}

--- The tour's hunk-hash set, read from its cached manifest (`manifest-<key>`,
--- keyed identically to the progress file). Flattened across the manifest's
--- steps and de-duplicated, since the dashboard only needs the set to intersect
--- with the reviewed-earlier overlay when counting covered hunks (ADR-0001).
--- Returns nil when no manifest is cached, so coverage degrades to walked-here.
local function manifest_hashes(dir, key)
  local f = io.open(('%s/manifest-%s.json'):format(dir, key), 'r')
  if not f then
    return nil
  end
  local ok, saved = pcall(vim.json.decode, f:read '*a')
  f:close()
  if not (ok and type(saved) == 'table' and type(saved.steps) == 'table') then
    return nil
  end
  local seen, hashes = {}, {}
  for _, step in ipairs(saved.steps) do
    for _, hash in ipairs(type(step) == 'table' and step.hunks or {}) do
      if type(hash) == 'string' and not seen[hash] then
        seen[hash] = true
        hashes[#hashes + 1] = hash
      end
    end
  end
  return hashes
end

--- @param slug string this repo's cache-key prefix (scopes records to the repo)
--- @return table[] decoded records, each with `key`, `last_touched`, `hunks` added
function M.read(slug)
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
        saved.hunks = manifest_hashes(dir, saved.key)
        records[#records + 1] = saved
      end
    end
  end
  return records
end

return M
