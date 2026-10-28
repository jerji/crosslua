-- Tiny persistence helper: JSON files in this app's data folder (/.crosslua/data/<app>/).
local store = {}

function store.load(name, default)
  local text = fs.read("data:" .. name)
  if text then
    local t = json.decode(text)
    if type(t) == "table" then return t end
  end
  return default
end

function store.save(name, t)
  local text, err = json.encode(t)
  if not text then return nil, err end
  return fs.write("data:" .. name, text)   -- atomic: old file survives a power cut
end

return store
