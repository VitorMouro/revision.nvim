local h = require('tests.helpers')
local session = require('revision.session')

it('stop restores the window options from before the session', function()
  local fx = h.fixture()
  vim.cmd.cd(vim.fn.fnameescape(fx.wt))
  vim.cmd.edit('a.lua')
  vim.wo.foldmethod = 'indent'
  vim.wo.winbar = 'mine'
  vim.wo.signcolumn = 'no'
  session.start()
  assert(vim.wo.foldmethod == 'expr' and vim.wo.winbar:find('revision', 1, true))
  session.stop()
  assert(vim.wo.foldmethod == 'indent', vim.wo.foldmethod)
  assert(vim.wo.winbar == 'mine', vim.wo.winbar)
  assert(vim.wo.signcolumn == 'no', vim.wo.signcolumn)
  assert(vim.bo.modifiable)
end)

it('changed lines highlight to end of line without hiding word highlights', function()
  local fx = h.start()
  vim.cmd.edit(fx.wt .. '/a.lua')
  local inline = require('revision.inline')
  local line, word
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, inline.ns, { 2, 0 }, { 2, -1 }, { details = true })) do
    if m[4].hl_group == 'RevisionChange' then
      line = m[4]
    end
  end
  word = vim.api.nvim_buf_get_extmarks(0, inline.ns_words, { 2, 0 }, { 2, -1 }, { details = true })[1][4]
  assert(line and line.hl_eol and line.line_hl_group == nil)
  assert(word.priority > line.priority, 'word highlight must win over the line highlight')
end)

it('diff tints fade the Diff* background toward the editor background', function()
  local function bg(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false }).bg
  end
  local config = require('revision.config')
  vim.cmd('hi clear')
  vim.api.nvim_set_hl(0, 'DiffChange', { bg = 0x6464c8 })
  vim.api.nvim_set_hl(0, 'Normal', { bg = 0x000000 })
  require('revision').define_highlights()
  assert(bg('RevisionChange') == 0x282850, ('%06x'):format(bg('RevisionChange') or 0))

  vim.cmd('hi clear')
  vim.api.nvim_set_hl(0, 'DiffChange', { bg = 0x6464c8 })
  vim.api.nvim_set_hl(0, 'Normal', {})
  config.opts.bg = '#ffffff'
  require('revision').define_highlights()
  config.opts.bg = nil
  assert(bg('RevisionChange') == 0xc1c1e9, 'a transparent Normal falls back to the bg option')
  vim.cmd('hi clear')
  require('revision').define_highlights()
end)
