if vim.g.loaded_revision then
  return
end
vim.g.loaded_revision = true

local subs = { 'start', 'files', 'range', 'save', 'discard', 'delete', 'stop', 'body', 'verdict', 'comments', 'info' }

vim.api.nvim_create_user_command('Revision', function(a)
  local sub = a.fargs[1] or 'start'
  if not vim.tbl_contains(subs, sub) then
    require('revision.util').err('unknown subcommand ' .. sub)
    return
  end
  require('revision.util').guard(function()
    require('revision.session')[sub]()
  end)()
end, {
  nargs = '?',
  complete = function(lead)
    return vim.tbl_filter(function(s)
      return s:sub(1, #lead) == lead
    end, subs)
  end,
})
