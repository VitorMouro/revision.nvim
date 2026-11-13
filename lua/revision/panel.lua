local util = require('revision.util')
local git = require('revision.git')
local view = require('revision.view')
local inline = require('revision.inline')

local M = {}

local NAME = 'revision://files'
local ns = vim.api.nvim_create_namespace('revision_panel')
local ns_current = vim.api.nvim_create_namespace('revision_panel_current')

--- Per-render row map: { [row] = { kind = 'dir'|'file', path, e?, name_col, name_end } }.
M.rows = {}
--- Show every file of the repo, not only the changed ones.
M.all = false

local levels = {}
--- Directory fold state by path: true closed, false open, nil for the default.
local closed = {}
--- Window M.rows and the folds were last rendered into, and the root they are relative to.
local rendered_win, rendered_root
--- Row of each file path in the last render.
local file_rows = {}
--- { root, paths } of every file, rescanned on demand.
local listing

--- Walk cap for directories outside git, where nothing is ignored.
local WALK_LIMIT = 20000

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

local function scan()
  local s = session()
  local cwd = vim.fn.getcwd()
  local root = s and s.root or git.out(cwd, { 'rev-parse', '--show-toplevel' }, { allow_fail = true })
  local paths = {}
  if root and root ~= '' then
    local out = git.run(root, { 'ls-files', '-z', '--cached', '--others', '--exclude-standard' }, { allow_fail = true })
    local seen = {}
    for _, p in ipairs(vim.split(out or '', '\0', { plain = true })) do
      if p ~= '' and not seen[p] then
        seen[p] = true
        table.insert(paths, p)
      end
    end
  else
    root = cwd
    for name, kind in vim.fs.dir(root, { depth = math.huge }) do
      if kind ~= 'directory' then
        if #paths == WALK_LIMIT then
          util.warn(('%s has over %d files; the panel lists the first %d'):format(root, WALK_LIMIT, WALK_LIMIT))
          break
        end
        table.insert(paths, name)
      end
    end
  end
  listing = { root = root, paths = paths }
end

