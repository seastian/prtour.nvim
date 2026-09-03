-- Entry point for the plain-Lua test suite. Run from the repo root:
--
--     luajit tests/run.lua
--
-- Adds the plugin's `lua/` to the module path, discovers every `*_spec.lua`
-- under `tests/`, runs them, and exits non-zero if anything failed.

local here = debug.getinfo(1, 'S').source:sub(2)
local root = here:match '(.*)/tests/run%.lua$' or '.'
package.path = ('%s/lua/?.lua;%s/lua/?/init.lua;%s'):format(root, root, package.path)

local harness = dofile(root .. '/tests/harness.lua')

-- Discover specs by listing tests/, then sort so failures read in a stable
-- order. `ls` keeps this dependency-free; the suite already assumes a Unix
-- shell to run under.
local specs = {}
local pipe = io.popen(('ls "%s/tests"'):format(root))
if pipe then
  for name in pipe:lines() do
    if name:match '_spec%.lua$' then
      specs[#specs + 1] = ('%s/tests/%s'):format(root, name)
    end
  end
  pipe:close()
end
table.sort(specs)

os.exit(harness.run(specs) == 0 and 0 or 1)
