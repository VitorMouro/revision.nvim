local h = require('tests.helpers')
local range = require('revision.range')
local session = require('revision.session')

local function paths(s)
  return vim.tbl_map(function(e)
    return e.path
  end, s.files)
end

it('default range lists every changed file', function()
  local fx = h.start()
  assert(vim.deep_equal(paths(fx.s), { 'a.lua', 'del.lua', 'moved.lua', 'new.lua' }), vim.inspect(paths(fx.s)))
  assert(fx.s.file_map['moved.lua'].status == 'R' and fx.s.file_map['moved.lua'].old_path == 'move_me.lua')
  assert(fx.s.file_map['del.lua'].status == 'D')
end)

it('applying c1 only checks out c1 detached and lists only a.lua', function()
  local fx = h.start()
  range.apply(fx.main, fx.c1, 'custom')
  assert(h.git(fx.wt, 'rev-parse', 'HEAD') == fx.c1)
  assert(vim.system({ 'git', 'symbolic-ref', '-q', 'HEAD' }, { cwd = fx.wt }):wait().code ~= 0, 'must be detached')
  assert(vim.deep_equal(paths(fx.s), { 'a.lua' }))
end)

it('refuses to move a dirty worktree', function()
  local fx = h.start()
  h.write(fx.wt .. '/a.lua', 'dirty\n')
  local ok, err = pcall(range.apply, fx.main, fx.c1, 'custom')
  assert(not ok and err:find('uncommitted changes'), tostring(err))
  assert(h.git(fx.wt, 'rev-parse', 'HEAD') == fx.c2)
end)

it('applying all restores the branch', function()
  local fx = h.start()
  range.apply(fx.main, fx.c1, 'custom')
  range.apply(fx.s.merge_base, fx.s.head, 'all')
  assert(h.git(fx.wt, 'symbolic-ref', '--short', 'HEAD') == 'feat')
end)

it('stop restores the branch', function()
  local fx = h.start()
  range.apply(fx.main, fx.c1, 'custom')
  session.stop()
  assert(h.git(fx.wt, 'symbolic-ref', '--short', 'HEAD') == 'feat')
end)

it('revision specs diff like git diff, HEAD meaning the session head', function()
  local fx = h.start()
  local session = require('revision.session')
  session.start('main...HEAD')
  assert(fx.s.range.start == fx.main and fx.s.range.end_ == fx.c2 and fx.s.range.label == 'main...HEAD')

  range.apply(fx.main, fx.c1, 'custom')
  session.start('HEAD~1..')
  assert(fx.s.range.start == fx.c1 and fx.s.range.end_ == fx.c2, vim.inspect(fx.s.range))
  assert(h.git(fx.wt, 'symbolic-ref', '--short', 'HEAD') == 'feat')

  range.apply(fx.main, fx.c1, 'custom')
  h.write(fx.wt .. '/untracked.lua', 'x\n')
  session.start(fx.c1)
  assert(fx.s.range.worktree and fx.s.range.start == fx.c1, vim.inspect(fx.s.range))
  assert(h.git(fx.wt, 'symbolic-ref', '--short', 'HEAD') == 'feat', 'a worktree diff returns to the branch')
  assert(fx.s.file_map['new.lua'] and fx.s.file_map['untracked.lua'] and not fx.s.file_map['a.lua'])
  h.write(fx.wt .. '/new.lua', 'changed\n')
  range.reload()
  assert(fx.s.range.start == fx.c1, 'reload keeps the spec start')

  local ok, err = pcall(session.start, 'nope..HEAD')
  assert(not ok and err:find('unknown revision nope'), tostring(err))
end)

--- Pid of a process that has exited.
local function dead_pid()
  local p = vim.system({ 'git', '--version' })
  local pid = p.pid
  p:wait()
  return pid
end

it('a branch left detached by a session that died is restored on the next start', function()
  local fx = h.start()
  local session = require('revision.session')
  range.apply(fx.main, fx.c1, 'custom')
  range.recover(fx.wt)
  assert(h.git(fx.wt, 'rev-parse', 'HEAD') == fx.c1, 'a record whose Neovim still runs is left alone')
  -- Simulate a crash: the session vanishes without stop, and its Neovim is gone.
  pcall(vim.api.nvim_del_augroup_by_name, 'revision')
  session.s = nil
  local record = vim.fs.find(function(name)
    return name:match('%.json$')
  end, { path = vim.env.XDG_STATE_HOME .. '/nvim/revision/checkouts' })[1]
  local t = vim.json.decode(h.read(record))
  assert(t.pid == vim.fn.getpid(), vim.inspect(t))
  t.pid = dead_pid()
  h.write(record, vim.json.encode(t))
  local s = session.start()
  assert(h.git(fx.wt, 'symbolic-ref', '--short', 'HEAD') == 'feat' and s.branch == 'feat')

  range.apply(fx.main, fx.c1, 'custom')
  pcall(vim.api.nvim_del_augroup_by_name, 'revision')
  session.s = nil
  h.git(fx.wt, 'checkout', '-q', '--detach', fx.main)
  vim.cmd('silent! %bwipeout!')
  local record2 = vim.fs.find(function(name)
    return name:match('%.json$')
  end, { path = vim.env.XDG_STATE_HOME .. '/nvim/revision/checkouts' })[1]
  local t2 = vim.json.decode(h.read(record2))
  t2.pid = dead_pid()
  h.write(record2, vim.json.encode(t2))
  range.recover(fx.wt)
  assert(h.git(fx.wt, 'rev-parse', 'HEAD') == fx.main, 'a HEAD the user moved is left alone')
  h.git(fx.wt, 'checkout', '-q', 'feat')
  range.recover(fx.wt)
  assert(h.git(fx.wt, 'rev-parse', 'HEAD') == fx.c2, 'the record is gone after the first look')
end)

it('status describes the running session', function()
  assert(require('revision').status() == nil)
  h.start()
  assert(require('revision').status():find('^rev: '), require('revision').status())
end)
