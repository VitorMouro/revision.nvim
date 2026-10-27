local util = require('revision.util')
local git = require('revision.git')
local inline = require('revision.inline')
local store = require('revision.store')

local M = {}

M.KINDS = { 'comment', 'note', 'task' }

local SEVERITY_RANK = { blocking = 1, major = 2, minor = 3, nit = 4, info = 5 }
local KIND_HL = { comment = 'RevisionComment', note = 'RevisionNote', task = 'RevisionTask' }
local KIND_SIGN = { comment = 'C', note = 'N', task = 'T' }

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

--- Agent-reported status of an own task comment, or nil.
local function task_status(c)
  local s = session()
  if c.kind ~= 'task' or not (s and s.task_status) then
    return nil
  end
  return s.task_status[c.id]
end

local function severity_hl(severity)
  return 'RevisionFinding' .. severity:sub(1, 1):upper() .. severity:sub(2)
end

function M.hl(c)
  if c.remote then
    return 'RevisionRemote'
  end
  if c.finding and not c.kind then
    return severity_hl(c.severity)
  end
  if task_status(c) then
    return 'RevisionViewed'
  end
  return KIND_HL[c.kind] or 'RevisionComment'
end

function M.sign(c)
  if c.remote then
    return 'R'
  end
  if c.finding and not c.kind then
    return 'F'
  end
  return KIND_SIGN[c.kind] or 'C'
end

--- Findings from the context that are neither dismissed nor already answered by a comment.
function M.findings(s)
  if not s.ctx then
    return {}
  end
  local hidden = {}
  for _, id in ipairs(s.review.dismissed_findings) do
    hidden[id] = true
  end
  for _, c in ipairs(s.review.comments) do
    local f = util.nn(c.finding)
    if f then
      hidden[f] = true
    end
  end
  local out = {}
  for _, f in ipairs(s.ctx.findings) do
    if not hidden[f.id] then
      table.insert(out, f)
    end
  end
  return out
end

--- Annotation counts of one file: own unposted comments plus remote threads, and visible findings.
function M.counts(s, path)
  local n = 0
  for _, c in ipairs(s.review.comments) do
    if c.path == path and not (s.posted_ids and s.posted_ids[c.id]) then
      n = n + 1
    end
  end
  for _, t in ipairs(s.ctx and s.ctx.threads or {}) do
    if t.path == path then
      n = n + 1
    end
  end
  local f = 0
  for _, fd in ipairs(M.findings(s)) do
    if fd.path == path then
      f = f + 1
    end
  end
  return { comments = n, findings = f }
end

--- Where an item is drawn in st: 'right' on the buffer's own lines, 'left' inside deletion blocks.
local function placement(s, st, c)
  if c.path ~= st.path then
    return nil
  end
  if c.worktree then
    if s.range.worktree and st.kind == 'file' and c.side == 'RIGHT' then
      return 'right'
    end
    return nil
  end
  if st.kind == 'deleted' then
    return (c.side == 'LEFT' and c.commit == s.range.start) and 'right' or nil
  end
  if c.side == 'RIGHT' and c.commit == s.range.end_ then
    return 'right'
  end
  if c.side == 'LEFT' and c.commit == s.range.start then
    return 'left'
  end
end

--- Remote threads first, then findings by severity, then own comments by id.
local function sort_key(c)
  if c.remote then
    return 1, c.order, 0
  end
  if c.finding and not c.kind then
    return 2, SEVERITY_RANK[c.severity] or 9, c.order
  end
  return 3, c.id, 0
end

local function by_key(x, y)
  local a1, a2, a3 = sort_key(x)
  local b1, b2, b3 = sort_key(y)
  if a1 ~= b1 then
    return a1 < b1
  end
  if a2 ~= b2 then
    return a2 < b2
  end
  return a3 < b3
end

