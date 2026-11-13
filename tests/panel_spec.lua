local h = require('tests.helpers')
local panel = require('revision.panel')
local range = require('revision.range')
local viewed = require('revision.viewed')
local session = require('revision.session')

local function panel_lines()
  return vim.api.nvim_buf_get_lines(vim.fn.bufnr('revision://files'), 0, -1, false)
end

local function dump()
  return table.concat(panel_lines(), '\n')
end

local function row_of(text)
  for i, l in ipairs(panel_lines()) do
    if l:find(text, 1, true) then
      return i
    end
  end
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
end

--- Fixture plus src/deep/x.lua, src/y.lua and an unchanged lib/keep.lua, reviewing only the last commit.
local function tree_fixture()
  local fx = h.start()
  h.write(fx.wt .. '/lib/keep.lua', 'return 1\n')
  h.write(fx.wt .. '/src/deep/x.lua', 'return 1\n')
  h.write(fx.wt .. '/src/y.lua', 'return 1\n')
  h.git(fx.wt, 'add', '-A')
  h.git(fx.wt, 'commit', '-q', '-m', 'c3')
  local c3 = h.git(fx.wt, 'rev-parse', 'HEAD')
  h.write(fx.wt .. '/src/deep/x.lua', 'return 2\nlocal more = true\n')
  h.write(fx.wt .. '/src/y.lua', 'return 2\n')
  h.write(fx.wt .. '/top.lua', 'return 0\n')
  h.git(fx.wt, 'add', '-A')
  h.git(fx.wt, 'commit', '-q', '-m', 'c4')
  range.refresh_local(fx.s)
  range.apply(c3, h.git(fx.wt, 'rev-parse', 'HEAD'), 'c4')
  return fx
end

it('panel focuses, shows a compacted tree with directories first, opens and marks files', function()
  local fx = tree_fixture()
  panel.toggle()
  assert(vim.api.nvim_get_current_win() == panel.win(), 'the panel must take focus')
  local src, deep, x, y, top = row_of('▾ src/'), row_of('▾ deep/'), row_of('x.lua'), row_of('y.lua'), row_of('top.lua')
  assert(src and deep and x and y and top, dump())
  assert(src < deep and deep < x and x < y and y < top, dump())
  assert(panel_lines()[x]:find('^      x') and panel_lines()[y]:find('^    y'), dump())
  assert(not row_of('keep.lua'), 'unchanged files are hidden by default')

  vim.api.nvim_win_set_cursor(0, { x, 0 })
  press('v')
  assert(viewed.file_viewed(fx.s, 'src/deep/x.lua'), 'v must mark the file viewed')
  assert(panel_lines()[x]:find('✓', 1, true), panel_lines()[x])
  press('<CR>')
  assert(vim.api.nvim_buf_get_name(0):find('src/deep/x.lua$'), vim.api.nvim_buf_get_name(0))
end)

it('directory folds survive re-renders that move rows', function()
  local fx = tree_fixture()
  panel.toggle()
  vim.api.nvim_win_set_cursor(0, { row_of('▾ deep/'), 0 })
  press('zc')
  press(',S')
  assert(fx.s.view.sort == 'size' and fx.s.view.reverse, vim.inspect(fx.s.view))
  local deep = row_of('deep/')
  assert(deep and vim.fn.foldclosed(deep) == deep, dump())
  assert(vim.fn.foldclosed(row_of('x.lua')) == deep, 'files of a folded directory stay hidden')
  assert(vim.api.nvim_win_get_cursor(0)[1] == deep, 'the cursor follows its row')
  press('zo')
  assert(vim.fn.foldclosed(deep) == -1, dump())
end)

it('. shows unchanged files with unchanged directories folded', function()
  tree_fixture()
  panel.toggle()
  press('.')
  local lib, keep = row_of('▾ lib/'), row_of('keep.lua')
  assert(lib and keep and keep == lib + 1, dump())
  assert(vim.fn.foldclosed(lib) == lib, 'a directory without changes starts folded')
  assert(vim.fn.foldclosed(row_of('▾ src/')) == -1, dump())
  assert(row_of('bin.png'), dump())
  press('.')
  assert(not row_of('keep.lua'), dump())
end)

it('f filters paths live and <Esc> restores the previous filter', function()
  tree_fixture()
  panel.toggle()
  vim.api.nvim_feedkeys('fy.l' .. vim.keycode('<CR>'), 'x', false)
  assert(row_of('y.lua') and not row_of('x.lua') and not row_of('top.lua'), dump())
  assert(vim.wo[panel.win()].winbar:find('filter: "y.l"', 1, true), vim.wo[panel.win()].winbar)
  vim.api.nvim_feedkeys('fzzz' .. vim.keycode('<Esc>'), 'xt', false)
  assert(row_of('y.lua'), dump())
  vim.api.nvim_feedkeys('f' .. vim.keycode('<C-u><CR>'), 'x', false)
  assert(row_of('x.lua') and row_of('top.lua'), dump())
end)

it('works without a review session and keeps working after one stops', function()
  local fx = tree_fixture()
  session.stop()
  panel.toggle()
  assert(row_of('keep.lua') or row_of('▾ lib/'), dump())
  assert(row_of('top.lua'), dump())
  assert(panel_lines()[1]:find(vim.fs.basename(fx.wt), 1, true), dump())
  vim.api.nvim_win_set_cursor(0, { row_of('top.lua'), 0 })
  press('<CR>')
  assert(vim.api.nvim_buf_get_name(0):find('top.lua$'), vim.api.nvim_buf_get_name(0))
end)
