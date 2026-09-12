-- The always-visible session list, pinned to the top-right of the editor.
--
--     ┌──────────────────────────────────┐
--     │ local M = {}        1 main       │
--     │                     2 tutorial   │
--     │                     3 solo       │
--     │                     4 packages   │
--     └──────────────────────────────────┘
--
-- A single floating window rather than a per-buffer extmark. Benchmarked, both
-- are free (0.0011ms vs 0.0018ms per update), so this is chosen on failure
-- modes, not speed:
--
--   * O(1) in buffer count. An extmark has to be applied to every buffer and
--     re-applied on BufEnter; measured 0.0283ms across 20 buffers, and that
--     grows.
--   * `virt_text_pos = "right_align"` anchors to a *line*, so it needs
--     re-placing on every WinScrolled and collides with any other plugin that
--     puts virtual text on that line. A float is independent of both.
--   * No user buffer is ever touched. The float owns its own scratch buffer.
--
-- Rejected `winbar` because it costs a screen row, which is the thing ghost
-- text exists to avoid.

local Config = require("tmux-sessions.config")
local Highlights = require("tmux-sessions.highlights")
local Sessions = require("tmux-sessions.sessions")

local M = {}

local NS = vim.api.nvim_create_namespace("tmux-sessions.ghost")

local buf, win
-- Last drawn text and the geometry it was drawn for. Redraw is skipped when
-- neither moved, which is what keeps a 5s refresh loop from touching the screen.
local drawn, drawn_col

