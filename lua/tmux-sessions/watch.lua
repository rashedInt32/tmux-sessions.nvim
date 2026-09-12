-- Decide *when* to ask tmux for the session list.
--
-- This is the only performance decision that matters. Measured on tmux 3.7c:
-- rendering the list costs 0.0011ms, spawning `tmux list-sessions` costs 1.11ms
-- even through `vim.system`, and 3.54ms if you block on it. So the draw is free
-- and the subprocess is not; everything here exists to spawn less.
--
-- Default path, which installs nothing:
--
--   * FocusGained. A `switch-client` landing on this pane fires it, which is
--     exactly the moment the list matters, and it costs nothing at rest.
--   * A slow timer, 5s, purely to notice sessions created in another pane.
--   * VimResized repositions without spawning.
--
-- Opt-in path: tmux hooks touch a stamp file, every nvim watches it with one
-- fs_event, and an idle machine spawns tmux zero times.

local Config = require("tmux-sessions.config")
local Ghost = require("tmux-sessions.ghost")
local Keys = require("tmux-sessions.keys")
local Sessions = require("tmux-sessions.sessions")

local uv = vim.uv or vim.loop

local M = {}

local GROUP = "TmuxSessionsWatch"
local HOOKS = { "session-created", "session-closed", "client-session-changed" }
-- Tag inside the hook command so uninstall can recognise ours and leave any
-- other hook on the same event alone.
local TAG = "tmux-sessions.nvim"

local timer, fswatch

--- Re-query, then rebuild the keymaps only if the list actually moved.
---
--- The ghost text is redrawn unconditionally. Gating it on `changed` meant that
--- anything which closed the float -- a session restore, a window wipe, a
--- picker that rearranged the layout -- left it gone until the *tmux* session
--- list happened to change, which can be hours. update() costs 0.0011ms and
--- early-returns when nothing moved, so there is nothing to save by skipping it.
---@param force? boolean rebuild keymaps even when the list is unchanged
function M.refresh(force)
  Sessions.refresh(function(changed)
    if changed or force then
      Keys.apply()
    end
    Ghost.update()
  end)
end

--- A stamp path safe to embed in the shell string tmux will run.
---
--- This is the one place the plugin hands tmux something to pass to a shell, so
--- the path is allowlisted rather than escaped. Anything outside this character
--- set is refused, not quoted.
---@param path string
---@return boolean
local function safe_path(path)
  return type(path) == "string" and path ~= "" and path:match("^[%w%._/%-]+$") ~= nil and not path:find("%.%.")
end

--- Watch the stamp file for the hooks' touch.
---
--- Watches the *directory*, not the file: `touch` on a missing file creates it,
--- and an fs_event bound to a path that does not exist yet never fires.
local function watch_stamp()
  local stamp = Config.options.refresh.stamp
  local dir = vim.fn.fnamemodify(stamp, ":h")
  vim.fn.mkdir(dir, "p")
  local ok, handle = pcall(uv.new_fs_event)
  if not ok or not handle then
    return
  end
  fswatch = handle
  pcall(function()
    fswatch:start(dir, {}, function()
      vim.schedule(function()
        M.refresh()
      end)
    end)
  end)
end

--- Install the tmux hooks. Appends with `-ga`, so an existing hook on the same
--- event survives; tmux stores hooks as arrays (`session-created[0]`).
---@return boolean ok
function M.install_hooks()
  local stamp = Config.options.refresh.stamp
  if not safe_path(stamp) then
    vim.notify("tmux-sessions: refusing an unsafe stamp path: " .. tostring(stamp), vim.log.levels.ERROR)
    return false
  end
  local dir = vim.fn.fnamemodify(stamp, ":h")
  local cmd = ("run-shell '# %s\nmkdir -p %s && touch %s'"):format(TAG, dir, stamp)
  for _, hook in ipairs(HOOKS) do
    Sessions.spawn({ "tmux", "set-hook", "-ga", hook, cmd }, function() end)
  end
  return true
end

--- Remove only the hooks carrying our tag, one event at a time.
function M.uninstall_hooks()
  for _, hook in ipairs(HOOKS) do
    Sessions.spawn({ "tmux", "show-hooks", "-g" }, function(lines)
      if not lines then
        return
      end
      for _, line in ipairs(lines) do
        local index = line:match("^" .. hook .. "%[(%d+)%]")
        if index and line:find(TAG, 1, true) then
          Sessions.spawn({ "tmux", "set-hook", "-gu", ("%s[%s]"):format(hook, index) }, function() end)
        end
      end
    end)
  end
end

--- Idempotent: calls stop() first, so a repeated setup() never leaks a timer.
function M.start()
  M.stop()
  local r = Config.options.refresh

  if r.on_focus then
    vim.api.nvim_create_autocmd("FocusGained", {
      group = vim.api.nvim_create_augroup(GROUP, { clear = true }),
      desc = "Refresh the tmux session list when a switch lands here",
      callback = function()
        M.refresh()
      end,
    })
  end

  if r.hooks then
    watch_stamp()
    M.install_hooks()
  end

  if r.interval_ms and r.interval_ms > 0 then
    timer = uv.new_timer()
    -- vim.schedule, not a bare call: a uv timer callback runs in a fast event
    -- context, where the keymap and window APIs this refresh ends in are not
    -- allowed. Without it every tick raises E5560 and the list stays empty.
    timer:start(0, r.interval_ms, function()
      vim.schedule(function()
        M.refresh()
      end)
    end)
  else
    -- Still need one query to populate the list at startup.
    M.refresh(true)
  end
end

function M.stop()
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  timer = nil
  if fswatch and not fswatch:is_closing() then
    pcall(function()
      fswatch:stop()
    end)
    fswatch:close()
  end
  fswatch = nil
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
end

function M._timer()
  return timer
end

M._safe_path = safe_path

return M
