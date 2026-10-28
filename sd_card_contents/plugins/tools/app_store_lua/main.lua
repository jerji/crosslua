-- app_store.lua — download + install the CrossLua apps bundle (crosslua-apps-*.zip) straight off the
-- GitHub release, then point the user at Home -> Plugins. First cut: pick the right URL in this file
-- (or drop a data:url.txt override), confirm once, and it does the rest.
--
-- Follow-up ideas (not done): resolve "latest" via the GitHub API, pin the TLS cert, a check-for-updates
-- view. The install primitive (app.install_plugin) is the only hard part and it is core.

local URL_FILE = "data:url.txt"
-- The crosslua-apps-<version>.zip asset of the current release. Bump the version on each release, or put the
-- full URL in data:url.txt to override without editing this file.
local DEFAULT_URL = "https://github.com/jerji/crosslua/releases/download/2.1.0-crosslua.1/crosslua-apps-2.1.0-crosslua.1.zip"

local W, H
local fail  -- forward-declared so main() can call it before its definition below

local function main()
  W, H = gfx.size()
  local url = DEFAULT_URL
  local ov = fs.read(URL_FILE)
  if ov then url = (ov:gsub("%s+$", "")) end
  local shown = url:match("([^/]+%.zip)") or url

  gfx.clear()
  gfx.text(16, 10, "App Store", "ui12", "b")
  gfx.line(0, 44, W - 1, 44)
  gfx.text(16, 60, "Installs every CrossLua app", "sans16", "b")
  gfx.text(16, 96, "from the release zip.", "sans16")
  gfx.text(16, 128, shown:sub(1, 42), "small")
  gfx.text(16, H - 60, "Confirm: download + install", "small")
  gfx.text(16, H - 34, "Back: quit", "small")
  gfx.present("full")
  if input.wait() ~= "confirm" then return end

  gfx.clear(); gfx.text(16, 10, "Connecting...", "ui12", "b"); gfx.present("fast")
  local ok, why = wifi.connect()
  if not ok then return fail("WiFi failed: " .. tostring(why)) end

  gfx.clear(); gfx.text(16, 10, "Downloading...", "ui12", "b")
  gfx.text(16, 50, shown:sub(1, 42), "small"); gfx.present("fast")
  local ok2, err2 = http.request{ url = url, save_to = "data:apps.zip" }
  if not ok2 then return fail("Download failed: " .. tostring(err2)) end

  gfx.clear(); gfx.text(16, 10, "Installing...", "ui12", "b"); gfx.present("fast")
  local ok3, n = app.install_plugin("data:apps.zip")
  if not ok3 then return fail("Install failed: " .. tostring(n)) end

  gfx.clear()
  gfx.text(16, 10, "Done", "ui12", "b")
  gfx.line(0, 44, W - 1, 44)
  gfx.text(16, 60, "Installed " .. tostring(n) .. " files", "sans16", "b")
  gfx.text(16, 96, "Go to Home -> Plugins to", "sans16")
  gfx.text(16, 124, "see the apps, grouped by", "sans16")
  gfx.text(16, 152, "category.", "sans16")
  gfx.text(16, H - 34, "Back: quit", "small")
  gfx.present("full")
  input.wait()
end

fail = function(msg)
  gfx.clear(); gfx.text(16, 10, "Failed", "ui12", "b")
  gfx.line(0, 44, W - 1, 44)
  gfx.text(16, 60, (msg or "error"):sub(1, 44), "small")
  gfx.present("full")
  input.wait()
end

local ok, err = pcall(main)
if not ok then
  fail("Error: " .. tostring(err):sub(1, 44))
end
app.restart("main.lua")