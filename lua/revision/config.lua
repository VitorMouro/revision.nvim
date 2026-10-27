local M = {}

M.defaults = { remote = 'origin', base = nil, context_lines = 3, keymaps = true }

M.opts = vim.deepcopy(M.defaults)

return M
