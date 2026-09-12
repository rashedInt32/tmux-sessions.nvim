# tmux-sessions.nvim — Specification

Status: draft, awaiting approval
Date: 2026-09-12
Verified against: tmux 3.7c, Neovim ≥ 0.10, macOS (darwin 24.6.0)

---

## 1. Objective

Every tmux session on the machine, always visible in the top-right of Neovim,
each bound to a `<leader>N` key that jumps straight to it.

Today switching tmux sessions means leaving the editor, hitting the tmux prefix,
and reading a picker. This removes all three steps. The list is already on
screen, so the jump is one chord with no lookup.

### Target user

One person: a developer who runs one tmux session per project and one Neovim
per session. Not a general-purpose session manager. No multi-user concerns.

### The constraint that shapes the design

`tmux switch-client` moves the whole client. Your Neovim instance stays behind
in the old session. So this plugin is a **launcher, not a manager**. Every tmux
session runs its own Neovim with its own copy of the plugin. Each instance
queries tmux independently and holds no shared state.

That is why always-visible ghost text wins over a popup. The list must be
readable without a keystroke, because the keystroke is the thing being replaced.

### Non-goals

- Creating, renaming, or killing sessions. tmux already does this well.
- Window or pane level navigation. Session granularity only.
- Working outside tmux. Without `$TMUX` the plugin stays fully dormant.
- Replacing the tmux status bar.

---

## 2. Measured basis for the design

Benchmarked on this machine, Neovim headless, 2000-line buffers.

| Operation | Cost |
|---|---|
| Ghost text via extmark, 1 buffer | 0.0018 ms |
| Ghost text via extmark, 20 buffers | 0.0283 ms |
| Ghost text via pinned float, update | 0.0011 ms |
| Popup open, buffer + window + keymaps | 0.1858 ms |
| `tmux list-sessions` via `vim.system`, main-loop cost | 1.1118 ms |
| `tmux list-sessions` via `vim.fn.systemlist`, blocking | 3.5353 ms |

**Finding.** The subprocess spawn costs 60x the most expensive render. Popup
versus ghost text is a rounding error; both are far under one frame at 60fps.

**Consequence.** The design lever is refresh frequency, not draw method. Every
decision below optimizes the number of `tmux` spawns. Render freely.

**Second consequence.** Never call tmux synchronously. `vim.fn.system` blocks
the UI for 3.5 ms, and that is 3.5 ms of dropped input. `vim.system` with a
callback still costs 1.1 ms on the main loop to spawn, so spawns stay rare.

---

## 3. Capability map

Six modules. Arrows point from dependency to dependent. Build in listed order.

```
config ──┬──> sessions ──┬──> switch ──> keys
         │               │
         │               └──> ghost
         │
         └──> health          watch ──> (refresh: sessions -> keys, ghost)
```

| # | Module | Responsibility | Depends on | Independently testable |
|---|---|---|---|---|
| M1 | `config` | Defaults, `setup()` merge, LuaLS annotations | — | Yes |
| M2 | `sessions` | Spawn tmux, parse, assign stable indices | M1 | Yes, with a fake spawn |
| M3 | `switch` | `switch-client` by session id, last-session | M1 | Yes, with a fake spawn |
| M4 | `keys` | Bind and rebind `<leader>N` to current indices | M2, M3 | Yes |
| M5 | `ghost` | Pinned top-right float, render and reposition | M1, M2 | Yes |
| M6 | `watch` | Decide when to refresh, drive M4 and M5 | M2 | Yes |
| M7 | `health` | `:checkhealth` for tmux, version, `$TMUX` | M1 | Yes |

`init.lua` wires them. `plugin/tmux-sessions.lua` is a stub, matching
claude-sessions.nvim's eight-line plugin file.

---

## 4. Core decisions

### 4.1 Index model: creation order, stable

Sort by `#{session_created}` ascending. Index is position in that sort.

A new session always has the newest timestamp, so it always appends at the end.
Indices 1..N never shift when a session is created. Muscle memory holds.

Alphabetical sorting was rejected: creating a session named `api` renumbers
every session after it, which breaks the one property that makes fixed
keybindings worth having.

Killing a session does renumber everything below it. This is accepted. Killing
is rare and deliberate, unlike creating.

Sessions past index 9 get no keybinding. They still render in the ghost text
with a dim `+N` overflow marker, matching claude-sessions.nvim's `max_dots`
behavior.

### 4.2 Target sessions by id, never by name

**Verified on tmux 3.7c:** with sessions `main` and `main2` present,
`tmux display-message -t main` resolves to `main`. Prefix matching makes
name targets ambiguous in general, and the `=name` exact form returned empty
in testing.

