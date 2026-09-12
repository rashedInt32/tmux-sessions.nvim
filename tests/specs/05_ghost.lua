-- The pinned float: truncation, geometry, and the redraw it must skip.
return function(H)
  local TMUX = "/tmp/tmux-501/default,1,2"
  local Ghost = require("tmux-sessions.ghost")

  local function child(opts)
    return H.child(opts or {}, { TMUX = TMUX })
  end

  -- Pure truncation, in this process ----------------------------------------

  H.it("leaves a name that already fits alone", function()
    H.eq("main", Ghost.truncate("main", 12))
    H.eq("exactlytwelve", Ghost.truncate("exactlytwelve", 13))
  end)

  H.it("truncates with an ellipsis", function()
    local got = Ghost.truncate("a-very-long-session-name", 10)
    H.eq(10, vim.fn.strdisplaywidth(got))
    H.contains(got, "…")
  end)

  H.it("never cuts a multibyte character in half", function()
    -- Bytewise slicing here would emit a partial UTF-8 sequence.
    local got = Ghost.truncate("héllo-wörld-ünicode", 8)
    H.eq(got, vim.fn.strcharpart(got, 0, vim.fn.strchars(got)), "result is valid utf-8")
    H.ok(vim.fn.strdisplaywidth(got) <= 8)
  end)

  H.it("counts display cells, not characters, for wide text", function()
    -- Each CJK char is two cells, so 8 cells is 4 characters or fewer.
    local got = Ghost.truncate("日本語のセッション", 8)
    H.ok(vim.fn.strdisplaywidth(got) <= 8, "got width " .. vim.fn.strdisplaywidth(got))
  end)

  H.it("a zero or negative width yields nothing rather than erroring", function()
    H.eq("", Ghost.truncate("main", 0))
    H.eq("", Ghost.truncate("main", -3))
  end)

  -- The real float, in a child ----------------------------------------------

  H.it("opens top-right, unfocusable, below nvim's default float zindex", function()
    local c = child()
    c:fixture({ H.line("$1", 1000, "main"), H.line("$2", 2000, "tut") })
    local g = c:ghost()
    H.ok(g, "ghost float is open")
    H.eq("editor", g.relative, "pinned to the editor, not to a window")
    H.eq(0, g.row)
    H.eq(false, g.focusable, "must never take <C-w>w or :windo")
    H.ok(g.zindex < 50, "must lose the corner to telescope/noice, not fight for it")
    H.contains(g.text, "1 main")
    H.contains(g.text, "2 tut")
    c:stop()
  end)

  H.it("stacks one session per row by default", function()
    local c = child()
    c:fixture({
      H.line("$1", 1000, "main"),
      H.line("$2", 2000, "tut"),
      H.line("$3", 3000, "solo"),
    })
    local g = c:ghost()
    H.eq({ "1 main", "2 tut", "3 solo" }, g.lines)
    H.eq(3, g.height, "the float is as tall as the list")
    H.eq(6, g.width, "as wide as the longest entry, not the sum")
    c:stop()
  end)

  H.it("layout = horizontal puts them all on one row", function()
    local c = child({ ghost = { layout = "horizontal" } })
    c:fixture({ H.line("$1", 1000, "main"), H.line("$2", 2000, "tut") })
    local g = c:ghost()
    H.eq({ "1 main  2 tut" }, g.lines)
    H.eq(1, g.height)
    c:stop()
  end)

  H.it("sits flush against the right edge in both layouts", function()
    for _, layout in ipairs({ "vertical", "horizontal" }) do
      local c = child({ ghost = { layout = layout } })
      c:lua("vim.o.columns = 120")
      c:fixture({ H.line("$1", 1000, "main"), H.line("$2", 2000, "a-longer-name") })
      local g = c:ghost()
      H.eq(120 - g.width - 1, g.col, layout .. ": col + width + col_offset == columns")
      c:stop()
    end
  end)

  H.it("the index column lines up when the count reaches double digits", function()
    -- Entries are left-aligned inside a right-positioned block precisely so the
    -- digits form a readable column; right-aligning each row would not.
    local c = child({ ghost = { max_items = 12 } })
    local lines = {}
    for i = 1, 11 do
      lines[i] = H.line("$" .. i, 1000 + i, "s" .. i)
    end
    c:fixture(lines)
    local g = c:ghost()
    H.eq(11, #g.lines)
    H.eq("9 s9", g.lines[9])
    H.eq("10 s10", g.lines[10])
    c:stop()
  end)

  H.it("collapses the tail past max_items into its own +N row", function()
    local c = child({ ghost = { max_items = 3 } })
    local lines = {}
    for i = 1, 7 do
      lines[i] = H.line("$" .. i, 1000 + i, "s" .. i)
    end
    c:fixture(lines)
    local g = c:ghost()
    H.eq({ "1 s1", "2 s2", "3 s3", "+4" }, g.lines)
    c:stop()
  end)

  H.it("a list taller than the screen is truncated, not pushed off it", function()
    local c = child({ ghost = { max_items = 30 } })
    c:lua("vim.o.lines = 10")
    local lines = {}
    for i = 1, 25 do
      lines[i] = H.line("$" .. i, 1000 + i, "s" .. i)
    end
    c:fixture(lines)
    local g = c:ghost()
    H.ok(g, "still shown")
    H.ok(g.height <= 8, "leaves the statusline and cmdline their rows; got " .. g.height)
    H.eq(g.height, #g.lines, "buffer holds only what the float can show")
    c:stop()
  end)

  H.it("hides entirely when there are no sessions", function()
    local c = child()
    c:fixture({ H.line("$1", 1000, "main") })
    H.ok(c:ghost(), "open with one session")
    c:fixture({})
    H.eq(nil, c:ghost(), "an empty list must close the window, not draw a blank one")
    c:stop()
  end)

  H.it("hides when the screen is too narrow to hold it", function()
    local c = child()
    c:fixture({ H.line("$1", 1000, "a-long-enough-name") })
    H.ok(c:ghost())
    -- 12 is nvim's floor for &columns; the entry is ~14 cells, so it cannot fit.
    c:lua("vim.o.columns = 12; require('tmux-sessions.ghost').update()")
    H.eq(nil, c:ghost(), "clipping into nonsense is worse than hiding")
    c:stop()
  end)

  H.it("repositions on resize without re-querying tmux", function()
    local c = child()
    c:lua("vim.o.columns = 120")
    c:fixture({ H.line("$1", 1000, "main") })
    local before = c:ghost()
    c:lua([[
      _G.__spawns = 0
      local S = require("tmux-sessions.sessions")
      local real = S.spawn
      S.spawn = function(a, cb) _G.__spawns = _G.__spawns + 1; return real(a, cb) end
      vim.o.columns = 200
      vim.api.nvim_exec_autocmds("VimResized", {})
    ]])
    local after = c:ghost()
    H.eq(before.width, after.width, "same text")
    H.eq(200 - after.width - 1, after.col, "moved with the right edge")
    H.eq(0, c:lua("return _G.__spawns"), "a resize must not spawn tmux")
    c:stop()
  end)

  H.it("an unchanged list does not redraw the float", function()
    local c = child()
    c:fixture({ H.line("$1", 1000, "main") })
    local first = c:lua("return require('tmux-sessions.ghost')._win()")
    -- Same fixture again: the window must be reused, not torn down and rebuilt.
    c:fixture({ H.line("$1", 1000, "main") })
    H.eq(first, c:lua("return require('tmux-sessions.ghost')._win()"))
    c:stop()
  end)

  H.it("renders a hostile name truncated, with no shell evaluation", function()
    local c = child()
    c:fixture({ H.line("$4", 1000, "ev;il|na me$(x)") })
    local g = c:ghost()
    H.ok(g, "a nasty name still renders")
    H.contains(g.text, "1 ")
    H.ok(vim.fn.strdisplaywidth(g.text) < 30, "truncated to name_width")
    c:stop()
  end)

  H.it("comes back after something else closes the float", function()
    -- Regression: update() used to be gated on the session list having changed,
    -- so a float closed by a session restore or a window wipe stayed gone until
    -- tmux itself changed -- possibly hours.
    local c = child()
    c:fixture({ H.line("$1", 1000, "main") })
    H.ok(c:ghost())
    -- Drop the self-heal autocmds first, so this exercises the refresh gate
    -- alone rather than being rescued by the window events.
    c:lua([[
      vim.api.nvim_del_augroup_by_name("TmuxSessionsGhost")
      vim.api.nvim_win_close(require("tmux-sessions.ghost")._win(), true)
    ]])
    H.eq(nil, c:ghost(), "closed, with nothing left to restore it")
    -- Same session list as before: the old gate would have skipped the redraw.
    c:fixture({ H.line("$1", 1000, "main") })
    H.ok(c:ghost(), "an unchanged list must still re-assert the float")
    c:stop()
  end)

  H.it("re-asserts itself on a window event without any tmux query", function()
    local c = child()
    c:fixture({ H.line("$1", 1000, "main") })
    c:lua([[
      _G.__spawns = 0
      local S = require("tmux-sessions.sessions")
      local real = S.spawn
      S.spawn = function(a, cb) _G.__spawns = _G.__spawns + 1; return real(a, cb) end
      vim.api.nvim_win_close(require("tmux-sessions.ghost")._win(), true)
      vim.api.nvim_exec_autocmds("BufWinEnter", {})
    ]])
    c:wait("return require('tmux-sessions.ghost')._win() ~= nil")
    H.ok(c:ghost(), "restored by the autocmd")
    H.eq(0, c:lua("return _G.__spawns"), "self-healing must not cost a subprocess")
    c:stop()
  end)

  H.it("ghost.enabled = false opens no window", function()
    local c = child({ ghost = { enabled = false } })
    c:fixture({ H.line("$1", 1000, "main") })
    H.eq(nil, c:ghost())
    c:stop()
  end)

  H.it("toggle flips visibility", function()
    local c = child()
    c:fixture({ H.line("$1", 1000, "main") })
    H.ok(c:ghost())
    H.eq(false, c:lua("return require('tmux-sessions').toggle()"))
    H.eq(nil, c:ghost())
    H.eq(true, c:lua("return require('tmux-sessions').toggle()"))
    H.ok(c:ghost())
    c:stop()
  end)

  H.it("the float buffer is scratch and never a user buffer", function()
    local c = child()
    c:fixture({ H.line("$1", 1000, "main") })
    H.eq(
      { "nofile", false, false },
      c:lua([[
        local b = require("tmux-sessions.ghost")._buf()
        return { vim.bo[b].buftype, vim.bo[b].modifiable, vim.bo[b].swapfile }
      ]])
    )
    c:stop()
  end)
end