--- Annotations drawn in a buffer: own comments, remote threads and visible findings.
function M.for_buffer(s, st)
  local items = {}
  for _, c in ipairs(s.review.comments) do
    if not (s.posted_ids and s.posted_ids[c.id]) then
      table.insert(items, c)
    end
  end
  if s.ctx then
    vim.list_extend(items, s.ctx.threads)
    vim.list_extend(items, M.findings(s))
  end
  local right, left = {}, {}
  for _, c in ipairs(items) do
    local where = placement(s, st, c)
    if where == 'right' then
      table.insert(right, c)
    elseif where == 'left' then
      table.insert(left, c)
    end
  end
  table.sort(right, by_key)
  table.sort(left, by_key)
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

local function header(c, old)
  local span = M.span_text(first_line(c), c.line)
  local tail = old and ' (old)' or ''
  if c.remote then
    return span .. (c.resolved and ' · resolved' or '') .. tail
  end
  if c.finding and not c.kind then
    return ('%s · %s %s%s'):format(c.severity, c.title, span, tail)
  end
  local status = task_status(c)
  if status then
    return ('task · %s · %s %s%s'):format(status.status, util.nn(status.note) or '', span, tail)
  end
  return ('%s · %s%s%s'):format(c.kind, util.nn(c.reply_to) and 'reply · ' or '', span, tail)
end

--- Virtual lines for an annotation; body lines wrap to width display cells.
function M.block(c, old, width)
  local hl = M.hl(c)
  local prefix = '  ┃ '
  local out = { { { prefix .. header(c, old), hl } } }
  local room = (width or vim.o.columns) - vim.fn.strdisplaywidth(prefix)
  local function body(text)
    for _, l in ipairs(vim.split(text or '', '\n', { plain = true })) do
      for _, piece in ipairs(wrap(l, room)) do
        table.insert(out, { { prefix .. piece, hl } })
      end
    end
  end
  if c.remote then
    for _, rc in ipairs(c.comments or {}) do
      table.insert(out, { { prefix .. '@' .. tostring(util.nn(rc.author) or '?'), hl } })
      body(util.nn(rc.body))
    end
  else
    body(util.nn(c.body))
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

--- Row (1-based) where the comment shows in the current range, or nil when it cannot be shown.
function M.mapped_row(s, c)
  if c.worktree then
    return s.range.worktree and c.line or nil
  end
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

local function review_diff(s, path)
  if not s.review_diff[path] then
    local e = s.file_map[path]
    local args = { 'diff', '-U3', '--histogram', '--no-color', '-M', s.merge_base, s.head, '--' }
    if e and e.old_path then
      table.insert(args, e.old_path)
    end
    table.insert(args, path)
    local parsed = git.parse_hunks(git.run(s.root, args))
    s.review_diff[path] = parsed[path] or {}
  end
  return s.review_diff[path]
end

--- Whether a side and line range lies inside the diff a forge would show for this review.
local function in_review_diff(s, side, path, a, b)
  if not s.merge_base then
    return true
  end
  for _, h in ipairs(review_diff(s, path)) do
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

--- Whether a comment no longer matches the review diff a forge would accept it on.
function M.outdated(s, c)
  if c.kind ~= 'comment' then
    return false
  end
  local anchored = (c.side == 'RIGHT' and c.commit == s.range.end_ and s.range.end_ == s.head)
    or (c.side == 'LEFT' and c.commit == s.range.start and s.range.start == s.merge_base)
  if not anchored then
    return true
  end
  return not in_review_diff(s, c.side, c.path, first_line(c), c.line)
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

--- Moves one annotation onto the same content at target; true when it moved.
local function move(s, c, target)
  local commit = util.nn(c.commit)
  local forward = target
    and commit
    and commit ~= target
    and git.ok(s.root, { 'merge-base', '--is-ancestor', commit, target })
    and git.ok(s.root, { 'cat-file', '-e', target .. ':' .. c.path })
  if not forward then
    return false
  end
  local hunks = align_hunks(s, commit, target, c.path)
  local start = util.nn(c.start_line)
  local line = place(hunks, c.line)
  c.line = line
  if start then
    c.start_line = math.min(place(hunks, start), line)
  end
  c.commit = target
  return true
end