`#{session_id}` is unambiguous, stable for the session's lifetime, and always
matches `^%$%d+$`. Verified that `has-session -t '$30'` and
`switch-client -t '$30'` both work.

So: **session id is the target, name is display only.** This removes the entire
class of name-based ambiguity and injection in one decision.

### 4.3 Field separator: TAB

Verified what tmux accepts in a session name:

| Character | Accepted? |
|---|---|
| `\|` `;` `$( )` space | **Yes** |
| tab | No, `invalid session name` |
| newline | No, `invalid session name` |
| ESC `\033` | No, `invalid session name` |

A `\|` separator is therefore unsafe. A real session named `ev;il\|na me$(x)`
was created successfully and split a `\|`-delimited line into three fields.

TAB is safe because tmux rejects it in names. Format string:

```
#{session_id}\t#{session_created}\t#{session_attached}\t#{session_windows}\t#{session_name}
```

The only variable-length, user-controlled field is `session_name`, and it is
last. Parse with `line:match("^(%S+)\t(%d+)\t(%d+)\t(%d+)\t(.*)$")`.

### 4.4 Ghost text: one pinned float window

A single `nvim_open_win` with `relative = "editor"`, `row = 0`, right-aligned
by column, `style = "minimal"`, `focusable = false`, `zindex = 10`.

Chosen over per-buffer extmarks because it is O(1) in buffer count, survives
scrolling with no re-anchoring, never modifies a user buffer, and cannot
collide with another plugin's `virt_text` on the same line. Extmark
`right_align` anchors to a *line*, so it needs re-placing on every
`WinScrolled` and applying to every buffer.

Chosen over `winbar` because winbar consumes a screen row, which is exactly
what ghost text exists to avoid.

**Known risks, to be handled in implementation:**

- The float overlaps buffer text in the top-right corner. Mitigate with
  `winblend` and a config option to hide while in insert mode.
- It must hide when it would cover a floating window with higher zindex, and
  when `vim.o.columns` is too narrow to fit the label.
- It must be excluded from `:windo`, `<C-w>` cycling, and session save. Set
  `focusable = false` and mark the buffer `buftype = "nofile"`, `bufhidden =
  "wipe"`, plus a `win` local flag other plugins can filter on.
- Reposition on `VimResized`.

### 4.5 Keybindings: global `<leader>1`..`<leader>9`

Global normal-mode maps, rebound whenever the session list changes.

`<leader>` prefix rather than bare numbers, because bare `1`..`9` shadow vim's
count prefix and would break `3dd`. `<leader>0` maps to
`tmux switch-client -l` for last-session toggle, verified working.

Rebinding deletes maps for indices that no longer exist, so a stale
`<leader>7` never jumps to a dead session.

Every key, prefix, and the whole feature are configurable and disableable.

### 4.6 Refresh strategy: event-driven, with a slow floor

Given 1.1 ms per spawn, the goal is to spawn rarely.

**Default (non-invasive):**

1. `FocusGained` — fires when a tmux `switch-client` lands on this pane. This
   is the moment the list matters most, and it costs nothing at rest.
   claude-sessions.nvim's `repaint.lua` already relies on this behavior.
2. After the plugin's own `switch()` call completes.
3. A slow background `uv` timer, default 5000 ms, for sessions created in
   another pane. At 1.1 ms per spawn this is 0.02% of one core.
4. On `VimResized`, reposition only. No spawn.

**Opt-in (zero polling at rest):** `watch.hooks = true` installs tmux hooks.
Verified available on 3.7c: `session-created`, `session-closed`,
`client-session-changed`.

Each hook runs `run-shell` to touch a stamp file. Every Neovim watches that one
path with `uv.fs_event` and re-queries only on change. The background timer
drops to 0 when hooks are active.

Hooks are opt-in because they mutate global tmux state. They must be installed
with `set-hook -ga` (append, verified that hooks are arrays indexed
`session-created[0]`), tagged so they are identifiable, and removed by
`:TmuxSessionsHooksUninstall`. The plugin must never clobber an existing hook.

### 4.7 Both UIs, ghost text first

Ghost text is the primary surface and the default. A popup ships too, since the
data source and render are already built and the popup costs 0.19 ms.

The popup handles what ghost text cannot: sessions past index 9, full untruncated
names, and window counts. Opened with `<leader>ts`, bound buffer-locally to
`1`..`9` plus `j`/`k`/`<CR>`/`q`.

Both read the same cached session list. Neither triggers its own spawn.

---

## 5. Commands and public API

```lua
require("tmux-sessions").setup({})   -- wire everything
require("tmux-sessions").switch(n)   -- jump to index n
require("tmux-sessions").last()      -- switch-client -l
require("tmux-sessions").pick()      -- open popup
require("tmux-sessions").refresh()   -- force a re-query
require("tmux-sessions").list()      -- cached session list, for statuslines
require("tmux-sessions").lualine()   -- ready-made component, mirrors claude-sessions
```

