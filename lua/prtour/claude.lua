-- Claude Code integration: headless questions and tmux handoff for changes.
local M = {}

---@param ctx {pr: integer|nil, label: string|nil, file: string, start_line: integer, line_count: integer, diff: string}
---@param question string
---@param cb fun(answer: string|nil, err: string|nil)
function M.ask(ctx, question, cb)
  local config = require('prtour').config
  local cmd = vim.deepcopy(config.claude_cmd or { 'claude', '-p' })
  cmd[#cmd + 1] = 'You are assisting a code review in this repository. stdin has the hunk under review and a question. Answer concisely for an expert reviewer — a short paragraph, code only if essential. Read repository files if you need more context.'
  cmd[#cmd + 1] = '--allowedTools=Read,Grep,Glob'
  local model = (config.models or {}).ask
  if model then
    cmd[#cmd + 1] = '--model=' .. model
  end
  local last_line = ctx.start_line + math.max(ctx.line_count - 1, 0)
  local what = ctx.label or (ctx.pr and ('PR #' .. ctx.pr)) or 'local changes'
  local parts = {
    ('Reviewing %s — %s (around lines %d-%d)'):format(what, ctx.file, ctx.start_line, last_line),
    '',
    'Hunk diff:',
    ctx.diff,
  }
  if ctx.history then
    parts[#parts + 1] = ''
    parts[#parts + 1] = 'Earlier in this conversation:'
    parts[#parts + 1] = ctx.history
  end
  parts[#parts + 1] = ''
  parts[#parts + 1] = 'Question: ' .. question
  local stdin = table.concat(parts, '\n')
  vim.system(cmd, { text = true, stdin = stdin }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        return cb(nil, vim.trim(out.stderr or 'claude failed'))
      end
      cb(vim.trim(out.stdout or ''), nil)
    end)
  end)
end

--- Draft a review summary body from the reviewer's inline comments.
---@param label string
---@param comment_lines string one "path:line — body" per line
---@param cb fun(draft: string|nil, err: string|nil)
function M.draft_summary(label, comment_lines, cb)
  local config = require('prtour').config
  local cmd = vim.deepcopy(config.claude_cmd or { 'claude', '-p' })
  cmd[#cmd + 1] = 'stdin has a reviewer\'s inline comments from a code review. Draft the review summary body: one or two short paragraphs of plain markdown synthesizing the themes, professional and direct. No headings, no preamble, no sign-off. Output ONLY the summary text.'
  local model = (config.models or {}).ask
  if model then
    cmd[#cmd + 1] = '--model=' .. model
  end
  vim.system(cmd, { text = true, stdin = ('Review of %s\n\n%s'):format(label, comment_lines) }, function(out)
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

--- Pick a Claude pane (auto when only one) and send the message.
---@param msg string
---@param cb fun(ok: boolean, err: string|nil, label: string|nil)
function M.dispatch(msg, cb)
  M.panes(function(panes, err)
    if not panes then
      return cb(false, err)
    end
    if #panes == 0 then
      return cb(false, 'no tmux pane running Claude found')
    end
    local function send_to(pane)
      M.send(pane.id, msg, function(ok, err2)
        cb(ok, err2, pane.label)
      end)
    end
    if #panes == 1 then
      return send_to(panes[1])
    end
    vim.ui.select(
      vim.tbl_map(function(pn)
        return pn.label
      end, panes),
      { prompt = 'Send to which Claude pane?' },
      function(_, idx)
        if idx then
          send_to(panes[idx])
        end
      end
    )
  end)
end

--- Interactive Q&A about a hunk: multiline question float, markdown answer
--- float, `f` in the answer to ask a follow-up carrying the conversation.
---@param ctx {pr: integer|nil, label: string|nil, file: string, start_line: integer, line_count: integer, diff: string}
function M.ask_flow(ctx)
  local function question_float(history)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = 'markdown'
    vim.bo[buf].bufhidden = 'wipe'
    local win = vim.api.nvim_open_win(buf, true, {
      relative = 'cursor',
      row = 1,
      col = 0,
      width = 72,
      height = 5,
      style = 'minimal',
      border = 'rounded',
      title = (history and ' follow-up' or ' ask Claude') .. ' · <CR> send · q cancel ',
      title_pos = 'center',
    })
    local function close()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    vim.keymap.set('n', 'q', close, { buffer = buf })
    vim.keymap.set('n', '<CR>', function()
      local q = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
      close()
      if q == '' then
        return
      end
      local p = require('prtour.progress').start 'Claude'
      p:report(history and 'thinking about your follow-up' or 'thinking about your question')
      local t0 = vim.uv.hrtime()
      M.ask(vim.tbl_extend('force', ctx, { history = history }), q, function(answer, err)
        if not answer then
          return p:fail('ask failed: ' .. err)
        end
        p:finish()
        if (vim.uv.hrtime() - t0) / 1e9 > 10 then
          require('prtour.alert').ping 'Claude answered your question'
        end
        local new_history = (history or '') .. ('\n\nQ: %s\nA: %s'):format(q, answer)
        M.show_answer(q, answer, function()
          question_float(new_history)
        end)
      end)
    end, { buffer = buf })
    vim.cmd 'startinsert'
  end
  question_float(nil)
end

--- Show an answer in a centered, scrollable markdown float.
---@param question string
---@param answer string
---@param on_follow_up fun()|nil
function M.show_answer(question, answer, on_follow_up)
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
    title = on_follow_up and ' Claude · f follow-up · q close ' or ' Claude ',
    title_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, k in ipairs { 'q', '<Esc>' } do
    vim.keymap.set('n', k, close, { buffer = buf })
  end
  if on_follow_up then
    vim.keymap.set('n', 'f', function()
      close()
      on_follow_up()
    end, { buffer = buf })
  end
end

return M
