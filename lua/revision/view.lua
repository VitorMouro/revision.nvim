local util = require('revision.util')

local M = {}

--- Display and sort order of the categories.
M.ORDER = { 'Source', 'Migration', 'Infra', 'Deps', 'Tests', 'Config', 'I18n', 'Style', 'Docs', 'Mechanical', 'Generated' }

M.RULES = {
  {
    category = 'Generated',
    globs = {
      '**/*.lock',
      '**/package-lock.json',
      '**/pnpm-lock.yaml',
      '**/yarn.lock',
      '**/bun.lock*',
      '**/go.sum',
      '**/Cargo.lock',
      '**/dist/**',
      '**/build/**',
      '**/*.min.*',
      '**/__snapshots__/**',
      '**/*.snap',
      '**/*.generated.*',
      '**/*.pb.go',
      '**/*_gen.go',
    },
  },
  { category = 'Migration', globs = { '**/migrations/**', '**/migration/**', '**/*.sql' } },
  {
    category = 'Infra',
    globs = {
      '.github/**',
      '**/Dockerfile*',
      '**/*.tf',
      '**/*.tfvars',
      '**/docker-compose*.y*ml',
      '**/infra/**',
      '**/k8s/**',
      '**/helm/**',
    },
  },
  {
    category = 'Deps',
    globs = { '**/package.json', '**/go.mod', '**/Cargo.toml', '**/requirements*.txt', '**/pyproject.toml' },
  },
  {
    category = 'Tests',
    globs = { '**/*_test.go', '**/*.test.*', '**/*.spec.*', '**/*_spec.*', '**/test/**', '**/tests/**', '**/__tests__/**' },
  },
  { category = 'I18n', globs = { '**/locales/**', '**/i18n/**', '**/lang/**' } },
  { category = 'Style', globs = { '**/*.css', '**/*.scss', '**/*.sass', '**/*.less' } },
  { category = 'Docs', globs = { '**/*.md', '**/docs/**' } },
  { category = 'Config', globs = { '**/*.json', '**/*.y*ml', '**/*.toml', '**/.env*' } },
}

local builtin, user = nil, {}

local function compile(glob)
  local ok, pat = pcall(vim.glob.to_lpeg, glob)
  if not ok then
    error(('invalid category glob %s: %s'):format(glob, pat), 0)
  end
  return pat
end

--- Compiles the user rules; they win over the builtins. Errors on an invalid glob.
function M.compile(rules)
  user = {}
  for _, r in ipairs(rules or {}) do
    table.insert(user, { category = r.category, pat = compile(r.glob) })
  end
end

local function builtins()
  if not builtin then
    builtin = {}
    for _, rule in ipairs(M.RULES) do
      for _, glob in ipairs(rule.globs) do
        table.insert(builtin, { category = rule.category, pat = compile(glob) })
      end
    end
  end
  return builtin
end

function M.category(s, path)
  s.category_cache = s.category_cache or {}
  local hit = s.category_cache[path]
  if hit then
    return hit
  end
  local found = 'Source'
  for _, list in ipairs({ user, builtins() }) do
    for _, rule in ipairs(list) do
      if vim.lpeg.match(rule.pat, path) then
        found = rule.category
        goto done
      end
    end
  end
  ::done::
  s.category_cache[path] = found
  return found
end

local function annotations(s, path)
  local c = require('revision.comments').counts(s, path)
  return c.comments + c.findings
end

--- Paths listed in the context order, mapped to their position.
local function order_index(s)
  local idx = {}
  for i, e in ipairs(s.ctx and s.ctx.order or {}) do
    if type(e.path) == 'string' then
      idx[e.path] = i
    end
  end
  return idx
end

function M.reason(s, path)
  for _, e in ipairs(s.ctx and s.ctx.order or {}) do
    if e.path == path then
      return util.nn(e.reason)
    end
  end
end

M.SORTS = { 'path', 'size', 'activity', 'order' }

--- Path text filter; session-only, like yazi's.
M.query = nil

--- View used when no review session is active.
local loose = { sort = 'path', reverse = false, unviewed = false, annotated = false, categories = vim.NIL }

function M.state(s)
  return s and s.review.view or loose
end

local function dir_node(name, path)
  return {
    dir = true,
    name = name,
    path = path,
    children = {},
    map = {},
    size = 0,
    activity = 0,
    order = math.huge,
    changed = 0,
    additions = 0,
    deletions = 0,
  }
end

local KEYS = {
  path = function(n)
    return n.name
  end,
  size = function(n)
    return -n.size
  end,
  activity = function(n)
    return -n.activity
  end,
  order = function(n)
    return n.order
  end,
}

