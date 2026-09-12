# tmux-sessions.nvim

Every tmux session on your machine, pinned to the top-right of Neovim, each one
a `<leader>N` away.

```
┌──────────────────────────────────────────────────────────────┐
│ init.lua            1 main  2 effective-t…  3 solo  4 pkgs   │
│                                                              │
│ local M = {}                                                 │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

No prefix key, no picker, no lookup. The list is already on screen, so the jump
is one chord.

- **Stable numbers.** Sessions are ordered by creation time, so a new one always
  appends at the end. `<leader>3` is the same session tomorrow.
- **Always visible.** A single floating window, not a statusline segment and not
  a screen row. It never touches your buffers.
- **Quiet.** Refreshes when a switch lands on your pane, plus a slow 5s floor.
  Turn on tmux hooks and an idle machine queries tmux zero times.
- **`<leader>0`** goes back to the session you came from.
- **`<leader>ts`** opens a popup for the full list, untruncated, past nine.

## How it works, and what it is not

`tmux switch-client` moves the whole client, so your Neovim stays behind in the
old session. That makes this a **launcher, not a manager**: every tmux session
runs its own Neovim with its own copy of the plugin, each querying tmux
independently.

It is read-only against tmux apart from `switch-client` and the opt-in hooks.
It will not create, rename or kill sessions — tmux already does that well.

Outside tmux it is completely dormant: no window, no keymap, no timer, no
subprocess.

## Requirements

- Neovim **≥ 0.10**
- tmux **≥ 3.0** (for the `session_created` format field)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "rashedInt32/tmux-sessions.nvim",
  event = "VeryLazy",
  opts = {},
}
```

## Setup

All options with their defaults:

```lua
require("tmux-sessions").setup({
  enabled = true,

  refresh = {
    interval_ms = 5000,   -- background floor; 0 disables the timer
    on_focus = true,      -- re-query when a switch-client lands here
    hooks = false,        -- see "Zero polling" below
    stamp = "/tmp/tmux-sessions.nvim/stamp",
  },

  ghost = {
    enabled = true,
    max_items = 9,        -- past this, the tail collapses to a dim +N
    name_width = 12,      -- truncate longer names with an ellipsis
    hide_in_insert = false,
    winblend = 0,
    row = 0,
    col_offset = 1,       -- cells from the right edge
    zindex = 10,
    format = "%d %s",
    separator = "  ",
  },

  keys = {
    enabled = true,
    prefix = "<leader>",  -- gives <leader>1 .. <leader>9
    last = "<leader>0",
    picker = "<leader>ts",
  },

  highlights = {
    index = "#f5d76e",
    name = "#9f9ca6",
    current = "#7fe08a",  -- the session this nvim lives in
    more = "#6b6772",
  },
})
```

`<leader>` rather than bare digits on purpose: `1`..`9` are vim's count prefix,
and shadowing them breaks `3dd`.

## Commands

| Command | Effect |
|---|---|
| `:TmuxSessions` | Open the popup |
| `:TmuxSessionsRefresh` | Re-query now |
| `:TmuxSessionsToggle` | Show or hide the ghost text |
| `:TmuxSessionsHooksInstall` | Install the tmux hooks |
| `:TmuxSessionsHooksUninstall` | Remove them |
| `:checkhealth tmux-sessions` | tmux version, `$TMUX`, focus-events, hook state |

## Zero polling

By default the plugin queries tmux when your pane regains focus, plus once every
five seconds to notice sessions created elsewhere. That costs about 1.1ms per
query — around 0.02% of one core.

If you want it at exactly zero, let tmux push instead:

```vim
:TmuxSessionsHooksInstall
```

```lua
refresh = { hooks = true }
```

This appends `session-created`, `session-closed` and `client-session-changed`
hooks that touch a stamp file, which every Neovim watches with one `fs_event`.
The timer then turns off entirely. Hooks are appended with `set-hook -ga` and
tagged, so an existing hook of yours on the same event survives, and
`:TmuxSessionsHooksUninstall` removes only ours.

For instant refresh on switch, make sure your `tmux.conf` has:

```tmux
set -g focus-events on
```

`:checkhealth tmux-sessions` will tell you if it doesn't.

## Why a float and not virtual text

Both were benchmarked, and both are free:

| | per update |
|---|---|
| extmark `virt_text`, 1 buffer | 0.0018 ms |
| extmark `virt_text`, 20 buffers | 0.0283 ms |
| **pinned float** | **0.0011 ms** |
| popup, full build | 0.1858 ms |
| `tmux list-sessions` (async spawn) | 1.1118 ms |

So the choice was made on failure modes, not speed. `virt_text_pos =
"right_align"` anchors to a *line*, so it must be re-placed on every scroll,
applied to every buffer, and it collides with any other plugin drawing virtual
text there. A float is O(1) in buffer count, independent of scrolling, and never
modifies a buffer. `winbar` was rejected because it costs a screen row, which is
the thing ghost text exists to avoid.

The one real cost is the subprocess, which is why everything above is about
querying tmux less rather than drawing faster.

## Notes on hostile session names

tmux accepts `;`, `|`, `$()` and spaces in a session name. It rejects tab,
newline and ESC. So:

- Fields come back TAB separated with the name last, because a `|` separator
  splits a session named `ev;il|na me$(x)` into the wrong number of fields.
- Sessions are targeted by `#{session_id}` (always `$<digits>`), never by name.
  With `main` and `main2` both alive, `tmux -t main` resolves by prefix match,
  so a name target is ambiguous.
- Every tmux call is argv, never a shell string, so `$(x)` in a name is inert.

## Pairs with

[claude-sessions.nvim](https://github.com/rashedInt32/claude-sessions.nvim),
which shows every Claude Code agent on your machine in the same palette.

## Development

```sh
make test           # full suite, headless
make test FILTER=ghost
make lint           # stylua --check + luacheck
make fmt
```

No test shells out to tmux; `sessions.spawn` is swapped for a fake that replays
fixture lines.
