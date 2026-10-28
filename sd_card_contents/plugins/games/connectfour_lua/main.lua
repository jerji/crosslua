-- Connect Four — CrossLua port of the crossplay game (two players, one device).
-- Design: crossplay/docs/apps/connectfour.md. Rules: ConnectFourCore.h.
-- Light always opens (the outlined disc); dark follows (solid).
-- Left/right move the drop column along the lip; confirm drops the disc.
-- The board is stored bottom-up (row 1 at the bottom) and flipped when drawn.
-- PLAY NEARBY (crossplay docs/apps/connectfour.md, spec play-nearby §4.3): two
-- devices on ESP-NOW; the whole board travels as the 46-byte game blob (wire.lua).

local game4 = require("game4")
local nearby = require("nearby")
local wire = require("wire")
local GAME_ID = 0x0201

local W, H = gfx.size()

local CELL = 64          -- 7 * 64 = 448, exactly the width between the margins
local GRID_W, GRID_H = CELL * game4.COLS, CELL * game4.ROWS
local LEFT = math.floor((W - GRID_W) / 2)
local DISC_R = 26        -- disc radius inside a cell
local RIM = 4            -- light disc's black rim
local SLOT_H = 42        -- the lip: a shallow channel, shallower than a row
local LIP_R = 16         -- the waiting disc, smaller than a played one
local F_TITLE, F_TXT, F_SMALL = "sans18", "sans18", "ui12"

local screen = "menu"    -- menu | howto | board | result | linkwait | linkend
local menuSel = 1        -- 1 = PLAY, 2 = PLAY NEARBY, 3 = HOW TO PLAY
local resultSel = 1      -- 1 = PLAY AGAIN, 2 = MENU
local S = nil            -- PLAY NEARBY session, nil when playing alone
local mySide = game4.LIGHT
local myAgain = false    -- I have said PLAY AGAIN this round
local flash = ""         -- one-line message on the menu
local howPage = 1        -- 1..3
local game = nil
local sel = 4            -- selected drop column (1..7)
local dirty = true

-- ---------------------------------------------------------------- drawing

local function centerText(y, s, font, flags)
  local f = font or F_TXT
  local fl = flags or "b"
  gfx.text(math.floor((W - gfx.text_width(s, f, fl)) / 2), y, s, f, fl)
end

local function band(title, right)
  gfx.rect(0, 0, W, 48, true, true)
  local fl = "bw"
  gfx.text(math.floor((W - gfx.text_width(title, F_TITLE, fl)) / 2), 13, title, F_TITLE, fl)
  if right then
    gfx.text(W - 16 - gfx.text_width(right, F_TITLE, fl), 13, right, F_TITLE, fl)
  end
end

-- The dithered slab: a white base with thin black lines. E-ink grey.
local function slab(x, y, w, h)
  gfx.rect(x, y, w, h, true, false)
  local yy = y + 2
  while yy < y + h do
    gfx.rect(x, yy, w, 2, true, true)
    yy = yy + 8
  end
end

-- A black frame around the slab (the board object).
local function boardFrame(x, y, w, h)
  gfx.rect(x - 4, y - 4, w + 8, h + 8, true, true)
  slab(x, y, w, h)
end

-- An empty place: a white disc punched into the slab. A hole, not an outline.
local function hole(cx, cy, r)
  gfx.rounded_rect(cx - r, cy - r, 2 * r, 2 * r, r, true, false)
end

-- light = white fill with a 4px black rim; dark = solid black.
-- (an unfilled gfx rect border reads the same as a filled one on e-ink, so
-- the rim is two filled circles: black r, then white r - RIM)
local function disc(cx, cy, r, side)
  gfx.rounded_rect(cx - r, cy - r, 2 * r, 2 * r, r, true, true)
  if side ~= game4.DARK then
    gfx.rounded_rect(cx - r + RIM, cy - r + RIM, 2 * (r - RIM), 2 * (r - RIM), r - RIM, true, false)
  end
end

-- The last disc is ringed, INSIDE the disc, so it cannot be confused with the
-- winning-line mark (which is corner brackets).
local function lastMark(cx, cy, r, side)
  local rr = math.floor(r * 0.55)
  if side == game4.DARK then
    gfx.rounded_rect(cx - rr, cy - rr, 2 * rr, 2 * rr, rr, true, false)
    gfx.rounded_rect(cx - rr + 3, cy - rr + 3, 2 * (rr - 3), 2 * (rr - 3), rr - 3, true, true)
  else
    gfx.rounded_rect(cx - rr, cy - rr, 2 * rr, 2 * rr, rr, true, true)
    gfx.rounded_rect(cx - rr + 3, cy - rr + 3, 2 * (rr - 3), 2 * (rr - 3), rr - 3, true, false)
  end
