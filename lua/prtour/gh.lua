-- Thin async wrappers around the `gh` and `git` CLIs.
local M = {}

---@param args string[]
---@param cb fun(stdout: string|nil, err: string|nil)
local function run(args, cb)
  vim.system(args, { text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        cb(nil, vim.trim(out.stderr or ('exit code ' .. out.code)))
      else
        cb(out.stdout or '', nil)
      end
    end)
  end)
end

---@param cb fun(prs: table[]|nil, err: string|nil)
function M.list_prs(cb)
  run({ 'gh', 'pr', 'list', '--json', 'number,title,author,headRefName,isDraft,additions,deletions' }, function(stdout, err)
    if not stdout then
      return cb(nil, err)
    end
    local ok, prs = pcall(vim.json.decode, stdout)
    if not ok then
      return cb(nil, 'could not parse `gh pr list` output')
    end
    cb(prs, nil)
  end)
end

---@param number integer
---@param cb fun(ok: boolean, err: string|nil)
function M.checkout(number, cb)
  run({ 'gh', 'pr', 'checkout', tostring(number) }, function(stdout, err)
    cb(stdout ~= nil, err)
  end)
end

--- Check out a PR without claiming its branch, for when the branch is
--- already checked out in another worktree. Leaves HEAD detached.
---@param number integer
---@param cb fun(ok: boolean, err: string|nil)
function M.checkout_detached(number, cb)
  run({ 'git', 'fetch', 'origin', ('pull/%d/head'):format(number) }, function(stdout, err)
    if not stdout then
      return cb(false, err)
    end
    run({ 'git', 'checkout', '--detach', 'FETCH_HEAD' }, function(stdout2, err2)
      cb(stdout2 ~= nil, err2)
    end)
  end)
end

--- True if the working tree has uncommitted changes.
---@param cb fun(dirty: boolean)
function M.is_dirty(cb)
  run({ 'git', 'status', '--porcelain' }, function(stdout)
    cb(stdout ~= nil and vim.trim(stdout) ~= '')
  end)
end

---@param base string e.g. 'origin/master'
---@param cb fun(diff: string|nil, err: string|nil)
function M.diff(base, cb)
  run({ 'git', 'diff', '--no-color', '--no-ext-diff', base .. '...HEAD' }, cb)
end

---@param cb fun(sha: string|nil, err: string|nil)
function M.head_sha(cb)
  run({ 'git', 'rev-parse', 'HEAD' }, function(stdout, err)
    cb(stdout and vim.trim(stdout) or nil, err)
  end)
end

--- PR head commit and GraphQL node id in one API call.
---@param number integer
---@param cb fun(meta: {head_oid: string, id: string}|nil, err: string|nil)
function M.pr_meta(number, cb)
  run({ 'gh', 'pr', 'view', tostring(number), '--json', 'headRefOid,id' }, function(stdout, err)
    if not stdout then
      return cb(nil, err)
    end
    local ok, meta = pcall(vim.json.decode, stdout)
    if not ok or type(meta) ~= 'table' then
      return cb(nil, 'could not parse pr view output')
    end
    cb({ head_oid = meta.headRefOid, id = meta.id }, nil)
  end)
end

--- Flip GitHub's per-file "Viewed" checkbox for the PR.
---@param pr_id string PR GraphQL node id
---@param path string repo-relative file path
---@param cb fun(ok: boolean, err: string|nil)|nil
function M.mark_viewed(pr_id, path, cb)
  run({
    'gh', 'api', 'graphql',
    '-f', 'query=mutation($id: ID!, $path: String!) { markFileAsViewed(input: {pullRequestId: $id, path: $path}) { clientMutationId } }',
    '-f', 'id=' .. pr_id,
    '-f', 'path=' .. path,
  }, function(stdout, err)
    if cb then
      cb(stdout ~= nil, err)
    end
  end)
end

--- Repo owner/name, from the origin remote URL when possible (no network).
---@param cb fun(owner: string|nil, name: string|nil, err: string|nil)
local function repo_slug(cb)
  run({ 'git', 'remote', 'get-url', 'origin' }, function(stdout)
    local url = stdout and vim.trim(stdout) or ''
    local owner, name = url:match 'github%.com[:/]([^/]+)/([^/]+)$'
    if owner and name then
      return cb(owner, (name:gsub('%.git$', '')), nil)
    end
    run({ 'gh', 'repo', 'view', '--json', 'owner,name', '-q', '.owner.login + " " + .name' }, function(stdout2, err)
      if not stdout2 then
        return cb(nil, nil, err)
      end
      local o, n = vim.trim(stdout2):match '^(%S+) (%S+)$'
      cb(o, n, o and nil or 'could not resolve repo owner/name')
    end)
  end)
