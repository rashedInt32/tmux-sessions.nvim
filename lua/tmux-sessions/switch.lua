-- Move the tmux client to another session.
--
-- This is the only write the plugin makes to tmux, and the only place a value
-- derived from the session list becomes a command argument. Two guards, both
-- cheap: the target is always a `$<digits>` session id, re-validated here
-- rather than trusted from the cache, and it goes out as argv so nothing in it
-- can be interpreted by a shell.
--
-- Note what switching does to us: `switch-client` moves the whole client, so
-- this nvim stays behind in the old session. That is expected -- each tmux
-- session runs its own nvim, and this plugin is a launcher, not a manager.

local Sessions = require("tmux-sessions.sessions")

local M = {}

---@param msg string
local function warn(msg)
  vim.schedule(function()
    vim.notify("tmux-sessions: " .. msg, vim.log.levels.WARN)
  end)
end

--- Run a tmux command, and treat a failure as "the list is stale".
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
---@return boolean started true when a tmux command was actually issued
function M.to(index)
  if type(index) ~= "number" then
    return false
  end
  local session = Sessions.at(index)
  if not session then
    warn("no session at " .. tostring(index))
    return false
  end
  -- Re-validated at the boundary rather than trusted from the cache: this is
  -- the value that becomes a process argument.
  if not tostring(session.id):match("^%$%d+$") then
    warn("refusing a malformed session id")
    return false
  end
  run({ "tmux", "switch-client", "-t", session.id }, "switch to " .. session.id)
  return true
end

--- Back to the previously attached session. tmux tracks this itself, so there
--- is no state to keep on our side.
---@return boolean
function M.last()
  run({ "tmux", "switch-client", "-l" }, "switch to last session")
  return true
end

return M
