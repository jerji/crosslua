-- Generation worker. main.lua restarts into THIS script to build a puzzle (a fresh VM: the game screens, the
-- lesson text and the game state are not in memory while it runs). It writes the finished puzzle to
-- data:sudoku.job (seed, level, then the 81 given digits and the 81 solution digits on one line each) and restarts
-- back into main.lua, which loads it. The device's own advice: generate, save, reload with new state.
-- Cancel: Back writes data:sudoku.job = "" and restarts; main.lua sees the empty file and returns to the menu.

local sudoku = require("sudoku")
local job = fs.read("data:sudoku.job") or ""
local level = tonumber(job:match("^%d+")) or 0

-- the progress frame: the same screen main.lua draws, so the handover looks continuous
gfx.clear()
gfx.text(14, 10, "SUDOKU", "ui12", "bw")
gfx.text(14, 300, "MAKING ONE...", "sans18", "c")
gfx.text(14, 360, "Back cancels", "small")
gfx.present()

local out = {}
local work = sudoku.newWork()
local rng = sudoku.newRng((system.millis() & 0xFFFFFFFF) | 1)
local done = false
while not done do
  if sudoku.generate(out, level, work, rng, 24) then done = true end
  if input.poll() == "back" then break end
  app.sleep(40)
end

local payload
if done then
  payload = string.format("%d\n%s\n%s\n", level, table.concat(out.given, ","), table.concat(out.solution, ","))
else
  payload = ""
end
fs.write("data:sudoku.job", payload)
app.restart("main.lua")
