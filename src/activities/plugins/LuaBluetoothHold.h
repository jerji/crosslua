#pragma once

// Lua apps and the Bluetooth page turner share ONE NimBLE stack (the SDK's BleKeyboardHost is a singleton). The page turner's
// per-loop tick() ends any running stack whenever it does not want the radio, which would kill a Lua app's Bluetooth session a
// moment after it starts. While a Lua session owns the radio, main.cpp skips that tick.
namespace luabt {
bool held();  // true from a successful ble.start() until the stack is down again
}
