local util = require('revision.util')
local git = require('revision.git')
local inline = require('revision.inline')
local viewed = require('revision.viewed')
local view = require('revision.view')

local M = {}

local function session()
  return require('revision.session').s
end

local function flag(e)
  if e.binary then
    return 'binary'
  elseif e.status == 'D' then
    return 'deleted'
  elseif e.status == 'R' then
    return 'renamed'
  end
  return ''
end

--- Row of a file, one value per column.
local function fields(s, e)
  local n, total = viewed.hunk_counts(s, e.path)
  return {
    viewed = viewed.file_viewed(s, e.path) and '✓' or ' ',
    path = e.path,
    adds = '+' .. e.additions,
    dels = '-' .. e.deletions,
    hn = tostring(n),
    ht = tostring(total),
    category = view.category(s, e.path),
    flag = flag(e),
  }
end
M.fields = fields

function M.format(s, e)
  local f = fields(s, e)
  local parts = { f.viewed .. ' ' .. f.path, f.adds .. ' ' .. f.dels, ('h:%s/%s'):format(f.hn, f.ht) }
  if f.flag ~= '' then
    table.insert(parts, f.flag)
  end
  return table.concat(parts, '  ')
end

local function pad(text, width, right)
  local n = width - vim.fn.strdisplaywidth(text)
  if n <= 0 then
    return text
  end
  local spaces = string.rep(' ', n)
  return right and (spaces .. text) or (text .. spaces)
end

--- Picker rows with every column padded to a common width.
function M.rows(s)
  local rows = {}
  local w = { path = 0, adds = 0, dels = 0, hn = 0, ht = 0, category = 0 }
  for _, e in ipairs(view.visible(s)) do
    local f = fields(s, e)
    f.e = e
    for _, k in ipairs({ 'path', 'adds', 'dels', 'hn', 'ht', 'category' }) do
      w[k] = math.max(w[k], vim.fn.strdisplaywidth(f[k]))
    end
    table.insert(rows, f)
  end
  for _, f in ipairs(rows) do
    local parts = {
      f.viewed .. ' ' .. pad(f.path, w.path),
      pad(f.adds, w.adds, true) .. ' ' .. pad(f.dels, w.dels, true),
      ('h:%s/%s'):format(pad(f.hn, w.hn, true), pad(f.ht, w.ht)),
    }
    table.insert(parts, pad(f.category, w.category))
    if f.flag ~= '' then
      table.insert(parts, f.flag)
    end
    f.text = (table.concat(parts, '  '):gsub('%s+$', ''))
  end
  return rows
end

function M.open(e)
  local s = session()
  if e.status == 'D' then
    require('revision.deleted').open(e)
  else
    vim.cmd.edit(vim.fn.fnameescape(s.root .. '/' .. e.path))
  end
end

--- Unified diff of one file in the current range, for the picker preview.
function M.preview(s, e)
  if e.binary then
    return { 'binary file' }
  end
  local text
  if e.untracked then
    local f = io.open(s.root .. '/' .. e.path, 'rb')
    if f then
      text = f:read('*a')
      f:close()
    end
    text = (text or ''):gsub('\r\n', '\n')
  else
    local args = { 'diff', '--no-color', '-M', s.range.start }
    if not s.range.worktree then
      table.insert(args, s.range.end_)
    end
    vim.list_extend(args, { '--', e.old_path or e.path })
    text = git.run(s.root, args, { allow_fail = true }) or ''
  end
  local lines = util.lines(text)
  if #lines > 20000 then
    lines = vim.list_slice(lines, 1, 20000)
    table.insert(lines, '(truncated)')
  end
  if #lines == 0 then
    return { '(no diff)' }
  end
  return lines
end

--- Telescope picker; false when telescope is not loaded.
local function telescope(s, rows)
  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then
    return false
  end
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local previewers = require('telescope.previewers')
  pickers.new({}, {
    prompt_title = ('Revision files · %s · %s'):format(require('revision.range').describe(s.range), view.describe(s)),
    finder = finders.new_table({
      results = rows,
      entry_maker = function(r)
        return { value = r, display = r.text, ordinal = r.e.path }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = 'Diff',
      define_preview = function(self, entry)
        local buf = self.state.bufnr
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.preview(s, entry.value.e))
        vim.bo[buf].filetype = 'diff'
      end,
    }),
    layout_strategy = 'horizontal',
    layout_config = { width = 0.9, height = 0.85, preview_width = 0.55 },
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          M.open(entry.value.e)
        end
      end)
      local menu = function()
        actions.close(prompt_bufnr)
        view.menu(M.pick)
      end
      for _, lhs in ipairs({ '<C-s>', '<C-f>' }) do
        map('i', lhs, menu)
        map('n', lhs, menu)
      end
      return true
    end,
  }):find()
  return true
end

function M.pick()
  local s = require('revision.session').start()
  require('revision.range').reload()
  local rows = M.rows(s)
  if #rows == 0 then
    util.notify(('no files match the view (%s)'):format(view.describe(s)))
    return
  end
  if telescope(s, rows) then
    return
  end
  vim.ui.select(rows, {
    prompt = ('Revision files (%s · %s)'):format(require('revision.range').describe(s.range), view.describe(s)),
    format_item = function(r)
      return r.text
    end,
  }, util.guard(function(r)
    if r then
      M.open(r.e)
    end
  end))
end

--- Path of the file in the current buffer, or nil.
local function current_path()
  local st = inline.state[vim.api.nvim_get_current_buf()]
  return st and st.path or nil
end

local function index_of(list, path)
  for i, e in ipairs(list) do
    if e.path == path then
      return i
    end
  end
end

--- Step dir files through the visible list, from the current file's place in the full sort.
function M.step(dir)
  local s = session()
  local list = view.visible(s)
  local path = current_path()
  local i = path and index_of(list, path)
  local j
  if i then
    j = i + dir
  elseif path then
    local all = view.sorted(s)
    local at = index_of(all, path) or 0
    j = dir > 0 and #list + 1 or 0
    for k, e in ipairs(list) do
      local pos = index_of(all, e.path)
      if dir > 0 and pos > at then
        j = k
        break
      elseif dir < 0 and pos < at then
        j = k
      end
    end
  else
    j = dir > 0 and 1 or #list
  end
  if j < 1 then
    util.notify('first file')
  elseif j > #list then
    util.notify('last file')
  else
    M.open(list[j])
  end
end

function M.next_unviewed()
  local s = session()
  local list = view.visible(s)
  local n = #list
  if n == 0 then
    util.notify('all files viewed')
    return
  end
  local path = current_path()
  local i = (path and index_of(list, path)) or 0
  for k = 1, n do
    local at = (i + k - 1) % n + 1
    local e = list[at]
    if not viewed.file_viewed(s, e.path) then
      if at == i then
        util.notify('no other unviewed file')
      else
        M.open(e)
      end
      return
    end
  end
  util.notify('all files viewed')
end

return M
