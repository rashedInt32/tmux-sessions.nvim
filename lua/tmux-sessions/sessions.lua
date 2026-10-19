-- Ask the multiplexer for its sessions, and turn the answer into a stable
-- numbered list.
--
-- Everything multiplexer-specific -- the command, the line format, how the
-- current session is identified -- lives in `backend/`. This module owns the
-- part both share: spawning, ordering and caching.

local Backend = require("tmux-sessions.backend")
local Config = require("tmux-sessions.config")

local M = {}

---@class tmux-sessions.Session
---@field id string backend handle: a tmux `$<digits>`, or a zmx session name
---@field name string raw session name, untruncated
---@field created integer unix seconds
---@field attached integer number of clients attached
---@field windows integer
---@field cwd? string working directory, when the backend reports one
---@field window_names? string[] sluice only: zmx names of the session's windows
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

--- The session this nvim is running in, as the active backend names it.
---@return string?
function M.current_id()
  local b = Backend.get()
  return b and b.current_id() or nil
end

--- Turn raw listing lines into the numbered list.
---
--- Sorted by creation time so a new session always appends: indices 1..N never
--- shift when one is created, which is the whole reason fixed keybindings are
--- worth having. Creation time has second resolution in both backends, so two
--- sessions born in the same second tie; the backend breaks it with something
--- it hands out monotonically. Without that tiebreak the sort is unstable and
--- two keybindings silently swap between queries.
---@param lines string[]
---@return tmux-sessions.Session[]
function M.parse(lines)
  local b = Backend.get()
  if not b then
    return {}
  end
  local current = b.current_id()
  local out = {}

  for _, line in ipairs(lines or {}) do
    local row = b.parse_line(line)
    if row then
      row.current = row.id == current
      out[#out + 1] = row
    end
  end

  table.sort(out, function(x, y)
    if x.created ~= y.created then
      return x.created < y.created
    end
    return b.before(x, y)
  end)

  for i, s in ipairs(out) do
    s.index = i
  end
  return out
end

--- Re-query and replace the cache. `cb` receives `true` when the list changed,
--- so callers can skip a redraw and a keymap rebuild.
---@param cb? fun(changed: boolean)
function M.refresh(cb)
  local b = Backend.get()
  if not b then
    if cb then
      vim.schedule(function()
        cb(false)
      end)
    end
    return
  end
  M.spawn(b.list_argv(), function(lines)
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

--- " ◆3" after a session that has more than one window, for the list views.
--- Only sluice reports its windows by name; under tmux this is always empty,
--- so the tmux display is unchanged.
---@param session tmux-sessions.Session
---@return string
function M.count_mark(session)
  local n = session.window_names and #session.window_names or 0
  if n > 1 then
    return (" ◆%d"):format(n)
  end
  return ""
end

--- Drop the cache. Only for specs and `stop()`.
function M.reset()
  cache = {}
end

-- Kept for callers and specs that referred to the tmux format directly.
M.FORMAT = require("tmux-sessions.backend.tmux").FORMAT

return M
