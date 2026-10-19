-- :checkhealth tmux-sessions

local Config = require("tmux-sessions.config")

local M = {}

-- 3.0 introduced the `session_created` format field this plugin sorts on.
local MIN = { 3, 0 }

---@param out string
---@return integer? major, integer? minor
local function parse_version(out)
  local major, minor = out:match("(%d+)%.(%d+)")
  return tonumber(major), tonumber(minor)
end

function M.check()
  local H = vim.health
  H.start("tmux-sessions.nvim")

  local Backend = require("tmux-sessions.backend")
  local backend = Backend.get()

  if not backend then
    H.warn("no multiplexer detected: neither $TMUX nor $ZMX_SESSION is set, so the plugin stays dormant")
    H.info("supported backends: " .. table.concat(Backend.names, ", "))
    return
  end
  H.ok("backend: " .. backend.name)

  if backend.name == "sluice" then
    M.check_sluice(H)
  else
    M.check_tmux(H)
  end

  local id = require("tmux-sessions.sessions").current_id()
  if id then
    H.ok("current session " .. id)
  else
    H.warn("the current session could not be identified; it will not be highlighted")
  end

  local r = Config.options.refresh
  if r.hooks and not backend.supports_hooks then
    H.warn(("refresh.hooks is on, but the %s backend has no hooks; falling back to the timer"):format(backend.name))
  elseif r.hooks then
    if require("tmux-sessions.watch")._safe_path(r.stamp) then
      H.ok("tmux hooks enabled, watching " .. r.stamp)
    else
      H.error("refresh.stamp is not a safe path: " .. tostring(r.stamp))
    end
  else
    H.ok(("polling every %dms"):format(r.interval_ms))
  end

  local count = #require("tmux-sessions").list()
  H.info(("%d session%s in the cache"):format(count, count == 1 and "" or "s"))
end

--- sluice itself, plus the zmx daemon it drives.
function M.check_sluice(H)
  if vim.fn.executable("sluice") == 0 then
    H.error("sluice not found on $PATH")
    return
  end
  H.ok(vim.trim(vim.fn.system({ "sluice", "--version" })))
  if vim.fn.executable("zmx") == 0 then
    H.error("zmx not found on $PATH; sluice cannot list or switch sessions without it")
  end
end

--- tmux, its version, and the focus-events setting the refresh leans on.
function M.check_tmux(H)
  if vim.fn.executable("tmux") == 0 then
    H.error("tmux not found on $PATH")
    return
  end

  local out = vim.fn.system({ "tmux", "-V" })
  local major, minor = parse_version(out)
  if not major then
    H.warn("could not read a version from `tmux -V`: " .. vim.trim(out))
  elseif major < MIN[1] or (major == MIN[1] and minor < MIN[2]) then
    H.error(("tmux %d.%d is too old; %d.%d or newer is required"):format(major, minor, MIN[1], MIN[2]))
  else
    H.ok(("tmux %s"):format(vim.trim(out)))
  end

  -- Without focus-events tmux never tells nvim a switch landed, so the timer is
  -- doing all the work and the list can lag by interval_ms.
  if Config.options.refresh.on_focus then
    local focus = vim.trim(vim.fn.system({ "tmux", "show-options", "-gv", "focus-events" }))
    if focus == "on" then
      H.ok("tmux focus-events on")
    else
      H.warn("tmux focus-events is off; add `set -g focus-events on` to tmux.conf for instant refresh")
    end
  end
end

M._parse_version = parse_version

return M
