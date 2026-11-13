local util = require('revision.util')
local inline = require('revision.inline')
local store = require('revision.store')

local M = {}

local function session()
  return require('revision.session').s
end

--- The value stored for a viewed file: its blob at the range end, or "deleted".
local function marker(s, path)
  local e = s.file_map[path]
  if e and e.status == 'D' then
    return 'deleted'
  end
  return s.blobs[path]
end

function M.file_viewed(s, path)
  local v = s.marks.viewed_files[path]
  return v ~= nil and v == marker(s, path)
end

function M.hunk_counts(s, path)
  local set = {}
  for _, h in ipairs(s.marks.viewed_hunks) do
    set[h] = true
  end
  local list = s.hunks[path] or {}
  local n = 0
  for _, h in ipairs(list) do
    if set[h.hash] then
      n = n + 1
    end
  end
  return n, #list
end

--- Marks every hunk of path viewed or unviewed in one step.
local function set_hunks(s, path, on)
  local want = {}
  for _, h in ipairs(s.hunks[path] or {}) do
    want[h.hash] = true
  end
  local list = {}
  for _, v in ipairs(s.marks.viewed_hunks) do
    if not want[v] then
      table.insert(list, v)
    end
  end
  if on then
    for h in pairs(want) do
      table.insert(list, h)
    end
  end
  table.sort(list)
  s.marks.viewed_hunks = list
end

--- A file is viewed exactly when all of its hunks are; keeps the two marks in step.
local function sync_file(s, path)
  local n, total = M.hunk_counts(s, path)
  if total > 0 and n == total then
    s.marks.viewed_files[path] = marker(s, path)
  else
    s.marks.viewed_files[path] = nil
  end
end

--- Repairs marks that disagree, e.g. a file marked whose hunks were not.
function M.reconcile(s)
  for path in pairs(s.marks.viewed_files) do
    if M.file_viewed(s, path) then
      set_hunks(s, path, true)
    end
  end
  for path in pairs(s.hunks or {}) do
    local n, total = M.hunk_counts(s, path)
    if total > 0 and n == total and not M.file_viewed(s, path) then
      s.marks.viewed_files[path] = marker(s, path)
    end
  end
end

--- Marks one file viewed or unviewed, keeping its hunks and any open buffer in step.
function M.set_file(s, path, on)
  s.marks.viewed_files[path] = on and marker(s, path) or nil
  set_hunks(s, path, on)
  store.save(s)
  for buf, st in pairs(inline.state) do
    if st.path == path and vim.api.nvim_buf_is_valid(buf) then
      inline.render(buf)
    end
  end
  require('revision.panel').refresh()
end

function M.toggle_file()
  local s = session()
  local st = inline.state[vim.api.nvim_get_current_buf()]
  if not st then
    return
  end
  M.set_file(s, st.path, not M.file_viewed(s, st.path))
end

function M.toggle_hunk()
  local s = session()
  local buf = vim.api.nvim_get_current_buf()
  local st = inline.state[buf]
  local h = inline.hunk_at(buf, vim.api.nvim_win_get_cursor(0)[1])
  if not h then
    util.notify('no hunk at cursor')
    return
  end
  local list = s.marks.viewed_hunks
  local found
  for i, v in ipairs(list) do
    if v == h.hash then
      found = i
    end
  end
  if found then
    table.remove(list, found)
  else
    table.insert(list, h.hash)
    table.sort(list)
  end
  if st then
    sync_file(s, st.path)
  end
  store.save(s)
  require('revision.panel').refresh()
  inline.render(buf)
  inline.jump(1)
end

return M