| Command | Effect |
|---|---|
| `:TmuxSessions` | Open the popup |
| `:TmuxSessionsRefresh` | Force re-query now |
| `:TmuxSessionsToggle` | Show or hide the ghost text |
| `:TmuxSessionsHooksInstall` | Install the tmux hooks |
| `:TmuxSessionsHooksUninstall` | Remove them |
| `:checkhealth tmux-sessions` | tmux present, version, `$TMUX` set, hook state |

### Configuration defaults

```lua
{
  enabled = true,              -- false, or no $TMUX, means fully dormant

  refresh = {
    interval_ms = 5000,        -- background floor; 0 disables
    on_focus = true,           -- FocusGained
    hooks = false,             -- opt-in tmux hooks, sets interval_ms to 0
    stamp = "/tmp/tmux-sessions.nvim/stamp",
  },

  ghost = {
    enabled = true,
    max_items = 9,             -- past this, collapse to a dim +N
    name_width = 12,           -- truncate longer names with an ellipsis
    hide_in_insert = false,
    winblend = 0,
    row = 0,
    col_offset = 1,            -- cells from the right edge
    zindex = 10,
    format = "%d %s",          -- index, truncated name
    separator = "  ",
  },

  keys = {
    enabled = true,
    prefix = "<leader>",       -- so <leader>1 .. <leader>9
    last = "<leader>0",
    picker = "<leader>ts",
  },

  highlights = {
    index   = "#f5d76e",       -- the number
    name    = "#9f9ca6",       -- the session name
    current = "#7fe08a",       -- session this nvim lives in
    more    = "#6b6772",       -- the +N overflow marker
  },
}
```

Colors follow claude-sessions.nvim's palette so the two plugins read as one
system on screen.

---

## 6. Project structure

```
tmux-sessions.nvim/
  SPEC.md
  README.md
  plugin/tmux-sessions.lua        -- guard + user commands, ~10 lines
  lua/tmux-sessions/
    init.lua                      -- public API, setup(), lazy requires
    config.lua                    -- defaults + LuaLS classes
    sessions.lua                  -- M2: spawn, parse, index
    switch.lua                    -- M3: switch-client by id
    keys.lua                      -- M4: dynamic keymaps
    ghost.lua                     -- M5: pinned float
    picker.lua                    -- popup
    watch.lua                     -- M6: refresh triggers + tmux hooks
    highlights.lua                -- hl groups, ColorScheme re-assert
    health.lua                    -- M7
  tests/
    minimal_init.lua
    specs/01_parse.lua .. 08_health.lua
```

Mirrors claude-sessions.nvim exactly: one responsibility per module, lazy
`require` inside `init.lua` functions, `config.lua` holding all defaults with
LuaLS annotations.

---

## 7. Code style

Follows claude-sessions.nvim, which is the house standard.

- **Comment the why, never the what.** `repaint.lua` opens with 20 lines
  explaining an Ink renderer anchor bug. That is the bar. A comment that
  restates the code is deleted in review.
- **Module header comment** on every file, stating its one job.
- **LuaLS annotations** on every public function and config field.
- **`local uv = vim.uv or vim.loop`** at the top of any file using timers.
- **`pcall` around every external reach** — tmux calls, other plugins'
  internals, window operations that can race a close.
- **Change detection before redraw.** `statusline.lua` compares the rendered
  string and returns early if identical. Ghost text does the same.
- **Idempotent `start()`**, which calls `stop()` first, so a repeated `setup()`
  never leaks a timer or an autocmd.
- **No module-level side effects.** `plugin/` only registers commands.

---

## 8. Security boundaries

Threat model is narrow but not empty. The trust boundary is **tmux session
names**, which are attacker-influenced in the weak sense that any process able
to run `tmux new-session` chooses them. Verified above that `;`, `|`, `$()`,
and spaces all survive into a name.

### Always

- **Spawn with argv, never a shell string.** `vim.system({ "tmux", "switch-client",
  "-t", id })`. No `vim.fn.system(string)`, no `io.popen`, no `os.execute`, no
  `:!`. argv form means `$(x)` in a name is inert bytes.
- **Target by `#{session_id}`, validated against `^%$%d+$`** before use. A value
  failing that pattern is dropped, not passed to tmux.
- **Parse with a TAB separator** and keep `session_name` as the final field.
- **Truncate and sanitize names before display.** Cap at `name_width`
  display cells using `vim.fn.strcharpart`, not byte slicing, so a multibyte
  name is never cut mid-codepoint. Strip any C0 control byte defensively, even
  though tmux rejects them at creation.
- **Treat every tmux exit code as expected.** A session killed between the
  query and the switch returns nonzero. Notify at `WARN` and refresh. Never
  throw.

