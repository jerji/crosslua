-- Ruby capture browser (read grant: Captures). Lists the .pcap files in sd:Captures, summarises each
-- capture, lists its packets and shows one packet in detail (hex + addresses). Read-only: only fs.list,
-- fs.size and fs.read are used. Nothing is written, nothing is transmitted.

local SRC = "sd:Captures"
local MAX_SCAN = 20000   -- records counted per file
local MAX_INDEX = 256    -- packets kept in RAM for the packet list
local MAX_SSID = 64      -- distinct beacon SSIDs kept for the summary
local SNAP = 200        -- bytes read per packet (radiotap + 802.11 header + tags)
local LH = 24
local W, H = 0, 0

local LT_NAME = { [105] = "802.11", [127] = "802.11+radiotap" }
local MGMT = {
  [0] = "assoc-req", [1] = "assoc-resp", [2] = "reassoc-req", [3] = "reassoc-resp",
  [4] = "probe-req", [5] = "probe-resp", [8] = "beacon", [10] = "disassoc",
  [11] = "auth", [12] = "deauth",
}
local LLC_EAPOL = "\170\170\3\0\0\0\136\142"   -- AA AA 03 00 00 00 88 8E

local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function frame_top(title)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, clip(title, 30), "ui12", "bw")
end

local function wrapped(lines, y)
  for _, l in ipairs(lines) do
    if l == "" then y = y + 10 else
      for _, w in ipairs(gfx.wrap(l, W - 28, "small")) do
        if y < H - 50 then gfx.text(14, y, w, "small") end
        y = y + 22
      end
    end
  end
  return y
end

local function message(title, lines)
  frame_top(title)
  wrapped(lines, 56)
  gfx.text(14, H - 34, "Back = return", "small"); gfx.present()
  while input.wait() ~= "back" do end
end

-- Generic scrolling list. label(i) is called only for visible rows. Returns the chosen index or nil.
local function list_view(title, n, label, hint)
  local cur, top = 1, 1
  while true do
    frame_top(title)
    local per = math.floor((H - 100) / LH)
    if n == 0 then gfx.text(14, 60, "(nothing here)", "ui12") end
    if cur < top then top = cur end
    if cur >= top + per then top = cur - per + 1 end
    local y = 56
    for i = top, math.min(n, top + per - 1) do
      local s = clip(label(i), 44)
      if i == cur then
        gfx.rect(10, y - 4, W - 20, LH + 4, true); gfx.text(16, y, s, "small", "w")
      else
        gfx.text(16, y, s, "small")
      end
      y = y + LH
    end
    gfx.text(14, H - 34, hint, "small")
    gfx.present()
    local e = input.wait()
    if e == "up" and n > 0 then cur = cur > 1 and cur - 1 or n
    elseif e == "down" and n > 0 then cur = cur < n and cur + 1 or 1
    elseif e == "confirm" and n > 0 then return cur
    elseif e == "back" then return nil end
  end
end

-- 802.11 classification. Returns kind, ssid (beacon/probe only).
local function decode(f)
  if #f < 2 then return "short", nil end
  local b0, flags = f:byte(1), f:byte(2)
  local ftype, sub = (b0 >> 2) & 3, (b0 >> 4) & 15
  if ftype == 0 then
    local kind = MGMT[sub] or ("mgmt-" .. sub)
    local ssid
    if sub == 8 or sub == 5 or sub == 4 then
      local p = (sub == 4) and 25 or 37          -- tagged params start after the fixed fields
      if f:byte(p) == 0 and #f >= p + 1 then     -- tag 0 = SSID
        local len = f:byte(p + 1)
        ssid = f:sub(p + 2, p + 1 + len):gsub("[^%g ]", "?")
      end
    end
    return kind, ssid
  elseif ftype == 1 then
    return "ctrl", nil
  elseif ftype == 2 then
    local hl = 24
    if (flags & 3) == 3 then hl = hl + 6 end     -- WDS addressing
    if (sub & 8) ~= 0 then hl = hl + 2 end       -- QoS control
    return (f:sub(hl + 1, hl + 8) == LLC_EAPOL) and "EAPOL" or "data", nil
  end
  return "other", nil
end

-- Returns frame (802.11 bytes, radiotap stripped), kind, ssid for the record data at doff.
local function read_frame(S, doff, incl)
  local d = fs.read(S.path, doff, math.min(incl, SNAP)) or ""
  local frame = d
  if S.linktype == 127 and #d >= 4 then frame = d:sub(string.unpack("<I2", d, 3) + 1) end
  local kind, ssid = decode(frame)
  return frame, kind, ssid
end

local function scan_progress(n)
  frame_top("Scanning")
  gfx.text(14, 60, string.format("%d packets so far", n), "ui12")
  gfx.present()
end

