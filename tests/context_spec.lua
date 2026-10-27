local h = require('tests.helpers')
local comments = require('revision.comments')
local session = require('revision.session')
local inline = require('revision.inline')

local function virt_text(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, inline.ns_comments, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      table.insert(out, vl[1][1])
    end
  end
  return table.concat(out, '\n')
end

local function qf_text()
  comments.quickfix()
  local out = {}
  for _, item in ipairs(vim.fn.getqflist()) do
    table.insert(out, item.text)
  end
  vim.cmd('cclose')
  return table.concat(out, '\n')
end

--- Writes the body of the comment editor and saves it.
local function write_editor(body)
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.api.nvim_buf_get_name(buf):find('revision://comment/', 1, true), vim.api.nvim_buf_get_name(buf))
  vim.cmd.stopinsert()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { body })
  vim.cmd('write')
end

local function reload(fx, extra)
  h.context(fx, extra)
  session.reload()
end

it('context base and head drive the session', function()
  local fx = h.start({ context = true })
  h.context(fx, { base = fx.c1 })
  session.stop({ force = true })
  fx.s = session.start()
  assert(fx.s.merge_base == fx.c1, tostring(fx.s.merge_base))
  assert(fx.s.range.start == fx.c1, tostring(fx.s.range.start))
end)

it('invalid context.json aborts start', function()
  local fx = h.start({ context = true })
  session.stop({ force = true })
  h.write(fx.wt .. '/.revision/context.json', '{ broken')
  local ok, err = pcall(session.start)
  assert(not ok and err:find('cannot parse'), tostring(err))
  assert(session.s == nil)
end)

it('info without a context file errors', function()
  h.start()
  local ok, err = pcall(session.info)
  assert(not ok and err:find('no context file'), tostring(err))
end)

it('a remote thread renders and can be replied to', function()
  local fx = h.start({ context = true })
  reload(fx, {
    threads = {
      {
        id = 'T1',
        path = 'a.lua',
        side = 'RIGHT',
        line = 3,
        commit = fx.c2,
        resolved = false,
        comments = { { author = 'alice', body = 'why?', created_at = '' } },
      },
    },
  })
  vim.cmd.edit(fx.wt .. '/a.lua')
  local buf = vim.api.nvim_get_current_buf()
  local text = virt_text(buf)
  assert(text:find('@alice', 1, true) and text:find('why?', 1, true), text)

  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  comments.reply()
  write_editor('because')
  local c = fx.s.review.comments[1]
  assert(c and c.reply_to == 'T1' and c.kind == 'comment' and c.commit == fx.c2, vim.inspect(c))
end)

it('a posted comment is hidden and tagged', function()
  local fx = h.start({ context = true })
  comments.commit(fx.s, { path = 'a.lua', side = 'RIGHT', line = 3, kind = 'comment' }, 'posted already')
  session.save()
  reload(fx, {
    threads = {
      {
        id = 'T1',
        path = 'a.lua',
        side = 'RIGHT',
        line = 3,
        commit = fx.c2,
        comments = { { author = 'me', body = 'posted already', local_id = 1 } },
      },
    },
  })
  vim.cmd.edit(fx.wt .. '/a.lua')
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  assert(#comments.at_cursor('own') == 0, 'the posted comment must be hidden')
  assert(comments.counts(fx.s, 'a.lua').comments == 1, 'the thread replaces it in the counts')
  assert(qf_text():find('[posted]', 1, true), qf_text())
end)

it('a posted round clears body and verdict', function()
  local fx = h.start({ context = true })
  vim.api.nvim_buf_set_lines(fx.s.review_buf, 0, -1, false, { 'lgtm' })
  fx.s.review.verdict = 'approve'
  session.save()
  local last = fx.s.review.rounds[#fx.s.review.rounds]
  reload(fx, { posted = { last.saved_at } })
  assert(fx.s.review.body == '', fx.s.review.body)
  assert(fx.s.review.verdict == vim.NIL, tostring(fx.s.review.verdict))
  assert(vim.bo[fx.s.review_buf].modified, 'the cleared body must be unsaved')
end)

it('agent task status shows on the task', function()
  local fx = h.start({ context = true })
  comments.commit(fx.s, { path = 'a.lua', side = 'RIGHT', line = 3, kind = 'task' }, 'rename it')
  reload(fx, { tasks = { { local_id = 1, status = 'done', note = 'fixed' } } })
  vim.cmd.edit(fx.wt .. '/a.lua')
  local text = virt_text(vim.api.nvim_get_current_buf())
  assert(text:find('done · fixed', 1, true), text)
  assert(qf_text():find('[done]', 1, true), qf_text())
end)

it('findings render, accept into a comment, and dismiss', function()
  local fx = h.start({ context = true })
  reload(fx, {
    findings = {
      { id = 'F1', path = 'a.lua', side = 'RIGHT', line = 3, commit = fx.c2, severity = 'major', title = 'magic number', body = 'name it' },
      { id = 'F2', path = 'a.lua', side = 'RIGHT', line = 19, commit = fx.c2, severity = 'nit', title = 'spacing' },
    },
  })
  vim.cmd.edit(fx.wt .. '/a.lua')
  local text = virt_text(vim.api.nvim_get_current_buf())
  assert(text:find('major · magic number', 1, true), text)

  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  comments.accept_finding()
  write_editor('magic number')
  local c = fx.s.review.comments[1]
  assert(c and c.finding == 'F1', vim.inspect(c))
  for _, f in ipairs(comments.findings(fx.s)) do
    assert(f.id ~= 'F1', 'an accepted finding must disappear')
  end

  vim.cmd.edit(fx.wt .. '/a.lua')
  vim.api.nvim_win_set_cursor(0, { 19, 0 })
  comments.dismiss_finding()
  assert(vim.deep_equal(fx.s.review.dismissed_findings, { 'F2' }), vim.inspect(fx.s.review.dismissed_findings))
  assert(vim.bo[fx.s.review_buf].modified)
end)

it('annotation navigation hops between annotations', function()
  local fx = h.start({ context = true })
  comments.commit(fx.s, { path = 'a.lua', side = 'RIGHT', line = 3, kind = 'comment' }, 'here')
  reload(fx, {
    findings = {
      { id = 'F1', path = 'a.lua', side = 'RIGHT', line = 19, commit = fx.c2, severity = 'nit', title = 'spacing' },
    },
  })
  vim.cmd.edit(fx.wt .. '/a.lua')
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  inline.jump_note(1)
  assert(vim.api.nvim_win_get_cursor(0)[1] == 3, tostring(vim.api.nvim_win_get_cursor(0)[1]))
  inline.jump_note(1)
  assert(vim.api.nvim_win_get_cursor(0)[1] == 19, tostring(vim.api.nvim_win_get_cursor(0)[1]))
end)
