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

function M.sorted(s)
  local list = vim.list_slice(s.files)
  local sort = s.review.view.sort
  local by_path = function(x, y)
    return x.path < y.path
  end
  if sort == 'category' then
    local rank = {}
    for i, c in ipairs(M.ORDER) do
      rank[c] = i
    end
    table.sort(list, function(x, y)
      local a, b = rank[M.category(s, x.path)] or #M.ORDER + 1, rank[M.category(s, y.path)] or #M.ORDER + 1
      if a ~= b then
        return a < b
      end
      return x.path < y.path
    end)
  elseif sort == 'size' then
    table.sort(list, function(x, y)
      local a, b = x.additions + x.deletions, y.additions + y.deletions
      if a ~= b then
        return a > b
      end
      return x.path < y.path
    end)
  elseif sort == 'activity' then
    local n = {}
    for _, e in ipairs(list) do
      n[e.path] = annotations(s, e.path)
    end
    table.sort(list, function(x, y)
      if n[x.path] ~= n[y.path] then
        return n[x.path] > n[y.path]
      end
      return x.path < y.path
    end)
  elseif sort == 'order' then
    local idx = order_index(s)
    table.sort(list, function(x, y)
      local a, b = idx[x.path], idx[y.path]
      if a and b and a ~= b then
        return a < b
      end
      if a ~= b then
        return a ~= nil
      end
      return x.path < y.path
    end)
  else
    table.sort(list, by_path)
  end
  return list
end

function M.visible(s)
  local v = s.review.view
  local cats = util.nn(v.categories)
  local wanted = cats and {}
  for _, c in ipairs(cats or {}) do
    wanted[c] = true
  end
  local out = {}
  for _, e in ipairs(M.sorted(s)) do
    local keep = true
    if v.unviewed and require('revision.viewed').file_viewed(s, e.path) then
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

function M.describe(s)
  local v = s.review.view
  local text = 'sort:' .. v.sort
  if v.unviewed then
    text = text .. ' · unviewed'
  end
  if v.annotated then
    text = text .. ' · annotated'
  end
  local cats = util.nn(v.categories)
  if cats and #cats > 0 then
    text = text .. ' · ' .. table.concat(cats, ',')
  end
  return text
end

local function refresh(after)
  require('revision.panel').refresh()
  if after then
    after()
  end
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

--- Sort and filter menu. Changes are not marked unsaved; they ride along with the next save.
function M.menu(after)
  local s = require('revision.session').s
  local v = s.review.view
  local items = {}
  local function add(text, fn, sub)
    table.insert(items, { text = text, fn = fn, sub = sub })
  end
  for _, k in ipairs({ 'category', 'path', 'size', 'activity' }) do
    add((v.sort == k and '● ' or '  ') .. 'Sort: ' .. k, function()
      v.sort = k
    end)
  end
  if s.ctx and #s.ctx.order > 0 then
    add((v.sort == 'order' and '● ' or '  ') .. 'Sort: agent order', function()
      v.sort = 'order'
    end)
  end
  add(('  Filter: unviewed only [%s]'):format(v.unviewed and 'on' or 'off'), function()
    v.unviewed = not v.unviewed
  end)
  add(('  Filter: annotated only [%s]'):format(v.annotated and 'on' or 'off'), function()
    v.annotated = not v.annotated
  end)
  add('  Filter: categories…', function()
    categories_menu(s, after)
  end, true)
  add('  Clear filters', function()
    v.unviewed, v.annotated, v.categories = false, false, vim.NIL
  end)
  vim.ui.select(items, {
    prompt = 'Revision view',
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

return M
