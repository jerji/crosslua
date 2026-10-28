-- chess.lua: the rules engine, ported from crossplay's ChessCore (C++).
--
-- Freestanding on purpose: no gfx, no fs, no device namespaces -- the same
-- guarantee as the C++ (no heap, no Arduino), so the whole ruleset is
-- verifiable on the host (see the perft logic tests). Board squares are
-- 0 = a1 .. 63 = h8, file = sq & 7, rank = sq >> 3, white advances +8.
--
-- Pieces: type in the low 3 bits plue a colour bit (8 = black), so Empty is 0
-- and one byte per square keeps the board at 64 entries.
-- Moves are packed ints: from | to<<6 | promo<<12 | flags<<15.
-- (Maximum 63 | 63<<6 | 7<<12 | 31<<15 fits a 32-bit integer easily.)
--
-- The position is a table the caller owns: { squares, white, castling, ep,
-- half, full } -- squares is a 64-entry table (index sq+1). Everything here
-- mutates in place; copy with clone() when you need a scratch.

local chess = {}

-- pieces
chess.EMPTY, chess.PAWN, chess.KNIGHT, chess.BISHOP = 0, 1, 2, 3
chess.ROOK, chess.QUEEN, chess.KING, chess.BLACK = 4, 5, 6, 8

-- flags
chess.F_NONE, chess.F_CAP, chess.F_DPUSH, chess.F_EP = 0, 1, 2, 4
chess.F_CASTLE, chess.F_PROMO = 8, 16

-- castling rights
chess.WK, chess.WQ, chess.BK, chess.BQ = 1, 2, 4, 8

chess.NO_SQUARE = -1
chess.MAX_HISTORY = 128

local function band(a, b) return a & b end
chess.band = band

function chess.pieceType(p) return band(p, 7) end
function chess.isBlack(p) return band(p, 8) ~= 0 end
function chess.isColour(p, white) return p ~= 0 and chess.isBlack(p) ~= white end
function chess.isWhitePiece(p) return p ~= 0 and not chess.isBlack(p) end
function chess.isBlackPiece(p) return p ~= 0 and chess.isBlack(p) end

function chess.fileOf(sq) return sq & 7 end
function chess.rankOf(sq) return sq >> 3 end
local function onBoard(f, r) return f >= 0 and f < 8 and r >= 0 and r < 8 end
local function squareAt(f, r) return r * 8 + f end
function chess.squareAt(f, r) return squareAt(f, r) end

-- packed moves
function chess.mkMove(from, to, promo, flags) return from | (to << 6) | (promo << 12) | (flags << 15) end
function chess.mvFrom(mv) return band(mv, 0x3F) end
function chess.mvTo(mv) return band(mv >> 6, 0x3F) end
function chess.mvPromo(mv) return band(mv >> 12, 0x7) end
function chess.mvFlags(mv) return band(mv >> 15, 0x1F) end

local KNIGHT_D = { {1, 2}, {2, 1}, {2, -1}, {1, -2}, {-1, -2}, {-2, -1}, {-2, 1}, {-1, 2} }
local KING_D = { {0, 1}, {1, 1}, {1, 0}, {1, -1}, {0, -1}, {-1, -1}, {-1, 0}, {-1, 1} }
local ROOK_D = { {0, 1}, {1, 0}, {0, -1}, {-1, 0} }
local BISHOP_D = { {1, 1}, {1, -1}, {-1, -1}, {-1, 1} }
chess.deltas = { knight = KNIGHT_D, king = KING_D, rook = ROOK_D, bishop = BISHOP_D }

-- ---------------------------------------------------------------- FEN
function chess.newPos()
  local squares = {}
  for i = 1, 64 do squares[i] = 0 end
  return { squares = squares, white = true, castling = 0, ep = chess.NO_SQUARE, half = 0, full = 1 }
end

