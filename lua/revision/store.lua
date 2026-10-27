local util = require('revision.util')
local git = require('revision.git')

local M = {}

M.VERSION = 2

local function session()
  return require('revision.session').s
end

local function ensure_excluded(s)
  local dir = git.common_dir(s.root) .. '/info'
  vim.fn.mkdir(dir, 'p')
  local file = dir .. '/exclude'
  local text = ''
  local f = io.open(file, 'r')
  if f then
    text = f:read('*a')
    f:close()
  end
  for line in vim.gsplit(text, '\n', { plain = true }) do
    if line == '/.revision' then
      return
    end
  end
  f = assert(io.open(file, 'a'))
  if text ~= '' and text:sub(-1) ~= '\n' then
    f:write('\n')
  end
  f:write('/.revision\n')
  f:close()
end

--- The review directory. Creates <root>/.revision as a symlink into the data dir when absent.
function M.dir(s)
  local link = s.root .. '/.revision'
  local st = vim.uv.fs_lstat(link)
  local dir
  if st and st.type == 'link' then
    dir = vim.uv.fs_realpath(link)
    if not dir then
      local target = assert(vim.uv.fs_readlink(link))
      vim.fn.mkdir(target, 'p')
      dir = assert(vim.uv.fs_realpath(target))
    end
  elseif st and st.type == 'directory' then
    dir = link
  elseif st then
    error(link .. ' exists and is not a directory or symlink', 0)
  else
    local key
    if s.branch then
      key = 'branch-' .. s.branch:gsub('[^%w._-]', '_')
    else
      key = 'head-' .. (s.head or 'none'):sub(1, 12)
    end
    dir = vim.fn.stdpath('data') .. '/revision/' .. s.repo .. '/' .. key
    vim.fn.mkdir(dir, 'p')
    assert(vim.uv.fs_symlink(dir, link))
  end
  ensure_excluded(s)
  return dir
end

function M.review_path(s)
  return s.dir .. '/review.json'
end

function M.context_path(s)
  return s.dir .. '/context.json'
end

local function fresh()
  return {
    version = M.VERSION,
    verdict = vim.NIL,
    body = '',
    comments = {},
    viewed_files = vim.empty_dict(),
    viewed_hunks = {},
    rounds = {},
    next_id = 1,
    dismissed_findings = {},
    reviewed_commits = {},
    view = { sort = 'category', unviewed = false, annotated = false, categories = vim.NIL },
  }
end

--- Reads the review file; errors on unparsable or newer files. Never writes.
function M.load(path)
  local f = io.open(path, 'r')
  if not f then
    return fresh()
  end
  local text = f:read('*a')
  f:close()
  local ok, t = pcall(vim.json.decode, text)
  if not ok or type(t) ~= 'table' then
    error(('cannot parse %s: %s'):format(path, ok and 'not an object' or t), 0)
  end
  if type(t.version) == 'number' and t.version > M.VERSION then
    error('unsupported review file version ' .. t.version, 0)
  end
  for k, v in pairs(fresh()) do
    if t[k] == nil then
      t[k] = v
    end
  end
  return t
end

function M.touch()
  local s = session()
  if s and s.review_buf and vim.api.nvim_buf_is_valid(s.review_buf) then
    vim.bo[s.review_buf].modified = true
  end
end

function M.set_body_lines(s)
  local buf = s.review_buf
  local lines = vim.split(s.review.body or '', '\n', { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
end

function M.create_buf(s)
  local old = vim.fn.bufnr('revision://review')
  if old ~= -1 then
    vim.api.nvim_buf_delete(old, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, 'revision://review')
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  s.review_buf = buf
  M.set_body_lines(s)
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = util.guard(function()
      require('revision.session').save()
    end),
  })
  return buf
end

local function encode(review)
  local t = vim.deepcopy(review)
  if next(t.viewed_files) == nil then
    t.viewed_files = vim.empty_dict()
  end
  table.sort(t.viewed_hunks)
  table.sort(t.dismissed_findings)
  table.sort(t.reviewed_commits)
  return vim.json.encode(t, { indent = '  ', sort_keys = true })
end

--- Every commit of the reviewed range, oldest first.
local function range_commits(s)
  local r = s.range
  if not r or r.worktree or not r.end_ then
    return {}
  end
  local args = { 'rev-list' }
  if r.start == git.EMPTY_TREE then
    table.insert(args, r.end_)
  else
    table.insert(args, r.start .. '..' .. r.end_)
  end
  return util.lines(git.run(s.root, args, { allow_fail = true }) or '')
end

local function mark_reviewed(s)
  local seen = {}
  for _, sha in ipairs(s.review.reviewed_commits) do
    seen[sha] = true
  end
  for _, sha in ipairs(range_commits(s)) do
    if not seen[sha] then
      seen[sha] = true
      table.insert(s.review.reviewed_commits, sha)
    end
  end
end

function M.save(s)
  local r = s.review
  r.version = M.VERSION
  r.body = table.concat(vim.api.nvim_buf_get_lines(s.review_buf, 0, -1, false), '\n')
  r.repo = s.repo
  r.branch = s.branch or vim.NIL
  r.base_ref = s.base_ref or vim.NIL
  r.head = s.head or vim.NIL
  r.merge_base = s.merge_base or vim.NIL
  local now = util.now()
  local last = r.rounds[#r.rounds]
  if last and last.head == s.head then
    last.saved_at = now
  elseif s.head then
    table.insert(r.rounds, { head = s.head, saved_at = now })
  end
  mark_reviewed(s)

  local path = M.review_path(s)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local tmp = path .. '.tmp'
  local f = assert(io.open(tmp, 'w'))
  f:write(encode(r), '\n')
  f:close()
  assert(vim.uv.fs_rename(tmp, path))
  vim.bo[s.review_buf].modified = false
  util.notify('saved ' .. path)
end

function M.unlink(s)
  vim.uv.fs_unlink(M.review_path(s))
end

return M
