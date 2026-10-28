-- link.lua: play-nearby session over ESP-NOW, ported from crossplay's
-- LinkSession/LinkProtocol/LinkPlay (C++). The Lua wire format is text
-- (same approach as play_nearby_ttt_lua) so frames stay debuggable:
--
--   frame := "CH1|<kind>|<toss>|<seq>|<payload>"
--   kinds:  H hello (payload = your name)      -- broadcast, discovery
--           J join (payload = your name)       -- unicast, "I pick you"
--           S state (payload = fen+lastSan)    -- the whole shared position
--           A ack (empty)                      -- also the heartbeat
--           B bye (payload = reason)           -- leaving
--           N note (payload = one byte)        -- rematch conversation
--           NS note-ack (empty)
--
-- The protocol preserves the C++ session's semantics exactly:
--   * the payload is the WHOLE shared state, not a move, so a lost packet is
--     a stale frame the next one corrects;
--   * turns strictly alternate and the host moves first -- host is elected by
--     coin toss (per-search, mixed from the clock and the MAC), ties broken by
--     lower MAC, both sides compute the same answer with nothing to negotiate;
--   * unacknowledged state retransmits every 400ms; a side with nothing to say
--     re-acks every 1000ms (the liveness signal); 10s of silence = lost;
--   * notes (say) run on their own sequence so either side can raise a rematch
--     question exactly when there is no turn left to carry it.
--
-- Timing constants match LinkSession.h. Only the name and the payload differ
-- from device to device; the GameId is the literal "CH1" (chess).

local link = {}

link.GAME = "CH1"
link.HELLO_MS = 400
link.JOIN_MS = 200
link.HEARTBEAT_MS = 1000
link.RETRY_MS = 400
link.PEER_TIMEOUT_MS = 10000
link.CANDIDATE_FORGET_MS = 3000
link.BYE_REPEATS = 3
link.MAX_PACKETS_PER_TICK = 16

-- notes (the one shared vocabulary, see LinkActivity.cpp)
link.NOTE_PLAY_AGAIN = 1
link.NOTE_LEAVING = 2

local S_IDLE, S_SEARCHING, S_PLAYING, S_ENDED = 0, 1, 2, 3
local E_NONE, E_PEER_LEFT, E_PEER_LOST, E_LOCAL_LEFT = 0, 1, 2, 3

local function macKey(mac)
  -- six raw bytes, so string comparison == the C++ memcmp address order
  local t = {}
  for i = 1, 6 do
    t[i] = tonumber(mac:sub(i * 3 - 2, i * 3 - 1), 16)
  end
  return string.char(table.unpack(t))
end

local function macBytes(mac)
  local t = {}
  for i = 1, 6 do t[i] = tonumber(mac:sub(i * 3 - 2, i * 3 - 1), 16) end
  return t
end

-- The coin toss: mixed from the clock and the MAC so it changes every time
-- somebody taps PLAY NEARBY and two devices tapping in the same millisecond
-- still differ. Arithmetic is kept well below 2^31 so it behaves identically
-- on the device's 32-bit Lua and a 64-bit host.
local function coinToss(nowMs, mac)
  local hash = nowMs % 65536
  for _, b in ipairs(macBytes(mac)) do
    hash = (hash * 33 + b) % 16777216
  end
  return hash % 256
end

local function splitFrame(data)
  local g, kind, toss, seq, payload = data:match("^([^|]+)|([^|]+)|(%d+)|(%d+)|(.*)$")
  if not g then return nil end
  return g, kind, tonumber(toss), tonumber(seq), payload or ""
end

local function newSession(radio)
  local s = {
    radio = radio or espnow,
    state = S_IDLE,
    endReason = E_NONE,
    started = false,
    matchStartPending = false,
    isHost = false,
    myTurn = false,
    peerConfirmed = false,
    toss = 0,
    myMac = "",
    myMacKey = "",
    peerMac = "",
    peerKey = "",
    peerName = "",
    localName = "PLAYER",
    candidate = "",
    candidateKey = "",
    hasCandidate = false,
    candidateHeardMs = 0,
    sequence = 0,
    outgoing = "",
    outgoingSeq = 0,
    outgoingPending = false,
    incoming = "",
    incomingPending = false,
    outgoingSay = "",
    outgoingSaySeq = 0,
    outgoingSayPending = false,
    lastSayMs = 0,
    incomingSay = "",
    incomingSayPending = false,
    peerSaySeq = 0,
    nowMs = 0,
    lastHelloMs = 0,
    lastJoinMs = 0,
    lastSentMs = 0,
    lastStateMs = 0,
    lastHeardMs = 0,
  }
  return s
end

local Session = {}
Session.__index = Session

function Session:phase()
  if self.state == S_SEARCHING then return "searching" end
  if self.state == S_PLAYING then
    if self.myTurn and not self.incomingPending then return "yourturn" end
    return "theirturn"
  end
  if self.state == S_ENDED then return "over" end
  return "off"
end

function Session:ending()
  if self.endReason == E_PEER_LEFT then return "peerleft" end
  if self.endReason == E_PEER_LOST then return "peerlost" end
  if self.endReason == E_LOCAL_LEFT then return "youleft" end
  return "none"
