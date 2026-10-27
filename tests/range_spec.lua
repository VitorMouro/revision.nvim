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
  session.stop({ force = true })
  assert(h.git(fx.wt, 'symbolic-ref', '--short', 'HEAD') == 'feat')
end)

it('offers "since last review" after a save at an older head', function()
  local fx = h.start()
  local kinds = function()
    return vim.tbl_map(function(i)
      return i.kind
    end, range.items(fx.s))
  end
  assert(vim.deep_equal(kinds(), { 'working', 'all', 'commit', 'commit' }))
  fx.s.head = fx.c1
  session.save()
  fx.s.head = fx.c2
  local items = range.items(fx.s)
  assert(items[3].kind == 'since' and items[3].last == fx.c1, vim.inspect(items[3]))
end)
