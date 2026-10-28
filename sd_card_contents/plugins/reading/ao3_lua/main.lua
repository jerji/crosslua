-- AO3 & Library: one app for the library and every AO3 tool.
-- Home is the paged library grid (each cell's glyph = saved progress). Hold
-- Confirm opens the AO3 menu: continue reading, page as QR, chapter updates
-- and EPUB downloads, the metadata index, archive and restore. Back leaves a
-- screen; Back on the home grid exits. Features live in their own modules.

local function __main()
  local grid = require("grid")
  local hub = require("hub")
  while true do
    if grid.run() ~= "hub" then break end   -- nil = Back on home: leave
    hub.run()                               -- returns to the grid on Back
  end
  app.exit()
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end
