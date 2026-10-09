# Voyage: curated KOReader changes

Running list of changes for the curated build. `[~]` = installed, awaiting test on the device. Implemented as user patches in `koreader/patches/` or as global defaults in `settings.reader.lua`.

## Planned

### Reading
- [x] **Embedded fonts off by default.** (Set by user 2026-10-09, captured in `src/defaults/reading.lua`.) Books' bundled fonts never override the chosen font. (Aa tab: Embedded Fonts → off; global default `copt_embedded_fonts = 0`.)
- [~] **Ignore publisher font families by default.** (Installed 2026-10-09, awaiting test; menu hiding still to do.) Style tweak `font_family_all_inherit` on globally, so every paragraph uses the chosen font. Hide the option from menus once it's a default.
- [x] **Render mode: Web by default.** (Set by user 2026-10-09; hiding the global setting still to do.) Closest to the stock Kindle look (publisher layout honored). Hide the global setting; keep a per-book switch to **Book** for EPUBs that come out cramped or with narrow columns.

- [~] **Kindle-style footer.** (Installed 2026-10-09 via `src/patches/2-kindle-footer.lua` + `src/defaults/footer.lua`, awaiting test.) "Page 9" on the left, "45%" on the right, nothing else. Amazon Ember (the Kindle UI font, system font) as the footer font, no progress bar, no icons/separators. Items: current page + dynamic filler + percentage. Small patch to render the page item as `Page 9` (stock shows `9 / 400`). Ember confirmed loading via debug log. User-tuned: bold, size 14, height 24. Side margins follow the book's text margins (patch, awaiting test).

### Quick panel
- [~] **Kindle-style swipe-down panel.** (Installed 2026-10-09 as `src/plugins/voyagepanel.koplugin`; look and Airplane toggle confirmed by user 2026-10-09. Device name: Kumba (set 2026-10-09; the Kindle's registered name is "Skyler's 2nd Kindle" in reginfo, not used).) Swipe down from the top edge; tap at the top still opens KOReader's menus. Modeled on the Kindle's quick actions, minus warmth and colour style:
  - Header: device name (bold), time • date, battery %.
  - Round buttons: Airplane (flips the wireless switch directly like the Kindle: no connect attempt, network list or popups; wifid rejoins saved networks itself), Dark mode (in Bluetooth's slot, since the Voyage has none), Sync (KOReader progress sync), All Settings (full KOReader menu).
  - Brightness 0–24 slider with −/+ and value over the knob; tap or drag.
  - Auto Brightness checkbox, driven by the Voyage's light sensor (polls every 3 s while awake). Moving the slider turns Auto off.
  - Close: chevron, swipe up, tap below the panel, or a page-turn button.

### Reading toolbar
- [x] **Kindle-style toolbar on top tap.** (Installed 2026-10-09 as `voyagepanel.koplugin/toolbar.lua`; confirmed working by user.) Laid out from a screenshot of the Voyage's own reader. Replaces KOReader's top/bottom menus when tapping the top while reading.
  - Status line: book title; airplane (when wireless is off), battery %, drawn battery, time.
  - Row 1: home (library), back (previous location, else library), settings (KOReader's full menu); Search (in-book search); ⋮ (Notes, Book description, Reading statistics, Rotate). Goodreads/Store slots dropped.
  - Row 2: Aa, Go To (Contents, Notes, Page…, Beginning), bookmark ribbon (filled when the page is bookmarked; tap toggles).
  - Bottom: chapter, "Page X of Y | N mins left in chapter | P%", Book map / Page browser buttons.
  - Closes on tapping the page, swiping, or a page-turn button.
- [x] **Kindle-style Aa panel.** (Installed 2026-10-09 as `voyagepanel.koplugin/aapanel.lua`; confirmed by user.) Bottom sheet with Themes / Font / Layout / More tabs, laid out from screenshots of the Voyage's own (`design/reference/voyage-stock-aa-*.png`). Changes apply to the open book and become the default for all books.
  - Themes: Compact / Standard / Large presets, saved custom themes, Custom when unsaved; Save Current Settings; Manage Themes (delete).
  - Font: Font Family list (Kindle and sideloaded fonts, each shown in its own face), Bold 1–5, Size 1–14 (KOReader 22 = Kindle 4).
  - Layout: Orientation, Margins (3), Alignment (justified / left), Spacing (3).
  - More: Reading Progress (Page in book / Time left in chapter / Time left in book / None, drives the footer), Show Clock While Reading (top center), Highlight Menu. Amazon-only items left out.

### Library
- [~] **Kindle 2-style library as home.** (Installed 2026-10-09 in `voyagepanel.koplugin/library.lua`, awaiting test. Skips Kindle clutter: My Clippings, crash reports, Amazon dictionaries. KFX store books are not listed: KOReader cannot open them.) Replaces KOReader's file browser whenever it would show.
  - Flat list of every book under `documents/` (Author folders ignored). Titles/authors from Calibre's `metadata.calibre`, falling back to the `Title - Author` file name.
  - Header bar: device name; Wi-Fi/OFF and a drawn battery on the right. Subheader: "Showing All N Items" and the sort label.
  - Rows: title in Caecilia (original Kindle serif) with length/progress dots, author right, "read" in the margin for finished books. Tapped row flashes inverted, then opens.
  - Sort (tap the label to cycle): Most Recent First (last opened or added), Title, Author, Newest Added. Remembered.
  - "Page N of M" footer; page buttons and left/right swipes turn pages. Tap the header for KOReader's menu, swipe down from the top for the quick panel.

### Loading & messages
- [~] **Kindle-style loading.** (Installed 2026-10-09, awaiting test.) Books opened from the library open seamlessly: no "Opening file" box, the tapped row stays inverted until the page appears. All other message boxes use Amazon Ember, no info icon, short text centered (`src/patches/2-kindle-messages.lua`).

### Device
- [ ] **"Connect to computer" menu item.** Exits KOReader to the Kindle UI so USB drive mode works.

## Done
- [x] Library reorganized 2026-10-09: author folders removed (backup in `backup/author-folders-2026-10-09`), 197 Calibre EPUBs copied flat to `documents/` as `Title - Author.epub` (full titles from Calibre's metadata.opf). KFX store books left untouched.
- [x] Reading defaults captured: Bookerly 22, line spacing 115%, side margins 30, top 30, bottom 12, word spacing 95/75, best kerning (`src/defaults/reading.lua`)
- [x] KOReader v2026.07.1 (kindlepw2 build), 2026-10-09
- [x] Start KOReader at boot (KUAL > Voyage), once per boot, `NO_KOREADER` escape hatch
- [x] SSH key-only login (`ssh voyage`, needs the Voyage's IP)
