# revision.nvim

Code review inside Neovim. Diff a branch against its base inline, comment on
lines, mark files and hunks as viewed, write the review body and pick a
verdict. The review is saved as JSON, so an external tool or a coding agent can
post it or act on it.

revision.nvim does no remote work. Anything that talks to GitHub or to an agent
goes through two files: it reads `.revision/context.json` (PR description,
existing threads, agent findings, suggested reading order) and writes
`.revision/review.json`. [FORMAT.md](FORMAT.md) is the contract for both.

## Requirements

- Neovim 0.12 (tested on 0.12.6)
- git
- Optional: [sidekick.nvim](https://github.com/folke/sidekick.nvim) for the
  agent actions. Without it, the prompt is copied to the `+` register.

## Install

```lua
vim.pack.add({ 'https://github.com/VitorMouro/revision.nvim' })
require('revision').setup()
```

Defaults:

```lua
require('revision').setup({
  remote = 'origin',
  base = nil,          -- base ref; nil uses <remote>/HEAD, context.json overrides it
  context_lines = 3,
  keymaps = true,      -- false to bind your own
  categories = {},     -- labels for grouping files in the panel
  panel_width = 40,
  agent = { tool = nil }, -- sidekick tool name
})
```

## Use

`:Revision` starts a session for the current branch. Subcommands:

| command | what it does |
|---|---|
| `start` | open a review session (default) |
| `panel` / `files` | file panel / file picker |
| `view` | sort and filter files |
| `range` / `commits` | review a commit range or single commits |
| `body` / `verdict` | edit the review body / pick approve, request changes or comment |
| `comments` | all annotations in the quickfix list |
| `save` / `discard` / `delete` | save review.json / drop unsaved changes / delete the review |
| `reload` | re-read context.json |
| `tasks` | send task comments to the agent |
| `info` / `stop` | session info / end the session |

There are three kinds of annotation, cycled with `<leader>rp`:

- `comment` is meant to be posted on the PR.
- `note` is private and never posted.
- `task` is a fix for the agent to make locally, never posted.

Findings that an agent writes into context.json show inline by severity and
can be accepted into a comment or dismissed.

### Keymaps

Global, under `<leader>r`: `f` panel, `o` files, `v` view, `r` range, `k`
commits, `s` save, `b` body, `V` verdict, `q` quickfix, `i` info, `t` toggle
comment display, `l` reload, `T` send tasks.

In a review buffer:

| key | action |
|---|---|
| `<leader>rc` | comment on line or selection |
| `<leader>rd` | comment on deleted lines |
| `<leader>re` / `rx` | edit / delete comment |
| `<leader>rR` | reply to a thread |
| `<leader>ry` / `rn` | accept / dismiss a finding |
| `<leader>ra` | ask the agent about the line or selection |
| `<leader>rm` / `rh` | toggle file / hunk viewed |
| `<leader>rE` | make the buffer editable |
| `]c` `[c` | next / previous hunk |
| `]n` `[n` | next / previous annotation |
| `]f` `[f` `]u` | next / previous / next unviewed file |

## Tests

```sh
nvim --headless --clean --cmd 'set rtp^=.' -l tests/run.lua
```
