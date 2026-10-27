local util = require('revision.util')
local git = require('revision.git')
local store = require('revision.store')
local context = require('revision.context')

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

local function resolve_base(root, cfg, ctx)
  if ctx then
    local oid = util.nn(ctx.base)
    local name = util.nn(ctx.base_ref)
    if oid and git.ok(root, { 'cat-file', '-e', oid .. '^{commit}' }) then
      return oid, name or util.short(oid)
    end
    if name then
      local ref = cfg.remote .. '/' .. name
      if oid then
        util.warn(('base %s not fetched locally; using %s (run git fetch)'):format(util.short(oid), ref))
      end
      return ref, name
    end
  end
  local ref = cfg.base
  if not ref then
    ref = git.out(root, { 'symbolic-ref', '--short', 'refs/remotes/' .. cfg.remote .. '/HEAD' }, { allow_fail = true })
    if ref == '' then
      return nil
    end
  end
  if not ref then
    return nil
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
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    callback = function()
      require('revision.panel').refresh()
    end,
  })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = util.guard(function(a)
      if s.range and s.range.worktree and inline.relpath(s, a.buf) then
        require('revision.range').working()
      end
    end),
  })
  vim.api.nvim_create_autocmd('WinResized', {
    group = group,
    callback = function()
      local seen = {}
      for _, win in ipairs(vim.v.event.windows) do
        local buf = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
        if buf and inline.state[buf] and not seen[buf] then
          seen[buf] = true
          inline.render(buf)
        end
      end
    end,
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

function M.start()
  if M.s then
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
    show_comments = true,
    saved_wo = {},
    review_diff = {},
    panel_collapsed = { Generated = true, Mechanical = true },
  }
  s.dir = store.dir(s)
  s.ctx = context.load(store.context_path(s))
  s.base, s.base_ref = resolve_base(root, cfg, s.ctx)
  local merge_base = s.base and head and git.out(root, { 'merge-base', 'HEAD', s.base }, { allow_fail = true })
  s.merge_base = (merge_base and merge_base ~= '') and merge_base or nil
  if not s.ctx then
    local upstream =
      git.out(root, { 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}' }, { allow_fail = true })
    s.upstream = (upstream and upstream ~= '') and upstream or nil
  end
  if s.ctx and util.nn(s.ctx.head) and s.ctx.head ~= head then
    util.warn(('worktree HEAD %s is not the context head %s'):format(util.short(head), util.short(s.ctx.head)))
  end

  require('revision.range').refresh_local(s)
  s.review = store.load(store.review_path(s))

  M.s = s
  local ok, e = pcall(function()
    store.create_buf(s)
    setup_autocmds(s)
    context.apply(s)
    require('revision.range').default()
  end)
  if not ok then
    M.stop({ force = true })
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
  M.start()
  require('revision.panel').toggle()
end

function M.commits()
  M.start()
  require('revision.commits').toggle()
end

function M.tasks()
  M.start()
  require('revision.agent').tasks()
end

function M.save()
  local s = M.start()
  store.save(s)
end

--- Re-reads context.json; the base, head and range are left alone.
function M.reload()
  local s = M.start()
  s.ctx = context.load(store.context_path(s))
  context.apply(s)
  require('revision.panel').refresh()
  util.notify('context reloaded')
end

function M.discard()
  local s = M.s
  if not s then
    return
  end
  if vim.fn.confirm('Discard unsaved review changes?', '&Yes\n&No', 2) ~= 1 then
    return
  end
  s.review = store.load(store.review_path(s))
  require('revision.viewed').reconcile(s)
  store.set_body_lines(s)
  require('revision.inline').rerender()
end

function M.delete()
  local s = M.start()
  local path = store.review_path(s)
  if vim.fn.confirm('Delete review file ' .. path .. '?', '&Yes\n&No', 2) ~= 1 then
    return
  end
  store.unlink(s)
  M.stop({ force = true })
end

function M.stop(opts)
  local s = M.s
  if not s then
    return
  end
  opts = opts or {}
  if not opts.force and s.review_buf and vim.api.nvim_buf_is_valid(s.review_buf) and vim.bo[s.review_buf].modified then
    error('unsaved review; :Revision save or :Revision discard', 0)
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
  require('revision.panel').close()
  require('revision.commits').close()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):find('^revision://') then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  M.s = nil
end

function M.toggle_comments()
  local s = M.start()
  s.show_comments = not s.show_comments
  require('revision.inline').rerender()
end

function M.comments()
  M.start()
  require('revision.comments').quickfix()
end

function M.body()
  local s = M.start()
  local w = math.floor(vim.o.columns * 0.8)
  local h = math.floor(vim.o.lines * 0.8)
  local verdict = util.nn(s.review.verdict) or 'no verdict'
  vim.api.nvim_open_win(s.review_buf, true, {
    relative = 'editor',
    width = w,
    height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
    border = 'rounded',
    title = ' Review: ' .. verdict .. ' ',
    title_pos = 'left',
  })
end

function M.verdict()
  local s = M.start()
  vim.ui.select({ 'approve', 'request_changes', 'comment', 'none' }, { prompt = 'Verdict' }, function(v)
    if not v then
      return
    end
    s.review.verdict = v == 'none' and vim.NIL or v
    store.touch()
  end)
end

function M.info()
  local s = M.start()
  local ctx = s.ctx
  if not ctx then
    error('no context file; the review tool writes ' .. store.context_path(s), 0)
  end
  local lines = { util.nn(ctx.title) or s.branch or util.short(s.head) }
  if util.nn(ctx.url) then
    table.insert(lines, ctx.url)
  end
  table.insert(
    lines,
    ('base %s (%s) ← head %s (%s)'):format(
      s.base_ref or '-',
      util.short(s.merge_base),
      s.branch or util.short(s.head),
      util.short(s.head)
    )
  )
  for _, m in ipairs(ctx.meta) do
    table.insert(lines, ('%s: %s'):format(tostring(util.nn(m.label)), tostring(util.nn(m.value))))
  end
  table.insert(lines, 'range ' .. require('revision.range').describe(s.range))
  local desc = util.nn(ctx.description)
  if desc and desc ~= '' then
    table.insert(lines, '')
    vim.list_extend(lines, vim.split(desc, '\n', { plain = true }))
  end
  for _, r in ipairs(ctx.reviews) do
    table.insert(lines, '')
    table.insert(
      lines,
      ('%s %s %s'):format(tostring(util.nn(r.author)), tostring(util.nn(r.state)), tostring(util.nn(r.submitted_at)))
    )
    local body = util.nn(r.body)
    if body and body ~= '' then
      vim.list_extend(lines, vim.split(body, '\n', { plain = true }))
    end
  end
  vim.lsp.util.open_floating_preview(lines, 'markdown', { border = 'rounded' })
end

return M
