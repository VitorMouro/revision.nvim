local M = {}

function M.notify(msg, level)
  vim.notify('revision: ' .. msg, level or vim.log.levels.INFO)
end

function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

function M.err(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

--- Runs argv; returns stdout. Errors with the first stderr line unless opts.allow_fail.
function M.run(argv, opts)
  opts = opts or {}
  local ok, obj = pcall(function()
    return vim.system(argv, { cwd = opts.cwd, text = true }):wait(opts.timeout or 10000)
  end)
  if not ok then
    if opts.allow_fail then
      return nil
    end
    error(argv[1] .. ': ' .. tostring(obj), 0)
  end
  if obj.code ~= 0 then
    if opts.allow_fail then
      return nil, obj
    end
    local line = (obj.stderr or ''):match('[^\n]+')
    if obj.code == 124 and obj.signal ~= 0 then
      line = argv[1] .. ' ' .. (argv[2] or '') .. ' timed out'
    end
    error(line or (table.concat(argv, ' ') .. ': exit ' .. obj.code), 0)
  end
  return obj.stdout, obj
end

function M.trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Splits file text into lines, dropping the empty element after a final newline.
function M.lines(text)
  if text == '' then
    return {}
  end
  local l = vim.split(text, '\n', { plain = true })
  if l[#l] == '' then
    l[#l] = nil
  end
  return l
end

function M.nn(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

function M.short(sha)
  return sha and sha:sub(1, 7) or '-------'
end

function M.now()
  return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

--- Wraps fn so errors become notifications instead of stack traces.
function M.guard(fn)
  return function(...)
    local ok, e = pcall(fn, ...)
    if not ok then
      M.err(tostring(e))
    end
  end
end

return M
