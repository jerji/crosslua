-- Luacheck config for CrossLua apps: the firmware injects a fixed set of globals (the Lua API
-- namespaces) at runtime, so those are "known globals" here. Anything else that is undefined (and not
-- defined as a non-standard global in the same file) is a real bug — a typo'd variable.
std = "min"

globals = {
  -- core
  "gfx", "input", "app", "system", "fs", "json", "time",
  -- network / codec / data
  "zip", "epub", "crypto", "xml", "net", "wifi", "http", "ble", "espnow",
  -- hardware
  "device", "audio", "mic", "led",
  -- runtime builtins
  "print", "require", "collectgarbage",
  -- Lua stdlibs + 5.2+ environment (grimoire shim sandbox touches _ENV)
  "string", "table", "math", "coroutine", "utf8", "_ENV",
}

-- Ignore the cosmetic warnings: unused locals/args/loop vars, assigned-but-unread values, line length.
-- The signal we keep is undefined-variable (W113), non-standard globals (W111), redefined (W411) and shadowing.
ignore = {
  "211", "212", "213",  -- unused local / argument / loop variable
  "311", "312", "313", "314",  -- value assigned to a variable is never used
  "631",  -- line too long
}

max_line_length = false