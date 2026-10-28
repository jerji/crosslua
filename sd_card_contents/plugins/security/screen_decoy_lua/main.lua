-- Screen decoy (no radio, no storage): shows an ordinary-looking reading page. Confirm = next page,
-- up/left = previous, back = leave. Use it when someone is looking over your shoulder.
-- The inverted/high-contrast decoy and the duress wipe are in pin_lock_lua (duress PIN).

local PAGES = {
  { "Chapter 4", "", "The train slowed as it came into the valley, and the", "lights of the small station flickered once before the", "platform came into view. Nobody was waiting. She", "stepped down anyway and let the doors close behind her." },
  { "", "She had read the letter three times on the way up", "from the city, and each time the same line caught in her", "throat: the house was hers now, whether she wanted it or not.", "", "The stationmaster nodded at her ticket without looking up." },
  { "", "By dusk the rain had settled into the kind of steady", "grey that makes a village feel like the last place on", "the map. She found the inn, took the room at the top of", "the stairs, and sat by the window until the lamps came on." },
}

local ok, err = pcall(function()
  local W, H = gfx.size()
  local page = 1
  local function draw()
    gfx.clear()
    local y = 40
    for _, line in ipairs(PAGES[page]) do
      gfx.text(24, y, line, "ui12"); y = y + 30
    end
    gfx.text(24, H - 40, tostring(page), "small")
    gfx.present()
  end
  draw()
  while true do
    local e = input.wait()
    if e == "back" then break
    elseif e == "confirm" or e == "down" or e == "right" then page = page < #PAGES and page + 1 or 1; draw()
    elseif e == "up" or e == "left" then page = page > 1 and page - 1 or #PAGES; draw()
    end
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
