-- notes_core.lua -- the rules behind the Notes app, ported from crossplay's
-- src/apps_local/notes (NotesCore.cpp + NotesLibrary.cpp).
--
-- A note is a Markdown file in the card folder Notes/ (the crossplay design
-- doc says /notes/; on this reader the app is granted the folder "Notes"),
-- and its NAME is its filename: Notes/Shopping.md is the list called
-- Shopping. One kind of line: a note is a LIST, where every drawn line has a
-- tick box, or a PAGE of words, where none does. The kind is inferred from
-- the file -- any "- [ ]" style marker makes it a list -- and it can be
-- switched with coerceToList / stripMarkers, because inference can be wrong.
--
-- The task marker is STRICT: optional leading space/tab, a '-', '*' or '+'
-- bullet, a space, '[', a space or x (either case), ']', and then a space or
-- the end of the line. "- [] milk" and "- [x]tra" are prose on purpose:
-- being permissive would mean a tick had to INSERT a byte. A tick flips
-- exactly one byte, so everything else in the file is preserved by
-- construction.
--
-- Files arrive from phones and desktop editors, so '\r\n' is a line ending,
-- never part of the text, and every rewrite preserves the ending it found.
--
-- The first half is pure (no fs); the second half is the fs-backed library.

local M = {}

local DIR = "Notes"           -- the card folder (design doc: /notes/)
local EXT = ".md"
local MAX_NAME = 64           -- a filename cap, counted in bytes
local MAX_NOTE = 16 * 1024    -- one screen of text, not a document
local MAX_NOTES = 120         -- deck rows capped like crossplay

local function isSpace(c) return c == 32 or c == 9 end        -- ' ' or '\t'
local function isBullet(c) return c == 45 or c == 42 or c == 43 end -- - * +

-- --------------------------------------------------------- pure rules --

-- Fills the task fields when the line begins with a strict task marker.
-- Anything else stays prose, which is the safe direction: a line wrongly
-- read as prose cannot be ticked, while a line wrongly read as a task would
-- put a tickable box on the user's sentence.
local function classify(doc, ln)
  local e = ln.e
  local i = ln.b
  while i <= e and isSpace(doc:byte(i)) do i = i + 1 end
  if i > e or not isBullet(doc:byte(i)) then return end
  i = i + 1
  if i > e or doc:byte(i) ~= 32 then return end              -- bullet space
  i = i + 1
  if i > e or doc:byte(i) ~= 91 then return end              -- '['
  local mark = i + 1
  if mark + 1 > e then return end
  local m = doc:byte(mark)
  if m ~= 32 and m ~= 120 and m ~= 88 then return end        -- ' ' 'x' 'X'
  if doc:byte(mark + 1) ~= 93 then return end                -- ']'
  local after = mark + 2
  if after <= e then
    -- the marker must be followed by a space or be the whole line, so
    -- "- [x]tra credit" stays prose and a tick never has to insert a byte
    if doc:byte(after) ~= 32 then return end
    after = after + 1
  end
  ln.task = true
  ln.checked = (m == 120 or m == 88)
  ln.m = mark
  ln.tb = after
end

-- Parse a document into line records {b, e, tb, m, task, checked}, where
-- b..e is the byte range of the line (e exclusive in the C++ sense: the last
-- byte is e; "\r" stripped from the end; "\n" never included) and tb is the
-- first byte of the visible text. A document ending in a newline keeps its
-- trailing empty line: it is a real line, and dropping it would make the
-- ranges disagree with the file on the next edit.
function M.parse(doc)
  local lines = {}
  local n = #doc
  local i = 1
  while i <= n + 1 do
    local b = i
    local j = i
    while j <= n and doc:byte(j) ~= 10 do j = j + 1 end      -- '\n'
    local e = j - 1
    if e >= b and doc:byte(e) == 13 then e = e - 1 end       -- '\r'
    local ln = { b = b, e = e, tb = b, m = 0, task = false, checked = false }
    classify(doc, ln)
    lines[#lines + 1] = ln
    if j > n then break end
    i = j + 1
  end
  return lines
end

-- Every non-empty line counts, marker or not (a line typed on a phone is part
-- of the list whether or not it arrived with a marker). Blank lines and the
-- trailing empty line are not items.
function M.counts(lines)
  local done, total, marked = 0, 0, 0
  for i = 1, #lines do
    local ln = lines[i]
    if ln.b <= ln.e then
      total = total + 1
      if ln.task then marked = marked + 1 end
      if ln.checked then done = done + 1 end
    end
  end
  return { done = done, total = total, marked = marked }
end

-- The kind belongs to the NOTE, never to the line: one tick box anywhere
-- makes the whole file a list. An empty note has no evidence either way, so
-- the caller's choice at creation decides (and the first line written
-- settles it for good).
function M.kindOf(lines, emptyIsList)
  local any = false
  for i = 1, #lines do
    local ln = lines[i]
    if ln.b <= ln.e then
      any = true
      if ln.task then return "list" end
    end
  end
  if any then return "page" end
  return (emptyIsList == false) and "page" or "list"
