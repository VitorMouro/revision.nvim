# revision.nvim

A diff viewer for Neovim. Changes show inline in the real file buffers: added
and changed lines highlighted, deleted lines as virtual lines, word-level
highlights inside changed lines. Diff the working tree, a branch against its
base, single commits or any range, browse the changed files in a tree, and
mark files and hunks as viewed.

## Requirements

- Neovim 0.12 (tested on 0.12.6)
- git
- [ripgrep](https://github.com/BurntSushi/ripgrep) for `<leader>rs`
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
  for the pickers; without it they fall back to `vim.ui.select`.
- Optional: [sidekick.nvim](https://github.com/folke/sidekick.nvim) for
  asking an agent about a line. Without it, the prompt is copied to the `+`
  register.

## Install

```lua
vim.pack.add({ 'https://github.com/VitorMouro/revision.nvim' })
require('revision').setup()
```

Defaults:

```lua
require('revision').setup({
  remote = 'origin',
  base = nil,          -- base ref; nil uses <remote>/HEAD
  context_lines = 3,
  keymaps = true,      -- false to bind your own
  categories = {},     -- {glob, category} rules for the category filter
  panel_width = 40,
  bg = nil,            -- editor bg for fading the diff tints when Normal has none (transparent themes)
  agent = { tool = nil }, -- sidekick tool name
})
```

## Use

`:Revision` starts a session on the default range: working changes when the
tree is dirty, else unpushed commits, else the branch against its base. The
default range never moves `HEAD`. While a session runs, every file of the repo
you open shows its diff inline; `:Revision stop` (`<leader>rx`) ends it and
restores the windows. Opening the panel or any picker starts one.

`:Revision <rev>` diffs a revision like `git diff` does:

| argument | diff |
|---|---|
| `main...HEAD` | merge base of the two against `HEAD` |
| `HEAD~3..HEAD`, `HEAD~3..` | `HEAD~3` against `HEAD` |
| `HEAD~3`, `abc123` | that commit against the working tree |

An empty side means `HEAD`, and `HEAD` is the branch the session started on.
A range whose end is not the working tree checks that commit out (detached),
so buffers are real files with LSP; it refuses while the tree has uncommitted
changes, and the branch is restored when the session stops or Neovim exits.
If Neovim dies while detached, the branch is restored on the next start in
that repo (unless you moved `HEAD` yourself or have uncommitted changes).
Another Neovim on the same repo leaves a running session's checkout alone.

`require('revision').status()` returns e.g. `rev: working abc1234..worktree`
while a session runs, nil otherwise, for a statusline.

Subcommands:

| command | what it does |
|---|---|
| `start` | start a session (default) |
| `panel` / `files` | file panel / file picker |
| `view` | sort and filter files |
| `range` / `commits` | pick a range / commit list |
| `stop` | end the session |

Viewed marks are saved per repository and branch under
`stdpath('state')/revision/`. A file mark clears when the file changes again.

### File panel

`:Revision panel` (`<leader>rf`) opens a file tree of the changed files and
focuses it, starting a session if needed; it is empty when nothing changed.
`.` adds the rest of the repo, with unchanged directories folded. Outside git
there is no session: the panel starts empty and `.` lists the current
directory. Directories fold with the
usual `z` commands.

The winbar shows the sort and the filter. Sort keys follow yazi: `,p` path,
`,s` size, and the uppercase key reverses. Directories come first and sort by
the sum of their files. `f` filters by path as you type (smart-case, `<Esc>`
restores the previous filter), `F` opens the filter menu (unviewed,
categories). `]f` / `[f` and the picker follow the same order and filters, over
changed files only. `?` lists the panel keys.

### Keymaps

Global, under `<leader>r`: `f` panel, `o` files, `v` view, `r` range, `k`
commits, `x` stop the session, `s` search changed lines with ripgrep (regex, live), `z` fuzzy search
changed lines. Both cover added and deleted lines; picking a deleted line jumps
to where it was removed.

In a diffed buffer:

| key | action |
|---|---|
| `<leader>ra` | ask the agent about the line or selection |
| `<leader>rm` / `rh` | toggle file / hunk viewed |
| `<leader>rE` | make the buffer editable |
| `]c` `[c` | next / previous hunk |
| `]f` `[f` `]u` | next / previous / next unviewed file |

## Tests

```sh
nvim --headless --clean --cmd 'set rtp^=.' -l tests/run.lua
```
