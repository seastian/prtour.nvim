vim.api.nvim_create_user_command('PrTour', function(cmd)
  if cmd.fargs[1] == 'local' then
    return require('prtour').start_local(cmd.fargs[2])
  end
  require('prtour').start(tonumber(cmd.fargs[1]))
end, {
  nargs = '*',
  complete = function()
    return { 'local' }
  end,
  desc = 'Review a PR (optional number) or local changes (:PrTour local [base])',
})

vim.api.nvim_create_user_command('PrTourStop', function()
  require('prtour.tour').stop()
end, { desc = 'End the active PR review tour' })

vim.api.nvim_create_user_command('PrTourSubmit', function(cmd)
  require('prtour.tour').submit(cmd.fargs[1])
end, {
  nargs = '?',
  complete = function()
    return { 'comment', 'approve', 'request-changes', 'pending' }
  end,
  desc = 'Submit queued comments as one GitHub review',
})
