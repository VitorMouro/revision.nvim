# revision.nvim file contract

revision.nvim does no remote work. An external tool or agent writes the review
context into `<root>/.revision/context.json`, and reads the review back from
`<root>/.revision/review.json`.

## Review directory

`<root>/.revision` resolves at session start:

1. If it is a symlink, its `realpath` is the review directory.
2. If it is a real directory, it is used as is.
3. If it is absent, revision creates
   `<stdpath('data')>/revision/<repo>/<key>/` and symlinks `<root>/.revision`
   to it. `<key>` is `branch-<branch with [^%w._-] replaced by _>`, or
   `head-<first 12 chars of head>` when detached.
4. If it exists but is neither, revision errors.

In every case the line `/.revision` is in `<git common dir>/info/exclude`
exactly once.

## `review.json`

Written only by revision, atomically (tmp + rename), so it is safe to read at
any time. `version` is `2`. Keys:

- `version`, `repo`, `branch`, `base_ref`, `head`, `merge_base`
- `verdict`: `"approve" | "request_changes" | "comment" | null`
- `body`
- `comments`
- `viewed_files`, `viewed_hunks`
- `rounds`: `[{head, saved_at}]`
- `next_id`
- `dismissed_findings`: sorted list of finding ids
- `reviewed_commits`: sorted list of shas
- `view`: `{sort, reverse, unviewed, annotated, categories}`
  - `sort` is `"path" | "size" | "activity" | "order"`; any other value loads
    as `"path"`
  - `reverse`, `unviewed` and `annotated` are bools
  - `categories` is a list of category labels, or null (null means all)

A comment is:

```
{id:int, kind:"comment"|"note"|"task", path, side:"RIGHT"|"LEFT", start_line:int|null, line:int,
 commit:sha|null, worktree:bool, body, reply_to:string|null, finding:string|null, created_at, updated_at}
```

`worktree = true` (with `commit = null`) only for notes and tasks written while
reviewing working changes. Unknown top-level keys are preserved across load and
save.

## `context.json`

Written by the tool or agent, never by revision; it should be written
atomically too (tmp + rename). `version` is `1`. Every key except `version` is
optional:

```json
{
  "version": 1,
  "title": "…", "url": "…", "description": "markdown",
  "base": "sha", "base_ref": "main", "head": "sha",
  "meta": [{"label": "mergeable", "value": "MERGEABLE"}],
  "reviews": [{"author": "x", "state": "APPROVED", "body": "…", "submitted_at": "iso"}],
  "threads": [{"id": "T1", "path": "a.lua", "side": "RIGHT", "start_line": null, "line": 3, "commit": "sha",
               "resolved": false, "comments": [{"author": "x", "body": "…", "created_at": "iso", "local_id": null}]}],
  "findings": [{"id": "F1", "path": "a.lua", "side": "RIGHT", "start_line": null, "line": 3, "commit": "sha",
                "severity": "blocking|major|minor|nit|info", "title": "…", "body": "…", "source": "omp"}],
  "order": [{"path": "a.lua", "reason": "core change, read first"}],
  "tasks": [{"local_id": 4, "status": "done|wontfix", "note": "…"}],
  "posted": ["<saved_at of a review.json round that was submitted>"]
}
```

Threads and findings need `id`, `path`, `side`, a numeric `line` and a
`commit`; entries that do not are skipped with a warning.

revision reads `context.json` only at session start and on `:Revision reload`
(`<leader>rl`), so tell the user to reload after writing it.

## Handoff rules

- `note` comments are never posted.
- `task` comments are for the agent to fix locally, and are never posted.
- A `comment` with `reply_to` is posted as a reply to that thread.
- After posting a comment, the tool lists it in a thread comment with
  `local_id = <comment id>`. Revision hides own comments whose id appears as
  any `local_id`, and the tool must not post them again.
- After submitting the body and verdict, the tool appends `rounds[-1].saved_at`
  to `posted`.
- After working on a task, the agent writes `{local_id, status, note}` into
  `tasks`.
