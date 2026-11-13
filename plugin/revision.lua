if vim.g.loaded_revision then
  return
end
vim.g.loaded_revision = true

local subs = { 'start', 'files', 'range', 'stop', 'view', 'panel', 'commits' }

vim.api.nvim_create_user_command('Revision', function(a)
  local arg = a.fargs[1] or 'start'
  require('revision.util').guard(function()
    local session = require('revision.session')
    if vim.tbl_contains(subs, arg) then
      session[arg]()
    else
      session.start(arg)
    end
  end)()
end, {
  nargs = '?',
  complete = function(lead)
    return vim.tbl_filter(function(s)
      return s:sub(1, #lead) == lead
    end, subs)
  end,
})
