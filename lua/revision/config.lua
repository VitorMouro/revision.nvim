local M = {}

M.defaults = {
  remote = 'origin',
  base = nil,
  context_lines = 3,
  keymaps = true,
  categories = {},
  panel_width = 40,
  bg = nil,
  agent = { tool = nil },
}

M.opts = vim.deepcopy(M.defaults)

return M
