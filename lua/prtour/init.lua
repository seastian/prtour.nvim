local M = {}

M.config = {
  -- Base to diff against; nil means the repo's default branch (via gh).
  base = nil,
  -- Flip GitHub's per-file "Viewed" checkbox as files are fully visited.
  mark_viewed = true,
  -- Command used to generate the reading order (instructions appended).
  claude_cmd = { 'claude', '-p' },
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
end

local function notify(msg, level)
  vim.notify('prtour: ' .. msg, level or vim.log.levels.INFO)
end

--- Entry point: pick a PR (or use the given number) and start reviewing it.
---@param pr_number integer|nil
function M.start(pr_number)
  local gh = require('prtour.gh')
  gh.is_dirty(function(dirty)
    if dirty then
      return notify('working tree has uncommitted changes — commit or stash first', vim.log.levels.ERROR)
    end
    if pr_number then
      return M._checkout(pr_number)
    end
    local p = require('prtour.progress').start 'Fetching open PRs'
    gh.list_prs(function(prs, err)
      if not prs then
        return p:fail(err)
      end
      if #prs == 0 then
        return p:fail 'no open PRs'
      end
      p:finish()
      M._pick(prs)
    end)
  end)
end

---@param prs table[]
function M._pick(prs)
  local entries, by_line = {}, {}
  for _, pr in ipairs(prs) do
    local line = string.format(
      '#%-5d %s%s  (+%d -%d, %s)',
      pr.number,
      pr.isDraft and '[draft] ' or '',
      pr.title,
      pr.additions,
      pr.deletions,
      pr.author.login
    )
    entries[#entries + 1] = line
    by_line[line] = pr
  end
  require('fzf-lua').fzf_exec(entries, {
    prompt = 'Review PR> ',
    actions = {
      ['default'] = function(selected)
        local pr = selected and by_line[selected[1]]
        if pr then
          M._checkout(pr.number)
        end
      end,
    },
  })
end

---@param number integer
function M._checkout(number)
  local gh = require('prtour.gh')
  local p = require('prtour.progress').start(('PR #%d'):format(number))
  p:report 'checking PR status'
  gh.pr_meta(number, function(meta)
    gh.head_sha(function(sha)
      if meta and sha and meta.head_oid == sha then
        -- Already on the PR head; nothing to fetch or check out.
        return M._load_hunks(number, p, meta.id)
      end
      p:report 'checking out branch'
      gh.checkout(number, function(ok, err)
        if ok then
          return M._load_hunks(number, p, meta and meta.id)
        end
        if not err:find('already used by worktree', 1, true) then
          return p:fail('checkout failed: ' .. err)
        end
        -- Branch lives in another worktree; review its head detached instead.
        p:report 'branch open in another worktree — checking out detached'
        gh.checkout_detached(number, function(ok2, err2)
          if not ok2 then
            return p:fail('detached checkout failed: ' .. err2)
          end
          M._load_hunks(number, p, meta and meta.id)
        end)
      end)
    end)
  end)
end

---@param number integer
---@param p prtour.Progress
---@param pr_id string|nil
function M._load_hunks(number, p, pr_id)
  local gh = require('prtour.gh')
  local function with_base(base)
    p:report('diffing against ' .. base)
    gh.diff(base, function(diff, err)
      if not diff then
        return p:fail('diff failed: ' .. err)
      end
      local hunks = require('prtour.hunks').parse(diff)
      if #hunks == 0 then
        return p:fail('no changes vs ' .. base)
      end
      M._start_tour(number, base, hunks, p, pr_id)
    end)
  end
  if M.config.base then
    return with_base(M.config.base)
  end
  p:report 'resolving default branch'
  gh.default_base(function(base, err)
    if not base then
      return p:fail('could not resolve default branch: ' .. err)
    end
    with_base(base)
  end)
end

---@param number integer
---@param base string
---@param hunks prtour.Hunk[]
---@param p prtour.Progress
---@param pr_id string|nil
function M._start_tour(number, base, hunks, p, pr_id)
  local gh = require('prtour.gh')
  gh.head_sha(function(sha, err)
    if not sha then
      return p:fail('rev-parse failed: ' .. err)
    end
    require('prtour.manifest').get({
      pr = number,
      sha = sha,
      hunks = hunks,
      claude_cmd = M.config.claude_cmd,
    }, p, function(steps, from_cache)
      local function launch(viewed_files)
        p:finish(('%d hunks in %d steps%s — <CR> to begin'):format(#hunks, #steps, from_cache and ' (cached)' or ''))
        require('prtour.tour').start {
          pr = number,
          pr_id = pr_id,
          sha = sha,
          base = base,
          hunks = hunks,
          steps = steps,
          mark_viewed = M.config.mark_viewed,
          viewed_files = viewed_files,
        }
        -- Node id is only needed for viewed-marking; fetch it late if we don't have it.
        if M.config.mark_viewed and not pr_id then
          gh.pr_meta(number, function(meta)
            local tour = require('prtour.tour')
            if meta and meta.id and tour.active() then
              tour.set_pr_id(meta.id)
            end
          end)
        end
      end
      if M.config.mark_viewed then
        p:report 'fetching viewed files from GitHub'
        gh.viewed_files(number, function(paths)
          launch(paths or {})
        end)
      else
        launch {}
      end
    end)
  end)
end

return M
