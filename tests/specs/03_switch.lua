-- The one place the plugin writes to tmux. Asserts the exact argv, because the
-- shape of this call is the security boundary.
return function(H)
  local S = require("tmux-sessions.sessions")
  local Switch = require("tmux-sessions.switch")

  --- Run `fn` with the spawn faked, and return every argv it produced.
  local function capture(fn, fail)
    local calls = {}
    local saved = S.spawn
    S.spawn = function(argv, cb)
      calls[#calls + 1] = argv
      -- Not `fail and nil or {}`: in Lua that collapses to `{}` for every value
      -- of `fail`, which silently turns this into a success-only fake.
      if fail then
        cb(nil)
      else
        cb({})
      end
    end
    fn()
    vim.wait(100, function()
      return false
    end, 5)
    S.spawn = saved
    return calls
  end

  local function seed(lines)
    local saved = S.spawn
    S.spawn = function(_, cb)
      cb(lines)
    end
    S.refresh()
    vim.wait(300, function()
      return #S.list() == #lines
    end, 5)
    S.spawn = saved
  end

  H.it("targets the session id, never the name", function()
    -- With `main` and `main2` alive, tmux resolves `-t main` to `main` by prefix
    -- match, so a name target is ambiguous. Ids are not.
    seed({ H.line("$0", 1000, "main"), H.line("$1", 2000, "main2") })
    local calls = capture(function()
      Switch.to(2)
    end)
    H.eq(1, #calls)
    H.eq({ "tmux", "switch-client", "-t", "$1" }, calls[1])
    S.reset()
  end)

  H.it("passes a hostile name's session id without ever touching the name", function()
    seed({ H.line("$4", 1000, "ev;il|na me$(x)") })
    local calls = capture(function()
      Switch.to(1)
    end)
    H.eq({ "tmux", "switch-client", "-t", "$4" }, calls[1])
    for _, arg in ipairs(calls[1]) do
      H.ok(not arg:find("ev;il", 1, true), "the name must never reach argv")
    end
    S.reset()
  end)

  H.it("argv is a list, so nothing is ever handed to a shell", function()
    seed({ H.line("$1", 1000, "a") })
    local calls = capture(function()
      Switch.to(1)
    end)
    H.eq("table", type(calls[1]))
    H.eq("tmux", calls[1][1], "argv[1] is the binary, not a command string")
    S.reset()
  end)

  H.it("an index with no session issues no command", function()
    seed({ H.line("$1", 1000, "a") })
    H.eq(
      {},
      capture(function()
        Switch.to(9)
      end)
    )
    H.eq(
      {},
      capture(function()
        Switch.to(0)
      end)
    )
    H.eq(
      {},
      capture(function()
        Switch.to(nil)
      end)
    )
    H.eq(
      {},
      capture(function()
        Switch.to("1")
      end)
    )
    S.reset()
  end)

  H.it("last() asks tmux for the previous session", function()
    local calls = capture(function()
      Switch.last()
    end)
    H.eq({ "tmux", "switch-client", "-l" }, calls[1])
  end)

  H.it("a failed switch refreshes instead of throwing", function()
    seed({ H.line("$1", 1000, "a") })
    -- fail=true makes the fake report a nonzero exit, as tmux does when the
    -- session died between the last query and this keypress.
    local calls = capture(function()
      Switch.to(1)
    end, true)
    H.eq(2, #calls, "the failure must trigger a re-query")
    H.eq("switch-client", calls[1][2])
    H.eq("list-sessions", calls[2][2])
    S.reset()
  end)
end
