local util = require('revision.util')
local git = require('revision.git')

local M = {}

local function session()
  return require('revision.session').s
end

local function parse_files(name_status, numstat)
  local files, by_path = {}, {}
  local f = vim.split(name_status, '\0', { plain = true })
  local i = 1
  while i <= #f and f[i] ~= '' do
    local st = f[i]:sub(1, 1)
    local e
    if st == 'R' or st == 'C' then
      e = { status = st == 'R' and 'R' or 'A', old_path = f[i + 1], path = f[i + 2] }
      i = i + 3
    else
      e = { status = st == 'T' and 'M' or st, path = f[i + 1] }
      i = i + 2
    end
    e.additions, e.deletions, e.binary = 0, 0, false
    table.insert(files, e)
    by_path[e.path] = e
  end

  local n = vim.split(numstat, '\0', { plain = true })
  i = 1
  while i <= #n and n[i] ~= '' do
    local a, d, p = n[i]:match('^(%S+)\t(%S+)\t(.*)$')
    if p == '' then
      p = n[i + 2]
      i = i + 3
    else
      i = i + 1
    end
    local e = by_path[p]
    if e then
      e.binary = a == '-'
      e.additions = tonumber(a) or 0
      e.deletions = tonumber(d) or 0
    end
  end
  table.sort(files, function(x, y)
    return x.path < y.path
  end)
  return files
end

--- Per-path hunks of `git diff <revs...>`; one rev diffs against the worktree.
local function hunks_for(root, revs)
  local args = { 'diff', '-U0', '--histogram', '--indent-heuristic', '--no-color', '-M' }
  vim.list_extend(args, revs)
  local hunks = git.parse_hunks(git.run(root, args))
  for path, list in pairs(hunks) do
    for _, h in ipairs(list) do
      h.hash = git.hunk_hash(path, h.old_lines, h.new_lines)
    end
  end
  return hunks
end

local function blobs_for(root, rev)
  local out = git.run(root, { 'ls-tree', '-r', '-z', rev })
  local blobs = {}
  for rec in vim.gsplit(out, '\0', { plain = true }) do
    local sha, path = rec:match('^%S+ %S+ (%x+)\t(.*)$')
    if sha then
      blobs[path] = sha
    end
  end
  return blobs
end

