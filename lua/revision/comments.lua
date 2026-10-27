local util = require('revision.util')
local git = require('revision.git')
local inline = require('revision.inline')
local store = require('revision.store')

local M = {}

local function session()
  return require('revision.session').s
end

local function first_line(c)
  return util.nn(c.start_line) or c.line
end

function M.span_text(a, b)
  if a == b then
    return 'L' .. a
  end
  return ('L%d-L%d'):format(a, b)
end

--- Comments are part of the GitHub review: errors unless reviewing a PR on a commit range.
function M.require_enabled(s, need_commit_range)
  if not s.pr then
    error('comments need a GitHub PR', 0)
  end
  if need_commit_range and s.range.worktree then
    error('comments need a commit range, not working changes', 0)
  end
end

function M.count(s, path)
  local n = 0
  for _, c in ipairs(s.pr and s.review.comments or {}) do
    if c.path == path then
      n = n + 1
    end
  end
  return n
end

--- Comments drawn in a buffer: `right` on the buffer's own lines, `left` inside deletion blocks.
function M.for_buffer(s, st)
  local right, left = {}, {}
  for _, c in ipairs(s.pr and s.review.comments or {}) do
    if c.path == st.path then
      if st.kind == 'deleted' then
        if c.side == 'LEFT' and c.commit == s.range.start then
          table.insert(right, c)
        end
      elseif c.side == 'RIGHT' and c.commit == s.range.end_ then
        table.insert(right, c)
      elseif c.side == 'LEFT' and c.commit == s.range.start then
        table.insert(left, c)
      end
    end
  end
  local by_id = function(x, y)
    return x.id < y.id
  end
  table.sort(right, by_id)
  table.sort(left, by_id)
  return right, left
end

--- Splits line into pieces no wider than width display cells, breaking after spaces when possible.
local function wrap(line, width)
  if width < 10 or vim.fn.strdisplaywidth(line) <= width then
    return { line }
  end
  local out, cur = {}, ''
  for word in line:gmatch('%S+%s*') do
    while vim.fn.strdisplaywidth(cur .. word) > width do
      if cur ~= '' then
        table.insert(out, (cur:gsub('%s+$', '')))
        cur = ''
      else
        local n = vim.fn.strchars(word)
        local cut = 1
        while cut < n and vim.fn.strdisplaywidth(vim.fn.strcharpart(word, 0, cut + 1)) <= width do
          cut = cut + 1
        end
        table.insert(out, vim.fn.strcharpart(word, 0, cut))
        word = vim.fn.strcharpart(word, cut)
      end
    end
    cur = cur .. word
  end
  if cur ~= '' or #out == 0 then
    table.insert(out, (cur:gsub('%s+$', '')))
  end
  return out
end

--- Virtual lines for c; body lines wrap to width display cells (the text area of the window).
function M.block(c, old, width)
  local hl = c.private and 'RevisionPrivate' or 'RevisionComment'
  local prefix = '  ┃ '
  local head = prefix .. (c.private and 'private · ' or '') .. M.span_text(first_line(c), c.line)
  if old then
    head = head .. ' (old)'
  end
  local out = { { { head, hl } } }
  local room = (width or vim.o.columns) - vim.fn.strdisplaywidth(prefix)
  for _, l in ipairs(vim.split(c.body, '\n', { plain = true })) do
    for _, piece in ipairs(wrap(l, room)) do
      table.insert(out, { { prefix .. piece, hl } })
    end
  end
  return out
end

--- Hunk of the range diff whose old side holds a LEFT comment's line, or nil.
local function left_hunk(s, c)
  for _, h in ipairs(s.hunks[c.path] or {}) do
    if h.old_count > 0 and c.line >= h.old_start and c.line <= h.old_start + h.old_count - 1 then
      return h
    end
  end
end

--- Row (1-based) where the comment shows in the current range, or nil when outdated.
function M.mapped_row(s, c)
  if c.side == 'RIGHT' then
    return c.commit == s.range.end_ and c.line or nil
  end
  if c.commit ~= s.range.start then
    return nil
  end
  local e = s.file_map[c.path]
  if e and e.status == 'D' then
    return c.line
  end
  local h = left_hunk(s, c)
  if h then
    return math.max(h.new_start, 1)
  end
end

local function pr_diff(s, path)
  if not s.pr_diff[path] then
    local e = s.file_map[path]
    local args = { 'diff', '-U3', '--histogram', '--no-color', '-M', s.merge_base, s.head, '--' }
    if e and e.old_path then
      table.insert(args, e.old_path)
    end
    table.insert(args, path)
    local parsed = git.parse_hunks(git.run(s.root, args))
    s.pr_diff[path] = parsed[path] or {}
  end
  return s.pr_diff[path]
end

--- Whether GitHub accepts a comment on this side and line range of the PR diff.
local function in_diff(s, side, path, a, b)
  for _, h in ipairs(pr_diff(s, path)) do
    local lo, n = h.new_start, h.new_count
    if side == 'LEFT' then
      lo, n = h.old_start, h.old_count
    end
    if n > 0 and a >= lo and b <= lo + n - 1 then
      return true
    end
  end
  return false
