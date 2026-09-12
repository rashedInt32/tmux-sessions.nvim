-- Index assignment: the property the whole plugin rests on is that creating a
-- session never renumbers the ones you already know.
return function(H)
  local S = require("tmux-sessions.sessions")

  local function indexed(lines)
    local out = {}
    for _, s in ipairs(S.parse(lines)) do
      out[s.index] = s.name
    end
    return out
  end

  H.it("orders by creation time, not by name or by tmux's output order", function()
    -- tmux itself lists alphabetically; creation order must win.
    H.eq(
      { "main", "tut", "solo", "pkgs" },
      indexed({
        H.line("$30", 1789181871, "tut"),
        H.line("$0", 1788718199, "main"),
        H.line("$33", 1789185097, "pkgs"),
        H.line("$32", 1789185033, "solo"),
      })
    )
  end)

  H.it("a new session appends and leaves 1..N untouched", function()
    local before = {
      H.line("$0", 1000, "main"),
      H.line("$1", 2000, "tut"),
      H.line("$2", 3000, "solo"),
    }
    H.eq({ "main", "tut", "solo" }, indexed(before))

    local after = vim.deepcopy(before)
    -- 'api' sorts first alphabetically; creation order must still put it last.
    after[#after + 1] = H.line("$3", 4000, "api")
    H.eq({ "main", "tut", "solo", "api" }, indexed(after))
  end)

  H.it("killing a session renumbers only what was below it", function()
    H.eq(
      { "main", "solo" },
      indexed({
        H.line("$0", 1000, "main"),
        H.line("$2", 3000, "solo"),
      })
    )
  end)

  H.it("sessions born in the same second break the tie on id, not at random", function()
    -- session_created has second resolution, so ties are real. An unstable sort
    -- would swap two keybindings between queries.
    local lines = {
      H.line("$7", 1000, "seventh"),
      H.line("$5", 1000, "fifth"),
      H.line("$6", 1000, "sixth"),
    }
    local want = { "fifth", "sixth", "seventh" }
    H.eq(want, indexed(lines))
    -- Same set, different input order: the answer must not move.
    H.eq(want, indexed({ lines[2], lines[3], lines[1] }))
    H.eq(want, indexed({ lines[3], lines[1], lines[2] }))
  end)

  H.it("id tiebreak is numeric, so $10 comes after $9", function()
    H.eq(
      { "nine", "ten" },
      indexed({
        H.line("$10", 1000, "ten"),
        H.line("$9", 1000, "nine"),
      })
    )
  end)

  H.it("window() caps at max_items and reports the overflow", function()
    require("tmux-sessions.config").setup({ ghost = { max_items = 3 } })
    local lines = {}
    for i = 1, 5 do
      lines[i] = H.line("$" .. i, 1000 + i, "s" .. i)
    end
    -- window() reads the cache, so seed it through the same path refresh() uses.
    local saved = S.spawn
    S.spawn = function(_, cb)
      cb(lines)
    end
    S.refresh()
    local shown, hidden = S.window()
    H.eq(
      { "s1", "s2", "s3" },
      vim.tbl_map(function(s)
        return s.name
      end, shown)
    )
    H.eq(2, hidden)

    require("tmux-sessions.config").setup({ ghost = { max_items = 9 } })
    shown, hidden = S.window()
    H.eq(5, #shown)
    H.eq(0, hidden)

    S.spawn = saved
    S.reset()
  end)

  H.it("refresh reports whether the list actually changed", function()
    local saved, lines = S.spawn, { H.line("$1", 1000, "a") }
    S.spawn = function(_, cb)
      cb(lines)
    end
    S.reset()

    local seen
    S.refresh(function(changed)
      seen = changed
    end)
    vim.wait(500, function()
      return seen ~= nil
    end, 5)
    H.eq(true, seen, "first refresh populates the cache")

    seen = nil
    S.refresh(function(changed)
      seen = changed
    end)
    vim.wait(500, function()
      return seen ~= nil
    end, 5)
    H.eq(false, seen, "identical output must not report a change")

    seen, lines = nil, { H.line("$1", 1000, "a"), H.line("$2", 2000, "b") }
    S.refresh(function(changed)
      seen = changed
    end)
    vim.wait(500, function()
      return seen ~= nil
    end, 5)
    H.eq(true, seen)

    S.spawn = saved
    S.reset()
  end)

  H.it("a failed spawn empties the list rather than keeping a stale one", function()
    local saved = S.spawn
    S.spawn = function(_, cb)
      cb({ H.line("$1", 1000, "a") })
    end
    S.refresh()
    vim.wait(200, function()
      return #S.list() == 1
    end, 5)

    S.spawn = function(_, cb)
      cb(nil)
    end
    S.refresh()
    vim.wait(200, function()
      return #S.list() == 0
    end, 5)
    H.eq({}, S.list(), "a dead tmux must not leave keys pointing at gone sessions")

    S.spawn = saved
    S.reset()
  end)
end
