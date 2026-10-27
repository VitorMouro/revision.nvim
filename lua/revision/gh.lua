local util = require('revision.util')

local M = {}

local fields = {
  'number',
  'url',
  'title',
  'baseRefName',
  'baseRefOid',
  'headRefName',
  'headRefOid',
  'isDraft',
  'mergeable',
  'mergeStateStatus',
  'reviewDecision',
  'state',
}

--- Returns the PR table, or nil plus a reason.
function M.pr_view(root)
  if vim.fn.executable('gh') ~= 1 then
    return nil, 'gh not found'
  end
  util.notify('querying gh…')
  local ok, out = pcall(util.run, { 'gh', 'pr', 'view', '--json', table.concat(fields, ',') }, {
    cwd = root,
    timeout = 20000,
  })
  if not ok then
    return nil, out
  end
  local dok, pr = pcall(vim.json.decode, out)
  if not dok or type(pr) ~= 'table' then
    return nil, 'cannot parse gh output'
  end
  return pr
end

return M
