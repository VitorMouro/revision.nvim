local util = require('revision.util')
local git = require('revision.git')

local M = {}

M.ns = vim.api.nvim_create_namespace('revision_inline')
M.ns_words = vim.api.nvim_create_namespace('revision_words')
M.ns_comments = vim.api.nvim_create_namespace('revision_comments')

--- Per-buffer state: { path, kind = 'file'|'deleted', hunks, near, timer }.
M.state = {}

local function session()
  return require('revision.session').s
end

function M.relpath(s, buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or name:find('^%a+://') then
    return nil
  end
  local prefix = s.root .. '/'
  if name:sub(1, #prefix) ~= prefix then
    name = vim.uv.fs_realpath(name) or name
  end
  if name:sub(1, #prefix) == prefix then
    return name:sub(#prefix + 1)
  end
end

--- Loaded file buffers inside the worktree.
function M.root_bufs()
  local s = session()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and M.relpath(s, buf) then
      table.insert(out, buf)
    end
  end
  return out
end

function M.base_text(s, entry)
  if entry.status == 'A' then
    return ''
  end
  local p = entry.old_path or entry.path
  local key = s.range.start .. ':' .. p
  s.base_cache = s.base_cache or {}
  if not s.base_cache[key] then
    s.base_cache[key] = git.show(s.root, s.range.start, p)
  end
  return s.base_cache[key]
end

local function viewed_set(s)
  local set = {}
  for _, h in ipairs(s.review.viewed_hunks) do
    set[h] = true
  end
  return set
end

--- Splits s into word, whitespace, UTF-8 char or byte tokens; returns tokens and 0-based start offsets.
local function tokenize(s)
  local toks, offs = {}, {}
  local i = 1
  while i <= #s do
    local t = s:match('^[%w_]+', i) or s:match('^%s+', i) or s:match('^[\192-\247][\128-\191]*', i) or s:sub(i, i)
    table.insert(toks, t)
    table.insert(offs, i - 1)
    i = i + #t
  end
  return toks, offs
end

--- Byte spans { {from, to}... } (0-based, end-exclusive) of changed tokens in a and b.
local function word_spans(a, b)
  local ta, oa = tokenize(a)
  local tb, ob = tokenize(b)
  -- An empty side still diffs as one blank line, which would index past its tokens.
  if #ta == 0 or #tb == 0 then
    return #a > 0 and { { 0, #a } } or {}, #b > 0 and { { 0, #b } } or {}
  end
  local d = vim.text.diff(table.concat(ta, '\n') .. '\n', table.concat(tb, '\n') .. '\n', { result_type = 'indices' })
  local sa, sb = {}, {}
  for _, h in ipairs(d) do
    if h[2] > 0 then
      table.insert(sa, { oa[h[1]], oa[h[1] + h[2] - 1] + #ta[h[1] + h[2] - 1] })
    end
    if h[4] > 0 then
      table.insert(sb, { ob[h[3]], ob[h[3] + h[4] - 1] + #tb[h[3] + h[4] - 1] })
    end
  end
  return sa, sb
end

local function changed_bytes(spans)
  local n = 0
  for _, sp in ipairs(spans) do
    n = n + sp[2] - sp[1]
  end
  return n
end

--- Maps new line index -> old line index for word diff. Equal counts pair by position;
--- otherwise each new line takes the most similar later old line when at least half matches.
function M.pair_lines(old, new)
  local out = {}
  if #old == #new then
    for i = 1, #old do
      out[i] = i
    end
    return out
  end
  if #old * #new > 400 then
    return out
  end
  local from = 1
  for j, b in ipairs(new) do
    b = vim.trim(b)
    local best, best_score = nil, 0.5
    for i = from, #old do
      local a = vim.trim(old[i])
      if #a + #b > 0 and #a <= 500 and #b <= 500 then
        local sa, sb = word_spans(a, b)
        local score = 1 - (changed_bytes(sa) + changed_bytes(sb)) / (#a + #b)
        if score > best_score then
          best, best_score = i, score
        end
      end
    end
    if best then
      out[j], from = best, best + 1
    end
  end
  return out
end

local function expand(text, ts)
  return (text:gsub('\t', string.rep(' ', ts)))
end

--- One virtual line for a deleted base line, with changed spans in RevisionText.
local function deleted_virt_line(text, spans, ts)
  local chunks, pos, width = {}, 0, 0
  local function add(t, hl)
    if t ~= '' then
      t = expand(t, ts)
      table.insert(chunks, { t, hl })
      width = width + vim.fn.strdisplaywidth(t)
    end
  end
  for _, sp in ipairs(spans or {}) do
    add(text:sub(pos + 1, sp[1]), 'RevisionDelete')
    add(text:sub(sp[1] + 1, sp[2]), 'RevisionText')
    pos = sp[2]
  end
  add(text:sub(pos + 1), 'RevisionDelete')
  local pad = vim.o.columns - width
  if pad > 0 then
    table.insert(chunks, { string.rep(' ', pad), 'RevisionDelete' })
  end
  return chunks
end

--- Computes buffer hunks against the range start, with the same xdiff options as `git diff`.
local function compute(s, buf, st)
  local entry = s.file_map[st.path]
  local base = M.base_text(s, entry)
  local base_lines = util.lines(base)
  local cur_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cur = table.concat(cur_lines, '\n') .. '\n'
  local idx = vim.text.diff(base, cur, { result_type = 'indices', algorithm = 'histogram', indent_heuristic = true })
  local hunks = {}
  for _, h in ipairs(idx) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local old = vim.list_slice(base_lines, sa, sa + ca - 1)
    local new = vim.list_slice(cur_lines, sb, sb + cb - 1)
    local anchor, above
    if cb > 0 then
      anchor, above = sb - 1, true
    elseif sb == 0 then
      anchor, above = 0, true
    else
      anchor, above = sb - 1, false
    end
    table.insert(hunks, {
      sa = sa,
      ca = ca,
      sb = sb,
      cb = cb,
      old_lines = old,
      new_lines = new,
      anchor = anchor,
      above = above,
      hash = git.hunk_hash(st.path, old, new),
    })
  end
  return hunks
end

--- Hunks of a deleted file: everything is old-side, anchored on its own rows.
local function deleted_hunks(s, st)
  local out = {}
  for _, h in ipairs(s.hunks[st.path] or {}) do
    table.insert(out, {
      sa = h.old_start,
      ca = h.old_count,
      sb = 0,
      cb = 0,
      anchor = h.old_start - 1,
      hash = h.hash,
    })
  end
  return out
end

local function mark_near(near, from, to, ctx)
  for l = from - ctx, to + ctx do
    near[l] = true
  end
end

local function winbar(s, st)
  local r = s.range
  local parts = { ' revision', require('revision.range').describe(r) }
  if st.kind == 'deleted' then
    table.insert(parts, 'deleted')
  end
  table.insert(parts, st.path)
  local bar = table.concat(parts, ' · '):gsub('%%', '%%%%')
  if require('revision.viewed').file_viewed(s, st.path) then
    bar = bar .. ' · %#RevisionViewed#✓ viewed%*'
  end
  return bar
end

local wo_keys = { 'foldmethod', 'foldexpr', 'foldlevel', 'foldenable', 'signcolumn', 'winbar' }

--- Remembers win's original options the first time the plugin touches it.
function M.save_win(s, win)
  if not s.saved_wo[win] then
    local saved = {}
    for _, k in ipairs(wo_keys) do
      saved[k] = vim.wo[win][k]
    end
    s.saved_wo[win] = saved
  end
end

function M.update_winbar(buf)
  local s, st = session(), M.state[buf]
  if not (s and st) then
    return
  end
  local bar = winbar(s, st)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    M.save_win(s, win)
    vim.wo[win][0].winbar = bar
  end
end

--- Text-area width of the narrowest window showing buf, for wrapping comment blocks.
local function text_width(buf)
  local w
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    w = math.min(w or math.huge, info.width - info.textoff)
  end
  return w or vim.o.columns
end

function M.render(buf)
  local s, st = session(), M.state[buf]
  if not (s and st and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local comments = require('revision.comments')
  local cfg = require('revision.config').opts
  local ts = vim.bo[buf].tabstop
  local deleted = st.kind == 'deleted'
  st.hunks = deleted and deleted_hunks(s, st) or compute(s, buf, st)
  vim.b[buf].revision_hunks = vim.tbl_map(function(h)
    return { sa = h.sa, ca = h.ca, sb = h.sb, cb = h.cb, anchor = h.anchor, hash = h.hash }
  end, st.hunks)

  for _, ns in ipairs({ M.ns, M.ns_words, M.ns_comments }) do
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
  local viewed = viewed_set(s)
  local near = {}
  local ctx = cfg.context_lines
  local right, left = comments.for_buffer(s, st)
  local nlines = vim.api.nvim_buf_line_count(buf)
  local width = text_width(buf)

  if deleted then
    vim.api.nvim_buf_set_extmark(buf, M.ns, 0, 0, {
      end_row = nlines,
      end_col = 0,
      hl_group = 'RevisionDelete',
      hl_eol = true,
      strict = false,
      priority = 5,
    })
  end

  local left_by_line, note_rows = {}, {}
  for _, c in ipairs(left) do
    left_by_line[c.line] = left_by_line[c.line] or {}
    table.insert(left_by_line[c.line], c)
  end

  for _, h in ipairs(st.hunks) do
    local is_viewed = viewed[h.hash]
    if deleted then
      if is_viewed then
        for row = h.sa - 1, h.sa + h.ca - 2 do
          vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, { sign_text = '✓', sign_hl_group = 'RevisionViewed', priority = 5 })
        end
      end
    else
      local spans_old, spans_new = {}, {}
      if h.ca > 0 and h.cb > 0 then
        for j, i in pairs(M.pair_lines(h.old_lines, h.new_lines)) do
          local a, b = h.old_lines[i], h.new_lines[j]
          if #a <= 500 and #b <= 500 then
            spans_old[i], spans_new[j] = word_spans(a, b)
          end
        end
      end
      if h.cb > 0 then
        local group = h.ca == 0 and 'RevisionAdd' or 'RevisionChange'
        local sign = is_viewed and '✓' or (h.ca == 0 and '+' or '~')
        local sign_hl = is_viewed and 'RevisionViewed' or group
        for i = 0, h.cb - 1 do
          local row = h.sb - 1 + i
          vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
            -- Range highlight, not line_hl_group: that paints over word highlights and reads as a sign.
            end_row = row + 1,
            end_col = 0,
            hl_group = group,
            hl_eol = true,
            strict = false,
            sign_text = sign,
            sign_hl_group = sign_hl,
            priority = 5,
          })
          for _, sp in ipairs(spans_new[i + 1] or {}) do
            vim.api.nvim_buf_set_extmark(buf, M.ns_words, row, sp[1], { end_col = sp[2], hl_group = 'RevisionTextAdd' })
          end
        end
        mark_near(near, h.sb, h.sb + h.cb - 1, ctx)
      end
      if h.ca > 0 then
        local vl = {}
        for i, text in ipairs(h.old_lines) do
          table.insert(vl, deleted_virt_line(text, spans_old[i], ts))
          for _, c in ipairs(left_by_line[h.sa + i - 1] or {}) do
            note_rows[h.anchor + 1] = true
            if s.show_comments then
              vim.list_extend(vl, comments.block(c, true, width))
            end
          end
        end
        vim.api.nvim_buf_set_extmark(buf, M.ns, h.anchor, 0, {
          virt_lines = vl,
          virt_lines_above = h.above,
          virt_lines_overflow = 'scroll',
        })
        if h.cb == 0 then
          vim.api.nvim_buf_set_extmark(buf, M.ns, h.anchor, 0, {
            sign_text = is_viewed and '✓' or '_',
            sign_hl_group = is_viewed and 'RevisionViewed' or 'RevisionDelete',
            priority = 5,
          })
        end
        mark_near(near, h.anchor + 1, h.anchor + 1, ctx)
      end
    end
  end

  -- One extmark per row: separate virt_lines extmarks on a row draw newest first.
  local blocks, rows = {}, {}
  for _, c in ipairs(right) do
    local first = util.nn(c.start_line) or c.line
    if c.line <= nlines then
      local hl = comments.hl(c)
      for l = first, c.line do
        vim.api.nvim_buf_set_extmark(buf, M.ns_comments, l - 1, 0, {
          sign_text = comments.sign(c),
          sign_hl_group = hl,
          priority = 10,
        })
      end
      note_rows[first] = true
      if s.show_comments then
        if not blocks[c.line] then
          blocks[c.line] = {}
          table.insert(rows, c.line)
        end
        vim.list_extend(blocks[c.line], comments.block(c, false, width))
      end
      mark_near(near, first, c.line, 0)
    end
  end
  for _, line in ipairs(rows) do
    vim.api.nvim_buf_set_extmark(buf, M.ns_comments, line - 1, 0, { virt_lines = blocks[line] })
  end
  st.note_rows = vim.tbl_keys(note_rows)
  table.sort(st.note_rows)

  st.near = near
  M.update_winbar(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    M.show_top_filler(win, st)
  end
end

--- Virtual lines above line 1 are only drawn as filler (topfill), which views leave partly hidden.
function M.show_top_filler(win, st)
  local first = st.hunks and st.hunks[1]
  if first and first.anchor == 0 and first.above and first.ca > 0 and vim.fn.line('w0', win) == 1 then
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topfill = vim.o.lines })
    end)
  end
end

function M.schedule_render(buf)
  local st = M.state[buf]
  if not st then
    return
  end
  if not st.timer then
    st.timer = vim.uv.new_timer()
  end
  st.timer:stop()
  st.timer:start(200, 0, vim.schedule_wrap(function()
    M.render(buf)
  end))
end

function M.foldexpr(lnum)
  local st = M.state[vim.api.nvim_get_current_buf()]
  if not st or not st.near then
    return 0
  end
  return st.near[lnum] and 0 or 1
end

function M.setup_win(win, buf)
  local s, st = session(), M.state[buf]
  if not (s and st) then
    return
  end
  M.save_win(s, win)
  local wo = vim.wo[win][0]
  if st.binary then
    wo.winbar = 'binary file'
    return
  end
  wo.signcolumn = 'yes:2'
  local entry = s.file_map[st.path]
  wo.foldexpr = "v:lua.require'revision.inline'.foldexpr(v:lnum)"
  wo.foldmethod = 'expr'
  wo.foldlevel = 0
  wo.foldenable = not (entry and (entry.status == 'A' or entry.status == 'D'))
  M.update_winbar(buf)
  M.show_top_filler(win, st)
end

function M.restore_wins(s)
  for win, saved in pairs(s.saved_wo) do
    if vim.api.nvim_win_is_valid(win) then
      for k, v in pairs(saved) do
        vim.wo[win][0][k] = v
      end
    end
  end
  s.saved_wo = {}
end

local function clear(buf)
  for _, ns in ipairs({ M.ns, M.ns_words, M.ns_comments }) do
    pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
  end
end

--- Removes all decorations, keys and window options from buf.
function M.detach(buf)
  local st = M.state[buf]
  if not st then
    return
  end
  if st.timer then
    st.timer:stop()
    st.timer:close()
  end
  M.state[buf] = nil
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  clear(buf)
  pcall(vim.api.nvim_del_augroup_by_name, 'revision_buf_' .. buf)
  require('revision.keys').clear(buf)
  vim.b[buf].revision_hunks = nil
  if st.kind == 'file' then
    vim.bo[buf].modifiable = true
  end
  local s = session()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local saved = s and s.saved_wo[win]
    if saved then
      for k, v in pairs(saved) do
        vim.wo[win][0][k] = v
      end
    end
  end
end

--- Attaches buf if it is a reviewed file in the current range, detaches it otherwise.
function M.attach(buf)
  local s = session()
  if not s or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  local path = M.relpath(s, buf)
  local entry = path and s.file_map[path]
  if not entry or entry.status == 'D' then
    M.detach(buf)
    return
  end
  local st = M.state[buf]
  if st and st.path ~= path then
    M.detach(buf)
    st = nil
  end
  if not st then
    st = { path = path, kind = 'file' }
    M.state[buf] = st
    if not entry.binary then
      local group = vim.api.nvim_create_augroup('revision_buf_' .. buf, {})
      vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
        group = group,
        buffer = buf,
        callback = function()
          M.schedule_render(buf)
        end,
      })
      vim.api.nvim_create_autocmd('BufWritePost', {
        group = group,
        buffer = buf,
        callback = function()
          M.render(buf)
        end,
      })
      vim.api.nvim_create_autocmd('BufWipeout', {
        group = group,
        buffer = buf,
        callback = function()
          M.detach(buf)
        end,
      })
      require('revision.keys').buffer(buf)
    end
  end
  st.binary = entry.binary
  if entry.binary then
    clear(buf)
    return
  end
  vim.bo[buf].modifiable = s.range.worktree or vim.b[buf].revision_editable or false
  M.render(buf)
end

--- Re-attaches every worktree buffer and deleted-file buffer after a range or state change.
function M.refresh_all()
  for _, buf in ipairs(M.root_bufs()) do
    M.attach(buf)
  end
  require('revision.deleted').refresh_all()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if M.state[buf] then
      M.setup_win(win, buf)
      if vim.wo[win].foldmethod == 'expr' then
        vim.api.nvim_win_call(win, function()
          vim.cmd('silent! normal! zx')
        end)
      end
    end
  end
  require('revision.panel').refresh()
end

--- Re-renders attached buffers without re-attaching (comment/viewed changes).
function M.rerender()
  for buf in pairs(M.state) do
    if vim.api.nvim_buf_is_valid(buf) and not M.state[buf].binary then
      M.render(buf)
    end
  end
  require('revision.panel').refresh()
end

--- Hunk under the cursor row (1-based): new-side span or deletion anchor row.
function M.hunk_at(buf, row)
  local st = M.state[buf]
  if not st or not st.hunks then
    return nil
  end
  for _, h in ipairs(st.hunks) do
    if st.kind == 'deleted' then
      if row >= h.sa and row <= h.sa + h.ca - 1 then
        return h
      end
    elseif h.cb > 0 and row >= h.sb and row <= h.sb + h.cb - 1 then
      return h
    elseif h.ca > 0 and h.anchor + 1 == row then
      return h
    end
  end
end

function M.jump(dir)
  local buf = vim.api.nvim_get_current_buf()
  local st = M.state[buf]
  if not st or not st.hunks then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local target
  for _, h in ipairs(st.hunks) do
    if dir > 0 and h.anchor > row and (not target or h.anchor < target) then
      target = h.anchor
    elseif dir < 0 and h.anchor < row and (not target or h.anchor > target) then
      target = h.anchor
    end
  end
  if target then
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
    vim.cmd('normal! zv')
  end
end

--- Moves to the next or previous annotation row; stops at the ends.
function M.jump_note(dir)
  local st = M.state[vim.api.nvim_get_current_buf()]
  if not st or not st.note_rows then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local target
  for _, r in ipairs(st.note_rows) do
    if dir > 0 and r > row and (not target or r < target) then
      target = r
    elseif dir < 0 and r < row and (not target or r > target) then
      target = r
    end
  end
  if not target then
    util.notify(dir > 0 and 'last annotation' or 'first annotation')
    return
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd('normal! zv')
end

function M.toggle_editable()
  local buf = vim.api.nvim_get_current_buf()
  local st = M.state[buf]
  if not st or st.kind ~= 'file' then
    return
  end
  if session().range.worktree then
    util.notify('working changes are always editable')
    return
  end
  if vim.b[buf].revision_editable then
    if vim.bo[buf].modified then
      error('write or undo your changes first', 0)
    end
    vim.b[buf].revision_editable = false
    vim.bo[buf].modifiable = false
    util.notify('read-only')
  else
    vim.b[buf].revision_editable = true
    vim.bo[buf].modifiable = true
    util.notify('editable')
  end
end

return M
