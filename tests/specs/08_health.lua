-- :checkhealth. The version parse is the only logic worth isolating.
return function(H)
  local Health = require("tmux-sessions.health")

  H.it("reads a version out of tmux -V's various shapes", function()
    H.eq({ 3, 7 }, { Health._parse_version("tmux 3.7c\n") })
    H.eq({ 3, 0 }, { Health._parse_version("tmux 3.0a") })
    H.eq({ 2, 9 }, { Health._parse_version("tmux 2.9") })
    H.eq({ 3, 4 }, { Health._parse_version("tmux next-3.4") })
  end)

  H.it("an unparseable version is nil, not a crash", function()
    H.eq(nil, (Health._parse_version("tmux master")))
    H.eq(nil, (Health._parse_version("")))
  end)

  H.it("checkhealth runs end to end without erroring", function()
    local c = H.child({}, { TMUX = "/tmp/s,1,2" })
    local out = c:lua([[
      local ok, err = pcall(vim.cmd, "checkhealth tmux-sessions")
      if not ok then return tostring(err) end
      local lines = {}
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].filetype == "checkhealth" then
          lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        end
      end
      return table.concat(lines, "\n")
    ]])
    H.contains(out, "tmux-sessions.nvim")
    H.ok(not out:find("stack traceback", 1, true), "health check must not throw")
    c:stop()
  end)
end
