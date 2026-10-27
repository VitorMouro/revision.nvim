local inline = require('revision.inline')

local M = {}

local PREFIX = 'revision://deleted/'

local function session()
  return require('revision.session').s
end

local function fill(s, buf, entry)
  local lines = require('revision.util').lines(inline.base_text(s, entry))
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

--- Returns the rendered deleted-file buffer for entry, creating it if needed. Does not display it.
function M.ensure(entry)
  local s = session()
  local name = PREFIX .. entry.path
  local buf = vim.fn.bufnr(name)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].swapfile = false
    local ft = vim.filetype.match({ filename = entry.path })
    if ft then
      vim.bo[buf].filetype = ft
    end
    fill(s, buf, entry)
    inline.state[buf] = { path = entry.path, kind = 'deleted', start = s.range.start }
    require('revision.keys').buffer(buf)
    local group = vim.api.nvim_create_augroup('revision_buf_' .. buf, {})
    vim.api.nvim_create_autocmd('BufWinEnter', {
      buffer = buf,
      group = group,
      callback = function()
        inline.setup_win(vim.api.nvim_get_current_win(), buf)
      end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = buf,
      group = group,
      callback = function()
        inline.state[buf] = nil
      end,
    })
  end
  inline.render(buf)
  return buf
end

function M.open(entry)
  local buf = M.ensure(entry)
  vim.api.nvim_win_set_buf(0, buf)
  inline.setup_win(vim.api.nvim_get_current_win(), buf)
  return buf
end

function M.bufs()
  local out = {}
  for buf, st in pairs(inline.state) do
    if st.kind == 'deleted' and vim.api.nvim_buf_is_valid(buf) then
      table.insert(out, buf)
    end
  end
  return out
end

--- Re-renders deleted-file buffers still deleted in the range; wipes the rest.
function M.refresh_all()
  local s = session()
  for _, buf in ipairs(M.bufs()) do
    local st = inline.state[buf]
    local entry = s.file_map[st.path]
    if entry and entry.status == 'D' then
      if st.start ~= s.range.start then
        st.start = s.range.start
        fill(s, buf, entry)
      end
      inline.render(buf)
    else
      M.wipe(buf)
    end
  end
end

function M.wipe(buf)
  inline.detach(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

return M
