local h = require('tests.helpers')
local commits = require('revision.commits')
local range = require('revision.range')

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

it('commit panel keys move the range', function()
  local fx = h.start()
  commits.toggle()
  local row = row_of(fx.c2)
  assert(row, table.concat(lines(), '\n'))
  vim.api.nvim_set_current_win(commits.win())
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  assert(fx.s.range.start == fx.c1 and fx.s.range.end_ == fx.c2, vim.inspect(fx.s.range))
end)
