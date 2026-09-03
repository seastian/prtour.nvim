# prtour.nvim

Review pull requests — and local, not-yet-pushed changes — as a **guided tour** inside Neovim.

Instead of walking a PR file-by-file in alphabetical order, prtour asks Claude Code to order the diff's hunks into a reading narrative (types first, then logic, then call sites, mechanical churn last), and walks you through it one keypress at a time. You read real buffers from your working tree, so LSP — go-to-definition, references, diagnostics — works everywhere. Comments go to GitHub as a proper review; on local changes they go back to the Claude session that wrote the code.

## The whole interface is one key

`\`

- **Outside a tour** it opens the launcher: resume an unfinished review, pick an open PR, or review local changes.
- **Inside a tour** it opens a context menu showing only the actions that apply where your cursor is.

During a tour: **Enter** = next hunk, **Backspace** = previous hunk. That's everything you need to remember.

## Features

- **Narrative ordering** — hunks grouped into titled steps with reviewer notes ("this is the guard that browser and server agree — check the exclusions"), generated once per diff and cached.
- **Real buffers, real LSP** — changes render inline via gitsigns (deleted lines as virtual text, word-level diffs). One key toggles a side-by-side vimdiff for heavy rewrites.
- **GitHub review flow** — read existing threads inline, reply, comment on lines/ranges, edit or delete your own comments, save work-in-progress to a pending review as you go, submit with a verdict. Per-file viewed state syncs both ways.
- **Local mode** — review what your AI agent (or you) just changed, before any commit or PR exists. Untracked files included. Queued comments batch into one message fired at a Claude Code tmux pane.
- **Content-addressed progress** — "seen" is tracked by a hash of each hunk's content, not line positions. Rebases, force-pushes and unrelated edits don't reset your progress; only hunks that actually changed come back unread.
- **Ask Claude mid-review** — question the hunk under your cursor and get an answer in a float, or fire a change request at a running Claude Code session and keep reading.
- **The small stuff that adds up** — PR description in a float, CI status in the picker (✓/✗/●), `]u` to jump to the frontier of unseen hunks, refresh-in-place after your agent pushes more changes (comments survive), Claude-drafted review summaries you edit before submitting, and a warning when the diff touches a lockfile so you know to reinstall for accurate LSP.

## Requirements

- Neovim ≥ 0.10
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) — inline diff rendering
- [fzf-lua](https://github.com/ibhagwan/fzf-lua) — PR picker
- [`gh`](https://cli.github.com/) authenticated — all GitHub interaction
- [Claude Code](https://claude.com/claude-code) CLI — optional; without it, tours fall back to file order and the ask/handoff actions are unavailable
- tmux — optional; only for handing change requests to a running Claude Code pane
- [fidget.nvim](https://github.com/j-hui/fidget.nvim) — optional; nicer progress display

## Install

lazy.nvim:

```lua
{
  'seastian/prtour.nvim',
  keys = {
    { '\\', function() require('prtour').launcher() end, desc = 'PR tour: launcher / actions' },
  },
  opts = {},
}
```

## Usage

Press `\` and pick. Or use the commands directly:

| Command | What it does |
| --- | --- |
| `:PrTour` | pick an open PR, check it out, start the tour |
| `:PrTour 1234` | tour a specific PR |
| `:PrTour local` | tour uncommitted changes (working tree vs `HEAD`) |
| `:PrTour local master` | tour the whole branch + working tree vs the merge-base |
| `:PrTourStop` | end the tour (prompts about unsubmitted comments) |
| `:PrTourSubmit [comment\|approve\|request-changes\|pending]` | submit queued comments as one review |

During a tour, direct chords exist for everything in the `\` menu and are shown next to each menu entry: `<leader>gc` comment, `<leader>ge` edit/delete your comment, `<leader>gr` reply, `<leader>gd` toggle split diff, `<leader>go` step outline, `<leader>gq` quit. Learn them by osmosis or never — the menu always works.

If the PR's branch is checked out in another worktree, prtour reviews its head detached, so a dedicated review worktree works well:

```sh
git worktree add ../review master
```

## Configuration

Defaults:

```lua
require('prtour').setup {
  -- Diff base; nil resolves the repo's default branch.
  base = nil,
  -- Flip GitHub's per-file "Viewed" checkbox as you exhaust files.
  mark_viewed = true,
  -- Headless Claude invocation (instructions are appended).
  claude_cmd = { 'claude', '-p' },
  -- Models per task; nil uses your CLI default.
  models = {
    manifest = 'claude-sonnet-5',
    ask = 'claude-sonnet-5',
  },
}
```

Highlights: the HUD defines `PrtourTitle`, `PrtourKicker`, `PrtourDim`, `PrtourKey`, `PrtourNext`, `PrtourAdded`, `PrtourRemoved`, derived from your colorscheme — override them after `setup` if you want different accents.

## How it works

1. The diff (PR merge-base three-dot, or working tree) is parsed into hunks; untracked files are synthesized as all-added hunks in local mode.
2. Claude Code receives the hunk bodies on stdin and returns ordered steps as JSON; the result is validated (every hunk exactly once, stragglers collected into a visible final step) and cached under `~/.cache/nvim/prtour/` keyed by diff content.
3. The tour repoints gitsigns at the base revision and walks the manifest. Progress persists on every jump; hunks are identified by `sha256(path + hunk body)`, so seen-state survives anything that doesn't change the hunk itself.
4. GitHub writes go through `gh`: comments accumulate into your single pending review (GraphQL — repeated saves append), and a final submit attaches the verdict.

## Tests

The pure modules (no `vim.*`, no IO) run without a Neovim. From the repo root:

```sh
luajit tests/run.lua
```

The runner discovers every `tests/*_spec.lua`, so new pure modules are tested by dropping a spec beside the existing ones.

## Status

Built for my own workflow and shaped by using it on real PRs. Expect sharp edges; issues and PRs welcome.
