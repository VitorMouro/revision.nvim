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

it('quickfix points deleted-file comments at the deleted buffer', function()
  local fx = h.start({ context = true })
  require('revision.files').open(fx.s.file_map['del.lua'])
  require('revision.comments').commit(fx.s, { path = 'del.lua', side = 'LEFT', line = 1, kind = 'note' }, 'gone')
  require('revision.comments').quickfix()
  local item = vim.fn.getqflist()[1]
  assert(vim.api.nvim_buf_get_name(item.bufnr) == 'revision://deleted/del.lua')
  assert(item.lnum == 1 and not item.text:find('outdated'), item.text)
end)