### Ask first

- Installing tmux hooks. Global tmux state, so opt-in only, append-only via
  `set-hook -ga`, tagged, and removable.
- Writing a stamp file outside `/tmp`.

### Never

- Build a shell command string containing a session name.
- Pass a session name to `vim.cmd`, `vim.fn.expand`, `luaeval`, or a `:terminal`.
- Run `kill-session` or any destructive tmux command. The plugin is read-only
  against tmux except for `switch-client` and the opt-in hooks.
- Write to a user buffer. The ghost float owns its own scratch buffer.

Not applicable here, and deliberately out of scope: authentication, network
I/O, secrets, PII, persistence. The plugin stores nothing on disk except the
opt-in stamp file, which holds no content.

---

## 9. Testing strategy

Harness matches switcheroo.nvim: `tests/minimal_init.lua` plus numbered specs
under `tests/specs/`, run headless.

`sessions.lua` takes its spawn function from config, so tests inject a fake
that returns fixture lines. No test shells out to a real tmux.

| Spec | Covers |
|---|---|
| `01_parse` | TAB parsing; a name containing `\|`, `;`, `$()`, and spaces parses as one field; malformed lines are dropped |
| `02_index` | Creation-order sort; a new session appends and never shifts 1..N; killing renumbers below only; ids validate against `^%$%d+$` |
| `03_switch` | argv shape is exact; targets the id not the name; nonzero exit warns and refreshes rather than throwing |
| `04_keys` | Maps created for live indices; stale maps deleted; nothing bound past `max_items`; `keys.enabled = false` binds nothing |
| `05_ghost` | Right-aligned position math; truncation at a codepoint boundary; `+N` overflow; repositions on resize; identical render does not redraw |
| `06_watch` | FocusGained triggers one refresh; timer honors `interval_ms`; `hooks = true` zeroes the timer; `stop()` leaves no live timer or autocmd |
| `07_dormant` | No `$TMUX` means zero spawns, zero keymaps, zero windows; `setup()` twice leaks nothing |
| `08_health` | Reports missing tmux, old tmux, absent `$TMUX`, and hook state |

### Acceptance criteria

The feature is done when all of these hold.

1. With four tmux sessions, the ghost text shows `1 main  2 tut  3 solo  4 pkgs`
   in the top-right, and the session this Neovim lives in is highlighted.
2. `<leader>3` switches the tmux client to session index 3.
3. `<leader>0` returns to the previous session.
4. Creating a fifth session in another pane makes `<leader>5` work within
   `interval_ms`, and indices 1..4 are unchanged.
5. Killing session 2 removes `<leader>5`, renumbers 3..4 to 2..3, and leaves no
   keymap pointing at a dead session.
6. A session named `ev;il|na me$(x)` renders truncated and switches correctly,
   with no shell evaluation.
7. Outside tmux, `setup()` is a no-op: no window, no keymap, no timer, no spawn.
8. At rest with no session changes, `tmux` is spawned at most once per
   `interval_ms`, and zero times with `hooks = true`.
9. Ghost text repositions correctly after `VimResized` with no spawn.
10. `:checkhealth tmux-sessions` is green on a working setup.
11. All specs pass headless. `stylua` and `luacheck` are clean.

### Definition of done

Beyond the above: README written with an asciinema or screenshot, `:help`
docs generated, and the plugin verified running in the author's real config
across at least four live tmux sessions.

---

## 10. Open risks

| Risk | Severity | Mitigation |
|---|---|---|
| Ghost float overlaps buffer text at top-right | Medium | `winblend`, `hide_in_insert`, and a documented `col_offset`. Revisit if it annoys in real use. |
| Float interferes with another floating-window plugin | Medium | Low `zindex`, `focusable = false`, `nofile` buffer, and a win-local flag. Needs testing against telescope, noice, and sidekick. |
| `FocusGained` unreliable if `focus-events` is off in tmux | Low | Health check warns; background timer is the fallback. |
| Killing a session renumbers and breaks muscle memory | Low | Accepted. Pinned `@index` options are a possible v2 if it bites. |
| tmux format fields change in a future version | Low | Health check pins a minimum version. Parser drops malformed lines rather than erroring. |

---

## 11. Build order

1. M1 `config` + `plugin/` stub + dormant-outside-tmux guard → spec 07
2. M2 `sessions` with injectable spawn → specs 01, 02
3. M3 `switch` → spec 03
4. M4 `keys` → spec 04
5. M5 `ghost` + `highlights` → spec 05
6. M6 `watch`, timer and focus path only → spec 06
7. `picker` popup
8. M7 `health` → spec 08
9. tmux hooks, opt-in
10. README, `:help` docs, real-config verification

Each step lands green before the next starts.
