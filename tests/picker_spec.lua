local h = require('tests.helpers')
local files = require('revision.files')

it('picker rows line up every column', function()
  local fx = h.start()
  local rows = files.rows(fx.s)
  assert(#rows == #fx.s.files and #rows > 0)
  local col
  for _, r in ipairs(rows) do
    local i = r.text:find('  h:', 1, true)
    assert(i, r.text)
    col = col or i
    assert(i == col, ('hunk column drifts: %q'):format(r.text))
    local first = r.text:sub(1, 1)
    assert(first == ' ' or first == '✓', r.text)
  end
end)

it('picker rows carry the hunk counts', function()
  local fx = h.start()
  local rows = files.rows(fx.s)
  local by_path = {}
  for _, r in ipairs(rows) do
    by_path[r.e.path] = r.text
  end
  assert(by_path['a.lua']:find('h:0/3', 1, true), by_path['a.lua'])
end)
