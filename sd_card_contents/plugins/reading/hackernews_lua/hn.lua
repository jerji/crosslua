-- Pure logic for the Hacker News app. No device namespaces, so the host-side
-- logic test can drive it under plain lua5.4 (WRITING_APPS.md 7.3).
--
-- Ported from the crossplay app (HackerNewsSaved / HackerNewsCore, see
-- crossplay/docs/apps/hackernews-saved-port.md): the saved-library format, the
-- front-page parse and the readability gate.
--
-- Library layout (the app holds a write grant on the folder HackerNews):
--   HackerNews/saved.tsv   the index: a "hnsaved 2" header, then one
--                          tab-separated row per article:
--                          <id>\t<savedAt>\t<title>\t<url>
--   HackerNews/<id>.txt    the article text, plain UTF-8. <id> is a stable
--                          32-bit FNV-1a of the URL in lowercase hex, short
--                          enough for a FAT filename and stable across
--                          reboots, so saving the same URL twice is one row.

local M = {}

-- --- FNV-1a, exact in int32 ----------------------------------------------
-- On the device Lua integers are 32-bit and floats are single precision, so a
-- straight h*16777619 overflows into a float32 and quietly loses bits. The
-- multiply is done mod 2^32 in 16-bit limbs with int32 intermediates instead;
-- the << 16 wraps mod 2^32 exactly (Lua 5.4 shift semantics).
local function fnv1a_byte(h, b)
  h = h ~ b
  local h0 = (h >> 16) & 0xFFFF
  local h1 = h & 0xFFFF
  local s = h0 * 0x193 + h1 * 0x100  -- (h0*403 + h1*256), fits int32
  local t = h1 * 0x193               -- fits int32
  return ((((s + (t >> 16)) & 0xFFFF) << 16) + (t & 0xFFFF))
end

function M.fnv1a32(url)
  local h = -2128831035  -- 0x811c9dc5 as int32, the FNV offset basis
  for i = 1, #url do h = fnv1a_byte(h, url:byte(i)) end
  return h
end

-- The saved-file / index id: lowercase hex, 8 digits. Written from the two
-- halves rather than string.format("%x", h) because %x on a negative int32
-- prints the full (64-bit on the host, 32-bit on the device) width.
function M.saved_id(url)
  local h = M.fnv1a32(url)
  return string.format("%04x%04x", (h >> 16) & 0xFFFF, h & 0xFFFF)
end

-- Flatten anything that would break the row format (tabs, newlines, CR) and
-- collapse whitespace runs. The URL column goes through this too, so it must
-- NOT fold typography: saved_id() hashes the URL, and a byte changed here is
-- an article that can never be unsaved again (the C++ original says the same).
function M.sanitize_field(s)
  s = s:gsub("^[ \t\r\n]+", "")
  s = s:gsub("[ \t\r\n]+$", "")
  return s:gsub("[ \t\r\n]+", " ")
end

