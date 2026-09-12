-- When the plugin spawns tmux. This is the only performance decision that
-- matters: the draw is 0.0011ms, the spawn is 1.11ms.
return function(H)
  local TMUX = "/tmp/tmux-501/default,1,2"
  local Watch = require("tmux-sessions.watch")

  local function child(opts)
    return H.child(opts or {}, { TMUX = TMUX })
  end

  --- Count spawns from now on, in the child.
  local function count_spawns(c)
    c:lua([[
      _G.__spawns = 0
      local S = require("tmux-sessions.sessions")
      local real = S.spawn
      S.spawn = function(a, cb) _G.__spawns = _G.__spawns + 1; return real(a, cb) end
    ]])
  end

  H.it("FocusGained triggers a refresh", function()
    local c = child({ refresh = { interval_ms = 0 } })
    c:fixture({ H.line("$1", 1000, "a") })
    count_spawns(c)
    c:lua("vim.api.nvim_exec_autocmds('FocusGained', {})")
    c:wait("return _G.__spawns >= 1")
    H.ok(true)
    c:stop()
  end)

  H.it("on_focus = false leaves no FocusGained autocmd of ours", function()
    local c = child({ refresh = { on_focus = false, interval_ms = 0 } })
    H.eq(
      0,
      c:lua([[
        local ok, au = pcall(vim.api.nvim_get_autocmds, { group = "TmuxSessionsWatch", event = "FocusGained" })
        return ok and #au or 0
      ]])
    )
    c:stop()
  end)

  H.it("the background timer fires on its interval", function()
    local c = child({ refresh = { interval_ms = 60 } })
    count_spawns(c)
    c:wait("return _G.__spawns >= 3", 3000)
    H.ok(true, "timer polled repeatedly")
    c:stop()
  end)

  H.it("the timer tick reaches keymaps and the float, not just the spawn", function()
    -- Regression: a uv timer callback runs in a fast event context. Calling the
    -- refresh directly from it raised E5560 on the first vim.env read, so every
    -- tick threw and the list stayed empty while still looking like it polled.
    local c = child({ refresh = { interval_ms = 50 } })
    c:lua("_G.__fixture = ...", { H.line("$1", 1000, "alpha"), H.line("$2", 2000, "beta") })
    c:wait("return #require('tmux-sessions').list() == 2", 3000)
    H.ok(c:maps()[" 2"], "the timer path must build keymaps")
    H.ok(c:ghost(), "the timer path must draw the float")
    c:stop()
  end)

  H.it("interval_ms = 0 runs no timer but still populates once", function()
    local c = child({ refresh = { interval_ms = 0 } })
    c:fixture({ H.line("$1", 1000, "a") })
    H.eq(1, #c:lua("return require('tmux-sessions').list()"))
    H.eq(nil, c:lua("return require('tmux-sessions.watch')._timer() ~= nil or nil"))
    count_spawns(c)
    -- Give a timer that should not exist ample room to fire.
    vim.wait(300)
    H.eq(0, c:lua("return _G.__spawns"), "interval_ms = 0 must be genuinely idle")
    c:stop()
  end)

  H.it("hooks = true forces the timer off, so the two never both poll", function()
    local cfg = require("tmux-sessions.config").setup({ refresh = { hooks = true, interval_ms = 5000 } })
    H.eq(0, cfg.refresh.interval_ms)
    require("tmux-sessions.config").setup({})
  end)

  H.it("stop() leaves no timer and no autocmd", function()
    local c = child({ refresh = { interval_ms = 50 } })
    c:lua("require('tmux-sessions').stop()")
    H.eq(nil, c:lua("return require('tmux-sessions.watch')._timer() ~= nil or nil"))
    H.eq(
      0,
      c:lua([[
        local ok, au = pcall(vim.api.nvim_get_autocmds, { group = "TmuxSessionsWatch" })
        return ok and #au or 0
      ]])
    )
    count_spawns(c)
    vim.wait(250)
    H.eq(0, c:lua("return _G.__spawns"), "a stopped plugin must be silent")
    c:stop()
  end)

  H.it("setup() twice does not double the poll rate", function()
    local c = child({ refresh = { interval_ms = 50 } })
    c:setup({ refresh = { interval_ms = 50 } })
    c:setup({ refresh = { interval_ms = 50 } })
    count_spawns(c)
    vim.wait(220)
    local n = c:lua("return _G.__spawns")
    H.ok(n <= 6, "one timer, not three; saw " .. n .. " spawns in 220ms")
    c:stop()
  end)

  -- The stamp path is the one string the plugin lets tmux hand to a shell.
  H.it("safe_path allowlists ordinary paths and refuses the rest", function()
    H.eq(true, Watch._safe_path("/tmp/tmux-sessions.nvim/stamp"))
    H.eq(true, Watch._safe_path("/var/folders/x_1/T/stamp-2"))
    for _, bad in ipairs({
      "/tmp/a; rm -rf /",
      "/tmp/$(whoami)",
      "/tmp/`id`",
      "/tmp/a b",
      "/tmp/a'b",
      '/tmp/a"b',
      "/tmp/a|b",
      "/tmp/../etc/passwd",
      "/tmp/a\nb",
      "",
    }) do
      H.eq(false, Watch._safe_path(bad), "must refuse: " .. vim.inspect(bad))
    end
    H.eq(false, Watch._safe_path(nil))
    H.eq(false, Watch._safe_path(42))
  end)

  H.it("install_hooks refuses rather than quoting an unsafe stamp", function()
    local c = child({ refresh = { interval_ms = 0, stamp = "/tmp/x; rm -rf /" } })
    count_spawns(c)
    H.eq(false, c:lua("return require('tmux-sessions.watch').install_hooks()"))
    H.eq(0, c:lua("return _G.__spawns"), "no tmux command may be issued at all")
    c:stop()
  end)

  H.it("install_hooks appends with -ga so an existing hook survives", function()
    local c = child({ refresh = { interval_ms = 0 } })
    c:lua([[
      _G.__argv = {}
      require("tmux-sessions.sessions").spawn = function(a, cb) _G.__argv[#_G.__argv+1] = a; cb({}) end
    ]])
    c:lua("require('tmux-sessions.watch').install_hooks()")
    local argv = c:lua("return _G.__argv")
    H.eq(3, #argv, "one hook per event")
    for _, a in ipairs(argv) do
      H.eq("set-hook", a[2])
      H.eq("-ga", a[3], "-g would clobber a user's existing hook")
      H.contains(a[5], "tmux-sessions.nvim", "tagged, so uninstall can find only ours")
    end
    H.eq({ "session-created", "session-closed", "client-session-changed" }, {
      argv[1][4],
      argv[2][4],
      argv[3][4],
    })
    c:stop()
  end)
end
