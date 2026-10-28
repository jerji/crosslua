-- NOTES -- lists you tick with one hand and words to keep. A port of the
-- crossplay Notes app (src/apps_local/notes) to CrossLua; the product rules
-- live in notes_core.lua (ported from NotesCore.cpp / NotesLibrary.cpp, see
-- crossplay/docs/apps/notes-design.md).
--
-- A list is a Markdown file in Notes/ on the card, and its NAME is its
-- filename. One kind of line: a note is a LIST, where every drawn line has a
-- tick box, or a PAGE of words, where none does. A tick flips exactly one
-- byte and is written IMMEDIATELY, never on the way out.
--
-- Screens: the deck (+ LIST / + NOTE), the note (tick boxes, ADD, CLEAR
-- DONE, the menu), the menu (MAKE IT A LIST/NOTE, RENAME, DELETE NOTE), the
-- delete confirm (KEEP IT / DELETE IT) and notices. No touchscreen: a cursor
-- moves with up/down (left/right pages on the deck and note, and switches
-- the two footer buttons), confirm acts, back goes up a level.
--
-- Not ported from the design doc: TYPE ON YOUR PHONE (a hotspot + web
-- server + QR — the doc itself says nothing in the app needs it, and a
-- radio mode would eat most of the ~85 KB Lua heap) and the sleep screen
-- (no CrossLua API to set the sleep screen or write /.crosspoint). See the
-- app report.

local cores = require("notes_core")

-- ------------------------------------------------------------- geometry --

local W, H = gfx.size()
local MARGIN = 16
local HDR = 64                 -- the band is chrome; nothing resizes it
local FTR = 48
local FTR_Y = H - MARGIN - FTR
local BODY_TOP = HDR + 12
local BODY_BOT = FTR_Y - 10
local F_BODY = "sans16"
local F_SMALL = "ui12"
local F_TALL = "sans18"
local LH = gfx.line_height(F_BODY)
local LHS = gfx.line_height(F_SMALL)
local PAD = 10                 -- air above and below an item's text
local PARA_GAP = 12            -- between two paragraphs of a page
local GROW_CAP = 36            -- max a row grows when the list fits one page
local MINROW = math.max(48, LH + 24)  -- button cursor, not a finger
local BOX = 40                 -- tick box side
local BOX_GAP = 12
local CARD_H, CARD_GAP, CARD_PITCH = 100, 12, 112
local BADGE = 72
local NAME_MAX_CHARS = 40      -- draw guard; naming refuses by measure

-- -------------------------------------------------------------- state --

local S = {
  -- deck
  entries = {}, deckTop = 1, deckCur = 1,
  -- open note
  open = "", doc = "", lines = {}, rows = {}, blocks = {},
  pStarts = { 1 }, isPage = false, newIsList = true,
  done = 0, marked = 0, noteTop = 1, noteCur = 1,
  -- other views
  menuCur = 1, confCur = 1, notice = "",
  view = "deck", ready = true,
}

local function anyDone()
  for i = 1, #S.rows do
    if S.lines[S.rows[i]].checked then return true end
  end
  return false
end