--- Truncate to `width` display cells, never mid-codepoint.
---
--- Byte slicing would cut a multibyte name in half and paint a replacement
--- character; `strcharpart` counts characters, and `strdisplaywidth` is what
--- actually decides whether it fits, since a CJK name is two cells per char.
---@param s string
---@param width integer
---@return string
function M.truncate(s, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  local out = ""
  for i = 1, vim.fn.strchars(s) do
    local candidate = vim.fn.strcharpart(s, 0, i)
    -- Reserve one cell for the ellipsis.
    if vim.fn.strdisplaywidth(candidate) > width - 1 then
      break
    end
    out = candidate
  end
  return out .. "…"
end

---@class tmux-sessions.Entry
---@field text string one rendered session, e.g. "2 main"
---@field spans table[] each { group, start_col, end_col }, relative to `text`

--- One entry per visible session, plus the `+N` overflow marker.
---
--- Layout-independent on purpose: the vertical list, the horizontal line and
--- the lualine component are three arrangements of the same entries, so the
--- formatting and highlighting live here once.
---@return tmux-sessions.Entry[]
function M.entries()
  local g = Config.options.ghost
  local shown, hidden = Sessions.window()
  local out = {}

  for _, session in ipairs(shown) do
    local name = M.truncate(session.name, g.name_width)
    local text = g.format:format(session.index, name)
    local digits = #tostring(session.index)
    out[#out + 1] = {
      text = text,
      spans = {
        { Highlights.prefix .. "Index", 0, digits },
        { Highlights.prefix .. (session.current and "Current" or "Name"), digits, #text },
      },
    }
  end

  if hidden > 0 then
    local text = "+" .. hidden
    out[#out + 1] = { text = text, spans = { { Highlights.prefix .. "More", 0, #text } } }
  end

  return out
end

--- The buffer lines and their highlight spans, for the configured layout.
---@return string[] lines, table[] spans each { group, start_col, end_col, row }
function M.lines()
  local g = Config.options.ghost
  local entries = M.entries()
  if #entries == 0 then
    return {}, {}
  end

  if g.layout == "horizontal" then
    local parts, spans, col = {}, {}, 0
    for i, e in ipairs(entries) do
      if i > 1 then
        parts[#parts + 1] = g.separator
        col = col + #g.separator
      end
      for _, s in ipairs(e.spans) do
        spans[#spans + 1] = { s[1], col + s[2], col + s[3], 0 }
      end
      parts[#parts + 1] = e.text
      col = col + #e.text
    end
    return { table.concat(parts) }, spans
  end

  -- Vertical: one session per row. Entries stay left-aligned inside a block
  -- that is itself flush right, so the index digits line up in a column. Right
  -- -aligning each line individually would leave that column ragged.
  local lines, spans = {}, {}
  for i, e in ipairs(entries) do
    lines[i] = e.text
    for _, s in ipairs(e.spans) do
      spans[#spans + 1] = { s[1], s[2], s[3], i - 1 }
    end
  end
  return lines, spans
end

--- Single-line form, for a statusline component. Independent of `layout`: a
--- statusline has one row whichever way the float is arranged.
---@return string
function M.render()
  local parts = {}
  for _, e in ipairs(M.entries()) do
    parts[#parts + 1] = e.text
  end
  return table.concat(parts, Config.options.ghost.separator)
end

local function close()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win, drawn, drawn_col = nil, nil, nil
end

local function ensure_buf()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, "tmux-sessions://ghost")
  return buf
end

--- Should the ghost text be on screen, and where?
---@param lines string[]
---@return boolean, integer? col, integer? width, integer? height
local function placement(lines)
  local g = Config.options.ghost
  if not g.enabled or #lines == 0 then
    return false
  end
  if g.hide_in_insert and vim.fn.mode():find("^i") then
    return false
  end

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  local col = vim.o.columns - width - g.col_offset
  -- Too narrow to sit in the corner: hide rather than overlap the left edge or
  -- get clipped into nonsense.
  if col < 0 then
    return false
  end

  -- Leave the statusline and cmdline their rows. A list taller than the screen
  -- is truncated rather than pushed off the bottom.
  local height = math.min(#lines, math.max(1, vim.o.lines - g.row - 2))
  if height < 1 then
    return false
  end

  return true, col, width, height
end

--- Redraw the ghost text from the current session list.
function M.update()
  local lines, spans = M.lines()
  local show, col, width, height = placement(lines)

  if not show then
    return close()
  end

  local text = table.concat(lines, "\n")
  -- Nothing moved: skip the whole draw. This is what makes the background
  -- refresh loop invisible.
  if win and vim.api.nvim_win_is_valid(win) and text == drawn and col == drawn_col then
    return
  end

  Highlights.ensure()
  local g = Config.options.ghost
  local b = ensure_buf()

  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.list_slice(lines, 1, height))
  vim.bo[b].modifiable = false

  vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
  for _, s in ipairs(spans) do
    if s[4] < height then
      pcall(vim.api.nvim_buf_set_extmark, b, NS, s[4], s[2], { end_col = s[3], hl_group = s[1] })
    end
  end

  local cfg = {
    relative = "editor",
    row = g.row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    -- Not focusable, so <C-w>w and :windo never land here.
    focusable = false,
    zindex = g.zindex,
    noautocmd = true,
  }

  if win and vim.api.nvim_win_is_valid(win) then
    cfg.noautocmd = nil -- not accepted by nvim_win_set_config
    pcall(vim.api.nvim_win_set_config, win, cfg)
  else
    local ok, w = pcall(vim.api.nvim_open_win, b, false, cfg)
    if not ok then
      return
    end
    win = w
    -- A flag other plugins and the user's own window pickers can filter on.
    vim.w[win].tmux_sessions_ghost = true
    vim.wo[win].winblend = g.winblend
    vim.wo[win].winhighlight = "Normal:Normal,NormalFloat:Normal"
    vim.wo[win].wrap = false
  end

  drawn, drawn_col = text, col
end

function M.hide()
  close()
end

--- Flip visibility. Returns the new state.
---@return boolean visible
function M.toggle()
  local g = Config.options.ghost
  g.enabled = not g.enabled
  M.update()
  return g.enabled
end

function M.enable()
  local group = vim.api.nvim_create_augroup("TmuxSessionsGhost", { clear = true })
  -- Reposition only: the text is unchanged, so this costs no tmux spawn.
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    desc = "Reposition the tmux-sessions ghost text",
    callback = M.update,
  })
  -- Self-heal on the draw path, the same way highlights.ensure does.
  --
  -- A float is easy to lose: a session restore, `:only`, a picker that rebuilds
  -- the window layout, or a plugin that closes every float can take it out, and
  -- none of those fire an event saying so. Re-asserting on the events that
  -- follow such a change is cheaper than trying to enumerate the causes.
  -- update() early-returns when the window is still valid and nothing moved, so
  -- the common case is a validity check and two comparisons.
  vim.api.nvim_create_autocmd({
    "BufWinEnter",
    "WinEnter",
    "WinClosed",
    "TabEnter",
    "SessionLoadPost",
    "ColorScheme",
  }, {
    group = group,
    desc = "Re-assert the tmux-sessions ghost text if something closed it",
    callback = function()
      -- Deferred: during WinClosed and SessionLoadPost the layout is still
      -- settling, and a float opened mid-teardown can be taken out with it.
      vim.schedule(M.update)
    end,
  })
  if Config.options.ghost.hide_in_insert then
    vim.api.nvim_create_autocmd({ "InsertEnter", "InsertLeave" }, {
      group = group,
      desc = "Hide the tmux-sessions ghost text while inserting",
      callback = M.update,
    })
  end
  M.update()
end

function M.disable()
  pcall(vim.api.nvim_del_augroup_by_name, "TmuxSessionsGhost")
  close()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  buf = nil
end

-- Test seams.
function M._win()
  return win
end

function M._buf()
  return buf
end

return M
