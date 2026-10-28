-- nearby.lua — PLAY NEARBY link layer (ESP-NOW, two devices, no router).
-- Port of crossplay/src/apps_local/link (LinkProtocol, LinkSession), reduced to what
-- a two-player match needs. This copy is bundled per game app; keep the copies identical.
--
-- Wire header (12 bytes, little-endian, spec §4.2):
--   "XLNK" | version=1 | type | gameId u16 | seq u16 | payloadLen u8 | toss u8 | payload
-- Types: 1 Hello (broadcast, our name) · 2 Join (unicast, our name) · 3 State (whole
-- game blob, seq = our move counter) · 4 Ack (seq = highest State we accepted from
-- the peer; doubles as heartbeat) · 5 Bye (1 byte: 1 = left) · 6 Say (1 byte note,
-- own counter) · 7 SayAck (seq echoed).
-- Pairing: a device with a LOWER address that hears a Hello is joined by the higher one
-- (Join). First mover: toss compare, lower address breaks ties (spec §5.6).
-- Malformed or foreign packets are dropped silently.

local M = {}

local MAGIC, VERSION = "XLNK", 1
M.HELLO, M.JOIN, M.STATE, M.ACK, M.BYE, M.SAY, M.SAYACK = 1, 2, 3, 4, 5, 6, 7
M.NOTE_PLAY_AGAIN, M.NOTE_LEAVING = 1, 2

local HELLO_MS, JOIN_MS, HEART_MS, RETRY_MS, PEER_MS, CAND_MS = 400, 200, 1000, 400, 10000, 3000
local NEG_INF = -1000000000

-- ------------------------------------------------------------------ codec