-- Reads the PCAP header and walks every record once. Keeps the first MAX_INDEX packets for the list.
local function scan_file(path)
  local hdr = fs.read(path, 0, 24)
  if not hdr or #hdr < 24 then return nil, "file too short" end
  if (string.unpack("<I4", hdr, 1)) ~= 0xa1b2c3d4 then return nil, "not a classic PCAP (bad magic)" end
  local S = {
    path = path, size = fs.size(path) or 0, linktype = string.unpack("<I4", hdr, 21),
    n = 0, counts = {}, kinds = {}, ssids = {}, ssid_list = {},
    idx_off = {}, idx_len = {}, idx_ts = {}, first = nil, last = nil,
  }
  local off = 24
  while off + 16 <= S.size and S.n < MAX_SCAN do
    local rh = fs.read(path, off, 16)
    if not rh or #rh < 16 then break end
    local sec, usec, incl = string.unpack("<I4I4I4", rh)
    if incl > 262144 then break end              -- corrupt record header: stop here
    local ts = sec * 1000000 + usec
    S.n = S.n + 1
    S.first = S.first or ts
    S.last = ts
    local _, kind, ssid = read_frame(S, off + 16, incl)
    S.counts[kind] = (S.counts[kind] or 0) + 1
    if kind == "beacon" and ssid and not S.ssids[ssid] and #S.ssid_list < MAX_SSID then
      S.ssids[ssid] = true
      S.ssid_list[#S.ssid_list + 1] = ssid
    end
    if S.n <= MAX_INDEX then
      S.idx_off[S.n], S.idx_len[S.n], S.idx_ts[S.n] = off + 16, incl, ts
    end
    if S.n % 2000 == 0 then scan_progress(S.n) end
    off = off + 16 + incl
  end
  S.first = S.first or 0
  S.last = S.last or 0
  return S
end

local function summary(S, name)
  frame_top(name)
  local lines = {
    string.format("Linktype %d (%s), %d bytes", S.linktype, LT_NAME[S.linktype] or "unknown", S.size),
    string.format("%d packets%s, span %.1f s", S.n, S.n >= MAX_SCAN and " (scan cap)" or "", (S.last - S.first) / 1e6),
    "",
  }
  local keys = {}
  for k in pairs(S.counts) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return S.counts[a] > S.counts[b] end)
  for _, k in ipairs(keys) do lines[#lines + 1] = string.format("%-12s %d", k, S.counts[k]) end
  if #S.ssid_list > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Beacon SSIDs: " .. table.concat(S.ssid_list, ", ")
  end
  wrapped(lines, 52)
  gfx.text(14, H - 34, "Confirm = packets, Back = files", "small"); gfx.present()
  while true do
    local e = input.wait()
    if e == "confirm" then return "packets" elseif e == "back" then return nil end
  end
end

local function pkt_label(S, i)
  local k = S.kinds[i]
  if not k then
    local _, kind = read_frame(S, S.idx_off[i], S.idx_len[i])
    k = kind
    S.kinds[i] = k
  end
  return string.format("%3d  +%8.2fs  %-9s %5dB", i, (S.idx_ts[i] - S.first) / 1e6, k, S.idx_len[i])
end

local function mac(f, o)
  if #f < o + 6 then return "--" end
  return string.format("%02x:%02x:%02x:%02x:%02x:%02x", f:byte(o + 1, o + 6))
end

local function detail(S, i)
  while true do
    local frame, kind, ssid = read_frame(S, S.idx_off[i], S.idx_len[i])
    frame_top(string.format("#%d  %s", i, kind))
    local y = 52
    local function ln(s) gfx.text(14, y, clip(s, 56), "small"); y = y + 22 end
    ln(string.format("time +%.3f s   captured %d B", (S.idx_ts[i] - S.first) / 1e6, S.idx_len[i]))
    ln("type " .. kind .. (ssid and ("   SSID \"" .. ssid .. "\"") or ""))
    ln("addr1 " .. mac(frame, 4))
    ln("addr2 " .. mac(frame, 10))
    ln("addr3 " .. mac(frame, 16))
    y = y + 12
    for r = 0, 2 do                               -- first 48 bytes of the frame, 16 per row
      local parts = {}
      for b = r * 16 + 1, math.min(#frame, r * 16 + 16) do
        parts[#parts + 1] = string.format("%02x", frame:byte(b))
      end
      if #parts > 0 then ln(table.concat(parts, " ")) end
    end
    gfx.text(14, H - 34, "Left/Right = prev/next, Back = list", "small"); gfx.present()
    local e = input.wait()
    if e == "back" then return
    elseif e == "left" and i > 1 then i = i - 1
    elseif e == "right" and i < #S.idx_off then i = i + 1 end
  end
end

local function main()
  W, H = gfx.size()
  local names = fs.list(SRC)
  if not names then
    return message("Ruby captures", {
      "No Captures folder on the card.",
      "Copy .pcap files into sd:Captures/ on the SD card. This app reads that folder only, read-only.",
    })
  end
  while true do
    local files = {}
    for _, f in ipairs(names) do
      if f:lower():match("%.pcap$") then files[#files + 1] = f end
    end
    local pick = list_view("Captures", #files, function(i)
      return string.format("%s  (%d KB)", files[i], math.floor((fs.size(SRC .. "/" .. files[i]) or 0) / 1024))
    end, "Confirm = open, Back = exit")
    if not pick then return end
    local name = files[pick]
    local S, err = scan_file(SRC .. "/" .. name)
    if not S then
      message(name, { "Cannot read capture: " .. tostring(err) })
    else
      while summary(S, name) == "packets" do
        local hint = string.format("Confirm = detail, Back = summary (%d of %d listed)", #S.idx_off, S.n)
        local i = list_view(name, #S.idx_off, function(k) return pkt_label(S, k) end, hint)
        if not i then break end
        detail(S, i)
      end
    end
  end
end

local ok, err = pcall(main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
