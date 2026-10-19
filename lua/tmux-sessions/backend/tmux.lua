-- tmux backend: the original behaviour, unchanged.
--
-- Two decisions carry it, both verified against tmux 3.7c.
--
-- 1. Sessions are targeted by `#{session_id}`, never by name. With sessions
--    `main` and `main2` alive, `tmux display-message -t main` resolves to
--    `main` by prefix match, and the documented exact form `=main` came back
--    empty. A session id is always `$<digits>`, so it is unambiguous and
--    carries nothing a user chose. Names are display only.
--
-- 2. Fields are TAB separated, with the name last. tmux happily accepts a
--    session named `ev;il|na me$(x)` -- pipes, semicolons, `$()` and spaces all
--    survive -- so a `|` separator splits that line into the wrong number of
--    fields. tmux *rejects* tab, newline and ESC in a name, which makes TAB the
--    one separator a name can never contain.

local uv = vim.uv or vim.loop

-- Name last, because it is the only field whose content a user picks.
local FORMAT = table.concat({
  "#{session_id}",
  "#{session_created}",
  "#{session_attached}",
  "#{session_windows}",
  "#{session_name}",
}, "\t")

local M = {
  name = "tmux",
  supports_hooks = true,
  FORMAT = FORMAT,
}

---@return boolean
function M.detect()
  local v = uv.os_getenv("TMUX")
  return v ~= nil and v ~= ""
end

---@return string[]
function M.list_argv()
  return { "tmux", "list-sessions", "-F", FORMAT }
end

--- One `list-sessions` line into a raw row, or nil when it does not parse.
---
--- A malformed line is dropped rather than raised: a tmux that grows a field
--- should cost a stale list, not a stacktrace on every keystroke.
---@param line string
---@return table?
function M.parse_line(line)
  local id, created, attached, windows, name = line:match("^(%S+)\t(%d+)\t(%d+)\t(%d+)\t(.*)$")
  if not id or not id:match("^%$%d+$") or name == "" then
    return nil
  end
  return {
    id = id,
    name = name,
    created = tonumber(created),
    attached = tonumber(attached),
    windows = tonumber(windows),
  }
end

--- Tiebreak for two sessions created in the same second. tmux hands ids out
--- monotonically, so the number inside `$N` orders them. Without this the sort
--- is unstable and two keybindings silently swap between queries.
---@param a table
---@param b table
---@return boolean
function M.before(a, b)
  return tonumber(a.id:sub(2)) < tonumber(b.id:sub(2))
end

--- The session this nvim runs in, read straight out of `$TMUX`.
---
--- `$TMUX` is `<socket>,<server_pid>,<session_id>`, so the id is free -- no
--- spawn, no guessing from `#{session_attached}` (which is ambiguous once a
--- second client attaches). It is captured at attach time, so moving this pane
--- to another session leaves it stale until nvim restarts; that costs one
--- wrong highlight, so it is not worth a subprocess to correct.
---
--- Read through libuv rather than the Vimscript-backed environment table,
--- which raises E5560 in a fast event context; this is reached from a uv timer.
---@return string?
function M.current_id()
  local tmux = uv.os_getenv("TMUX")
  if not tmux or tmux == "" then
    return nil
  end
  local n = tmux:match("^[^,]*,%d+,(%d+)$")
  return n and ("$" .. n) or nil
end

--- Re-validated at the boundary rather than trusted from the cache: this is
--- the value that becomes a process argument.
---@param session table
---@return string[]?
function M.switch_argv(session)
  if not tostring(session.id):match("^%$%d+$") then
    return nil
  end
  return { "tmux", "switch-client", "-t", session.id }
end

--- tmux tracks the last session itself, so there is no state to keep here.
---@return string[]
function M.last_argv()
  return { "tmux", "switch-client", "-l" }
end

return M
