# AO3 Library (Lua) — plan

Port of the useful core of [AvesO3](https://github.com/SiliconAves/AvesO3)'s "AO3 library" as an SD-card Lua app, plus the
runtime pieces it needs. Written after surveying AvesO3 and testing AO3 from the real X4 (see Findings).

## What AvesO3 actually does (2.6k lines: `Ao3Librarian`, `Ao3IndexActivity`, `AO3SyncActivity`, …)
1. **Local library browser**: scans a folder of AO3 EPUBs, scrapes each book's metadata into an index (title, author, fandom,
   up to 2 relationships, rating, warnings, word count, chapters, summary), shows AO3-style rows with summary + metadata.
2. **Sort** (title / author / word count / series / date added) and **filter** (fandom, relationship; automatic or by folder tree).
3. Reading status per fic (unread / reading / waiting / new chapter / finished), dashboard lists (marked for later, WIPs, recents).
4. **Network**: download new chapters from AO3 for fics you already have ("sync"), receive EPUBs pushed by a browser extension.

## Scope decision
* **v1 = the local library (1-3)**: index, browse, details, sort, filter, open in the reader. Most of the value, no network, and
  everything it needs is useful to other apps.
* **v2 = network (4)**: "check for updates / download new chapters". Needs the Phase 3 API (done) and a small Lua heap; see Risks.
* Out of scope: the browser extension, cover decoration/fandom logos, series continuous reading (later).

## Findings (measured, not assumed)
* **AO3 EPUB layout** (real file from AO3, work 5000): `content.opf` has `dc:title`, `dc:creator`, `dc:description` (HTML-escaped
  summary), `dc:subject` ×N — **unlabeled and mixed** (rating, warning, fandom, characters, tags), so the OPF alone cannot tell
  a fandom from a relationship. The first spine page (`*_split_000.xhtml`, "Preface") has clean `<dt>Label:</dt><dd>…</dd>` pairs
  (Rating, Archive Warning, Category, Fandom, Relationship, Characters, Additional Tags, Language) and a Stats `<dd>` with
  `Published: …  Words: 1,037  Chapters: 1/1`, plus the work URL (`/works/5000`, which doubles as the work id). Entries are tiny
  (OPF ~3 KB, preface ~3 KB).
* **AO3 is reachable from the X4**: Cloudflare accepted the firmware's wolfSSL client + `CrossPoint-ESP32-*` User-Agent.
  EPUB download: 8,460 bytes, valid ZIP, identical to curl's. **AO3 intermittently answers `525`** (Cloudflare↔origin TLS) —
  try 1 failed, try 2 succeeded, both on the X4 and with curl — so any network feature **must retry**. Work pages are big (37 KB,
  ~6 s) — stream to a file, never into RAM.
* **TLS server certificates are not verified** anywhere in CrossPoint (`setInsecure()`); fine for public AO3 metadata, but the app
  must not send credentials (no login in v1/v2).
* Firmware already provides: `ZipFile` (list/read entries, inflate), `activityManager.goToReader(path)`, `HttpDownloader`.

## Runtime pieces needed (generic, not AO3-specific)
| piece | design |
|---|---|
| **`sd:` scope** | Read-only access to the SD card outside the app's sandbox, for `fs.list/size/exists/read` and `zip.*`. Gated by `"permissions": ["library"]` in `manifest.json`. **Hidden components (`.crosspoint`, `.crosslua`, any `.x`) are refused and hidden from listings**, so an app can't read WiFi credentials, settings or other apps' data. Never writable. |
| **`zip` API** | `zip.list(path [, max])` → `{ {name=, size=}… }`; `zip.read(path, name [, max_bytes])` → string \| nil, err. Backed by firmware `ZipFile`. Refuses entries bigger than `max_bytes` (default 32 KB, hard cap 64 KB) and checks free RAM first (inflate needs ~45 KB transient). |
| **`app.open_book(path)`** | Parks the app and hands the path to `ActivityManager::goToReader` (replaces the app, like Home does). `sd:` paths only, so it needs `library`. |

## Data design (RAM is ~20-30 KB for a *network* app, 48 KB for a local one)
Same pattern as Study: **nothing per-book lives in Lua tables**.
* `books.bin`: fixed-size records (≈ 256 B: path-hash, title 56, author 32, fandom 40, rel1 40, rel2 40, words, chapters,
  status, rating, flags, added-seq). 1,000 books = 250 KB on the card, read in ranges, updated in place.
* `paths.bin`: variable-length epub paths with an offset in the record (paths are long; keep them out of the fixed record).
* `summary.bin`: summary text per book (≤ 400 B), offset+len in the record, read only for the detail view.
* `order_<key>.bin`: u16 per book giving the sorted order for each sort key, built at index time with an external merge sort
  (runs of ~64 books in RAM). Filters produce a bitmap/subset file. The UI pages through an order file 6-8 rows at a time.
* Re-index is incremental: a book is (re)scraped only when its path-hash or file size changed.

## Milestones (each ends with tests, then a run on the real X4)
1. **[DONE] Core: `sd:` scope + `zip` + `app.open_book`** — verified on the X4 with a real AO3 EPUB (list 11 entries, read OPF + preface, hidden/read-only refused, book opened in the reader, ~10 KB RAM); host tests (permission, hidden paths, limits, memory safety under ASAN) and an
   on-device check against a real AO3 EPUB (list + read OPF + preface).
2. **Metadata scraper in Lua** (`ao3.lua`): OPF + preface → record; unit-tested on the real AO3 EPUB text plus edge cases
   (missing stats, 2+ relationships, HTML entities, Calibre/FanFicFare variants from AvesO3's test files).
3. **Index store**: scan folder, incremental update, order files; test with 1,000 synthetic books under a tight memory budget.
4. **Browser UI**: list rows with metadata, detail view with summary, open in reader, sort + fandom/relationship filter.
5. **Status tracking + dashboard** (unread/reading/finished from the reader's progress where available).
6. **Network (v2)**: update check + download new chapters, retry on 5xx, Back cancels, tiny heap.

## Risks / open questions
* **Heap**: a local app can use ~48 KB; the network part needs ≥ 96 KB free at start (WiFi 56 + TLS 40). Plan: split into two
  apps (library browser, and "AO3 updater" that reads the same index) so the browser never pays the radio's price.
* **Reader progress / status** lives in the firmware's per-book cache (`.crosspoint`), which `sd:` deliberately cannot read;
  v1 keeps its own status in the index. A small, narrow `books.progress(path)` API may be added later.
* **Index build time** on-device: ~100-300 ms per book is the guess (zip open + 2 inflates + parse); measure at M2/M3.
* **Filter/sort memory**: external merge sort in Lua is the riskiest piece of M3; fall back to "sort within filtered page" if it
  is too slow.
