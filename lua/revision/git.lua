local util = require('revision.util')

local M = {}

--- Raw stdout of `git -c core.quotePath=false <args>` in root.
function M.run(root, args, opts)
  local argv = { 'git', '-c', 'core.quotePath=false' }
  vim.list_extend(argv, args)
  opts = vim.tbl_extend('force', { cwd = root, timeout = 10000 }, opts or {})
  return util.run(argv, opts)
end

--- Trimmed stdout, or nil when the command fails and opts.allow_fail is set.
function M.out(root, args, opts)
  local o = M.run(root, args, opts)
  return o and util.trim(o)
end

function M.ok(root, args)
  return M.run(root, args, { allow_fail = true }) ~= nil
end

function M.toplevel(cwd)
  local o = M.out(cwd, { 'rev-parse', '--show-toplevel' }, { allow_fail = true })
  if not o or o == '' then
    error('not in a git repository', 0)
  end
  return o
end

function M.common_dir(root)
  return M.out(root, { 'rev-parse', '--path-format=absolute', '--git-common-dir' })
end

function M.head(root)
  return M.out(root, { 'rev-parse', 'HEAD' })
end

--- The empty tree object: the base for files when there is no parent commit.
M.EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

--- HEAD's sha, or nil on a branch without commits.
function M.try_head(root)
  local o = M.out(root, { 'rev-parse', '--verify', '-q', 'HEAD' }, { allow_fail = true })
  if o == '' then
    return nil
  end
  return o
end

function M.current_branch(root)
  local b = M.out(root, { 'symbolic-ref', '--short', '-q', 'HEAD' }, { allow_fail = true })
  if b == '' then
    return nil
  end
  return b
end

function M.show(root, rev, path)
  return M.run(root, { 'show', rev .. ':' .. path })
end

--- Parses `git diff` output into { [path] = { hunk... } } with old_lines/new_lines per hunk.
function M.parse_hunks(text)
  local out = {}
  local old_path, path, cur
  for line in vim.gsplit(text, '\n', { plain = true }) do
    if line:sub(1, 11) == 'diff --git ' then
      old_path, path, cur = nil, nil, nil
    elseif not cur and line:sub(1, 4) == '--- ' then
      local p = line:sub(5):gsub('\t$', '')
      old_path = p ~= '/dev/null' and p:sub(3) or nil
    elseif not cur and line:sub(1, 4) == '+++ ' then
      local p = line:sub(5):gsub('\t$', '')
      path = p ~= '/dev/null' and p:sub(3) or old_path
      out[path] = out[path] or {}
    elseif line:sub(1, 3) == '@@ ' then
      local a, b, c, d = line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
      cur = {
        old_start = tonumber(a),
        old_count = b == '' and 1 or tonumber(b),
        new_start = tonumber(c),
        new_count = d == '' and 1 or tonumber(d),
        old_lines = {},
        new_lines = {},
      }
      table.insert(out[path], cur)
    elseif cur then
      local ch = line:sub(1, 1)
      if ch == '-' then
        table.insert(cur.old_lines, line:sub(2))
      elseif ch == '+' then
        table.insert(cur.new_lines, line:sub(2))
      end
    end
  end
  return out
end

function M.hunk_hash(path, old_lines, new_lines)
  return vim.fn.sha256(path .. '\0' .. table.concat(old_lines, '\n') .. '\0' .. table.concat(new_lines, '\n'))
end

return M
