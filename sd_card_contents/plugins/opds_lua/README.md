# OPDS Browser

Browses OPDS catalogues (Atom feeds) over Wi-Fi and saves EPUBs to `Books/`.

Default catalogues: Project Gutenberg (popular, newest, full catalogue).

## Add your own catalogues

Create `feeds.txt` in this app's data folder (`/.crosslua/data/opds_lua/feeds.txt` on the card),
one catalogue per line:

```
# comments start with #
My Calibre|http://calibre.example:8080/opds
Gutenberg popular|https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads
```

If the file exists, it replaces the defaults. Plain-HTTP LAN servers work with the
`network` permission. HTTPS is encrypted but the server certificate is not verified.

## Notes

- Only EPUB acquisition links are offered; other formats are hidden.
- Feeds are cached on the card, so Back does not need the radio.
- Inline base64 thumbnails are dropped while the feed is saved, so big catalogue pages fit.
