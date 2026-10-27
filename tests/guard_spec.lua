local h = require('tests.helpers')
local session = require('revision.session')

it(':qa is refused with E37 while the review is unsaved', function()
  local fx = h.start()
  table.insert(fx.s.review.comments, {
    id = 1,
    path = 'a.lua',
    side = 'RIGHT',
    line = 3,
    start_line = vim.NIL,
    commit = fx.c2,
    body = 'x',
    kind = 'note',
  })
  require('revision.store').touch()
  local ok, err = pcall(vim.cmd, 'qa')
  assert(not ok and err:find('E37'), tostring(err))
  session.save()
  assert(not vim.bo[fx.s.review_buf].modified)
end)

it('stop refuses while unsaved', function()
  h.start()
  require('revision.store').touch()
  local ok, err = pcall(session.stop)
  assert(not ok and err:find('unsaved review'), tostring(err))
end)
