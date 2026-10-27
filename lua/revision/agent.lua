local util = require('revision.util')

local M = {}

local ROOT = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

local function session()
  return require('revision.session').s
end

--- Hands lines to the agent through sidekick, or to the + register when it is missing.
function M.send(lines)
  local ok, cli = pcall(require, 'sidekick.cli')
  if ok then
    cli.send({
      text = vim.tbl_map(function(l)
        return { { l } }
      end, lines),
      name = require('revision.config').opts.agent.tool,
      submit = false,
      focus = true,
    })
    return
  end
  vim.fn.setreg('+', table.concat(lines, '\n'))
  util.notify('sidekick.nvim not found; prompt copied to the + register')
end

local function anchor(s, c)
  if c.worktree then
    return 'worktree'
  end
  return util.short(util.nn(c.commit))
end

--- One line describing an annotation that overlaps the asked-about lines.
local function annotation_line(c)
  local first = function(text)
    return vim.split(util.nn(text) or '', '\n', { plain = true })[1] or ''
  end
  if c.remote then
    local rc = (c.comments or {})[1] or {}
    return ('- [@%s] %s'):format(tostring(util.nn(rc.author) or '?'), first(rc.body))
  end
  if c.finding and not c.kind then
    return ('- [finding:%s] %s'):format(c.severity, c.title)
  end
  return ('- [%s #%d] %s'):format(c.kind, c.id, first(c.body))
end

function M.ask(visual)
  local comments = require('revision.comments')
  local s, buf, st = comments.current()
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
  local side = st.kind == 'deleted' and 'LEFT' or 'RIGHT'
  local at = s.range.worktree and 'worktree' or util.short(s.range.end_)
  local lines = {
    ('Reviewing %s %s (review files: %s)'):format(s.repo, require('revision.range').describe(s.range), s.dir),
    ('%s lines %d-%d (%s, at %s):'):format(st.path, a, b, side, at),
    '```' .. (vim.bo[buf].filetype or ''),
  }
  vim.list_extend(lines, vim.api.nvim_buf_get_lines(buf, a - 1, b, false))
  table.insert(lines, '```')

  local right, left = comments.for_buffer(s, st)
  local hits = {}
  for _, list in ipairs({ right, left }) do
    for _, c in ipairs(list) do
      local first = util.nn(c.start_line) or c.line
      if first <= b and c.line >= a then
        table.insert(hits, annotation_line(c))
      end
    end
  end
  if #hits > 0 then
    table.insert(lines, 'Annotations on these lines:')
    vim.list_extend(lines, hits)
  end
  table.insert(lines, 'Question: ')
  M.send(lines)
end

function M.tasks()
  local s = session()
  if vim.bo[s.review_buf].modified then
    error('unsaved review; :Revision save first', 0)
  end
  local open = {}
  for _, c in ipairs(s.review.comments) do
    if c.kind == 'task' and not (s.task_status and s.task_status[c.id]) then
      table.insert(open, c)
    end
  end
  if #open == 0 then
    util.notify('no open tasks')
    return
  end
  local comments = require('revision.comments')
  local lines = {
    ('Fix the open review tasks below. They are stored in %s/review.json (comments with kind "task").'):format(s.dir),
  }
  for _, c in ipairs(open) do
    table.insert(
      lines,
      ('- #%d %s:%s (%s, at %s): %s'):format(
        c.id,
        c.path,
        comments.span_text(util.nn(c.start_line) or c.line, c.line),
        c.side,
        anchor(s, c),
        vim.split(c.body, '\n', { plain = true })[1] or ''
      )
    )
  end
  table.insert(
    lines,
    ('When done with each, record it in %s/context.json under "tasks" as '):format(s.dir)
      .. '{"local_id": <id>, "status": "done" or "wontfix", "note": "<one line>"}, '
      .. ('keeping the rest of the file. Format: %s/FORMAT.md'):format(ROOT)
  )
  M.send(lines)
end

return M
