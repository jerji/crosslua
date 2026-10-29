-- app_store.lua — download + install the CrossLua apps bundle (crosslua-apps-*.zip) straight off the
-- GitHub release, then point the user at Home -> Plugins.
--
-- Two phases by design: the firmware's heap after a WiFi download cannot also run the unzip (the deflate window
-- alone is a 32 KB contiguous block, and the post-download heap is fragmented), so phase 1 downloads the bundle,
-- drops data:install-pending and app.restart(\"main.lua\") — a fresh VM with the radio back off. Phase 2 starts
-- immediately in that fresh VM, installs, and exits normally.
local URL_FILE = "data:url.txt"
local PENDING = "data:install-pending"
-- Same repository the OTA update check uses; the bundle URL is derived from its latest release tag (or overridden by
-- data:url.txt, e.g. a local test bundle).
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
  local shown = url and (url:match("([^/]+%.zip)") or url) or ("latest release (" .. RELEASE_REPO .. ")")

  gfx.clear()
  gfx.text(16, 10, "App Store", "ui12", "b")
  gfx.line(0, 44, W - 1, 44)
  gfx.text(16, 60, "Installs every CrossLua app", "sans16", "b")
  gfx.text(16, 96, "from the release zip.", "sans16")
  gfx.text(16, 128, shown:sub(1, 42), "small")
  gfx.text(16, H - 60, "Confirm: download + install", "small")
  gfx.text(16, H - 34, "Back: quit", "small")
  gfx.present("fast")
  if input.wait() ~= "confirm" then return end

  gfx.clear(); gfx.text(16, 10, "Connecting...", "ui12", "b"); gfx.present("fast")
  collectgarbage()  -- free gfx/font/string temps: the WiFi preflight needs ~80 KB (plain) / 96 KB (TLS)
  local https = url:sub(1, 8) == "https://"
  local ok, why
  if https then ok, why = wifi.connect() else ok, why = wifi.connect({ tls = false }) end
  if not ok then return fail("WiFi failed: " .. tostring(why)) end

  gfx.clear(); gfx.text(16, 10, "Downloading...", "ui12", "b")
  gfx.text(16, 50, shown:sub(1, 42), "small"); gfx.present("fast")
  if not url then
    -- Derive the bundle URL from the release repo's latest tag, the same source the OTA update check uses.
    gfx.clear(); gfx.text(16, 10, "Looking up the release...", "ui12", "b"); gfx.present("fast")
    local okr, bodyr = http.request{ url = "https://api.github.com/repos/" .. RELEASE_REPO .. "/releases/latest",
                                     max_body = 65536 }
    local tag = nil
    if okr then
      local rel = json.decode(bodyr)
      if rel and rel.tag_name then tag = tostring(rel.tag_name):gsub("^v", "") end
    end
    if not tag then
      return fail("Could not find the latest release: " .. tostring(okr and "bad response" or bodyr))
    end
    url = "https://github.com/" .. RELEASE_REPO .. "/releases/download/" .. tag .. "/crosslua-apps-" .. tag .. ".zip"
    shown = url:match("([^/]+%.zip)") or url
    gfx.clear(); gfx.text(16, 10, "Downloading...", "ui12", "b")
    gfx.text(16, 50, shown:sub(1, 42), "small"); gfx.present("fast")
  end
  local ok2, err2 = http.request{ url = url, save_to = "data:apps.zip" }
  if not ok2 then return fail("Download failed: " .. tostring(err2)) end

  -- Install in a fresh VM: app.restart turns the radio back off, and the unzip needs the contiguous heap that frees.
  fs.write(PENDING, "1")
  gfx.clear(); gfx.text(16, 10, "Downloaded. Installing...", "ui12", "b"); gfx.present("fast")
  app.restart("main.lua")
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