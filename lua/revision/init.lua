local M = {}

local highlights = {
  RevisionAdd = 'DiffAdd',
  RevisionChange = 'DiffChange',
  RevisionDelete = 'DiffDelete',
  RevisionText = 'DiffText',
  RevisionTextAdd = 'DiffTextAdd',
  RevisionCurrent = 'Visual',
  RevisionViewed = 'Comment',
  RevisionUnchanged = 'Comment',
}

function M.define_highlights()
  for group, link in pairs(highlights) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

function M.setup(opts)
  local config = require('revision.config')
  config.opts = vim.tbl_deep_extend('force', vim.deepcopy(config.defaults), opts or {})
  require('revision.view').compile(config.opts.categories)
  M.define_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('revision_hl', {}),
    callback = M.define_highlights,
  })
  if config.opts.keymaps then
    require('revision.keys').global()
  end
end

return M