end

-- A slot you cannot use is DIMMED, not removed and not reshaped: a dithered
-- (hatched) disc of the same radius in the same place.
local function dimDisc(cx, cy, r)
  disc(cx, cy, r, game4.LIGHT)
  for dy = -(r - 5), r - 5, 5 do
    local rr = r - 4
    local hw = math.floor(math.sqrt(math.max(0, rr * rr - dy * dy)))
    gfx.rect(cx - hw, cy + dy, 2 * hw, 2, true, true)
  end
end

-- Corner brackets around a winning cell (short L-strokes at the corners).
local function bracket(cx, cy, half)
  local len, wt = 10, 3
  local o = half - 2
  local px, py = cx - o, cy - o          -- top-left tip
  gfx.rect(px - len + 1, py, len, wt, true, true)          -- TL, left arm
  gfx.rect(px - wt + 1, py - len + 1, wt, len, true, true) -- TL, top arm
  px, py = cx + o - wt + 1, cy - o
  gfx.rect(px, py - len + 1, wt, len, true, true)          -- TR, top arm
  gfx.rect(px, py, len, wt, true, true)                    -- TR, right arm
  px, py = cx - o, cy + o - wt + 1
  gfx.rect(px - len + 1, py, len, wt, true, true)          -- BL, left arm
  gfx.rect(px - wt + 1, py, wt, len, true, true)           -- BL, bottom arm
  px, py = cx + o - wt + 1, cy + o - wt + 1
  gfx.rect(px, py, wt, len, true, true)                    -- BR, bottom arm
  gfx.rect(px, py, len, wt, true, true)                    -- BR, right arm
end

local function cellCenter(c, r, gridTop, cell)
  local cx = LEFT + (c - 1) * cell + cell // 2
  local cy = gridTop + (game4.ROWS - r) * cell + cell // 2
  return cx, cy
end

local function drawGrid(gridTop, cell)
  local r = math.floor(cell * DISC_R / CELL)
  for c = 1, game4.COLS do
    for rr = 1, game4.ROWS do
      local cx, cy = cellCenter(c, rr, gridTop, cell)
      hole(cx, cy, r)
      local piece = game.board[c][rr]
      if piece ~= game4.EMPTY then
        disc(cx, cy, r, piece)
        if c == game.lastC and rr == game.lastR then lastMark(cx, cy, r, piece) end
      end
    end
  end
end

local function drawBoard()
  local turnText = game.turn == game4.LIGHT and "LIGHT'S TURN" or "DARK'S TURN"
  if S then turnText = game.turn == mySide and "YOUR TURN" or "THEIR TURN" end
  band("CONNECT FOUR", turnText)
  gfx.text(16, 56, S and "< > MOVE    OK DROP    BACK LEAVE" or "< > MOVE    OK DROP    BACK QUIT", F_SMALL)
  local lipTop = 76
  local gridTop = lipTop + SLOT_H
  boardFrame(LEFT, lipTop, GRID_W, GRID_H + SLOT_H)
  -- the lip: the selected column holds the disc you are about to drop, a full
  -- column's slot is dimmed, the rest are plain holes
  for c = 1, game4.COLS do
    local cx = LEFT + (c - 1) * CELL + CELL // 2
    local cy = lipTop + SLOT_H // 2
    hole(cx, cy, LIP_R)
    if game4.landingRow(game, c) == 0 then
      dimDisc(cx, cy, LIP_R)
    elseif c == sel then
      disc(cx, cy, LIP_R, game.turn)
    end
  end
  drawGrid(gridTop, CELL)
end

local function button(x, y, w, h, label, active)
  if active then
    gfx.rect(x, y, w, h, true, true)
    gfx.text(x + math.floor((w - gfx.text_width(label, F_TXT, "bw")) / 2), y + 17, label, F_TXT, "bw")
  else
    gfx.rect(x, y, w, h, true, false)
    gfx.text(x + math.floor((w - gfx.text_width(label, F_TXT, "b")) / 2), y + 17, label, F_TXT, "b")
  end
end

