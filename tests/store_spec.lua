local h = require('tests.helpers')
local session = require('revision.session')
local store = require('revision.store')

it('save writes JSON with the schema keys into a linked review directory', function()
  local fx = h.start()
  session.save()
  local path = store.review_path(fx.s)
  local t = vim.json.decode(h.read(path))
  for _, k in ipairs({
    'version',
    'repo',
    'branch',
    'base_ref',
    'merge_base',
    'head',
    'verdict',
    'body',
    'comments',
    'viewed_files',
    'viewed_hunks',
    'rounds',
    'next_id',
    'dismissed_findings',
    'reviewed_commits',
    'view',
  }) do
    assert(t[k] ~= nil, 'missing key ' .. k)
  end
  assert(t.version == 2 and t.head == fx.c2 and t.merge_base == fx.main and t.branch == 'feat')
  assert(t.pr == nil and t.url == nil)
  assert(h.read(path):find('"viewed_files": {}', 1, true), 'viewed_files must encode as an object')
  local link = fx.wt .. '/.revision'
  assert(vim.uv.fs_lstat(link).type == 'link')
  assert(vim.uv.fs_realpath(link) == vim.fs.dirname(path))
  assert(path:sub(-12) == '/review.json', path)
end)

it('a real .revision directory is used as is', function()
  local fx = h.start({ context = true })
  session.save()
  assert(h.read(fx.wt .. '/.revision/review.json'), 'review.json must live in the directory')
  assert(vim.uv.fs_lstat(fx.wt .. '/.revision').type == 'directory')
  assert(h.git(fx.wt, 'status', '--porcelain') == '', 'the directory must be ignored')
end)

it('keeps unknown keys across load and save', function()
  local fx = h.start()
  session.save()
  local path = store.review_path(fx.s)
  local t = vim.json.decode(h.read(path))
  t.poster_state = { posted_at = 'x' }
  h.write(path, vim.json.encode(t))
  session.stop({ force = true })
  fx.s = session.start()
  session.save()
  local u = vim.json.decode(h.read(path))
  assert(u.poster_state and u.poster_state.posted_at == 'x')
end)

it('adds /.revision to info/exclude exactly once', function()
  local fx = h.start()
  session.save()
  session.save()
  local text = h.read(fx.repo .. '/.git/info/exclude')
  local n = 0
  for line in vim.gsplit(text, '\n', { plain = true }) do
    if line == '/.revision' then
      n = n + 1
    end
  end
  assert(n == 1, 'found ' .. n .. ' entries in\n' .. text)
  assert(h.git(fx.wt, 'status', '--porcelain') == '', 'symlink must be ignored')
end)

it('invalid JSON aborts start and leaves the file alone', function()
  local fx = h.start()
  session.save()
  local path = store.review_path(fx.s)
  session.stop({ force = true })
  h.write(path, '{ broken')
  local ok, err = pcall(session.start)
  assert(not ok and err:find('cannot parse'), tostring(err))
  assert(session.s == nil)
  assert(h.read(path) == '{ broken')
end)
