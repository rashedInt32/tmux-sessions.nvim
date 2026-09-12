-- Parsing `list-sessions -F` output. Runs in the runner process.
--
-- The nasty names here are not hypothetical: `ev;il|na me$(x)` was created on a
-- real tmux 3.7c while speccing this, which is why the separator is TAB.
return function(H)
  local S = require("tmux-sessions.sessions")

  local function parse(lines)
    return S.parse(lines)
  end

  local function names(list)
    return vim.tbl_map(function(s)
      return s.name
    end, list)
  end

  H.it("reads every field off a well-formed line", function()
    local got = parse({ H.line("$3", 1000, "main", 1, 4) })
    H.eq(1, #got)
    H.eq("$3", got[1].id)
    H.eq("main", got[1].name)
    H.eq(1000, got[1].created)
    H.eq(1, got[1].attached)
    H.eq(4, got[1].windows)
    H.eq(1, got[1].index)
  end)

  H.it("a name containing | ; $() and spaces stays one field", function()
    local nasty = "ev;il|na me$(x)"
    local got = parse({ H.line("$1", 1000, nasty) })
    H.eq(1, #got)
    H.eq(nasty, got[1].name)
  end)

  H.it("keeps a name that itself contains the format's other fields", function()
    -- A name like "9\t9" cannot exist (tmux rejects tabs) but a name that looks
    -- like digits must not be mistaken for a numeric field.
    local got = parse({ H.line("$1", 1000, "1000") })
    H.eq({ "1000" }, names(got))
  end)

  H.it("drops malformed lines instead of erroring", function()
    local got = parse({
      "garbage",
      "",
      "$1\tnotanumber\t0\t1\tbad",
      H.line("$2", 1000, "good"),
      "$3\t1000\t0\tbad",
    })
    H.eq({ "good" }, names(got))
  end)

  H.it("rejects an id that is not $<digits>", function()
    local got = parse({
      "main\t1000\t0\t1\tby-name",
      "$\t1000\t0\t1\tempty-id",
      "$1x\t1000\t0\t1\tsuffixed",
      H.line("$9", 1000, "ok"),
    })
    H.eq({ "ok" }, names(got))
  end)

  H.it("drops an empty name", function()
    H.eq({}, parse({ H.line("$1", 1000, "") }))
  end)

  H.it("nil and empty input are not errors", function()
    H.eq({}, parse(nil))
    H.eq({}, parse({}))
  end)

  H.it("the format string puts the user-controlled name last", function()
    local fields = vim.split(S.FORMAT, "\t")
    H.eq("#{session_name}", fields[#fields])
    H.eq("#{session_id}", fields[1])
  end)

  H.it("current_id reads the session out of $TMUX", function()
    local saved = vim.env.TMUX
    vim.env.TMUX = "/private/tmp/tmux-501/default,39122,33"
    H.eq("$33", S.current_id())
    vim.env.TMUX = "/tmp/x,1,0"
    H.eq("$0", S.current_id())
    -- Junk must not produce a target we would hand to tmux.
    vim.env.TMUX = "nonsense"
    H.eq(nil, S.current_id())
    vim.env.TMUX = nil
    H.eq(nil, S.current_id())
    vim.env.TMUX = saved
  end)

  H.it("marks the session this nvim lives in", function()
    local saved = vim.env.TMUX
    vim.env.TMUX = "/tmp/x,1,2"
    local got = parse({ H.line("$1", 1000, "other"), H.line("$2", 1001, "mine") })
    H.eq(false, got[1].current)
    H.eq(true, got[2].current)
    vim.env.TMUX = saved
  end)
end
