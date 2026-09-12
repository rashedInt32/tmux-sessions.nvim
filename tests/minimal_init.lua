-- Init for the child nvim the suite drives over RPC: the plugin and nothing else.
-- setup() is deliberately not called here, so each spec chooses its own options.
local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")
vim.opt.runtimepath:append(root)
vim.o.swapfile = false
vim.o.shortmess = vim.o.shortmess .. "I"
vim.g.mapleader = " "
vim.cmd("runtime plugin/tmux-sessions.lua")
