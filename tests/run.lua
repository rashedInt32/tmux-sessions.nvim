-- Test runner.  Usage:  nvim --headless --clean -l tests/run.lua [name-filter]
--
-- Pure specs run in this process. Anything that needs real autocmds, real
-- keymaps or a real window spawns a child `nvim --embed` and drives it over
-- RPC, so FocusGained, <leader>N and the ghost float behave as they do
-- interactively.
--
-- No spec ever shells out to tmux. `sessions.spawn` is swapped for a fake that
-- replays fixture lines, which keeps the suite deterministic and lets us test
-- session names that would be a nuisance to create for real.

local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")
vim.opt.runtimepath:append(root)
local filter = _G.arg and _G.arg[1] or nil

local H = { root = root }

function H.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(
      (msg or "values differ") .. "\n  expected: " .. vim.inspect(expected) .. "\n  actual:   " .. vim.inspect(actual),
      2
    )
  end
end

function H.ok(v, msg)
  if not v then
    error(msg or "expected a truthy value", 2)
  end
end

function H.contains(haystack, needle, msg)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error(
      (msg or "substring missing") .. "\n  looking for: " .. vim.inspect(needle) .. "\n  in: " .. vim.inspect(haystack),
      2
    )
  end
end

--- One `list-sessions -F` output line.
---@param id string
---@param created integer
---@param name string
function H.line(id, created, name, attached, windows)
  return table.concat({ id, created, attached or 0, windows or 1, name }, "\t")
end

-- Child nvim over RPC ---------------------------------------------------------

local Child = {}
Child.__index = Child

--- Start a child nvim with the plugin loaded but `setup()` not yet called, so
--- each spec picks its own options.
--- `$TMUX` is always stripped from the inherited environment first, so a spec
--- that wants it must say so. Otherwise the suite silently passes when run
--- inside tmux and fails outside it, and the dormancy specs test nothing.
---@param opts? table passed straight to setup(); nil means no setup at all
---@param env? table extra environment, e.g. { TMUX = ... }
function H.child(opts, env)
  local e = vim.fn.environ()
  e.TMUX, e.TMUX_PANE = nil, nil
  e = vim.tbl_extend("force", e, env or {})
  local chan = vim.fn.jobstart({
    "nvim",
    "--headless",
    "--embed",
    "--clean",
    "-u",
    root .. "/tests/minimal_init.lua",
  }, { rpc = true, env = e, clear_env = true })
  H.ok(chan > 0, "could not start child nvim")
  local c = setmetatable({ chan = chan }, Child)
  -- Stub the spawn before setup() so no child ever reaches a real tmux.
  c:lua([[require("tmux-sessions.sessions").spawn = function(_, cb) cb(_G.__fixture or {}) end]])
  if opts then
    c:setup(opts)
  end
  return c
end

function Child:req(method, ...)
  return vim.rpcrequest(self.chan, method, ...)
end

function Child:lua(code, ...)
  local r = self:req("nvim_exec_lua", code, { ... })
  if r == vim.NIL then
    return nil
  end
  return r
end

function Child:setup(opts)
  self:lua("require('tmux-sessions').setup(...)", opts or {})
end

--- Replace what the fake tmux returns, then refresh and wait for it to land.
---@param lines string[]
function Child:fixture(lines)
  self:lua("_G.__fixture = ...", lines)
  self:lua([[
    _G.__done = false
    require("tmux-sessions").refresh(function() _G.__done = true end)
  ]])
  self:wait("return _G.__done == true")
end

function Child:input(keys)
  self:req("nvim_input", keys)
end

function Child:wait(code, timeout)
  local ok = vim.wait(timeout or 3000, function()
    return self:lua(code) == true
  end, 10)
  H.ok(ok, "timed out waiting for: " .. code)
end

--- Every normal-mode mapping the plugin owns, as lhs -> true.
function Child:maps()
  return self:lua([[
    local out = {}
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if (m.desc or ""):find("^tmux%-sessions") then out[m.lhs] = m.desc end
    end
    return out
  ]])
end

--- The ghost float's state, or nil when it is not open.
function Child:ghost()
  return self:lua([[
    local G = require("tmux-sessions.ghost")
    local w = G._win()
    if not w or not vim.api.nvim_win_is_valid(w) then return nil end
    local cfg = vim.api.nvim_win_get_config(w)
    return {
      text = vim.api.nvim_buf_get_lines(G._buf(), 0, -1, false)[1],
      row = cfg.row, col = cfg.col, width = cfg.width, zindex = cfg.zindex,
      focusable = cfg.focusable, relative = cfg.relative,
    }
  ]])
end

function Child:stop()
  pcall(vim.fn.jobstop, self.chan)
end

-- Runner ----------------------------------------------------------------------

local passed, failed = 0, {}
local current_spec

function H.it(name, fn)
  local full = current_spec .. " › " .. name
  if filter and not full:find(filter, 1, true) then
    return
  end
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    io.write("  ok   ", full, "\n")
  else
    failed[#failed + 1] = full .. "\n" .. tostring(err)
    io.write("  FAIL ", full, "\n")
  end
end

local specs = vim.fn.glob(root .. "/tests/specs/*.lua", false, true)
table.sort(specs)
for _, path in ipairs(specs) do
  current_spec = vim.fn.fnamemodify(path, ":t:r")
  local spec = assert(loadfile(path))()
  spec(H)
end

io.write(("\n%d passed, %d failed\n"):format(passed, #failed))
for _, f in ipairs(failed) do
  io.write("\n", f, "\n")
end
os.exit(#failed == 0 and 0 or 1)
