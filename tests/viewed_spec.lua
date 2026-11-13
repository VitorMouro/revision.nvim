local h = require('tests.helpers')
local session = require('revision.session')
local viewed = require('revision.viewed')
local range = require('revision.range')

it('a viewed file becomes unviewed when a new commit changes it', function()
  local fx = h.start()
  for _, p in ipairs({ 'a.lua', 'new.lua' }) do
    vim.cmd.edit(fx.wt .. '/' .. p)
    viewed.toggle_file()
    assert(viewed.file_viewed(fx.s, p))
  end
  session.stop()

  vim.cmd('silent! %bwipeout!')
  h.write(fx.wt .. '/a.lua', 'changed\n')
  h.git(fx.wt, 'commit', '-q', '-am', 'c3')
  local s = session.start()
  assert(not viewed.file_viewed(s, 'a.lua'), 'changed file must be unviewed')
  assert(viewed.file_viewed(s, 'new.lua'), 'untouched file must stay viewed')
end)

it('hunk viewed toggles by hash and shows in counts', function()
  local fx = h.start()
  vim.cmd.edit(fx.wt .. '/a.lua')
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  viewed.toggle_hunk()
  local n, total = viewed.hunk_counts(fx.s, 'a.lua')
  assert(n == 1 and total == 3)
  assert(vim.api.nvim_win_get_cursor(0)[1] == 19, 'must jump to the next hunk')
  assert(require('revision.files').format(fx.s, fx.s.file_map['a.lua']):find('h:1/3', 1, true))
end)

it('file and hunk marks stay in sync in both directions', function()
  local fx = h.start()
  vim.cmd.edit(fx.wt .. '/a.lua')
  local inline = require('revision.inline')
  local st = inline.state[vim.api.nvim_get_current_buf()]
  local hunk = st.hunks[2]
  local row = hunk.cb > 0 and hunk.sb or hunk.anchor + 1
  viewed.toggle_file()
  local n, total = viewed.hunk_counts(fx.s, 'a.lua')
  assert(total == 3 and n == 3, ('viewing the file must view every hunk: %d/%d'):format(n, total))
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  viewed.toggle_hunk()
  assert(not viewed.file_viewed(fx.s, 'a.lua'), 'unviewing one hunk must unview the file')
  assert(viewed.hunk_counts(fx.s, 'a.lua') == 2)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  viewed.toggle_hunk()
  assert(viewed.file_viewed(fx.s, 'a.lua'), 'viewing every hunk must view the file')
end)

it('disagreeing marks are reconciled when the range loads', function()
  local fx = h.start()
  local r = fx.s.marks
  r.viewed_files = { ['a.lua'] = fx.s.blobs['a.lua'] }
  r.viewed_hunks = {}
  range.apply(fx.s.range.start, fx.s.range.end_, 'all')
  local n, total = viewed.hunk_counts(fx.s, 'a.lua')
  assert(total == 3 and n == 3, ('legacy file mark must gain its hunks: %d/%d'):format(n, total))

  r.viewed_files = {}
  r.viewed_hunks = {}
  for _, hunk in ipairs(fx.s.hunks['a.lua']) do
    table.insert(r.viewed_hunks, hunk.hash)
  end
  range.apply(fx.s.range.start, fx.s.range.end_, 'all')
  assert(viewed.file_viewed(fx.s, 'a.lua'), 'hunks marked viewed must mark the file')
end)
