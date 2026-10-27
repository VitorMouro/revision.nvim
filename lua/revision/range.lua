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
  if end_ == s.head and s.branch then
    git.run(s.root, { 'checkout', '--quiet', s.branch })
  else
    git.run(s.root, { 'checkout', '--quiet', '--detach', end_ })
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

--- Without a PR the session follows the branch: new local commits move head and the bases.
function M.refresh_local(s)
  if s.pr then
    return
  end
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
  s.pr_diff = {}
  require('revision.comments').reanchor(s)
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

--- Reviews uncommitted changes: HEAD against the worktree, untracked files as added.
function M.working()
  local s = session()
  M.refresh_local(s)
  local head = git.try_head(s.root) or git.EMPTY_TREE
  local name_status = git.run(s.root, { 'diff', '--name-status', '-z', '-M', '--no-color', head })
  local numstat = git.run(s.root, { 'diff', '--numstat', '-z', '-M', head })
  local files = parse_files(name_status, numstat)
  local hunks = hunks_for(s.root, { head })
  untracked(s, files, hunks)
  set(s, files, hunks, worktree_blobs(s, files), { start = head, worktree = true, label = 'working' })
end

--- Recomputes the working-changes range after files change on disk; commit ranges are fixed.
function M.reload()
  local s = session()
  if s and s.range and s.range.worktree then
    M.working()
  end
end

local function short(rev)
  return rev == git.EMPTY_TREE and 'empty' or util.short(rev)
end

function M.describe(r)
  local stop = r.worktree and 'worktree' or short(r.end_)
  return ('%s %s..%s'):format(r.label, short(r.start), stop)
end

--- The newest saved round head that is a strict ancestor of the PR head, or nil.
function M.last_reviewed(s)
  if not s.head then
    return nil
  end
  local rounds = s.review.rounds or {}
  local older = false
  for i = #rounds, 1, -1 do
    local h = rounds[i].head
    if h ~= s.head then
      older = true
      if git.ok(s.root, { 'merge-base', '--is-ancestor', h, s.head }) then
        return h
      end
    end
  end
  if older and not s.warned_force_push then
    s.warned_force_push = true
    util.warn("last reviewed head is not in this PR's history (force-push?)")
  end
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

--- Picker items: { text, kind = 'working'|'all'|'unpushed'|'since'|'commit', ... }.
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
  local last = M.last_reviewed(s)
  if last then
    table.insert(items, {
      kind = 'since',
      last = last,
      text = ('Since last review  %s..%s'):format(util.short(last), head7),
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
    choices[#choices].text = choices[#choices].text .. (s.pr and ' (PR head)' or ' (head)')
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
    local first = commits[item.index].sha
    local parent = git.out(s.root, { 'rev-parse', '--verify', '-q', first .. '^1' }, { allow_fail = true })
    M.apply((parent and parent ~= '') and parent or git.EMPTY_TREE, c.sha, 'custom')
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
    elseif item.kind == 'since' then
      M.apply(item.last, s.head, 'since last review')
    else
      pick_end(s, item)
    end
  end))
end

--- Initial range: PR changes for a PR, else working changes, unpushed commits or branch changes.
function M.default()
  local s = session()
  local tracked_dirty = git.out(s.root, { 'status', '--porcelain', '--untracked-files=no' }) ~= ''
  if s.pr then
    if tracked_dirty then
      util.notify('worktree has local changes; reviewing working changes')
      return M.working()
    end
    return M.apply(s.merge_base, s.head, 'all')
  end
  if tracked_dirty or git.out(s.root, { 'status', '--porcelain' }) ~= '' then
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
