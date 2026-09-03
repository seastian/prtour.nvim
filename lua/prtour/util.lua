local M = {}

--- Word-wrap text (which may already contain newlines) to a display width.
---@param text string
---@param width integer
---@return string[]
function M.wrap(text, width)
  local out = {}
  for _, raw in ipairs(vim.split(text, '\n')) do
    if raw == '' then
      out[#out + 1] = ''
    else
      local line = ''
      local function flush()
        if line ~= '' then
          out[#out + 1] = line
          line = ''
        end
      end
      for word in raw:gmatch '%S+' do
        while vim.fn.strdisplaywidth(word) > width do
          flush()
          out[#out + 1] = vim.fn.strcharpart(word, 0, width)
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
    end
  end
  return out
end

--- Sensible width for inline annotation blocks.
---@return integer
function M.annotation_width()
  return math.max(40, math.min(100, vim.o.columns - 12))
end

return M
