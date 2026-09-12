-- Highlight groups for the ghost text and the popup.
--
-- Re-asserted on ColorScheme and again on the draw path, because a colorscheme
-- that calls `:hi clear` wipes plugin groups and there is no event that fires
-- reliably afterwards for every scheme.

local Config = require("tmux-sessions.config")

local M = {}

local PREFIX = "TmuxSessions"

---@return table<string, string>
local function groups()
  local c = Config.options.highlights
  return {
    [PREFIX .. "Index"] = c.index,
    [PREFIX .. "Name"] = c.name,
    [PREFIX .. "Current"] = c.current,
    [PREFIX .. "More"] = c.more,
  }
end

function M.set()
  for name, color in pairs(groups()) do
    -- `default = false`: we own these names, and a stale definition from a
    -- previous colorscheme must lose to the configured colour.
    pcall(vim.api.nvim_set_hl, 0, name, { fg = color })
  end
end

--- Re-assert the groups if something cleared them. Cheap enough for the draw
--- path: one hlID lookup, and a full set only when it comes back empty.
function M.ensure()
  if vim.fn.hlexists(PREFIX .. "Index") == 0 then
    M.set()
  end
end

function M.enable()
  M.set()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup(PREFIX .. "Highlights", { clear = true }),
    desc = "Re-assert tmux-sessions highlight groups",
    callback = M.set,
  })
end

M.prefix = PREFIX

return M
