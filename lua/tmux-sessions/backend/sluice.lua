-- sluice backend: zmx sessions through the sluice CLI.
--
-- sluice is a prefix layer over zmx with no screen model of its own, so there
-- is no `switch-client` that moves a whole client. `sluice switch` instead
-- signals the sluice process sitting in this pane, which reattaches it to
-- another session. The effect on this nvim is the same as tmux's: it stays
-- behind in the session it was started in. A launcher, not a manager, either
-- way.
--
-- `sluice list` prints one session per line, tab separated:
--   index \t name \t clients \t created \t cwd
-- Names are sanitised by sluice (no tab, no slash, no space) and the list
-- already arrives in creation order; it is re-sorted anyway so the two
-- backends cannot drift.

local uv = vim.uv or vim.loop

local M = {
  name = "sluice",
  -- zmx has no hook system. FocusGained and the timer carry the refresh.
  supports_hooks = false,
}

---@return boolean
function M.detect()
  local v = uv.os_getenv("ZMX_SESSION")
  return v ~= nil and v ~= ""
end

---@return string[]
function M.list_argv()
  return { "sluice", "list" }
end

---@param line string
---@return table?
function M.parse_line(line)
  -- index, name, clients, created, windows, cwd. Older sluice printed no
  -- windows column; such a line is read as a one-window session.
  local index, name, clients, created, wins, cwd = line:match("^(%d+)\t([^\t]+)\t(%d+)\t(%d+)\t([^\t]*)\t(.*)$")
  if not index then
    index, name, clients, created, cwd = line:match("^(%d+)\t([^\t]+)\t(%d+)\t(%d+)\t(.*)$")
    wins = nil
  end
  if not index or name == "" then
    return nil
  end
  local window_names = {}
  for w in (wins or name):gmatch("[^,]+") do
    window_names[#window_names + 1] = w
  end
  return {
    -- zmx names are unique and are what `sluice switch` takes, so the name is
    -- the id. Unlike tmux there is no numeric handle to prefer.
    id = name,
    name = name,
    created = tonumber(created),
    attached = tonumber(clients),
    windows = #window_names,
    -- zmx names of the session's windows, in window order
    window_names = window_names,
    cwd = cwd,
  }
end

--- "◆2/3" when this nvim's session has more than one window: which one this
--- nvim is in, of how many. Empty otherwise, and always empty under tmux.
---@param session table? the current session's row from the cache
---@return string
function M.window_mark(session)
  if not session or not session.window_names or #session.window_names < 2 then
    return ""
  end
  -- Read directly: raw_session() is declared further down this file.
  local me = uv.os_getenv("ZMX_SESSION")
  local at = 1
  for i, w in ipairs(session.window_names) do
    if w == me then
      at = i
      break
    end
  end
  return ("◆%d/%d"):format(at, #session.window_names)
end

--- Same-second tiebreak. Names are unique, so this is a total order.
---@param a table
---@param b table
---@return boolean
function M.before(a, b)
  return a.name < b.name
end

--- The zmx session this nvim runs in, exactly as zmx named it. With sluice
--- windows that is one window: `glass` for window 1, `glass+3` for window 3.
---
--- Read through libuv rather than the Vimscript-backed environment table,
--- which raises E5560 in a fast event context; this is reached from a uv timer.
---@return string?
local function raw_session()
  local v = uv.os_getenv("ZMX_SESSION")
  if v == nil or v == "" then
    return nil
  end
  return v
end

--- The sluice session this nvim runs in. `sluice list` folds windows into
--- their session, so a window suffix is dropped here to match: an nvim in
--- `glass+3` highlights `glass`.
---@return string?
function M.current_id()
  local v = raw_session()
  if not v then
    return nil
  end
  return (v:gsub("%+%d+$", ""))
end

--- Re-validated at the boundary: this becomes a process argument. sluice
--- already sanitises names, so a name outside that shape means the cache is
--- stale or something else wrote the list. `-` is refused because sluice reads
--- it as "the previous session".
---@param session table
---@return string[]?
function M.switch_argv(session)
  local name = tostring(session.name)
  if name == "" or name == "-" or name:match("[%s/]") then
    return nil
  end
  -- `--session` names the window this pane is on, which is what sluice
  -- registered its client under; the target is the whole session.
  local me = raw_session()
  if not me then
    return nil
  end
  return { "sluice", "switch", name, "--session", me }
end

--- sluice remembers the previous session per pane, the same as prefix+0.
---@return string[]?
function M.last_argv()
  local me = raw_session()
  if not me then
    return nil
  end
  return { "sluice", "switch", "-", "--session", me }
end

return M
