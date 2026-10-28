-- Hacker News: the front page and the SAVED shelf (CrossLua port of the
-- crossplay app; see crossplay/docs/apps/hackernews-saved-port.md).
--
-- Ported behaviour, in the C++ app's own words:
--   * The app opens on the front-page list with the radio down. Only a tap
--     that needs the network raises it; the SAVED shelf always works.
--   * Back from an article opened out of the library returns to the
--     library, not the front page.
--   * Removing the article you are currently reading drops you back to the
--     list.
--   * A failed fetch lands on the list (TRY AGAIN / LOAD), never on a dead
--     end: every notice carries a way back.
--
-- The library is plain text files in the storage-granted folder HackerNews:
-- HackerNews/saved.tsv (the index) and HackerNews/<fnv1a8>.txt (one article
-- per file), readable in any editor and recoverable by hand. See hn.lua.
--
-- RAM discipline (API.md figures): wifi.connect needs 96 KB free, TLS needs
-- 40 KB free + a 20 KB contiguous block at each request and only ~5 KB of
-- live Lua data while the handshake runs, and after connect only ~44 KB of
-- device RAM is free (guard drops to 12 KB). So: connect while the heap is
-- near-empty, hold one response at a time, drop the story list and the old
-- document before every request, and cap the article at ~12 KB of text. The
-- front page, which the C++ keeps in RAM, is cached to data:front.json so
-- returning from the reader (and relaunching) restores it without the radio.

local hn              -- required inside __main so a load error hits the pcall

local BAND_H = 44
local SEG_H = 26
local FOOT_H = 40
local MAX_STORIES = 20
local ARTICLE_MAX = 12000          -- bytes of article text the reader holds
local FONT_BAND = "ui12"
local FONT_BODY = "sans14"
local FONT_SMALL = "ui12"
local kFrontPage = "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=" .. MAX_STORIES
local kExtractor = "https://r.jina.ai/"
local kSelfPost = "https://hn.algolia.com/api/v1/search?tags=story_"  -- one request per item
local kIndex = "sd:HackerNews/saved.tsv"
local kFrontCache = "data:front.json"
local UNREACHABLE = "Could not reach Hacker News. Saved articles still work."

-- --- state ----------------------------------------------------------------
local W, H = 0, 0
local phase = "list"        -- "list" | "reader" | "notice"
local view = "front"        -- "front" | "saved"
local stories = {}          -- front page: {id,title,url,comments,readable}
local saved = {}            -- library: {id,savedAt,title,url}
local saved_ids = {}        -- id -> true, the reader's save mark
local front_failed = false  -- draw the failed empty state
local cursor = 1
local doc = ""              -- the document the reader is holding
local doc_title = ""
local reader_url = ""
local reading_saved = false  -- back returns to the SAVED shelf
local top_line = 0
local line_offsets = {}      -- byte offset of each wrapped line start
local line_count = 0
local save_toast = nil
local notice_headline, notice_message = "", ""

-- --- wifi / network -------------------------------------------------------
local function connected()
  local s = wifi.status()
  return s and s.connected
end

local function ensure_wifi()
  if connected() then return true end
  return wifi.connect()   -- TLS-capable by default; needs 96 KB free, sees
end                       -- the system flow (picker/keyboard) when needed

-- Before ANY TLS request: the handshake needs ~40 KB free RAM, so only ~5 KB
-- of Lua data may be live. The story list goes to the card cache instead.
local function prepare_request()
  stories = {}
  doc = ""
  line_offsets = {}
  collectgarbage()
end

local function fetch_json(url, max_body)
  if type(http) ~= "table" then return nil, "http unavailable" end
  return http.request({ url = url, max_body = max_body })
end

-- --- the library ----------------------------------------------------------
local function library_load()
  local text = fs.read(kIndex)
  if text then
    local parsed = hn.parse_index(text)
    saved = parsed or {}
  else
    saved = {}
  end
  saved_ids = {}
  for _, a in ipairs(saved) do saved_ids[a.id] = true end
end