local function drawResult()
  local title = game.outcome == "light" and "LIGHT WINS"
    or (game.outcome == "dark" and "DARK WINS" or "A DRAW")
  if S then
    local won = game.outcome == "light" and game4.LIGHT or game4.DARK
    title = game.outcome == "draw" and "A DRAW"
      or (won == mySide and "YOU WIN" or "THEY WIN")
  end
  band("CONNECT FOUR")
  centerText(56, title, F_TITLE, "b")
  -- the result screen is the board, drawn higher (no slot row to reserve)
  local gridTop = 84
  boardFrame(LEFT, gridTop, GRID_W, GRID_H)
  drawGrid(gridTop, CELL)
  -- the four cells it marks come from the rules' own winningLine
  for i = 1, #game.line do
    local wc, wr = game.line[i][1], game.line[i][2]
    local cx = LEFT + (wc - 1) * CELL + CELL // 2
    local cy = gridTop + (game4.ROWS - wr) * CELL + CELL // 2
    bracket(cx, cy, CELL // 2)
  end
  -- the screen has gained two buttons
  local by, bw2, bh, gap = 720, 210, 56, 16
  local bx = math.floor((W - (2 * bw2 + gap)) / 2)
  button(bx, by, bw2, bh, "PLAY AGAIN", resultSel == 1)
  button(bx + bw2 + gap, by, bw2, bh, "MENU", resultSel == 2)
  if S then
    local note = myAgain and "WAITING FOR THEM TO SAY PLAY AGAIN"
      or (S.peerAgain and "THEY WANT ANOTHER GAME" or "")
    centerText(660, note, F_SMALL, "b")
  end
end

-- The nearby screens: searching for a partner, and the match ended early.
local function drawLinkWait()
  band("CONNECT FOUR", "PLAY NEARBY")
  centerText(300, "LOOKING FOR A PLAYER", F_TITLE, "b")
  centerText(344, "Turn on PLAY NEARBY on the other device.", F_SMALL, "b")
  gfx.text(16, 700, "BACK CANCEL", F_SMALL)
end

local function drawLinkEnd()
  band("CONNECT FOUR")
  centerText(300, S and S.reason == "lost" and "LOST CONNECTION" or "THEY LEFT", F_TITLE, "b")
  gfx.text(16, 700, "OK OR BACK: MENU", F_SMALL)
end

-- ------------------------------------------------------- menu / how to play

local function drawMenu()
  band("CONNECT FOUR")
  gfx.text(16, 58, "PASS AND PLAY    LIGHT ALWAYS OPENS", F_SMALL)
  local rows = { "PLAY", "PLAY NEARBY", "HOW TO PLAY" }
  for i = 1, 3 do
    local y = 150 + (i - 1) * 48
    local x = math.floor((W - gfx.text_width(rows[i], F_TXT, "b")) / 2)
    if menuSel == i then gfx.text(x - 36, y, ">", F_TXT, "b") end
    gfx.text(x, y, rows[i], F_TXT, "b")
  end
  -- ornament: a mini slab with a sample position, holes and all
  local oc = 32
  local ox = math.floor((W - oc * game4.COLS) / 2)
  boardFrame(ox, 300, oc * game4.COLS, oc * game4.ROWS)
  local orr = math.floor(oc * DISC_R / CELL)
  local sample = {
    { 3, 1, game4.LIGHT }, { 3, 2, game4.DARK }, { 4, 1, game4.DARK },
    { 5, 1, game4.LIGHT }, { 6, 1, game4.DARK }, { 6, 2, game4.LIGHT },
  }
  for i = 1, #sample do
    local s = sample[i]
    local cx = ox + (s[1] - 1) * oc + oc // 2
    local cy = 300 + (game4.ROWS - s[2]) * oc + oc // 2
    hole(cx, cy, orr)
    disc(cx, cy, orr, s[3])
  end
  gfx.text(16, 540, "SEVEN COLUMNS. FOUR IN A LINE WINS.", F_SMALL)
  if flash ~= "" then centerText(580, flash, F_SMALL, "b") end
  gfx.text(16, 700, "OK SELECT    BACK QUIT", F_SMALL)
end

-- A small board diagram for the how-to pages: cells = {{c, r, side}...},
-- optional lip drawn above the grid (lipCol holds a waiting disc, dimCols
-- are dimmed full columns).
local function miniBoard(cells, gridTop, lipCol, lipKind, dimCols)
  local oc = 36
  local r = math.floor(oc * DISC_R / CELL)
  local lipR = math.floor(oc * LIP_R / CELL)
  local ox = math.floor((W - oc * game4.COLS) / 2)
  local ow, oh = oc * game4.COLS, oc * game4.ROWS
  local lipH = (lipCol or dimCols or lipKind) and SLOT_H or 0
  boardFrame(ox, gridTop - lipH, ow, oh + lipH)
  if lipH > 0 then
    for c = 1, game4.COLS do
      local cx = ox + (c - 1) * oc + oc // 2
      local cy = gridTop - lipH + SLOT_H // 2
      hole(cx, cy, lipR)
      local dim = false
      if dimCols then
        for i = 1, #dimCols do if dimCols[i] == c then dim = true end end
      end
      if dim then
        dimDisc(cx, cy, lipR)
      elseif c == lipCol and lipKind then
        disc(cx, cy, lipR, lipKind)
      end
    end
  end
  for i = 1, #cells do
    local s = cells[i]
    local cx = ox + (s[1] - 1) * oc + oc // 2
    local cy = gridTop + (game4.ROWS - s[2]) * oc + oc // 2
    hole(cx, cy, r)
    disc(cx, cy, r, s[3])
  end
end

local function fullCol(c)
  local t = {}
  for rr = 1, game4.ROWS do
    t[#t + 1] = { c, rr, (rr % 2 == 1) and game4.LIGHT or game4.DARK }
  end
  return t
end

local function drawHowTo()
  band("HOW TO PLAY", howPage .. " OF 3")
  if howPage == 1 then
    gfx.text(16, 62, "LEFT/RIGHT MOVE THE DROP COLUMN.", F_TXT)
    gfx.text(16, 94, "OK DROPS YOUR DISC INTO THE LOWEST", F_TXT)
    gfx.text(16, 126, "FREE PLACE IN THAT COLUMN.", F_TXT)
    miniBoard({ { 4, 1, game4.LIGHT }, { 4, 2, game4.DARK }, { 4, 3, game4.LIGHT } }, 372, 4, game4.LIGHT)
  elseif howPage == 2 then
    gfx.text(16, 62, "FOUR IN A LINE WINS:", F_TXT)
    gfx.text(16, 94, "ACROSS, UP, OR ON EITHER DIAGONAL.", F_TXT)
    miniBoard({
      { 1, 1, game4.LIGHT }, { 2, 2, game4.LIGHT }, { 3, 3, game4.LIGHT }, { 4, 4, game4.LIGHT },
      { 2, 1, game4.DARK }, { 3, 1, game4.DARK }, { 3, 2, game4.DARK },
      { 4, 1, game4.DARK }, { 4, 2, game4.DARK }, { 4, 3, game4.DARK },
    }, 400)
  else
    gfx.text(16, 62, "A FULL COLUMN STOPS TAKING DISCS.", F_TXT)
    gfx.text(16, 94, "ITS SLOT AT THE TOP GOES GREY.", F_TXT)
    local cells = {}
    for i = 1, #fullCol(1) do cells[#cells + 1] = fullCol(1)[i] end
    for i = 1, #fullCol(7) do cells[#cells + 1] = fullCol(7)[i] end
    miniBoard(cells, 372, 4, game4.LIGHT, { 1, 7 })
  end
  gfx.text(16, 640, "OK NEXT    BACK PREV", F_SMALL)
end

-- ------------------------------------------------------------- input loop

-- ------------------------------------------------------ PLAY NEARBY link

local function leaveLink()
  if S then S:stop(system.millis()) end
  S = nil
  myAgain = false
  screen = "menu"
  dirty = true
end

local function startLink()
  S = nearby.new(GAME_ID, "PUP " .. string.sub(system.mac(), 16, 17))
  local ok, err = S:start()
  if not ok then
    S = nil
    flash = "RADIO WILL NOT START: " .. tostring(err):sub(1, 30)
    dirty = true
    return
  end
  flash = ""
  screen = "linkwait"
  dirty = true
end

-- A new round: both devices have said PLAY AGAIN (or the peer's first move
-- arrived). The first mover flips each round, so both sides take turns going first.
local function startRound()
  S.iFirst = not S.iFirst
  mySide = S.iFirst and game4.LIGHT or game4.DARK
  S:newRound()
  game = game4.newGame()
  sel = 4
  myAgain = false
  screen = "board"
  dirty = true
end

-- Runs every pass: pumps the radio, then applies the match, the peer's move,
-- and the peer leaving. Nothing here draws unless something changed.
local function pollLink()
  if not S then return end
  local now = system.millis()
  S:pump(now)
  S:tick(now)
  if S:takeMatch() then
    mySide = S.iFirst and game4.LIGHT or game4.DARK
    game = game4.newGame()
    sel = 4
    myAgain = false
    screen = "board"
    dirty = true
  end
  local blob = S:takeState()
  if blob then
    local ng = wire.unpack(blob)
    if ng then
      if screen == "result" and ng.outcome == "running" then startRound() end
      game = ng
      if game.outcome ~= "running" then
        resultSel = 1
        screen = "result"
      else
        screen = "board"
      end
      dirty = true
    end
  end
  if S.phase == "ended" and screen ~= "linkend" then
    screen = "linkend"
    dirty = true
  end
  -- both said PLAY AGAIN; whichever note arrived last starts the round
  if screen == "result" and myAgain and S.peerAgain then startRound() end
end

-- A key on the board during a match: drop only on my turn, then send the board.
local function linkDrop()
  if game.turn ~= mySide then
    flash = "NOT YOUR TURN"
    return
  end
  if game4.drop(game, sel) then
    flash = ""
    S:sendState(system.millis(), wire.pack(game))
    dirty = true
    if game.outcome ~= "running" then
      resultSel = 1
      screen = "result"
    end
  end
end

-- Returns "exit" when the app should end.
local function handleKey(ev)
  if screen == "menu" then
    if ev == "up" then
      menuSel = (menuSel - 2) % 3 + 1
      dirty = true
    elseif ev == "down" then
      menuSel = menuSel % 3 + 1
      dirty = true
    elseif ev == "confirm" then
      if menuSel == 1 then
        game = game4.newGame()
        sel = 4
        screen = "board"
      elseif menuSel == 2 then
        startLink()
      else
        howPage = 1
        screen = "howto"
      end
      dirty = true
    elseif ev == "back" then
      return "exit"
    end
  elseif screen == "howto" then
    if ev == "confirm" or ev == "right" then
      if howPage < 3 then howPage = howPage + 1 else screen = "menu" end
      dirty = true
    elseif ev == "back" or ev == "left" then
      if howPage > 1 then howPage = howPage - 1 else screen = "menu" end
      dirty = true
    end
  elseif screen == "linkwait" then
    if ev == "back" then leaveLink() end
  elseif screen == "linkend" then
    if ev == "confirm" or ev == "back" then leaveLink() end
  elseif screen == "board" then
    if ev == "left" or ev == "right" then
      sel = ((sel + (ev == "right" and 1 or -1) - 1) % game4.COLS) + 1
      dirty = true
    elseif ev == "confirm" then
      if S then
        linkDrop()
      elseif game4.drop(game, sel) then
        -- a full column's drop is refused and changes nothing; a settled
        -- game moves to the result screen
        dirty = true
        if game.outcome ~= "running" then
          resultSel = 1
          screen = "result"
        end
      end
    elseif ev == "back" then
      if S then leaveLink() else screen = "menu"; dirty = true end
    end
  elseif screen == "result" then
    if ev == "left" or ev == "right" then
      resultSel = resultSel == 1 and 2 or 1
      dirty = true
    elseif ev == "confirm" then
      if S then
        if resultSel == 1 then
          if not myAgain then
            myAgain = true
            S:say(system.millis(), nearby.NOTE_PLAY_AGAIN)
            if S.peerAgain then startRound() end
          end
          dirty = true
        else
          leaveLink()
        end
      elseif resultSel == 1 then
        game = game4.newGame()
        sel = 4
        screen = "board"
        dirty = true
      else
        screen = "menu"
        dirty = true
      end
    elseif ev == "back" then
      if S then leaveLink() else screen = "menu"; dirty = true end
    end
  end
  return nil
end

local function update()
  while true do
    pollLink()
    if dirty then
      if screen == "menu" then drawMenu()
      elseif screen == "howto" then drawHowTo()
      elseif screen == "board" then drawBoard()
      elseif screen == "result" then drawResult()
      elseif screen == "linkwait" then drawLinkWait()
      else drawLinkEnd() end
      gfx.present()
      dirty = false
    end
    -- while linked, wake every 100 ms so the radio keeps moving
    local ev
    if S then ev = input.wait(100) else ev = input.wait() end
    if ev and handleKey(ev) == "exit" then return end
  end
end

local function __main()
  dirty = true
  update()
  app.exit()
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end