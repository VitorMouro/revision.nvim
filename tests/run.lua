-- nvim --headless --clean --cmd 'set rtp^=.' -l tests/run.lua
-- Tests cd into fixture worktrees, so every plugin path must be absolute.
local here = vim.fn.getcwd()
vim.opt.rtp:prepend(here)
package.path = here .. '/?.lua;' .. package.path
local helpers = require('tests.helpers')
vim.notify = function(msg, level)
  table.insert(helpers.notes, { msg = msg, level = level })
end
helpers.isolate()
require('revision').setup({ keymaps = false })

local failed, passed = 0, 0
local specs = vim.fn.glob(here .. '/tests/*_spec.lua', false, true)
table.sort(specs)

for _, file in ipairs(specs) do
  local cases = {}
  _G.it = function(name, fn)
    table.insert(cases, { name = name, fn = fn })
  end
  dofile(file)
  for _, c in ipairs(cases) do
    local name = vim.fs.basename(file):gsub('_spec%.lua$', '') .. ': ' .. c.name
    local ok, err = xpcall(c.fn, debug.traceback)
    helpers.reset()
    if ok then
      passed = passed + 1
      io.stdout:write('ok   ', name, '\n')
    else
      failed = failed + 1
      io.stdout:write('FAIL ', name, ': ', tostring(err), '\n')
    end
  end
end

io.stdout:write(('%d passed, %d failed\n'):format(passed, failed))
os.exit(failed > 0 and 1 or 0)
