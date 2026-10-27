local h = require('tests.helpers')
local view = require('revision.view')
local files = require('revision.files')
local viewed = require('revision.viewed')

local function paths(rows)
  return vim.tbl_map(function(r)
    return r.e.path
  end, rows)
end

it('classifies with builtins and user rules first', function()
  local fx = h.start()
  local s = fx.s
  assert(view.category(s, 'Cargo.lock') == 'Generated')
  assert(view.category(s, 'tests/x_spec.lua') == 'Tests')
  assert(view.category(s, 'README.md') == 'Docs')
  assert(view.category(s, 'a.lua') == 'Source')
  view.compile({ { glob = '**/*.lua', category = 'Mechanical' } })
  s.category_cache = nil
  assert(view.category(s, 'a.lua') == 'Mechanical')
  view.compile({})
  s.category_cache = nil
  assert(view.category(s, 'a.lua') == 'Source')
  local ok, err = pcall(view.compile, { { glob = '[', category = 'X' } })
  assert(not ok and tostring(err):find('invalid category glob'), tostring(err))
  view.compile({})
end)

it('sort and filter drive picker rows and ]f', function()
  local fx = h.start()
  local v = fx.s.review.view
  v.sort = 'size'
  local sized = files.rows(fx.s)
  local sizes = vim.tbl_map(function(r)
    return r.e.additions + r.e.deletions
  end, sized)
  for i = 2, #sizes do
    assert(sizes[i - 1] >= sizes[i], vim.inspect(sizes))
  end

  v.unviewed = true
  viewed.set_file(fx.s, 'a.lua', true)
  assert(not vim.tbl_contains(paths(files.rows(fx.s)), 'a.lua'), vim.inspect(paths(files.rows(fx.s))))
  vim.cmd.edit(fx.wt .. '/new.lua')
  local visible = paths(files.rows(fx.s))
  local expected
  for i, p in ipairs(visible) do
    if p == 'new.lua' then
      expected = visible[i + 1]
    end
  end
  assert(expected and expected ~= 'a.lua', vim.inspect(visible))
  files.step(1)
  assert(vim.api.nvim_buf_get_name(0):find(expected .. '$'), vim.api.nvim_buf_get_name(0))
end)

it('agent order sorts by context order with reasons', function()
  local fx = h.start({ context = { order = { { path = 'new.lua', reason = 'start here' } } } })
  fx.s.review.view.sort = 'order'
  local rows = files.rows(fx.s)
  assert(rows[1].e.path == 'new.lua', vim.inspect(paths(rows)))
  assert(rows[1].text:find('start here', 1, true), rows[1].text)
end)
