-- Minimal plain-Lua test harness. Runs prtour's pure modules without a
-- running Neovim, so `vim.*`-free code can be exercised under luajit/lua.
--
-- It exposes a tiny describe/it DSL plus deep-equality assertions, collects
-- results, and reports a summary. `run(specs)` returns the failure count so a
-- caller can set the process exit status.
local H = {}

local passed, failed, failures = 0, 0, {}
local current = '(top level)'

--- Render a value for assertion messages: tables are shown one level deep,
--- which is enough to read model fixtures without drowning in nesting.
local function fmt(v, depth)
  depth = depth or 0
  if type(v) == 'string' then
    return ('%q'):format(v)
  elseif type(v) ~= 'table' then
    return tostring(v)
  end
  if depth >= 3 then
    return '{...}'
  end
  local parts, seen_array = {}, 0
  for i, item in ipairs(v) do
    parts[#parts + 1] = fmt(item, depth + 1)
    seen_array = i
  end
  local keys = {}
  for k in pairs(v) do
    if not (type(k) == 'number' and k >= 1 and k <= seen_array) then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = ('%s = %s'):format(tostring(k), fmt(v[k], depth + 1))
  end
  return '{ ' .. table.concat(parts, ', ') .. ' }'
end
H.fmt = fmt

--- Structural equality: same scalars, or tables equal key-by-key both ways.
local function deep_eq(a, b)
  if a == b then
    return true
  end
  if type(a) ~= 'table' or type(b) ~= 'table' then
    return false
  end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end
H.deep_eq = deep_eq

function H.describe(name, fn)
  local prev = current
  current = name
  fn()
  current = prev
end

function H.it(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write '.'
  else
    failed = failed + 1
    failures[#failures + 1] = ('%s › %s\n    %s'):format(current, name, tostring(err))
    io.write 'F'
  end
end

--- Deep-equality assertion; raises with both sides rendered on mismatch.
function H.eq(actual, expected, msg)
  if not deep_eq(actual, expected) then
    error(('%sexpected %s\n         got %s'):format(msg and (msg .. ': ') or '', fmt(expected), fmt(actual)), 2)
  end
end

function H.ok(value, msg)
  if not value then
    error(msg or 'expected a truthy value, got ' .. fmt(value), 2)
  end
end

function H.is_nil(value, msg)
  if value ~= nil then
    error((msg or 'expected nil, got ') .. fmt(value), 2)
  end
end

--- Load and run each spec file (paths relative to repo root), then report.
---@param specs string[]
---@return integer failed count
function H.run(specs)
  -- Publish the DSL as globals so specs read cleanly.
  for _, name in ipairs { 'describe', 'it', 'eq', 'ok', 'is_nil' } do
    _G[name] = H[name]
  end
  for _, spec in ipairs(specs) do
    dofile(spec)
  end
  io.write '\n'
  for _, f in ipairs(failures) do
    io.write('\nFAIL  ' .. f .. '\n')
  end
  io.write(('\n%d passed, %d failed\n'):format(passed, failed))
  return failed
end

return H
