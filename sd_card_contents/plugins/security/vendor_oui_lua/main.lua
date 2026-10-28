-- Vendor OUI lookup (no radio, no network). Looks up the first 3 bytes of a MAC address in the IEEE
-- MA-L registry. The data ships in this folder: oui.idx (sorted fixed records: 3-byte OUI + 3-byte offset
-- into oui.names) and oui.names (one vendor line per record, newline-terminated). The lookup is a binary
-- search over the index, reading only 6 bytes per step, so the table never has to fit in RAM.
-- Source: IEEE OUI registry (https://standards-oui.ieee.org/oui/oui.txt), converted to these two files.

local IDX = "app:oui.idx"
local NAMES = "app:oui.names"
local REC = 6
local N = 40418

local function txt(...) return input.text(...) or "" end

local function lookup(oui3)
  local lo, hi = 0, N - 1
  while lo <= hi do
    local mid = (lo + hi) // 2
    local rec = fs.read(IDX, mid * REC, REC)
    if not rec or #rec < REC then return nil, "index read failed" end
    local key = rec:sub(1, 3)
    if key == oui3 then
      local off = string.unpack(">I3", rec, 4)
      local line = fs.read(NAMES, off, 100) or ""
      return (line:match("^([^\n]*)") or "")
    elseif key < oui3 then
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return nil
end

local function show(lines)
  gfx.clear(); local W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Vendor lookup (OUI)", "ui12", "bw")
  local y = 60
  for _, l in ipairs(lines) do gfx.text(14, y, l, "ui12"); y = y + 30 end
  gfx.text(14, H - 34, "Confirm = look up another, Back = exit", "small")
  gfx.present()
end

local ok, err = pcall(function()
  show({ "Enter a MAC address to look up." })
  while true do
    local e = input.wait()
    if e == "back" then break end
    if e == "confirm" then
      local mac = txt("MAC (e.g. 00:00:0C:12:34:56)", "", 17)
      local hex = mac:gsub("[:%-%.]", "")
      if #hex < 6 or hex:find("[^%x]") then
        show({ "not a MAC address" })
      else
        local oui = crypto.unhex(hex:sub(1, 6))
        local vendor, why = lookup(oui)
        local label = string.format("%s:%s:%s", hex:sub(1, 2), hex:sub(3, 4), hex:sub(5, 6)):upper()
        if vendor then show({ label, vendor })
        elseif why then show({ label, why })
        else show({ label, "not in the registry (unassigned or locally administered)" }) end
      end
    end
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