local function restore_front_page()
  local cached = fs.read(kFrontCache)
  if cached then
    local hits = json.decode(cached)
    cached = nil
    if hits then
      local hh = hits.hits
      if type(hh) == "table" then stories = hn.parse_hits(hh, json.null) end
    end
    if #stories > 0 then cursor = 1; return true end
  end
  return false
end

-- --- fetching --------------------------------------------------------------
local function fetch_front_page()
  local r, why = fetch_json(kFrontPage, 20480)
  if not r then
    print("hn: front page fetch failed: " .. tostring(why))
    return false
  end
  if not r.ok then
    print("hn: front page HTTP " .. tostring(r.status))
    return false
  end
  -- Keep a card copy: the list must survive the next TLS request dropping
  -- the 20-story table (the C++ holds it in RAM; Lua cannot).
  fs.write(kFrontCache, r.body)
  local hits = json.decode(r.body)
  r.body = nil
  collectgarbage()
  if not hits then
    print("hn: front page decode failed")
    return false
  end
  stories = {}
  if hits and type(hits.hits) == "table" then stories = hn.parse_hits(hits.hits, json.null) end
  hits = nil
  return #stories > 0
end

local function fetch_self_post(st)
  local r, why = fetch_json(kSelfPost .. st.id .. "&hitsPerPage=1", 8192)
  if not r then
    print("hn: self-post fetch failed: " .. tostring(why))
    return nil
  end
  if not r.ok then
    print("hn: self-post HTTP " .. tostring(r.status))
    return nil
  end
  local hits = json.decode(r.body)
  r.body = nil
  collectgarbage()
  local text = nil
  if hits and hits.hits and type(hits.hits[1]) == "table" then
    local t = hits.hits[1].text
    if type(t) == "string" and t ~= "" then text = t end
  end
  if not text then return nil end
  local paras = hn.paragraphs_from_text(text)
  if #paras == 0 then return nil end
  return table.concat(paras, "\n\n")
end

local function fetch_article(st)
  local r, why = fetch_json(kExtractor .. st.url, 16384)
  if not r then
    print("hn: article fetch failed: " .. tostring(why))
    return nil
  end
  if not r.ok then
    print("hn: article HTTP " .. tostring(r.status))
    return nil
  end
  local title, body = hn.split_extractor(r.body)
  r.body = nil
  collectgarbage()
  local parts, truncated = hn.score_article(body, ARTICLE_MAX)
  body = nil
  collectgarbage()
  if not parts then return nil end  -- the readability gate
  local text = table.concat(parts)
  if truncated then text = text .. "\n\n…" end
  return { title = title ~= "" and title or st.title, text = text }
end

-- --- drawing ---------------------------------------------------------------
local function ellipsize(s, font, width)
  while #s > 0 and gfx.text_width(s .. "…", font) > width do
    s = s:sub(1, -2)
  end
  return s .. "…"
end

