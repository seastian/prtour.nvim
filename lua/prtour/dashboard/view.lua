-- The dashboard's pure presentation seam: turn a built model (from
-- prtour.dashboard.model) into the buffer's lines, the ordered selectable
-- entries, and highlight spans. Like the model builder it calls no `vim.*`,
-- does no IO, and makes no decisions — every choice about *what* to show lives
-- in the model; the view only decides *how* to draw it. That keeps the drawing
-- layer thin and lets rendering be tested under plain Lua.
--
-- render(model, opts) -> { lines, entries, hls }
--   opts.repo     string  repo name for the header
--   opts.now      number  epoch, for "last touched" relative times
--   opts.spinner  string  the current spinner frame (drawn while loading)
--
--   lines    string[]                       the buffer text
--   entries  { n, line, select }[]          selectable rows, in visual order;
--                                            `n` is the 1-based quick-select
--                                            number, `line` its 1-based line,
--                                            `select` a plain action descriptor
--                                            the impure layer dispatches on
--   hls      { line, col_start, col_end, group }[]  0-based highlight spans
local M = {}

--- The interpunct separator that sets a dim tag/hint off from a row's body,
--- matching the "  ·  " the resume line already uses for its meta figures.
local TAG_SEP = '  ·  '

--- The tag a PR carries when its head branch matches a prior local review.
local REVIEWED_TAG = 'reviewed locally'

--- Compact "time since" for a last-touched epoch; '' when unknown.
local function ago(then_, now)
  if type(then_) ~= 'number' then
    return ''
  end
  local d = now - then_
  if d < 60 then
    return 'just now'
  elseif d < 3600 then
    return ('%dm ago'):format(math.floor(d / 60))
  elseif d < 86400 then
    return ('%dh ago'):format(math.floor(d / 3600))
  else
    return ('%dd ago'):format(math.floor(d / 86400))
  end
end

--- ✓ all green, ✗ any failed, ● running, ' ' when there's no CI. Mirrors the
--- legacy picker but stays string-only so it's safe under plain Lua (real
--- `gh` output threads JSON nulls through, which the impure layer strips).
local function ci_icon(rollup)
  if type(rollup) ~= 'table' or #rollup == 0 then
    return ' '
  end
  local failed, pending = false, false
  for _, c in ipairs(rollup) do
    local s = c.conclusion
    if type(s) ~= 'string' or s == '' then
      s = c.state
    end
    if type(s) ~= 'string' or s == '' then
      s = c.status
    end
    s = (type(s) == 'string' and s or ''):upper()
    if s == 'FAILURE' or s == 'ERROR' or s == 'TIMED_OUT' or s == 'CANCELLED' then
      failed = true
    elseif s ~= 'SUCCESS' and s ~= 'NEUTRAL' and s ~= 'SKIPPED' and s ~= 'COMPLETED' then
      pending = true
    end
  end
  return failed and '✗' or pending and '●' or '✓'
end

--- Accumulate lines, selectable entries and highlight spans while keeping the
--- running quick-select number and line index in one place.
local function builder()
  local b = { lines = {}, entries = {}, hls = {}, n = 0 }

  function b:push(line)
    self.lines[#self.lines + 1] = line
    return #self.lines
  end

  function b:hl(line, col_start, col_end, group)
    self.hls[#self.hls + 1] = { line = line - 1, col_start = col_start, col_end = col_end, group = group }
  end

  --- Draw a selectable row: ` N  <body>`. Only the first nine rows show a
  --- quick-select number (those are the only ones bound to a key); later rows
  --- keep the same indent but no number, since they're reached with j/k. The
  --- number is highlighted and the entry records where `select` points.
  function b:entry(body, select)
    self.n = self.n + 1
    local numbered = self.n <= 9
    local prefix = (' %s  '):format(numbered and self.n or ' ')
    local line = self:push(prefix .. body)
    if numbered then
      self:hl(line, 1, 1 + #tostring(self.n), 'PrtourKey')
    end
    self.entries[#self.entries + 1] = { n = self.n, line = line, select = select }
    return line
  end

  return b
end

--- Build a Resume row body from a model resume entry.
local function resume_body(e)
  local meta = ('%s  ·  walked %d/%d'):format(e.badge, e.walked, e.total)
  return ('%-24s  %s'):format(e.label, meta)
end

--- Build a Start PR row body from a `gh`-shaped PR record.
local function pr_body(pr)
  return ('%s #%-4d %s  (+%d −%d, %s)'):format(
    ci_icon(pr.statusCheckRollup),
    pr.number,
    pr.title or '',
    pr.additions or 0,
    pr.deletions or 0,
    pr.author and pr.author.login or '?'
  )
end

--- Build the Start local-card body from the model's adaptive local card. When
--- the tree is clean but the default branch couldn't be resolved (no
--- `origin/HEAD`), `base` is nil — degrade the label rather than crash.
local function local_body(card)
  if card.dirty then
    return 'local  ·  working tree vs HEAD'
  end
  return ('local  ·  HEAD vs %s'):format(card.base or 'default branch')
end

---@param model table the built dashboard model
---@param opts { repo: string, now: number, spinner: string }
---@return table view  { lines, entries, hls }
function M.render(model, opts)
  opts = opts or {}
  local now = opts.now or 0
  local b = builder()

  local title = ('prtour — %s'):format(opts.repo or '')
  b:hl(b:push(title), 0, #title, 'PrtourKicker')
  b:push ''

  -- Resume — omitted entirely when there are no unfinished tours.
  if #model.resume > 0 then
    b:hl(b:push 'Resume', 0, #'Resume', 'PrtourTitle')
    for _, e in ipairs(model.resume) do
      local line = b:entry(resume_body(e), { action = 'resume', resume = e.resume })
      local rel = ago(e.last_touched, now)
      if rel ~= '' then
        local text = b.lines[line] .. '  ·  ' .. rel
        b.lines[line] = text
        b:hl(line, #text - #rel, #text, 'PrtourDim')
      end
    end
    b:push ''
  end

  -- Start — always shown: the local card is local data and renders instantly.
  b:hl(b:push 'Start', 0, #'Start', 'PrtourTitle')
  local card = model.start.local_card
  b:entry(local_body(card), { action = 'start_local', base_arg = card.base_arg })

  if model.loading then
    -- Spinner row: not selectable, no number. PRs stream in on refresh.
    local spin = ('    %s  loading open PRs…'):format(opts.spinner or '')
    b:hl(b:push(spin), 0, -1, 'PrtourDim')
  else
    for _, pr in ipairs(model.start.prs) do
      local body = pr_body(pr)
      if pr.disabled then
        -- The model marks a PR un-startable (a dirty tree can't check it out).
        -- Draw it aligned with the numbered rows but as a plain, whole-line-dim,
        -- unselectable row — no entry, no quick-select number — with its hint so
        -- the dimming reads as intentional.
        if pr.hint then
          body = body .. TAG_SEP .. pr.hint
        end
        b:hl(b:push('    ' .. body), 0, -1, 'PrtourDim')
      else
        local line = b:entry(body, { action = 'start_pr', number = pr.number })
        -- A PR whose head branch matches a prior local review carries a dim tag.
        if pr.reviewed_locally then
          local text = b.lines[line] .. TAG_SEP .. REVIEWED_TAG
          b.lines[line] = text
          b:hl(line, #text - #REVIEWED_TAG, #text, 'PrtourDim')
        end
      end
    end
  end

  return { lines = b.lines, entries = b.entries, hls = b.hls }
end

return M