-- The index as it is written to the card.
function M.serialize_index(articles)
  local out = { "hnsaved 2" }
  for _, a in ipairs(articles) do
    out[#out + 1] = a.id .. "\t" .. tostring(a.savedAt) .. "\t"
      .. M.sanitize_field(a.title) .. "\t" .. a.url
  end
  return table.concat(out, "\n") .. "\n"
end

-- Reads the index. nil = "not this format at all" (the file is left alone,
-- like the C++ parseSavedIndex); a damaged row is skipped rather than failing
-- the library, because losing one entry beats losing the shelf.
function M.parse_index(text)
  if type(text) ~= "string" then return nil end
  if text:sub(1, 7) ~= "hnsaved" then return nil end
  local nl = text:find("\n", 1, true)
  local header = nl and text:sub(1, nl - 1) or text
  local version = tonumber(header:sub(8)) or 0
  if version < 1 or version > 2 then return nil end
  local articles = {}
  if not nl then return articles end
  local rest = text:sub(nl + 1)
  for row in rest:gmatch("[^\n]+") do
    local t = {}
    local start = 1
    while true do
      local tab = row:find("\t", start, true)
      if not tab then t[#t + 1] = row:sub(start); break end
      t[#t + 1] = row:sub(start, tab - 1)
      start = tab + 1
    end
    local id, title, url
    local savedAt = tonumber(t[2]) or 0
    if version == 1 and #t >= 6 then
      -- The old shape sometimes carried an Instapaper bookmark id and a
      -- have-we-got-the-text flag, and sometimes did not. Count the row
      -- rather than trusting the header: a real v1 library in the wild has
      -- four columns (see the crossplay port notes).
      id, title, url = t[1], t[5], t[6]
    elseif #t >= 4 then
      id, title, url = t[1], t[3], t[4]
    end
    if id and id ~= "" and title and title ~= "" then
      articles[#articles + 1] = { id = id, savedAt = savedAt, title = title, url = url or "" }
    end
  end
  return articles
end

-- --- The front page ------------------------------------------------------
-- parse_hits consumes the DECODED "hits" array of
-- https://hn.algolia.com/api/v1/search?tags=front_page (the shape json.decode
-- produces: array part 1..n, JSON null as the nullv sentinel, numbers as
-- numbers, objectID as a string). Stories with an empty title are dropped,
-- like the C++ fetchFrontPage.
function M.parse_hits(hits, nullv)
  local out = {}
  if type(hits) ~= "table" then return out end
  for i = 1, #hits do
    local h = hits[i]
    if type(h) == "table" then
      local title = h.title
      if type(title) ~= "string" or title == "" then title = nil end
      if title then
        local u = h.url
        if u == nullv or type(u) ~= "string" then u = "" end
        local oid = h.objectID
        out[#out + 1] = {
          id = (oid and tonumber(oid)) or 0,
          title = title,
          url = u,
          comments = tonumber(h.num_comments) or 0,
          -- A story with no link is its own text; a link that can never be an
          -- article is marked before anything is fetched.
          readable = u == "" or M.url_can_be_article(u),
        }
      end
    end
  end
  return out
end

-- --- The readability gate -------------------------------------------------
-- The free half: URLs that cannot be an article no matter what comes back.
-- Same suffix and host lists as the C++ urlCanBeArticle.
function M.url_can_be_article(url)
  if url == "" then return false end
  local p = url:match("^[a-zA-Z][a-zA-Z0-9+.-]*://(.*)$") or url
  p = (p:match("^[^?#]*") or p):lower()
  for _, suf in ipairs({ ".pdf", ".zip", ".tar", ".gz", ".mp3", ".mp4",
                         ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp" }) do
    if p:sub(-#suf) == suf then return false end
  end
  for _, host in ipairs({ "twitter.com", "x.com/", "youtube.com", "youtu.be",
                          "reddit.com", "instagram.com", "tiktok.com",
                          "news.ycombinator.com" }) do
    if p:find(host, 1, true) then return false end
  end
  return true
end

-- --- Hacker News's own text ----------------------------------------------
-- Decode the entities HN emits (the five named ones it actually uses plus
-- &#NN; and &#xNN;), for text that is for DISPLAY only -- never for URLs.
-- The C++ folds typography on the way out; Lua has no fold, so the characters
-- are kept as decoded (deviation, see the report).
local NAMED = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }
function M.decode_entities(s)
  local out = {}
  local i = 1
  local n = #s
  while i <= n do
    if s:byte(i) ~= 38 then  -- &
      out[#out + 1] = s:sub(i, i)
      i = i + 1
    else
      local semi = s:find(";", i + 1, true)
      if not semi or semi - i > 10 then
        out[#out + 1] = "&"
        i = i + 1
      else
        local body = s:sub(i + 1, semi - 1)
        local rep
        if body:sub(1, 1) == "#" then
          local digits = body:sub(2)
          local hex = false
          if digits:sub(1, 1):lower() == "x" then hex = true; digits = digits:sub(2) end
          if digits ~= "" and digits:match("^[0-9a-fA-F]+$") then
            local v = tonumber(digits, hex and 16 or 10)
            -- Surrogate halves are dropped rather than paired (same as the
            -- C++ scanner); utf8.char would raise on them.
            if v and v > 0 and v <= 0x10FFFF then
              if v >= 0xD800 and v <= 0xDFFF then
                rep = ""  -- a lone surrogate half is not a character; consume
              else
                rep = utf8.char(v)
              end
            end
          end
        else
          rep = NAMED[body]
        end
        if rep then
          out[#out + 1] = rep
          i = semi + 1
        else
          out[#out + 1] = "&"
          i = i + 1
        end
      end
    end
  end
  return table.concat(out)
end

-- HN post text as paragraphs of plain text. Tags are stripped and entities
-- are decoded, with a paragraph break at every <p> and <br> (the whole of
-- HN's vocabulary; see the C++ paragraphsFromHnHtml).
function M.paragraphs_from_text(html)
  local out = {}
  local cur = {}
  local function flush()
    local para = M.decode_entities(table.concat(cur)):gsub("^%s+", ""):gsub("%s+$", "")
    if para ~= "" then out[#out + 1] = para end
    cur = {}
  end
  local i = 1
  local n = #html
  while i <= n do
    if html:byte(i) ~= 60 then  -- <
      cur[#cur + 1] = html:sub(i, i)
      i = i + 1
    else
      local close = html:find(">", i + 1, true)
      if not close then
        cur[#cur + 1] = "<"
        i = i + 1
      else
        local name = html:sub(i + 1, close - 1):match("^%s*([^%s>]+)") or ""
        name = name:gsub("/", ""):lower()
        if name == "p" or name == "br" then flush() end
        i = close + 1
      end
    end
  end
  flush()
  return out
end

-- --- The extractor's answer ----------------------------------------------
-- r.jina.ai prefixes its Markdown with a header (Title, URL Source, ...) and
-- a "Markdown Content:" line. Returns the title and the body.
function M.split_extractor(response)
  local marker = "Markdown Content:"
  local m = response:find(marker, 1, true)
  local header = m and response:sub(1, m - 1) or ""
  local body = m and response:sub(m + #marker) or response
  local title = ""
  for line in header:gmatch("[^\n]+") do
    if line:sub(1, 6) == "Title:" then
      title = line:sub(7):gsub("^%s+", ""):gsub("%s+$", "")
      break
    end
  end
  return title, body
end

-- --- Markdown -> prose, measured as it flattens --------------------------
-- delink: link labels kept, targets dropped, images dropped entirely. Same
-- rules as the C++ delinked().
local function delink(s)
  local out = {}
  local run = 1
  local pos = 1
  local n = #s
  while pos <= n do
    local b = s:byte(pos)
    local image = b == 33 and s:byte(pos + 1) == 91  -- ![
    if b == 91 or image then  -- [
      local open = image and pos + 1 or pos
      local close = s:find("]", open + 1, true)
      if close and close + 1 <= n and s:byte(close + 1) == 40 then  -- (
        local target = s:find(")", close + 2, true)
        if target then
          if run < pos then out[#out + 1] = s:sub(run, pos - 1) end
          if not image then out[#out + 1] = s:sub(open + 1, close - 1) end
          pos = target + 1
          run = pos
        else
          pos = pos + 1
        end
      else
        pos = pos + 1
      end
    else
      pos = pos + 1
    end
  end
  if run <= n then out[#out + 1] = s:sub(run) end
  return table.concat(out)
end

-- One line of Markdown, delinked and stripped of structure markers. This is
-- the C++ delinked() + paragraphsFromMarkdown folded into a streaming line
-- pass so the app never holds the raw body and the flattened text at once.
local function flatten_line(raw)
  local d = delink(raw)
  local n = #d
  local j = 1
  while j <= n and (d:byte(j) == 32 or d:byte(j) == 9) do j = j + 1 end
  local k = j
  while k <= n and d:byte(k) == 35 do k = k + 1 end  -- #
  if k > j and k <= n and d:byte(k) == 32 then
    d = d:sub(k + 1)  -- heading: drop the marker
  else
    local fb = d:byte(j)
    if j <= n and fb == 62 then  -- >
      d = d:sub(j + 1):gsub("^%s+", "")  -- quote: drop the marker
    elseif j + 1 <= n and (fb == 42 or fb == 45 or fb == 43) and d:byte(j + 1) == 32 then
      d = "- " .. d:sub(j + 2)  -- bullet: keep a marker that survives wrapping
    end
  end
  d = d:gsub("`+", ""):gsub("%*+", ""):gsub("_+", "")
  return d:gsub("^%s+", ""):gsub("%s+$", "")
end

-- The paid half of the gate, and the flattening, in one streaming pass.
-- Markdown blocks (paragraphs separated by blank lines) that read as prose --
-- at least kProseBlockMin chars, and not a list/heading/table/rule -- count
-- toward the kReadableThreshold total AND form the article text.
--
-- Returns (parts, truncated): the article body as concatable strings, or nil
-- when the page does not read as prose. `parts` is a table of pre-joined
-- paragraphs so the CALLER decides when to free the body and concatenate
-- (the Lua heap after a TLS request is the scarce resource, see API.md).
--
-- Deviations from the C++ gate, both consequences of streaming: the score is
-- the FLATTENED block length rather than the raw-delinked one (markers only,
-- not words, and the measured gap around the threshold is two orders of
-- magnitude), and typography is not folded.
local PROSE_BLOCK_MIN = 200
local READABLE_THRESHOLD = 600
function M.score_article(body, max_bytes)
  local parts = {}
  local total = 0
  local kept = 0
  local truncated = false
  local cur = {}
  local function flush()
    local block = table.concat(cur, " "):gsub("^%s+", ""):gsub("%s+$", "")
    cur = {}
    if block == "" then return end
    local first = block:byte(1)
    if #block >= PROSE_BLOCK_MIN and first ~= 42 and first ~= 45 and first ~= 124 and first ~= 35 then
      total = total + #block
      if not truncated and kept < max_bytes then
        local add = (kept == 0) and block or ("\n\n" .. block)
        if kept + #add <= max_bytes then
          parts[#parts + 1] = add
          kept = kept + #add
        else
          truncated = true
        end
      elseif kept >= max_bytes then
        truncated = true
      end
    end
  end
  for line in body:gmatch("[^\n]+") do
    if line:match("%S") then cur[#cur + 1] = flatten_line(line) else flush() end
  end
  flush()
  if total < READABLE_THRESHOLD then return nil end
  return parts, truncated
end

return M