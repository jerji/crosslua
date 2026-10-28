-- link.lua -- the espnow transport for Jaipur PLAY NEARBY.
--
-- A whole game state is one packet: the 64-byte wire format, hex-encoded.
-- The deck never travels -- the seed does, and both devices rebuild the same
-- shuffle from it, which is what keeps a hidden-hand game inside one frame.
--
-- Frames (text, broadcast on channel 1, only the matching game id is
-- accepted):
--   "JP1|<seq>|<128 hex>"   a game state (the sender's whole position)
--   "JP1|<seq>"             ack (no hex: that is what tells them apart)
--
-- The transport turn alternates strictly: send, then wait for the ack, then
-- the peer sends back. The game turn can disagree across a round boundary
-- (the loser starts), and core.link_action closes that gap with a silent
-- pass -- the state is sent back unchanged. Exactly one device deals a new
-- round or a rematch: whichever holds the transport turn.
--
-- ESP-NOW has no delivery guarantee, so every state frame carries a sequence
-- number and is retransmitted every RETRY_MS until acked (MAX_TRIES), and a
-- received state is applied once (duplicates are re-acked and ignored).

local core = require("core")

local link = {}

link.GAME_ID = "JP1"
link.RETRY_MS = 1000
link.MAX_TRIES = 12

function link.start()
  local ok, err = espnow.start({ channel = 1 })
  if not ok then return nil, err end
  return true
end

function link.stop()
  pcall(function() espnow.stop() end)
end

-- A fresh match on this device (clear per-match bookkeeping). Roles are
-- chosen by the user once; seat 0 (host) deals the opening round.
function link.new_match(st, my_seat)
  st.seq = 0
  st.pending = nil
  st.applied = {}
  st.my_transport = my_seat == 0
end

-- Send the current game: next sequence number, remembered until acked.
-- After the call the transport turn is the peer's.
function link.send_state(game, st)
  st.seq = st.seq + 1
  local frame = link.GAME_ID .. "|" .. st.seq .. "|" .. core.tohex(core.pack(game))
  st.pending = { seq = st.seq, frame = frame, tries = 1, last = system.millis() }
  espnow.send("broadcast", frame)
  st.my_transport = false
  return st.pending
end

local function send_ack(seq)
  espnow.send("broadcast", link.GAME_ID .. "|" .. seq)
end

-- Returns "state" when a new peer state was adopted, "ack" when acking our
-- own pending frame, "repeat" for a state we already applied, "ignored".
function link.handle_frame(data, st, on_state)
  local gid, seq, hex = data:match("^(%w+)%|(%d+)%|(%x+)$")
  if gid == link.GAME_ID and hex and #hex == 128 then
    seq = tonumber(seq)
    send_ack(seq)
    if st.applied[seq] then return "repeat" end
    st.applied[seq] = true
    on_state(core.unpack(core.fromhex(hex)), seq)
    return "state"
  end
  local gida, aseq = data:match("^(%w+)%|(%d+)$")
  if gida == link.GAME_ID and aseq and st.pending and tonumber(aseq) == st.pending.seq then
    st.pending = nil
    return "ack"
  end
  return "ignored"
end

-- Retransmit bookkeeping: call each loop; returns true while a send is in
-- flight (so the caller can block new moves, the tic-tac-toe rule).
function link.tick(st, now)
  if not st.pending then return false end
  if now - st.pending.last < link.RETRY_MS then return true end
  if st.pending.tries >= link.MAX_TRIES then
    st.pending = nil -- dropped, like the turn that could not be delivered
    return false
  end
  espnow.send("broadcast", st.pending.frame)
  st.pending.tries = st.pending.tries + 1
  st.pending.last = now
  return true
end

return link