local h = require('tests.helpers')
local panel = require('revision.panel')
local range = require('revision.range')
local viewed = require('revision.viewed')

local function panel_lines()
  local buf = vim.fn.bufnr('revision://files')
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function row_of(text)
  for i, l in ipairs(panel_lines()) do
    if l:find(text, 1, true) then
      return i
    end
  end
end

it('panel groups by category, collapses generated, opens files', function()
  local fx = h.start()
  h.write(fx.wt .. '/Cargo.lock', 'generated = true\n')
  h.git(fx.wt, 'add', '-A')
  h.git(fx.wt, 'commit', '-q', '-m', 'lock')
  range.refresh_local(fx.s)
  range.apply(fx.s.merge_base, fx.s.head, 'all')

  panel.toggle()
  local source = row_of('▾ Source')
  assert(source, table.concat(panel_lines(), '\n'))
  assert(row_of('▸ Generated (1)'), table.concat(panel_lines(), '\n'))
  assert(not row_of('Cargo.lock'), 'the collapsed group must hide its files')
  local a = row_of('a.lua')
  assert(a and a > source, table.concat(panel_lines(), '\n'))

  vim.api.nvim_set_current_win(panel.win())
  vim.api.nvim_win_set_cursor(0, { a, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
  assert(vim.api.nvim_buf_get_name(0):find('a.lua$'), vim.api.nvim_buf_get_name(0))

  vim.api.nvim_set_current_win(panel.win())
  vim.api.nvim_win_set_cursor(0, { a, 0 })
  vim.api.nvim_feedkeys('v', 'x', false)
  assert(viewed.file_viewed(fx.s, 'a.lua'), 'v must mark the file viewed')
  assert(panel_lines()[a]:find('✓', 1, true), panel_lines()[a])
end)