--- Directories first, then by the sort key among siblings; names break ties.
local function comparator(v)
  local key = KEYS[v.sort] or KEYS.path
  return function(a, b)
    if (a.dir or false) ~= (b.dir or false) then
      return a.dir == true
    end
    local ka, kb = key(a), key(b)
    if ka ~= kb then
      if v.reverse then
        return ka > kb
      end
      return ka < kb
    end
    return a.name < b.name
  end
end

--- Compacts single-directory chains and sorts every level.
local function finish(node, cmp)
  node.map = nil
  for i, c in ipairs(node.children) do
    if c.dir then
      while #c.children == 1 and c.children[1].dir do
        local only = c.children[1]
        only.name = c.name .. '/' .. only.name
        c = only
      end
      node.children[i] = c
      finish(c, cmp)
    end
  end
  table.sort(node.children, cmp)
end

--- Tree of { path, e? } entries, where e marks a changed file. Directories carry
--- the sum of their files' size, activity and changes, and the lowest agent order.
--- s is nil outside a review.
function M.tree(s, entries)
  local idx = s and order_index(s) or {}
  local root = dir_node('', '')
  for _, it in ipairs(entries) do
    local e, path = it.e, it.path
    local leaf = {
      path = path,
      e = e,
      size = e and (e.additions + e.deletions) or 0,
      activity = e and annotations(s, e.path) or 0,
      order = idx[path] or math.huge,
    }
    local node, start = root, 1
    while true do
      node.size = node.size + leaf.size
      node.activity = node.activity + leaf.activity
      node.order = math.min(node.order, leaf.order)
      if e then
        node.changed = node.changed + 1
        node.additions = node.additions + e.additions
        node.deletions = node.deletions + e.deletions
      end
      local slash = path:find('/', start, true)
      if not slash then
        leaf.name = path:sub(start)
        table.insert(node.children, leaf)
        break
      end
      local part = path:sub(start, slash - 1)
      local child = node.map[part]
      if not child then
        child = dir_node(part, path:sub(1, slash - 1))
        node.map[part] = child
        table.insert(node.children, child)
      end
      node, start = child, slash + 1
    end
  end
  finish(root, comparator(M.state(s)))
  return root
end

--- Changed files of a tree in display order.
function M.flatten(node, out)
  out = out or {}
  for _, c in ipairs(node.children) do
    if c.dir then
      M.flatten(c, out)
    elseif c.e then
      table.insert(out, c.e)
    end
  end
  return out
end

local function entries(files)
  return vim.tbl_map(function(e)
    return { path = e.path, e = e }
  end, files)
end

--- Smart-case substring match against the path text filter.
function M.match_query(path)
  local q = M.query
  if not q or q == '' then
    return true
  end
  if q:find('%u') then
    return path:find(q, 1, true) ~= nil
  end
  return path:lower():find(q:lower(), 1, true) ~= nil
end

--- Changed files that pass the review filters and the path text filter.
function M.filtered(s)
  local v = s.review.view
  local cats = util.nn(v.categories)
  local wanted = cats and {}
  for _, c in ipairs(cats or {}) do
    wanted[c] = true
  end
  local out = {}
  for _, e in ipairs(s.files) do
    local keep = M.match_query(e.path)
    if keep and v.unviewed and require('revision.viewed').file_viewed(s, e.path) then
      keep = false
    end
    if keep and v.annotated and annotations(s, e.path) == 0 then
      keep = false
    end
    if keep and wanted and not wanted[M.category(s, e.path)] then
      keep = false
    end
    if keep then
      table.insert(out, e)
    end
  end
  return out
end

--- Every changed file, in tree order.
function M.sorted(s)
  return M.flatten(M.tree(s, entries(s.files)))
end

--- Filtered changed files, in tree order.
function M.visible(s)
  return M.flatten(M.tree(s, entries(M.filtered(s))))
end

