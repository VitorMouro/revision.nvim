local util = require('revision.util')
local view = require('revision.view')
local inline = require('revision.inline')

local M = {}

local NAME = 'revision://files'
local ns = vim.api.nvim_create_namespace('revision_panel')

--- Per-render row map: { [row] = { kind = 'header'|'file', category, e } }.
M.rows = {}

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

--- Path shown in the window the user came from, for the current-file highlight.
local function current_path(panel)
  local cur = vim.api.nvim_get_current_win()
  if cur ~= panel and inline.state[vim.api.nvim_win_get_buf(cur)] then
    return inline.state[vim.api.nvim_win_get_buf(cur)].path
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local st = w ~= panel and inline.state[vim.api.nvim_win_get_buf(w)]
    if st then
      return st.path
    end
  end
end

local function file_text(s, e, indent)
  local f = require('revision.files').fields(s, e)
  local parts = { indent .. f.viewed .. ' ' .. f.path, f.adds .. ' ' .. f.dels }
  if f.comments > 0 then
    table.insert(parts, 'c:' .. f.comments)
  end
  if f.findings > 0 then
    table.insert(parts, 'f:' .. f.findings)
  end
  return table.concat(parts, '  ')
end

local function header_text(s, category, files, collapsed)
  local a, d = 0, 0
  for _, e in ipairs(files) do
    a, d = a + e.additions, d + e.deletions
  end
  return ('%s %s (%d)  +%d -%d'):format(collapsed and '▸' or '▾', category, #files, a, d)
end

--- Visible files grouped by category, in display order.
local function grouped(s, files)
  local by_cat, order = {}, {}
  for _, e in ipairs(files) do
    local c = view.category(s, e.path)
    if not by_cat[c] then
      by_cat[c] = {}
      table.insert(order, c)
    end
    table.insert(by_cat[c], e)
  end
  local rank = {}
  for i, c in ipairs(view.ORDER) do
    rank[c] = i
  end
  table.sort(order, function(x, y)
    return (rank[x] or #view.ORDER + 1) < (rank[y] or #view.ORDER + 1)
  end)
  return order, by_cat
end

function M.refresh()
  local win = M.win()
  local s = session()
  if not win or not s or not s.range then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local cur = current_path(win)
  local files = view.visible(s)
  local sort = s.review.view.sort
  local lines, rows = { ('%s · %s'):format(require('revision.range').describe(s.range), view.describe(s)) }, {}

  local function add_file(e, indent)
    table.insert(lines, file_text(s, e, indent))
    rows[#lines] = { kind = 'file', e = e }
  end

  if #files == 0 then
    table.insert(lines, 'no files match the view')
  elseif sort == 'category' then
    local order, by_cat = grouped(s, files)
    for _, c in ipairs(order) do
      local collapsed = s.panel_collapsed[c] or false
      table.insert(lines, header_text(s, c, by_cat[c], collapsed))
      rows[#lines] = { kind = 'header', category = c }
      if not collapsed then
        for _, e in ipairs(by_cat[c]) do
          add_file(e, '  ')
        end
      end
    end
  else
    for _, e in ipairs(files) do
      add_file(e, '')
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local viewed = require('revision.viewed')
  for row, meta in pairs(rows) do
    if meta.kind == 'file' then
      if viewed.file_viewed(s, meta.e.path) then
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { line_hl_group = 'RevisionViewed' })
      end
      if meta.e.path == cur then
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { line_hl_group = 'RevisionCurrent' })
      end
      local reason = sort == 'order' and view.reason(s, meta.e.path)
      if reason then
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
          virt_text = { { '  ' .. reason, 'RevisionViewed' } },
        })
      end
    end
  end
  M.rows = rows
end

local function at_cursor()
  return M.rows[vim.api.nvim_win_get_cursor(0)[1]]
end

local function toggle_group(category)
  local s = session()
  s.panel_collapsed[category] = not s.panel_collapsed[category]
  M.refresh()
end

local function keys(buf)
  local map = function(lhs, fn)
    vim.keymap.set('n', lhs, util.guard(fn), { buffer = buf, nowait = true, desc = 'revision: panel' })
  end
  map('<CR>', function()
    local meta = at_cursor()
    if not meta then
      return
    end
    if meta.kind == 'header' then
      toggle_group(meta.category)
    else
      vim.cmd('wincmd p')
      require('revision.files').open(meta.e)
    end
  end)
  map('v', function()
    local meta = at_cursor()
    if meta and meta.kind == 'file' then
      local s = session()
      local viewed = require('revision.viewed')
      viewed.set_file(s, meta.e.path, not viewed.file_viewed(s, meta.e.path))
    end
  end)
  map('za', function()
    local meta = at_cursor()
    if meta and meta.category then
      toggle_group(meta.category)
    end
  end)
  map('s', function()
    view.menu()
  end)
  map('f', function()
    view.menu()
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
  vim.bo[buf].filetype = 'revision-files'
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
  local cur = vim.api.nvim_get_current_win()
  vim.cmd('topleft vsplit')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, ensure_buf())
  vim.api.nvim_win_set_width(win, require('revision.config').opts.panel_width)
  local wo = vim.wo[win][0]
  wo.winfixwidth = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.wrap = false
  if vim.api.nvim_win_is_valid(cur) then
    vim.api.nvim_set_current_win(cur)
  end
  M.refresh()
end

return M
