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
  { '<leader>rf', session_call('files'), 'files' },
  { '<leader>rr', session_call('range'), 'range' },
  { '<leader>rs', session_call('save'), 'save' },
  { '<leader>rb', session_call('body'), 'review body' },
  { '<leader>rV', session_call('verdict'), 'verdict' },
  { '<leader>rq', session_call('comments'), 'comments quickfix' },
  { '<leader>ri', session_call('info'), 'PR info' },
  { '<leader>rt', session_call('toggle_comments'), 'toggle comment display' },
}

local buffer = {
  { 'n', '<leader>rc', call('comments', 'create', false), 'comment' },
  { 'x', '<leader>rc', call('comments', 'create', true), 'comment' },
  { 'n', '<leader>rd', call('comments', 'create_left'), 'comment on deleted lines' },
  { 'n', '<leader>re', call('comments', 'edit'), 'edit comment' },
  { 'n', '<leader>rx', call('comments', 'delete'), 'delete comment' },
  { 'n', '<leader>rp', call('comments', 'toggle_private'), 'toggle private' },
  { 'n', '<leader>rm', call('viewed', 'toggle_file'), 'file viewed' },
  { 'n', '<leader>rh', call('viewed', 'toggle_hunk'), 'hunk viewed' },
  { 'n', '<leader>rE', call('inline', 'toggle_editable'), 'editable' },
  { 'n', ']c', call('inline', 'jump', 1), 'next hunk' },
  { 'n', '[c', call('inline', 'jump', -1), 'previous hunk' },
  { 'n', ']f', call('files', 'step', 1), 'next file' },
  { 'n', '[f', call('files', 'step', -1), 'previous file' },
  { 'n', ']u', call('files', 'next_unviewed'), 'next unviewed file' },
}

function M.global()
  for _, k in ipairs(global) do
    vim.keymap.set('n', k[1], k[2], { desc = 'revision: ' .. k[3] })
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