function M.encode(t, gid, seq, toss, payload)
  payload = payload or ""
  if #payload > 192 then return nil end
  return string.pack("<c4BBI2I2BB", MAGIC, VERSION, t, gid, seq, #payload, toss) .. payload
end

function M.decode(d)
  if type(d) ~= "string" or #d < 12 then return nil end
  local magic, ver, t, gid, seq, plen, toss = string.unpack("<c4BBI2I2BB", d)
  if magic ~= MAGIC or ver ~= VERSION or t < 1 or t > 7 then return nil end
  if #d ~= 12 + plen then return nil end
  return { type = t, gameId = gid, seq = seq, toss = toss, payload = d:sub(13) }
end

-- true when I move first. Both devices evaluate the same pair and get opposite answers.
function M.firstMover(myToss, theirToss, myMac, theirMac)
  if myToss ~= theirToss then return myToss < theirToss end
  return myMac < theirMac
end

-- ---------------------------------------------------------------- session

local S = {}
S.__index = S

function M.new(gameId, name)
  return setmetatable({
    gid = gameId, name = name or "PLAYER",
    phase = "off",            -- off | search | play | ended
    reason = nil,             -- ended: "left" (Bye / note 2) | "lost" (silence) | "local"
    mac = "", toss = 0,
    peer = nil, peerName = nil, peerToss = 0, iFirst = false,
    cands = {}, joinTo = nil,
    lastHello = NEG_INF, lastJoin = NEG_INF, lastSend = 0, lastHeard = 0,
    outSeq = 0, outBlob = nil, outAt = 0,          -- our State, until acked
    peerSeq = 0, inBlob = nil,                     -- peer's State, accepted once
    saySeq = 0, sayNote = nil, sayAt = 0,          -- our Say, until SayAck
    peerSaySeq = 0, peerAgain = false,
    matched = false,                               -- one-shot, see takeMatch
  }, S)
end

-- Radio up. Returns true, mac | nil, err. The caller shows the error and goes back.
function S:start()
  local ok, info = espnow.start({ channel = 1 })
  if not ok then return nil, info end
  self.mac = string.lower(type(info) == "string" and info or system.mac())
  self.toss = crypto.random(1):byte()
  self.phase = "search"
  self.lastHello = NEG_INF
  return true, self.mac
end

local function send(self, now, to, t, seq, payload)
  local pkt = M.encode(t, self.gid, seq, self.toss, payload)
  if pkt then
    local ok = espnow.send(to, pkt)   -- nil, err = a normal loss; retries cover it
    self.lastSend = now
    return ok
  end
end

-- Leave a live match: Bye x3 (spec), then the session is over. Safe in any phase.
function S:leave(now)
  if self.phase == "play" and self.peer then
    for _ = 1, 3 do send(self, now or 0, self.peer, M.BYE, 0, "\1") end
    self.phase, self.reason = "ended", "local"
  end
end

function S:stop(now)
  self:leave(now)
  espnow.stop()
  self.phase = "off"
end

local function match(self, from, pkt, now)
  self.phase = "play"
  self.peer = from
  self.peerToss = pkt.toss
  self.peerName = (pkt.type == M.JOIN) and pkt.payload or (self.cands[from] and self.cands[from].name)
  self.iFirst = M.firstMover(self.toss, pkt.toss, self.mac, from)
  self.lastHeard = now
  self.matched = true
  send(self, now, from, M.ACK, self.peerSeq, "")
end

-- Everything the radio hands us while searching or playing.
function S:handle(from, pkt, now)
  from = string.lower(from or "")
  if from == self.mac or pkt.gameId ~= self.gid then return end

  if self.phase == "search" then
    if pkt.type == M.HELLO then
      self.cands[from] = { t = now, name = pkt.payload }
    elseif pkt.type == M.JOIN then
      match(self, from, pkt, now)
    elseif from == self.joinTo and (pkt.type == M.ACK or pkt.type == M.STATE) then
      match(self, from, pkt, now)
    end
    return
  end

  if self.phase ~= "play" or from ~= self.peer then return end
  self.lastHeard = now
  if pkt.type == M.JOIN then
    send(self, now, from, M.ACK, self.peerSeq, "")
  elseif pkt.type == M.STATE then
    if pkt.seq > self.peerSeq then
      self.peerSeq = pkt.seq
      self.inBlob = pkt.payload
    end
    send(self, now, from, M.ACK, self.peerSeq, "")
  elseif pkt.type == M.ACK then
    if self.outBlob and pkt.seq >= self.outSeq then self.outBlob = nil end
  elseif pkt.type == M.BYE then
    self.phase, self.reason = "ended", "left"
  elseif pkt.type == M.SAY then
    if pkt.seq > self.peerSaySeq and #pkt.payload >= 1 then
      self.peerSaySeq = pkt.seq
      local note = pkt.payload:byte(1)
      if note == M.NOTE_PLAY_AGAIN then self.peerAgain = true
      elseif note == M.NOTE_LEAVING then self.phase, self.reason = "ended", "left" end
    end
    send(self, now, from, M.SAYACK, pkt.seq, "")
  elseif pkt.type == M.SAYACK then
    if self.sayNote and pkt.seq >= self.saySeq then self.sayNote = nil end
  end
end

-- Drain the radio (at most 16 frames per call). Never blocks.
function S:pump(now)
  if self.phase == "off" then return end
  for _ = 1, 16 do
    local data, from = espnow.recv()
    if not data then break end
    local pkt = M.decode(data)
    if pkt then self:handle(from, pkt, now) end
  end
end

-- Timers: Hello/Join while searching; retransmit + heartbeat + silence while playing.
function S:tick(now)
  if self.phase == "search" then
    if now - self.lastHello >= HELLO_MS then
      self.lastHello = now
      send(self, now, "broadcast", M.HELLO, 0, self.name)
    end
    local best
    for mac, c in pairs(self.cands) do
      if now - c.t > CAND_MS then
        self.cands[mac] = nil
      elseif mac < self.mac and (best == nil or mac < best) then
        best = mac
      end
    end
    self.joinTo = best
    if best and now - self.lastJoin >= JOIN_MS then
      self.lastJoin = now
      send(self, now, best, M.JOIN, 0, self.name)
    end
  elseif self.phase == "play" then
    if now - self.lastHeard >= PEER_MS then
      self.phase, self.reason = "ended", "lost"
      return
    end
    if self.outBlob and now - self.outAt >= RETRY_MS then
      self.outAt = now
      send(self, now, self.peer, M.STATE, self.outSeq, self.outBlob)
    end
    if self.sayNote and now - self.sayAt >= RETRY_MS then
      self.sayAt = now
      send(self, now, self.peer, M.SAY, self.saySeq, string.char(self.sayNote))
    end
    if not self.outBlob and now - self.lastSend >= HEART_MS then
      send(self, now, self.peer, M.ACK, self.peerSeq, "")
    end
  end
end

-- Send our whole game state after a move (the state IS the move).
function S:sendState(now, blob)
  self.outSeq = self.outSeq + 1
  self.outBlob = blob
  self.outAt = now
  send(self, now, self.peer, M.STATE, self.outSeq, blob)
end

-- Say a note to the peer (rematch answer). Retransmitted until SayAck.
function S:say(now, note)
  self.saySeq = self.saySeq + 1
  self.sayNote = note
  self.sayAt = now
  send(self, now, self.peer, M.SAY, self.saySeq, string.char(note))
end

-- One-shot readers for the game loop.
function S:takeMatch()
  local m = self.matched
  self.matched = false
  return m
end

function S:takeState()
  local b = self.inBlob
  self.inBlob = nil
  return b
end

-- A new round has begun on both devices: rematch answers start fresh.
function S:newRound()
  self.peerAgain = false
  self.sayNote = nil
end

return M
