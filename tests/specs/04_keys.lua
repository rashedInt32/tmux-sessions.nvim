-- Dynamic keymaps, in a real child nvim so these are real mappings.
return function(H)
  local TMUX = "/tmp/tmux-501/default,1,2"

  local function child(opts)
    return H.child(opts or {}, { TMUX = TMUX })
  end

  local function lhs_set(maps)
    return vim.tbl_keys(maps)
  end

  H.it("binds one key per session and nothing more", function()
    local c = child()
    c:fixture({ H.line("$1", 1000, "a"), H.line("$2", 2000, "b"), H.line("$3", 3000, "c") })
    local maps = c:maps()
    H.ok(maps[" 1"], "<leader>1 bound")
    H.ok(maps[" 2"], "<leader>2 bound")
    H.ok(maps[" 3"], "<leader>3 bound")
    H.eq(nil, maps[" 4"], "no key for a session that does not exist")
    c:stop()
  end)

  H.it("the static keys are bound even with no sessions", function()
    local c = child()
    local maps = c:maps()
    H.ok(maps[" 0"], "<leader>0 is last-session and never depends on the list")
    H.ok(maps[" ts"], "<leader>ts opens the picker")
    c:stop()
  end)

  H.it("a shrinking list deletes the keys that lost their session", function()
    local c = child()
    c:fixture({
      H.line("$1", 1000, "a"),
      H.line("$2", 2000, "b"),
      H.line("$3", 3000, "c"),
      H.line("$4", 4000, "d"),
    })
    H.ok(c:maps()[" 4"])
    c:fixture({ H.line("$1", 1000, "a"), H.line("$2", 2000, "b") })
    local maps = c:maps()
    H.eq(nil, maps[" 3"], "a stale key must never point at a dead session")
    H.eq(nil, maps[" 4"])
    H.ok(maps[" 1"])
    H.ok(maps[" 2"])
    H.ok(maps[" 0"], "shrinking the list must not take the static keys with it")
    c:stop()
  end)

  H.it("the description follows the session now at that index", function()
    local c = child()
    c:fixture({ H.line("$1", 1000, "alpha"), H.line("$2", 2000, "beta") })
    H.contains(c:maps()[" 2"], "beta")
    -- Kill index 1; beta moves up and <leader>1 must describe beta now.
    c:fixture({ H.line("$2", 2000, "beta") })
    H.contains(c:maps()[" 1"], "beta")
    H.eq(nil, c:maps()[" 2"])
    c:stop()
  end)

  H.it("caps at max_items, so a tenth session gets no key", function()
    local c = child()
    local lines = {}
    for i = 1, 12 do
      lines[i] = H.line("$" .. i, 1000 + i, "s" .. i)
    end
    c:fixture(lines)
    local maps = c:maps()
    for i = 1, 9 do
      H.ok(maps[" " .. i], "<leader>" .. i .. " bound")
    end
    -- " 10" is not even a keypress; what must not happen is a stray extra map.
    local numbered = vim.tbl_filter(function(k)
      -- [1-9], not %d: <leader>0 is the static last-session key, not a slot.
      return k:match("^ [1-9]$")
    end, lhs_set(maps))
    H.eq(9, #numbered)
    c:stop()
  end)

  H.it("keys.enabled = false binds nothing at all", function()
    local c = child({ keys = { enabled = false } })
    c:fixture({ H.line("$1", 1000, "a"), H.line("$2", 2000, "b") })
    H.eq({}, c:maps())
    c:stop()
  end)

  H.it("a custom prefix is honoured", function()
    local c = child({ keys = { prefix = "<C-t>", last = "<C-t>0", picker = "<C-t>p" } })
    c:fixture({ H.line("$1", 1000, "a") })
    local maps = c:maps()
    H.ok(maps["<C-T>1"] or maps["<C-t>1"], "custom prefix bound: " .. vim.inspect(lhs_set(maps)))
    c:stop()
  end)

  H.it("pressing <leader>2 switches to the second session", function()
    local c = child()
    c:lua([[
      _G.__argv = {}
      local S = require("tmux-sessions.sessions")
      local real = S.spawn
      S.spawn = function(argv, cb)
        if argv[2] == "switch-client" then _G.__argv[#_G.__argv+1] = argv; return cb({}) end
        return real(argv, cb)
      end
    ]])
    c:fixture({ H.line("$7", 1000, "first"), H.line("$9", 2000, "second") })
    c:input(" 2")
    c:wait("return #_G.__argv > 0")
    H.eq({ "tmux", "switch-client", "-t", "$9" }, c:lua("return _G.__argv[1]"))
    c:stop()
  end)

  H.it("setup() twice leaves exactly one set of keys", function()
    local c = child()
    c:fixture({ H.line("$1", 1000, "a") })
    c:setup({})
    c:fixture({ H.line("$1", 1000, "a") })
    local numbered = vim.tbl_filter(function(k)
      -- [1-9], not %d: <leader>0 is the static last-session key, not a slot.
      return k:match("^ [1-9]$")
    end, lhs_set(c:maps()))
    H.eq(1, #numbered)
    c:stop()
  end)
end
