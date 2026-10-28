-- Wavelength (party spectrum game), one device passed round the table.
-- The DECK is not shipped with this app. It is a commercial card set, and the crossplay doc (docs/apps/wavelength.md,
-- "The deck") says it is not ours to republish. Put the file at  Wavelength/pairs.txt  on the card, one pair per line:
--   LEFT WORD|RIGHT WORD            e.g.  HOT|COLD
-- Rules (from the doc): a 20-slot strip with a hidden target slot (1..20). The clue-giver peeks (here: one press shows
-- the target for 4 seconds, since the device has no hold). The guesser moves the marker (up/down = one slot, left/right
-- = five slots) and locks it with Confirm. Then the END-CALL: left or right, whether the target is further left or right
-- than the guess. Scoring: exact 5, one off 3, two off 1, nothing beyond. A correct end-call adds 1.
-- Round one is practice and does not score. Back exits. The "pick one of two spectra" step is not in this build.

local W, H = 0, 0
local SLOTS = 20
local PEEK_MS = 4000
local pairs_list = {}

local function load_deck()
  local text = fs.read("sd:Wavelength/pairs.txt")
  if not text then return end
  for line in text:gmatch("[^\n]+") do
    local l, r = line:match("^%s*(.-)%s*|%s*(.-)%s*$")
    if l and r and l ~= "" and r ~= "" then pairs_list[#pairs_list + 1] = { l = l, r = r } end
  end
end

local function rnd(n)
  local ok, b = pcall(crypto.random, 2)
  if ok and type(b) == "string" and #b == 2 then return (b:byte(1) * 256 + b:byte(2)) % n + 1 end
  return math.random(n)
end

local function score_guess(target, guess)
  local d = math.abs(target - guess)
  if d == 0 then return 5 elseif d == 1 then return 3 elseif d == 2 then return 1 end
  return 0
end

local function strip(x, y, marker, target_show, label)
  -- the strip: 20 cells of 20 px. marker: guess slot. target_show: target slot or nil.
  local cw = 20
  local ox = (W - SLOTS * cw) // 2
  for s = 1, SLOTS do
    gfx.rect(ox + (s - 1) * cw, y, cw, 24, false)
  end
  if marker then
    local mx = ox + (marker - 1) * cw
    gfx.rect(mx + 2, y - 10, cw - 4, 10, true)
  end
  if target_show then
    local tx = ox + (target_show - 1) * cw
    gfx.rect(tx + 4, y + 6, cw - 8, 12, true)
  end
end

local function draw(state, note)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "Wavelength", "ui12", "bw")
  gfx.text(W - 120, 10, "Score " .. state.score, "ui12", "bw")
  local pr = state.pair
  if pr then
    gfx.text(W // 2, 70, pr.l, "sans18", "c")
    gfx.text(W // 2, 720, pr.r, "sans18", "c")
  end
  if state.stage == "mode" then
    gfx.text(W // 2, 200, "CHOOSE A MODE", "ui12", "c")
    gfx.text(W // 2, 260, (state.mode_sel == 1 and "> " or "  ") .. "CO-OP  (score the distance only)", "ui12", "c")
    gfx.text(W // 2, 300, (state.mode_sel == 2 and "> " or "  ") .. "TEAMS (other team bets the end-call, +1)", "ui12", "c")
    gfx.text(W // 2, 360, "Up/Down choose, Confirm starts", "small", "c")
  elseif state.stage == "peek" then
    gfx.text(W // 2, 300, "Clue-giver: press Confirm to peek", "ui12", "c")
  elseif state.stage == "peek_show" then
    strip(0, 400, nil, state.target, "")
    gfx.text(W // 2, 360, "TARGET (4 s)", "ui12", "c")
  elseif state.stage == "guess" then
    strip(0, 400, state.guess, nil, "")
    gfx.text(W // 2, 360, "Up/Down = 1, Left/Right = 5, Confirm locks", "small", "c")
  elseif state.stage == "call" then
    strip(0, 400, state.guess, nil, "")
    gfx.text(W // 2, 360, "End-call: is the target LEFT or RIGHT of the marker?", "small", "c")
    gfx.text(W // 2, 380, "Left = further left, Right = further right", "small", "c")
  elseif state.stage == "reveal" then
    strip(0, 400, state.guess, state.target, "")
    gfx.text(W // 2, 330, string.format("Target %d, guess %d", state.target, state.guess), "ui12", "c")
    if state.mode == "teams" then
      gfx.text(W // 2, 360, string.format("Round points: %d  (end-call %s)", state.round_points, state.call_ok and "correct +1" or "wrong"), "ui12", "c")
    else
      gfx.text(W // 2, 360, string.format("Round points: %d  (co-op: no end-call)", state.round_points), "ui12", "c")
    end
  end
  gfx.text(14, H - 60, note or "", "small")
  gfx.text(14, H - 34, state.round_label or "", "small")
  gfx.present()
end

local ok, err = pcall(function()
  W, H = gfx.size()
  load_deck()
  if #pairs_list == 0 then
    gfx.clear(); gfx.text(14, 80, "No pairs.txt found.", "ui12")
    gfx.text(14, 110, "Put LEFT|RIGHT pairs in Wavelength/pairs.txt on the card.", "small")
    gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  local state = { score = 0, round = 0, mode = "coop", mode_sel = 1, stage = "mode" }
  -- resolve one round. said = "LEFT"/"RIGHT" (teams end-call) or nil (co-op: no call).
  -- Co-op scores the distance only; teams adds one point for a correct end-call. Round one is practice.
  local function resolve_round(st, said)
    local base = score_guess(st.target, st.guess)
    local true_side = (st.target < st.guess) and "LEFT" or ((st.target > st.guess) and "RIGHT" or nil)
    st.call_ok = (said ~= nil) and (true_side == nil or said == true_side) or nil
    local bonus = (st.mode == "teams" and st.call_ok and true_side ~= nil) and 1 or 0
    st.round_points = base + bonus
    if st.round > 1 then st.score = st.score + st.round_points end
    st.stage = "reveal"
  end
  local function new_round()
    state.round = state.round + 1
    state.pair = pairs_list[rnd(#pairs_list)]
    state.target = rnd(SLOTS)
    state.guess = 10
    state.stage = "peek"
    state.round_points = 0
    state.round_label = (state.round == 1) and "Round 1: practice, not scored. Confirm to peek." or ("Round " .. state.round .. ". Confirm to peek.")
  end
  draw(state, "")
  while true do
    local e = input.wait()
    if e == "back" then break end
    if state.stage == "mode" then
      if e == "up" then state.mode_sel = 1
      elseif e == "down" then state.mode_sel = 2
      elseif e == "confirm" then
        state.mode = (state.mode_sel == 2) and "teams" or "coop"
        new_round()
      end
    elseif state.stage == "peek" then
      if e == "confirm" then
        state.stage = "peek_show"
        draw(state, "")
        input.wait(PEEK_MS)   -- the device has no hold, so the peek is timed
        state.stage = "guess"
      end
    elseif state.stage == "guess" then
      if e == "up" then state.guess = math.max(1, state.guess - 1)
      elseif e == "down" then state.guess = math.min(SLOTS, state.guess + 1)
      elseif e == "left" then state.guess = math.max(1, state.guess - 5)
      elseif e == "right" then state.guess = math.min(SLOTS, state.guess + 5)
      elseif e == "confirm" then
        if state.mode == "teams" then
          state.stage = "call"
        else
          resolve_round(state, nil)
        end
      end
    elseif state.stage == "call" then
      if e == "left" or e == "right" then
        resolve_round(state, (e == "left") and "LEFT" or "RIGHT")
      end
    elseif state.stage == "reveal" then
      if e == "confirm" then new_round() end
    end
    draw(state, "")
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
