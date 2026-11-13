local util = require('revision.util')

local M = {}

local function session()
  return require('revision.session').s
end

--- Added and deleted lines of the range, in panel order:
--- { e, sign = '+'|'-', text, new?, old?, target } where target is the row to jump to.
function M.entries(s)
  local out = {}
  for _, e in ipairs(require('revision.view').sorted(s)) do
    for _, h in ipairs(s.hunks[e.path] or {}) do
      for i, text in ipairs(h.old_lines) do
        local old = h.old_start + i - 1
        -- A deletion-only hunk's new_start is the line before the deleted block, 0 at the top.
        local target = e.status == 'D' and old or math.max(h.new_start, 1)
        table.insert(out, { e = e, sign = '-', text = text, old = old, target = target })
      end
      for i, text in ipairs(h.new_lines) do
        local new = h.new_start + i - 1
        table.insert(out, { e = e, sign = '+', text = text, new = new, target = new })
      end
    end
  end
  return out
end

local function label(it)
  return ('%s:%d %s %s'):format(it.e.path, it.sign == '+' and it.new or it.old, it.sign, it.text)
end

local function jump(it)
  require('revision.files').open(it.e)
  local row = math.min(it.target, vim.api.nvim_buf_line_count(0))
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.cmd('normal! zvzz')
end

--- Row of the entry in files.preview output: the unified diff, or the raw text of an untracked file.
local function preview_row(lines, it)
  if it.e.untracked then
    return it.new
  end
  local old, new
  for i, l in ipairs(lines) do
    local a, c = l:match('^@@ %-(%d+),?%d* %+(%d+)')
    if a then
      old, new = tonumber(a), tonumber(c)
    elseif old then
      local ch = l:sub(1, 1)
      if ch == '-' then
        if it.sign == '-' and old == it.old then
          return i
        end
        old = old + 1
      elseif ch == '+' then
        if it.sign == '+' and new == it.new then
          return i
        end
        new = new + 1
      elseif ch == ' ' then
        old, new = old + 1, new + 1
      end
    end
  end
end

--- Indexes (1-based) of the entries whose text matches pattern, by rg over stdin.
--- Returns nil and the error when rg fails, e.g. on an invalid regex.
function M.rg(items, pattern)
  if pattern == '' then
    return {}
  end
  local input = {}
  for i, it in ipairs(items) do
    input[i] = it.text
  end
  local r = vim
    .system({ 'rg', '--line-number', '--no-heading', '--color=never', '--smart-case', '--', pattern }, {
      stdin = table.concat(input, '\n') .. '\n',
      text = true,
    })
    :wait()
  if r.code == 1 then
    return {}
  elseif r.code ~= 0 then
    return nil, vim.trim(r.stderr or '')
  end
  local out = {}
  for line in vim.gsplit(r.stdout, '\n', { plain = true }) do
    local n = tonumber(line:match('^(%d+):'))
    if n then
      table.insert(out, n)
    end
  end
  return out
end

local ns = vim.api.nvim_create_namespace('revision_search_preview')

local function telescope(s, items, live)
  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then
    return false
  end
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local previewers = require('telescope.previewers')
  local sorters = require('telescope.sorters')

  local function entry_maker(it)
    return { value = it, display = label(it), ordinal = it.text }
  end
  local finder
  if live then
    finder = finders.new_dynamic({
      fn = function(prompt)
        local hits = M.rg(items, prompt or '') or {}
        return vim.tbl_map(function(i)
          return items[i]
        end, hits)
      end,
      entry_maker = entry_maker,
    })
  else
    finder = finders.new_table({ results = items, entry_maker = entry_maker })
  end

  pickers
    .new({}, {
      prompt_title = ('Revision %s · %s'):format(live and 'rg diffs' or 'fuzzy diffs', require('revision.range').describe(s.range)),
      finder = finder,
      sorter = live and sorters.empty() or conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = 'Diff',
        define_preview = function(self, entry)
          local buf = self.state.bufnr
          local it = entry.value
          local lines = require('revision.files').preview(s, it.e)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
          vim.bo[buf].filetype = it.e.untracked and (vim.filetype.match({ filename = it.e.path }) or '') or 'diff'
          local row = preview_row(lines, it)
          if row then
            vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { line_hl_group = 'TelescopePreviewLine' })
            local win = self.state.winid
            -- Telescope resets the preview view after define_preview returns.
            vim.schedule(function()
              if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
                pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
                vim.api.nvim_win_call(win, function()
                  vim.cmd('normal! zz')
                end)
              end
            end)
          end
        end,
      }),
      layout_strategy = 'horizontal',
      layout_config = { width = 0.9, height = 0.85, preview_width = 0.55 },
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            jump(entry.value)
          end
        end)
        return true
      end,
    })
    :find()
  return true
end

local function select(items)
  vim.ui.select(items, { prompt = 'Revision diffs', format_item = label }, util.guard(function(it)
    if it then
      jump(it)
    end
  end))
end

local function run(live)
  local s = session()
  local items = M.entries(s)
  if #items == 0 then
    util.notify('no changed lines in ' .. require('revision.range').describe(s.range))
    return
  end
  if telescope(s, items, live) then
    return
  end
  if not live then
    select(items)
    return
  end
  local pattern = vim.fn.input({ prompt = 'rg diffs: ', cancelreturn = false })
  if not pattern or pattern == '' then
    return
  end
  local hits, err = M.rg(items, pattern)
  if not hits then
    error('rg: ' .. err, 0)
  end
  if #hits == 0 then
    util.notify('no changed line matches ' .. pattern)
    return
  end
  select(vim.tbl_map(function(i)
    return items[i]
  end, hits))
end

--- Regex search over the changed lines with ripgrep, live as you type.
function M.grep()
  run(true)
end

--- Fuzzy search over the changed lines.
function M.fuzzy()
  run(false)
end

return M
