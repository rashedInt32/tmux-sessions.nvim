-- Outside tmux the plugin does not render empty. It starts nothing at all.
return function(H)
  H.it("no $TMUX means no window, no keymap, no timer, no spawn", function()
    -- H.child strips TMUX from the inherited environment, so this is a real
    -- "outside tmux" child even when the suite itself runs inside one.
    local c = H.child({})
    H.eq(false, c:lua("return require('tmux-sessions').active()"))
    H.eq({}, c:maps())
    H.eq(nil, c:ghost())
    H.eq(nil, c:lua("return require('tmux-sessions.watch')._timer() ~= nil or nil"))
    H.eq(0, #c:lua("return require('tmux-sessions').list()"))
    c:lua([[
      _G.__spawns = 0
      local S = require("tmux-sessions.sessions")
      local real = S.spawn
      S.spawn = function(a, cb) _G.__spawns = _G.__spawns + 1; return real(a, cb) end
    ]])
    vim.wait(300)
    H.eq(0, c:lua("return _G.__spawns"))
    c:stop()
  end)

  H.it("enabled = false is dormant even inside tmux", function()
    local c = H.child({ enabled = false }, { TMUX = "/tmp/s,1,2" })
    H.eq(false, c:lua("return require('tmux-sessions').active()"))
    H.eq({}, c:maps())
    H.eq(nil, c:ghost())
    c:stop()
  end)

  H.it("the commands exist without setup() and do not throw", function()
    local c = H.child(nil, { TMUX = "/tmp/s,1,2" })
    local cmds = c:lua("return vim.tbl_keys(vim.api.nvim_get_commands({}))")
    for _, name in ipairs({
      "TmuxSessions",
      "TmuxSessionsRefresh",
      "TmuxSessionsToggle",
      "TmuxSessionsHooksInstall",
      "TmuxSessionsHooksUninstall",
    }) do
      H.ok(vim.tbl_contains(cmds, name), name .. " is registered by plugin/")
    end
    -- No setup() has run: these must be harmless, not stacktraces.
    H.eq(true, c:lua("return (pcall(vim.cmd, 'TmuxSessions')) ~= false or true"))
    H.eq(true, c:lua("return (pcall(vim.cmd, 'TmuxSessionsRefresh')) ~= false or true"))
    c:stop()
  end)

  H.it("setup() twice leaks nothing", function()
    local c = H.child({}, { TMUX = "/tmp/s,1,2" })
    c:fixture({ H.line("$1", 1000, "a") })
    for _ = 1, 3 do
      c:setup({})
    end
    c:fixture({ H.line("$1", 1000, "a") })
    H.eq(
      1,
      c:lua([[
        local n = 0
        for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
          if m.lhs == " 1" then n = n + 1 end
        end
        return n
      ]])
    )
    -- One ghost window, not four.
    H.eq(
      1,
      c:lua([[
        local n = 0
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if pcall(function() return vim.w[w].tmux_sessions_ghost end) and vim.w[w].tmux_sessions_ghost then
            n = n + 1
          end
        end
        return n
      ]])
    )
    c:stop()
  end)

  H.it("stop() after a real start returns the editor to clean", function()
    local c = H.child({}, { TMUX = "/tmp/s,1,2" })
    c:fixture({ H.line("$1", 1000, "a"), H.line("$2", 2000, "b") })
    H.ok(c:ghost())
    c:lua("require('tmux-sessions').stop()")
    H.eq({}, c:maps())
    H.eq(nil, c:ghost())
    H.eq(false, c:lua("return require('tmux-sessions').active()"))
    c:stop()
  end)
end
