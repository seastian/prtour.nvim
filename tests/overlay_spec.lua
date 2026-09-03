-- The cross-tour "reviewed-earlier" overlay (ADR-0001), exercised at its pure
-- seam. A hunk's seen-identity is sha256(path + body), so identical content
-- shares a hash across same-repo tours; reviewed-earlier for a tour is the
-- content other tours have walked that this tour has not walked itself.
local overlay = require 'prtour.overlay'

describe('overlay.reviewed_earlier', function()
  it('unions the OTHER same-repo tours\' seen sets', function()
    local records = {
      { key = 'r-pr-1', seen = { 'a', 'b' } },
      { key = 'r-local-main', seen = { 'b', 'c' } },
    }
    eq(overlay.reviewed_earlier(records, 'r-pr-2', {}), { a = true, b = true, c = true })
  end)

  it('excludes this tour\'s own record from the union, by key', function()
    -- The on-disk record for this tour's key never counts as reviewed-earlier,
    -- even when this tour hasn't walked those hunks in memory yet.
    local records = { { key = 'r-pr-1', seen = { 'x', 'y' } } }
    eq(overlay.reviewed_earlier(records, 'r-pr-1', {}), {})
  end)

  it('subtracts hashes this tour has already walked here', function()
    local records = { { key = 'r-local-main', seen = { 'a', 'b' } } }
    -- `a` is walked here, so it is seen-here, not reviewed-earlier.
    eq(overlay.reviewed_earlier(records, 'r-pr-1', { a = true }), { b = true })
  end)

  it('carries identical content over but not changed content', function()
    -- Tour A walked hashX; this tour's own (changed) content hashes to hashY.
    local records = {
      { key = 'r-local-main', seen = { 'hashX' } },
      { key = 'r-pr-9', seen = { 'hashY' } },
    }
    local got = overlay.reviewed_earlier(records, 'r-pr-9', { hashY = true })
    eq(got, { hashX = true })
    is_nil(got.hashY)
  end)

  it('is defensive about malformed records and hashes', function()
    local records = {
      'not-a-table',
      { key = 'r-pr-1' }, -- no seen field
      { key = 'r-x', seen = { 42, 'ok' } }, -- non-string hash is skipped
    }
    eq(overlay.reviewed_earlier(records, 'r-pr-1', {}), { ok = true })
  end)

  it('tolerates nil inputs', function()
    eq(overlay.reviewed_earlier(nil, 'k', nil), {})
  end)
end)
