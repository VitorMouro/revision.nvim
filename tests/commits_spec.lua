local h = require('tests.helpers')
local commits = require('revision.commits')
local range = require('revision.range')
local session = require('revision.session')

local function lines()
  return vim.api.nvim_buf_get_lines(vim.fn.bufnr('revision://commits'), 0, -1, false)
end

local function row_of(sha)
  for row, s in pairs(commits.shas) do
    if s == sha then
      return row
    end
  end
end

it('save marks the range commits reviewed and offers unreviewed', function()
  local fx = h.start()
  range.apply(fx.main, fx.c1, 'custom')
  session.save()
  assert(vim.deep_equal(fx.s.review.reviewed_commits, { fx.c1 }), vim.inspect(fx.s.review.reviewed_commits))
  local item
  for _, i in ipairs(range.items(fx.s)) do
    if i.kind == 'unreviewed' then
      item = i
    end
  end
  assert(item and item.start == fx.c1, vim.inspect(item))
end)

it('commit panel keys move the range', function()
  local fx = h.start()
  commits.toggle()
  local row = row_of(fx.c2)
  assert(row, table.concat(lines(), '\n'))
  vim.api.nvim_set_current_win(commits.win())
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  assert(fx.s.range.start == fx.c1 and fx.s.range.end_ == fx.c2, vim.inspect(fx.s.range))

  vim.api.nvim_set_current_win(commits.win())
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.api.nvim_feedkeys('m', 'x', false)
  assert(vim.deep_equal(fx.s.review.reviewed_commits, { fx.c2 }), vim.inspect(fx.s.review.reviewed_commits))
  assert(lines()[row]:find('✓', 1, true), lines()[row])
end)
