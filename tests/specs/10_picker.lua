-- Where the popup opens, and how wide.
return function(H)
  local TMUX = "/tmp/tmux-501/default,1,2"

  local function child(opts)
    return H.child(opts or {}, { TMUX = TMUX })
  end

  local function open(c)
    return c:lua([[
      local w, b = require("tmux-sessions.picker").open()
      if not w then return nil end
      local cfg = vim.api.nvim_win_get_config(w)
      return {
        row = cfg.row, col = cfg.col, width = cfg.width, height = cfg.height,
        columns = vim.o.columns, lines = vim.o.lines,
        text = vim.api.nvim_buf_get_lines(b, 0, -1, false),
      }
    ]])
  end

  local function seed(c, n)
    local lines = {}
    for i = 1, n do
      lines[i] = H.line("$" .. i, 1000 + i, "session-" .. i)
    end
    c:fixture(lines)
  end

  H.it("opens in the top-right by default, not over the code", function()
    local c = child()
    c:lua("vim.o.columns = 200; vim.o.lines = 50")
    seed(c, 4)
    local p = open(c)
    H.ok(p, "popup opened")
    H.eq(2, p.row, "sits at the configured margin from the top")
    -- col + width + border(2) + margin == columns
    H.eq(200 - p.width - 2 - 2, p.col, "flush to the right edge, border allowed for")
    c:stop()
  end)

  H.it("never hugs its content below min_width", function()
    local c = child()
    c:lua("vim.o.columns = 200")
    c:fixture({ H.line("$1", 1000, "a") })
    H.eq(34, open(c).width, "short names must not produce a mean little box")
    c:stop()
  end)

  H.it("grows past min_width for a long name", function()
    local c = child()
    c:lua("vim.o.columns = 200")
    c:fixture({ H.line("$1", 1000, "a-really-quite-long-session-name-here") })
    H.ok(open(c).width > 34, "wide enough for the longest entry")
    c:stop()
  end)

  H.it("position = center puts it in the middle", function()
    local c = child({ picker = { position = "center" } })
    c:lua("vim.o.columns = 200; vim.o.lines = 50")
    seed(c, 4)
    local p = open(c)
    H.eq(math.floor((200 - p.width) / 2), p.col)
    H.ok(p.row > 10, "vertically centred, not pinned to the top; got " .. p.row)
    c:stop()
  end)

  H.it("a custom margin moves it off the edge", function()
    local c = child({ picker = { margin = 6 } })
    c:lua("vim.o.columns = 200")
    seed(c, 3)
    local p = open(c)
    H.eq(6, p.row)
    H.eq(200 - p.width - 6 - 2, p.col)
    c:stop()
  end)

  H.it("a narrow editor clamps the width instead of overflowing", function()
    local c = child()
    c:lua("vim.o.columns = 24")
    c:fixture({ H.line("$1", 1000, "a-really-quite-long-session-name-here") })
    local p = open(c)
    H.ok(p.width <= 22, "fits inside the editor; got " .. p.width)
    H.ok(p.col >= 0, "never a negative column")
    c:stop()
  end)

  H.it("lists every session with its global number", function()
    local c = child()
    seed(c, 3)
    local p = open(c)
    H.eq(3, #p.text)
    H.contains(p.text[1], "1")
    H.contains(p.text[3], "session-3")
    c:stop()
  end)

  H.it("marks the session this nvim lives in", function()
    local c = child()
    c:fixture({ H.line("$1", 1000, "other"), H.line("$2", 2000, "mine") })
    local p = open(c)
    H.contains(p.text[2], "▸")
    H.ok(not p.text[1]:find("▸", 1, true), "only the current one is marked")
    c:stop()
  end)

  H.it("an empty list opens nothing rather than an empty box", function()
    local c = child()
    c:fixture({})
    H.eq(nil, open(c))
    c:stop()
  end)
end
