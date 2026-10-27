local util = require('revision.util')
local git = require('revision.git')
local gh = require('revision.gh')
local store = require('revision.store')

local M = {}

--- The active session, or nil.
M.s = nil

local gh_noted = false

local function require_pr(s)
  if not s.pr then
    error('no GitHub PR for this branch', 0)
  end
end

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

local function resolve_base(root, cfg, pr)
  if pr then
    local oid = pr.baseRefOid
    if oid and git.ok(root, { 'cat-file', '-e', oid .. '^{commit}' }) then
      return oid, pr.baseRefName
    end
    local ref = cfg.remote .. '/' .. pr.baseRefName
    util.warn(('base %s not fetched locally; using %s (run git fetch)'):format(util.short(oid), ref))
    return ref, pr.baseRefName
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

  local pr, why = gh.pr_view(root)
  if not pr and not gh_noted then
    gh_noted = true
    util.notify(('no GitHub PR (%s); reviewing locally'):format(why))
  end

  local base, base_ref = resolve_base(root, cfg, pr)
  local head = git.try_head(root)
  local merge_base = base and head and git.out(root, { 'merge-base', 'HEAD', base }, { allow_fail = true })
  local branch = git.current_branch(root)
  if pr and pr.headRefOid ~= head then
    util.warn(('worktree HEAD %s is not the PR head %s'):format(util.short(head), util.short(pr.headRefOid)))
  end
  local upstream = not pr
    and git.out(root, { 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}' }, { allow_fail = true })

  local s = {
    root = root,
    repo = repo_slug(root, cfg.remote),
    pr = pr,
    branch = branch,
    base = base,
    base_ref = base_ref,
    merge_base = merge_base ~= '' and merge_base or nil,
    upstream = upstream ~= '' and upstream or nil,
    head = head,
    show_comments = true,
    saved_wo = {},
    pr_diff = {},
  }
  require('revision.range').refresh_local(s)
  s.review = store.load(store.path(s))

  M.s = s
  local ok, e = pcall(function()
    store.create_buf(s)
    setup_autocmds(s)
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

function M.save()
  local s = M.start()
  store.save(s)
end

function M.discard()
  local s = M.s
  if not s then
    return
  end
  if vim.fn.confirm('Discard unsaved review changes?', '&Yes\n&No', 2) ~= 1 then
    return
  end
  s.review = store.load(store.path(s))
  require('revision.viewed').reconcile(s)
  store.set_body_lines(s)
  require('revision.inline').rerender()
end

function M.delete()
  local s = M.start()
  local path = store.path(s)
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
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):find('^revision://') then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  M.s = nil
end

function M.toggle_comments()
  local s = M.start()
  require_pr(s)
  s.show_comments = not s.show_comments
  require('revision.inline').rerender()
end

function M.comments()
  M.start()
  require('revision.comments').quickfix()
end

function M.body()
  local s = M.start()
  require_pr(s)
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
  require_pr(s)
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
  require_pr(s)
  local pr, why = gh.pr_view(s.root)
  if not pr then
    error('gh: ' .. tostring(why), 0)
  end
  s.pr = pr
  vim.lsp.util.open_floating_preview({
    ('#%d %s'):format(pr.number, pr.title),
    pr.url,
    ('base %s (%s) ← head %s (%s)'):format(pr.baseRefName, util.short(s.merge_base), pr.headRefName, util.short(s.head)),
    ('state %s%s'):format(pr.state, pr.isDraft and ', draft' or ''),
    ('mergeable %s / %s'):format(pr.mergeable, pr.mergeStateStatus),
    ('review decision %s'):format(util.nn(pr.reviewDecision) ~= '' and pr.reviewDecision or 'none'),
    'range ' .. require('revision.range').describe(s.range),
  }, 'text', { border = 'rounded' })
end

return M
