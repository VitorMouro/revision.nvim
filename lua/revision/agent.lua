local util = require('revision.util')

local M = {}

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

function M.ask(visual)
  local s, buf = session(), vim.api.nvim_get_current_buf()
  local st = require('revision.inline').state[buf]
  if not st or st.binary then
    error('not a file in the diff', 0)
  end
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
    ('Reviewing %s %s'):format(s.repo, require('revision.range').describe(s.range)),
    ('%s lines %d-%d (%s, at %s):'):format(st.path, a, b, side, at),
    '```' .. (vim.bo[buf].filetype or ''),
  }
  vim.list_extend(lines, vim.api.nvim_buf_get_lines(buf, a - 1, b, false))
  table.insert(lines, '```')
  table.insert(lines, 'Question: ')
  M.send(lines)
end

return M