--- Moves annotations from earlier rounds onto the same content in the current range.
function M.reanchor(s)
  local r = s.range
  if not r or r.worktree then
    return
  end
  local moved = false
  for _, c in ipairs(s.review.comments) do
    if not c.worktree then
      moved = move(s, c, c.side == 'RIGHT' and r.end_ or r.start) or moved
    end
  end
  if moved then
    store.touch()
  end
  if s.ctx then
    for _, t in ipairs(s.ctx.threads) do
      move(s, t, t.side == 'RIGHT' and r.end_ or r.start)
    end
    for _, f in ipairs(s.ctx.findings) do
      move(s, f, f.side == 'RIGHT' and r.end_ or r.start)
    end
  end
end

--- Refuses comments on a buffer whose text is not the one the anchor refers to.
local function check_anchor(s, buf, st)
  if st.kind ~= 'file' then
    return
  end
  if s.range.worktree then
    if vim.bo[buf].modified then
      error('save the file first; comment anchors would not match', 0)
    end
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

--- The session, the current buffer and its review state; errors outside a reviewed file.
function M.current()
  local s = session()
  local buf = vim.api.nvim_get_current_buf()
  local st = inline.state[buf]
  if not st or st.binary then
    error('not a reviewed file', 0)
  end
  return s, buf, st
end

--- The kind a new draft starts at: working changes cannot carry comments for the remote.
local function default_kind(s)
  return s.range.worktree and 'task' or 'comment'
end

--- The next kind in the cycle, skipping 'comment' when it cannot be posted.
function M.next_kind(kind, skip_comment)
  local i = 1
  for n, k in ipairs(M.KINDS) do
    if k == kind then
      i = n
    end
  end
  repeat
    i = i % #M.KINDS + 1
  until not (skip_comment and M.KINDS[i] == 'comment')
  return M.KINDS[i]
end

function M.create(visual)
  local s, buf, st = M.current()
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
    kind = default_kind(s),
    body = '',
  })
end

function M.create_left()
  local s, buf, st = M.current()
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
      kind = default_kind(s),
      body = '',
    })
  end))
end

--- Annotations under the cursor; LEFT ones in file buffers count at their deletion anchor.
function M.at_cursor(which)
  local s, buf, st = M.current()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local right, left = M.for_buffer(s, st)
  local function wanted(c)
    if which == 'remote' then
      return c.remote
    end
    if which == 'finding' then
      return c.finding and not c.kind
    end
    return not c.remote and c.kind ~= nil
  end
  local out = {}
  for _, c in ipairs(right) do
    if wanted(c) and row >= first_line(c) and row <= c.line then
      table.insert(out, c)
    end
  end
  for _, c in ipairs(left) do
    local h = inline.hunk_at(buf, row)
    if wanted(c) and h and h.ca > 0 and c.line >= h.sa and c.line <= h.sa + h.ca - 1 then
      table.insert(out, c)
    end
  end
  return out
end

local function pick(which, empty, prompt, format, cb)
  local list = M.at_cursor(which)
  if #list == 0 then
    util.notify(empty)
  elseif #list == 1 then
    cb(list[1])
  else
    vim.ui.select(list, { prompt = prompt, format_item = format }, util.guard(function(x)
      if x then
        cb(x)
      end
    end))
  end
end

local function choose(cb)
  pick('own', 'no comment at cursor', 'Comment', function(c)
    return ('%s %s: %s'):format(c.side, M.span_text(first_line(c), c.line), vim.split(c.body, '\n')[1])
  end, cb)
end

