-- Commands only. Everything else waits for setup().
if vim.g.loaded_tmux_sessions then
  return
end
vim.g.loaded_tmux_sessions = true

local function cmd(name, fn, desc)
  vim.api.nvim_create_user_command(name, fn, { desc = desc })
end

cmd("TmuxSessions", function()
  require("tmux-sessions").pick()
end, "Pick a tmux session")

cmd("TmuxSessionsRefresh", function()
  require("tmux-sessions").refresh()
end, "Re-query the tmux session list")

cmd("TmuxSessionsToggle", function()
  require("tmux-sessions").toggle()
end, "Show or hide the tmux-sessions ghost text")

cmd("TmuxSessionsHooksInstall", function()
  require("tmux-sessions.watch").install_hooks()
end, "Install the tmux hooks that push session changes")

cmd("TmuxSessionsHooksUninstall", function()
  require("tmux-sessions.watch").uninstall_hooks()
end, "Remove the tmux hooks this plugin installed")
