local h = require('tests.helpers')
local search = require('revision.search')

local function find(items, sign, text)
  for i, it in ipairs(items) do
    if it.sign == sign and it.text == text then
      return it, i
    end
  end
end

it('changed lines carry the row to jump to on either side', function()
  local fx = h.start()
  local items = search.entries(fx.s)
  local add = find(items, '+', 'local v5 = 500')
  assert(add and add.e.path == 'a.lua' and add.target == 3, vim.inspect(add))
  local del = find(items, '-', 'local v1 = 1')
  assert(del and del.e.path == 'a.lua' and del.target == 1, vim.inspect(del))
  local gone = find(items, '-', 'local x = 1')
  assert(gone and gone.e.path == 'del.lua' and gone.target == 2, vim.inspect(gone))
end)

it('rg matches line text only, smart-case, and reports bad patterns', function()
  local fx = h.start()
  local items = search.entries(fx.s)
  local _, i = find(items, '+', 'local v5 = 500')
  local hits = search.rg(items, 'v5 = \\d{3}')
  assert(vim.deep_equal(hits, { i }), vim.inspect(hits))
  assert(#search.rg(items, 'a.lua') == 0, 'paths are not searched')
  assert(#search.rg(items, 'LOCAL') == 0 and #search.rg(items, 'local') > 1)
  local none, err = search.rg(items, '(')
  assert(none == nil and err ~= '', tostring(err))
end)

it('picking a deleted line opens the file at the row it was removed from', function()
  h.start()
  local select = vim.ui.select
  vim.ui.select = function(items, _, cb)
    cb((find(items, '-', 'local x = 1')))
  end
  search.fuzzy()
  vim.ui.select = select
  assert(vim.api.nvim_buf_get_name(0) == 'revision://deleted/del.lua', vim.api.nvim_buf_get_name(0))
  assert(vim.api.nvim_win_get_cursor(0)[1] == 2)
end)
