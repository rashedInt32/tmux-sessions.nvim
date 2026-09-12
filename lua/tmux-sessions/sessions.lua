-- Ask tmux for its sessions, and turn the answer into a stable numbered list.
--
-- Two decisions here carry the plugin, both verified against tmux 3.7c.
--
-- 1. Sessions are targeted by `#{session_id}`, never by name. With sessions
--    `main` and `main2` alive, `tmux display-message -t main` resolves to
--    `main` by prefix match, and the documented exact form `=main` came back
--    empty. A session id is always `$<digits>`, so it is unambiguous and
--    carries nothing a user chose. Names are display only.
--
-- 2. Fields are TAB separated, with the name last. tmux happily accepts a
--    session named `ev;il|na me$(x)` -- pipes, semicolons, `$()` and spaces all
--    survive -- so a `|` separator splits that line into the wrong number of
--    fields. tmux *rejects* tab, newline and ESC in a name, which makes TAB the
--    one separator a name can never contain.

local Config = require("tmux-sessions.config")

local uv = vim.uv or vim.loop

local M = {}

-- Name last, because it is the only field whose content a user picks.
local FORMAT = table.concat({
  "#{session_id}",
  "#{session_created}",
  "#{session_attached}",
  "#{session_windows}",
  "#{session_name}",
}, "\t")

---@class tmux-sessions.Session
---@field id string tmux session id, always `$<digits>`
---@field name string raw session name, untruncated
---@field created integer unix seconds
---@field attached integer number of clients attached
---@field windows integer
---@field index integer 1-based position in creation order
---@field current boolean this nvim lives in this session

---@type tmux-sessions.Session[]
local cache = {}

--- Spawn a command and hand its stdout lines to `cb`. Indirected through the
--- module so specs can swap in a fake without ever shelling out.
---
--- argv form, never a shell string: it is what makes a session named `$(x)`
--- inert bytes rather than a command substitution.
---
--- The callback is handed back on the main loop. `vim.system`'s on_exit runs in
--- a fast event context, where most of the API raises E5560, and every caller
--- here ends in keymaps, windows or highlights. Scheduling once at the source
--- is cheaper than auditing each callback for what it is allowed to touch.
---@param argv string[]
---@param cb fun(lines: string[]|nil)
function M.spawn(argv, cb)
  local function done(lines)
    vim.schedule(function()
      cb(lines)
    end)
  end
  local ok = pcall(vim.system, argv, { text = true }, function(res)
    if res.code ~= 0 or not res.stdout then
      return done(nil)
    end
    done(vim.split(res.stdout, "\n", { trimempty = true }))
  end)
  if not ok then
    done(nil)
  end
end

--- The session this nvim is running in, read straight out of `$TMUX`.
---
--- `$TMUX` is `<socket>,<server_pid>,<session_id>`, so the id is free -- no
--- spawn, no guessing from `#{session_attached}` (which is ambiguous once a
--- second client attaches). It is captured at attach time, so moving this pane
--- to another session leaves it stale until nvim restarts; that costs one
--- wrong highlight, so it is not worth a subprocess to correct.
---
--- Read through libuv, not `vim.env`: `vim.env` is backed by the Vimscript
--- `getenv`, which raises E5560 in a fast event context. parse() is reached
--- from a uv timer callback, so this has to be callable from anywhere.
---@return string? id
function M.current_id()
  local tmux = uv.os_getenv("TMUX")
  if not tmux or tmux == "" then
    return nil
  end
  local n = tmux:match("^[^,]*,%d+,(%d+)$")
  return n and ("$" .. n) or nil
end

--- Turn raw `list-sessions` lines into the numbered list.
---
--- Sorted by creation time so a new session always appends: indices 1..N never
--- shift when one is created, which is the whole reason fixed keybindings are
--- worth having. `session_created` only has second resolution, so two sessions
--- born in the same second tie -- broken by the numeric id, which tmux hands
--- out monotonically. Without that tiebreak the sort is unstable and two
--- keybindings silently swap between queries.
---@param lines string[]
---@return tmux-sessions.Session[]
function M.parse(lines)
  local current = M.current_id()
  local out = {}

  for _, line in ipairs(lines or {}) do
    local id, created, attached, windows, name = line:match("^(%S+)\t(%d+)\t(%d+)\t(%d+)\t(.*)$")
    -- A malformed line is dropped rather than raised: a tmux that grows a field
    -- should cost a stale list, not a stacktrace on every keystroke.
    if id and id:match("^%$%d+$") and name ~= "" then
      out[#out + 1] = {
        id = id,
        name = name,
        created = tonumber(created),
        attached = tonumber(attached),
        windows = tonumber(windows),
        current = id == current,
      }
    end
  end

  table.sort(out, function(a, b)
    if a.created ~= b.created then
      return a.created < b.created
    end
    return tonumber(a.id:sub(2)) < tonumber(b.id:sub(2))
  end)

  for i, s in ipairs(out) do
    s.index = i
  end
  return out
end

--- Re-query tmux and replace the cache. `cb` receives `true` when the list
--- changed, so callers can skip a redraw and a keymap rebuild.
---@param cb? fun(changed: boolean)
function M.refresh(cb)
  M.spawn({ "tmux", "list-sessions", "-F", FORMAT }, function(lines)
    local next_list = M.parse(lines)
    local changed = not vim.deep_equal(cache, next_list)
    cache = next_list
    if cb then
      vim.schedule(function()
        cb(changed)
      end)
    end
  end)
end

--- Last known session list. Never spawns: every caller renders off the cache so
--- that drawing stays free and only `refresh()` pays for a subprocess.
---@return tmux-sessions.Session[]
function M.list()
  return cache
end

---@param index integer
---@return tmux-sessions.Session?
function M.at(index)
  return cache[index]
end

--- Visible entries: the first `max_items`, plus how many were left over.
---@return tmux-sessions.Session[] shown, integer hidden
function M.window()
  local max = Config.options.ghost.max_items
  if #cache <= max then
    return cache, 0
  end
  return vim.list_slice(cache, 1, max), #cache - max
end

--- Drop the cache. Only for specs and `stop()`.
function M.reset()
  cache = {}
end

M.FORMAT = FORMAT

return M
