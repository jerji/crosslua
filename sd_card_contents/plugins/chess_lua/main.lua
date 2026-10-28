-- Chess for the X4, ported from crossplay's chess (ChessCore / ChessEngine /
-- ChessActivity / ChessScreens / ChessWire / LinkSession). See WRITING_APPS.md
-- and the screen graph in the crossplay docs; the rules, the four game-end
-- kinds, the engine and the play-nearby link are direct ports.
--
--   main.lua   screens + flow (menu, settings, board, link)   [this file]
--   chess.lua  the rules engine (movegen, make/unmake, FEN, SAN, repetition)
--   engine.lua the opponent (negamax alpha-beta, MVV-LVA, node budget)
--   link.lua   the ESP-NOW session (search / match / turns / notes)
--   art.lua + art/*.bmp  the celtic piece set, generated from ChessPieces.h
--
-- Buttons, not touch: the Lua runtime exposes seven buttons and the other
-- playable Lua games navigate with a cursor, so the board plays with a cursor
-- and Confirm, and the gear (settings) is the square above the top rank.

local chess = require("chess")
local engine = require("engine")
local link = require("link")
local art = require("art")

-- ---------------------------------------------------------------- geometry
local W, H = gfx.size()
local SQ = 48                    -- board square: 8 of them = 384px
local BOARD = SQ * 8
local LEFT = (W - BOARD) // 2    -- 48
local TOP = 76                   -- board top, under the header and the strip
local HEADER = 40
local CAP = 48                   -- status capsule height
local MINI_CELL = 32             -- menu / rematch art board
local TYPE_NAME = { [0] = "", "Pawn", "Knight", "Bishop", "Rook", "Queen", "King" }
-- ink extents of the small cut, from ChessPieces.h kSmallInk: {left, width}
local SMALL_INK = { [1] = { 6, 13 }, [2] = { 2, 19 }, [3] = { 4, 16 },
                    [4] = { 4, 17 }, [5] = { 1, 22 }, [6] = { 2, 20 } }
local STARTING_COUNT = { 0, 8, 2, 2, 2, 1, 1 }
local TRACKED = { chess.QUEEN, chess.ROOK, chess.BISHOP, chess.KNIGHT, chess.PAWN }

-- ---------------------------------------------------------------- state
local SAVE_PATH = "data:chess.sav"
local CFG_PATH = "data:chess.cfg"

local settings = { level = 1, playAsWhite = true, hints = true, opponent = 0 }
local startedOpponent, startedHumanWhite = 0, true
local pos, gameOver, drawReason, engineThinking
local legal = {}
local legalN = 0
local selected = -1
local history = {}         -- SAN lines
local historyUndo = {}     -- undo records, parallel
local historyBase = 0
local undoableFrom = 0
local repKeys = {}
local hasSavedGame = false
local continueDetail = ""

-- the link session and its conversation state. Declared here at the top of
-- the chunk so every function below (whatever it does with them) binds the
-- same locals; a `local` declared mid-chunk would leave the earlier
-- functions reading a global that nothing ever sets.
local linkS                    -- nil = no link requested; a session otherwise
local seatYou, seatThem = "ready", "looking"
local rematchQuestion = false
local endgameStage = "live"    -- live / final / offer
local finalUntil = 0
local linkCursor, linkGear = 12, false
local settingsOpen = false
local linkSettingsSel = 0

function vsComputer() return not linkS and settings.opponent == 0 end
function engineToMove() return vsComputer() and pos.white ~= settings.playAsWhite end
function linkPlaying() return linkS ~= nil end
function linkMatched()
  local ph = linkS and linkS:phase() or "off"
  return ph == "yourturn" or ph == "theirturn" or ph == "over"
end
function linkYourTurn() return linkS and linkS:phase() == "yourturn" end

-- ---------------------------------------------------------------- art
local solidBytes = {}      -- typeName:lower() -> binary string (48px)
local solidSmallBytes = {}

local function unhex(s)
  local t = {}
  local n = #s // 2
  for i = 1, n do t[i] = tonumber(s:sub(i * 2 - 1, i * 2), 16) end
  return string.char(table.unpack(t))
end

local function solidFor(type_, small)
  local key = TYPE_NAME[type_]:lower()
  if small then
    local v = solidSmallBytes[key]
    if not v then v = unhex(art.solidSmall[key]); solidSmallBytes[key] = v end
    return v
  end
  local v = solidBytes[key]
  if not v then v = unhex(art.solid[key]); solidBytes[key] = v end
  return v
end

-- Erases the piece's silhouette (white pixels): the knock-out that lets a
-- white piece read as a solid body on a dithered square.
local function eraseSilhouette(x, y, type_, small)
  local bytes = solidFor(type_, small)
  local size = small and 24 or 48
  local perRow = size // 8
  for row = 0, size - 1 do
    local base = row * perRow
    for col = 0, perRow - 1 do
      local b = bytes:byte(base + col + 1)
      if b ~= 0 then
        for bit = 0, 7 do
          if b & (0x80 >> bit) ~= 0 then gfx.pixel(x + col * 8 + bit, y + row, false) end
        end
      end
    end
  end
end

local function drawPieceAt(x, y, piece, small)
  if piece == 0 then return end
  local t = chess.pieceType(piece)
  local suffix = small and "Small" or ""
  local size = small and 24 or 48
  local name = TYPE_NAME[t] .. (chess.isBlack(piece) and "Solid" or "Light") .. suffix
  if chess.isBlack(piece) then
    gfx.image("app:art/" .. name .. ".bmp", x, y, size, size)
  else
    eraseSilhouette(x, y, t, small)
    gfx.image("app:art/" .. name .. ".bmp", x, y, size, size)
  end
end

-- the dark-square dither, the same dots every 8px the other Lua games use
local function dither(x, y, sq)
  for dy = 2, sq - 8, 8 do
    for dx = 2, sq - 8, 8 do gfx.pixel(x + dx, y + dy) end
  end
end

local function cornerMarks(x, y, sq, len, thick)
  local h = len - thick
  gfx.rect(x, y, h, thick, true)
  gfx.rect(x, y, thick, h, true)
  gfx.rect(x + sq - h, y, h, thick, true)
  gfx.rect(x + sq - thick, y, thick, h, true)
  gfx.rect(x, y + sq - thick, h, thick, true)
  gfx.rect(x, y + sq - h, thick, h, true)
  gfx.rect(x + sq - h, y + sq - thick, h, thick, true)
  gfx.rect(x + sq - thick, y + sq - h, thick, h, true)
end

local function header(title)
  gfx.rect(0, 0, W, HEADER, true)
  gfx.text(16, 11, title, "sans16", "bw")
end

local function capsule(text)
  gfx.rect(0, H - CAP, W, CAP, true)
  gfx.text(W // 2, H - CAP + 11, text, "sans16", "cwb")
end

-- ---------------------------------------------------------------- board geometry
local function whiteAtBottom()
  if linkPlaying() then return settings.playAsWhite end
  if settings.opponent == 2 then return true end          -- FaceToFace
  if settings.opponent == 1 then return pos.white end     -- PassAndPlay
  return settings.playAsWhite                             -- Computer
end

local function sqToScreen(sq)
  local whiteBottom = whiteAtBottom()
  local f, r = chess.fileOf(sq), chess.rankOf(sq)
  local col = whiteBottom and f or 7 - f
  local row = whiteBottom and (7 - r) or r
  return LEFT + col * SQ, TOP + row * SQ
end

local function screenColRow(sq)
  local whiteBottom = whiteAtBottom()
  local f, r = chess.fileOf(sq), chess.rankOf(sq)
  return (whiteBottom and f or 7 - f), (whiteBottom and (7 - r) or r)
end

local function cursorStep(c, df, dr)
  local col, row = screenColRow(c)
  col, row = col + df, row + dr
  if col < 0 or col > 7 or row < 0 or row > 7 then return c, false end
  local whiteBottom = whiteAtBottom()
  local f = whiteBottom and col or 7 - col
  local r = whiteBottom and (7 - row) or row
  return r * 8 + f, true
end

local function gearIcon(x, y, s, chosen)
  if chosen then
    gfx.rounded_rect(x, y, s, s, s // 4, true)
    gfx.rounded_rect(x + s // 4, y + s // 4, s // 2, s // 2, s // 8, true, false)
    gfx.rect(x + s // 2 - 2, y, 4, 6, true, false)
    gfx.rect(x + s // 2 - 2, y + s - 6, 4, 6, true, false)
    gfx.rect(x, y + s // 2 - 2, 6, 4, true, false)
    gfx.rect(x + s - 6, y + s // 2 - 2, 6, 4, true, false)
  else
    gfx.rounded_rect(x, y, s, s, s // 4, false)
    gfx.rounded_rect(x + s // 4, y + s // 4, s // 2, s // 2, s // 8, false)
    gfx.rect(x + s // 2 - 2, y, 4, 6, true)
    gfx.rect(x + s // 2 - 2, y + s - 6, 4, 6, true)
    gfx.rect(x, y + s // 2 - 2, 6, 4, true)
    gfx.rect(x + s - 6, y + s // 2 - 2, 6, 4, true)
  end
end

-- ---------------------------------------------------------------- game state
local function refreshLegalMoves()
  legalN = chess.genLegal(pos, legal)
  drawReason = nil
  -- Mate and stalemate are the older, stronger facts: a position repeated for
  -- the third time with no move to make is stalemate, not a draw by repetition.
  if legalN == 0 then
    gameOver = true
    return
  end
  local rep = chess.repetitionCount(repKeys, #repKeys, pos.half)
  if rep >= 3 then drawReason = "rep"
  elseif pos.half >= 100 then drawReason = "50"
  end
  gameOver = drawReason ~= nil
end

local function pushRepetitionKey()
  local key = chess.positionKey(pos)
  -- Two consecutive positions can never share a key (the side to move is
  -- hashed), so an equal key is a retransmit from the other device.
  if #repKeys > 0 and repKeys[#repKeys] == key then return end
  if #repKeys == 128 then table.remove(repKeys, 1) end
  repKeys[#repKeys + 1] = key
end

local function resetRepetition()
  repKeys = {}
  pushRepetitionKey()
end

local function isLegalDestination(sq)
  if selected < 0 then return false end
  for i = 1, legalN do
    if chess.mvFrom(legal[i]) == selected and chess.mvTo(legal[i]) == sq then return true end
  end
  return false
end

-- Applies the selected-to-target move if one is legal. Promotion always takes
-- a queen (as in the C++); underpromotion wants a picker nobody has asked for.
local function tryMove(from, to)
  for i = 1, legalN do
    local mv = legal[i]
    if chess.mvFrom(mv) == from and chess.mvTo(mv) == to then
      if chess.mvFlags(mv) & chess.F_PROMO ~= 0 and chess.mvPromo(mv) ~= chess.QUEEN then
        -- several entries share from/to when promoting; take the queen
      else
        applyMove(mv)
        return true
      end
    end
  end
  return false
end

local function refreshTurnLabel()
  -- the capsule reads the turn live; this hook exists to mirror the C++
  -- shape and stay a no-op if the turn logic ever needs precomputing again
end

-- Global (not local): tryMove() is compiled earlier in the chunk and calls
-- this at runtime; compiler-order would leave it reading a nil global.
function applyMove(mv)
  local san = chess.moveToSan(pos, mv)
  if #history == chess.MAX_HISTORY then
    table.remove(history, 1)
    table.remove(historyUndo, 1)
    historyBase = historyBase + 1
    if undoableFrom > 0 then undoableFrom = undoableFrom - 1 end
  end
  history[#history + 1] = san
  local undo = {}
  chess.makeMove(pos, mv, undo)
  undo.mv = mv
  historyUndo[#historyUndo + 1] = undo
  pushRepetitionKey()
  refreshLegalMoves()
  -- The move is on our board; put it on theirs -- only after refreshLegalMoves,
  -- so a move that ends the game travels with the position that proves it.
  if linkMatched() and linkYourTurn() then sendPosition() end
end

local function recordRemoteMove(san)
  -- score sheet only: a position says nothing about how it was reached, and
  -- there is no undo data because take-back is off in a match.
  if #history == chess.MAX_HISTORY then
    table.remove(history, 1)
    historyBase = historyBase + 1
  end
  history[#history + 1] = san
end

function sendPosition()
  if not linkS then return end
  local last = #history > 0 and history[#history] or ""
  linkS:play(chess.toFen(pos) .. "+" .. last)
end

local function adoptRemote(payload)
  local fen, san = payload:match("^([^+]+)%+(.*)$")
  if not fen or not chess.parseFen(fen) then return end
  pos = chess.parseFen(fen)
  if san ~= "" then recordRemoteMove(san) end
  selected = -1
  pushRepetitionKey()
  refreshLegalMoves()
end

local function canTakeBack()
  return (not linkPlaying()) and #history > undoableFrom and not engineThinking
end

local function takeBack()
  if not canTakeBack() then return end
  -- Undo back to your own turn: one ply if the engine has not replied yet,
  -- two if it has. Sharing the device, one ply is a whole turn.
  local plies = vsComputer() and (engineToMove() and 1 or 2) or 1
  for _ = 1, plies do
    if #history <= undoableFrom then break end
    local rec = historyUndo[#historyUndo]
    local mv = rec.mv
    table.remove(historyUndo)
    table.remove(history)
    chess.unmakeMove(pos, mv, rec)
    if #repKeys > 1 then table.remove(repKeys) end
  end
  selected = -1
  refreshLegalMoves()
  saveGame()
end

-- Global (not local): takeBack() is compiled earlier in the chunk and calls
-- this at runtime; compiler-order would leave it reading a nil global.
function saveGame()
  -- Never during a match: the position on screen is the shared game, and
  -- this file is the single-player slot.
  if linkPlaying() then return end
  local lines = {}
  lines[#lines + 1] = "1"
  lines[#lines + 1] = chess.toFen(pos)
  lines[#lines + 1] = tostring(historyBase)
  for i = 1, #history do lines[#lines + 1] = history[i] end
  fs.write(SAVE_PATH, table.concat(lines, "\n") .. "\n")
end

local function loadGame()
  local raw = fs.read(SAVE_PATH)
  if not raw then return false end
  local version, fen, base = raw:match("^(%d+)\n([^\n]+)\n(%d+)\n(.*)$")
  if not version then return false end
  local restored = chess.parseFen(fen)
  if not restored then return false end
  pos = restored
  historyBase = tonumber(base)
  history = {}
  historyUndo = {}
  for line in (raw:gsub("^%d+\n[^\n]+\n%d+\n", "")):gmatch("[^\n]+") do
    if #history < chess.MAX_HISTORY then history[#history + 1] = line end
  end
  selected = -1
  engineThinking = false
  -- The plies just read back are notation only: neither take-back nor
  -- repetition may look behind this point.
  undoableFrom = #history
  resetRepetition()
  refreshLegalMoves()
  return true
end

local function saveSettings()
  fs.write(CFG_PATH, string.format("1 %d %d %d %d\n", settings.level,
                                   settings.playAsWhite and 1 or 0,
                                   settings.hints and 1 or 0, settings.opponent))
end

local function loadSettings()
  local raw = fs.read(CFG_PATH)
  if not raw then return end
  local version, level, white, hints, opponent = raw:match("^(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
  if not version or tonumber(version) ~= 1 then return end
  settings.level = math.max(0, math.min(2, tonumber(level)))
  settings.playAsWhite = white ~= "0"
  settings.hints = hints ~= "0"
  -- A multiplayer setting never persists (multiplayer is an action, not a
  -- setting): anything in the file reads back as COMPUTER.
  settings.opponent = math.max(0, math.min(2, tonumber(opponent)))
end

local function resetGame()
  pcall(function() fs.remove(SAVE_PATH) end)
  startedOpponent = settings.opponent
  startedHumanWhite = settings.playAsWhite
  saveSettings()
  pos = chess.startPos()
  selected = -1
  gameOver = false
  engineThinking = false
  history = {}
  historyUndo = {}
  historyBase = 0
  undoableFrom = 0
  resetRepetition()
  refreshLegalMoves()
  -- Playing Black means the engine opens.
  if engineToMove() and not gameOver then engineThinking = true end
end

local function playEngineMove()
  engineThinking = false
  -- A COPY: search() makes and unmakes thousands of moves on whatever
  -- position it is handed, and the board on screen must not move underneath.
  local scratch = chess.clone(pos)
  local depth = engine.DEPTH_BY_LEVEL[settings.level + 1]
  local res = engine.search(scratch, depth, engine.NODE_BUDGET)
  if not res.hasMove then
    gameOver = true
    return
  end
  applyMove(res.best)
  if gameOver then
    pcall(function() fs.remove(SAVE_PATH) end)
  else
    saveGame()
  end
end

local function requestNewGame()
  -- Solo it starts one; in a match it asks the other device.
  if linkPlaying() then
    proposeRematch()
  else
    resetGame()
  end
end

local function leaveBoard()
  -- One implementation for every exit from the board.
  if linkPlaying() then
    leaveLink()
    return
  end
  if not gameOver then saveGame() end
  hasSavedGame = true
end

local function refreshContinueDetail()
  continueDetail = string.format("%d %s", #history // 2 + 1,
                                 gameOver and "OVER" or (pos.white and "WHITE" or "BLACK"))
end

local function statusText()
  if gameOver then return "PLAY AGAIN" end
  if engineThinking then return "THINKING" end
  if chess.isInCheck(pos) then return "CHECK" end
  if linkPlaying() then return linkYourTurn() and "YOUR MOVE" or "THEIR MOVE" end
  if settings.opponent ~= 0 then return pos.white and "WHITE TO MOVE" or "BLACK TO MOVE" end
  return engineToMove() and "THINKING" or "YOUR MOVE"
end

local function resultText()
  if not gameOver then return "" end
  if drawReason == "rep" then return "DRAW: REPETITION" end
  if drawReason == "50" then return "DRAW: 50 MOVES" end
  if chess.isInCheck(pos) then return pos.white and "BLACK WINS" or "WHITE WINS" end
  return "STALEMATE"
end

-- ---------------------------------------------------------------- drawing: board
local function drawCapturedStrip(y, capturedFromBlack)
  local x = 16
  for _, t in ipairs(TRACKED) do
    local present = 0
    for sq = 0, 63 do
      local p = pos.squares[sq + 1]
      if p ~= 0 and chess.pieceType(p) == t and chess.isBlack(p) == capturedFromBlack then
        present = present + 1
      end
    end
    local piece = t | (capturedFromBlack and chess.BLACK or 0)
    local ink = SMALL_INK[t]
    for _ = 1, STARTING_COUNT[t] - present do
      drawPieceAt(x - ink[1], y, piece, true)
      x = x + ink[2] + 4
    end
  end
end

local function drawMoveList(top, height)
  local lineHeight = 17
  local lines = height // lineHeight
  if lines <= 0 then return end
  local startY = top
  if gameOver then
    gfx.text(W // 2, top + height - lineHeight, resultText(), "ui12", "bc")
    lines = lines - 1
  end
  if lines <= 0 or #history == 0 then return end
  -- Show the most recent full moves that fit, starting on a White ply so the
  -- columns line up.
  local firstPly = #history - lines * 2
  if firstPly < 0 then firstPly = 0 end
  firstPly = firstPly - (firstPly + historyBase) % 2
  if firstPly < 0 then firstPly = 0 end
  for line = 0, lines - 1 do
    local ply = firstPly + line * 2
    if ply + 1 > #history then break end
    local moveNumber = (historyBase + ply) // 2 + 1
    local text
    if ply + 2 <= #history then
      text = string.format("%d. %s  %s", moveNumber, history[ply + 1], history[ply + 2])
    else
      text = string.format("%d. %s", moveNumber, history[ply + 1])
    end
    gfx.text(W // 2, startY + line * lineHeight, text, "ui12", "c")
  end
end

local function drawBoard(cursor, gear, thinking)
  gfx.clear()
  header("CHESS")
  gearIcon(W - 16 - 36, 8, 36, gear)

  -- the frame and the board
  gfx.rect(LEFT - 6, TOP - 6, BOARD + 12, BOARD + 12, true)
  gfx.rect(LEFT - 3, TOP - 3, BOARD + 6, BOARD + 6, true, false)
  for sq = 0, 63 do
    local x, y = sqToScreen(sq)
    gfx.rect(x, y, SQ, SQ, true, false)
    if (chess.fileOf(sq) + chess.rankOf(sq)) & 1 == 0 then dither(x, y, SQ) end
    drawPieceAt(x, y, pos.squares[sq + 1], false)
  end

  -- the selection frame sits outside its square, so it must come after every
  -- square is painted, and the legal-destination hints with it
  if selected >= 0 then
    local x, y = sqToScreen(selected)
    gfx.rect(x - 2, y - 2, SQ + 4, 2, true)
    gfx.rect(x - 2, y + SQ, SQ + 4, 2, true)
    gfx.rect(x - 2, y - 2, 2, SQ + 4, true)
    gfx.rect(x + SQ, y - 2, 2, SQ + 4, true)
    if settings.hints then
      for i = 1, legalN do
        if chess.mvFrom(legal[i]) == selected then
          local d = chess.mvTo(legal[i])
          local dx, dy = sqToScreen(d)
          if pos.squares[d + 1] == 0 then
            local size = 12
            gfx.rounded_rect(dx + (SQ - size) // 2, dy + (SQ - size) // 2, size, size, size // 2, true)
          else
            cornerMarks(dx, dy, SQ, 14, 3)
          end
        end
      end
    end
  end

  -- the cursor frame (or the gear, which is already drawn highlighted)
  if not gear then
    local cx, cy = sqToScreen(cursor)
    gfx.rect(cx - 2, cy - 2, SQ + 4, 2, true)
    gfx.rect(cx - 2, cy + SQ, SQ + 4, 2, true)
    gfx.rect(cx - 2, cy - 2, 2, SQ + 4, true)
    gfx.rect(cx + SQ, cy - 2, 2, SQ + 4, true)
  end

  -- captured strips: Black's losses above the board, White's below
  drawCapturedStrip(TOP - 6 - 4 - 24, true)
  drawCapturedStrip(TOP + BOARD + 6 + 4, false)

  -- the score sheet between the captures and the status capsule
  local listTop = TOP + BOARD + 6 + 4 + 24 + 8
  drawMoveList(listTop, H - CAP - listTop - 30)

  capsule(thinking and "THINKING" or statusText())
  gfx.text(W // 2, H - 76, "Up/Down/Left/Right move   Confirm = select/move   Back = menu", "small", "c")
  gfx.present()
end

-- ---------------------------------------------------------------- drawing: mini board
local function drawMiniBoard(x0, y0, cell)
  gfx.rect(x0 - 6, y0 - 6, cell * 8 + 12, cell * 8 + 12, true)
  for sq = 0, 63 do
    local f, r = chess.fileOf(sq), chess.rankOf(sq)
    local x, y = x0 + f * cell, y0 + (7 - r) * cell
    gfx.rect(x, y, cell, cell, true, false)
    if (f + r) & 1 == 0 then dither(x, y, cell) end
    if pos.squares[sq + 1] ~= 0 then
      local inset = (cell - 24) // 2
      drawPieceAt(x + inset, y + inset, pos.squares[sq + 1], true)
    end
  end
end

-- ---------------------------------------------------------------- drawing: menu
local function menuRows()
  if hasSavedGame then return { "CONTINUE", "NEW GAME", "PLAY NEARBY", "SETTINGS" } end
  return { "NEW GAME", "PLAY NEARBY", "SETTINGS" }
end

local function drawMenu(sel)
  gfx.clear()
  header("CHESS")
  -- the picture of your game: the position you would be returning to
  drawMiniBoard((W - MINI_CELL * 8) // 2, 62, MINI_CELL)
  continueDetail = continueDetail or ""
  local rows = menuRows()
  local rowH, gap = 44, 6
  local top = H - 60 - #rows * (rowH + gap) + gap
  for i = 1, #rows do
    local y = top + (i - 1) * (rowH + gap)
    local label = rows[i]
    if i - 1 == sel then gfx.rounded_rect(48, y, W - 96, rowH, 8, true) end
    gfx.text(W // 2, y + 11, label, "sans16", (i - 1 == sel) and "cwb" or "cb")
    if label == "CONTINUE" then
      gfx.text(W - 56, y + 11, continueDetail, "ui12", (i - 1 == sel) and "wr" or "r")
    end
    if label == "PLAY NEARBY" then
      -- the two-dot multiplayer mark, right of the label; white ink on the
      -- selected row like the text beside it
      local mx, my = W - 74, y + (rowH - 14) // 2
      local dark = not (i - 1 == sel)
      gfx.rounded_rect(mx, my, 14, 14, 7, true, dark)
      gfx.rounded_rect(mx + 22, my, 14, 14, 7, true, dark)
    end
  end
  gfx.text(W // 2, H - 60, "Up/Down = choose   Confirm = open   Back = exit", "small", "c")
  gfx.present()
end

-- ---------------------------------------------------------------- drawing + logic: settings
local function settingRows(fromMenu)
  local person = settings.opponent ~= 0
  local rows = {}
  if not fromMenu then
    rows[#rows + 1] = "newgame"
    rows[#rows + 1] = "takeback"
  end
  rows[#rows + 1] = "opponent"
  if not person then rows[#rows + 1] = "level" rows[#rows + 1] = "playas" end
  rows[#rows + 1] = "hints"
  return rows
end

local function rowLabel(id)
  return ({ newgame = "NEW GAME", takeback = "TAKE BACK", opponent = "OPPONENT",
            level = "LEVEL", playas = "PLAY AS", hints = "MOVE HINTS" })[id]
end

local function rowValue(id)
  if id == "takeback" then return canTakeBack() and "" or "NONE" end
  if id == "level" then return ({ "EASY", "NORMAL", "HARD" })[settings.level + 1] end
  if id == "playas" then return settings.playAsWhite and "WHITE" or "BLACK" end
  if id == "opponent" then
    return ({ "COMPUTER", "P&P", "F2F" })[settings.opponent + 1]
  end
  if id == "hints" then return settings.hints and "ON" or "OFF" end
  return ""
end

local function restartPending()
  return (not linkPlaying()) and
         (settings.opponent ~= startedOpponent or
          (settings.opponent == 0 and settings.playAsWhite ~= startedHumanWhite))
end

local function closeButtonLabel(fromMenu)
  if restartPending() then return "START NEW GAME" end
  return fromMenu and "BACK TO MENU" or "BACK TO BOARD"
end

local function drawSettings(sel, fromMenu)
  gfx.clear()
  header("SETTINGS")
  local rows = settingRows(fromMenu)
  local rowH, gap = 40, 4
  local top = 64
  for i = 1, #rows do
    local id = rows[i]
    local y = top + (i - 1) * (rowH + gap)
    if i - 1 == sel then gfx.rounded_rect(24, y, W - 48, rowH, 8, true) end
    gfx.text(40, y + 10, rowLabel(id), "ui12", (i - 1 == sel) and "bw" or "b")
    local v = rowValue(id)
    if v ~= "" then gfx.text(W - 40, y + 10, v, "ui12", (i - 1 == sel) and "bwr" or "r") end
  end
  -- the close button, anchored to the bottom margin
  local label = closeButtonLabel(fromMenu)
  local by = H - CAP - 16
  if #rows == sel then
    gfx.rounded_rect(24, by, W - 48, CAP - 8, 8, true)
    gfx.text(W // 2, by + 9, label, "sans16", "cwb")
  else
    gfx.rect(24, by, W - 48, CAP - 8, true)
    gfx.text(W // 2, by + 9, label, "sans16", "cwb")
  end
  gfx.text(W // 2, H - 40, "Up/Down = choose   Confirm = change   Back = close", "small", "c")
  gfx.present()
end

-- One settings event. Returns "close" (or nil) and the new selection index.
local function settingsEvent(ev, sel, fromMenu)
  local rows = settingRows(fromMenu)
  local closeIdx = #rows
  if ev == "up" then return nil, (sel + #rows) % (#rows + 1)
  elseif ev == "down" then return nil, (sel + 1) % (#rows + 1)
  elseif ev == "back" then return "close", sel
  elseif ev == "confirm" then
    if sel == closeIdx then return "close", sel end
    local id = rows[sel + 1]
    if id == "newgame" then
      requestNewGame()
      return "close", sel
    elseif id == "takeback" then
      -- without a board in front of you the row stays inert (the C++ guard:
      -- it returns without closing the overlay)
      if canTakeBack() then
        takeBack()
        return "close", sel
      end
      return nil, sel
    elseif id == "opponent" then
      settings.opponent = (settings.opponent + 1) % 3
      -- the row set shrinks against a person: the selection must come back
      -- into range
      local nr = #settingRows(fromMenu)
      if sel >= nr then sel = nr - 1 end
      saveSettings()
    elseif id == "level" then
      settings.level = (settings.level + 1) % 3
      saveSettings()
    elseif id == "playas" then
      settings.playAsWhite = not settings.playAsWhite
      saveSettings()
    elseif id == "hints" then
      settings.hints = not settings.hints
      saveSettings()
    end
  end
  return nil, sel
end

-- ---------------------------------------------------------------- screens
local function settingsScreen(fromMenu)
  local sel = 0
  while true do
    drawSettings(sel, fromMenu)
    local ev = input.wait()
    local r
    r, sel = settingsEvent(ev, sel, fromMenu)
    if r == "close" then
      -- A setting that cannot apply mid-game restarts it: the close button
      -- has been saying it would.
      if restartPending() then requestNewGame() end
      return fromMenu and "menu" or "board"
    end
  end
end

local function menuScreen()
  local sel = 0
  while true do
    refreshContinueDetail()
    drawMenu(sel)
    local ev = input.wait()
    if ev == "back" then return "exit" end
    if ev == "up" then sel = (sel - 1 + #menuRows()) % #menuRows()
    elseif ev == "down" then sel = (sel + 1) % #menuRows()
    elseif ev == "confirm" then
      local row = menuRows()[sel + 1]
      if row == "CONTINUE" then return "board" end
      if row == "NEW GAME" then
        requestNewGame()
        return "board"
      end
      if row == "PLAY NEARBY" then return "link" end
      if row == "SETTINGS" then settingsScreen(true) end
    end
  end
end

local function boardLoop(interactive)
  -- solo game screen. `interactive` is always true here; the match uses its
  -- own driver so the link keeps ticking.
  local cursor, gear = 12, false
  while true do
    if engineThinking then
      drawBoard(cursor, gear, true)
      playEngineMove()
    end
    drawBoard(cursor, gear, false)
    local ev = input.wait()
    if ev == "back" then
      if gear then gear = false
      elseif selected >= 0 then selected = -1
      else
        leaveBoard()
        return
      end
    elseif ev == "up" then
      local col, row = screenColRow(cursor)
      if row == 0 then gear = true else cursor = cursorStep(cursor, 0, -1) end
    elseif ev == "down" then
      if gear then gear = false else cursor = cursorStep(cursor, 0, 1) end
    elseif ev == "left" then cursor = cursorStep(cursor, -1, 0)
    elseif ev == "right" then cursor = cursorStep(cursor, 1, 0)
    elseif ev == "confirm" then
      if gear then
        local where = settingsScreen(false)
        -- a restart may have happened (closeSettings -> START NEW GAME)
        cursor, gear = 12, false
      elseif gameOver then
        requestNewGame()
      elseif not engineToMove() then
        if selected >= 0 and tryMove(selected, cursor) then
          selected = -1
          if not gameOver and engineToMove() then engineThinking = true end
        else
          local p = pos.squares[cursor + 1]
          if chess.isColour(p, pos.white) then
            selected = (selected == cursor) and -1 or cursor
          else
            selected = -1
          end
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- the link
-- The link conversation state. (linkS itself is declared at the top of the
-- chunk with the rest of the state, so every function binds the same local.)
local seatYou, seatThem = "ready", "looking"
local rematchQuestion = false
local endgameStage = "live"       -- live / final / offer
local finalUntil = 0
local linkCursor, linkGear = 12, false
local settingsOpen = false

local function opponentName()
  return linkS and linkS:opponentName() or ""
end

local function seatValue(seat)
  if seat == "looking" then return "LOOKING" end
  if seat == "deciding" then return "DECIDING" end
  if seat == "ready" then return "READY" end
  if seat == "left" then return "LEFT" end
  return "LOST"
end

local function linkHeadline()
  if not gameOver then return "ANOTHER GAME?" end
  if legalN == 0 and chess.isInCheck(pos) then
    return (pos.white == settings.playAsWhite) and "YOU LOST" or "YOU WON"
  end
  return "DRAW"
end

local function drawLinkScreen(search)
  gfx.clear()
  local headline
  if search then
    headline = "LOOKING FOR A PLAYER"
  elseif not gameOver and seatThem == "lost" then
    headline = "LOST CONNECTION"
  elseif not gameOver and seatThem == "left" then
    headline = "THEY LEFT"
  else
    headline = linkHeadline()
  end
  header("CHESS")
  gfx.text(W // 2, 58, headline, "sans18", "bc")

  -- the seats: you and them, and what each is doing
  local y = 116
  gfx.text(40, y, "YOU", "ui12", "b")
  gfx.text(W - 40, y, search and "READY" or seatValue(seatYou), "ui12", "r")
  y = y + 34
  local themName = opponentName()
  gfx.text(40, y, "THEM", "ui12", "b")
  gfx.text(W - 40, y, search and "LOOKING" or seatValue(seatThem), "ui12", "r")
  if themName ~= "" then
    gfx.text(40, y + 26, themName, "small")
  end

  -- the zone under the seats belongs to the game: the position you have just
  -- finished, in the app's own material
  if not search then
    drawMiniBoard((W - MINI_CELL * 8) // 2, y + 60, MINI_CELL)
  end

  local offer = not search and rematchQuestion and seatThem ~= "left" and seatThem ~= "lost"
  if search then
    capsule("CANCEL")
  elseif offer then
    capsule("PLAY AGAIN")
  else
    capsule("BACK")
  end
  gfx.present()
end

-- Globals on purpose: requestNewGame() and leaveBoard() are compiled earlier
-- in the chunk and call these at runtime; a `local` here would leave those
-- callers reading a global that nothing ever sets.
function proposeRematch()
  if not linkS then return end
  local theyAlreadyAgreed = rematchQuestion and seatThem == "ready"
  -- they have seen everything the final-board hold exists to show them
  endgameStage = "offer"
  settingsOpen = false
  seatYou = "ready"
  linkS:say(link.NOTE_PLAY_AGAIN)
  if theyAlreadyAgreed then
    onRematch()
    return
  end
  rematchQuestion = true
  if seatThem ~= "left" and seatThem ~= "lost" then seatThem = "deciding" end
end

function onMatchStart()
  settings.playAsWhite = linkS:goesFirst()
  refreshTurnLabel()
  resetGame()
  seatYou, seatThem = "deciding", "deciding"
  rematchQuestion = false
  endgameStage = "live"
  linkCursor, linkGear = 12, false
  settingsOpen = false
end

function onRematch()
  -- the side holding the turn plays White (after a mate that is the player
  -- who was mated, which is the courtesy anyway)
  settings.playAsWhite = linkS:phase() == "yourturn"
  resetGame()
  seatYou, seatThem = "deciding", "deciding"
  rematchQuestion = false
  endgameStage = "live"
  linkCursor, linkGear = 12, false
  settingsOpen = false
end

function leaveLink()
  if not linkS then return end
  -- only while a question is open: stop() sends a Bye regardless
  if rematchQuestion then linkS:say(link.NOTE_LEAVING) end
  linkS:stop()
  linkS = nil
  rematchQuestion = false
  endgameStage = "live"
  loadSettings()
  hasSavedGame = loadGame()
  if not hasSavedGame then resetGame() end
end

local function linkFlow()
  linkS = link.open()
  if not linkS:start(nil, system.millis()) then
    linkS = nil
    return
  end
  seatYou, seatThem = "ready", "looking"
  rematchQuestion = false
  endgameStage = "live"
  local screen = "search"
  settingsOpen = false

  while true do
    local now = system.millis()

    -- 1. the link, driven before anything else
    linkS:tick(now)

    -- 2. notes first: one of them can end the wait
    local note = linkS:heard()
    if note == link.NOTE_LEAVING then
      seatThem = "left"
      rematchQuestion = true
      screen = "rematch"
    elseif note == link.NOTE_PLAY_AGAIN then
      seatThem = "ready"
      rematchQuestion = true
      if seatYou == "ready" then
        onRematch()
        screen = "board"
      else
        seatYou = "deciding"
        screen = "rematch"
      end
    end

    -- 3. their move, if any
    local payload = linkS:takeOpponent()
    if payload then adoptRemote(payload) end

    -- 4. the match starting (search -> board)
    if screen == "search" and linkS:takeMatchStart() then
      onMatchStart()
      screen = "board"
    end

    -- 5. phases: they left or went silent
    if linkS:phase() == "over" then
      seatThem = (linkS:ending() == "peerlost") and "lost" or "left"
      rematchQuestion = true
    end

    -- 6. the endgame hold: the final board outranks everything, including the
    -- opponent walking away in the same second. The hold counts from the
    -- paint, and the paint is synchronous here, so from the detection.
    if gameOver and endgameStage == "live" and screen == "board" then
      endgameStage = "final"
      finalUntil = system.millis() + 2500
    end
    if endgameStage == "final" and system.millis() - finalUntil >= 0 then
      endgameStage = "offer"
    end
    if endgameStage == "offer" and screen == "board" then screen = "rematch" end
    if linkS:phase() == "over" and endgameStage ~= "final" then screen = "rematch" end

    -- 7. screen: search / settings / rematch / board
    if screen == "search" then
      drawLinkScreen(true)
      local ev = input.poll()
      if ev == "back" or ev == "confirm" then
        leaveLink()
        break
      end
      app.sleep(30)
    elseif settingsOpen then
      drawSettings(linkSettingsSel, false)
      local ev = input.poll()
      local r
      r, linkSettingsSel = settingsEvent(ev or "", linkSettingsSel, false)
      if r == "close" then
        settingsOpen = false
        -- closing applies (restartPending is always false in a match) and a
        -- NEW GAME row asked the other device already
      end
      app.sleep(30)
    elseif screen == "rematch" then
      drawLinkScreen(false)
      local ev = input.poll()
      if ev == "back" or ev == "confirm" then
        local offer = rematchQuestion and seatThem ~= "left" and seatThem ~= "lost"
        if ev == "confirm" and offer then
          proposeRematch()
        else
          leaveLink()
          break
        end
      end
      app.sleep(30)
    else -- board
      drawBoard(linkCursor, linkGear, false)
      local ev = input.poll()
      if ev == "back" then
        if linkGear then linkGear = false
        elseif selected >= 0 then selected = -1
        else
          leaveLink()
          break
        end
      elseif ev == "up" then
        local col, row = screenColRow(linkCursor)
        if row == 0 then linkGear = true else linkCursor = cursorStep(linkCursor, 0, -1) end
      elseif ev == "down" then
        if linkGear then linkGear = false else linkCursor = cursorStep(linkCursor, 0, 1) end
      elseif ev == "left" then linkCursor = cursorStep(linkCursor, -1, 0)
      elseif ev == "right" then linkCursor = cursorStep(linkCursor, 1, 0)
      elseif ev == "confirm" then
        if linkGear then
          settingsOpen = true
        elseif gameOver then
          requestNewGame() -- asks the other device
        elseif linkYourTurn() then
          if selected >= 0 and tryMove(selected, linkCursor) then
            selected = -1
          else
            local p = pos.squares[linkCursor + 1]
            if chess.isColour(p, pos.white) then
              selected = (selected == linkCursor) and -1 or linkCursor
            else
              selected = -1
            end
          end
        end
      end
      app.sleep(30)
    end
  end
  -- leaving the loop means leaveLink() already ran, or the radio never
  -- started; go back to the menu
end

-- ---------------------------------------------------------------- entry
local function __main()
  W, H = gfx.size()
  loadSettings()
  hasSavedGame = loadGame()
  if not hasSavedGame then resetGame() end
  if engineToMove() and not gameOver then engineThinking = true end
  while true do
    local choice = menuScreen()
    if choice == "exit" then break end
    if choice == "board" then boardLoop(true)
    elseif choice == "link" then linkFlow() end
  end
  if not gameOver and not linkPlaying() then saveGame() end
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