-- Which multiplexer this nvim is sitting in.
--
-- tmux and sluice differ in three places only: how the session list is
-- fetched and parsed, how the current session is identified, and how a switch
-- is issued. Everything above this line -- the ghost window, the picker, the
-- keymaps, the highlights -- is the same either way.

local M = {}

local BACKENDS = { "tmux", "sluice" }

---@type table?
local active = nil

---@param name string
---@return table?
local function load(name)
  local ok, mod = pcall(require, "tmux-sessions.backend." .. name)
  if ok then
    return mod
  end
  return nil
end

--- Pick a backend. `preferred` comes from config: a backend name, or "auto" to
--- take the first one whose environment is present. tmux wins a tie, because a
--- tmux running inside a sluice session is a tmux pane first.
---@param preferred? string
---@return table? backend
function M.detect(preferred)
  if preferred and preferred ~= "auto" then
    local mod = load(preferred)
    active = (mod and mod.detect()) and mod or nil
    return active
  end
  for _, name in ipairs(BACKENDS) do
    local mod = load(name)
    if mod and mod.detect() then
      active = mod
      return active
    end
  end
  active = nil
  return nil
end

--- The backend chosen by the last detect().
---
--- Detects on first use so that every module stays usable on its own, before
--- or without setup(): two `os_getenv` calls, then cached. setup() always runs
--- detect() with the configured preference first, so this fallback only ever
--- decides when nobody has asked for a specific one.
---@return table?
function M.get()
  if active == nil then
    return M.detect("auto")
  end
  return active
end

--- Force a backend regardless of the environment.
---
--- For specs, which exercise one backend's parsing from fixtures while the
--- process they run in may well be sitting inside the other one. Not reachable
--- from config: pinning there should still leave the plugin dormant when that
--- multiplexer is not actually running.
---@param name string
---@return table?
function M.use(name)
  active = load(name)
  return active
end

--- Name of the active backend, for messages and :checkhealth.
---@return string
function M.name()
  return active and active.name or "none"
end

--- Only for specs and stop().
function M.reset()
  active = nil
end

M.names = BACKENDS

return M