local function deckVisible()
  return math.max(1, (BODY_BOT - BODY_TOP + CARD_GAP) // CARD_PITCH)
end

local function noteTopY()
  return (not S.isPage and S.marked > 0) and (BODY_TOP + 4 + 10 + 10 + 8) or BODY_TOP
end

local function noteBandH() return BODY_BOT - noteTopY() end

-- ------------------------------------------------------------ drawing --

local function fit(s, maxW, font)      -- cut to width on a whole UTF-8 char
  if gfx.text_width(s, font) <= maxW then return s end
  local out, k, n = "", 1, #s
  while k <= n do
    local ch = s:sub(k, k)
    k = k + 1
    while k <= n and s:byte(k) >= 128 and s:byte(k) < 192 do
      ch = ch .. s:sub(k, k)
      k = k + 1
    end
    if gfx.text_width(out .. ch, font) > maxW then break end
    out = out .. ch
  end
  return out
end

local function header(title, right)
  gfx.rect(0, 0, W, HDR, true)
  local room = W - 2 * MARGIN - (right and gfx.text_width(right, F_SMALL) + 12 or 0)
  gfx.text(MARGIN, 20, fit(title, math.max(40, room), F_TALL), F_TALL, "w")
  if right then gfx.text(W - MARGIN, 22, right, F_SMALL, "wr") end
end

local function marker(x, y, h, on)
  if on then gfx.rect(x - 10, y + 4, 5, math.max(8, h - 8), true) end
end

-- a button slot: filled (makes something) on the left, outlined (takes
-- something away) on the right; selection is a black bar beside the slot
local function button(x, y, w, h, label, sel, filled)
  if filled then
    gfx.rect(x, y, w, h, true)
    gfx.text(x + w / 2, y + (h - LHS) / 2, label, F_SMALL, "wc")
  else
    gfx.rect(x, y, w, h, false)
    gfx.rect(x + 1, y + 1, w - 2, h - 2, false)
    gfx.text(x + w / 2, y + (h - LHS) / 2, label, F_SMALL, "c")
  end
  marker(x, y, h, sel)
end

local function footer(btns, focal)
  local n = #btns
  local gap = 10
  local bw = (W - 2 * MARGIN - gap * (n - 1)) / n
  local x = MARGIN
  for i = 1, n do
    button(x, FTR_Y, bw, FTR, btns[i].label, i == focal, btns[i].filled)
    x = x + bw + gap
  end
end

local function bar(x, y, w, h, done, total)
  gfx.rect(x, y, w, h, false)
  if total > 0 and done > 0 then
    local fw = math.max(3, math.min(w, math.floor(w * done / total)))
    gfx.rect(x, y, fw, h, true)
  end
end

-- words wrapped by measure: each line is measured as a whole run, so sizing
-- and drawing cannot disagree; a run of letters wider than the row (a pasted
-- URL) is split at a character boundary, never inside a UTF-8 sequence
local function pushSplit(word, out, maxW)
  local acc, k = "", 1
  while k <= #word do
    local c = word:sub(k, k)
    k = k + 1
    while k <= #word and word:byte(k) >= 128 and word:byte(k) < 192 do
      c = c .. word:sub(k, k)
      k = k + 1
    end
    local cand = acc .. c
    if acc ~= "" and gfx.text_width(cand, F_BODY) > maxW then
      out[#out + 1] = acc
      acc = c
    else
      acc = cand
    end
  end
  if acc ~= "" then out[#out + 1] = acc end
end

local function wrap(text, maxW)
  local out, cur = {}, ""
  local i, n = 1, #text
  while true do
    local sp = text:find(" ", i, true)
    local e = sp and (sp - 1) or n
    local word = ""
    if e >= i then word = text:sub(i, e) end
    if word ~= "" then
      local cand = (cur == "") and word or (cur .. " " .. word)
      if gfx.text_width(cand, F_BODY) <= maxW then
        cur = cand
      else
        if cur ~= "" then out[#out + 1] = cur; cur = "" end
        if gfx.text_width(word, F_BODY) <= maxW then
          cur = word
        else
          pushSplit(word, out, maxW)
        end
      end
    end
    if not sp then break end
    i = sp + 1
  end
  if cur ~= "" then out[#out + 1] = cur end
  if #out == 0 then out[#out + 1] = "" end
  return out
end

-- the last line of an item cut at its cap, shortened until "..." fits beside
local function endWithEllipsis(line, maxW)
  local s = line
  while s ~= "" and gfx.text_width(s .. "...", F_BODY) > maxW do
    local sp = s:match("^(.*) ")
    if sp and sp ~= "" then
      s = sp
    else
      local k = #s
      while k > 1 and s:byte(k) >= 128 and s:byte(k) < 192 do k = k - 1 end
      s = s:sub(1, k - 1)
    end
  end
  return s .. "..."
end

local function previewToWidth(text, maxW)
  if gfx.text_width(text, F_SMALL) <= maxW then return text end
  local out, i, n = "", 1, #text
  while i <= n do
    local sp = text:find(" ", i, true)
    local e = sp and (sp - 1) or n
    local word = text:sub(i, e)
    local cand = (out == "") and word or (out .. " " .. word)
    if gfx.text_width(cand .. "...", F_SMALL) > maxW then break end
    out = cand
    if not sp then break end
    i = sp + 1
  end
  if out == "" then                     -- one word wider than the strip
    local k, ch = 1, ""
    while k <= n do
      ch = text:sub(k, k)
      k = k + 1
      while k <= n and text:byte(k) >= 128 and text:byte(k) < 192 do
        ch = ch .. text:sub(k, k)
        k = k + 1
      end
      if gfx.text_width(out .. ch .. "...", F_SMALL) > maxW then break end
      out = out .. ch
    end
  end
  return out .. "..."
end

-- ------------------------------------------------------------- layout --

local function pageLabelReserve() return LHS + 12 end

-- greedy pages by HEIGHT; an item never splits across pages. On a page of
-- words a paragraph never leaves ONE line behind at a break, at either end.
local function pageStarts(blocks, height)
  local starts = { 1 }
  local y, i, count = 0, 1, #blocks
  while i <= count do
    local b = blocks[i]
    local gap = (b.paraStart and y > 0) and PARA_GAP or 0
    if y > 0 and y + gap + b.height > height then
      local at = i
      if S.isPage and not b.paraStart then
        local begin = i
        while begin > 1 and not blocks[begin].paraStart do begin = begin - 1 end
        local last = i + 1
        while last <= count and not blocks[last].paraStart do last = last + 1 end
        if i - begin == 1 then
          at = begin                    -- only the first line would stay
        elseif last - i == 1 and i - begin >= 3 then
          at = i - 1                    -- only the last line would carry over
        end
        if at <= starts[#starts] then at = i end  -- never empty the page it leaves
      end
      starts[#starts + 1] = at
      y = 0
      i = at
    else
      y = y + gap + b.height
      i = i + 1
    end
  end
  return starts
end

local function layoutBlocks()
  local blocks = {}
  local bandH = noteBandH()
  if S.isPage then
    local bodyW = W - 2 * MARGIN
    for _, ri in ipairs(S.rows) do
      local ls = wrap(cores.textOf(S.doc, S.lines[ri]), bodyW)
      for li = 1, #ls do
        blocks[#blocks + 1] = {
          item = ri, lines = { ls[li] }, height = LH, paraStart = li == 1,
        }
      end
    end
  else
    local textW = W - 2 * MARGIN - BOX - BOX_GAP
    -- a list item never outgrows a page: past the cap it is cut with "..."
    -- (whole on the phone page), measured against the band a PAGED list has
    local cap = math.max(1, (bandH - pageLabelReserve() - 2 * PAD) // LH)
    for _, ri in ipairs(S.rows) do
      local ls = wrap(cores.textOf(S.doc, S.lines[ri]), textW)
      if #ls > cap then
        local cut = {}
        for k = 1, cap do cut[k] = ls[k] end
        cut[cap] = endWithEllipsis(cut[cap], textW)
        ls = cut
      end
      local th = #ls * LH + 2 * PAD
      if th < MINROW then th = MINROW end
      blocks[#blocks + 1] = { item = ri, lines = ls, height = th }
    end
  end
  S.blocks = blocks
  local usable = bandH
  S.pStarts = pageStarts(blocks, usable)
  if #S.pStarts > 1 then
    usable = bandH - pageLabelReserve()
    S.pStarts = pageStarts(blocks, usable)
  end
  S.usableH = usable
end

local function noteLastSlot()
  return #S.blocks + 1 + ((not S.isPage and anyDone()) and 1 or 0)
end

local function clampNote()
  local last = noteLastSlot()
  if S.noteCur > last then S.noteCur = last end
  if S.noteCur < 0 then S.noteCur = 0 end
  if #S.blocks == 0 then S.noteCur = 1 end
  local topPage = 1
  if S.noteCur >= 1 and S.noteCur <= #S.blocks then
    for p = #S.pStarts, 1, -1 do
      if S.pStarts[p] <= S.noteCur then topPage = p break end
    end
  else
    topPage = #S.pStarts
  end
  S.noteTop = S.pStarts[math.min(topPage, #S.pStarts)]
end

local function rebuildNote()
  S.lines = cores.parse(S.doc)
  S.rows = cores.drawnLines(S.doc, S.lines)
  local c = cores.counts(S.lines)
  S.done, S.marked = c.done, c.marked
  S.isPage = (cores.kindOf(S.lines, S.newIsList) == "page")
  layoutBlocks()
  clampNote()
end

local function notePageLabel()
  if #S.pStarts <= 1 then return "" end
  local p = 1
  for i = #S.pStarts, 1, -1 do
    if S.pStarts[i] <= S.noteTop then p = i break end
  end
  return p .. " / " .. #S.pStarts
end

local function deckPageLabel()
  local vis = deckVisible()
  if #S.entries <= vis then return "" end
  return (math.floor((S.deckTop - 1) / vis) + 1) .. " / " ..
         math.ceil(#S.entries / vis)
end

-- ------------------------------------------------------------ actions --

local function showNotice(text)
  S.notice = text
  S.view = "notice"
  S.ready = false
end

local function openDeck()
  local entries, err = cores.scan()
  if not entries then
    S.entries = {}
    showNotice("The card would not open, so nothing was changed.")
    return
  end
  S.entries = entries
  S.view = "deck"
  S.deckCur = 1
  S.deckTop = 1
  S.open = ""
  S.ready = false
end

local function buildNote()
  layoutBlocks()
  clampNote()
end

local function openNote(name)
  S.open = name
  S.doc = cores.load(name) or ""
  S.newIsList = true
  rebuildNote()
  S.view = "note"
  S.ready = false
end

local function nameFitsBand(name)
  -- the band is chrome and carries one cut; a name that will not fit it is
  -- a name this app will not make
  return gfx.text_width(name, F_TALL) <= W - 2 * MARGIN - 48
end

local function doToggle(slot)
  local li = S.blocks[slot].item
  local oldDoc = S.doc
  local nd = cores.tickRow(S.doc, S.lines, li)
  if not nd then return end
  local ok, msg = cores.save(S.open, nd)
  if not ok then
    S.doc = oldDoc                        -- the file is the truth
    rebuildNote()
    showNotice(msg)
    return
  end
  S.doc = nd
  rebuildNote()
end

local function askLineLoop()
  while true do
    local title = S.open .. "  " .. #S.rows
    if #title > 60 then title = title:sub(1, 60) end
    local text = input.text(title, "", 200)
    if text == nil or text == "cancelled" or text == "" then return end
    local nd = cores.appendLine(S.doc, not S.isPage, text)
    local ok, msg = cores.save(S.open, nd)
    if not ok then
      showNotice(msg)
      return
    end
    S.doc = nd
    rebuildNote()
    -- stand on the page the new line begins on, so it is visibly there
    if #S.blocks > 0 then S.noteCur = #S.blocks end
    clampNote()
    S.ready = false
  end
end

local function askNewName()
  local name = input.text(S.newIsList and "NAME THIS LIST" or "NAME THIS NOTE", "", 64)
  if name == nil or name == "cancelled" then return end
  local clean = cores.sanitise(name)
  if clean == "" then showNotice("That name cannot be used.") return end
  if not nameFitsBand(clean) then
    showNotice("That name is too long to fit the title bar. Try a shorter one.")
    return
  end
  local made, msg = cores.create(S.entries, clean)
  if not made then showNotice(msg) return end
  openNote(made)
end

local function askRename()
  local name = input.text("RENAME", S.open, 64)
  if name == nil or name == "cancelled" then return end
  local clean = cores.sanitise(name)
  if clean == "" then showNotice("That name cannot be used.") return end
  if not nameFitsBand(clean) then
    showNotice("That name is too long to fit the title bar. Try a shorter one.")
    return
  end
  local ok, msg = cores.rename(S.entries, S.open, clean)
  if not ok then showNotice(msg) return end
  S.open = clean
  S.view = "note"
  S.ready = false
end

local function switchKind()
  local wasList = not S.isPage
  local nd, changed
  if wasList then
    nd, changed = cores.stripMarkers(S.doc, S.lines)
  else
    nd, changed = cores.coerceToList(S.doc, S.lines)
  end
  if not changed then
    -- nothing to rewrite: an empty note has no line to carry a box; remember
    -- the kind it will take so the first line added gets it
    S.newIsList = not wasList
    rebuildNote()
    S.view = "note"
    S.ready = false
    return
  end
  local ok, msg = cores.save(S.open, nd)
  if not ok then showNotice(msg) return end
  S.doc = nd
  S.newIsList = not wasList
  rebuildNote()
  S.view = "note"
  S.ready = false
end

local function clearDone()
  local nd, removed = cores.clearChecked(S.doc, S.lines)
  if #removed == 0 then return end
  local ok, msg = cores.save(S.open, nd)
  if not ok then showNotice(msg) return end
  S.doc = nd
  rebuildNote()
  S.view = "note"
  S.ready = false
end

local function deleteNote()
  cores.remove(S.entries, S.open)
  openDeck()
end

-- ----------------------------------------------------------- renderers --

local function drawDeckCard(y, e, sel)
  local cx = MARGIN
  if e.hasTasks then
    gfx.rect(cx, y + (CARD_H - BADGE) / 2, BADGE, BADGE, true)
    gfx.text(cx + BADGE / 2, y + (CARD_H - LHS) / 2, e.done .. "/" .. e.total,
             F_SMALL, "wc")
  else
    -- a note's badge: an outline with three rules, the last one short
    gfx.rect(cx, y + (CARD_H - BADGE) / 2, BADGE, BADGE, false)
    local inset, gap = 16, 12
    local w0 = BADGE - inset * 2
    local top = y + (CARD_H - BADGE) / 2 + (BADGE - (2 * 3 + gap * 2)) / 2
    for r = 0, 2 do
      local rw = (r == 2) and math.floor(w0 * 3 / 5) or w0
      gfx.rect(cx + inset, top + r * (2 + gap), rw, 2, true)
    end
  end
  local tx = cx + BADGE + 12
  local tw = W - MARGIN - tx
  -- a long name wraps to a second line, set tighter than reading leading
  local ls = wrap(e.name, tw)
  if #ls > 2 then
    local cut = { ls[1], ls[2] }
    cut[2] = endWithEllipsis(cut[2], tw)
    ls = cut
  end
  local step = math.floor(LH * 8 / 10)
  local titleH = LH + (#ls - 1) * step
  local hasSecond = e.hasTasks or e.preview ~= ""
  local secondH = e.hasTasks and 10 or LHS
  local gap = (#ls > 1) and 6 or 10
  local top = y + (CARD_H - (titleH + (hasSecond and (gap + secondH) or 0))) / 2
  for li = 1, #ls do
    gfx.text(tx, top + (li - 1) * step, ls[li], F_BODY)
  end
  if hasSecond then
    local sy = top + titleH + gap
    if e.hasTasks then
      bar(tx, sy, tw, secondH, e.done, e.total)
    else
      gfx.text(tx, sy, previewToWidth(e.preview, tw), F_SMALL)
    end
  end
  marker(cx, y, CARD_H, sel)
end

local function drawDeck()
  header("NOTES", nil)
  local vis = deckVisible()
  local n = #S.entries
  if n == 0 then
    local bandH = BODY_BOT - BODY_TOP
    local ls = wrap("Nothing here yet. A list is things to tick off. A note is words to keep.", W - 2 * MARGIN)
    if #ls > 6 then ls = { ls[1], ls[2], ls[3] } end
    local top = BODY_TOP + (bandH - #ls * LH) / 2
    for i = 1, #ls do
      gfx.text(W / 2, top + (i - 1) * LH, ls[i], F_BODY, "c")
    end
  else
    local y = BODY_TOP
    for i = S.deckTop, math.min(n, S.deckTop + vis - 1) do
      drawDeckCard(y, S.entries[i], S.deckCur == i)
      y = y + CARD_PITCH
    end
    local label = deckPageLabel()
    if label ~= "" then gfx.text(W / 2, BODY_BOT - LHS, label, F_SMALL, "c") end
  end
  local fill = n + 1   -- cursor slots: rows, then the two footer buttons
  footer({ { label = "+ LIST", filled = true }, { label = "+ NOTE", filled = false } },
         S.deckCur - n)
end

local function drawStrip()
  local left = S.marked - S.done
  local label = (left == 0) and "ALL DONE" or (left .. " LEFT OF " .. S.marked)
  local by = BODY_TOP + 4
  local bh = 10
  local lw = gfx.text_width(label, F_SMALL) + 12
  gfx.text(MARGIN, by + bh / 2 - LHS / 2, label, F_SMALL)
  bar(MARGIN + lw, by, W - 2 * MARGIN - lw, bh, S.done, S.marked)
  gfx.line(MARGIN, by + bh + 10, W - MARGIN, by + bh + 10)
end

local function drawNoteRow(y, block, sel, grow)
  local li = block.item
  local h = block.height + grow
  local nx = MARGIN
  if S.isPage then
    gfx.text(nx, y, block.lines[1], F_BODY)
    marker(nx, y, h, sel)
    return
  end
  local ln = S.lines[li]
  local textH = #block.lines * LH
  local textTop = y + (h - textH) / 2
  local boxY = textTop + LH / 2 - BOX / 2    -- the box sits on the FIRST line
  gfx.rect(nx, boxY, BOX, BOX, false)
  if ln.checked then
    gfx.rect(nx + 8, boxY + 8, BOX - 16, BOX - 16, true)
  end
  local tx = nx + BOX + BOX_GAP
  for k = 1, #block.lines do
    local ly = textTop + (k - 1) * LH
    local l = block.lines[k]
    gfx.text(tx, ly, l, F_BODY)
    if ln.checked then
      -- a done line is struck, not greyed: one crisp rule over the run
      gfx.rect(tx, ly + LH / 2 - 1, gfx.text_width(l, F_BODY), 2, true)
    end
  end
  marker(nx, y, h, sel)
end

local function drawNote()
  header(S.open, "MENU")
  if not S.isPage and S.marked > 0 then drawStrip() end
  local topY = noteTopY()
  if #S.blocks == 0 then
    local msg = S.isPage and "This note is empty. Tap ADD." or "Nothing on this list. Tap ADD."
    gfx.text(W / 2, topY + (noteBandH() - LH) / 2, msg, F_BODY, "c")
  else
    local page = 1
    for i = #S.pStarts, 1, -1 do
      if S.pStarts[i] <= S.noteTop then page = i break end
    end
    local from = S.pStarts[page]
    local to = (page + 1 <= #S.pStarts) and (S.pStarts[page + 1] - 1) or #S.blocks
    local grow = 0
    if not S.isPage and #S.pStarts == 1 then
      local total = 0
      for i = 1, #S.blocks do total = total + S.blocks[i].height end
      local share = (S.usableH - total) / #S.blocks
      if share > 0 then grow = math.min(GROW_CAP, math.floor(share)) end
    end
    local y = topY
    for i = from, to do
      local b = S.blocks[i]
      if S.isPage and b.paraStart and y > topY then y = y + PARA_GAP end
      drawNoteRow(y, b, S.noteCur == i, grow)
      y = y + b.height + grow
    end
    local label = notePageLabel()
    if label ~= "" then gfx.text(W / 2, BODY_BOT - LHS, label, F_SMALL, "c") end
  end
  local btns = { { label = "ADD", filled = true } }
  if not S.isPage and anyDone() then
    btns[2] = { label = "CLEAR DONE", filled = false }
  end
  local last = noteLastSlot()
  local focal = (S.noteCur >= #S.blocks + 1) and (S.noteCur - #S.blocks) or 1
  footer(btns, focal)
end

local function drawMenuRow(y, label, caption, sel)
  local h = 84
  local bh = LH + (caption and (LHS + 4) or 0)
  local top = y + (h - bh) / 2
  gfx.text(MARGIN, top, label, F_BODY)
  if caption then gfx.text(MARGIN, top + LH + 4, caption, F_SMALL) end
  marker(MARGIN, y, h, sel)
  gfx.line(MARGIN, y + h, W - MARGIN, y + h)
end

local function drawMenu()
  header(S.open, nil)
  local y = BODY_TOP
  if S.isPage then
    drawMenuRow(y, "MAKE IT A LIST", nil, S.menuCur == 1)
  else
    drawMenuRow(y, "MAKE IT A NOTE", "the ticks are lost", S.menuCur == 1)
  end
  y = y + 84
  drawMenuRow(y, "RENAME", nil, S.menuCur == 2)
  footer({ { label = "DELETE NOTE", filled = false } }, (S.menuCur == 3) and 1 or 0)
end

local function drawConfirm()
  header(S.open, nil)
  local ls = wrap("Delete this note and everything written in it? There is no way back.",
                  W - 2 * MARGIN)
  local y = BODY_TOP + (noteBandH() - #ls * LH) / 2
  for i = 1, #ls do
    gfx.text(MARGIN, y + (i - 1) * LH, ls[i], F_BODY)
  end
  footer({ { label = "KEEP IT", filled = true }, { label = "DELETE IT", filled = false } },
         S.confCur)
end

local function drawNotice()
  header(S.open ~= "" and S.open or "NOTES", nil)
  local ls = wrap(S.notice, W - 2 * MARGIN)
  if #ls > 12 then
    local cut = {}
    for i = 1, 12 do cut[i] = ls[i] end
    ls = cut
  end
  local y = BODY_TOP + (noteBandH() - #ls * LH) / 2
  for i = 1, #ls do
    gfx.text(MARGIN, y + (i - 1) * LH, ls[i], F_BODY)
  end
  footer({ { label = "BACK", filled = true } }, 1)
end

local function draw()
  gfx.clear()
  if S.view == "deck" then drawDeck()
  elseif S.view == "note" then drawNote()
  elseif S.view == "menu" then drawMenu()
  elseif S.view == "confirm" then drawConfirm()
  else drawNotice() end
  gfx.present()
end

-- ------------------------------------------------------------- input --

local function pageNote(dir)
  local p = 1
  for i = #S.pStarts, 1, -1 do
    if S.pStarts[i] <= S.noteTop then p = i break end
  end
  local np = p + dir
  if np < 1 or np > #S.pStarts then return end
  S.noteTop = S.pStarts[np]
  S.noteCur = S.pStarts[np]
  S.ready = false
end

local function pageDeck(dir)
  local vis = deckVisible()
  local np = S.deckTop + dir * vis
  if np < 1 or np > #S.entries then return end
  S.deckTop = np
  S.deckCur = np
  S.ready = false
end

local function onConfirm()
  if S.view == "notice" then
    S.view = (S.open ~= "") and "note" or "deck"
  elseif S.view == "deck" then
    local n = #S.entries
    if S.deckCur <= n then
      openNote(S.entries[S.deckCur].name)
    elseif S.deckCur == n + 1 then
      S.newIsList = true
      askNewName()
    else
      S.newIsList = false
      askNewName()
    end
  elseif S.view == "note" then
    if S.noteCur == 0 then
      S.view = "menu"
      S.menuCur = 1
      S.ready = false
    elseif S.noteCur <= #S.blocks then
      if not S.isPage then doToggle(S.noteCur) end
    elseif S.noteCur == #S.blocks + 1 then
      askLineLoop()
    else
      clearDone()
    end
  elseif S.view == "menu" then
    if S.menuCur == 1 then switchKind()
    elseif S.menuCur == 2 then askRename()
    else
      S.view = "confirm"
      S.confCur = 1
      S.ready = false
    end
  elseif S.view == "confirm" then
    if S.confCur == 1 then
      S.view = "note"
      S.ready = false
    else
      deleteNote()
    end
  end
  S.ready = false
end

local function onBack()
  if S.view == "deck" then return "exit" end
  if S.view == "note" then openDeck() return nil end
  if S.view == "notice" then
    S.view = (S.open ~= "") and "note" or "deck"
  else
    S.view = (S.open ~= "") and "note" or "deck"
  end
  S.ready = false
end

local __main
__main = function()
  local ok, err = cores.begin()
  if not ok then
    S.entries = {}
    S.notice = "The card would not open, so nothing was changed."
    S.view = "notice"
  else
    openDeck()       -- scan the card BEFORE the first draw
  end

  while true do
    if not S.ready then draw(); S.ready = true end
    local ev = input.wait()
    if ev == "back" then
      if onBack() == "exit" then break end
    elseif ev == "confirm" then
      onConfirm()
    elseif ev == "up" then
      if S.view == "deck" then
        if S.deckCur > 1 then
          S.deckCur = S.deckCur - 1
          if S.deckCur < S.deckTop then S.deckTop = S.deckCur end
        end
      elseif S.view == "note" then
        if S.noteCur > 0 then S.noteCur = S.noteCur - 1 end
        clampNote()
      elseif S.view == "menu" then
        if S.menuCur > 1 then S.menuCur = S.menuCur - 1 end
      elseif S.view == "confirm" then
        if S.confCur > 1 then S.confCur = S.confCur - 1 end
      end
      S.ready = false
    elseif ev == "down" then
      if S.view == "deck" then
        local n = #S.entries
        if S.deckCur < n + 2 then
          S.deckCur = S.deckCur + 1
          local vis = deckVisible()
          if S.deckCur <= n and S.deckCur > S.deckTop + vis - 1 then
            S.deckTop = S.deckCur - vis + 1
          end
        end
      elseif S.view == "note" then
        local last = noteLastSlot()
        if S.noteCur < last then S.noteCur = S.noteCur + 1 end
        clampNote()
      elseif S.view == "menu" then
        if S.menuCur < 3 then S.menuCur = S.menuCur + 1 end
      elseif S.view == "confirm" then
        if S.confCur < 2 then S.confCur = S.confCur + 1 end
      end
      S.ready = false
    elseif ev == "left" or ev == "right" then
      local dir = (ev == "right") and 1 or -1
      if S.view == "deck" then
        local n = #S.entries
        if S.deckCur > n then
          S.deckCur = S.deckCur + dir
          if S.deckCur < n + 1 then S.deckCur = n + 1 end
          if S.deckCur > n + 2 then S.deckCur = n + 2 end
        else
          pageDeck(dir)
        end
      elseif S.view == "note" then
        -- cursor 0 is "nothing on the band": no move
        if S.noteCur ~= 0 and S.noteCur >= #S.blocks + 1 then
          local last = noteLastSlot()
          S.noteCur = S.noteCur + dir
          if S.noteCur < #S.blocks + 1 then S.noteCur = #S.blocks + 1 end
          if S.noteCur > last then S.noteCur = last end
        elseif S.noteCur ~= 0 then
          pageNote(dir)
        end
      elseif S.view == "menu" then
        if S.menuCur == 3 then
          S.menuCur = (dir > 0) and 1 or 2
        end
      elseif S.view == "confirm" then
        S.confCur = (dir > 0) and 2 or 1
      end
      S.ready = false
    end
  end
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()