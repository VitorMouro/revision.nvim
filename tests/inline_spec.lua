local h = require('tests.helpers')
local inline = require('revision.inline')

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, inline.ns, 0, -1, { details = true })
end

it('renders deletions, changes and additions on the right rows', function()
  local fx = h.start()
  vim.cmd.edit(fx.wt .. '/a.lua')
  local buf = vim.api.nvim_get_current_buf()
  assert(not vim.bo[buf].modifiable)

  local top, change_virt, change_hl, add_rows = nil, nil, {}, {}
  for _, m in ipairs(marks(buf)) do
    local row, d = m[2], m[4]
    if d.virt_lines then
      if row == 0 then
        top = d
      elseif row == 2 then
        change_virt = d
      end
    end
    if d.hl_group == 'RevisionChange' then
      change_hl[row] = true
    elseif d.hl_group == 'RevisionAdd' then
      add_rows[row] = true
    end
  end
  assert(top and top.virt_lines_above, 'top deletion must be above row 0')
  assert(#top.virt_lines == 2)
  assert(top.virt_lines[1][1][1]:find('^local v1 = 1'))
  assert(change_hl[2], 'line 3 (old line 5) must be RevisionChange')
  assert(change_virt and change_virt.virt_lines_above and change_virt.virt_lines[1][1][1]:find('^local v5 = '))
  assert(add_rows[18] and add_rows[19] and add_rows[20], 'appended lines must be RevisionAdd')

  local words = vim.api.nvim_buf_get_extmarks(buf, inline.ns_words, 0, -1, { details = true })
  assert(#words == 1 and words[1][2] == 2 and words[1][4].hl_group == 'RevisionTextAdd')
  local line = vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]
  assert(line:sub(words[1][3] + 1, words[1][4].end_col) == '500')
end)

it('word diff pairs a new line with its most similar deleted line', function()
  local fx = h.fixture()
  local text = h.read(fx.wt .. '/a.lua'):gsub('local v7 = 7\nlocal v8 = 8\nlocal v9 = 9\n', 'local v9 = 900\n')
  h.write(fx.wt .. '/a.lua', text)
  vim.cmd.cd(vim.fn.fnameescape(fx.wt))
  require('revision.session').start()
  vim.cmd.edit(fx.wt .. '/a.lua')
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.fn.search('^local v9 = 900$') - 1
  local words = vim.api.nvim_buf_get_extmarks(buf, inline.ns_words, { row, 0 }, { row, -1 }, { details = true })
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  assert(#words == 1 and line:sub(words[1][3] + 1, words[1][4].end_col) == '900', vim.inspect(words))

  local block
  for _, m in ipairs(marks(buf)) do
    if m[2] == row and m[4].virt_lines then
      block = m[4].virt_lines
    end
  end
  local changed = {}
  for i, vl in ipairs(block) do
    for _, chunk in ipairs(vl) do
      if chunk[2] == 'RevisionText' then
        changed[i] = (changed[i] or '') .. chunk[1]
      end
    end
  end
  assert(vim.deep_equal(changed, { [3] = '9' }), vim.inspect(changed))
end)

it('word diff pairing skips blank old lines', function()
  local pairs_ = inline.pair_lines({ '', 'local foo = 1' }, { 'local foo = 2' })
  assert(vim.deep_equal(pairs_, { 2 }), vim.inspect(pairs_))
  assert(vim.deep_equal(inline.pair_lines({ 'x' }, { '', 'y' }), {}))
end)

it('buffer hunk hashes equal git diff -U0 hashes', function()
  local fx = h.start()
  vim.cmd.edit(fx.wt .. '/a.lua')
  local buf = vim.api.nvim_get_current_buf()
  local from_buf = vim.tbl_map(function(x)
    return x.hash
  end, vim.b[buf].revision_hunks)
  local from_git = vim.tbl_map(function(x)
    return x.hash
  end, fx.s.hunks['a.lua'])
  assert(#from_buf == 3, #from_buf)
  assert(vim.deep_equal(from_buf, from_git))
end)

it('folds unchanged middle lines', function()
  local fx = h.start()
  vim.cmd.edit(fx.wt .. '/a.lua')
  assert(vim.wo.foldmethod == 'expr')
  assert(vim.fn.foldclosed(10) ~= -1, 'line 10 must be folded')
  assert(vim.fn.foldclosed(3) == -1, 'changed line must be open')
end)

it('opens deleted files as read-only scratch buffers', function()
  local fx = h.start()
  require('revision.files').open(fx.s.file_map['del.lua'])
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.api.nvim_buf_get_name(buf) == 'revision://deleted/del.lua')
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 'return "deleted"')
  assert(not vim.bo[buf].modifiable)
  local m = marks(buf)[1]
  assert(m[4].hl_group == 'RevisionDelete' and m[2] == 0 and m[4].end_row == 2 and m[4].hl_eol)
end)
