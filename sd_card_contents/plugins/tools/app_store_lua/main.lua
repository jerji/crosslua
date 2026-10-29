-- app_store.lua — download + install the CrossLua apps bundle (crosslua-apps-*.zip) straight off the
-- GitHub release, then point the user at Home -> Plugins.
--
-- Three phases, because WiFi + a TLS handshake (~45 KB peak) + the unzip's 32 KB deflate window
-- cannot share one heap:
--   phase 1 (main.lua, wifi):  look up the latest release tag (JSON streamed to SD + pattern-scanned),
--                              write the derived bundle URL to data:store-url.txt, restart into download.lua.
--   phase 2 (download.lua):    a deliberately tiny app that only connects and downloads the zip to
--                              data:apps.zip. Loading main.lua here too would leave the handshake with
--                              no margin for the response headers (measured on-device: OOM abort at
--                              50.7 KB free), so the phase is a few-KB VM of its own.
--   phase 3 (main.lua, no radio): app.restart turned the radio off; the pristine heap installs the zip.
--
-- Phase selection is by pending flags alone, so the app is safe to relaunch at any step. A data:url.txt
-- override skips the release lookup. download.lua is REQUIRED (phase 2); an error there shows its own screen.
local URL_FILE = "data:url.txt"          -- explicit override (no lookup)
local STORE_URL = "data:store-url.txt"   -- derived URL written by phase 1, consumed by phase 2
local DOWNLOAD = "data:download-pending" -- phase 2 marker
local PENDING = "data:install-pending"   -- phase 3 marker
-- Same repository the OTA update check uses; the bundle URL is derived from its latest release tag.
local RELEASE_REPO = "jerji/crosslua"

local W, H
local fail  -- forward-declared so the phase functions can call it before its definition below

local function installPhase()
  gfx.clear(); gfx.text(16, 10, "Installing...", "ui12", "b"); gfx.present("fast")
  local ok3, n = app.install_plugin("data:apps.zip")
  fs.remove(PENDING)
  if not ok3 then return fail("Install failed: " .. tostring(n)) end

  gfx.clear()
  gfx.text(16, 10, "Done", "ui12", "b")
  gfx.line(0, 44, W - 1, 44)
  gfx.text(16, 60, "Installed " .. tostring(n) .. " files", "sans16", "b")
  gfx.text(16, 96, "Go to Home -> Plugins to", "sans16")
  gfx.text(16, 124, "see the apps, grouped by", "sans16")
  gfx.text(16, 152, "category.", "sans16")
  gfx.text(16, H - 34, "Back: quit", "small")
  gfx.present("fast")
  input.wait()
end

local function main()
  W, H = gfx.size()
  if fs.exists(PENDING) then
    installPhase()
    return
  end

  local url = nil
  local ov = fs.read(URL_FILE)
  if ov and ov:gsub("%s+$", "") ~= "" then url = ov:gsub("%s+$", "") end

  -- Connect FIRST, while free heap is still at launch levels: the TLS preflight wants 96 KB free and
  -- drawing the storefront first shaves the margin to nothing (measured on-device: 97,428 B -> fail).
  gfx.clear(); gfx.text(16, 10, "Connecting...", "ui12", "b"); gfx.present("fast")
  collectgarbage()
  local https = (url == nil) or (url:sub(1, 8) == "https://")  -- derived URLs are always GitHub HTTPS
  local ok, why
  if https then ok, why = wifi.connect() else ok, why = wifi.connect({ tls = false }) end
  if not ok then return fail("WiFi failed: " .. tostring(why)) end

  local lookupUrl = nil
  if not url then
    -- Derive the bundle URL from the release repo's latest tag, the same source the OTA update check uses.
    -- Stream the JSON to SD and pattern-scan for the tag: holding the full body (19 KB) plus
    -- json.decode on the post-WiFi heap starves the download phase that follows.
    gfx.clear(); gfx.text(16, 10, "Looking up the release...", "ui12", "b"); gfx.present("fast")
    local okr, errr = http.request{ url = "https://api.github.com/repos/" .. RELEASE_REPO .. "/releases/latest",
                                    save_to = "data:release.json", max_body = 65536 }
    local tag = nil
    if okr then
      local off, overlap = 0, ""
      while true do
        local chunk = fs.read("data:release.json", off, 512)
        if not chunk or #chunk == 0 then break end
        local found = (overlap .. chunk):match('"tag_name"%s*:%s*"([^"]+)"')
        if found then tag = found; break end
        overlap = overlap .. chunk
        overlap = overlap:sub(-24)  -- enough to catch a tag_name spanning the chunk boundary
        off = off + #chunk
      end
      fs.remove("data:release.json")
    end
    if not tag then
      return fail("Could not find the latest release: " .. tostring(okr and "bad response" or errr))
    end
    lookupUrl = "https://github.com/" .. RELEASE_REPO .. "/releases/download/" .. tag .. "/crosslua-apps-" .. tag .. ".zip"
    fs.write(STORE_URL, lookupUrl)
  else
    fs.write(STORE_URL, url)
  end

  -- Phase 2 (download.lua) does the actual download in a tiny VM; the phase-1 VM already proved the
  -- github.com TLS handshake peaking at ~45 KB here, and carrying this VM's loaded code into the
  -- download would leave no margin for it. Just hand off and restart.
  fs.write(DOWNLOAD, "1")
  gfx.clear(); gfx.text(16, 10, "Connecting to GitHub...", "ui12", "b"); gfx.present("fast")
  app.restart("download.lua")
end

fail = function(msg)
  local fh, mn, lb = system.heap()
  gfx.clear(); gfx.text(16, 10, "Failed", "ui12", "b")
  gfx.line(0, 44, W - 1, 44)
  gfx.text(16, 60, (msg or "error"):sub(1, 40), "small")
  gfx.text(16, 88, "free " .. fh .. " min " .. mn .. " blk " .. lb, "small")
  gfx.present("fast")
  input.wait()
end

local ok, err = pcall(main)
if not ok then
  fail("Error: " .. tostring(err):sub(1, 44))
end