-- The AO3 menu (opened by holding Confirm on the library grid). Each entry is
-- one feature screen; a feature returns here on Back.

local ui = require("ui")

local M = {}

local ENTRIES = {
  { "Continue reading", function() require("shelf").run("continue") end },
  { "Page as QR", function() require("shelf").run("qr") end },
  { "AO3 updates: check and download", function() require("ao3.update").run() end },
  { "AO3 indexer: scan Books/AO3", function() require("ao3.indexer").run() end },
  { "AO3 archive and restore", function() require("ao3.archive").run() end },
}

function M.run()
  local labels = {}
  for i, e in ipairs(ENTRIES) do labels[i] = e[1] end
  while true do
    local pick = ui.menu("AO3 menu", labels, "Confirm: open   Back: library")
    if not pick then return end
    ENTRIES[pick][2]()
  end
end

return M
