local M = {}

M.config = {
  -- Base to diff against; nil means the repo's default branch (via gh).
  base = nil,
  -- Flip GitHub's per-file "Viewed" checkbox as files are fully visited.
  mark_viewed = true,
  -- Command used for headless Claude calls (instructions appended).
  claude_cmd = { 'claude', '-p' },
  -- Models per task; nil falls back to the CLI default.
  models = {
    manifest = 'claude-sonnet-5',
    ask = 'claude-sonnet-5',
  },
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  -- Prune stale manifest/progress caches; content-hash keys accrete forever.
  vim.defer_fn(function()
    local dir = vim.fn.stdpath 'cache' .. '/prtour'
    local cutoff = os.time() - 45 * 86400
    for _, f in ipairs(vim.fn.glob(dir .. '/*.json', false, true)) do
      if vim.fn.getftime(f) < cutoff then
        os.remove(f)
      end
    end
  end, 2000)
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

--- Cache keys are scoped per repo: PR numbers and branch names collide
--- across repositories. Exposed so the dashboard scopes to the same slug.
function M.repo_slug()
  local top = vim.trim(vim.fn.system { 'git', 'rev-parse', '--show-toplevel' })
  if vim.v.shell_error ~= 0 or top == '' then
    return 'norepo'
  end
  return vim.fn.fnamemodify(top, ':t'):gsub('[^%w%-_]', '-') .. '-' .. vim.fn.sha256(top):sub(1, 4)
end
local repo_slug = M.repo_slug

--- One key for everything: context actions during a tour, dashboard otherwise.
function M.launcher()
  local tour = require('prtour.tour')
  if tour.active() then
    return tour.actions()
  end
  require('prtour.dashboard').open()
end

--- Review local changes (no PR): working tree vs HEAD, or vs the merge-base
--- of a given ref ('master', 'origin/master', ...).
---@param base_arg string|nil
---@param sopts {preserve_comments: boolean}|nil
function M.start_local(base_arg, sopts)
  sopts = sopts or {}
  local gh = require('prtour.gh')
  local p = require('prtour.progress').start 'Local review'
  local function go(base, base_label)
    p:report('diffing against ' .. base_label)
    gh.diff_worktree(base, function(diff, err)
      if not diff then
        return p:fail('diff failed: ' .. err)
      end
      gh.untracked(function(untracked)
        local hunks_mod = require('prtour.hunks')
        local hunks = hunks_mod.parse(diff)
        for _, path in ipairs(untracked) do
          local ok, flines = pcall(vim.fn.readfile, path)
          if ok and #flines > 0 then
            local lines = {}
            for _, l in ipairs(flines) do
              lines[#lines + 1] = '+' .. l
            end
            hunks[#hunks + 1] = {
              id = #hunks + 1,
              file = path,
              deleted = false,
              added = true,
              start_line = 1,
              line_count = #flines,
              lines = lines,
            }
          end
        end
        hunks_mod.fingerprint(hunks)
        if #hunks == 0 then
          return p:fail('no local changes vs ' .. base_label)
        end
        local branch = vim.trim(vim.fn.system { 'git', 'branch', '--show-current' })
        branch = branch ~= '' and branch or 'detached'
        local key = repo_slug() .. '-local-' .. branch:gsub('[^%w%-_]', '-')
        local hashes = {}
        for _, h in ipairs(hunks) do
          hashes[#hashes + 1] = h.hash
        end
        local diff_hash = vim.fn.sha256(table.concat(hashes, ''))
        require('prtour.manifest').get({
          key = key,
          sha = diff_hash,
          hunks = hunks,
          claude_cmd = M.config.claude_cmd,
        }, p, function(steps, from_cache)
          p:finish(('%d hunks in %d steps%s — <CR> to begin'):format(#hunks, #steps, from_cache and ' (cached)' or ''))
          if not from_cache then
            require('prtour.alert').ping(('%s tour ready — %d hunks in %d steps'):format(branch, #hunks, #steps))
          end
          require('prtour.tour').start {
            key = key,
            label = branch .. ' (local)',
            resume = { kind = 'local', base_arg = base_arg },
            sha = diff_hash,
            base = base,
            hunks = hunks,
            steps = steps,
            mark_viewed = false,
            preserve_comments = sopts.preserve_comments,
          }
        end)
      end)
    end)
  end
  if not base_arg then
    return go('HEAD', 'HEAD')
  end
  require('prtour.gh').merge_base(base_arg, function(mb, err)
    if not mb then
      return p:fail('merge-base failed: ' .. err)
    end
    go(mb, base_arg .. ' (merge-base)')
  end)
end

--- ✓ all checks green, ✗ any failed, ● running, blank when no CI.
local function ci_icon(rollup)
  if type(rollup) ~= 'table' or #rollup == 0 then
    return ' '
  end
  local failed, pending = false, false
  for _, c in ipairs(rollup) do
    local s = c.conclusion
    if s == nil or s == vim.NIL or s == '' then
      s = c.state or c.status or ''
    end
    s = tostring(s):upper()
    if s == 'FAILURE' or s == 'ERROR' or s == 'TIMED_OUT' or s == 'CANCELLED' then
      failed = true
    elseif s ~= 'SUCCESS' and s ~= 'NEUTRAL' and s ~= 'SKIPPED' and s ~= 'COMPLETED' then
      pending = true
    end
  end
  return failed and '✗' or pending and '●' or '✓'
end

---@param prs table[]
function M._pick(prs)
  local entries, by_line = {}, {}
  for _, pr in ipairs(prs) do
    local line = string.format(
      '%s #%-5d %s%s  (+%d -%d, %s)',
      ci_icon(pr.statusCheckRollup),
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
    local base_ref = meta and meta.base_ref
    gh.head_sha(function(sha)
      if meta and sha and meta.head_oid == sha then
        -- Already on the PR head; nothing to fetch or check out.
        return M._load_hunks(number, p, meta.id, base_ref)
      end
      p:report 'checking out branch'
      gh.checkout(number, function(ok, err)
        if ok then
          return M._load_hunks(number, p, meta and meta.id, base_ref)
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
          M._load_hunks(number, p, meta and meta.id, base_ref)
        end)
      end)
    end)
  end)
end

---@param number integer
---@param p prtour.Progress
---@param pr_id string|nil
---@param base_ref string|nil the PR's declared base branch
function M._load_hunks(number, p, pr_id, base_ref)
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
      local lock_cmds, seen_locks = {}, {}
      local INSTALLERS = {
        ['pnpm-lock.yaml'] = { 'pnpm', 'install' },
        ['package-lock.json'] = { 'npm', 'install' },
        ['yarn.lock'] = { 'yarn', 'install' },
        ['spago.lock'] = { 'spago', 'install' },
      }
      for _, h in ipairs(hunks) do
        local cmd = INSTALLERS[h.file:match '([^/]+)$']
        if cmd and not seen_locks[h.file] then
          seen_locks[h.file] = true
          lock_cmds[#lock_cmds + 1] = { file = h.file, dir = vim.fn.fnamemodify(h.file, ':h'), cmd = cmd }
        end
      end
      M._start_tour(number, base, hunks, p, pr_id, lock_cmds)
    end)
  end
  if M.config.base then
    return with_base(M.config.base)
  end
  if base_ref then
    -- Diff against the PR's declared base, which matters for stacked PRs.
    -- Non-default bases move and get rebased onto; fetch those first.
    local default = vim.trim(vim.fn.system { 'git', 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD' })
    if 'origin/' .. base_ref == default then
      return with_base(default)
    end
    p:report('fetching base branch ' .. base_ref)
    return vim.system({ 'git', 'fetch', 'origin', base_ref }, { text = true }, function()
      vim.schedule(function()
        with_base('origin/' .. base_ref)
      end)
    end)
  end
  p:report 'resolving default branch'
  gh.default_base(function(base, err)
    if not base then
      return p:fail('could not resolve default branch: ' .. err)
    end
    with_base(base)
  end)
end

local function file_hash(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local content = f:read '*a'
  f:close()
  return vim.fn.sha256(content)
end

-- Files the package manager writes on install; newer than the lockfile
-- means the install already ran (by any means, prtour or manual).
local INSTALL_MARKERS = {
  npm = 'node_modules/.package-lock.json',
  yarn = 'node_modules/.yarn-integrity',
}

local function install_needed(l)
  local prefix = l.dir == '.' and '' or l.dir .. '/'
  if l.cmd[1] == 'pnpm' then
    -- pnpm keeps a copy of the lockfile it installed; identical content
    -- means up to date regardless of mtimes (checkouts bump them).
    local installed = file_hash(prefix .. 'node_modules/.pnpm/lock.yaml')
    return installed == nil or installed ~= file_hash(l.file)
  end
  local marker = INSTALL_MARKERS[l.cmd[1]]
  if not marker then
    return true
  end
  local mtime = vim.fn.getftime(prefix .. marker)
  return mtime == -1 or mtime < vim.fn.getftime(l.file)
end

--- Changed lockfiles that still need installing: offer to run them.
---@param locks {file: string, dir: string, cmd: string[]}[]
function M._offer_installs(locks)
  locks = vim.tbl_filter(install_needed, locks)
  if #locks == 0 then
    return
  end
  local function run_one(l, done)
    local label = ('%s (%s/)'):format(table.concat(l.cmd, ' '), l.dir)
    local p = require('prtour.progress').start(label)
    p:report 'running'
    vim.system(l.cmd, { cwd = l.dir ~= '.' and l.dir or nil, text = true }, function(out)
      vim.schedule(function()
        if out.code == 0 then
          p:finish 'done'
        else
          p:fail(('%s failed: %s'):format(label, vim.trim(out.stderr or ''):sub(1, 120)))
        end
        if done then
          done()
        end
      end)
    end)
  end
  local items = {}
  if #locks > 1 then
    items[#items + 1] = ('run all %d installs'):format(#locks)
  end
  for _, l in ipairs(locks) do
    items[#items + 1] = ('run `%s` in %s/'):format(table.concat(l.cmd, ' '), l.dir)
  end
  items[#items + 1] = 'skip'
  vim.ui.select(items, { prompt = 'Lockfiles changed since last install — run now?' }, function(_, idx)
    if not idx or idx == #items then
      return
    end
    local offset = #locks > 1 and 1 or 0
    if offset == 1 and idx == 1 then
      local i = 0
      local function step()
        i = i + 1
        if locks[i] then
          run_one(locks[i], step)
        end
      end
      step()
    else
      run_one(locks[idx - offset])
    end
  end)
end

---@param number integer
---@param base string
---@param hunks prtour.Hunk[]
---@param p prtour.Progress
---@param pr_id string|nil
---@param locks table[]|nil
function M._start_tour(number, base, hunks, p, pr_id, locks)
  local gh = require('prtour.gh')
  gh.head_sha(function(sha, err)
    if not sha then
      return p:fail('rev-parse failed: ' .. err)
    end
    local key = repo_slug() .. '-pr-' .. number
    require('prtour.manifest').get({
      key = key,
      sha = sha,
      hunks = hunks,
      claude_cmd = M.config.claude_cmd,
    }, p, function(steps, from_cache)
      local function launch(viewed_files)
        p:finish(('%d hunks in %d steps%s — <CR> to begin'):format(#hunks, #steps, from_cache and ' (cached)' or ''))
        if not from_cache then
          require('prtour.alert').ping(('PR #%d tour ready — %d hunks in %d steps'):format(number, #hunks, #steps))
        end
        require('prtour.tour').start {
          pr = number,
          pr_id = pr_id,
          key = key,
          resume = { kind = 'pr', pr = number },
          sha = sha,
          base = base,
          hunks = hunks,
          steps = steps,
          mark_viewed = M.config.mark_viewed,
          viewed_files = viewed_files,
        }
        -- Install offer only after the tour has rendered, so its picker
        -- cannot race the first hunk's window.
        if locks and #locks > 0 then
          vim.schedule(function()
            M._offer_installs(locks)
          end)
        end
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
