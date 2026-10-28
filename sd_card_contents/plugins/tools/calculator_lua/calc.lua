-- Calculator key state machine (crossplay docs/apps/calculator.md, "What is settled about the KEYS").
-- Rules pinned here: percent reads the pending operator (200 + 10 % = 220; 200 x 10 % = 20); 2 + 3 = = = is 5, 8, 11;
-- two operators in a row replace; divide by zero is an error that refuses every key but C; the 11th typed digit is
-- refused (we cap at 10 digits, which is what the panel shows); no negative zero; backspace never leaves an empty panel.
local D = require("dec")
local C = {}

local ZERO = { s = 1, d = "0", e = 0 }

function C.new()
  return { entry = nil, entry_neg = false, acc = nil, op = nil, last_op = nil, last_rhs = nil,
           err = nil, just_eq = false }
end

local function digits_in(s) local n = 0; for _ in s:gmatch("%d") do n = n + 1 end; return n end

local function apply(st, a, o, b)
  if o == "+" then return D.add(a, b)
  elseif o == "-" then return D.add(a, D.neg(b))
  elseif o == "*" then return D.mul(a, b)
  else
    local r = D.div(a, b)
    if not r then st.err = "Cannot divide by zero"; return ZERO end
    return r
  end
end

local function entry_value(st)
  local v = D.parse(st.entry)
  if st.entry_neg and st.entry ~= "0" then v = D.neg(v) end
  return v
end

function C.display(st)
  if st.err then return st.err end
  if st.entry then
    local sign = (st.entry_neg and st.entry ~= "0") and "-" or ""
    return sign .. st.entry
  end
  if st.acc then return D.format(st.acc, 10) end
  return "0"
end

local function fresh_if_done(st)
  if st.just_eq then st.entry = nil; st.entry_neg = false; st.acc = nil; st.op = nil; st.just_eq = false end
end

function C.press(st, key)
  if key == "C" then local n = C.new(); for k, v in pairs(n) do st[k] = v end; return st end
  if st.err then return st end
  if key:match("^%d$") then
    fresh_if_done(st)
    if st.entry == nil then st.entry = key
    elseif st.entry == "0" and key ~= "0" then st.entry = key
    elseif st.entry == "0" then st.entry = "0"
    elseif digits_in(st.entry) < 10 then st.entry = st.entry .. key end
  elseif key == "." then
    fresh_if_done(st)
    if st.entry == nil then st.entry = "0."
    elseif not st.entry:find("%.") then st.entry = st.entry .. "." end
  elseif key == "+" or key == "-" or key == "*" or key == "/" then
    st.just_eq = false
    if st.entry then
      local rhs = entry_value(st)
      if st.op and st.acc then st.acc = apply(st, st.acc, st.op, rhs) else st.acc = rhs end
      st.entry = nil; st.entry_neg = false
    elseif st.acc == nil then
      st.acc = ZERO
    end
    st.op = key     -- two operators in a row replace
    if st.err then return st end
  elseif key == "=" then
    if st.op then
      local rhs
      if st.entry then rhs = entry_value(st) else rhs = st.acc or ZERO end
      st.acc = apply(st, st.acc or ZERO, st.op, rhs)
      st.last_op, st.last_rhs = st.op, rhs
      st.entry = nil; st.entry_neg = false; st.op = nil
      st.just_eq = true
    elseif st.last_op then
      st.acc = apply(st, st.acc or ZERO, st.last_op, st.last_rhs)
      st.just_eq = true
    end
  elseif key == "%" then
    if st.entry then
      local v = entry_value(st)
      local p = D.div(v, { s = 1, d = "100", e = 0 })
      if (st.op == "+" or st.op == "-") and st.acc then
        p = D.mul(st.acc, p)       -- 200 + 10 % : the percent is of the accumulated value
      end
      local txt = D.format(p, 10)
      st.entry_neg = txt:sub(1, 1) == "-"
      st.entry = txt:gsub("^%-", "")
    elseif st.acc then
      st.acc = D.div(st.acc, { s = 1, d = "100", e = 0 }) or ZERO
    end
  elseif key == "+/-" then
    if st.entry then
      if st.entry == "0" then st.entry_neg = not st.entry_neg
      else st.entry_neg = not st.entry_neg end
    elseif st.acc then
      st.acc = D.neg(st.acc)
    end
  elseif key == "BS" then
    if st.entry then
      local e2 = st.entry:sub(1, -2)
      if e2 == "" then st.entry = nil; st.entry_neg = false else st.entry = e2 end
    end
  end
  return st
end

return C