function chess.parseFen(fen)
  local pos = chess.newPos()
  -- board part
  local boardPart, rest = fen:match("^([^ ]+) ?(.*)$")
  if not boardPart then return nil end
  local rank, file = 7, 0
  for i = 1, #boardPart do
    local c = boardPart:sub(i, i)
    if c == "/" then
      if file ~= 8 then return nil end
      rank = rank - 1
      file = 0
      if rank < 0 then return nil end
    elseif c >= "1" and c <= "8" then
      file = file + (c:byte() - 48)
      if file > 8 then return nil end
    else
      local type_ = ({ p = 1, n = 2, b = 3, r = 4, q = 5, k = 6 })[c:lower()]
      if not type_ then return nil end
      local piece = type_
      if c >= "a" and c <= "z" then piece = piece | chess.BLACK end
      if file > 7 or rank < 0 then return nil end
      pos.squares[squareAt(file, rank) + 1] = piece
      file = file + 1
    end
  end
  if rank ~= 0 or file ~= 8 then return nil end

  -- side to move
  rest = rest:gsub("^ +", "")
  if rest:sub(1, 1) == "w" then pos.white = true
  elseif rest:sub(1, 1) == "b" then pos.white = false
  else return nil end
  rest = rest:sub(2):gsub("^ +", "")

  -- castling
  if rest:sub(1, 1) == "-" then
    rest = rest:sub(2)
  else
    local j = 1
    while j <= #rest and rest:sub(j, j) ~= " " do
      local c = rest:sub(j, j)
      local r = ({ K = chess.WK, Q = chess.WQ, k = chess.BK, q = chess.BQ })[c]
      if not r then return nil end
      pos.castling = pos.castling | r
      j = j + 1
    end
    rest = rest:sub(j)
  end

  -- en passant
  rest = rest:gsub("^ +", "")
  local epf = rest:sub(1, 1)
  if epf == "-" then
    rest = rest:sub(2)
  elseif epf >= "a" and epf <= "h" then
    local epr = rest:sub(2, 2)
    if epr < "1" or epr > "8" then return nil end
    pos.ep = squareAt(epf:byte() - 97, epr:byte() - 49)
    rest = rest:sub(3)
  elseif epf ~= "" then
    return nil
  end

  -- clocks (optional)
  rest = rest:gsub("^ +", "")
  local half = rest:match("^(%d+)")
  if half then
    pos.half = math.min(tonumber(half), 255)
    rest = rest:sub(#half + 1):gsub("^ +", "")
    local full = rest:match("^(%d+)")
    if full then pos.full = tonumber(full) end
  end
  return pos
end

local FEN_PIECE_CHARS = ".pnbrqk"

function chess.toFen(pos)
  local out = {}
  local n = 0
  for rank = 7, 0, -1 do
    local empty = 0
    for file = 0, 7 do
      local piece = pos.squares[squareAt(file, rank) + 1]
      if piece == 0 then
        empty = empty + 1
      else
        if empty > 0 then
          n = n + 1
          out[n] = tostring(empty)
          empty = 0
        end
        local symbol = (".pnbrqk"):sub(chess.pieceType(piece) + 1, chess.pieceType(piece) + 1)
        n = n + 1
        out[n] = chess.isBlack(piece) and symbol or symbol:upper()
      end
    end
    if empty > 0 then
      n = n + 1
      out[n] = tostring(empty)
    end
    if rank > 0 then
      n = n + 1
      out[n] = "/"
    end
  end
  n = n + 1
  out[n] = " "
  n = n + 1
  out[n] = pos.white and "w" or "b"
  n = n + 1
  out[n] = " "
  local cast = ""
  if pos.castling == 0 then
    cast = "-"
  else
    if band(pos.castling, chess.WK) ~= 0 then cast = cast .. "K" end
    if band(pos.castling, chess.WQ) ~= 0 then cast = cast .. "Q" end
    if band(pos.castling, chess.BK) ~= 0 then cast = cast .. "k" end
    if band(pos.castling, chess.BQ) ~= 0 then cast = cast .. "q" end
  end
  n = n + 1
  out[n] = cast
  n = n + 1
  out[n] = " "
  if pos.ep == chess.NO_SQUARE then
    out[n + 1] = "-"
    n = n + 1
  else
    out[n + 1] = string.char(97 + chess.fileOf(pos.ep))
    out[n + 2] = string.char(49 + chess.rankOf(pos.ep))
    n = n + 2
  end
  n = n + 1
  out[n] = " "
  out[n + 1] = tostring(pos.half)
  out[n + 2] = " "
  out[n + 3] = tostring(pos.full)
  return table.concat(out)
end

function chess.clone(pos)
  local copy = { squares = {}, white = pos.white, castling = pos.castling, ep = pos.ep,
                 half = pos.half, full = pos.full }
  for i = 1, 64 do copy.squares[i] = pos.squares[i] end
  return copy
end

chess.START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
function chess.startPos() return chess.parseFen(chess.START_FEN) end

-- ---------------------------------------------------------------- attack
local function hasPieceAt(pos, f, r, type_, white)
  if not onBoard(f, r) then return false end
  local p = pos.squares[squareAt(f, r) + 1]
  return p ~= 0 and chess.pieceType(p) == type_ and chess.isBlack(p) ~= white
end

local function attackedBySlider(pos, f, r, deltas, sliderType, byWhite)
  for d = 1, #deltas do
    local df, dr = deltas[d][1], deltas[d][2]
    local ff, rr = f + df, r + dr
    while onBoard(ff, rr) do
      local p = pos.squares[squareAt(ff, rr) + 1]
      if p ~= 0 then
        if chess.isBlack(p) ~= byWhite then
          local t = chess.pieceType(p)
          if t == sliderType or t == chess.QUEEN then return true end
        end
        break
      end
      ff = ff + df
      rr = rr + dr
    end
  end
  return false
end

function chess.isSquareAttacked(pos, sq, byWhite)
  local f, r = chess.fileOf(sq), chess.rankOf(sq)
  local pawnRank = byWhite and (r - 1) or (r + 1)
  if hasPieceAt(pos, f - 1, pawnRank, chess.PAWN, byWhite) then return true end
  if hasPieceAt(pos, f + 1, pawnRank, chess.PAWN, byWhite) then return true end
  for i = 1, 8 do
    if hasPieceAt(pos, f + KNIGHT_D[i][1], r + KNIGHT_D[i][2], chess.KNIGHT, byWhite) then return true end
    if hasPieceAt(pos, f + KING_D[i][1], r + KING_D[i][2], chess.KING, byWhite) then return true end
  end
  if attackedBySlider(pos, f, r, ROOK_D, chess.ROOK, byWhite) then return true end
  if attackedBySlider(pos, f, r, BISHOP_D, chess.BISHOP, byWhite) then return true end
  return false
end

function chess.findKing(pos, white)
  local target = chess.KING | (white and 0 or chess.BLACK)
  for sq = 0, 63 do
    if pos.squares[sq + 1] == target then return sq end
  end
  return nil
end

function chess.isInCheck(pos)
  local king = chess.findKing(pos, pos.white)
  if not king then return false end
  return chess.isSquareAttacked(pos, king, not pos.white)
end

-- ---------------------------------------------------------------- generation
local PROMO_TYPES = { chess.QUEEN, chess.ROOK, chess.BISHOP, chess.KNIGHT }

local function addPawnMoves(list, n, from, to, flags, promoting)
  if not promoting then
    list[n + 1] = chess.mkMove(from, to, 0, flags)
    return n + 1
  end
  -- C++ order: Queen, Rook, Bishop, Knight.
  for i = 1, 4 do
    n = n + 1
    list[n] = chess.mkMove(from, to, PROMO_TYPES[i], flags | chess.F_PROMO)
  end
  return n
end

-- Appends pseudo-legal moves into `list` (1-based), returns the count.
function chess.genPseudo(pos, list)
  local n = 0
  local white = pos.white
  local forward = white and 1 or -1
  local startRank = white and 1 or 6
  local promoRank = white and 7 or 0

  for from = 0, 63 do
    local piece = pos.squares[from + 1]
    if chess.isColour(piece, white) then
      local f, r = chess.fileOf(from), chess.rankOf(from)
      local t = chess.pieceType(piece)
      if t == chess.PAWN then
        local oneRank = r + forward
        if onBoard(f, oneRank) and pos.squares[squareAt(f, oneRank) + 1] == 0 then
          n = addPawnMoves(list, n, from, squareAt(f, oneRank), chess.F_NONE, oneRank == promoRank)
          local twoRank = r + 2 * forward
          if r == startRank and pos.squares[squareAt(f, twoRank) + 1] == 0 then
            n = n + 1
            list[n] = chess.mkMove(from, squareAt(f, twoRank), 0, chess.F_DPUSH)
          end
        end
        for df = -1, 1, 2 do
          local cf = f + df
          if onBoard(cf, oneRank) then
            local to = squareAt(cf, oneRank)
            local target = pos.squares[to + 1]
            if target ~= 0 and chess.isBlack(target) == white then
              n = addPawnMoves(list, n, from, to, chess.F_CAP, oneRank == promoRank)
            elseif target == 0 and pos.ep ~= chess.NO_SQUARE and to == pos.ep then
              n = n + 1
              list[n] = chess.mkMove(from, to, 0, chess.F_CAP | chess.F_EP)
            end
          end
        end
      elseif t == chess.KNIGHT or t == chess.KING then
        local deltas = t == chess.KNIGHT and KNIGHT_D or KING_D
        for i = 1, 8 do
          local ff, rr = f + deltas[i][1], r + deltas[i][2]
          if onBoard(ff, rr) then
            local target = pos.squares[squareAt(ff, rr) + 1]
            if not chess.isColour(target, white) then
              local flags_ = target == 0 and chess.F_NONE or chess.F_CAP
              n = n + 1
              list[n] = chess.mkMove(from, squareAt(ff, rr), 0, flags_)
            end
          end
        end
      else
        -- bishop / rook / queen
        if t == chess.BISHOP or t == chess.QUEEN then
          for d = 1, 4 do
            local df, dr = BISHOP_D[d][1], BISHOP_D[d][2]
            local ff, rr = f + df, r + dr
            while onBoard(ff, rr) do
              local target = pos.squares[squareAt(ff, rr) + 1]
              if chess.isColour(target, white) then break end
              local flags_ = target == 0 and chess.F_NONE or chess.F_CAP
              n = n + 1
              list[n] = chess.mkMove(from, squareAt(ff, rr), 0, flags_)
              if target ~= 0 then break end
              ff = ff + df
              rr = rr + dr
            end
          end
        end
        if t == chess.ROOK or t == chess.QUEEN then
          for d = 1, 4 do
            local df, dr = ROOK_D[d][1], ROOK_D[d][2]
            local ff, rr = f + df, r + dr
            while onBoard(ff, rr) do
              local target = pos.squares[squareAt(ff, rr) + 1]
              if chess.isColour(target, white) then break end
              local flags_ = target == 0 and chess.F_NONE or chess.F_CAP
              n = n + 1
              list[n] = chess.mkMove(from, squareAt(ff, rr), 0, flags_)
              if target ~= 0 then break end
              ff = ff + df
              rr = rr + dr
            end
          end
        end
      end
    end
  end

  -- castling. Rights alone are not enough: the squares between must be empty,
  -- and neither the start nor the pass-through squares may be attacked.
  local homeRank = white and 0 or 7
  local kingSq = squareAt(4, homeRank)
  local ksRight = white and chess.WK or chess.BK
  local qsRight = white and chess.WQ or chess.BQ
  if pos.squares[kingSq + 1] == (chess.KING | (white and 0 or chess.BLACK)) and
      not chess.isSquareAttacked(pos, kingSq, not white) then
    if band(pos.castling, ksRight) ~= 0 and pos.squares[squareAt(5, homeRank) + 1] == 0 and
        pos.squares[squareAt(6, homeRank) + 1] == 0 and
        not chess.isSquareAttacked(pos, squareAt(5, homeRank), not white) and
        not chess.isSquareAttacked(pos, squareAt(6, homeRank), not white) then
      n = n + 1
      list[n] = chess.mkMove(kingSq, squareAt(6, homeRank), 0, chess.F_CASTLE)
    end
    if band(pos.castling, qsRight) ~= 0 and pos.squares[squareAt(3, homeRank) + 1] == 0 and
        pos.squares[squareAt(2, homeRank) + 1] == 0 and pos.squares[squareAt(1, homeRank) + 1] == 0 and
        not chess.isSquareAttacked(pos, squareAt(3, homeRank), not white) and
        not chess.isSquareAttacked(pos, squareAt(2, homeRank), not white) then
      n = n + 1
      list[n] = chess.mkMove(kingSq, squareAt(2, homeRank), 0, chess.F_CASTLE)
    end
  end
  return n
end

-- Losing a rook (moving it or having it captured) forfeits that side's right
-- on that flank. Keyed by the rook's home square.
local function castlingMaskFor(sq)
  if sq == 0 then return chess.WQ end
  if sq == 7 then return chess.WK end
  if sq == 56 then return chess.BQ end
  if sq == 63 then return chess.BK end
  return 0
end

-- ---------------------------------------------------------------- make/unmake
-- undo: { captured, castling, ep, half }
function chess.makeMove(pos, mv, undo)
  local from, to = chess.mvFrom(mv), chess.mvTo(mv)
  local flags_ = chess.mvFlags(mv)
  undo.captured = pos.squares[to + 1]
  undo.castling = pos.castling
  undo.ep = pos.ep
  undo.half = pos.half

  local piece = pos.squares[from + 1]
  local white = pos.white
  local colourFlag = white and 0 or chess.BLACK

  pos.squares[from + 1] = 0
  pos.squares[to + 1] = piece

  if band(flags_, chess.F_EP) ~= 0 then
    local capturedSq = squareAt(chess.fileOf(to), chess.rankOf(from))
    undo.captured = pos.squares[capturedSq + 1]
    pos.squares[capturedSq + 1] = 0
  elseif band(flags_, chess.F_PROMO) ~= 0 then
    pos.squares[to + 1] = chess.mvPromo(mv) | colourFlag
  elseif band(flags_, chess.F_CASTLE) ~= 0 then
    local homeRank = chess.rankOf(from)
    local kingSide = chess.fileOf(to) == 6
    local rookFrom = squareAt(kingSide and 7 or 0, homeRank)
    local rookTo = squareAt(kingSide and 5 or 3, homeRank)
    pos.squares[rookTo + 1] = pos.squares[rookFrom + 1]
    pos.squares[rookFrom + 1] = 0
  end

  if chess.pieceType(piece) == chess.KING then
    pos.castling = pos.castling & ~(white and (chess.WK | chess.WQ) or (chess.BK | chess.BQ))
  end
  pos.castling = pos.castling & ~castlingMaskFor(from)
  pos.castling = pos.castling & ~castlingMaskFor(to)

  if band(flags_, chess.F_DPUSH) ~= 0 then
    pos.ep = squareAt(chess.fileOf(from), math.floor((chess.rankOf(from) + chess.rankOf(to)) / 2))
  else
    pos.ep = chess.NO_SQUARE
  end

  if chess.pieceType(piece) == chess.PAWN or undo.captured ~= 0 then
    pos.half = 0
  elseif pos.half < 255 then
    pos.half = pos.half + 1
  end
  if not white then pos.full = pos.full + 1 end
  pos.white = not white
end

function chess.unmakeMove(pos, mv, undo)
  pos.white = not pos.white
  local white = pos.white
  if not white then pos.full = pos.full - 1 end

  local from, to = chess.mvFrom(mv), chess.mvTo(mv)
  local flags_ = chess.mvFlags(mv)

  local moved = pos.squares[to + 1]
  if band(flags_, chess.F_PROMO) ~= 0 then
    pos.squares[from + 1] = chess.PAWN | (white and 0 or chess.BLACK)
  else
    pos.squares[from + 1] = moved
  end
  pos.squares[to + 1] = 0

  if band(flags_, chess.F_EP) ~= 0 then
    pos.squares[squareAt(chess.fileOf(to), chess.rankOf(from)) + 1] = undo.captured
  else
    pos.squares[to + 1] = undo.captured
  end

  if band(flags_, chess.F_CASTLE) ~= 0 then
    local homeRank = chess.rankOf(from)
    local kingSide = chess.fileOf(to) == 6
    local rookFrom = squareAt(kingSide and 7 or 0, homeRank)
    local rookTo = squareAt(kingSide and 5 or 3, homeRank)
    pos.squares[rookFrom + 1] = pos.squares[rookTo + 1]
    pos.squares[rookTo + 1] = 0
  end

  pos.castling = undo.castling
  pos.ep = undo.ep
  pos.half = undo.half
end

-- ---------------------------------------------------------------- legal moves
-- Every move that is legal for the side to move; pseudo-legal moves that leave
-- the king attacked are filtered out. Returns the count, filling `list`.
function chess.genLegal(pos, list)
  local tmp = {}
  local n = chess.genPseudo(pos, tmp)
  local count = 0
  local white = pos.white
  -- The king square is found once per call, not once per candidate: a king
  -- move relocates it (to the destination), anything else leaves it put.
  local kingSq = chess.findKing(pos, white)
  local undo = {}
  for i = 1, n do
    local mv = tmp[i]
    local moving = chess.pieceType(pos.squares[chess.mvFrom(mv) + 1])
    chess.makeMove(pos, mv, undo)
    -- a king move relocates the king to its destination; anything else leaves
    -- it put. (No king at all -- a hand-built position -- counts as not
    -- attacked, exactly like the C++ kNoSquare case.)
    local legalMove = true
    if kingSq then
      local testSq = moving == chess.KING and chess.mvTo(mv) or kingSq
      legalMove = not chess.isSquareAttacked(pos, testSq, not white)
    end
    if legalMove then
      count = count + 1
      list[count] = mv
    end
    chess.unmakeMove(pos, mv, undo)
  end
  return count
end

-- ---------------------------------------------------------------- perft
function chess.perft(pos, depth)
  if depth <= 0 then return 1 end
  local list = {}
  local n = chess.genLegal(pos, list)
  if depth == 1 then return n end
  local nodes = 0
  for i = 1, n do
    local undo = {}
    chess.makeMove(pos, list[i], undo)
    nodes = nodes + chess.perft(pos, depth - 1)
    chess.unmakeMove(pos, list[i], undo)
  end
  return nodes
end

-- ---------------------------------------------------------------- notation
function chess.moveToString(mv)
  local from, to = chess.mvFrom(mv), chess.mvTo(mv)
  local out = string.char(97 + chess.fileOf(from), 49 + chess.rankOf(from),
                          97 + chess.fileOf(to), 49 + chess.rankOf(to))
  if band(chess.mvFlags(mv), chess.F_PROMO) ~= 0 then
    local promo = chess.mvPromo(mv)
    local c = "q"
    if promo == chess.ROOK then c = "r"
    elseif promo == chess.BISHOP then c = "b"
    elseif promo == chess.KNIGHT then c = "n" end
    out = out .. c
  end
  return out
end

-- Standard algebraic notation; `pos` is the position BEFORE the move.
function chess.moveToSan(pos, mv)
  local from, to = chess.mvFrom(mv), chess.mvTo(mv)
  local flags_ = chess.mvFlags(mv)
  local piece = pos.squares[from + 1]
  local type_ = chess.pieceType(piece)
  local out = {}

  if band(flags_, chess.F_CASTLE) ~= 0 then
    return chess.fileOf(to) == 2 and "O-O-O" or "O-O"
  elseif type_ == chess.PAWN then
    if band(flags_, chess.F_CAP) ~= 0 then
      out[#out + 1] = string.char(97 + chess.fileOf(from))
      out[#out + 1] = "x"
    end
    out[#out + 1] = string.char(97 + chess.fileOf(to))
    out[#out + 1] = string.char(49 + chess.rankOf(to))
    if band(flags_, chess.F_PROMO) ~= 0 then
      out[#out + 1] = "=Q"
      local promo = chess.mvPromo(mv)
      if promo == chess.ROOK then out[#out] = "=R"
      elseif promo == chess.BISHOP then out[#out] = "=B"
      elseif promo == chess.KNIGHT then out[#out] = "=N" end
    end
  else
    out[#out + 1] = ("..NBRQK"):sub(type_ + 1, type_ + 1)
    -- disambiguation
    local others = {}
    local on = chess.genLegal(pos, others)
    local sameFile, sameRank, ambiguous = false, false, false
    for i = 1, on do
      local other = others[i]
      if chess.mvTo(other) == to and chess.mvFrom(other) ~= from and
          chess.pieceType(pos.squares[chess.mvFrom(other) + 1]) == type_ then
        ambiguous = true
        if chess.fileOf(chess.mvFrom(other)) == chess.fileOf(from) then sameFile = true end
        if chess.rankOf(chess.mvFrom(other)) == chess.rankOf(from) then sameRank = true end
      end
    end
    if ambiguous then
      if not sameFile then
        out[#out + 1] = string.char(97 + chess.fileOf(from))
      elseif not sameRank then
        out[#out + 1] = string.char(49 + chess.rankOf(from))
      else
        out[#out + 1] = string.char(97 + chess.fileOf(from))
        out[#out + 1] = string.char(49 + chess.rankOf(from))
      end
    end
    if band(flags_, chess.F_CAP) ~= 0 then out[#out + 1] = "x" end
    out[#out + 1] = string.char(97 + chess.fileOf(to))
    out[#out + 1] = string.char(49 + chess.rankOf(to))
  end

  -- suffix: '#' when the reply has no legal moves and the king is attacked,
  -- '+' when it is attacked but escapable.
  local afterCheck = {}
  local after = chess.clone(pos)
  local undo = {}
  chess.makeMove(after, mv, undo)
  if chess.isInCheck(after) then
    local replies = {}
    local rn = chess.genLegal(after, replies)
    out[#out + 1] = rn == 0 and "#" or "+"
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------- repetition
-- A compact 67-byte fingerprint (squares + side + castling + ep) used as the
-- repetition key. Strings compare by value, so hash collisions are impossible
-- -- a strict improvement over the C++ FNV-1a hash, which only existed there
-- because C++ strings cannot be compared as keys cheaply.
function chess.positionKey(pos)
  local bytes = {}
  for i = 1, 64 do bytes[i] = pos.squares[i] end
  bytes[65] = pos.white and 1 or 0
  bytes[66] = pos.castling
  bytes[67] = pos.ep + 1
  return string.char(table.unpack(bytes))
end

-- How many times the last key in `keys` already appears, itself included,
-- looking back at most `window` entries. Threefold repetition is this
-- returning 3 or more.
function chess.repetitionCount(keys, count, window)
  if count <= 0 then return 0 end
  local current = keys[count]
  local seen = 1
  for back = 1, window do
    local index = count - back
    if index < 1 then break end
    if keys[index] == current then seen = seen + 1 end
  end
  return seen
end

return chess