end

--- Paths the viewer has already marked as viewed on GitHub.
---@param number integer
---@param cb fun(paths: string[]|nil, err: string|nil)
function M.viewed_files(number, cb)
  repo_slug(function(owner, name, err)
    if not owner then
      return cb(nil, err)
    end
    run({
      'gh', 'api', 'graphql', '--paginate',
      '-f', 'query=query($owner: String!, $name: String!, $number: Int!, $endCursor: String) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { files(first: 100, after: $endCursor) { pageInfo { hasNextPage endCursor } nodes { path viewerViewedState } } } } }',
      '-f', 'owner=' .. owner,
      '-f', 'name=' .. name,
      '-F', 'number=' .. number,
      '--jq', '.data.repository.pullRequest.files.nodes[] | select(.viewerViewedState == "VIEWED") | .path',
    }, function(stdout2, err2)
      if not stdout2 then
        return cb(nil, err2)
      end
      cb(vim.split(vim.trim(stdout2), '\n', { trimempty = true }), nil)
    end)
  end)
end

--- Decode one line of `gh --jq '... | @json'` output (raw or quoted JSON).
local function decode_jq_line(line)
  local ok, v = pcall(vim.json.decode, line)
  if not ok then
    return nil
  end
  if type(v) == 'string' then
    local ok2, v2 = pcall(vim.json.decode, v)
    return ok2 and v2 or nil
  end
  return v
end

--- Review threads of a PR (path, anchor line, resolution, comments).
---@param number integer
---@param cb fun(threads: table[]|nil, err: string|nil)
function M.review_threads(number, cb)
  repo_slug(function(owner, name, err)
    if not owner then
      return cb(nil, err)
    end
    run({
      'gh', 'api', 'graphql', '--paginate',
      '-f', 'query=query($owner: String!, $name: String!, $number: Int!, $endCursor: String) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { reviewThreads(first: 50, after: $endCursor) { pageInfo { hasNextPage endCursor } nodes { isResolved isOutdated path line comments(first: 30) { nodes { body databaseId state author { login } } } } } } } }',
      '-f', 'owner=' .. owner,
      '-f', 'name=' .. name,
      '-F', 'number=' .. number,
      '--jq', '.data.repository.pullRequest.reviewThreads.nodes[] | @json',
    }, function(stdout, err2)
      if not stdout then
        return cb(nil, err2)
      end
      local threads = {}
      for line in vim.gsplit(vim.trim(stdout), '\n', { trimempty = true }) do
        local node = decode_jq_line(line)
        if type(node) == 'table' and node.path then
          local comments = {}
          for _, c in ipairs(node.comments.nodes or {}) do
            comments[#comments + 1] = {
              author = c.author and c.author.login or '?',
              body = c.body or '',
              database_id = c.databaseId,
              pending = c.state == 'PENDING',
            }
          end
          threads[#threads + 1] = {
            path = node.path,
            line = node.line,
            is_resolved = node.isResolved,
            is_outdated = node.isOutdated,
            comments = comments,
          }
        end
      end
      cb(threads, nil)
    end)
  end)
end

--- Immediate reply to an existing review comment.
---@param number integer
---@param comment_id integer databaseId of the thread's first comment
---@param body string
---@param cb fun(ok: boolean, err: string|nil)
function M.reply(number, comment_id, body, cb)
  run({
    'gh', 'api', ('repos/{owner}/{repo}/pulls/%d/comments/%d/replies'):format(number, comment_id),
    '-f', 'body=' .. body,
  }, function(stdout, err)
    cb(stdout ~= nil, err)
  end)
end

--- Repo default branch as 'origin/<name>', resolved locally when possible.
---@param cb fun(base: string|nil, err: string|nil)
function M.default_base(cb)
  run({ 'git', 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD' }, function(stdout)
    local ref = stdout and vim.trim(stdout)
    if ref and ref ~= '' then
      return cb(ref, nil)
    end
    run({ 'gh', 'repo', 'view', '--json', 'defaultBranchRef', '-q', '.defaultBranchRef.name' }, function(stdout2, err)
      if not stdout2 then
        return cb(nil, err)
      end
      cb('origin/' .. vim.trim(stdout2), nil)
    end)
  end)
end

return M
