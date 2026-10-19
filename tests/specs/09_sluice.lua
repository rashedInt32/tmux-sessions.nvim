-- The sluice backend: zmx sessions through the `sluice` CLI.
--
-- The suite pins the tmux backend globally, so every spec here swaps it and
-- puts it back. `ZMX_SESSION` is set for the duration where the current
-- session matters, because the backend reads it through libuv rather than
-- through a table a spec could stub.
return function(H)
  local Backend = require("tmux-sessions.backend")
  local S = require("tmux-sessions.sessions")
  local Switch = require("tmux-sessions.switch")
  local Sluice = require("tmux-sessions.backend.sluice")

  local uv = vim.uv or vim.loop

  --- Run `fn` with the sluice backend active and `$ZMX_SESSION` set to `me`.
  local function with_sluice(me, fn)
    Backend.use("sluice")
    local saved = uv.os_getenv("ZMX_SESSION")
    if me then
      uv.os_setenv("ZMX_SESSION", me)
    else
      pcall(uv.os_unsetenv, "ZMX_SESSION")
    end
    local ok, err = pcall(fn)
    if saved then
      uv.os_setenv("ZMX_SESSION", saved)
    else
      pcall(uv.os_unsetenv, "ZMX_SESSION")
    end
    Backend.use("tmux")
    S.reset()
    if not ok then
      error(err)
    end
  end

  --- One `sluice list` line: index, name, clients, created, cwd.
  local function line(index, name, clients, created, cwd)
    return ("%d\t%s\t%d\t%d\t%s"):format(index, name, clients, created, cwd or "~")
  end

  --- Capture the argv of every spawn `fn` makes.
  local function capture(fn)
    local calls = {}
    local saved = S.spawn
    S.spawn = function(argv, cb)
      calls[#calls + 1] = argv
      cb({})
    end
    fn()
    vim.wait(100, function()
      return false
    end, 5)
    S.spawn = saved
    return calls
  end

  H.it("reads every field off a sluice list line", function()
    with_sluice("main", function()
      local out = S.parse({ line(1, "main", 1, 1000, "~/code") })
      H.eq(1, #out)
      H.eq("main", out[1].name)
      H.eq("main", out[1].id, "the name is the handle sluice switch takes")
      H.eq(1000, out[1].created)
      H.eq(1, out[1].attached)
      H.eq("~/code", out[1].cwd)
      H.eq(1, out[1].index)
    end)
  end)

  H.it("marks the session this nvim lives in", function()
    with_sluice("glass", function()
      local out = S.parse({ line(1, "main", 1, 1000), line(2, "glass", 0, 2000) })
      H.eq(false, out[1].current)
      H.eq(true, out[2].current, "ZMX_SESSION names the current session")
    end)
  end)

  H.it("orders by creation time, not by the index sluice printed", function()
    with_sluice("main", function()
      local out = S.parse({ line(1, "newer", 0, 3000), line(2, "older", 0, 1000) })
      H.eq("older", out[1].name)
      H.eq("newer", out[2].name)
      H.eq(1, out[1].index)
    end)
  end)

  H.it("sessions born in the same second break the tie on name, not at random", function()
    with_sluice("main", function()
      local a = S.parse({ line(1, "beta", 0, 1000), line(2, "alpha", 0, 1000) })
      local b = S.parse({ line(1, "alpha", 0, 1000), line(2, "beta", 0, 1000) })
      H.eq("alpha", a[1].name)
      H.eq(a[1].name, b[1].name, "the same two sessions order the same way every query")
    end)
  end)

  H.it("drops malformed lines instead of erroring", function()
    with_sluice("main", function()
      local out = S.parse({
        "not a session line",
        "",
        "1\tmissing-fields",
        line(1, "good", 0, 1000),
      })
      H.eq(1, #out)
      H.eq("good", out[1].name)
    end)
  end)

  H.it("a name with spaces in it is not a sluice session", function()
    -- sluice sanitises names, so a line carrying one means something else
    -- produced the list. It must not reach argv.
    H.eq(nil, Sluice.switch_argv({ name = "two words", id = "two words" }))
    H.eq(nil, Sluice.switch_argv({ name = "", id = "" }))
    H.eq(nil, Sluice.switch_argv({ name = "-", id = "-" }), "`-` means previous to sluice")
  end)

  H.it("switch and last go out as argv with the pane's own session named", function()
    with_sluice("here", function()
      -- seed the cache through the fake so switch has something to target
      local saved = S.spawn
      S.spawn = function(_, cb)
        cb({ line(1, "main", 1, 1000), line(2, "glass", 0, 2000) })
      end
      S.refresh()
      vim.wait(100, function()
        return false
      end, 5)
      S.spawn = saved

      local calls = capture(function()
        Switch.to(2)
      end)
      H.eq({ "sluice", "switch", "glass", "--session", "here" }, calls[1])

      calls = capture(function()
        Switch.last()
      end)
      H.eq({ "sluice", "switch", "-", "--session", "here" }, calls[1])
    end)
  end)

  H.it("an nvim in a sluice window highlights its session and names its window", function()
    with_sluice("glass+3", function()
      H.eq("glass", Sluice.current_id(), "the window suffix is folded into the session")
      local out = S.parse({ line(1, "main", 1, 1000), line(2, "glass", 1, 2000) })
      H.eq(true, out[2].current)

      local saved = S.spawn
      S.spawn = function(_, cb)
        cb({ line(1, "main", 1, 1000), line(2, "glass", 1, 2000) })
      end
      S.refresh()
      vim.wait(100, function()
        return false
      end, 5)
      S.spawn = saved
      local calls = capture(function()
        Switch.to(1)
      end)
      -- the client is registered under the window it is on, not the session
      H.eq({ "sluice", "switch", "main", "--session", "glass+3" }, calls[1])
    end)
  end)

  --- A `sluice list` line with the windows column: index, name, clients,
  --- created, windows, cwd.
  local function wline(index, name, created, windows, cwd)
    return ("%d\t%s\t0\t%d\t%s\t%s"):format(index, name, created, windows, cwd or "~")
  end

  H.it("reads the windows column, and an old five-column line as one window", function()
    with_sluice("main", function()
      local out = S.parse({
        wline(1, "glass", 1000, "glass,glass+2,glass+4", "~/g"),
        line(2, "old", 0, 2000, "~/o"),
      })
      H.eq({ "glass", "glass+2", "glass+4" }, out[1].window_names)
      H.eq(3, out[1].windows)
      H.eq("~/g", out[1].cwd, "cwd is still the last field")
      H.eq({ "old" }, out[2].window_names, "no windows column: the session is its only window")
    end)
  end)

  H.it("the window mark says which window this nvim is in, of how many", function()
    with_sluice("glass+4", function()
      local row = S.parse({ wline(1, "glass", 1000, "glass,glass+2,glass+4") })[1]
      H.eq("◆3/3", Sluice.window_mark(row), "position in the list, not the window number")
    end)
    with_sluice("glass", function()
      local row = S.parse({ wline(1, "glass", 1000, "glass,glass+2") })[1]
      H.eq("◆1/2", Sluice.window_mark(row))
    end)
    with_sluice("solo", function()
      local row = S.parse({ wline(1, "solo", 1000, "solo") })[1]
      H.eq("", Sluice.window_mark(row), "one window: no mark at all")
    end)
  end)

  H.it("list views add a count only to sessions with several windows", function()
    with_sluice("main", function()
      local out = S.parse({ wline(1, "glass", 1000, "glass,glass+2,glass+3"), wline(2, "solo", 2000, "solo") })
      H.eq(" ◆3", S.count_mark(out[1]))
      H.eq("", S.count_mark(out[2]))
    end)
    -- tmux rows carry no window names, so the tmux display is unchanged
    H.eq("", S.count_mark({ name = "x", windows = 4 }))
  end)

  H.it("detects from the environment, and tmux wins when both are present", function()
    local saved_zmx = uv.os_getenv("ZMX_SESSION")
    local saved_tmux = uv.os_getenv("TMUX")

    uv.os_setenv("ZMX_SESSION", "s")
    pcall(uv.os_unsetenv, "TMUX")
    H.eq("sluice", Backend.detect("auto").name)

    uv.os_setenv("TMUX", "/tmp/sock,1,2")
    H.eq("tmux", Backend.detect("auto").name, "a tmux inside a sluice session is a tmux pane first")

    pcall(uv.os_unsetenv, "ZMX_SESSION")
    pcall(uv.os_unsetenv, "TMUX")
    H.eq(nil, Backend.detect("auto"), "outside both, no backend at all")

    if saved_zmx then
      uv.os_setenv("ZMX_SESSION", saved_zmx)
    end
    if saved_tmux then
      uv.os_setenv("TMUX", saved_tmux)
    end
    Backend.use("tmux")
  end)

  H.it("a plain zmx user without sluice installed keeps the plugin dormant", function()
    local saved_zmx = uv.os_getenv("ZMX_SESSION")
    local saved_tmux = uv.os_getenv("TMUX")
    local saved_path = uv.os_getenv("PATH")
    uv.os_setenv("ZMX_SESSION", "s")
    pcall(uv.os_unsetenv, "TMUX")
    uv.os_setenv("PATH", "/nonexistent") -- no sluice anywhere

    H.eq(false, Sluice.detect(), "ZMX_SESSION alone is not enough")
    H.eq(nil, Backend.detect("auto"))

    uv.os_setenv("PATH", saved_path)
    if saved_zmx then
      uv.os_setenv("ZMX_SESSION", saved_zmx)
    else
      pcall(uv.os_unsetenv, "ZMX_SESSION")
    end
    if saved_tmux then
      uv.os_setenv("TMUX", saved_tmux)
    end
    Backend.use("tmux")
  end)

  H.it("the sluice backend declares no hook support", function()
    H.eq(false, Sluice.supports_hooks, "zmx has no hooks; the timer carries the refresh")
    H.eq(true, require("tmux-sessions.backend.tmux").supports_hooks)
  end)
end
