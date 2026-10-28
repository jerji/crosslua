-- Wordle. Word data is NOT shipped with this app (its answers and guess list are third-party data, and the crossplay
-- doc says to source them from the user's card). Put these files in the Wordle folder on the card:
--   Wordle/answers.txt   one line per day: YYYY-MM-DD WORD     (today's answer is looked up by the device date)
--   Wordle/valid.txt     one accepted guess per line            (if absent, any five letters are accepted, shown as a note)
-- With no answers.txt entry for today, the game runs as PRACTICE with a random answer from answers.txt.
-- Scoring: G = right letter, right place (filled tile); Y = in the word elsewhere (dotted tile); blank = not in the word.
-- Controls: up/down/left/right move the letter cursor; confirm presses the letter; the DEL and ENTER keys sit on the
-- bottom row. Back exits. Today's guesses save to data:wordle.sav and resume on the next start.

local W, H = 0, 0
local LETTERS = "QWERTYUIOPASDFGHJKLZXCVBNM"
local ROWS = { "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM" }
local MAXG = 6
local SAVE = "data:wordle.sav"

local function today()
  local d = time and time.date and time.date()
  if not d then return nil end
  return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
end

local function load_answers()
  local text = fs.read("sd:Wordle/answers.txt") or ""
  local byday, all = {}, {}
  for date, word in text:gmatch("(%d%d%d%d%-%d%d%-%d%d)%s+(%a+)") do
    word = word:upper()
    if #word == 5 then byday[date] = word; all[#all + 1] = word end
  end
  return byday, all
end

local function load_valid()
  local text = fs.read("sd:Wordle/valid.txt")
  if not text then return nil end
  local set = {}
  for w in text:gmatch("%a+") do if #w == 5 then set[w:upper()] = true end end
  return set
end

local function score(guess, answer)
  -- two passes so repeated letters are counted correctly
  local res, used = {}, {}
  for i = 1, 5 do
    if guess:sub(i, i) == answer:sub(i, i) then res[i] = "G"; used[i] = true end
  end
  for i = 1, 5 do
    if not res[i] then
      local g = guess:sub(i, i)
      res[i] = "-"
      for j = 1, 5 do
        if not used[j] and answer:sub(j, j) == g then res[i] = "Y"; used[j] = true; break end
      end
    end
  end
  return res
end

local function save(state)
  local lines = { state.date or "practice", state.answer }
  for _, g in ipairs(state.guesses) do lines[#lines + 1] = g end
  fs.write(SAVE, table.concat(lines, "\n") .. "\n")
end

local function load_save(date)
  local s = fs.read(SAVE)
  if not s then return nil end
  local lines = {}
  for l in s:gmatch("[^\n]+") do lines[#lines + 1] = l end
  if lines[1] ~= (date or "practice") then return nil end
  local st = { date = date, answer = lines[2], guesses = {} }
  for i = 3, #lines do st.guesses[#st.guesses + 1] = lines[i] end
  return st
end

local function draw(st, cur, typed, valid_note, msg)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Wordle", "ui12", "bw")
  local tile, gap = 60, 10
  local ox = (W - (5 * tile + 4 * gap)) // 2
  for row = 1, MAXG do
    for col = 1, 5 do
      local x = ox + (col - 1) * (tile + gap)
      local y = 60 + (row - 1) * (tile + gap)
      gfx.rect(x, y, tile, tile, false)
      local g = st.guesses[row]
      if g then
        local res = score(g, st.answer)
        local ch = g:sub(col, col)
        if res[col] == "G" then gfx.rect(x + 2, y + 2, tile - 4, tile - 4, true); gfx.text(x + tile // 2 - 5, y + tile // 2 - 9, ch, "ui12", "w")
        elseif res[col] == "Y" then gfx.rect(x + 14, y + 14, tile - 28, tile - 28, false); gfx.text(x + tile // 2 - 5, y + tile // 2 - 9, ch, "ui12")
        else gfx.text(x + tile // 2 - 5, y + tile // 2 - 9, ch, "ui12") end
      elseif row == #st.guesses + 1 and typed[col] then
        gfx.text(x + tile // 2 - 5, y + tile // 2 - 9, typed[col], "ui12")
      end
    end
  end
  -- keyboard
  local ky = 60 + MAXG * (tile + gap) + 20
  local kw = 36
  for ri, row in ipairs(ROWS) do
    local rx = (W - #row * kw) // 2
    for ci = 1, #row do
      local ch = row:sub(ci, ci)
      local x, y = rx + (ci - 1) * kw, ky + (ri - 1) * kw
      if cur.kind == "letter" and cur.r == ri and cur.c == ci then gfx.rect(x, y, kw - 2, kw - 2, true); gfx.text(x + 10, y + 8, ch, "ui12", "w")
      else gfx.text(x + 10, y + 8, ch, "ui12") end
    end
  end
  local by = ky + 3 * kw
  local del_sel = cur.kind == "del"
  local ent_sel = cur.kind == "enter"
  gfx.text(W // 2 - 120, by, del_sel and "[DEL]" or " DEL ", "ui12", del_sel and "b" or nil)
  gfx.text(W // 2 + 20, by, ent_sel and "[ENTER]" or " ENTER ", "ui12", ent_sel and "b" or nil)
  gfx.text(14, H - 60, msg or "", "small")
  gfx.text(14, H - 34, (valid_note or "") .. "Confirm presses, Back exits", "small")
  gfx.present()
end

local ok, err = pcall(function()
  W, H = gfx.size()
  local date = today()
  local byday, all = load_answers()
  local answer = date and byday[date]
  local practice = answer == nil
  if practice then
    if #all == 0 then
      gfx.clear(); gfx.text(14, 80, "No answers found.", "ui12")
      gfx.text(14, 110, "Put answers.txt in the Wordle folder on the card.", "small")
      gfx.present(); while input.wait() ~= "back" do end
      return
    end
    local ok2, b = pcall(crypto.random, 1)
    local idx = (ok2 and type(b) == "string" and #b > 0) and (b:byte() % #all + 1) or math.random(#all)
    answer = all[idx]
  end
  local st = load_save(practice and nil or date) or { date = practice and nil or date, answer = answer, guesses = {} }
  if st.answer ~= answer then st = { date = practice and nil or date, answer = answer, guesses = {} } end
  local valid = load_valid()
  local valid_note = valid and "" or "No valid.txt: any 5 letters accepted. "
  local cur = { kind = "letter", r = 1, c = 1 }
  local typed, msg = {}, ""
  local done = false
  local function finished() return st.guesses[#st.guesses] == st.answer or #st.guesses >= MAXG end
  if finished() then done = true; msg = "Answer: " .. st.answer end
  draw(st, cur, typed, valid_note, done and msg or (practice and "Practice game" or ""))
  while true do
    local e = input.wait()
    if e == "back" then break end
    if done then
      -- read-only once finished
      draw(st, cur, typed, valid_note, msg)
    elseif e == "up" then
      if cur.kind == "letter" then
        if cur.r > 1 then cur.r = cur.r - 1 end
      elseif cur.kind == "del" then cur = { kind = "letter", r = 3, c = 1 }
      elseif cur.kind == "enter" then cur = { kind = "letter", r = 3, c = 1 } end
      msg = ""
    elseif e == "down" then
      if cur.kind == "letter" then
        if cur.r < 3 then cur.r = cur.r + 1 else cur = { kind = "del" } end
      elseif cur.kind == "enter" then cur = { kind = "letter", r = 1, c = 1 }
      elseif cur.kind == "del" then cur = { kind = "letter", r = 1, c = 1 } end
      msg = ""
    elseif e == "left" then
      if cur.kind == "letter" then cur.c = cur.c > 1 and cur.c - 1 or #ROWS[cur.r] end
      if cur.kind == "enter" then cur = { kind = "del" } elseif cur.kind == "del" then cur = { kind = "letter", r = 1, c = 1 } end
      msg = ""
    elseif e == "right" then
      if cur.kind == "letter" then cur.c = cur.c < #ROWS[cur.r] and cur.c + 1 or 1 end
      if cur.kind == "del" then cur = { kind = "enter" } elseif cur.kind == "enter" then cur = { kind = "letter", r = 1, c = 1 } end
      msg = ""
    elseif e == "confirm" then
      if cur.kind == "letter" then
        local ch = ROWS[cur.r]:sub(cur.c, cur.c)
        local n = 0
        for i = 1, 5 do if typed[i] then n = n + 1 end end
        if n < 5 then
          for i = 1, 5 do if not typed[i] then typed[i] = ch; break end end
        end
        msg = ""
      elseif cur.kind == "del" then
        local last = 0
        for i = 1, 5 do if typed[i] then last = i end end
        if last > 0 then typed[last] = nil end
        msg = ""
      elseif cur.kind == "enter" then
        local word = table.concat({ typed[1] or "", typed[2] or "", typed[3] or "", typed[4] or "", typed[5] or "" })
        if #word < 5 then msg = "Five letters first."
        elseif valid and not valid[word] and word ~= st.answer then msg = word .. " is not in the word list."
        else
          st.guesses[#st.guesses + 1] = word
          typed = {}
          save(st)
          if finished() then
            done = true
            msg = (st.guesses[#st.guesses] == st.answer) and ("Solved in " .. #st.guesses .. "!") or ("Answer: " .. st.answer)
          else msg = "" end
        end
      end
    end
    draw(st, cur, typed, valid_note, msg)
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