end

-- The visible text of a line (the marker skipped).
function M.textOf(doc, ln)
  if ln.tb > ln.e then return "" end
  return doc:sub(ln.tb, ln.e)
end

-- Flips exactly one byte: the ' ' or 'x' between the brackets. Returns the
-- new document, or nil when the line is not a task (the only way it can
-- fail).
function M.toggle(doc, ln)
  if not ln.task or ln.m < 1 or ln.m > #doc then return nil end
  local ch = ln.checked and " " or "x"
  ln.checked = not ln.checked
  return doc:sub(1, ln.m - 1) .. ch .. doc:sub(ln.m + 1)
end

-- Ticking a row on a list. A line written on a computer without the marker
-- becomes one ("- [x] " is inserted at the line's first byte) rather than
-- the app carrying a second kind of line forever; a marker is flipped.
function M.tickRow(doc, lines, li)
  local ln = lines[li]
  if not ln.task then
    return doc:sub(1, ln.b - 1) .. "- [x] " .. doc:sub(ln.b)
  end
  return M.toggle(doc, ln)
end

-- Removes every checked task line and returns the new document plus the
-- removed texts in file order. The line ending each line actually used is
-- kept, never normalised: a note edited on a desktop and cleared on the
-- device should not come back as a one-line diff of every row.
function M.clearChecked(doc, lines)
  local out, removed = {}, {}
  local n = #doc
  for i = 1, #lines do
    local ln = lines[i]
    local last = (i == #lines)
    if ln.task and ln.checked then
      removed[#removed + 1] = M.textOf(doc, ln)
    else
      out[#out + 1] = doc:sub(ln.b, ln.e)
      if not last then
        if ln.e < n and doc:byte(ln.e + 1) == 13 then out[#out + 1] = "\r" end
        out[#out + 1] = "\n"
      end
    end
  end
  return table.concat(out), removed
end

local function endings(doc, ln, isLast, out) -- shared line-ending writer
  if isLast then return end
  local n = #doc
  if ln.e < n and doc:byte(ln.e + 1) == 13 then out[#out + 1] = "\r" end
  out[#out + 1] = "\n"
end

-- Turns a page of words into a list: every non-blank line that is not
-- already a tick box becomes one, in place. Lines that carry a marker are
-- left byte for byte alone, so a save cannot disturb what was ticked on the
-- device; a blank line stays blank (somebody who pressed return twice meant
-- a gap, not a thing to do).
function M.coerceToList(doc, lines)
  local out, changed = {}, false
  for i = 1, #lines do
    local ln = lines[i]
    if ln.b > ln.e or ln.task then
      out[#out + 1] = doc:sub(ln.b, ln.e)
    else
      out[#out + 1] = "- [ ] " .. doc:sub(ln.b, ln.e)
      changed = true
    end
    endings(doc, ln, i == #lines, out)
  end
  return table.concat(out), changed
end

-- The counterpart: strips the marker (and the indent in front of it) off
-- every task line, turning a list back into words. Ticks are lost on the
-- way to a note, which is the honest outcome: a note has nothing to be done
-- with.
function M.stripMarkers(doc, lines)
  local out, changed = {}, false
  for i = 1, #lines do
    local ln = lines[i]
    if ln.task then
      out[#out + 1] = doc:sub(ln.tb, ln.e)
      changed = true
    else
      out[#out + 1] = doc:sub(ln.b, ln.e)
    end
    endings(doc, ln, i == #lines, out)
  end
  return table.concat(out), changed
end

-- The lines a note DRAWS, as indices into `lines`: every one except a blank
-- line and a marker with nothing after it. Both are spacing in the file, not
-- things to do, and an empty tick box is a hole in the list.
function M.drawnLines(doc, lines)
  local out = {}
  for i = 1, #lines do
    local ln = lines[i]
    if ln.b <= ln.e and M.textOf(doc, ln):find("[^%s]") then
      out[#out + 1] = i
    end
  end
  return out
end

-- A new line typed on the device: a tick box on a list, a plain line on a
-- note. The kind was decided when the note was made and the first line
-- writes it into the file, so this never has to guess.
function M.appendLine(doc, isList, text)
  local nd = doc
  if nd ~= "" and nd:sub(-1) ~= "\n" then nd = nd .. "\n" end
  if isList then nd = nd .. "- [ ] " end
  return nd .. text .. "\n"
end

-- --------------------------------------------------- the card library --

function M.path(name) return "sd:" .. DIR .. "/" .. name .. EXT end

-- Notes/ is made on first use; a mkdir that fails because the folder is
-- already there is fine -- the LIST is the test, and the card refusing
-- means the app cannot work at all.
function M.begin()
  fs.mkdir("sd:" .. DIR)
  local names, err = fs.list("sd:" .. DIR)
  if not names then return nil, err end
  return true
end

function M.load(name)
  local doc = fs.read(M.path(name))
  if not doc then return nil end
  if #doc > MAX_NOTE then doc = doc:sub(1, MAX_NOTE) end
  return doc
end

-- The write IS the test: no free-space probe on the way in (fs here has no
-- card walk, and the write already fails and reports it on a full card -- a
-- probe would buy nothing but a better sentence, and it is not even
-- available). fs.write is atomic (temp file + rename) by construction, so
-- the .part staging crossplay does is not needed. The refusal is shown
-- verbatim.
function M.save(name, doc)
  local ok, err = fs.write(M.path(name), doc)
  if not ok then
    if type(err) == "string" and err ~= "" then return nil, err end
    return nil, "The card would not take the change."
  end
  return true
end

-- What a name may be: a filename on a FAT card. Trimmed of surrounding
-- space (otherwise invisible in a list and makes two notes look identical);
-- separators and wildcards dropped, never substituted; capped at 64 bytes.
-- A name that is only dots names this directory or its parent, so it is
-- refused.
function M.sanitise(name)
  local out = name:gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
  out = out:gsub("[/\\:*?\"<>|\r\n]", "")
  if #out > MAX_NAME then out = out:sub(1, MAX_NAME) end
  if out == "." or out == ".." then return "" end
  return out
end

-- FAT is case-insensitive, so two notes whose names differ only in case are
-- ONE file; comparing case-sensitively here would let "shopping" silently
-- overwrite "Shopping".
function M.exists(entries, name)
  local wanted = M.sanitise(name):lower()
  for i = 1, #entries do
    if entries[i].name:lower() == wanted then return true end
  end
  return false
end

-- Re-reads the directory on every entry to the deck: the card can be edited
-- from a computer between sessions, and an app that trusts a cached list
-- offers notes that are not there any more. Every entry's tally is counted
-- here, which costs one read per note; notes are small and few, and the
-- alternative is an index file that can disagree with the notes it indexes.
-- Alphabetical, case-insensitively: the order a person can predict.
function M.scan()
  local out = {}
  local names, err = fs.list("sd:" .. DIR)
  if not names then return nil, err end
  for _, fn in ipairs(names) do
    if fn:sub(-1) ~= "/" and fn:sub(-#EXT) == EXT then
      local name = fn:sub(1, #fn - #EXT)
      if name ~= "" then
        local doc = M.load(name) or ""
        local lines = M.parse(doc)
        local c = M.counts(lines)
        local row = {
          name = name, done = c.done, total = c.marked, marked = c.marked,
          hasTasks = c.marked > 0, preview = "",
        }
        if not row.hasTasks then
          -- a note's card shows its first words instead of a tally; only the
          -- first line with something on it
          for j = 1, #lines do
            local t = M.textOf(doc, lines[j]):gsub("^[ \t]+", "")
            if t ~= "" then
              row.preview = (#t > 80) and t:sub(1, 80) or t
              break
            end
          end
        end
        out[#out + 1] = row
        if #out >= MAX_NOTES then break end
      end
    end
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

-- A new, empty note. False when the name is unusable or already taken, and
-- the caller is told which.
function M.create(entries, name)
  local clean = M.sanitise(name)
  if clean == "" then return nil, "That name cannot be used." end
  if M.exists(entries, clean) then
    return nil, "There is already a note called that."
  end
  local ok, msg = M.save(clean, "")
  if not ok then return nil, msg end
  table.insert(entries, {
    name = clean, done = 0, total = 0, marked = 0,
    hasTasks = false, preview = "",
  })
  table.sort(entries, function(a, b) return a.name:lower() < b.name:lower() end)
  return clean
end

-- Renaming a note is a file rename: the note's name is its filename, so one
-- source of truth and nothing has to decide which of two titles wins.
function M.rename(entries, from, to)
  local clean = M.sanitise(to)
  if clean == "" then return nil, "That name cannot be used." end
  if clean == from then return true end
  if M.exists(entries, clean) then
    return nil, "There is already a note called that."
  end
  local ok, err = fs.rename(M.path(from), M.path(clean))
  if not ok then
    if type(err) == "string" and err ~= "" then return nil, err end
    return nil, "The card would not take the change."
  end
  for i = 1, #entries do
    if entries[i].name == from then entries[i].name = clean end
  end
  table.sort(entries, function(a, b) return a.name:lower() < b.name:lower() end)
  return true
end

function M.remove(entries, name)
  local ok = fs.remove(M.path(name))
  for i = 1, #entries do
    if entries[i].name == name then
      table.remove(entries, i)
      break
    end
  end
  return ok
end

return M