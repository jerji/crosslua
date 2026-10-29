-- download.lua — phase 2 of the Lua App Store: nothing but connect + download.
--
-- Deliberately TINY and deliberately DUMB: no drawing at all until the download ends. The
-- store's main.lua holds ~18 KB of Lua heap; even this thin VM loads to ~95 KB free, which is
-- only a couple KB past the TLS-connect floor, so any font caching before the request could
-- starve the zip's TLS handshake (~45 KB peak). Screens are drawn after the download only.
-- Phase 3 (main.lua with data:install-pending set) does the actual install.
local STORE_URL = "data:store-url.txt"   -- derived URL written by phase 1
local PENDING = "data:install-pending"   -- phase 3 marker
local DOWNLOAD = "data:download-pending" -- this phase's marker

local function fail(msg)
  local fh, mn, lb = system.heap()
  local W, H = gfx.size()
  gfx.clear(); gfx.text(16, 10, "Failed", "ui12", "b")
  gfx.line(0, 44, W - 1, 44)
  gfx.text(16, 60, (msg or "error"):sub(1, 40), "small")
  gfx.text(16, 88, "free " .. fh .. " min " .. mn .. " blk " .. lb, "small")
  gfx.present("fast")
  input.wait()
end

local ok, err = pcall(function()
  local url = fs.read(STORE_URL)
  if not url or url:gsub("%s+$", "") == "" then return fail("No bundle URL found — relaunch the store.") end
  url = url:gsub("%s+$", "")

  collectgarbage()
  local okl, whyl
  if url:sub(1, 8) == "https://" then okl, whyl = wifi.connect() else okl, whyl = wifi.connect({ tls = false }) end
  if not okl then return fail("WiFi failed: " .. tostring(whyl)) end

  local ok2, err2 = http.request{ url = url, save_to = "data:apps.zip" }
  if not ok2 then return fail("Download failed: " .. tostring(err2)) end

  fs.remove(DOWNLOAD)
  fs.write(PENDING, "1")
  local W, H = gfx.size()
  gfx.clear(); gfx.text(16, 10, "Downloaded. Installing...", "ui12", "b"); gfx.present("fast")
  app.restart("main.lua")
end)
if not ok then
  if type(err) == "table" and err.message then err = err.message end
  return fail("Error: " .. tostring(err):sub(1, 44))
end