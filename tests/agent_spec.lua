local h = require('tests.helpers')
local agent = require('revision.agent')
local comments = require('revision.comments')
local session = require('revision.session')

--- Captures what agent.send hands to sidekick; returns a getter and a restore function.
local function stub_sidekick()
  local captured
  package.loaded['sidekick.cli'] = {
    send = function(opts)
      captured = opts
    end,
  }
  return function()
    return captured
  end, function()
    package.loaded['sidekick.cli'] = nil
  end
end

local function joined(opts)
  return table.concat(
    vim.tbl_map(function(t)
      return t[1][1]
    end, opts.text),
    '\n'
  )
end

it('ask sends the selection with annotations and the review dir', function()
  local fx = h.start({ context = true })
  local get, restore = stub_sidekick()
  comments.commit(fx.s, { path = 'a.lua', side = 'RIGHT', line = 3, kind = 'comment' }, 'why 500?')
  vim.cmd.edit(fx.wt .. '/a.lua')
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  agent.ask(false)
  local opts = get()
  restore()
  assert(opts and opts.submit == false, vim.inspect(opts))
  local text = joined(opts)
  assert(text:find('Reviewing ', 1, true), text)
  assert(text:find('a.lua lines 3-3 (RIGHT', 1, true), text)
  assert(text:find('local v5 = 500', 1, true), text)
  assert(text:find('[comment #1]', 1, true), text)
  assert(text:find('(review files: ' .. fx.s.dir .. ')', 1, true), text)
  assert(text:match('Question: $'), text)
end)

it('without sidekick the prompt goes to the + register', function()
  local fx = h.start({ context = true })
  package.loaded['sidekick.cli'] = nil
  package.preload['sidekick.cli'] = function()
    error('no sidekick')
  end
  h.notes = {}
  vim.cmd.edit(fx.wt .. '/a.lua')
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  agent.ask(false)
  package.preload['sidekick.cli'] = nil
  local reg = vim.fn.getreg('+')
  if reg ~= '' then
    assert(reg:find('Question: ', 1, true), reg)
  else
    local msg = h.notes[#h.notes] and h.notes[#h.notes].msg or ''
    assert(msg:find('+ register', 1, true), msg)
  end
end)

it('tasks lists open tasks only', function()
  local fx = h.start({ context = true })
  local get, restore = stub_sidekick()
  comments.commit(fx.s, { path = 'a.lua', side = 'RIGHT', line = 3, kind = 'task' }, 'rename v5')
  comments.commit(fx.s, { path = 'a.lua', side = 'RIGHT', line = 4, kind = 'task' }, 'already handled')
  session.save()
  h.context(fx, { tasks = { { local_id = 2, status = 'done', note = 'ok' } } })
  session.reload()
  agent.tasks()
  local text = joined(get())
  restore()
  assert(text:find('#1 a.lua:L3', 1, true), text)
  assert(not text:find('#2 ', 1, true), text)
  assert(text:find('FORMAT.md', 1, true), text)
end)