--- Stores a draft from the editor: a new comment, or an update to draft.id.
function M.commit(s, d, body)
  local r = s.review
  local now = util.now()
  if d.id then
    for _, c in ipairs(r.comments) do
      if c.id == d.id then
        c.body, c.kind, c.updated_at = body, d.kind, now
      end
    end
  else
    local worktree = s.range.worktree or false
    table.insert(r.comments, {
      id = r.next_id,
      path = d.path,
      side = d.side,
      start_line = d.start_line or vim.NIL,
      line = d.line,
      commit = worktree and vim.NIL or (d.commit or (d.side == 'RIGHT' and s.range.end_ or s.range.start)),
      worktree = worktree,
      body = body,
      kind = d.kind,
      reply_to = d.reply_to or vim.NIL,
      finding = d.finding or vim.NIL,
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
      commit = util.nn(c.commit),
      kind = c.kind,
      reply_to = util.nn(c.reply_to),
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

function M.cycle_kind()
  choose(function(c)
    c.kind = M.next_kind(c.kind, c.worktree == true)
    c.updated_at = util.now()
    store.touch()
    inline.rerender()
  end)
end

function M.reply()
  local s, buf, st = M.current()
  check_anchor(s, buf, st)
  pick('remote', 'no remote thread at cursor', 'Thread', function(t)
    local rc = (t.comments or {})[1] or {}
    return ('%s @%s: %s'):format(
      M.span_text(first_line(t), t.line),
      tostring(util.nn(rc.author) or '?'),
      vim.split(util.nn(rc.body) or '', '\n')[1]
    )
  end, function(t)
    require('revision.editor').open({
      path = t.path,
      side = t.side,
      start_line = util.nn(t.start_line),
      line = t.line,
      commit = util.nn(t.commit),
      reply_to = t.id,
      kind = 'comment',
      body = '',
    })
  end)
end

local function format_finding(f)
  return ('%s %s · %s'):format(M.span_text(first_line(f), f.line), f.severity, f.title)
end

function M.accept_finding()
  local s, buf, st = M.current()
  check_anchor(s, buf, st)
  pick('finding', 'no finding at cursor', 'Finding', format_finding, function(f)
    local body = util.nn(f.body) or ''
    require('revision.editor').open({
      path = f.path,
      side = f.side,
      start_line = util.nn(f.start_line),
      line = f.line,
      commit = util.nn(f.commit),
      finding = f.id,
      kind = s.range.worktree and 'task' or 'comment',
      body = f.title .. (body ~= '' and ('\n\n' .. body) or ''),
    })
  end)
end

function M.dismiss_finding()
  local s = session()
  pick('finding', 'no finding at cursor', 'Finding', format_finding, function(f)
    for _, id in ipairs(s.review.dismissed_findings) do
      if id == f.id then
        return
      end
    end
    table.insert(s.review.dismissed_findings, f.id)
    store.touch()
    inline.rerender()
  end)
end

local function qf_item(s, c, row, text)
  local item = { lnum = row or c.line, text = text }
  local e = s.file_map[c.path]
  if e and e.status == 'D' then
    item.bufnr = require('revision.deleted').ensure(e)
  else
    item.filename = s.root .. '/' .. c.path
  end
  return item
end

local function by_location(x, y)
  if x.path ~= y.path then
    return x.path < y.path
  end
  return x.line < y.line
end

function M.quickfix()
  local s = session()
  local list = vim.deepcopy(s.review.comments)
  table.sort(list, by_location)
  local items = {}
  for _, c in ipairs(list) do
    local row = M.mapped_row(s, c)
    local tags = ''
    if c.side == 'LEFT' then
      tags = tags .. '[LEFT] '
    end
    if c.kind ~= 'comment' then
      tags = tags .. '[' .. c.kind .. '] '
    end
    local status = task_status(c)
    if status then
      tags = tags .. '[' .. status.status .. '] '
    end
    if s.posted_ids and s.posted_ids[c.id] then
      tags = tags .. '[posted] '
    end
    if M.outdated(s, c) then
      tags = tags .. '[outdated] '
    end
    if not row then
      tags = tags .. '[hidden] '
    end
    table.insert(items, qf_item(s, c, row, tags .. (vim.split(c.body, '\n', { plain = true })[1] or '')))
  end
  local findings = M.findings(s)
  table.sort(findings, by_location)
  for _, f in ipairs(findings) do
    local row = M.mapped_row(s, f)
    local tags = row and '' or '[hidden] '
    table.insert(items, qf_item(s, f, row, ('%s[finding:%s] %s'):format(tags, f.severity, f.title)))
  end
  vim.fn.setqflist({}, ' ', { title = 'Revision annotations', items = items })
  vim.cmd('copen')
end

return M
