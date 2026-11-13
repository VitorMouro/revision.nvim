local util = require('revision.util')
local git = require('revision.git')
local store = require('revision.store')

local M = {}

--- The active session, or nil.
M.s = nil

local function repo_slug(root, remote)
  local url = git.out(root, { 'remote', 'get-url', remote }, { allow_fail = true })
  if url and url ~= '' then
    local owner, name = url:gsub('%.git$', ''):gsub('/$', ''):match('[:/]([^/:]+)/([^/]+)$')
    if owner then
      return owner .. '/' .. name
    end
  end
  return '_/' .. vim.fs.basename(vim.fs.dirname(git.common_dir(root)))
end

local function resolve_base(root, cfg)
  local ref = cfg.base
  if not ref then
    ref = git.out(root, { 'symbolic-ref', '--short', 'refs/remotes/' .. cfg.remote .. '/HEAD' }, { allow_fail = true })
    if not ref or ref == '' then
      return nil
    end
  end
  local short = ref:gsub('^' .. vim.pesc(cfg.remote) .. '/', '')
  return ref, short
end

local function setup_autocmds(s)
  local group = vim.api.nvim_create_augroup('revision', {})
  local inline = require('revision.inline')
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    callback = function(a)
      inline.attach(a.buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    callback = function(a)
      if not inline.state[a.buf] then
        inline.attach(a.buf)
      end
      if inline.state[a.buf] then
        inline.setup_win(vim.api.nvim_get_current_win(), a.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = util.guard(function(a)
      if s.range and s.range.worktree and inline.relpath(s, a.buf) then
        require('revision.range').reload()
      end
    end),
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      local range = require('revision.range')
      if not range.at(s, s.head) then
        pcall(range.checkout, s, s.head)
      end
    end,
  })
end

--- Starts the session, on the default range or on spec (see range.from_spec).
--- With a session running, only moves it to spec.
function M.start(spec)
  if M.s then
    if spec then
      require('revision.range').from_spec(spec)
    end
    return M.s
  end
  require('revision').define_highlights()
  local cfg = require('revision.config').opts
  local root = git.toplevel(vim.fn.getcwd())
  local head = git.try_head(root)

  local s = {
    root = root,
    repo = repo_slug(root, cfg.remote),
    branch = git.current_branch(root),
    head = head,
    saved_wo = {},
    view = { sort = 'path', reverse = false, unviewed = false, categories = nil },
  }
  s.base, s.base_ref = resolve_base(root, cfg)
  local upstream = git.out(root, { 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}' }, { allow_fail = true })
  s.upstream = (upstream and upstream ~= '') and upstream or nil
  s.marks = store.load(s)

  M.s = s
  local ok, e = pcall(function()
    setup_autocmds(s)
    local range = require('revision.range')
    if spec then
      range.from_spec(spec)
    else
      range.default()
    end
  end)
  if not ok then
    M.stop()
    error(e, 0)
  end
  return s
end

function M.files()
  M.start()
  require('revision.files').pick()
end

function M.range()
  M.start()
  require('revision.range').pick()
end

function M.view()
  M.start()
  require('revision.view').menu()
end

function M.panel()
  require('revision.panel').toggle()
end

function M.commits()
  M.start()
  require('revision.commits').toggle()
end

function M.stop()
  local s = M.s
  if not s then
    return
  end
  local inline = require('revision.inline')
  local range = require('revision.range')
  for buf in pairs(inline.state) do
    inline.detach(buf)
  end
  inline.restore_wins(s)
  pcall(vim.api.nvim_del_augroup_by_name, 'revision')
  if s.range and not range.at(s, s.head) then
    local ok, e = pcall(range.checkout, s, s.head)
    if not ok then
      util.warn('could not restore ' .. (s.branch or util.short(s.head)) .. ': ' .. tostring(e))
    end
    vim.cmd('silent! checktime')
  end
  require('revision.commits').close()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:find('^revision://') and name ~= 'revision://files' then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  M.s = nil
  require('revision.panel').refresh()
end

return M