local function check_clean(s)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      if name:sub(1, #s.root + 1) == s.root .. '/' then
        error('unsaved changes in ' .. name:sub(#s.root + 2), 0)
      end
    end
  end
  if git.out(s.root, { 'status', '--porcelain', '--untracked-files=no' }) ~= '' then
    error('uncommitted changes; commit/stash them or pick Working changes', 0)
  end
end

--- Checks out end_ (the branch when end_ is the session head). No safety checks.
function M.checkout(s, end_)
  local store = require('revision.store')
  if end_ == s.head and s.branch then
    git.run(s.root, { 'checkout', '--quiet', s.branch })
    store.clear_detached(s.root)
  else
    if s.branch then
      store.mark_detached(s.root, s.branch, end_)
    end
    git.run(s.root, { 'checkout', '--quiet', '--detach', end_ })
  end
end

--- Whether the Neovim that wrote a detach record still runs; EPERM means it does.
local function alive(pid)
  if type(pid) ~= 'number' then
    return false
  end
  local ok, _, name = vim.uv.kill(pid, 0)
  return ok == 0 or name == 'EPERM'
end

--- Puts back the branch revision left detached when Neovim died mid-session. Skips
--- records whose Neovim still runs: that session owns the checkout. Leaves HEAD alone,
--- dropping the record, when the user has moved it since.
function M.recover(dir)
  local store = require('revision.store')
  local t = store.detached_under(dir)
  if not t or alive(t.pid) then
    return
  end
  store.clear_detached(t.root)
  if git.current_branch(t.root) or git.try_head(t.root) ~= t.sha then
    return
  end
  if git.out(t.root, { 'status', '--porcelain', '--untracked-files=no' }, { allow_fail = true }) ~= '' then
    util.warn(('%s was left detached at %s; local changes, so not restoring %s'):format(t.root, util.short(t.sha), t.branch))
    return
  end
  local ok = git.run(t.root, { 'checkout', '--quiet', t.branch }, { allow_fail = true })
  if ok then
    util.notify(('restored branch %s (left detached at %s by an interrupted session)'):format(t.branch, util.short(t.sha)))
    vim.cmd('silent! checktime')
  else
    util.warn(('could not restore branch %s in %s'):format(t.branch, t.root))
  end
end

--- Whether the worktree is at end_; a branch without commits has nothing to check out.
function M.at(s, end_)
  if not end_ then
    return true
  end
  if git.try_head(s.root) ~= end_ then
    return false
  end
  if end_ == s.head and s.branch then
    return git.current_branch(s.root) == s.branch
  end
  return true
end

--- The session follows the branch: new local commits move head and the bases.
function M.refresh_local(s)
  if s.branch then
    local tip = git.out(s.root, { 'rev-parse', '--verify', '-q', 'refs/heads/' .. s.branch }, { allow_fail = true })
    s.head = tip ~= '' and tip or nil
  end
  if not s.head then
    s.merge_base, s.upstream_base = nil, nil
    return
  end
  if s.base then
    s.merge_base = git.out(s.root, { 'merge-base', s.head, s.base }, { allow_fail = true })
  end
  s.upstream_base = s.upstream and git.out(s.root, { 'merge-base', s.head, s.upstream }, { allow_fail = true })
end

local function set(s, files, hunks, blobs, range)
  table.sort(files, function(x, y)
    return x.path < y.path
  end)
  s.files = files
  s.file_map = {}
  for _, e in ipairs(files) do
    s.file_map[e.path] = e
  end
  s.hunks = hunks
  s.blobs = blobs
  s.range = range
  s.category_cache = nil
  require('revision.viewed').reconcile(s)
  require('revision.inline').refresh_all()
end

--- Reviews start..end_ by checking out end_. Refused while tracked files have local changes.
function M.apply(start, end_, label)
  local s = session()
  check_clean(s)
  if not M.at(s, end_) then
    M.checkout(s, end_)
    local inline = require('revision.inline')
    for _, buf in ipairs(inline.root_bufs()) do
      vim.bo[buf].modifiable = true
    end
    vim.cmd('silent! checktime')
  end
  local name_status = git.run(s.root, { 'diff', '--name-status', '-z', '-M', '--no-color', start, end_ })
  local numstat = git.run(s.root, { 'diff', '--numstat', '-z', '-M', start, end_ })
  set(s, parse_files(name_status, numstat), hunks_for(s.root, { start, end_ }), blobs_for(s.root, end_), {
    start = start,
    end_ = end_,
    label = label,
  })
end

local function untracked(s, files, hunks)
  local out = git.run(s.root, { 'ls-files', '--others', '--exclude-standard', '-z' })
  for path in vim.gsplit(out, '\0', { plain = true }) do
    if path ~= '' then
      local f = io.open(s.root .. '/' .. path, 'rb')
      local text = f and f:read('*a') or ''
      if f then
        f:close()
      end
      local binary = text:sub(1, 8000):find('\0', 1, true) ~= nil
      local lines = binary and {} or util.lines((text:gsub('\r\n', '\n')))
      table.insert(files, {
        path = path,
        status = 'A',
        untracked = true,
        additions = #lines,
        deletions = 0,
        binary = binary,
      })
      if #lines > 0 then
        hunks[path] = {
          {
            old_start = 0,
            old_count = 0,
            new_start = 1,
            new_count = #lines,
            old_lines = {},
            new_lines = lines,
            hash = git.hunk_hash(path, {}, lines),
          },
        }
      end
    end
  end
end

--- Worktree content ids: what the blob shas would be if the files were committed now.
local function worktree_blobs(s, files)
  local paths = {}
  for _, e in ipairs(files) do
    if e.status ~= 'D' then
      table.insert(paths, e.path)
    end
  end
  local blobs = {}
  if #paths == 0 then
    return blobs
  end
  local args = { 'hash-object', '--' }
  vim.list_extend(args, paths)
  for i, sha in ipairs(util.lines(git.run(s.root, args))) do
    blobs[paths[i]] = sha
  end
  return blobs
end

--- Diffs start (default HEAD) against the worktree, untracked files as added.
--- Returns to the branch first when a commit range has it checked out elsewhere.
function M.working(start, label)
  local s = session()
  M.refresh_local(s)
  if not M.at(s, s.head) then
    check_clean(s)
    M.checkout(s, s.head)
    vim.cmd('silent! checktime')
  end
  local base = start or git.try_head(s.root) or git.EMPTY_TREE
  local name_status = git.run(s.root, { 'diff', '--name-status', '-z', '-M', '--no-color', base })
  local numstat = git.run(s.root, { 'diff', '--numstat', '-z', '-M', base })
  local files = parse_files(name_status, numstat)
  local hunks = hunks_for(s.root, { base })
  untracked(s, files, hunks)
  set(s, files, hunks, worktree_blobs(s, files), {
    start = base,
    worktree = true,
    label = label or 'working',
    follow = start == nil,
  })
end

--- Recomputes a worktree range after files change on disk; commit ranges are fixed.
function M.reload()
  local s = session()
  local r = s and s.range
  if r and r.worktree then
    M.working(not r.follow and r.start or nil, r.label)
  end
end

--- Commit sha of rev; HEAD means the session head, not a commit range checked out.
local function resolve(s, rev)
  if rev == '' then
    rev = 'HEAD'
  end
  if s.head and rev:match('^HEAD') then
    rev = s.head .. rev:sub(5)
  end
  local sha = git.out(s.root, { 'rev-parse', '--verify', '-q', rev .. '^{commit}' }, { allow_fail = true })
  if not sha or sha == '' then
    error('unknown revision ' .. rev, 0)
  end
  return sha
end

--- Diffs a revision spec like git diff: "A..B" diffs A against B, "A...B" the merge
--- base against B, both checking out B; an empty side is HEAD. A single revision is
--- diffed against the worktree.
function M.from_spec(spec)
  local s = session()
  M.refresh_local(s)
  local a, b = spec:match('^(.-)%.%.%.(.*)$')
  if a then
    local x, y = resolve(s, a), resolve(s, b)
    local base = git.out(s.root, { 'merge-base', x, y }, { allow_fail = true })
    if not base or base == '' then
      error(spec .. ': no merge base', 0)
    end
    return M.apply(base, y, spec)
  end
  a, b = spec:match('^(.-)%.%.(.*)$')
  if a then
    return M.apply(resolve(s, a), resolve(s, b), spec)
  end
  M.working(resolve(s, spec), spec)
end

local function short(rev)
  return rev == git.EMPTY_TREE and 'empty' or util.short(rev)
end

function M.describe(r)
  local stop = r.worktree and 'worktree' or short(r.end_)
  return ('%s %s..%s'):format(r.label, short(r.start), stop)
end

--- Commits after the merge base (or upstream base); the last 50 when neither exists.
function M.commits(s)
  local base = s.merge_base or s.upstream_base
  local args = { 'log', '--reverse', '--format=%H%x1f%P%x1f%s%x1f%an%x1f%ar' }
  if base then
    table.insert(args, base .. '..' .. s.head)
  else
    vim.list_extend(args, { '-n', '50', s.head })
  end
  local list = {}
  for _, line in ipairs(util.lines(git.run(s.root, args))) do
    local f = vim.split(line, '\x1f', { plain = true })
    table.insert(list, { sha = f[1], parents = f[2], subject = f[3], author = f[4], date = f[5] })
  end
  return list
end

--- First parent of sha, or the empty tree for a root commit.
function M.parent(s, sha)
  local p = git.out(s.root, { 'rev-parse', '--verify', '-q', sha .. '^1' }, { allow_fail = true })
  return (p and p ~= '') and p or git.EMPTY_TREE
end

--- Picker items: { text, kind = 'working'|'all'|'unpushed'|'commit', ... }.
function M.items(s)
  M.refresh_local(s)
  local head7 = util.short(s.head)
  local items = {
    {
      kind = 'working',
      text = ('Working changes  %s..worktree'):format(short(git.try_head(s.root) or git.EMPTY_TREE)),
    },
  }
  if not s.head then
    return items
  end
  if s.merge_base and s.merge_base ~= s.head then
    table.insert(items, { kind = 'all', text = ('All changes  %s..%s'):format(util.short(s.merge_base), head7) })
  end
  local ub = s.upstream_base
  if ub and ub ~= s.head and ub ~= s.merge_base then
    table.insert(items, {
      kind = 'unpushed',
      text = ('Unpushed (%s)  %s..%s'):format(s.upstream, util.short(ub), head7),
    })
  end
  local commits = M.commits(s)
  for i, c in ipairs(commits) do
    table.insert(items, {
      kind = 'commit',
      index = i,
      commits = commits,
      text = ('%s %s (%s, %s)'):format(util.short(c.sha), c.subject, c.author, c.date),
    })
  end
  return items
end

local function pick_end(s, item)
  local commits = item.commits
  local choices = { { text = 'Only this commit', sha = commits[item.index].sha } }
  for j = item.index + 1, #commits do
    local c = commits[j]
    table.insert(choices, { text = ('%s %s'):format(util.short(c.sha), c.subject), sha = c.sha })
  end
  if #choices > 1 then
    choices[#choices].text = choices[#choices].text .. ' (head)'
  end
  vim.ui.select(choices, {
    prompt = 'Range end',
    format_item = function(c)
      return c.text
    end,
  }, util.guard(function(c)
    if not c then
      return
    end
    M.apply(M.parent(s, commits[item.index].sha), c.sha, 'custom')
  end))
end

function M.pick()
  local s = session()
  vim.ui.select(M.items(s), {
    prompt = 'Revision range',
    format_item = function(i)
      return i.text
    end,
  }, util.guard(function(item)
    if not item then
      return
    end
    if item.kind == 'working' then
      M.working()
    elseif item.kind == 'all' then
      M.apply(s.merge_base, s.head, 'all')
    elseif item.kind == 'unpushed' then
      M.apply(s.upstream_base, s.head, 'unpushed')
    else
      pick_end(s, item)
    end
  end))
end

--- Initial range: working changes, else unpushed commits, else branch changes.
function M.default()
  local s = session()
  M.refresh_local(s)
  if git.out(s.root, { 'status', '--porcelain' }) ~= '' then
    return M.working()
  end
  if s.upstream_base and s.upstream_base ~= s.head then
    return M.apply(s.upstream_base, s.head, 'unpushed')
  end
  if s.merge_base and s.merge_base ~= s.head then
    return M.apply(s.merge_base, s.head, 'all')
  end
  util.notify('no local changes or unpushed commits; pick a range with <leader>rr')
  M.working()
end

return M
