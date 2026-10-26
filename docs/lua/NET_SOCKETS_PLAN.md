# Raw network sockets for Lua — survey and proposed design (NOT implemented yet)

Goal (Angel): give Lua apps TCP/UDP/DNS/mDNS **by calling what CrossPoint already links**, with minimum RAM and no duplicated
code. This file is the survey result; nothing here is built. Decide the API (section 3) before any code.

## 1. What already exists (measured by reading the trees, not guessed)

| source | what it uses | verdict |
|---|---|---|
| CrossPoint `HttpDownloader` / `OpdsTransport` | `esp_http_client` (CA bundle, streaming) | already behind `http.request`; keep for HTTP(S) |
| SDK `SecureNet::SecureClient` (`freeink-sdk/libs/network/SecureNet`) | an Arduino `Client` over mbedtls with `setCACert`, `setInsecure`, abort callback, `tls13Available()` | **reuse for TLS sockets**: same CA bundle, same TLS stack, no second mbedtls config |
| Arduino `NetworkClient` / `WiFiClient`, `WiFiServer`, `WiFiUDP` | lwIP sockets, already linked (web server, Calibre, OPDS) | **reuse for plain TCP/UDP/listen**; no new library |
| `WiFi.hostByName`, `WiFi.localIP/subnetMask/gatewayIP/dnsIP` | Arduino WiFi | DNS + local info, zero extra code |
| `ESPmDNS` (`MDNS.queryService`) | linked for `crosspoint.local` by `CrossPointWebServerActivity` | mDNS browse |
| **Grimoire** `src/lua_api/api_net.cpp` (160 lines) | `WiFiServer` + `WiFiClient`; 2 servers, 4 clients, handles are ints, `accept`/`read`/`available` non-blocking, 512-byte chunks | the precedent: its API is the compatibility target (the Grimoire shim's `net.*` and `wifi_server` spell fail today for lack of this) |
| **biscuit** network apps | `PingActivity` = TCP connect timing (no ICMP); `HostScannerActivity` = `connect` with `setTimeout` over `localIP`/`subnetMask`; `DnsLookupActivity` = `hostByName`; `MdnsBrowserActivity` = `MDNS.queryService`; `HttpClientActivity` = `HTTPClient` | the real use cases: connect-with-timeout, DNS, local network info, mDNS, HTTP (done) |
| **Ruby** `WifiSniffer` | `esp_wifi_set_promiscuous` | a radio feature, not a socket: stays behind the planned radio permission, out of scope here |
| crossplay / AvesO3 | only the stock web server + `esp_http_client` | nothing new |

No reference firmware implements ICMP or raw sockets; "ping" everywhere is a TCP connect. We will not add raw sockets.

## 2. RAM and duplication rules for the design
- Plain TCP/UDP/listen: Arduino classes over lwIP only. No custom buffers; reads go straight into one `luaL_Buffer` (one copy).
- TLS: `SecureClient` only (shares the CA bundle and the one mbedtls config with HTTPS). Known cost: WiFi ~56 KB, TLS needs
  40 KB free + a 20 KB contiguous block: the existing preflight (`NET_MIN_FREE_BYTES`) applies, and each new connection class
  gets a MEASURED figure (same method as `epub.meta`: min-free watermark before/after on the X4), never a guess.
- Fixed small tables of handles (Grimoire parity: 4 clients, 2 servers, 1-2 UDP sockets), freed when the app ends. Closing is
  automatic in `~Backend`, like the buzzer/LEDs.
- Everything is polled from the Activity loop or by the script; no worker task (a task costs ~10 KB, per the HTTP design notes).

## 3. Proposed Lua API (needs the manifest `"permissions": ["network"]`, like `http`/`wifi`)
```
net.info()                           -> { ip, mask, gateway, dns } | nil, err          (WiFi must be up)
net.resolve(host [, timeout_ms])     -> ip string | nil, err                           WiFi.hostByName
net.connect(host, port [, opts])     -> handle | nil, err      opts = { timeout_ms = 5000, tls = false, insecure = false }
                                        blocking with Back-to-cancel (same pump as http); TLS -> SecureClient
net.read(h [, max = 512])            -> string (maybe "") | nil, "closed"              never blocks; max <= 4096
net.write(h, data)                   -> bytes written | nil, err
net.available(h) / net.connected(h)  -> number / boolean
net.close(h)
net.listen(port) / net.accept(srv) / net.close(srv)   -> NEEDS the extra permission "listen" (exposes the device to the LAN)
net.udp(port?) , sock:send(host, port, data) , sock:recv([max]) -> data, ip, port | nil
net.mdns_query(service, proto [, timeout_ms]) -> { {host, ip, port, name}, ... }       ESPmDNS
```
Grimoire shim mapping: `listen/accept/closeServer/connect/available/isConnected/read/write/close` map 1:1 onto the above, so
the `wifi_server` spell becomes runnable (today it reports "not supported").

## 4. Decisions needed from Angel before coding
1. Is `listen` (device as a server) in scope for the first cut, behind a separate `"listen"` permission + approval screen
   (grants-style), or do we ship client-only first (connect/resolve/local/mdns/udp)? Recommendation: client-only first, since
   it covers every biscuit tool and has no LAN-exposure question.
2. TLS sockets in the first cut (`SecureClient`) or plain TCP first? Recommendation: plain first, TLS second (its RAM needs a
   separate measurement and it blocks the whole heap budget).
3. `net.*` as one namespace (proposed) next to `http.*` and `wifi.*`.

## 5. Test plan (same rules as every feature)
Mock backend with scripted sockets (partial reads, closes mid-read, timeouts, refused connects); argument-validation tests
before the backend is touched; handle-table exhaustion and reuse after close; mutants on every limit and on the permission
gate; on the X4: connect to a throwaway echo server on the LAN (this Linux box), measure RAM per connection and the leak over
200 open/close cycles, then port a biscuit tool (host scanner or DNS lookup) as a Lua app as the end-to-end proof.

## 5. Built (client-side TCP) and measured on the X4 (2026-10-26)

Shipped as `net.info / resolve / connect / read / write / available / connected / close` (see API.md "net"). Decisions taken with the defaults proposed in section 4: client-only, plain TCP first, one `net.*` namespace.

Differences from the proposal above:
- `net.local()` became **`net.info()`**: `local` is a Lua keyword, so `net.local()` does not parse.
- `net.resolve(host)` has no timeout argument: `WiFi.hostByName` in this Arduino core takes none (it uses the system DNS timeout).
- `{tls=true}` / `{insecure=true}` are accepted as option names but **refused with a clear message**: TLS sockets are the next step.

What the device told us (WiFi up, memprobe_lua / socktest_lua against `echo_server.py` on the LAN):
- The 40 KB guard floor is wrong once the radio is up: free heap is ~44 KB, so Lua could allocate ~1.3 KB. Any floor above ~16 KB made reads fail mid-stream (TCP buffering alone dips free heap to ~16.7 KB in a 64 KB burst). Floors of 16, 12 and 8 KB all completed with a matching SHA-256. **Shipped: 12 KB after a successful `wifi.connect()`** (one-way; WiFi apps restart the device on exit).
- Copying data out of the stack relieves memory pressure, so `net.read` relaxes the floor to 6 KB for that one allocation (restored inside a protected call, even on out-of-memory).
- Per-socket heap: idle 3.4-3.8 KB; after an echo 6.8 KB; receive window full ~16 KB. One flooded socket is survivable, two or more flooded at once ran out of memory (the system survived; Lua got `not enough memory`).
- `NetworkClient::connected()` does not notice a graceful FIN until a later read; the backend uses `recv(MSG_PEEK)` instead.
- Closed connections sit in TIME_WAIT: ~4.6 KB for the first ~40 cycles, then a plateau (+212 bytes over the next 120).
- Timings: connect to a LAN host 16-26 ms; DNS 30-52 ms; refused port 18-19 ms; a blackhole host with `timeout_ms=1500` failed after 1504-1505 ms.

Still open: UDP, `net.mdns_query`, TLS sockets (`SecureClient`, needs ~60 KB: that does not fit next to a socket-using Lua heap on the X4 without measurement), `listen/accept`, and a way for Back to interrupt a blocking `connect`.

## 6. WiFi driver buffer tuning: measured, no gain (dropped)

Idea: shrink the radio's ~58 KB by initialising the driver with fewer buffers (esp_wifi_init intercepted with a linker wrap, five candidate configs, one boot per candidate so each started from the same 115,044 B free). Result on the X4, radio cost and a 64 KB transfer:

| config | cost | transfer |
|---|---|---|
| Arduino default (4 static + 32 dynamic RX, 32 TX, AMPDU on) | 58,024 B | 277 KB/s |
| dynamic RX 16 / TX 16 | 58,024 B | 250 KB/s |
| dynamic RX 8 / TX 8 | 58,028 B | 273 KB/s |
| + AMPDU off | 57,872 B | 267 KB/s |
| + mgmt buffers | 57,932 B | 251 KB/s |

The best saving is 152 bytes: the dynamic counts are allocated on demand and the fixed cost is driver internals, task stacks and lwIP, which these knobs do not touch. Anything further would need a rebuilt SDK (the firmware already has `custom_sdkconfig`), which is firmware-wide and out of scope for the Lua runtime. The experiment code was removed.

Side finding (a real bug, fixed): the exit-time defrag reboot checked `WiFi.getMode() != WIFI_MODE_NULL`, but `wifi.off()` sets exactly that mode, so an app that turned WiFi off before exiting skipped the reboot although the radio had already fragmented the heap (~20 KB did not come back; an EPUB test right after a WiFi test failed 12 bytes short of a 32 KB block). The activity now remembers that the radio was used this session (it survives `app.restart`).
