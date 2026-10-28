-- ao3/works.lua: pure helpers for the AO3 update checker. No device calls here, so
-- the parsing can be checked under the host lua5.4.

local M = {}

M.LIST = "sd:Books/AO3/works.txt"
M.DIR = "sd:Books/AO3/"

-- works.txt: one work per line, "12345" or "12345 | label" or a full work URL.
-- Blank lines and lines starting with # are skipped; duplicates are dropped.
function M.parse_works(text)
  local list, seen = {}, {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local id = line:match("works/(%d+)") or line:match("^(%d+)")
      if id and not seen[id] then
        seen[id] = true
        local label = line:match("|%s*(.-)%s*$")
        if label == "" then label = nil end
        list[#list + 1] = { id = id, label = label }
      end
    end
  end
  return list
end

-- The navigate page lists every chapter of the work (small page, no text).
-- view_adult=true so adult-rated works do not stop at the content warning.
function M.navigate_url(id)
  return "https://archiveofourown.org/works/" .. id .. "/navigate?view_adult=true"
end

-- The whole work as one EPUB. AO3 routes by id; the file-name part is cosmetic.
function M.download_url(id)
  return "https://archiveofourown.org/downloads/" .. id .. "/work.epub"
end

function M.book_path(id)
  return M.DIR .. id .. ".epub"
end

-- Number of distinct chapters linked from the navigate page. A single-chapter
-- work has no chapter index, so the caller treats 0 as 1.
function M.chapter_count(html, id)
  local seen, n = {}, 0
  for cid in html:gmatch("/works/" .. id .. "/chapters/(%d+)") do
    if not seen[cid] then
      seen[cid] = true
      n = n + 1
    end
  end
  return n
end

-- Work title from the page heading, tags stripped, a few entities decoded.
function M.work_title(html)
  local t = html:match('<h2[^>]*class="title heading"[^>]*>(.-)</h2>')
  if not t then return nil end
  t = t:gsub("<[^>]+>", ""):gsub("^%s+", ""):gsub("%s+$", "")
  t = t:gsub("&amp;", "&"):gsub("&#39;", "'"):gsub("&quot;", '"'):gsub("&lt;", "<"):gsub("&gt;", ">")
  if t == "" then return nil end
  return t:sub(1, 120)
end

return M
