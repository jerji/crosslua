-- linkturn.lua — who may act over a PLAY NEARBY link, and what their move was.
-- Port of crossplay's seasalt/SeaSaltLink.h (linkAction, describeTheirTurn).
-- Freestanding: no gfx, no radio. Seat 0 is always this device.
--
-- Sea Salt has two notions of "your turn". The transport's alternates strictly
-- (whoever last sent has given it away). The game's does not: a boat pair keeps
-- the game turn, LAST CHANCE hands it over mid-round, and the device that banks
-- a round is not necessarily the one that deals the next. A device holding the
-- transport turn that the rules have nothing for sends the state back
-- unchanged ("pass"). This is the only place that decision lives.

local game = require("game")
local wire = require("wire")

local L = {}

-- "wait" (not your transport turn, or the match is over) | "move" (play, then
-- send) | "pass" (send back unchanged) | "deal" (the round is banked; deal the
-- next one and send it).
function L.action(g, transport)
  if not transport then return "wait" end
  local ph = g.phase
  if ph == game.PHASE.GAMEOVER then return "wait" end
  if ph == game.PHASE.ROUNDOVER then return "deal" end  -- exactly one side holds the transport
  return g.turn == 0 and "move" or "pass"
end

local LOUDEST = { 1, 0, 2, 3 }  -- boat, crab, fish, swimmer: extra turns first

-- One sentence about the opponent's move, from the difference between the state
-- we had and the one that arrived. Every clause reads a public fact.
-- `names` is the display vocabulary for kinds 0..13.
function L.describe(before, after, names)
  local me, them = 0, 1

  -- A new seed is a new deal, not a turn.
  if after.seed ~= before.seed then
    return string.format("ROUND %d. %s", after.round, after.turn == me and "YOU START." or "THEY START.")
  end

  -- A packet that changes nothing is the transport coming straight back.
  if wire.pack(before) == wire.pack(after) then return "YOUR MOVE." end

  if after.phase == game.PHASE.GAMEOVER and game.mermaidsHeld(after, them) == game.MERMAIDS_WIN then
    return "FOUR MERMAIDS. THEY WIN."
  end
  if after.ender == them and before.ender == game.NO_SEAT then
    return after.bet == 1 and "THEY BET LAST CHANCE. ONE MORE TURN, MAKE IT COUNT." or "THEY CALLED STOP."
  end
  if after.phase == game.PHASE.ROUNDOVER and after.ender == game.NO_SEAT then
    return "THE DECK RAN OUT. NOBODY SCORES."
  end
  if game.handSize(after, me) < game.handSize(before, me) then
    return "SWIMMER AND SHARK. THEY STOLE FROM YOUR HAND."
  end

  local theirTable = game.PLACE.TABLE0 + them
  for _, kind in ipairs(LOUDEST) do
    local grew = game.countIn(after, theirTable, kind) - game.countIn(before, theirTable, kind)
    if grew > 0 then
      if kind == 1 then return "THEY PLAYED BOATS FOR EXTRA TURNS." end
      if kind == 3 then return "THEY PLAYED SWIMMER AND SHARK." end
      local plural = kind == 2 and "FISH" or (names[kind + 1] .. "S")
      return "THEY PLAYED TWO " .. plural .. "."
    end
  end
  return "THEY TOOK A CARD. YOUR MOVE."
end

return L
