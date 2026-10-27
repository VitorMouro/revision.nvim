local util = require('revision.util')

local M = {}

local function session_call(name, ...)
  local args = { ... }
  return util.guard(function()
    require('revision.session')[name](unpack(args))
  end)
end

--- Calls module.fn with the session started.
local function call(mod, fn, ...)
  local args = { ... }
  return util.guard(function()
    require('revision.session').start()
    require('revision.' .. mod)[fn](unpack(args))
  end)
end

local global = {
  { 'n', '<leader>rf', session_call('panel'), 'file panel' },
  { 'n', '<leader>ro', session_call('files'), 'files picker' },
  { 'n', '<leader>rv', session_call('view'), 'view (sort/filter)' },
  { 'n', '<leader>rr', session_call('range'), 'range' },
  { 'n', '<leader>rk', session_call('commits'), 'commits' },
  { 'n', '<leader>rs', session_call('save'), 'save' },
  { 'n', '<leader>rb', session_call('body'), 'review body' },
  { 'n', '<leader>rV', session_call('verdict'), 'verdict' },
  { 'n', '<leader>rq', session_call('comments'), 'annotations quickfix' },
  { 'n', '<leader>ri', session_call('info'), 'info' },
  { 'n', '<leader>rt', session_call('toggle_comments'), 'toggle comment display' },
  { 'n', '<leader>rl', session_call('reload'), 'reload context' },
  { 'n', '<leader>rT', session_call('tasks'), 'send tasks to agent' },
}

local buffer = {
  { 'n', '<leader>rc', call('comments', 'create', false), 'comment' },
  { 'x', '<leader>rc', call('comments', 'create', true), 'comment' },
  { 'n', '<leader>rd', call('comments', 'create_left'), 'comment on deleted lines' },
  { 'n', '<leader>re', call('comments', 'edit'), 'edit comment' },
  { 'n', '<leader>rx', call('comments', 'delete'), 'delete comment' },
  { 'n', '<leader>rp', call('comments', 'cycle_kind'), 'cycle kind' },
  { 'n', '<leader>rR', call('comments', 'reply'), 'reply to thread' },
  { 'n', '<leader>ry', call('comments', 'accept_finding'), 'accept finding' },
  { 'n', '<leader>rn', call('comments', 'dismiss_finding'), 'dismiss finding' },
  { 'n', '<leader>ra', call('agent', 'ask', false), 'ask agent' },
  { 'x', '<leader>ra', call('agent', 'ask', true), 'ask agent' },
  { 'n', '<leader>rm', call('viewed', 'toggle_file'), 'file viewed' },
  { 'n', '<leader>rh', call('viewed', 'toggle_hunk'), 'hunk viewed' },
  { 'n', '<leader>rE', call('inline', 'toggle_editable'), 'editable' },
  { 'n', ']c', call('inline', 'jump', 1), 'next hunk' },
  { 'n', '[c', call('inline', 'jump', -1), 'previous hunk' },
  { 'n', ']n', call('inline', 'jump_note', 1), 'next annotation' },
  { 'n', '[n', call('inline', 'jump_note', -1), 'previous annotation' },
  { 'n', ']f', call('files', 'step', 1), 'next file' },
  { 'n', '[f', call('files', 'step', -1), 'previous file' },
  { 'n', ']u', call('files', 'next_unviewed'), 'next unviewed file' },
}

function M.global()
  for _, k in ipairs(global) do
    vim.keymap.set(k[1], k[2], k[3], { desc = 'revision: ' .. k[4] })
  end
  local ok, wk = pcall(require, 'which-key')
  if ok then
    wk.add({ { '<leader>r', group = 'revision' } })
  end
end

function M.buffer(buf)
  for _, k in ipairs(buffer) do
    vim.keymap.set(k[1], k[2], k[3], { buffer = buf, desc = 'revision: ' .. k[4] })
  end
end

function M.clear(buf)
  for _, k in ipairs(buffer) do
    pcall(vim.keymap.del, k[1], k[2], { buffer = buf })
  end
end

return M
