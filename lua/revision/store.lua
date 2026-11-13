local util = require('revision.util')

local M = {}

M.VERSION = 1

local function fresh()
  return { version = M.VERSION, viewed_files = {}, viewed_hunks = {} }
end

--- <stdpath('state')>/revision/<repo>/<branch or head>.json
function M.path(s)
  local key
  if s.branch then
    key = 'branch-' .. s.branch:gsub('[^%w._-]', '_')
  else
    key = 'head-' .. (s.head or 'none'):sub(1, 12)
  end
  return ('%s/revision/%s/%s.json'):format(vim.fn.stdpath('state'), s.repo, key)
end

--- Viewed marks of the session's repo and branch. Errors on an unparsable file
--- instead of starting empty, which would overwrite it on the next mark.
function M.load(s)
  local path = M.path(s)
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
  local out = fresh()
  if type(t.viewed_files) == 'table' then
    out.viewed_files = t.viewed_files
  end
  if type(t.viewed_hunks) == 'table' then
    out.viewed_hunks = t.viewed_hunks
  end
  return out
end

--- Writes the marks atomically (tmp + rename).
function M.save(s)
  local t = vim.deepcopy(s.marks)
  t.version = M.VERSION
  if next(t.viewed_files) == nil then
    t.viewed_files = vim.empty_dict()
  end
  table.sort(t.viewed_hunks)
  local path = M.path(s)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local tmp = path .. '.tmp'
  local f = assert(io.open(tmp, 'w'))
  f:write(vim.json.encode(t, { indent = '  ', sort_keys = true }), '\n')
  f:close()
  local ok, err = vim.uv.fs_rename(tmp, path)
  if not ok then
    util.err('cannot save viewed marks: ' .. tostring(err))
  end
end

return M
