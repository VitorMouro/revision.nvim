local util = require('revision.util')

local M = {}

M.VERSION = 1

local SEVERITY = { blocking = true, major = true, minor = true, nit = true, info = true }

local LISTS = { 'meta', 'reviews', 'threads', 'findings', 'order', 'tasks', 'posted' }

local function why_skip(item)
  if type(item) ~= 'table' then
    return 'missing field'
  end
  if item.id == nil or item.id == vim.NIL then
    return 'missing field'
  end
  if type(item.path) ~= 'string' or type(item.line) ~= 'number' then
    return 'missing field'
  end
  if type(item.commit) ~= 'string' then
    return 'missing field'
  end
  if item.side ~= 'RIGHT' and item.side ~= 'LEFT' then
    return 'bad side'
  end
end

local function anchored(list, what)
  local out = {}
  for _, item in ipairs(list) do
    local why = why_skip(item)
    if why then
      local id = type(item) == 'table' and util.nn(item.id) or nil
      util.warn(('context.json: %s %s skipped: %s'):format(what, id and tostring(id) or '?', why))
    else
      item.order = #out + 1
      table.insert(out, item)
    end
  end
  return out
end

--- Reads the context file written by the review tool; nil when absent. Never writes.
function M.load(path)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end
  local text = f:read('*a')
  f:close()
  local ok, t = pcall(vim.json.decode, text)
  if not ok or type(t) ~= 'table' then
    error(('cannot parse %s: %s'):format(path, ok and 'not an object' or t), 0)
  end
  if type(t.version) == 'number' and t.version > M.VERSION then
    error('unsupported context file version ' .. t.version, 0)
  end
  for _, k in ipairs(LISTS) do
    if type(t[k]) ~= 'table' then
      t[k] = {}
    end
  end
  t.threads = anchored(t.threads, 'threads')
  t.findings = anchored(t.findings, 'findings')
  for _, th in ipairs(t.threads) do
    th.remote = true
  end
  for _, fd in ipairs(t.findings) do
    fd.finding = true
    if not SEVERITY[fd.severity] then
      fd.severity = 'info'
    end
    if type(fd.title) ~= 'string' then
      fd.title = ''
    end
  end
  return t
end

--- Folds the loaded context into the session: posted comments, task status and a cleared round.
function M.apply(s)
  s.posted_ids, s.task_status = {}, {}
  local ctx = s.ctx
  if not ctx then
    return
  end
  for _, t in ipairs(ctx.threads) do
    for _, c in ipairs(t.comments or {}) do
      local id = util.nn(c.local_id)
      if type(id) == 'number' then
        s.posted_ids[id] = true
      end
    end
  end
  for _, t in ipairs(ctx.tasks) do
    local id = util.nn(t.local_id)
    if type(id) == 'number' then
      s.task_status[id] = { status = util.nn(t.status), note = util.nn(t.note) }
    end
  end
  local store = require('revision.store')
  local last = s.review.rounds[#s.review.rounds]
  if last and vim.tbl_contains(ctx.posted, last.saved_at) and (s.review.body ~= '' or util.nn(s.review.verdict)) then
    s.review.body = ''
    s.review.verdict = vim.NIL
    store.set_body_lines(s)
    store.touch()
    util.notify('last review round was posted; body and verdict cleared (save to keep)')
  end
  if s.range then
    require('revision.comments').reanchor(s)
    require('revision.inline').rerender()
  end
end

return M
