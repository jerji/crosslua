# KOReader Sync

Pushes the progress the reader already saved for each book (`epub.progress`) to a
KOReader sync server (kosync), and reads the server's copy back for display.

Setup (Right): server URL, username, password. Test login runs on save.

- **Confirm** — push the selected book's local progress.
- **Left** — fetch the server's position for that book (shown, not applied).
- **Back** — exit.

Notes:
- The password is stored encrypted, bound to this device and this app
  (`crypto.device_key` + AES-GCM). A copied card cannot decrypt it.
- `http://` sends the login in clear on the network. Use it only on a LAN you trust.
- `https://` needs `ca.pem` (your server's CA, PEM) placed in this app's folder.
  Without it the app refuses to send credentials.
- Position is sent as a percentage with an empty `progress` string, so another
  reader jumps by percent, not to the exact spot.
- Bookmarks and highlights are not synced (no binding for them yet).
- Applying a remote position to this device needs `epub.set_progress`, which
  does not exist yet.
