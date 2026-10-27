local h = require('tests.helpers')
local comments = require('revision.comments')
local range = require('revision.range')

local function add(s, path, line, commit)
  local r = s.review
  table.insert(r.comments, {
    id = r.next_id,
    path = path,
    side = 'RIGHT',
    start_line = vim.NIL,
    line = line,
    commit = commit,
    body = 'note ' .. r.next_id,
    private = false,
    created_at = '',
    updated_at = '',
  })
  r.next_id = r.next_id + 1
  return r.comments[#r.comments]
end

it('comments follow their content when a new commit lands', function()
  local fx = h.start({ pr = true })
  local keep = add(fx.s, 'a.lua', 15, fx.c2)
  local gone = add(fx.s, 'new.lua', 1, fx.c2)
  vim.cmd('silent! %bwipeout!')

  local text = h.read(fx.wt .. '/a.lua')
  h.write(fx.wt .. '/a.lua', '-- first\n-- second\n' .. text)
  h.git(fx.wt, 'rm', '-q', 'new.lua')
  h.git(fx.wt, 'commit', '-q', '-am', 'c3')
  local c3 = h.git(fx.wt, 'rev-parse', 'HEAD')

  range.apply(fx.s.merge_base, c3, 'all')
  assert(keep.commit == c3 and keep.line == 17, ('%s:%d'):format(keep.commit, keep.line))
  assert(comments.mapped_row(fx.s, keep) == 17)
  assert(gone.commit == fx.c2 and gone.line == 1, 'a deleted file comment must not move')
end)

it('a comment on a changed line moves to the line that replaced it', function()
  local fx = h.start({ pr = true })
  local c = add(fx.s, 'a.lua', 3, fx.c2)
  vim.cmd('silent! %bwipeout!')

  local text = h.read(fx.wt .. '/a.lua'):gsub('local v5 = 500', 'local v5 = 5000')
  h.write(fx.wt .. '/a.lua', text)
  h.git(fx.wt, 'commit', '-q', '-am', 'c3')
  local c3 = h.git(fx.wt, 'rev-parse', 'HEAD')

  range.apply(fx.s.merge_base, c3, 'all')
  assert(c.commit == c3 and c.line == 3, ('%s:%d'):format(c.commit, c.line))
  assert(comments.mapped_row(fx.s, c) == 3)
end)

it('a multi-line comment keeps its span when lines are inserted above it', function()
  local fx = h.start({ pr = true })
  local c = add(fx.s, 'a.lua', 15, fx.c2)
  c.start_line = 14
  vim.cmd('silent! %bwipeout!')

  local text = h.read(fx.wt .. '/a.lua')
  h.write(fx.wt .. '/a.lua', '-- first\n-- second\n' .. text)
  h.git(fx.wt, 'commit', '-q', '-am', 'c3')
  local c3 = h.git(fx.wt, 'rev-parse', 'HEAD')

  range.apply(fx.s.merge_base, c3, 'all')
  assert(c.commit == c3 and c.start_line == 16 and c.line == 17, ('%s:%s-%s'):format(c.commit, c.start_line, c.line))
end)

it('an older range leaves comments where they are', function()
  local fx = h.start({ pr = true })
  local c = add(fx.s, 'a.lua', 15, fx.c2)
  vim.cmd('silent! %bwipeout!')

  range.apply(fx.main, fx.c1, 'custom')
  assert(c.commit == fx.c2 and c.line == 15, ('%s:%d'):format(c.commit, c.line))
end)
