local h = require('tests.helpers')
local comments = require('revision.comments')
local range = require('revision.range')
local session = require('revision.session')

--- Opens the editor at line `line` of a.lua, types body, cycles the kind, and writes.
local function comment(fx, line, body, cycles)
  vim.g.mapleader = ' '
  vim.cmd.edit(fx.wt .. '/a.lua')
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  comments.create(false)
  vim.cmd.stopinsert()
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.api.nvim_buf_get_name(buf):find('revision://comment/new', 1, true))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { body })
  for _ = 1, cycles or 0 do
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

local function qf_text(path)
  comments.quickfix()
  local out = {}
  for _, item in ipairs(vim.fn.getqflist()) do
    table.insert(out, item.text)
  end
  vim.cmd('cclose')
  return table.concat(out, '\n') .. (path or '')
end

it('a RIGHT comment inside a hunk is stored and rendered', function()
  local fx = h.start({ context = true })
  comment(fx, 3, 'why 500?')
  local c = fx.s.review.comments[1]
  assert(c and c.side == 'RIGHT' and c.line == 3 and c.commit == fx.c2 and c.kind == 'comment', last_error())
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

it('a comment outside the review diff is kept and marked outdated', function()
  local fx = h.start({ context = true })
  comment(fx, 15, 'nit')
  local c = fx.s.review.comments[1]
  assert(c and c.line == 15 and c.kind == 'comment', last_error())
  assert(qf_text():find('[outdated]', 1, true), qf_text())
end)

it('a note outside the review diff is not outdated', function()
  local fx = h.start({ context = true })
  comment(fx, 15, 'note to self', 1)
  local c = fx.s.review.comments[1]
  assert(c and c.kind == 'note' and c.line == 15, last_error())
  assert(not qf_text():find('[outdated]', 1, true), qf_text())
end)

it('a comment on an older range anchors to that range end', function()
  local fx = h.start({ context = true })
  range.apply(fx.main, fx.c1, 'custom')
  comment(fx, 3, 'x')
  local c = fx.s.review.comments[1]
  assert(c and c.commit == fx.c1, last_error())
end)

it('comments and verdict work without a context file', function()
  local fx = h.start()
  comment(fx, 3, 'local review')
  assert(#fx.s.review.comments == 1, last_error())
  local picked
  local real = vim.ui.select
  vim.ui.select = function(items, _, cb)
    picked = items
    cb('approve')
  end
  session.verdict()
  vim.ui.select = real
  assert(picked and fx.s.review.verdict == 'approve', vim.inspect(fx.s.review.verdict))
end)

it('working changes take tasks, not comments', function()
  local fx = h.start({ context = true })
  h.write(fx.wt .. '/a.lua', h.read(fx.wt .. '/a.lua'):gsub('local v10 = 10', 'local v10 = 1000'))
  range.working()
  vim.g.mapleader = ' '
  vim.cmd.edit(fx.wt .. '/a.lua')
  vim.api.nvim_win_set_cursor(0, { 8, 0 })
  comments.create(false)
  vim.cmd.stopinsert()
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  assert(vim.api.nvim_win_get_config(win).title[1][1]:find('· task', 1, true), vim.inspect(vim.api.nvim_win_get_config(win).title))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'fix this' })
  h.notes = {}
  vim.cmd('write')
  local c = fx.s.review.comments[1]
  assert(c and c.kind == 'task' and c.worktree == true and c.commit == vim.NIL, last_error() or vim.inspect(c))

  vim.cmd.edit(fx.wt .. '/a.lua')
  vim.api.nvim_win_set_cursor(0, { 8, 0 })
  comments.cycle_kind()
  assert(c.kind == 'note', c.kind)
  comments.cycle_kind()
  assert(c.kind == 'task', c.kind)
end)

it('comments on one line render oldest first, wrapped to the window', function()
  local fx = h.start({ context = true })
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
  local head = '  ┃ comment · L3'
  assert(texts[1] == head and texts[#texts] == '  ┃ second' and texts[#texts - 1] == head, vim.inspect(texts))
  local body = {}
  for i = 2, #texts - 2 do
    assert(vim.fn.strdisplaywidth(texts[i]) <= width, texts[i])
    table.insert(body, (texts[i]:gsub('^  ┃ ', '')))
  end
  assert(#body > 1 and table.concat(body, ' ') == long, vim.inspect(body))
end)

it('the comment editor cycles kind on the leader, leaving <C-p> alone', function()
  local fx = h.start({ context = true })
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

it('quickfix marks outdated comments and ones the range cannot show', function()
  local fx = h.start({ context = true })
  comments.commit(fx.s, { path = 'a.lua', side = 'RIGHT', line = 3, kind = 'comment' }, 'inside')
  table.insert(fx.s.review.comments, {
    id = 99,
    path = 'new.lua',
    side = 'RIGHT',
    start_line = vim.NIL,
    line = 1,
    commit = fx.c1,
    worktree = false,
    kind = 'comment',
    body = 'from an older round',
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

it('the review body float wraps long paragraphs under a global nowrap', function()
  h.start()
  vim.o.wrap = false
  require('revision.session').body()
  assert(vim.wo.wrap and vim.wo.linebreak, 'the body float must wrap')
  vim.cmd.close()
  vim.o.wrap = true
end)