end

--- Errors with the refusal message when a public comment could not be posted as drafted.
function M.check_public(s, d)
  if d.side == 'RIGHT' and s.range.end_ ~= s.head then
    error('public comments need the range to end at the PR head; toggle private (<leader>rp) to keep it', 0)
  end
  if d.side == 'LEFT' and s.range.start ~= s.merge_base then
    error('public old-side comments need the range to start at the merge base', 0)
  end
  local a, b = first_line(d), d.line
  if not in_diff(s, d.side, d.path, a, b) then
    error(('L%d-L%d is outside the PR diff of %s; make it private (<leader>rp) to keep it'):format(a, b, d.path), 0)
  end
end

--- Whether GitHub would still accept this comment as drafted; private comments always pass.
function M.postable(s, c)
  if c.private then
    return true
  end
  local anchored = (c.side == 'RIGHT' and c.commit == s.range.end_ and s.range.end_ == s.head)
    or (c.side == 'LEFT' and c.commit == s.range.start and s.range.start == s.merge_base)
  if not anchored then
    return false
  end
  return in_diff(s, c.side, c.path, first_line(c), c.line)
end

--- Hunks of one path between two revisions, cached for the session.
local function align_hunks(s, from, to, path)
  s.align_cache = s.align_cache or {}
  local key = ('%s..%s::%s'):format(from, to, path)
  if not s.align_cache[key] then
    local out = git.run(s.root, {
      'diff',
      '-U0',
      '--histogram',
      '--indent-heuristic',
      '--no-color',
      '-M',
      from,
      to,
      '--',
      path,
    }, { allow_fail = true })
    s.align_cache[key] = out and git.parse_hunks(out)[path] or {}
  end
  return s.align_cache[key]
end

--- Line in the new version paired with old line `line` inside a changed hunk.
local function inside_hunk(h, line)
  local i = line - h.old_start + 1
  for j, k in pairs(inline.pair_lines(h.old_lines, h.new_lines)) do
    if k == i then
      return h.new_start + j - 1
    end
  end
  return math.max(h.new_start, 1)
end

--- Where a line of the old version lives in the new one; deleted lines land on the deletion point.
local function place(hunks, line)
  local delta = 0
  for _, h in ipairs(hunks) do
    local last = h.old_start + h.old_count - 1
    if h.old_count > 0 and line >= h.old_start and line <= last then
      if h.new_count == 0 then
        return math.max(h.new_start, 1)
      end
      return inside_hunk(h, line)
    end
    if h.old_count == 0 then
      if line > h.old_start then
        delta = delta + h.new_count
      end
    elseif line > last then
      delta = delta + h.new_count - h.old_count
    end
  end
  return line + delta
end

--- Moves comments from earlier rounds onto the same content in the current range.
function M.reanchor(s)
  local r = s.range
  if not s.pr or not r or r.worktree then
    return
  end
  local moved = false
  for _, c in ipairs(s.review.comments) do
    local target = c.side == 'RIGHT' and r.end_ or r.start
    local forward = target
      and c.commit
      and c.commit ~= target
      and git.ok(s.root, { 'merge-base', '--is-ancestor', c.commit, target })
      and git.ok(s.root, { 'cat-file', '-e', target .. ':' .. c.path })
    if forward then
      local hunks = align_hunks(s, c.commit, target, c.path)
      local start = util.nn(c.start_line)
      local line = place(hunks, c.line)
      c.line = line
      if start then
        c.start_line = math.min(place(hunks, start), line)
      end
      c.commit = target
      moved = true
    end
  end
  if moved then
    store.touch()
  end
end

