-- Every knob, with its default. Nothing else in the plugin holds configuration
-- state, so `setup()` is the single place a user's table is merged in.

---@class tmux-sessions.RefreshConfig
---@field interval_ms integer background floor between tmux queries; 0 disables the timer
---@field on_focus boolean re-query on FocusGained, which is when a switch-client lands here
---@field hooks boolean install tmux hooks and drop the timer entirely
---@field stamp string file the hooks touch and every nvim watches

---@class tmux-sessions.GhostConfig
---@field enabled boolean
---@field layout "vertical"|"horizontal" one session per row, or all on one row
---@field max_items integer past this, the tail collapses to a dim `+N`
---@field name_width integer truncate longer names to this many display cells
---@field hide_in_insert boolean
---@field winblend integer
---@field row integer editor row the float sits on
---@field col_offset integer cells left of the right edge
---@field zindex integer
---@field format string `string.format` pattern for one entry: index, name
---@field separator string between entries

---@class tmux-sessions.KeysConfig
---@field enabled boolean
---@field prefix string `<leader>` gives `<leader>1` .. `<leader>9`
---@field last string switch-client -l
---@field picker string open the popup

---@class tmux-sessions.Config
---@field enabled boolean
---@field refresh tmux-sessions.RefreshConfig
---@field ghost tmux-sessions.GhostConfig
---@field keys tmux-sessions.KeysConfig
---@field highlights table<string, string>

local M = {}

---@type tmux-sessions.Config
M.defaults = {
  enabled = true,

  refresh = {
    -- A `switch-client` landing on this pane fires FocusGained, so the list is
    -- current exactly when it matters. The timer only exists to notice sessions
    -- created in some *other* pane; at ~1.1ms per spawn, 5s costs 0.02% of a core.
    interval_ms = 5000,
    on_focus = true,
    -- Opt-in: tmux `session-created`/`session-closed` hooks touch the stamp file
    -- and every nvim watches it, so an idle machine spawns tmux zero times. Off
    -- by default because installing hooks mutates global tmux state.
    hooks = false,
    stamp = "/tmp/tmux-sessions.nvim/stamp",
  },

  ghost = {
    enabled = true,
    -- One session per row. A vertical block puts the index digits in a column
    -- you can scan, and buys the width to show names untruncated; the cost is
    -- rows, which the top-right corner has more of than it has columns.
    layout = "vertical",
    -- 9 because the bindings are <leader>1..<leader>9. Anything past that has no
    -- key to show, so it collapses rather than taking space.
    max_items = 9,
    -- Roomier than the horizontal layout could afford, since each row now has
    -- the full width to itself.
    name_width = 20,
    hide_in_insert = false,
    winblend = 0,
    row = 0,
    col_offset = 1,
    -- Below nvim's own default float zindex (50), so a telescope or noice window
    -- always wins the corner rather than fighting us for it.
    zindex = 10,
    format = "%d %s",
    separator = "  ",
  },

  keys = {
    enabled = true,
    -- Not bare 1..9: those are vim's count prefix, and shadowing them breaks 3dd.
    prefix = "<leader>",
    last = "<leader>0",
    picker = "<leader>ts",
  },

  -- Same palette as claude-sessions.nvim, so both plugins read as one system.
  highlights = {
    index = "#f5d76e",
    name = "#9f9ca6",
    current = "#7fe08a",
    more = "#6b6772",
  },
}

---@type tmux-sessions.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- Hooks make the timer redundant, and leaving both on would spawn tmux for no
  -- reason. Honour an explicit interval_ms only when hooks are off.
  if M.options.refresh.hooks then
    M.options.refresh.interval_ms = 0
  end
  return M.options
end

return M
