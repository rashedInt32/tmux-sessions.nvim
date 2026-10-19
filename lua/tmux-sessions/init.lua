-- tmux-sessions.nvim -- every tmux session in the top-right of your editor,
-- each one a <leader>N away.
--
-- `switch-client` moves the whole tmux client, so this nvim stays behind in the
-- old session. That makes the plugin a launcher, not a manager: every tmux
-- session runs its own nvim with its own copy, each querying tmux
-- independently and sharing no state. It is also why the list is always on
-- screen rather than behind a keystroke -- the keystroke is the thing being
-- replaced.
--
-- Read-only against tmux except for `switch-client` and the opt-in hooks.

local M = {}

--- True once setup() has run inside a supported multiplexer. Outside one the
--- plugin is fully dormant: no window, no keymap, no timer, no subprocess.
local active = false

---@return boolean
function M.active()
  return active
end

--- Jump to the session at `index` in the current list.
---@param index integer
function M.switch(index)
  return require("tmux-sessions.switch").to(index)
end

--- Back to the previously attached session.
function M.last()
  return require("tmux-sessions.switch").last()
end

--- Open the popup.
function M.pick()
  return require("tmux-sessions.picker").open()
end

--- Force a re-query now.
---@param cb? fun(changed: boolean)
function M.refresh(cb)
  if cb then
    return require("tmux-sessions.sessions").refresh(function(changed)
      require("tmux-sessions.keys").apply()
      require("tmux-sessions.ghost").update()
      cb(changed)
    end)
  end
  return require("tmux-sessions.watch").refresh(true)
end

--- Which backend is driving: "tmux", "sluice", or "none" when dormant.
---@return string
function M.backend()
  return require("tmux-sessions.backend").name()
end

--- The cached session list, for a statusline component of your own.
---@return tmux-sessions.Session[]
function M.list()
  return require("tmux-sessions.sessions").list()
end

--- Show or hide the ghost text.
---@return boolean visible
function M.toggle()
  return require("tmux-sessions.ghost").toggle()
end

--- "◆2/3" while the session this nvim lives in has more than one window:
--- which window this nvim is in, of how many. Empty otherwise, and always
--- empty under tmux. Reads the cache only, so it is free to call per redraw.
---@return string
function M.window_mark()
  local b = require("tmux-sessions.backend").get()
  if not active or not b or not b.window_mark then
    return ""
  end
  for _, s in ipairs(M.list()) do
    if s.current then
      return b.window_mark(s)
    end
  end
  return ""
end

--- Ready-made lualine component for `window_mark()`, hidden when empty.
---@return table
function M.lualine_windows()
  return {
    M.window_mark,
    cond = function()
      return M.window_mark() ~= ""
    end,
  }
end

--- Ready-made lualine component, shaped like claude-sessions.nvim's.
---@return table
function M.lualine()
  return {
    function()
      local text = require("tmux-sessions.ghost").render()
      return text
    end,
    cond = function()
      return active and #M.list() > 0
    end,
  }
end

--- Tear everything down. Idempotent, and called by setup() before it starts, so
--- a repeated setup() never leaks a timer, an autocmd or a keymap.
function M.stop()
  pcall(function()
    require("tmux-sessions.watch").stop()
  end)
  pcall(function()
    require("tmux-sessions.ghost").disable()
  end)
  pcall(function()
    require("tmux-sessions.keys").clear()
  end)
  pcall(function()
    require("tmux-sessions.sessions").reset()
  end)
  pcall(function()
    require("tmux-sessions.backend").reset()
  end)
  active = false
end

---@param opts? table see lua/tmux-sessions/config.lua for the full set
function M.setup(opts)
  local Config = require("tmux-sessions.config")
  Config.setup(opts)

  M.stop()

  -- Outside a multiplexer there is nothing to list and nothing to switch to,
  -- so the plugin does not merely render empty -- it starts nothing at all.
  if not Config.options.enabled then
    return
  end
  if not require("tmux-sessions.backend").detect(Config.options.backend) then
    return
  end

  active = true
  require("tmux-sessions.highlights").enable()
  require("tmux-sessions.keys").static()
  require("tmux-sessions.ghost").enable()
  require("tmux-sessions.watch").start()
end

return M
