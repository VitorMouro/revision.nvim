local util = require('revision.util')
local git = require('revision.git')
local store = require('revision.store')

local M = {}

local NAME = 'revision://commits'

--- Shas by row of the last render.
M.shas = {}

local function session()
  return require('revision.session').s
end

function M.win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) == NAME then
      return w
    end
  end
end

--- Shas inside the current commit range; empty while reviewing working changes.
local function in_range(s)
  local r = s.range
  if not r or r.worktree or not r.end_ then
    return {}
  end
  local spec = r.start == git.EMPTY_TREE and r.end_ or (r.start .. '..' .. r.end_)
  local set = {}
  for _, sha in ipairs(util.lines(git.run(s.root, { 'rev-list', spec }, { allow_fail = true }) or '')) do
    set[sha] = true
  end
  return set
end

local function reviewed_set(s)
  local set = {}
  for _, sha in ipairs(s.review.reviewed_commits) do
    set[sha] = true
  end
  return set
end

function M.refresh()
  local win = M.win()
  local s = session()
  if not win or not s then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local inside, reviewed = in_range(s), reviewed_set(s)
  local lines, shas = { 'range: ' .. require('revision.range').describe(s.range) }, {}
  for _, c in ipairs(require('revision.range').commits(s)) do
    table.insert(
      lines,
      ('%s %s %s %s  %s %s'):format(
        inside[c.sha] and '▶' or ' ',
        reviewed[c.sha] and '✓' or ' ',
        c.sha:sub(1, 7),
        c.subject,
        c.author,
        c.date
      )
    )
    shas[#lines] = c.sha
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  M.shas = shas
end

local function sha_at()
  local sha = M.shas[vim.api.nvim_win_get_cursor(0)[1]]
  if not sha then
    error('no commit at cursor', 0)
  end
  return sha
end

local function commit_range(s)
  if not s.range or s.range.worktree or not s.range.end_ then
    error('pick a commit range first', 0)
  end
  return s.range
end

local function keys(buf)
  local range = require('revision.range')
  local map = function(lhs, fn)
    vim.keymap.set('n', lhs, util.guard(function()
      fn(session(), range)
      M.refresh()
    end), { buffer = buf, nowait = true, desc = 'revision: commits' })
  end
  map('a', function(s, r)
    local base = s.merge_base or s.upstream_base
    if not base then
      util.notify('no base to compare against')
      return
    end
    r.apply(base, s.head, 'all')
  end)
  map('<CR>', function(s, r)
    local sha = sha_at()
    r.apply(r.parent(s, sha), sha, 'commit')
  end)
  map('s', function(s, r)
    local cur = commit_range(s)
    local sha = sha_at()
    if not git.ok(s.root, { 'merge-base', '--is-ancestor', sha, cur.end_ }) then
      error('start must be at or before the range end', 0)
    end
    r.apply(r.parent(s, sha), cur.end_, 'custom')
  end)
  map('e', function(s, r)
    local cur = commit_range(s)
    local sha = sha_at()
    if cur.start ~= git.EMPTY_TREE and not git.ok(s.root, { 'merge-base', '--is-ancestor', cur.start, sha }) then
      error('end must be after the range start', 0)
    end
    r.apply(cur.start, sha, 'custom')
  end)
  map('u', function(s, r)
    for _, item in ipairs(r.items(s)) do
      if item.kind == 'unreviewed' then
        r.apply(item.start, s.head, 'unreviewed')
        return
      end
    end
    util.notify('all commits reviewed')
  end)
  map('l', function(s, r)
    local last = r.last_reviewed(s)
    if not last then
      util.notify('no earlier review round')
      return
    end
    r.apply(last, s.head, 'since last review')
  end)
  map('m', function(s)
    local sha = sha_at()
    local list = s.review.reviewed_commits
    for i, v in ipairs(list) do
      if v == sha then
        table.remove(list, i)
        store.touch()
        return
      end
    end
    table.insert(list, sha)
    table.sort(list)
    store.touch()
  end)
  map('q', function()
    M.close()
  end)
end

local function ensure_buf()
  local buf = vim.fn.bufnr(NAME)
  if buf ~= -1 then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, NAME)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'revision-commits'
  vim.bo[buf].modifiable = false
  keys(buf)
  return buf
end

function M.close()
  local win = M.win()
  if win and #vim.api.nvim_list_wins() > 1 then
    vim.api.nvim_win_close(win, true)
  end
end

function M.toggle()
  if M.win() then
    M.close()
    return
  end
  local s = session()
  vim.cmd('botright split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, ensure_buf())
  vim.api.nvim_win_set_height(win, math.min(#require('revision.range').commits(s) + 2, 15))
  local wo = vim.wo[win][0]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.wrap = false
  M.refresh()
end

return M
