local h = require('tests.helpers')
local comments = require('revision.comments')
local range = require('revision.range')

--- Opens the editor at line `line` of a.lua, types body, toggles private if asked, and writes.
local function comment(fx, line, body, private)
  vim.g.mapleader = ' '
  vim.cmd.edit(fx.wt .. '/a.lua')
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  comments.create(false)
  vim.cmd.stopinsert()
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.api.nvim_buf_get_name(buf):find('revision://comment/new', 1, true))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { body })
  if private then
    vim.api.nvim_feedkeys(' rp', 'x', false)
  end
  h.notes = {}
  vim.cmd('write')
  return buf
end

local function last_error()
  for i = #h.notes, 1, -1 do
    if h.notes[i].level == vim.log.levels.ERROR then
      return h.notes[i].msg
    end
  end
end

it('public RIGHT comment inside a hunk is stored and rendered', function()
  local fx = h.start({ pr = true })
  comment(fx, 3, 'why 500?')
  local c = fx.s.review.comments[1]
  assert(c and c.side == 'RIGHT' and c.line == 3 and c.commit == fx.c2 and not c.private, last_error())
  vim.cmd('wincmd p')
  local buf = vim.fn.bufnr(fx.wt .. '/a.lua')
  local marks = vim.api.nvim_buf_get_extmarks(buf, require('revision.inline').ns_comments, 0, -1, { details = true })
  local text
  for _, m in ipairs(marks) do
    if m[4].virt_lines then
      text = m[4].virt_lines[2][1][1]
    end
  end
  assert(text == '  ┃ why 500?', tostring(text))
end)

it('public comment outside the PR diff is refused', function()
  local fx = h.start({ pr = true })
  local buf = comment(fx, 15, 'nit')
  assert(#fx.s.review.comments == 0)
  assert((last_error() or ''):find('outside the PR diff'), tostring(last_error()))
  assert(vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified, 'editor must stay open')
end)

it('private comment outside the PR diff is kept', function()
  local fx = h.start({ pr = true })
  comment(fx, 15, 'note to self', true)
  local c = fx.s.review.comments[1]
  assert(c and c.private and c.line == 15, last_error())
end)

it('public RIGHT comment on a range not ending at the PR head is refused', function()
  local fx = h.start({ pr = true })
  range.apply(fx.main, fx.c1, 'custom')
  comment(fx, 3, 'x')
  assert(#fx.s.review.comments == 0)
  assert((last_error() or ''):find('end at the PR head'), tostring(last_error()))
end)

it('comments are disabled without a GitHub PR', function()
  local fx = h.start()
  vim.cmd.edit(fx.wt .. '/a.lua')
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  local ok, err = pcall(comments.create, false)
  assert(not ok and err:find('need a GitHub PR'), tostring(err))
  ok, err = pcall(require('revision.session').verdict)
  assert(not ok and err:find('no GitHub PR'), tostring(err))
end)

it('comments are disabled on working changes even with a PR', function()
  local fx = h.start({ pr = true })
  h.write(fx.wt .. '/a.lua', 'changed\n')
  range.working()
  vim.cmd.edit(fx.wt .. '/a.lua')
  local ok, err = pcall(comments.create, false)
  assert(not ok and err:find('not working changes'), tostring(err))
end)

it('comments on one line render oldest first, wrapped to the window', function()
  local fx = h.start({ pr = true })
  local long = vim.trim(('wrapme '):rep(40))
  comment(fx, 3, long)
  comment(fx, 3, 'second')
  vim.cmd.edit(fx.wt .. '/a.lua')
  local buf = vim.api.nvim_get_current_buf()
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local width = info.width - info.textoff
  local blocks = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, require('revision.inline').ns_comments, 0, -1, { details = true })) do
    if m[4].virt_lines then
      table.insert(blocks, m[4].virt_lines)
    end
  end
  assert(#blocks == 1, 'one virt_lines block per row')
  local texts = vim.tbl_map(function(vl)
    return vl[1][1]
  end, blocks[1])
  assert(texts[1] == '  ┃ L3' and texts[#texts] == '  ┃ second' and texts[#texts - 1] == '  ┃ L3', vim.inspect(texts))
  local body = {}
  for i = 2, #texts - 2 do
    assert(vim.fn.strdisplaywidth(texts[i]) <= width, texts[i])
    table.insert(body, (texts[i]:gsub('^  ┃ ', '')))
  end
  assert(#body > 1 and table.concat(body, ' ') == long, vim.inspect(body))
end)

it('the comment editor toggles private on the leader, leaving <C-p> alone', function()
  local fx = h.start({ pr = true })
  vim.g.mapleader = ' '
  vim.cmd.edit(fx.wt .. '/a.lua')
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  comments.create(false)
  vim.cmd.stopinsert()
  local buf = vim.api.nvim_get_current_buf()
  local lhs = {}
  for _, mode in ipairs({ 'n', 'i' }) do
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
      lhs[m.lhs] = true
    end
  end
  assert(lhs[' rp'], 'leader chord must be bound')
  assert(not lhs['<C-p>'], '<C-p> must stay free for completion')
end)

it('quickfix marks comments GitHub would refuse and ones the range cannot show', function()
  local fx = h.start({ pr = true })
  comments.commit(fx.s, { path = 'a.lua', side = 'RIGHT', line = 3, private = false }, 'inside')
  table.insert(fx.s.review.comments, {
    id = 99,
    path = 'new.lua',
    side = 'RIGHT',
    start_line = vim.NIL,
    line = 1,
    commit = fx.c1,
    body = 'from an older round',
    private = false,
    created_at = '',
    updated_at = '',
  })
  comments.quickfix()
  local items = vim.fn.getqflist()
  assert(#items == 2, tostring(#items))
  assert(not items[1].text:find('outdated'), items[1].text)
  assert(items[2].text:find('outdated', 1, true), items[2].text)
  assert(items[2].text:find('hidden', 1, true), items[2].text)
  vim.cmd('cclose')
end)