end

function Session:opponentName()
  return self.peerName
end

function Session:goesFirst()
  return self.isHost
end

function Session:takeMatchStart()
  if not self.matchStartPending then return false end
  self.matchStartPending = false
  return true
end

function Session:transmit(toMac, kind, seq, payload)
  local frame = link.GAME .. "|" .. kind .. "|" .. self.toss .. "|" .. (seq or 0) .. "|" .. (payload or "")
  self.lastSentMs = self.nowMs
  if self.radio.send(toMac, frame) then return true end
  return false
end

function Session:sendHello()
  self.lastHelloMs = self.nowMs
  self:transmit("broadcast", "H", 0, self.localName)
end

function Session:sendJoin()
  self.lastJoinMs = self.nowMs
  local to = self.state == S_PLAYING and self.peerMac or self.candidate
  self:transmit(to, "J", 0, self.localName)
end

function Session:sendState()
  self.lastStateMs = self.nowMs
  self:transmit(self.peerMac, "S", self.outgoingSeq, self.outgoing)
end

function Session:sendAck()
  self:transmit(self.peerMac, "A", self.sequence, "")
end

function Session:sendSay()
  self.lastSayMs = self.nowMs
  self:transmit(self.peerMac, "N", self.outgoingSaySeq, self.outgoingSay)
end

function Session:sendSayAck()
  self:transmit(self.peerMac, "NS", self.peerSaySeq, "")
end

function Session:setPeerName(name)
  if not name or #name == 0 then return end
  self.peerName = name:sub(1, 20)
end

function Session:endMatch(reason)
  self.state = S_ENDED
  self.endReason = reason
  self.myTurn = false
  self.outgoingPending = false
  self.hasCandidate = false
end

function Session:matchWith(fromMac, peerToss, name)
  self.peerMac = fromMac
  self.peerKey = macKey(fromMac)
  self:setPeerName(name)
  self.isHost = (self.toss ~= peerToss and self.toss < peerToss) or
                (self.toss == peerToss and self.myMacKey < self.peerKey)
  self.myTurn = self.isHost
  self.peerConfirmed = false
  self.sequence = 0
  self.outgoing = ""
  self.outgoingSeq = 0
  self.outgoingPending = false
  self.incoming = ""
  self.incomingPending = false
  self.outgoingSay = ""
  self.outgoingSaySeq = 0
  self.outgoingSayPending = false
  self.incomingSay = ""
  self.incomingSayPending = false
  self.peerSaySeq = 0
  self.hasCandidate = false
  self.state = S_PLAYING
  self.lastHeardMs = self.nowMs
  self.matchStartPending = true
  self:sendAck()
end

function Session:handlePacket(fromMac, data)
  local g, kind, toss, seq, payload = splitFrame(data)
  if g ~= link.GAME then return end
  if fromMac == self.myMac then return end -- our own broadcast, reflected

  if self.state == S_SEARCHING then
    if kind == "H" or kind == "J" then
      local key = macKey(fromMac)
      if not self.hasCandidate or key < self.candidateKey then
        self.candidate = fromMac
        self.candidateKey = key
        self.hasCandidate = true
        self.candidateHeardMs = self.nowMs
        self:setPeerName(payload)
      elseif fromMac == self.candidate then
        self.candidateHeardMs = self.nowMs
      end
    end
    if kind == "J" and self.hasCandidate and fromMac == self.candidate then
      self:matchWith(fromMac, toss, payload)
      return
    end
    -- An Ack/State/Say from someone means they already matched with us:
    -- accepting is always the fastest route to both sides agreeing.
    if kind == "A" or kind == "S" or kind == "N" or kind == "NS" then
      self:matchWith(fromMac, toss, nil)
    end
    return
  end

  if self.state ~= S_PLAYING then return end
  if fromMac ~= self.peerMac then return end
  self.lastHeardMs = self.nowMs

  if kind == "J" then
    -- They are still searching, so our Join never landed. Answer it, but
    -- never more often than a searching device would Join, and never after
    -- they have proven the match is real (an Ack/State) -- that loop has no
    -- exit.
    if not self.peerConfirmed and self.nowMs - self.lastJoinMs >= link.JOIN_MS then
      self:sendJoin()
    end
  elseif kind == "S" then
    if seq > self.sequence then
      self.incoming = payload
      self.incomingPending = true
      self.sequence = seq
      self.myTurn = true
      self.outgoingPending = false -- they moved, so ours plainly arrived
    end
    self.peerConfirmed = true
    self:sendAck()
  elseif kind == "A" then
    self.peerConfirmed = true
    if self.outgoingPending and seq >= self.outgoingSeq then
      self.outgoingPending = false
    end
  elseif kind == "N" then
    if seq > self.peerSaySeq then
      self.incomingSay = payload
      self.incomingSayPending = true
      self.peerSaySeq = seq
    end
    self.peerConfirmed = true
    self:sendSayAck()
  elseif kind == "NS" then
    self.peerConfirmed = true
    if self.outgoingSayPending and seq >= self.outgoingSaySeq then
      self.outgoingSayPending = false
    end
  elseif kind == "B" then
    self:endMatch(E_PEER_LEFT)
  elseif kind == "H" then
    -- A Hello is broadcast only by a device NOT in a match; one from a peer
    -- we have exchanged real traffic with proves they left and went back to
    -- looking.
    if self.peerConfirmed then self:endMatch(E_PEER_LEFT) end
  end