local function fit_lines(text, font, width, max_lines)
  local lines = {}
  local line = ""
  for word in (text .. " "):gmatch("%S+") do
    local cand = line == "" and word or (line .. " " .. word)
    if gfx.text_width(cand, font) <= width then
      line = cand
    else
      if line ~= "" then
        lines[#lines + 1] = line
        if #lines >= max_lines then
          lines[max_lines] = ellipsize(lines[max_lines], font, width)
          return table.concat(lines, "\n")
        end
      end
      line = word
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  if #lines > max_lines then
    lines[max_lines] = ellipsize(lines[max_lines], font, width)
  end
  return table.concat(lines, "\n")
end

local function draw_band(title)
  gfx.rect(0, 0, W, BAND_H, true)
  gfx.text(16, 14, title, FONT_BAND, "bw")
end

local function draw_segments()
  local cw = W / 2
  local y = BAND_H
  for _, seg in ipairs({ { "FRONT PAGE", "front" }, { "SAVED", "saved" } }) do
    local x = seg[2] == "front" and 0 or cw
    local active = view == seg[2]
    if active then gfx.rect(x + 4, y + 3, cw - 8, SEG_H - 6, true) end
    gfx.text(x + cw / 2, y + SEG_H / 2 - 8, seg[1], FONT_BAND, active and "bwc" or "c")
  end
end

local function draw_footer(hint)
  gfx.line(0, H - FOOT_H, W, H - FOOT_H)
  if hint then gfx.text(16, H - FOOT_H + 10, hint, FONT_SMALL) end
end

local function draw_empty_state()
  local hl, msg, action
  if view == "saved" then
    hl, msg = "NOTHING SAVED YET", "Tap SAVE while you read."
  elseif front_failed then
    hl, msg, action = "NO LUCK", UNREACHABLE, "TRY AGAIN"
  else
    hl, msg, action = "NOT LOADED YET", "The front page needs a connection. Saved articles do not.", "LOAD"
  end
  local y = BAND_H + SEG_H + 60
  gfx.text(16, y, hl, FONT_BODY, "b")
  y = y + 36
  local wrapped = fit_lines(msg, FONT_BODY, W - 32, 6)
  for line in (wrapped .. "\n"):gmatch("(.-)\n") do
    gfx.text(16, y, line, FONT_BODY)
    y = y + gfx.line_height(FONT_BODY)
  end
  if action then
    y = y + 14
    gfx.text(16, y, "[confirm] " .. action, FONT_SMALL, "b")
  end
end

local function draw_list()
  gfx.clear()
  draw_band(view == "saved" and "SAVED" or "HACKER NEWS")
  draw_segments()
  local src = view == "saved" and saved or stories
  local y0 = BAND_H + SEG_H + 6
  local lh = gfx.line_height(FONT_BODY)
  local small = gfx.line_height(FONT_SMALL)
  local row_h = lh * 2 + small + 8
  local rows_visible = math.max(1, math.floor((H - y0 - FOOT_H - 6) / row_h))
  if #src == 0 then
    draw_empty_state()
    draw_footer("left/right shelf · confirm " .. (view == "front" and "load" or "") .. " · back exit")
    gfx.present()
    return
  end
  local top_i = cursor - math.floor(rows_visible / 2)
  if top_i < 0 then top_i = 0 end
  if top_i > #src - rows_visible then top_i = #src - rows_visible end
  for i = 1, rows_visible do
    local idx = top_i + i
    if idx > #src then break end
    local y = y0 + (i - 1) * row_h
    local selected = idx == cursor
    if selected then gfx.rect(0, y - 2, W, row_h, true) end
    local item = src[idx]
    local ty = selected and "w" or nil
    local title = fit_lines(item.title, FONT_BODY, W - 32, 2)
    local yy = y
    for line in (title .. "\n"):gmatch("(.-)\n") do
      gfx.text(16, yy, line, FONT_BODY, ty)
      yy = yy + lh
    end
    if view == "front" then
      gfx.text(16, yy + 2, tostring(item.comments) .. " comments", FONT_SMALL, ty)
    end
  end
  draw_footer("left/right shelf · up/down move · confirm open · back exit")
  gfx.present()
end

local function reader_visible()
  local lh = gfx.line_height(FONT_BODY)
  local body_top = BAND_H + 8
  return math.max(1, math.floor((H - body_top - FOOT_H - 8) / lh))
end


local function draw_reader()
  gfx.clear()
  draw_band(fit_lines(doc_title, FONT_BAND, W - 32, 1))
  local lh = gfx.line_height(FONT_BODY)
  local y0 = BAND_H + 8
  local visible = reader_visible()
  local y = y0
  for i = 1, visible do
    local idx = top_line + i
    if idx > line_count then break end
    local from = line_offsets[idx]
    local to = (line_offsets[idx + 1] and line_offsets[idx + 1] - 1) or #doc
    local s = doc:sub(from, to):gsub("%s+$", "")
    gfx.text(16, y, s, FONT_BODY)
    y = y + lh
  end
  gfx.line(0, H - FOOT_H, W, H - FOOT_H)
  local pages = math.max(1, math.ceil(line_count / visible))
  local page = math.max(1, math.floor(top_line / visible) + 1)
  local label = page .. " / " .. pages
  if reader_url ~= "" then
    label = label .. "  [" .. (is_saved(reader_url) and "SAVED" or "SAVE") .. "]"
  end
  gfx.text(16, H - FOOT_H + 10, "up next · down prev · confirm save/unsave · back", FONT_SMALL)
  gfx.text(W - 16, H - FOOT_H + 10, label, FONT_SMALL, "r")
  if save_toast then
    local tw = gfx.text_width(save_toast, FONT_SMALL)
    local bw = math.min(tw, W - 40)
    gfx.rect((W - bw) / 2 - 8, H / 2 - 16, bw + 16, 32, true)
    gfx.text(W / 2, H / 2 - 9, save_toast, FONT_SMALL, "wc")
  end
  gfx.present()
end

local function draw_notice()
  gfx.clear()
  gfx.text(16, 48, notice_headline, FONT_BODY, "b")
  local y = 96
  local wrapped = fit_lines(notice_message, FONT_BODY, W - 32, 12)
  for line in (wrapped .. "\n"):gmatch("(.-)\n") do
    gfx.text(16, y, line, FONT_BODY)
    y = y + gfx.line_height(FONT_BODY)
  end
  draw_footer("back")
  gfx.present()
end

local function draw_busy(label)
  gfx.clear()
  gfx.text(16, 48, label, FONT_BODY, "b")
  draw_footer("back cancels")
  gfx.present()
end

-- --- reading ---------------------------------------------------------------
local function wrap_lines(text, font, width)
  local offsets = { 1 }
  local line_len = 0
  local space_w = gfx.text_width(" ", font)
  local i = 1
  local n = #text
  while i <= n do
    local ws = text:find("%s", i)
    if ws and ws > i then
      local word = text:sub(i, ws - 1)
      local ww = gfx.text_width(word, font)
      if line_len > 0 and line_len + ww > width then
        offsets[#offsets + 1] = i
        line_len = ww
      else
        line_len = line_len + (line_len > 0 and space_w or 0) + ww
      end
    end
    local wend = ws or (n + 1)
    while wend <= n and text:find("%s", wend) == wend do wend = wend + 1 end
    i = wend
  end
  return offsets
end

local function enter_reader()
  phase = "reader"
  top_line = 0
  save_toast = nil
  line_offsets = wrap_lines(doc, FONT_BODY, W - 32)
  line_count = #line_offsets
end

local function turn_page(delta)
  save_toast = nil
  local visible = reader_visible()
  local max_top = line_count > visible and (line_count - visible) or 0
  if delta > 0 then
    top_line = top_line + visible > max_top and max_top or top_line + visible
  else
    top_line = top_line > visible and top_line - visible or 0
  end
  draw_reader()
end

local function is_saved(url)
  return saved_ids[hn.saved_id(url)] == true
end

local function save_current()
  if reader_url == "" or doc == "" then return end
  local id = hn.saved_id(reader_url)
  local ok, werr = fs.write("sd:HackerNews/" .. id .. ".txt", doc)
  if not ok then
    print("hn: article write failed: " .. tostring(werr))
    save_toast = "Not saved: the card is full."
    draw_reader()
    return
  end
  library_load()
  local found = false
  for _, a in ipairs(saved) do
    if a.id == id then a.title = doc_title; found = true; break end
  end
  if not found then
    saved[#saved + 1] = { id = id, savedAt = time.now() or 0, title = doc_title, url = reader_url }
  end
  local iok, ierr = fs.write(kIndex, hn.serialize_index(saved))
  if not iok then
    print("hn: index write failed: " .. tostring(ierr))
    library_load()  -- the card does not hold the row; say so honestly
    save_toast = "Not saved: the card is full."
    draw_reader()
    return
  end
  saved_ids[id] = true
  draw_reader()
end

local function unsave_current()
  if reader_url == "" then return end
  local id = hn.saved_id(reader_url)
  library_load()
  for i, a in ipairs(saved) do
    if a.id == id then table.remove(saved, i); break end
  end
  saved_ids[id] = nil
  fs.write(kIndex, hn.serialize_index(saved))
  -- Row first, then the file: a file with no row is a few unreferenced KB the
  -- next save of the same URL overwrites. Failure to remove is not a failure.
  local rok = fs.remove("sd:HackerNews/" .. id .. ".txt")
  if not rok then print("hn: article file not removed") end
  if reading_saved then
    view = "saved"
    reading_saved = false
    phase = "list"
  end
  doc = ""
  line_offsets = {}
  draw_list()
end

local function return_to_list()
  if reading_saved then view = "saved" end
  reading_saved = false
  doc = ""
  line_offsets = {}
  phase = "list"
  -- The front-page list was dropped before the last fetch; bring it back
  -- from the card copy, no radio needed.
  if view == "front" and #stories == 0 then restore_front_page() end
  draw_list()
end

local function show_notice(headline, message)
  phase = "notice"
  notice_headline, notice_message = headline, message
  draw_notice()
end

-- --- opening ---------------------------------------------------------------
local function open_story(st)
  if st.url == "" then
    -- A post with no link is its own text, fetched ONE item per request from
    -- the search endpoint (the item endpoint returns the whole thread, which
    -- a ~96 KB Lua heap cannot hold).
    draw_busy("OPENING")
    prepare_request()
    local okw = ensure_wifi()
    if not okw then
      phase = "list"
      if view == "front" and #stories == 0 then restore_front_page() end
      draw_list()
      return
    end
    local body = fetch_self_post(st)
    if not body then
      show_notice("NO LUCK", UNREACHABLE)
      return
    end
    doc = body
    doc_title = st.title
    reader_url = "https://news.ycombinator.com/item?id=" .. st.id
    reading_saved = false
    enter_reader()
    draw_reader()
  elseif not st.readable then
    show_notice("NOT READABLE HERE",
      "That link is a PDF, a video, or a page that only a browser can open. There is no article text to bring back.")
  else
    draw_busy("OPENING")
    prepare_request()
    local okw = ensure_wifi()
    if not okw then
      phase = "list"
      if view == "front" and #stories == 0 then restore_front_page() end
      draw_list()
      return
    end
    local article = fetch_article(st)
    if not article then
      show_notice("NO LUCK", UNREACHABLE)
      return
    end
    doc = article.text
    doc_title = article.title
    reader_url = st.url
    reading_saved = false
    enter_reader()
    draw_reader()
  end
end

local function open_saved(i)
  local a = saved[i]
  if not a then return end
  local text = fs.read("sd:HackerNews/" .. a.id .. ".txt")
  if not text then
    show_notice("NOT THERE", "That article is in the list but its text is missing from the card.")
    return
  end
  doc = text
  doc_title = a.title
  reader_url = a.url
  reading_saved = true
  enter_reader()
  draw_reader()
end

local function do_load()
  draw_busy("FETCHING THE FRONT PAGE")
  prepare_request()
  local okw = ensure_wifi()
  if not okw then phase = "list"; draw_list(); return end
  front_failed = false
  if not fetch_front_page() then front_failed = true end
  phase = "list"
  draw_list()
end

-- --- the app ---------------------------------------------------------------
local function __main()
  hn = require("hn")
  W, H = gfx.size()
  library_load()
  phase = "list"
  view = "front"
  front_failed = false
  cursor = 1
  draw_list()

  while true do
    local e = input.wait()
    if phase == "list" then
      if e == "back" then
        app.exit()
        return
      elseif e == "confirm" then
        local rows = view == "saved" and saved or stories
        if #rows == 0 then
          if view == "front" then do_load() end
        elseif view == "saved" then
          open_saved(cursor)
        else
          open_story(stories[cursor])
        end
      elseif e == "up" then
        local rows = view == "saved" and saved or stories
        if #rows > 0 and cursor > 1 then cursor = cursor - 1; draw_list() end
      elseif e == "down" then
        local rows = view == "saved" and saved or stories
        if #rows > 0 and cursor < #rows then cursor = cursor + 1; draw_list() end
      elseif e == "left" then
        if view ~= "saved" then view = "saved"; cursor = 1; draw_list() end
      elseif e == "right" then
        if view ~= "front" then view = "front"; cursor = 1; draw_list() end
      end
    elseif phase == "reader" then
      if e == "back" then
        return_to_list()
      elseif e == "confirm" then
        if reader_url ~= "" then
          if is_saved(reader_url) then unsave_current() else save_current() end
        end
      elseif e == "up" or e == "right" then
        turn_page(1)
      elseif e == "down" or e == "left" then
        turn_page(-1)
      end
    else  -- notice
      if e == "back" or e == "confirm" then return_to_list() end
    end
  end
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end