local M = {}

local function has_exe(name)
  return vim.fn.executable(name) == 1
end

function M.check()
  local health = vim.health
  health.start 'prtour'

  if vim.fn.has 'nvim-0.10' == 1 then
    health.ok 'Neovim >= 0.10'
  else
    health.error 'Neovim >= 0.10 required (vim.system, extmark virt_lines)'
  end

  if pcall(require, 'gitsigns') then
    health.ok 'gitsigns.nvim found'
  else
    health.error 'gitsigns.nvim not found — required for inline diff rendering'
  end

  if pcall(require, 'fzf-lua') then
    health.ok 'fzf-lua found'
  else
    health.warn 'fzf-lua not found — the PR picker will not work (:PrTour <number> and local mode still do)'
  end

  if has_exe 'git' then
    health.ok 'git found'
  else
    health.error 'git not found'
  end

  if has_exe 'gh' then
    local out = vim.system({ 'gh', 'auth', 'status' }, { text = true }):wait()
    if out.code == 0 then
      health.ok 'gh found and authenticated'
    else
      health.error 'gh found but not authenticated — run `gh auth login`'
    end
  else
    health.error 'gh not found — required for all GitHub interaction'
  end

  local claude_cmd = (require('prtour').config.claude_cmd or { 'claude' })[1]
  if has_exe(claude_cmd) then
    health.ok(('%s found — narrative ordering and ask-Claude available'):format(claude_cmd))
  else
    health.warn(('%s not found — tours fall back to file order; ask/handoff unavailable'):format(claude_cmd))
  end

  if has_exe 'tmux' and vim.env.TMUX then
    health.ok 'tmux session detected — Claude handoff available'
  else
    health.warn 'not inside tmux — "send to Claude" actions unavailable'
  end

  if pcall(require, 'fidget') then
    health.ok 'fidget.nvim found — progress shown as spinner'
  else
    health.info 'fidget.nvim not found — progress falls back to messages'
  end
end

return M
