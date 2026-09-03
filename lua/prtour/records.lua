-- Read this repo's decoded progress records from the cache dir. Impure (globs
-- files, decodes JSON); shared by the dashboard shell and the tour's cross-tour
-- overlay so both see records enriched with the fields only the filename and
-- mtime carry: its cache `key` and `last_touched`.
local M = {}

--- @param slug string this repo's cache-key prefix (scopes records to the repo)
--- @return table[] decoded records, each with `key` and `last_touched` added
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
        records[#records + 1] = saved
      end
    end
  end
  return records
end

return M
