local M = {}

local links = {
  RevisionCurrent = 'Visual',
  RevisionViewed = 'Comment',
  RevisionUnchanged = 'Comment',
}

--- Diff tints: the theme's Diff* groups with their background faded toward the editor's,
--- so syntax colours (comments especially) keep their contrast on changed lines.
local tints = {
  RevisionAdd = 'DiffAdd',
  RevisionChange = 'DiffChange',
  RevisionDelete = 'DiffDelete',
  RevisionText = 'DiffText',
  RevisionTextAdd = 'DiffTextAdd',
}

--- Share of the Diff* background kept in the blend.
local STRENGTH = 0.4

local function blend(fg, bg, t)
  local out = 0
  for shift = 16, 0, -8 do
    local a, b = bit.band(bit.rshift(fg, shift), 0xff), bit.band(bit.rshift(bg, shift), 0xff)
    out = out + bit.lshift(math.floor(a * t + b * (1 - t) + 0.5), shift)
  end
  return out
end

--- Editor background: Normal's, else the bg option, else black or white by 'background'.
local function editor_bg()
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg
  if normal then
    return normal
  end
  local opt = require('revision.config').opts.bg
  if opt then
    return vim.api.nvim_get_color_by_name(opt)
  end
  return vim.o.background == 'light' and 0xffffff or 0x000000
end

function M.define_highlights()
  for group, link in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  local bg = editor_bg()
  for group, source in pairs(tints) do
    local hl = vim.api.nvim_get_hl(0, { name = source, link = false })
    if hl.bg then
      hl.bg = blend(hl.bg, bg, STRENGTH)
      hl.default = true
      vim.api.nvim_set_hl(0, group, hl)
    else
      vim.api.nvim_set_hl(0, group, { link = source, default = true })
    end
  end
end

function M.setup(opts)
  local config = require('revision.config')
  config.opts = vim.tbl_deep_extend('force', vim.deepcopy(config.defaults), opts or {})
  require('revision.view').compile(config.opts.categories)
  M.define_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('revision_hl', {}),
    callback = M.define_highlights,
  })
  if config.opts.keymaps then
    require('revision.keys').global()
  end
  vim.schedule(function()
    require('revision.range').recover(vim.fn.getcwd())
  end)
end

--- Short session description for a statusline, or nil without a session.
function M.status()
  local s = require('revision.session').s
  if s and s.range then
    return 'rev: ' .. require('revision.range').describe(s.range)
  end
end

return M
