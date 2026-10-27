local util = require('revision.util')

local M = {}

local function title(d)
  local span = require('revision.comments').span_text(d.start_line or d.line, d.line)
  return (' %s:%s %s%s '):format(d.path, span, d.side, d.private and ' private' or '')
end

local function leader()
  local l = vim.g.mapleader
  if type(l) ~= 'string' or l == '' then
    return '\\'
  end
  return l == ' ' and '<Space>' or l
end

--- Opens the comment float for a draft { id?, path, side, start_line?, line, private, body }.
function M.open(d)
  local name = 'revision://comment/' .. (d.id or 'new')
  local old = vim.fn.bufnr(name)
  if old ~= -1 then
    vim.api.nvim_buf_delete(old, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(d.body, '\n', { plain = true }))
  vim.bo[buf].modified = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = math.min(80, vim.o.columns - 4),
    height = 8,
    border = 'rounded',
    title = title(d),
    title_pos = 'left',
    footer = (' %srp private '):format(leader()),
    footer_pos = 'right',
  })

  -- Normal mode only: an insert-mode leader chord would swallow typed spaces, and <C-p> is completion.
  vim.keymap.set('n', '<leader>rp', function()
    d.private = not d.private
    vim.api.nvim_win_set_config(win, { title = title(d), title_pos = 'left' })
  end, { buffer = buf, desc = 'revision: toggle private' })

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = util.guard(function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      while #lines > 0 and lines[#lines]:match('^%s*$') do
        lines[#lines] = nil
      end
      local body = table.concat(lines, '\n')
      if body:match('^%s*$') then
        error('empty comment', 0)
      end
      local comments = require('revision.comments')
      local s = require('revision.session').s
      if not d.private then
        comments.check_public(s, d)
      end
      comments.commit(s, d, body)
      vim.bo[buf].modified = false
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end)
    end),
  })

  if not d.id then
    vim.cmd.startinsert()
  end
  return buf, win
end

return M
