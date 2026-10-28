-- Calculator (no radio): type an expression with the on-screen keyboard, get the result.
-- Grammar: expr = term {(+|-) term}; term = factor {(*|/) factor}; factor = [-] (number | '(' expr ')').
-- Floats are single precision on this build (see API.md), so results are shown with limited digits.

local W, H = 0, 0
local history = {}

local function evaluate(src)
  local pos = 1
  local function skip() pos = src:find("[^%s]", pos) or (#src + 1) end
  local expr
  local function factor()
    skip()
    local c = src:sub(pos, pos)
    if c == "-" then pos = pos + 1; return -factor() end
    if c == "(" then
      pos = pos + 1
      local v = expr()
      skip()
      if src:sub(pos, pos) ~= ")" then error("missing )") end
      pos = pos + 1
      return v
    end
    local num = src:match("^%d+%.?%d*", pos) or src:match("^%.%d+", pos)
    if not num then error("expected a number at " .. pos) end
    pos = pos + #num
    return tonumber(num)
  end
  local function term()
    local v = factor()
    while true do
      skip()
      local op = src:sub(pos, pos)
      if op ~= "*" and op ~= "/" then return v end
      pos = pos + 1
      local r = factor()
      if op == "*" then v = v * r
      else
        if r == 0 then error("divide by zero") end
        v = v / r
      end
    end
  end
  expr = function()
    local v = term()
    while true do
      skip()
      local op = src:sub(pos, pos)
      if op ~= "+" and op ~= "-" then return v end
      pos = pos + 1
      local r = term()
      if op == "+" then v = v + r else v = v - r end
    end
  end
  local v = expr()
  skip()
  if pos <= #src then error("unexpected text at " .. pos) end
  return v
end

local function fmt(v)
  if math.type(v) == "integer" or v == math.floor(v) and math.abs(v) < 2^31 then
    return string.format("%d", math.tointeger(v) or v)
  end
  return string.format("%.6g", v)
end

local function draw(expr, result, err)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Calculator", "ui12", "bw")
  local y = 60
  for i = math.max(1, #history - 4), #history do
    gfx.text(14, y, history[i], "small"); y = y + 22
  end
  gfx.text(14, 300, expr or "", "ui12")
  if err then gfx.text(14, 340, "error: " .. err, "ui12")
  elseif result then gfx.text(14, 340, "= " .. result, "sans18") end
  gfx.text(14, H - 34, "Confirm = type expression, Back = exit", "small")
  gfx.present()
end

local function main()
  W, H = gfx.size()
  local last_expr, last_result, last_err = nil, nil, nil
  draw()
  while true do
    local e = input.wait()
    if e == "back" then break end
    if e == "confirm" then
      local src = input.text("Expression", "", 80)
      if src and src ~= "" then
        last_expr = src
        local ok, v = pcall(evaluate, src)
        if ok then last_result, last_err = fmt(v), nil
        else last_result, last_err = nil, tostring(v):gsub("^.-:%d+: ", "") end
        history[#history + 1] = src .. (last_result and (" = " .. last_result) or "")
      end
      draw(last_expr, last_result, last_err)
    end
  end
end

local ok, err = pcall(main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
