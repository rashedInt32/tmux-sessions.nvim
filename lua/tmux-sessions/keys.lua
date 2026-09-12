-- Bind <leader>1 .. <leader>9 to whatever the session list currently holds.
--
-- The maps are rebuilt on every change rather than bound once to a closure that
-- reads the list later, so a key that exists always points at a session that
-- exists. The alternative -- nine permanent maps that look up index N at press
-- time -- leaves <leader>7 bound and silently doing nothing on a four-session
-- machine, which reads as a broken keybinding rather than an absent one.

local Config = require("tmux-sessions.config")
local Sessions = require("tmux-sessions.sessions")
local Switch = require("tmux-sessions.switch")

local M = {}

-- Only what we created, so unbinding can never take a user's own mapping with
-- it. Keyed by lhs.
local owned = {}

---@param lhs string
local function unmap(lhs)
  pcall(vim.keymap.del, "n", lhs)
  owned[lhs] = nil
end

--- Rebuild the numbered maps from the current session list.
function M.apply()
  local keys = Config.options.keys
  if not keys.enabled then
    return M.clear()
  end

  local shown = Sessions.window()
  local wanted = {}

  for i, session in ipairs(shown) do
    if i > 9 then
      break -- <leader>10 is not a keypress
    end
    local lhs = keys.prefix .. i
    wanted[lhs] = true
    vim.keymap.set("n", lhs, function()
      Switch.to(i)
    end, {
      -- The name is in the description only, never in a command. It is also
      -- what makes our maps identifiable for cleanup.
      desc = ("tmux-sessions: switch to %s"):format(session.name),
      silent = true,
    })
    owned[lhs] = true
  end

  for lhs in pairs(owned) do
    if not wanted[lhs] and lhs ~= keys.last and lhs ~= keys.picker then
      unmap(lhs)
    end
  end
end

--- Bind the two maps that do not depend on the list. Called once from setup().
function M.static()
  local keys = Config.options.keys
  if not keys.enabled then
    return
  end
  if keys.last and keys.last ~= "" then
    vim.keymap.set("n", keys.last, function()
      Switch.last()
    end, { desc = "tmux-sessions: last session", silent = true })
    owned[keys.last] = true
  end
  if keys.picker and keys.picker ~= "" then
    vim.keymap.set("n", keys.picker, function()
      require("tmux-sessions.picker").open()
    end, { desc = "tmux-sessions: pick a session", silent = true })
    owned[keys.picker] = true
  end
end

--- Remove every map this module created.
function M.clear()
  for lhs in pairs(vim.deepcopy(owned)) do
    unmap(lhs)
  end
  owned = {}
end

return M