--- Refuses comments on a buffer whose text is not the range end's file.
local function check_anchor(s, buf, st)
  if st.kind ~= 'file' then
    return
  end
  local msg = ('file differs from %s; comment anchors would not match'):format(util.short(s.range.end_))
  if vim.bo[buf].modified then
    error(msg, 0)
  end
  local ok, text = pcall(git.show, s.root, s.range.end_, st.path)
  if not ok or not vim.deep_equal(util.lines(text), vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
    error(msg, 0)
  end
end

local function current()
  local s = session()
  M.require_enabled(s, true)
  local buf = vim.api.nvim_get_current_buf()
  local st = inline.state[buf]
  if not st or st.binary then
    error('not a reviewed file', 0)
  end
  return s, buf, st
end

function M.create(visual)
  local s, buf, st = current()
  local a, b
  if visual then
    a, b = vim.fn.line('v'), vim.fn.line('.')
    if a > b then
      a, b = b, a
    end
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
  else
    a = vim.api.nvim_win_get_cursor(0)[1]
    b = a
  end
  check_anchor(s, buf, st)
  require('revision.editor').open({
    path = st.path,
    side = st.kind == 'deleted' and 'LEFT' or 'RIGHT',
    start_line = a ~= b and a or nil,
    line = b,
    private = false,
    body = '',
  })
end

function M.create_left()
  local s, buf, st = current()
  local h = inline.hunk_at(buf, vim.api.nvim_win_get_cursor(0)[1])
  if not h or h.ca == 0 then
    error('no deleted lines at cursor', 0)
  end
  check_anchor(s, buf, st)
  local base = util.lines(inline.base_text(s, s.file_map[st.path]))
  local items = { { a = h.sa, b = h.sa + h.ca - 1, text = ('All %d lines (L%d-L%d)'):format(h.ca, h.sa, h.sa + h.ca - 1) } }
  for n = h.sa, h.sa + h.ca - 1 do
    table.insert(items, { a = n, b = n, text = ('L%d: %s'):format(n, base[n] or '') })
  end
  vim.ui.select(items, {
    prompt = 'Comment on deleted lines',
    format_item = function(i)
      return i.text
    end,
  }, util.guard(function(i)
    if not i then
      return
    end
    require('revision.editor').open({
      path = st.path,
      side = 'LEFT',
      start_line = i.a ~= i.b and i.a or nil,
      line = i.b,
      private = false,
      body = '',
    })
  end))
end

--- Comments under the cursor; LEFT comments in file buffers count at their deletion anchor.
function M.at_cursor()
  local s, buf, st = current()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local right, left = M.for_buffer(s, st)
  local out = {}
  for _, c in ipairs(right) do
    if row >= first_line(c) and row <= c.line then
      table.insert(out, c)
    end
  end
  for _, c in ipairs(left) do
    local h = inline.hunk_at(buf, row)
    if h and h.ca > 0 and c.line >= h.sa and c.line <= h.sa + h.ca - 1 then
      table.insert(out, c)
    end
  end
  return out
end

local function choose(cb)
  local list = M.at_cursor()
  if #list == 0 then
    util.notify('no comment at cursor')
  elseif #list == 1 then
    cb(list[1])
  else
    vim.ui.select(list, {
      prompt = 'Comment',
      format_item = function(c)
        return ('%s %s: %s'):format(c.side, M.span_text(first_line(c), c.line), vim.split(c.body, '\n')[1])
      end,
    }, util.guard(function(c)
      if c then
        cb(c)
      end
    end))
  end
end

--- Stores a draft from the editor: a new comment, or an update to draft.id.
function M.commit(s, d, body)
  local r = s.review
  local now = util.now()
  if d.id then
    for _, c in ipairs(r.comments) do
      if c.id == d.id then
        c.body, c.private, c.updated_at = body, d.private, now
      end
    end
  else
    table.insert(r.comments, {
      id = r.next_id,
      path = d.path,
      side = d.side,
      start_line = d.start_line or vim.NIL,
      line = d.line,
      commit = d.side == 'RIGHT' and s.range.end_ or s.range.start,
      body = body,
      private = d.private,
      created_at = now,
      updated_at = now,
    })
    r.next_id = r.next_id + 1
  end
  store.touch()
  inline.rerender()
end

function M.edit()
  choose(function(c)
    require('revision.editor').open({
      id = c.id,
      path = c.path,
      side = c.side,
      start_line = util.nn(c.start_line),
      line = c.line,
      private = c.private,
      body = c.body,
    })
  end)
end

function M.delete()
  choose(function(c)
    if vim.fn.confirm('Delete comment?', '&Yes\n&No', 2) ~= 1 then
      return
    end
    local s = session()
    for i, x in ipairs(s.review.comments) do
      if x.id == c.id then
        table.remove(s.review.comments, i)
        break
      end
    end
    store.touch()
    inline.rerender()
  end)
end

function M.toggle_private()
  choose(function(c)
    local s = session()
    if c.private then
      M.check_public(s, { path = c.path, side = c.side, start_line = util.nn(c.start_line), line = c.line })
    end
    c.private = not c.private
    c.updated_at = util.now()
    store.touch()
    inline.rerender()
  end)
end

function M.quickfix()
  local s = session()
  M.require_enabled(s, false)
  local list = vim.deepcopy(s.review.comments)
  table.sort(list, function(x, y)
    if x.path ~= y.path then
      return x.path < y.path
    end
    return x.line < y.line
  end)
  local items = {}
  for _, c in ipairs(list) do
    local row = M.mapped_row(s, c)
    local tags = ''
    if c.side == 'LEFT' then
      tags = tags .. '[LEFT] '
    end
    if c.private then
      tags = tags .. '[private] '
    end
    if not M.postable(s, c) then
      tags = tags .. '[outdated] '
    end
    if not row then
      tags = tags .. '[hidden] '
    end
    local item = {
      lnum = row or c.line,
      text = tags .. (vim.split(c.body, '\n', { plain = true })[1] or ''),
    }
    local e = s.file_map[c.path]
    if e and e.status == 'D' then
      item.bufnr = require('revision.deleted').ensure(e)
    else
      item.filename = s.root .. '/' .. c.path
    end
    table.insert(items, item)
  end
  vim.fn.setqflist({}, ' ', { title = 'Revision comments', items = items })
  vim.cmd('copen')
end

return M
