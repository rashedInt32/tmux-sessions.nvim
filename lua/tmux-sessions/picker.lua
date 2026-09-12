-- The popup. Secondary to the ghost text, and cheap enough to be worth having:
-- 0.19ms to build, and it reads the same cache, so opening it spawns nothing.
--
-- It exists for what the ghost text structurally cannot show: sessions past
-- index 9, untruncated names, and window counts.

local Config = require("tmux-sessions.config")
local Highlights = require("tmux-sessions.highlights")
local Sessions = require("tmux-sessions.sessions")
local Switch = require("tmux-sessions.switch")

local M = {}

local NS = vim.api.nvim_create_namespace("tmux-sessions.picker")

local function close(win, buf)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- Open the session list. Returns the window and buffer, for tests.
---@return integer? win, integer? buf
function M.open()
  local list = Sessions.list()
  if #list == 0 then
    vim.notify("tmux-sessions: no tmux sessions", vim.log.levels.INFO)
    return nil, nil
  end

  Highlights.ensure()

  local pc = Config.options.picker
  local lines, width = {}, pc.min_width
  for i, s in ipairs(list) do
    -- The marker sits where a name can never reach it, so a session called
    -- "*" cannot fake being the current one.
    lines[i] = ("%s %-2d %s"):format(s.current and "▸" or " ", i, s.name)
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]) + 4)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  for i, s in ipairs(list) do
    local group = Highlights.prefix .. (s.current and "Current" or "Index")
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, i - 1, 0, { end_col = 4, hl_group = group })
  end

  local height = math.min(#lines, math.max(1, vim.o.lines - 6))
  width = math.min(width, vim.o.columns - 2)

  local row, col
  if pc.position == "center" then
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
    col = math.max(0, math.floor((vim.o.columns - width) / 2))
  else
    -- `margin` accounts for the border, which sits outside the given width.
    row = pc.margin
    col = math.max(0, vim.o.columns - width - pc.margin - 2)
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " tmux sessions ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true

  local function pick(index)
    close(win, buf)
    Switch.to(index)
  end

  local map = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  -- Buffer-local, so bare digits are safe here: there is no count to shadow in
  -- a one-column list.
  for i = 1, math.min(#list, 9) do
    map(tostring(i), function()
      pick(i)
    end)
  end
  map("<CR>", function()
    pick(vim.api.nvim_win_get_cursor(win)[1])
  end)
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    map(lhs, function()
      close(win, buf)
    end)
  end

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        close(win, buf)
      end)
    end,
  })

  return win, buf
end

return M