--- Path shown in the window the user came from, for the current-file highlight.
local function current_path(panel, root)
  local function rel(w)
    local buf = vim.api.nvim_win_get_buf(w)
    if inline.state[buf] then
      return inline.state[buf].path
    end
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].buftype == '' and name:sub(1, #root + 1) == root .. '/' then
      return name:sub(#root + 2)
    end
  end
  local cur = vim.api.nvim_get_current_win()
  if cur ~= panel then
    return rel(cur)
  end
  local prev = vim.fn.win_getid(vim.fn.winnr('#'))
  if prev ~= 0 and prev ~= panel then
    return rel(prev)
  end
end

local function stats(n)
  return ('  +%d -%d'):format(n.additions, n.deletions)
end

local function file_text(s, e, prefix)
  local f = require('revision.files').fields(s, e)
  return prefix .. f.viewed .. ' ', f.adds .. ' ' .. f.dels
end

--- Rows of the tree under node, depth-first. Returns the directory rows in order.
local function render(s, tree, lines, rows)
  local dirs = {}
  local function walk(node, depth)
    local indent = string.rep('  ', depth)
    for _, c in ipairs(node.children) do
      local meta
      if c.dir then
        local prefix = indent .. '▾ '
        local name = c.name .. '/'
        table.insert(lines, prefix .. name .. (c.changed > 0 and stats(c) or ''))
        meta = { kind = 'dir', path = c.path, changed = c.changed, row = #lines, depth = depth }
        meta.name_col, meta.name_end = #prefix, #prefix + #name
        levels[#lines] = '>' .. (depth + 1)
        table.insert(dirs, meta)
      else
        local prefix, rest = indent .. '  ', ''
        if c.e then
          prefix, rest = file_text(s, c.e, indent)
          rest = '  ' .. rest
        end
        table.insert(lines, prefix .. c.name .. rest)
        meta = { kind = 'file', path = c.path, e = c.e }
        meta.name_col, meta.name_end = #prefix, #prefix + #c.name
        levels[#lines] = depth
      end
      rows[#lines] = meta
      if c.dir then
        walk(c, depth + 1)
      end
    end
  end
  walk(tree, 0)
  return dirs
end

--- Records the directories the user folded or unfolded since the last render.
local function capture(win)
  vim.api.nvim_win_call(win, function()
    for row, meta in pairs(M.rows) do
      if meta.kind == 'dir' then
        local fc = vim.fn.foldclosed(row)
        if fc == row and not meta.folded then
          closed[meta.path] = true
        elseif fc == -1 and meta.folded then
          closed[meta.path] = false
        end
      end
    end
  end)
end

--- Opens every fold, then closes the folded directories innermost first: a fold
--- inside an already closed one cannot be closed. Unchanged directories start
--- folded unless a path filter is active, so its matches stay visible.
local function apply_folds(win, dirs, all)
  local filtering = (view.query or '') ~= ''
  vim.api.nvim_win_call(win, function()
    vim.cmd('silent! %foldopen!')
    for i = #dirs, 1, -1 do
      local d = dirs[i]
      local want = closed[d.path]
      if want == nil then
        want = all and d.changed == 0 and not filtering
      end
      d.folded = want
      if want then
        vim.cmd(d.row .. 'foldclose')
      end
    end
  end)
end

local function key_of(meta)
  return meta and (meta.kind .. ':' .. meta.path)
end

function M.refresh()
  local win = M.win()
  -- BufEnter fires while toggle is still setting up the window.
  if not win or vim.wo[win].foldmethod ~= 'expr' then
    return
  end
  local s = session()
  if s and not s.range then
    return
  end
  local all = M.all
  if all and (not listing or (s and listing.root ~= s.root)) then
    scan()
  end
  local root = s and s.root or (listing and listing.root) or vim.fn.getcwd()
  local buf = vim.api.nvim_win_get_buf(win)

  local same = rendered_win == win
  local cursor_key
  if same then
    capture(win)
    cursor_key = key_of(M.rows[vim.api.nvim_win_get_cursor(win)[1]])
  end

  local list = {}
  local in_range = {}
  if s then
    for _, e in ipairs(s.files) do
      in_range[e.path] = true
    end
    for _, e in ipairs(view.filtered(s)) do
      table.insert(list, { path = e.path, e = e })
    end
  end
  if all then
    for _, p in ipairs(listing.paths) do
      if not in_range[p] and view.match_query(p) then
        table.insert(list, { path = p })
      end
    end
  end

  local header = s and require('revision.range').describe(s.range) or vim.fn.fnamemodify(root, ':~')
  if s and all then
    header = header .. '  (all files)'
  end
  local lines, rows = { header }, {}
  levels = { 0 }
  local dirs = {}
  if #list > 0 then
    dirs = render(s, view.tree(s, list), lines, rows)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  M.rows = rows
  rendered_win, rendered_root = win, root
  file_rows = {}
  for row, meta in pairs(rows) do
    if meta.kind == 'file' then
      file_rows[meta.path] = row
    end
  end
  apply_folds(win, dirs, all)

  local sort, filter = view.indicators(s)
  vim.wo[win].winbar = (' %s  %s'):format(sort, filter):gsub('%%', '%%%%')

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local viewed = require('revision.viewed')
  for row, meta in pairs(rows) do
    local hl = meta.kind == 'dir' and 'Directory' or (not meta.e and 'RevisionUnchanged') or nil
    if hl then
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, meta.name_col, { end_col = meta.name_end, hl_group = hl })
    end
    if meta.e and viewed.file_viewed(s, meta.path) then
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { line_hl_group = 'RevisionViewed' })
    end
  end
  M.mark_current()

  if cursor_key then
    for row, meta in pairs(rows) do
      if key_of(meta) == cursor_key then
        vim.api.nvim_win_set_cursor(win, { row, 0 })
        break
      end
    end
  end
end

--- Moves the current-file highlight; cheap enough for every BufEnter.
function M.mark_current()
  local win = M.win()
  if not win or win ~= rendered_win then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_buf_clear_namespace(buf, ns_current, 0, -1)
  local row = file_rows[current_path(win, rendered_root)]
  if row then
    vim.api.nvim_buf_set_extmark(buf, ns_current, row - 1, 0, { line_hl_group = 'RevisionCurrent' })
  end
end

function M.foldexpr()
  return levels[vim.v.lnum] or 0
end

--- The directory row with a closed arrow; the fill after it is blank.
function M.foldtext()
  local row = vim.v.foldstart
  local line = vim.fn.getline(row)
  local meta = M.rows[row]
  if not meta then
    return line
  end
  local prefix = line:sub(1, meta.name_col):gsub('▾', '▸', 1)
  return {
    { prefix },
    { line:sub(meta.name_col + 1, meta.name_end), 'Directory' },
    { line:sub(meta.name_end + 1) },
  }
end

local function at_cursor()
  return M.rows[vim.api.nvim_win_get_cursor(0)[1]]
end

--- A normal window to open files in: the previous one, else any, else a new split.
local function target_win(panel)
  local prev = vim.fn.win_getid(vim.fn.winnr('#'))
  if prev ~= 0 and prev ~= panel and vim.api.nvim_win_get_config(prev).relative == '' then
    return prev
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= panel and vim.api.nvim_win_get_config(w).relative == '' then
      return w
    end
  end
  vim.cmd('rightbelow vsplit')
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(panel, require('revision.config').opts.panel_width)
  return w
end

local function open()
  local meta = at_cursor()
  if not meta then
    return
  end
  if meta.kind == 'dir' then
    vim.cmd('normal! za')
    return
  end
  local root = session() and session().root or listing.root
  vim.api.nvim_set_current_win(target_win(vim.api.nvim_get_current_win()))
  if meta.e then
    require('revision.files').open(meta.e)
  else
    vim.cmd.edit(vim.fn.fnameescape(root .. '/' .. meta.path))
  end
end

local function toggle_viewed()
  local meta = at_cursor()
  local s = session()
  if meta and meta.e then
    local viewed = require('revision.viewed')
    viewed.set_file(s, meta.path, not viewed.file_viewed(s, meta.path))
  end
end

local function toggle_all()
  M.all = not M.all
  if M.all then
    listing = nil
  end
  M.refresh()
end

local function rescan()
  listing = nil
  require('revision.range').reload()
  M.refresh()
end

local function sort(key, reverse)
  return function()
    view.set_sort(key, reverse)
  end
end

local KEYMAPS = {
  { '<CR>', 'open file / toggle directory', open },
  { 'v', 'toggle file viewed', toggle_viewed },
  { '.', 'toggle unchanged files', toggle_all },
  {
    'f',
    'filter by path, live',
    function()
      view.filter_text()
    end,
  },
  {
    'F',
    'filter menu',
    function()
      view.filter_menu()
    end,
  },
  { ',p', 'sort by path', sort('path', false) },
  { ',P', 'sort by path, reversed', sort('path', true) },
  { ',s', 'sort by size', sort('size', false) },
  { ',S', 'sort by size, reversed', sort('size', true) },
  { 'R', 'rescan files', rescan },
  {
    '?',
    'help',
    function()
      M.help()
    end,
  },
  {
    'q',
    'close',
    function()
      M.close()
    end,
  },
}

local FOLD_HELP = {
  { 'za zo zc', 'toggle / open / close directory' },
  { 'zA zO zC', 'same, recursively' },
  { 'zR zM', 'open / close every directory' },
  { 'zj zk', 'next / previous directory' },
}

function M.help()
  local lines = {}
  local width = 0
  local function add(lhs, desc)
    local line = ('  %-9s %s'):format(lhs, desc)
    width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
    table.insert(lines, line)
  end
  for _, k in ipairs(KEYMAPS) do
    add(k[1], k[2])
  end
  table.insert(lines, '')
  for _, k in ipairs(FOLD_HELP) do
    add(k[1], k[2])
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = #lines,
    row = math.floor((vim.o.lines - #lines) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = 'rounded',
    title = ' revision panel ',
    title_pos = 'center',
    style = 'minimal',
  })
  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, lhs in ipairs({ 'q', '<Esc>', '?' }) do
    vim.keymap.set('n', lhs, close, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd('WinLeave', { buffer = buf, once = true, callback = close })
end

local function keys(buf)
  for _, k in ipairs(KEYMAPS) do
    vim.keymap.set('n', k[1], util.guard(k[3]), { buffer = buf, nowait = true, desc = 'revision: ' .. k[2] })
  end
end

local function autocmds()
  local group = vim.api.nvim_create_augroup('revision_panel', {})
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    callback = function()
      M.mark_current()
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufWritePost', 'DirChanged' }, {
    group = group,
    callback = function()
      if M.win() then
        listing = nil
        M.refresh()
      end
    end,
  })
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
  vim.bo[buf].filetype = 'revision-files'
  vim.bo[buf].modifiable = false
  keys(buf)
  autocmds()
  return buf
end

function M.close()
  local win = M.win()
  if win and #vim.api.nvim_list_wins() > 1 then
    vim.api.nvim_win_close(win, true)
  end
end

--- Opens and focuses the panel; focuses it when open elsewhere; closes it when focused.
function M.toggle()
  local win = M.win()
  if win then
    if win == vim.api.nvim_get_current_win() then
      M.close()
    else
      vim.api.nvim_set_current_win(win)
    end
    return
  end
  require('revision').define_highlights()
  vim.cmd('topleft vsplit')
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, ensure_buf())
  vim.api.nvim_win_set_width(win, require('revision.config').opts.panel_width)
  local wo = vim.wo[win][0]
  wo.winfixwidth = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.wrap = false
  wo.foldmethod = 'expr'
  wo.foldexpr = "v:lua.require'revision.panel'.foldexpr()"
  wo.foldtext = "v:lua.require'revision.panel'.foldtext()"
  wo.foldlevel = 99
  wo.foldcolumn = '0'
  wo.foldenable = true
  wo.fillchars = 'fold: '
  wo.winhighlight = 'Folded:Normal'
  rendered_win = nil
  listing = nil
  M.all = false
  M.refresh()
  if vim.api.nvim_buf_line_count(0) > 1 then
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
  end
end

return M