end

-- Drain the radio and run the clocks. Call once per loop pass.
function Session:tick(nowMs)
  self.nowMs = nowMs
  if self.state ~= S_SEARCHING and self.state ~= S_PLAYING then return end

  local drained = 0
  while true do
    local data, fromMac = self.radio.recv()
    if not data then break end
    drained = drained + 1
    if drained > link.MAX_PACKETS_PER_TICK then break end
    self:handlePacket(fromMac or "", data)
    if self.state ~= S_SEARCHING and self.state ~= S_PLAYING then return end
  end

  if self.state == S_SEARCHING then
    if self.hasCandidate and nowMs - self.candidateHeardMs >= link.CANDIDATE_FORGET_MS then
      self.hasCandidate = false
    end
    if nowMs - self.lastHelloMs >= link.HELLO_MS then self:sendHello() end
    if self.hasCandidate and nowMs - self.lastJoinMs >= link.JOIN_MS then self:sendJoin() end
    return
  end

  if nowMs - self.lastHeardMs >= link.PEER_TIMEOUT_MS then
    self:endMatch(E_PEER_LOST)
    return
  end
  if self.outgoingSayPending and nowMs - self.lastSayMs >= link.RETRY_MS then self:sendSay() end
  if self.outgoingPending and nowMs - self.lastStateMs >= link.RETRY_MS then
    self:sendState()
  elseif nowMs - self.lastSentMs >= link.HEARTBEAT_MS then
    self:sendAck()
  end
end

-- ---------------------------------------------------------------- public API
-- Brings up the radio and starts looking. `name` is what the other device
-- shows; `nowMs` feeds the coin toss. Returns false when the radio will not
-- start.
function Session:start(name, nowMs)
  self:stop()
  local ok, mac = self.radio.start({ channel = 1 })
  if not ok then return false end
  self.nowMs = nowMs or 0
  self.myMac = mac or ""
  self.myMacKey = macKey(self.myMac)
  self.localName = (name or ""):sub(1, 20)
  if #self.localName == 0 then
    -- same fallback as the C++ layer: derive from the radio's own address
    local tail = mac:gsub(":", ""):sub(-4):upper()
    self.localName = "PLAYER " .. tail
  end
  self.state = S_SEARCHING
  self.endReason = E_NONE
  self.started = true
  self.matchStartPending = false
  self.peerConfirmed = false
  self.toss = coinToss(self.nowMs, self.myMac)
  self.hasCandidate = false
  self.peerMac = ""
  self.peerKey = ""
  self.peerName = ""
  self.outgoingPending = false
  self.incomingPending = false
  self.outgoingSayPending = false
  self.incomingSayPending = false
  self.lastHeardMs = self.nowMs
  self.lastSentMs = self.nowMs
  self.lastStateMs = self.nowMs
  self.lastJoinMs = self.nowMs
  self:sendHello()
  return true
end

-- Tells the peer we are going (a Bye, repeated, plus a leaving note if one is
-- open) and shuts the radio down. Idempotent.
function Session:stop()
  if not self.started then return end
  if self.state == S_PLAYING then
    for _ = 1, link.BYE_REPEATS do
      self:transmit(self.peerMac, "B", self.sequence, "1")
    end
  end
  self.state = S_IDLE
  self.started = false
  self.matchStartPending = false
  if self.endReason == E_NONE then self.endReason = E_LOCAL_LEFT end
  pcall(function() self.radio.stop() end)
end

-- Sends the whole shared state after your move. Refused unless it is your
-- turn with nothing pending.
function Session:play(payload)
  if self.state ~= S_PLAYING or not self.myTurn then return false end
  if self.incomingPending then return false end
  if #payload > 190 then return false end
  self.sequence = (self.sequence + 1) % 65536
  self.outgoing = payload
  self.outgoingSeq = self.sequence
  self.outgoingPending = true
  self.myTurn = false
  self:sendState()
  return true
end

-- Copies the opponent's state out, once. Returns nil when nothing is new.
function Session:takeOpponent()
  if not self.incomingPending then return nil end
  self.incomingPending = false
  return self.incoming
end

-- One-byte note that does not touch the turn. Retransmitted until acked.
function Session:say(note)
  if self.state ~= S_PLAYING then return false end
  self.outgoingSay = tostring(note)
  self.outgoingSaySeq = (self.outgoingSaySeq + 1) % 65536
  self.outgoingSayPending = true
  self:sendSay()
  return true
end

-- True once per note the peer sends.
function Session:heard()
  if not self.incomingSayPending then return nil end
  self.incomingSayPending = false
  return tonumber(self.incomingSay)
end

-- ---------------------------------------------------------------- factory
function link.open()
  local s = setmetatable(newSession(espnow), Session)
  return s
end

return link