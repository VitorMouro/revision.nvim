local M = {}

--- Notifications captured by the runner.
M.notes = {}

local function sh(cwd, argv)
  local r = vim.system(argv, { cwd = cwd, text = true }):wait()
  if r.code ~= 0 then
    error(table.concat(argv, ' ') .. ': ' .. (r.stderr or ''), 2)
  end
  return vim.trim(r.stdout)
end
M.sh = sh

function M.git(cwd, ...)
  return sh(cwd, { 'git', ... })
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'wb'))
  f:write(text)
  f:close()
end
M.write = write

function M.read(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local t = f:read('*a')
  f:close()
  return t
end

local function numbered(n, fmt)
  local t = {}
  for i = 1, n do
    t[i] = (fmt or 'local v%d = %d'):format(i, i)
  end
  return t
end

--- Only git on PATH, so gh is unavailable; data dir under a temp dir.
function M.isolate()
  local tmp = vim.fn.tempname()
  local bin = tmp .. '/bin'
  vim.fn.mkdir(bin, 'p')
  vim.uv.fs_symlink(vim.fn.exepath('git'), bin .. '/git')
  vim.env.PATH = bin
  vim.env.XDG_DATA_HOME = tmp .. '/data'
  vim.env.GIT_CONFIG_GLOBAL = '/dev/null'
  vim.env.GIT_CONFIG_NOSYSTEM = '1'
  vim.env.GIT_AUTHOR_NAME, vim.env.GIT_AUTHOR_EMAIL = 'T', 't@x'
  vim.env.GIT_COMMITTER_NAME, vim.env.GIT_COMMITTER_EMAIL = 'T', 't@x'
end

--- Builds main + feat (c1, c2) in a repo with a worktree at feat.
--- Returns { repo, wt, main, c1, c2 }. dir defaults to a temp dir removed when nvim exits.
function M.fixture(dir)
  dir = dir or vim.fn.tempname()
  local repo = dir .. '/repo'
  vim.fn.mkdir(repo, 'p')
  vim.env.XDG_DATA_HOME = dir .. '/data'
  M.git(repo, 'init', '-q', '-b', 'main')
  local a = numbered(20)
  write(repo .. '/a.lua', table.concat(a, '\n') .. '\n')
  write(repo .. '/del.lua', 'return "deleted"\nlocal x = 1\n')
  write(repo .. '/move_me.lua', table.concat(numbered(10, 'print(%d, %d)'), '\n') .. '\n')
  write(repo .. '/bin.png', '\0\1\2')
  M.git(repo, 'add', '-A')
  M.git(repo, 'commit', '-q', '-m', 'base')
  local main = M.git(repo, 'rev-parse', 'HEAD')

  M.git(repo, 'checkout', '-q', '-b', 'feat')
  local b = vim.deepcopy(a)
  b[5] = 'local v5 = 500'
  table.remove(b, 1)
  table.remove(b, 1)
  vim.list_extend(b, { 'local extra1 = 1', 'local extra2 = 2', 'local extra3 = 3' })
  write(repo .. '/a.lua', table.concat(b, '\n') .. '\n')
  M.git(repo, 'commit', '-q', '-am', 'c1 edit a')
  local c1 = M.git(repo, 'rev-parse', 'HEAD')

  M.git(repo, 'rm', '-q', 'del.lua')
  M.git(repo, 'mv', 'move_me.lua', 'moved.lua')
  write(repo .. '/new.lua', 'return { new = true }\n')
  M.git(repo, 'add', '-A')
  M.git(repo, 'commit', '-q', '-m', 'c2 files')
  local c2 = M.git(repo, 'rev-parse', 'HEAD')

  M.git(repo, 'checkout', '-q', 'main')
  M.git(repo, 'update-ref', 'refs/remotes/origin/main', 'main')
  M.git(repo, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
  local wt = dir .. '/wt'
  M.git(repo, 'worktree', 'add', '-q', wt, 'feat')
  wt = vim.uv.fs_realpath(wt)
  return { repo = repo, wt = wt, main = main, c1 = c1, c2 = c2 }
end

local gh = require('revision.gh')
local real_pr_view = gh.pr_view

--- Fresh fixture with the session started in its worktree; opts.pr stubs gh with an open PR for feat.
function M.start(opts)
  local fx = M.fixture()
  vim.cmd.cd(vim.fn.fnameescape(fx.wt))
  if opts and opts.pr then
    gh.pr_view = function()
      return {
        number = 7,
        url = 'https://github.com/o/r/pull/7',
        title = 'feat',
        baseRefName = 'main',
        baseRefOid = fx.main,
        headRefName = 'feat',
        headRefOid = fx.c2,
      }
    end
  end
  fx.s = require('revision.session').start()
  return fx
end

--- Tears down any session and all buffers between tests.
function M.reset()
  local session = require('revision.session')
  pcall(session.stop, { force = true })
  session.s = nil
  gh.pr_view = real_pr_view
  vim.cmd('silent! %bwipeout!')
end

return M
