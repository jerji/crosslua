-- underhand_lua/save.lua
-- The save: profile + (optionally) the run in progress + the random state,
-- as a JSON document under data:underhand.sav (atomic fs.write). Keeps the
-- spirit of the C++ UnderhandSave: a run a build cannot continue drops the
-- run and keeps the profile; the profile is also read first when the shape
-- of the document is off.
local M = {}
local engine = require("engine")

local function gameTable(game)
  return {
    held = game.held, draw = game.draw, discard = game.discard,
    card = game.card, cost = game.cost, gain = game.gain, rolled = game.rolled,
    lockedMask = game.lockedMask, phase = game.phase, loss = game.loss,
    god = game.god, tutorial = game.tutorial,
    seen = game.seen, seenCount = game.seenCount, discardMask = game.discardMask,
    mayDiscard = game.mayDiscard, played = game.played, playedOption = game.playedOption,
    paid = game.paid, lost = game.lost, gained = game.gained,
    added = game.added, addedCount = game.addedCount,
    reshuffled = game.reshuffled, turn = game.turn,
  }
end

function M.encode(save)
  return json.encode({
    1, -- version
    save.profile.summoned, save.profile.previous, save.profile.tutorialDone and 1 or 0,
    save.inRun and 1 or 0, save.showOutcome and 1 or 0,
    save.rng, -- 16-hex string
    gameTable(save.game or {}),
  })
end

-- Returns a Save table, or nil when nothing can be trusted.
function M.decode(text, cards)
  local t = json.decode(text)
  if type(t) ~= "table" then return nil end
  -- layout: 1 version, 2 summoned, 3 previous, 4 tutorialDone,
  -- 5 inRun, 6 showOutcome, 7 rng (hex), 8 game
  if t[1] ~= 1 then return nil end
  local profile = {
    summoned = t[2] or 0,
    previous = t[3] or -1,
    tutorialDone = (t[4] or 0) ~= 0,
  }
  -- clamp the profile to these cards, like readProfile
  local gods = cards.godCount()
  if profile.previous < -1 or profile.previous >= gods then profile.previous = -1 end
  profile.summoned = profile.summoned & ((1 << gods) - 1)
  local inRunN, outN, rng, g = t[5] or 0, t[6] or 0, t[7], t[8]
  local save = { profile = profile, inRun = false, showOutcome = false }
  if type(rng) ~= "string" or #rng ~= 16 then rng = "0000000000000001" end
  save.rng = rng
  if (inRunN == 0 and outN == 0) or type(g) ~= "table" then return save end
  save.inRun = inRunN ~= 0
  save.showOutcome = outN ~= 0
  local game = {
    held = g.held or { 0, 0, 0, 0, 0, 0 },
    draw = g.draw or {}, discard = g.discard or {},
    card = g.card or 0,
    cost = g.cost or {}, gain = g.gain or {}, rolled = g.rolled or {},
    lockedMask = g.lockedMask or 0, phase = g.phase or engine.CHOOSING, loss = g.loss or 0,
    god = g.god or -1, tutorial = (g.tutorial or 0) ~= 0,
    seen = g.seen or { 0, 0, 0 }, seenCount = g.seenCount or 0,
    discardMask = g.discardMask or 0, mayDiscard = (g.mayDiscard or 0) ~= 0,
    played = g.played or 0, playedOption = g.playedOption or -1,
    paid = g.paid or { 0, 0, 0, 0, 0, 0 }, lost = g.lost or { 0, 0, 0, 0, 0, 0 },
    gained = g.gained or { 0, 0, 0, 0, 0, 0 },
    added = g.added or {}, addedCount = g.addedCount or 0,
    reshuffled = (g.reshuffled or 0) ~= 0, turn = g.turn or 0,
  }
  save.game = game
  -- An outcome is only ever shown over a card, for a choice that was made.
  if not (save.inRun and (game.phase == engine.CHOOSING or game.phase == engine.FORESIGHT)) then
    save.inRun = false
  end
  if save.inRun and not engine.valid(game, cards) then save.inRun = false end
  if not save.inRun or game.phase ~= engine.CHOOSING or game.played == 0 then save.showOutcome = false end
  if not save.inRun then save.game = nil end
  return save
end

function M.store(save)
  return fs.write("data:underhand.sav", M.encode(save))
end

function M.load(cards)
  local text, err = fs.read("data:underhand.sav")
  if not text then return nil end
  return M.decode(text, cards)
end

return M