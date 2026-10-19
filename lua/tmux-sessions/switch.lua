-- Move this pane to another session.
--
-- The only write the plugin makes, and the only place a value derived from the
-- session list becomes a command argument. Two guards, both cheap: the backend
-- re-validates its own handle rather than trusting the cache, and the command
-- goes out as argv so nothing in it can be interpreted by a shell.
--
-- Note what a switch does to us. tmux's `switch-client` moves the whole client
-- and `sluice switch` reattaches the pane's sluice process; either way this
-- nvim stays behind in the old session. That is expected -- each session runs
-- its own nvim, and this plugin is a launcher, not a manager.

local Backend = require("tmux-sessions.backend")
local Sessions = require("tmux-sessions.sessions")

local M = {}

---@param msg string
local function warn(msg)
  vim.schedule(function()
    vim.notify("tmux-sessions: " .. msg, vim.log.levels.WARN)
  end)
end

--- Run a backend command, and treat a failure as "the list is stale".
---
--- A session killed between the last refresh and this keypress is the common
--- case, and it is not exceptional enough to raise: warn, re-query, move on.
---@param argv string[]
---@param what string for the warning
local function run(argv, what)
  Sessions.spawn(argv, function(lines)
    if lines == nil then
      warn(what .. " failed; the session list may be stale")
      Sessions.refresh()
    end
  end)
end

--- Jump to the session at `index` in the current list.
---@param index integer
---@return boolean started true when a command was actually issued
function M.to(index)
  if type(index) ~= "number" then
    return false
  end
  local backend = Backend.get()
  if not backend then
    return false
  end
  local session = Sessions.at(index)
  if not session then
    warn("no session at " .. tostring(index))
    return false
  end
  local argv = backend.switch_argv(session)
  if not argv then
    warn("refusing a malformed session handle")
    return false
  end
  run(argv, "switch to " .. tostring(session.name))
  return true
end

--- Back to the previously attached session. Both backends track this
--- themselves, so there is no state to keep on our side.
---@return boolean
function M.last()
  local backend = Backend.get()
  if not backend then
    return false
  end
  local argv = backend.last_argv()
  if not argv then
    warn("this backend cannot name the previous session")
    return false
  end
  run(argv, "switch to last session")
  return true
end

return M
