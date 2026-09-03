-- Exercises the pure helpers of prtour.manifest under plain Lua: the streaming
-- display logic (what the status line shows as Claude's narration streams in),
-- the stream-json delta extraction, and the answer normalisation. The module's
-- IO/`vim.*` paths (run_claude, ticker, caching) are covered by the headless
-- end-to-end test, not here.
local manifest = require 'prtour.manifest'

local display = manifest._display_line
local delta = manifest._extract_delta
local validate = manifest._validate
local fallback = manifest._fallback_steps

describe('manifest — streaming display line', function()
  it('shows the last non-empty narration line', function()
    eq(display 'foundations first\nthe request handler\n', 'the request handler')
  end)

  it('ignores blank lines when picking the latest', function()
    eq(display 'foundations first\n\n', 'foundations first')
  end)

  it('never shows the JSON manifest — only narration before the first brace', function()
    eq(display 'foundations first\nthen the logic\n{"steps":[', 'then the logic')
  end)

  it('returns nil for a JSON-only reply (no narration to show)', function()
    is_nil(display '{"steps":[{"title":"x","hunks":[1]}]}')
  end)

  it('returns nil before any text has streamed', function()
    is_nil(display '')
  end)

  it('trims surrounding whitespace from the shown line', function()
    eq(display '  foundations first  \n', 'foundations first')
  end)
end)

describe('manifest — stream-json delta extraction', function()
  it('pulls the text out of a content_block_delta event', function()
    local ev = { type = 'stream_event', event = { type = 'content_block_delta', delta = { type = 'text_delta', text = 'Ap' } } }
    eq(delta(ev), 'Ap')
  end)

  it('returns nil for non-delta events', function()
    is_nil(delta { type = 'stream_event', event = { type = 'message_start' } })
    is_nil(delta { type = 'result', result = 'done' })
    is_nil(delta 'not a table')
    is_nil(delta { type = 'stream_event', event = { type = 'content_block_delta', delta = {} } })
  end)
end)

describe('manifest — answer normalisation (validate)', function()
  local hunks = { { id = 1 }, { id = 2 }, { id = 3 } }

  it('drops unknown ids and de-dupes repeats', function()
    local out = validate({ { title = 'A', hunks = { 1, 1, 99 } }, { title = 'B', hunks = { 2 } } }, hunks)
    eq(out[1], { title = 'A', note = nil, hunks = { 1 } })
    eq(out[2], { title = 'B', note = nil, hunks = { 2 } })
  end)

  it('appends any hunks the model forgot under a catch-all step', function()
    local out = validate({ { title = 'A', hunks = { 1 } } }, hunks)
    eq(out[#out], { title = 'Not covered by the tour plan', hunks = { 2, 3 } })
  end)

  it('returns nil for an empty or malformed plan', function()
    is_nil(validate({}, hunks))
    is_nil(validate('nope', hunks))
  end)
end)

describe('manifest — fallback ordering', function()
  it('is one step per file in diff order', function()
    local out = fallback {
      { id = 1, file = 'a.lua' },
      { id = 2, file = 'a.lua' },
      { id = 3, file = 'b.lua' },
    }
    eq(#out, 2)
    eq(out[1], { title = 'a.lua', hunks = { 1, 2 } })
    eq(out[2], { title = 'b.lua', hunks = { 3 } })
  end)
end)