--- The sort and filter indicators.
function M.indicators(s)
  local v = M.state(s)
  local sort = 'sort: ' .. v.sort .. (v.reverse and ' (rev)' or '')
  local f = {}
  if v.unviewed then
    table.insert(f, 'unviewed')
  end
  if v.annotated then
    table.insert(f, 'annotated')
  end
  local cats = util.nn(v.categories)
  if cats and #cats > 0 then
    table.insert(f, table.concat(cats, '+'))
  end
  if M.query and M.query ~= '' then
    table.insert(f, '"' .. M.query .. '"')
  end
  return sort, 'filter: ' .. (#f > 0 and table.concat(f, ', ') or 'none')
end

function M.describe(s)
  local sort, filter = M.indicators(s)
  return sort .. ' · ' .. filter
end

local function refresh(after)
  require('revision.panel').refresh()
  if after then
    after()
  end
end

local function session()
  return require('revision.session').s
end

function M.set_sort(key, reverse)
  local s = session()
  if key == 'order' and not (s and s.ctx and #s.ctx.order > 0) then
    util.notify('no agent order in context.json')
    return
  end
  local v = M.state(s)
  v.sort, v.reverse = key, reverse
  refresh()
end

--- Categories present in the current range, in display order.
local function present(s)
  local seen, out = {}, {}
  for _, e in ipairs(s.files) do
    local c = M.category(s, e.path)
    if not seen[c] then
      seen[c] = true
      table.insert(out, c)
    end
  end
  local rank = {}
  for i, c in ipairs(M.ORDER) do
    rank[c] = i
  end
  table.sort(out, function(x, y)
    return (rank[x] or #M.ORDER + 1) < (rank[y] or #M.ORDER + 1)
  end)
  return out
end

local function categories_menu(s, after)
  local v = s.review.view
  local items = { 'All' }
  vim.list_extend(items, present(s))
  local selected = {}
  for _, c in ipairs(util.nn(v.categories) or {}) do
    selected[c] = true
  end
  vim.ui.select(items, {
    prompt = 'Categories',
    format_item = function(c)
      return (selected[c] and '● ' or '  ') .. c
    end,
  }, util.guard(function(c)
    if not c then
      return
    end
    if c == 'All' then
      v.categories = vim.NIL
    else
      local list = {}
      for _, x in ipairs(util.nn(v.categories) or {}) do
        if x ~= c then
          table.insert(list, x)
        end
      end
      if not selected[c] then
        table.insert(list, c)
      end
      v.categories = #list > 0 and list or vim.NIL
    end
    refresh(after)
  end))
end

--- Live path text filter: the panel follows each keystroke; <Esc> restores the previous one.
function M.filter_text(after)
  local prev = M.query
  local group = vim.api.nvim_create_augroup('revision_filter_text', { clear = true })
  vim.api.nvim_create_autocmd('CmdlineChanged', {
    group = group,
    pattern = '@',
    callback = function()
      M.query = vim.fn.getcmdline()
      require('revision.panel').refresh()
      vim.cmd.redraw()
    end,
  })
  local ok, q = pcall(vim.fn.input, { prompt = 'Filter: ', default = prev or '', cancelreturn = false })
  vim.api.nvim_del_augroup_by_id(group)
  if not ok or q == false then
    M.query = prev
  else
    M.query = q ~= '' and q or nil
  end
  refresh(after)
end

local function filter_items(s, add, after)
  if s then
    local v = s.review.view
    add(('  Filter: unviewed only [%s]'):format(v.unviewed and 'on' or 'off'), function()
      v.unviewed = not v.unviewed
    end)
    add(('  Filter: annotated only [%s]'):format(v.annotated and 'on' or 'off'), function()
      v.annotated = not v.annotated
    end)
    add('  Filter: categories…', function()
      categories_menu(s, after)
    end, true)
  end
  add('  Filter: path text…', function()
    M.filter_text(after)
  end, true)
  add('  Clear filters', function()
    if s then
      local v = s.review.view
      v.unviewed, v.annotated, v.categories = false, false, vim.NIL
    end
    M.query = nil
  end)
end

local function choose(prompt, items, after)
  vim.ui.select(items, {
    prompt = prompt,
    format_item = function(i)
      return i.text
    end,
  }, util.guard(function(i)
    if not i then
      return
    end
    i.fn()
    if not i.sub then
      refresh(after)
    end
  end))
end

local function collector(items)
  return function(text, fn, sub)
    table.insert(items, { text = text, fn = fn, sub = sub })
  end
end

--- Sort and filter menu. Changes are not marked unsaved; they ride along with the next save.
function M.menu(after)
  local s = session()
  local v = M.state(s)
  local items = {}
  local add = collector(items)
  for _, k in ipairs(M.SORTS) do
    if k ~= 'order' or (s and s.ctx and #s.ctx.order > 0) then
      add((v.sort == k and '● ' or '  ') .. 'Sort: ' .. (k == 'order' and 'agent order' or k), function()
        v.sort = k
      end)
    end
  end
  add(('  Sort: reverse [%s]'):format(v.reverse and 'on' or 'off'), function()
    v.reverse = not v.reverse
  end)
  filter_items(s, add, after)
  choose('Revision view', items, after)
end

function M.filter_menu(after)
  local items = {}
  filter_items(session(), collector(items), after)
  choose('Revision filter', items, after)
end

return M
