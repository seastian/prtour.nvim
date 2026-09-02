-- Claude Code integration: headless questions and tmux handoff for changes.
local M = {}

---@param ctx {pr: integer, file: string, start_line: integer, line_count: integer, diff: string}
---@param question string
---@param cb fun(answer: string|nil, err: string|nil)
function M.ask(ctx, question, cb)
  local cmd = vim.deepcopy(require('prtour').config.claude_cmd or { 'claude', '-p' })
  cmd[#cmd + 1] = 'You are assisting a code review in this repository. stdin has the hunk under review and a question. Answer concisely for an expert reviewer — a short paragraph, code only if essential. Read repository files if you need more context.'
  cmd[#cmd + 1] = '--allowedTools=Read,Grep,Glob'
  local last_line = ctx.start_line + math.max(ctx.line_count - 1, 0)
  local stdin = ('PR #%d — %s (around lines %d-%d)\n\nHunk diff:\n%s\n\nQuestion: %s'):format(
    ctx.pr, ctx.file, ctx.start_line, last_line, ctx.diff, question
  )
  vim.system(cmd, { text = true, stdin = stdin }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        return cb(nil, vim.trim(out.stderr or 'claude failed'))
      end
      cb(vim.trim(out.stdout or ''), nil)
    end)
  end)
end

--- tmux panes that look like Claude Code sessions.
---@param cb fun(panes: {id: string, label: string}[]|nil, err: string|nil)
function M.panes(cb)
  vim.system(
    { 'tmux', 'list-panes', '-a', '-F', '#{pane_id}\t#{session_name}:#{window_index}.#{pane_index} #{window_name}\t#{pane_current_command}' },
    { text = true },
    function(out)
      vim.schedule(function()
        if out.code ~= 0 then
          return cb(nil, 'tmux not available')
        end
        local panes = {}
        for line in vim.gsplit(out.stdout or '', '\n', { trimempty = true }) do
          local id, label, cmdname = line:match '^(%%%d+)\t(.-)\t(.*)$'
          if id and (cmdname == 'claude' or label:match 'claude') then
            panes[#panes + 1] = { id = id, label = label }
          end
        end
        cb(panes, nil)
      end)
    end
  )
end

--- Paste text into a tmux pane (bracketed, so newlines don't submit early),
--- then press Enter.
---@param pane_id string
---@param text string
---@param cb fun(ok: boolean, err: string|nil)
function M.send(pane_id, text, cb)
  local function fail(msg)
    vim.schedule(function()
      cb(false, msg)
    end)
  end
  vim.system({ 'tmux', 'load-buffer', '-b', 'prtour', '-' }, { stdin = text }, function(out)
    if out.code ~= 0 then
      return fail 'tmux load-buffer failed'
    end
    vim.system({ 'tmux', 'paste-buffer', '-p', '-d', '-b', 'prtour', '-t', pane_id }, {}, function(out2)
      if out2.code ~= 0 then
        return fail 'tmux paste-buffer failed'
      end
      -- Let the TUI ingest the paste before submitting.
      vim.defer_fn(function()
        vim.system({ 'tmux', 'send-keys', '-t', pane_id, 'Enter' }, {}, function(out3)
          vim.schedule(function()
            cb(out3.code == 0, out3.code ~= 0 and 'tmux send-keys failed' or nil)
          end)
        end)
      end, 200)
    end)
  end)
end

--- Show an answer in a centered, scrollable markdown float.
---@param question string
---@param answer string
function M.show_answer(question, answer)
  local lines = { '# ' .. question, '' }
  vim.list_extend(lines, vim.split(answer, '\n'))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modifiable = false
  local width = math.min(80, vim.o.columns - 8)
  local height = math.min(#lines + 1, math.max(8, vim.o.lines - 10))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' Claude ',
    title_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  for _, k in ipairs { 'q', '<Esc>' } do
    vim.keymap.set('n', k, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf })
  end
end

return M
