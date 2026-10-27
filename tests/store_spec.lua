local h = require('tests.helpers')
local session = require('revision.session')
local store = require('revision.store')

it('save writes JSON with the schema keys and a worktree symlink', function()
  local fx = h.start()
  session.save()
  local path = store.path(fx.s)
  local t = vim.json.decode(h.read(path))
  for _, k in ipairs({ 'version', 'repo', 'branch', 'base_ref', 'merge_base', 'head', 'verdict', 'body', 'comments', 'viewed_files', 'viewed_hunks', 'rounds', 'next_id' }) do
    assert(t[k] ~= nil, 'missing key ' .. k)
  end
  assert(t.version == 1 and t.head == fx.c2 and t.merge_base == fx.main and t.branch == 'feat')
  assert(t.pr == vim.NIL and t.url == vim.NIL)
  assert(h.read(path):find('"viewed_files": {}', 1, true), 'viewed_files must encode as an object')
  local link = fx.wt .. '/.revision.json'
  assert(vim.uv.fs_lstat(link).type == 'link')
  assert(vim.uv.fs_readlink(link) == path)
end)

it('keeps unknown keys across load and save', function()
  local fx = h.start()
  session.save()
  local path = store.path(fx.s)
  local t = vim.json.decode(h.read(path))
  t.poster_state = { posted_at = 'x' }
  h.write(path, vim.json.encode(t))
  session.stop({ force = true })
  fx.s = session.start()
  session.save()
  local u = vim.json.decode(h.read(path))
  assert(u.poster_state and u.poster_state.posted_at == 'x')
end)

it('adds /.revision.json to info/exclude exactly once', function()
  local fx = h.start()
  session.save()
  session.save()
  local text = h.read(fx.repo .. '/.git/info/exclude')
  local _, n = text:gsub('\n/%.revision%.json\n', '\n')
  if text:sub(1, 15) == '/.revision.json' then
    n = n + 1
  end
  assert(n == 1, 'found ' .. n .. ' entries in\n' .. text)
  assert(h.git(fx.wt, 'status', '--porcelain') == '', 'symlink must be ignored')
end)

it('invalid JSON aborts start and leaves the file alone', function()
  local fx = h.start()
  session.save()
  local path = store.path(fx.s)
  session.stop({ force = true })
  h.write(path, '{ broken')
  local ok, err = pcall(session.start)
  assert(not ok and err:find('cannot parse'), tostring(err))
  assert(session.s == nil)
  assert(h.read(path) == '{ broken')
end)
