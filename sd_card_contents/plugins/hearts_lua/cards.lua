-- cards.lua — the shared deck encoding, a Lua port of cards/Cards.h.
--
-- A card is an id 0..51: suit * 13 + rank. Suits are 0 clubs, 1 diamonds,
-- 2 spades, 3 hearts. THE NUMBERING IS ACE-LOW (0 = ace .. 12 = king) and
-- it is not a trick-taking order — Klondike built foundations upward from
-- the ace and never compares two cards for height, so it got to keep the
-- numbering; any game that ranks cards converts in one place. Hearts does
-- that in trickRank(), and every "which is higher" question in the whole
-- game goes through it: a raw comparison would make the ace lose every
-- trick it enters, silently, in the one operation this game is made of.

local M = {}

M.NO_CARD = 255
M.ACE, M.TWO, M.JACK, M.QUEEN, M.KING = 0, 1, 10, 11, 12
M.CLUBS, M.DIAMONDS, M.SPADES, M.HEARTS = 0, 1, 2, 3

M.RANK = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }
M.SUIT = { "C", "D", "S", "H" }
M.SUIT_NAME = { "CLUBS", "DIAMONDS", "SPADES", "HEARTS" }

function M.make(suit, rank) return suit * 13 + rank end
function M.suitOf(c) return c // 13 end
function M.rankOf(c) return c % 13 end

function M.isRed(c)
  local s = M.suitOf(c)
  return s == M.DIAMONDS or s == M.HEARTS
end
function M.isHeart(c) return M.suitOf(c) == M.HEARTS end
function M.isQueenOfSpades(c) return M.suitOf(c) == M.SPADES and M.rankOf(c) == M.QUEEN end

-- Hearts ranks the ace HIGHEST: 2 = 0 .. K = 11, A = 12. Every trick and
-- pass decision reads this, never the raw rank.
function M.trickRank(c)
  local r = M.rankOf(c)
  return (r == M.ACE) and 12 or (r - 1)
end

-- What a card costs whoever takes the trick it is in.
function M.penalty(c)
  if M.isQueenOfSpades(c) then return 13 end
  return M.isHeart(c) and 1 or 0
end

M.TWO_OF_CLUBS = M.make(M.CLUBS, M.TWO)

-- Short label for a status line, e.g. "A S" / "10 H".
function M.label(c)
  return M.RANK[M.rankOf(c) + 1] .. M.SUIT[M.suitOf(c) + 1]
end

return M