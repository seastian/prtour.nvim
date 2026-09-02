-- Parse unified diff output into a flat list of hunks.
local M = {}

---@class prtour.Hunk
---@field id integer stable within one diff
---@field file string path in the new tree (old path for deleted files)
---@field deleted boolean file was deleted by the PR
---@field added boolean file is new in the PR
---@field start_line integer first line of the hunk in the new file (old file if deleted)
---@field line_count integer
---@field lines string[] raw diff lines of the hunk body

---@param diff string raw `git diff` output
---@return prtour.Hunk[]
function M.parse(diff)
  local hunks = {}
  local old_path, new_path
  local current
  for line in (diff .. '\n'):gmatch('(.-)\n') do
    if line:match('^diff %-%-git ') then
      old_path, new_path, current = nil, nil, nil
    elseif line:match('^%-%-%- ') then
      old_path = line:match('^%-%-%- a/(.+)$') -- nil for /dev/null (added file)
    elseif line:match('^%+%+%+ ') then
      new_path = line:match('^%+%+%+ b/(.+)$') -- nil for /dev/null (deleted file)
    else
      local old_start, new_start, new_count = line:match('^@@ %-(%d+),?%d* %+(%d+),?(%d*) @@')
      if new_start then
        local deleted = new_path == nil
        current = {
          id = #hunks + 1,
          file = new_path or old_path,
          deleted = deleted,
          added = old_path == nil,
          start_line = deleted and tonumber(old_start) or tonumber(new_start),
          line_count = new_count ~= '' and tonumber(new_count) or 1,
          lines = {},
        }
        hunks[#hunks + 1] = current
      elseif current and line:match('^[%+%- \\]') then
        current.lines[#current.lines + 1] = line
      end
    end
  end
  M.fingerprint(hunks)
  return hunks
end

--- Position-independent identity: same file + same change = same hash,
--- so "seen" survives rebases, force-pushes and unrelated edits.
--- Also derives change_line: start_line points at the hunk's leading
--- CONTEXT lines (3 by default); the first +/- line is what to jump to.
---@param hunks prtour.Hunk[]
function M.fingerprint(hunks)
  for _, h in ipairs(hunks) do
    h.hash = vim.fn.sha256(h.file .. '\0' .. table.concat(h.lines, '\n'))
    local offset = 0
    for _, l in ipairs(h.lines) do
      local c = l:sub(1, 1)
      if c == '+' or c == '-' then
        break
      end
      offset = offset + 1
    end
    h.change_line = h.start_line + offset
  end
end

return M
