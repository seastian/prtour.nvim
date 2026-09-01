vim.api.nvim_create_user_command('PrTour', function(cmd)
  require('prtour').start(tonumber(cmd.fargs[1]))
end, {
  nargs = '?',
  desc = 'Review a GitHub PR as a guided tour (optional PR number)',
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
