# Primer: changes

Running list of changes for Primer (formerly KO-Plus), the Kindle-style system built on KOReader. `[~]` = installed, awaiting test on the device. Implemented as user patches in `koreader/patches/` or as global defaults in `settings.reader.lua`.

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
- [x] **Toolbar ⋮ and Aa refinements** (2026-10-10). Confirmed by user.
  - ⋮ opens a Kindle-style dropdown under the button (Notebook, Reading Statistics) instead of a popup; Book description and Rotate removed. Any other tap closes it.
  - Reading Statistics: a card with the book, a progress bar ("Page X of Y", "N% read") and a two-column grid: time left in book, time spent reading, days reading, average per day, pages read, highlights · notes, started, estimated finish. Times need KOReader's statistics plugin (dash otherwise).
  - Aa Size and Bold show the new step at once and apply 1 s after the last tap, so stepping several sizes costs one re-layout (also applied on closing the panel).
  - Bigger size steps: 14, 16, 19, 22, 25, 29, 33, 38, 44, 51, 59, 68, 78, 90; Size 4 = KOReader 22, about 15% apart above it (was 16–58).
  - No re-layout icons in the top-left corner after a font or layout change (KOReader's partial-rerendering indicator); the fast chapter-first re-layout is kept.
  - Pinch / spread move one Aa size step (up to three for a long pinch) instead of by pinch distance, with a "Size N" note (the Aa step) instead of KOReader's raw size.

### Settings
- [x] **Kindle-style Settings** (`settings.lua`, modeled on `design/reference/kindle-settings-screenshot.png`). Opens from the quick panel's All Settings, the toolbar's settings and the library header; KOReader's full menu stays behind ⋮ (and Advanced > All KOReader settings). Confirmed by user.
  - Kumba (rename) · Wi-Fi (wireless toggle, networks) · Device options (battery, sleep after, start with last book/library, ask to connect to a computer, swap page-turn buttons, restart KOReader) · Screen and brightness (brightness panel, auto brightness, dark mode, full page refresh never/20/40, chapter refresh, sleep screen illustrations/cover/none) · Reading (Aa, reading progress, clock, highlight menu) · Home and Library (Kindle-style library, sort) · Advanced (KOReader menu, SSH server) · About.
  - Rows: icon, bold title, subtitle (current value for choices), ›, switches for toggles; choices open a pick-one list with a check mark. ‹ title, swipe right or Back go up a level; chevron or ✕ close.

- [~] **24-hour clock toggle** (Settings > Device options; subtitle shows the current time in the chosen format). All Primer clocks follow it. The toolbar's status line now has the time top-left with the title centred, like the other menus; the reading clock stays top-centre. Awaiting test.
- [~] About describes Primer as "A modern UI frontend for KOReader". Awaiting test.

### Dictionary
- [x] **Kindle-style dictionary.** (Installed 2026-10-10; confirmed by user.) Modeled on `design/reference/kindle-dictionary-photo.webp`.
  - Dictionary: English-English Wiktionary (462k entries, CC BY-SA, github.com/Vuizur/Wiktionary-Dictionaries, the source KOReader's catalog uses) in `koreader/data/dict/`. The Voyage's built-in Oxford dictionaries are DRM-protected Amazon files KOReader can't read.
  - Long-press a word: a card on the opposite half of the screen (Dictionary header, bold headword, italic part of speech, numbered senses in Bookerly, dictionary name ▸ at the bottom opens KOReader's full lookup). Swipe up/down for long entries (laid out a page at a time); swipe sideways between results when there are several.
  - Selection bar by the word: Highlight | Note | Copy | Search, plus ⋮ only when there are extras. Multi-word selections get the bar only. Tap elsewhere to dismiss.
  - ⋮ is a Kindle-style dropdown of what's left of KOReader's highlight menu after removing Select, Wikipedia, Translate, QR code, Dictionary, View HTML and the bar duplicates (Highlight, Copy, Note, Search): in practice Follow Link (on links) and Hyphenate. Confirmed by user.
  - Tapping an existing highlight shows the same bar: Delete | Note | Copy | Search. Confirmed by user. KOReader's Style, Color, Details and boundary-arrow buttons are gone (grayscale screen; the Kindle has none of them). Awaiting test.
  - **Kindle-style notes** (`notes.lua`, modeled on `design/reference/kindle-note-photo.webp`): a popup anchored to the highlight with a notch, "Note  ALL NOTES  ✕", the note, and COPY / DELETE / EDIT. Shown when tapping a highlight that has a note. EDIT, and Note on the bar (new selection or existing highlight), switch it to a text field above the keyboard with CANCEL / SAVE; cancelling a brand-new note removes the highlight made for it. Saving mirrors KOReader's own note saving. The popup is `is_always_active` so taps reach it past the modal keyboard; page-turn buttons cancel/close. Confirmed by user.
  - **Kindle-style Notebook** (`notebook.lua`) replaces KOReader's "Bookmarks" list everywhere (ALL NOTES opens it on Notes; Go To's Notes tab; ⋮ > Notes). Entries in page order: "Note · Page 42", the passage in Bookerly, the note under it with a margin bar. Filters All / Highlights / Notes / Bookmarks; tap to go there (Back returns); long-press for Edit/Add Note or Delete. Confirmed by user.
  - Parser unit-tested on real entries (run, set, lead, café, extraordinary) with a Lua VM.

### Go To
- [x] **Kindle-style Go To with chapters.** (Installed 2026-10-09 as `voyagepanel.koplugin/goto.lua`; confirmed by user.) Opens from the toolbar's Go To and the page flip's contents icon. Chapters with page numbers (sub-chapters indented), current chapter bold with a margin bar, opens on the current chapter's page of the list; tap to jump (Back returns). "Page…" for a page number, Notes tab for highlights/bookmarks; swipe or page buttons for long contents.

### Page flip
- [x] **Kindle-style page flip on swipe up from the bottom** (replaces KOReader's settings bar swipe). (Installed 2026-10-09 as `voyagepanel.koplugin/pageflip.lua`; confirmed by user.) Laid out from a photo of a Kindle's page flip (`design/reference/kindle-pageflip-photo.webp`).
  - Status line with ⌄ chevron (closes), toolbar: ← Library, Aa, Contents, Page flip, Bookmark, Search, ⋮; book title.
  - Current page as a large thumbnail (KOReader's thumbnail renderer), neighbours peeking in from both sides. Tap a side page or swipe to move; tap the centre page to go there.
  - "Back to page N" when moved away; chapter title with previous/next chapter jumps; grid opens the Page browser; scrubber with "Page N" over the knob and a dot where you were.
  - Nothing changes in the book until you tap a page.

### Library
- [~] **Kindle 2-style library as home.** (Installed 2026-10-09 in `voyagepanel.koplugin/library.lua`, awaiting test. Skips Kindle clutter: My Clippings, crash reports, Amazon dictionaries. KFX store books are not listed: KOReader cannot open them.) Replaces KOReader's file browser whenever it would show.
  - Flat list of every book under `documents/` (Author folders ignored). Titles/authors from Calibre's `metadata.calibre`, falling back to the `Title - Author` file name.
  - Header bar: device name; Wi-Fi/OFF and a drawn battery on the right. Subheader: "Showing All N Items" and the sort label.
  - Rows: title in Caecilia (original Kindle serif) with length/progress dots, author right, "read" in the margin for finished books. Tapped row flashes inverted, then opens.
  - Sort (tap the label to cycle): Most Recent First (last opened or added), Title, Author, Newest Added. Remembered.
  - "Page N of M" footer; page buttons and left/right swipes turn pages. Tap the header for KOReader's menu, swipe down from the top for the quick panel.

### Loading & messages
- [x] **Kindle-style loading.** (Installed 2026-10-09; confirmed by user.) Books opened from the library open seamlessly: no "Opening file" box, the tapped row stays inverted until the page appears. All other message boxes use Amazon Ember, no info icon, short text centered, and KOReader's "Opening file" box is never shown, including at startup and after the USB relaunch (`src/patches/2-kindle-messages.lua`).

### Sleep screens
- [x] **Stock Kindle sleep screens.** (Installed 2026-10-09; confirmed by user.) The Voyage is not Special Offers, so KOReader draws them: `screensaver_type = "random_image"` from `/mnt/us/screensavers`, no "Sleeping" message. The plugin copies the 20 stock illustrations (`/usr/share/blanket/screensaver/bg_ss00–19.png`, skipping the Amazon Kids set) there on first start (`tools/stock-screensavers.sh`). Add your own images to that folder to mix them in.

### Screen refresh
- [~] **Kindle-style refresh.** (Installed 2026-10-09.) Flash-free REAGL page turns with no forced flash every N pages (`full_refresh_count = 0`, day and night), no black flashes on menus (`avoid_flashing_ui`), one full refresh at each chapter start (plugin `onPageUpdate`). Watch for ghosting in long chapters; fallback is a refresh every 20–30 pages.

### Remaining KOReader screens (2026-10-10, confirmed by user)
- [x] **Primer's font everywhere.** Patch `2-primer-ui.lua` swaps KOReader's interface fonts (menus, title bars, dialogs, notifications such as "Size 4", dictionary and book map windows, keyboard labels) to Amazon Ember (Inter off-Kindle); Noto stays as the glyph fallback. Square window corners; full-screen title bars left-aligned over a rule; rounded keyboard keys.
- [x] **In-book search.** Search (toolbar, page flip, selection bar) opens Primer's top search bar ("Search this book"); results are a full-screen list: "Results for “word”", count, then chapter · page over the passage with the match in bold, paged by swipe or buttons. Tapping a result marks it on the page with a bottom bar: ‹ Previous | 3 of 27 (Back to results) | Next ›; tap the page to keep reading there.
- [x] **Search bar stays one line** (2026-10-10): the field no longer grows over the page with long text; it reopens with the last search only if that was a word or short phrase. Confirmed by user.
- [x] **Footnotes.** KOReader's popup (book font) gains a "Footnote" heading and a "Go to Footnote" button.
- [x] **Go To → Page….** Primer prompt with the number keyboard ("You are on page X of Y", checks the range). Books with publisher page labels keep KOReader's dialog.
- [x] **End of book.** Turning past the last page marks the book finished and shows a card: "You've finished", title, author, Mark as Unread / Go to Beginning / Library. KOReader's other end-of-book actions are untouched.
- [x] **Wi-Fi Networks screen works like the Kindle's** (2026-10-10). Confirmed by user. Settings > Wi-Fi > Wi-Fi networks (subtitle shows "Connected to …") opens the screen directly; it scans on opening, lists the connected network first with a check, then the rest by strength; Rescan in the header; with wireless off, tap to turn it on. On a Kindle, joining waits (up to 20 s) for the Kindle to report the new network, and the connected network offers no Disconnect (turn off Wireless instead).
- [x] **Wi-Fi network list.** Replaces KOReader's picker: networks by strength with drawn signal bars and state (Connected / Saved / Secured / Open); tap to connect (password prompt when needed) or disconnect; long-press a saved one for Password / Forget.
- [x] **Leftover dialogs.** Shared Primer prompt (`prompt.lua`) for Save Current Settings and Rename your Kindle; Manage Themes is a list inside the Aa panel (Delete, confirmed); the page flip's ⋮ uses the same dropdown as the toolbar (`dropdown.lua`: Notebook, Reading Statistics).

### Book map & page grid (2026-10-10, confirmed by user)
- [x] **Page grid** replaces KOReader's page browser (toolbar, page flip grid button, gestures): pages as thumbnails 3×3 with numbers under them, your page outlined in bold, the chapter of the first page above, header "‹ Title · Page X of Y", a track at the bottom (tap to jump). Swipe / page buttons for the next nine; tap a page to go there.
- [x] **Book map** replaces KOReader's: a bar for the whole book (chapter breaks, your place marked, read part filled), then the chapters, each with its first page and a bar filled as far as you've read, with marks under it for bookmarks (black) and highlights / notes (grey). Opens on the current chapter (bold); tap one to go there.
- [x] Book map, page grid and search results repaint the whole screen on opening (the book page no longer shows through).

### Installation (2026-10-10, confirmed by user on an existing install; fresh install untested)
- [x] **Plug and play.** First-run setup patch (`2-primer-setup.lua`) applies Primer's defaults (look, refresh, footer, Kindle sleep screens, start with last book; reading font/size/margins only where unset, Literata off-Kindle), turns off KOReader's frontlight / brightness / page-flip gestures, and skips KOReader's quickstart guide. Updating from an earlier Primer (any `voyage_*` / `primer_*` setting present) keeps the look and behaviour settings as they are. Defaults moved into the plugin (`defaults/`); `tools/apply-gestures.py` retired.
- [x] **Welcome screen** on first start: how to open the panel, toolbar and page flip; offers "Start at Boot" on Kindles; warns if KOReader is older than 2026.07.
- [x] **Settings > Device options > Start Primer at boot** toggle (Kindle).
- [x] **Device name** defaults to the Kindle's own registered name (reginfo) instead of a hard-coded one.
- [x] KUAL extension renamed `extensions/primer` (dev probe "Find device name" removed); the old `extensions/voyage` is removed on deploy.
- [x] **Release zip**: `tools/package.sh` (optionally with KOReader and a dictionary), `INSTALL.txt` guide, `VERSION`.
- [x] **Sleep after 10 minutes, like a Kindle** (2026-10-10, confirmed by user): setup v2 fills in `auto_suspend_timeout_seconds = 600` where unset (new installs and updates); Settings > Device options > Sleep after shows 10 minutes by default (was KOReader's 15).

### Gestures
- [x] **No frontlight toggle on bottom-left corner tap** (library and reader), **no page-flipping toggle on top-left corner tap** (reader). Applied 2026-10-09 in `settings/gestures.lua`, saved in `src/defaults/gestures.lua`; confirmed by user.

- [x] **No brightness gestures.** Left-edge swipes, two-finger vertical swipes and the south-west multiswipe no longer change brightness (Kindle has none; brightness lives in the quick panel). Applied by the first-run setup. Confirmed by user.
- [x] **Tapping the bottom of the page turns it** instead of opening KOReader's settings bar (2026-10-10). Confirmed by user.
- [x] **Quick panel opens on swipe release**, so the rest of the opening swipe can't drag the brightness slider. Confirmed by user.

- [x] **Library refinements** (2026-10-10): header shows time • date (follows 12/24 h, refreshed each minute) instead of the device name; Wi-Fi icon only when wireless is on, nothing when off; slim footer with "Page N of M" on the right; per-book progress after the dots ("23%" while reading, "read" when finished, nothing if unopened), replacing the margin tag. Confirmed by user.

- [x] **Library: filter, search, NEW, book card, trash** (2026-10-10). Confirmed by user.
  - Tap "Showing … ▾" for a dropdown: All Items / Reading / Unread / Finished / Trash (remembered).
  - Search (footer left) opens a Kindle-style bar at the top (magnifier, field, Cancel) with the keyboard below; the list filters as you type. Footer then offers "Clear “…”".
  - NEW badge right after the title for unopened books added in the last 3 days.
  - Long-press a book: compact card (cover, title, author, series, status, format/size; no description) with Open / Mark as Read (Unread) / Remove.
  - Remove moves the book and its reading data to a hidden `.primer-trash` folder (no confirmation, it's reversible). The Trash view lists removed books ("Removed 2 days ago"); tap or long-press for Restore (to its original folder) / Delete Forever (confirmed); footer offers Empty Trash.
  - Footer height raised to between the original and slim versions.

### Device
- [x] **USB handoff.** (Installed 2026-10-09; confirmed by user, KOReader relaunches after eject.) KOReader lives on the drive the Kindle exports, so it can't stay running while mounted. Plugging into a computer (detected via `fsl-usb2-udc/gadget/connected`, which a wall charger leaves at 0) shows "Connect to your computer?"; Connect exits KOReader and starts `tools/usb-handoff.sh` from /tmp, which waits for the gadget LUN (`gadget-lun0/file`) to be lent and returned, then relaunches KOReader once its files are reachable. Log copied to `/mnt/us/voyage-usb-handoff.log`. Prompt is a Kindle-style dialog (`dialog.lua`: Amazon Ember, bordered box, divided buttons); Connect flashes inverted, then shows "Switching to USB drive mode…" and quits KOReader explicitly.

### Portability (goal: any KOReader device)
- [x] **Fonts:** `fonts.lua` resolves each role to the Kindle's font (Amazon Ember / Bookerly / Caecilia), else bundled open fonts (Inter / Literata / Bitter, OFL, `src/fonts` → `koreader/fonts/primer`), else KOReader's default. Footer and message boxes follow. No visual change on the Voyage confirmed by user; off-Kindle untested.
- [~] **Kindle-only features hidden or adapted off-Kindle** (2026-10-10): wireless falls back to KOReader's Wi-Fi toggle; Settings hides "Ask to connect to a computer" and the "Kindle illustrations" sleep screen, and page-button swap without keys; Aa lists KOReader's fonts. Was: wireless flip and light sensor (lipc), USB handoff (`fsl-usb2-udc`), stock sleep screens (`/usr/share/blanket`), KUAL boot extension. Each needs a per-platform path (Kobo, PocketBook, Android) or should hide on non-Kindles.
- [~] **Paths:** library home falls back to KOReader's default dir; Kindle-only paths (screensavers, USB, KUAL) stay behind Kindle checks.
- [ ] **Layout:** sizes scale from a 1072px-wide screen; to be tuned as other devices are tested.

## Done
- [x] Aa Font Family list on Kindles includes Primer's bundled fonts folder, so Literata/Bitter (now resolved to the bundled copies) show again, plus Inter (2026-10-10).
- [x] Renamed KO-Plus → Primer (2026-10-10): visible strings, KUAL menu, About ("Built on KOReader" credit), repo.
- [x] Start with the last book (KOReader `start_with = "last"`), on boot and after the USB handoff; confirmed 2026-10-09.
- [x] Library reorganized 2026-10-09: author folders removed (backup in `backup/author-folders-2026-10-09`), 197 Calibre EPUBs copied flat to `documents/` as `Title - Author.epub` (full titles from Calibre's metadata.opf). KFX store books left untouched.
- [x] Reading defaults captured: Bookerly 22, line spacing 115%, side margins 30, top 30, bottom 12, word spacing 95/75, best kerning (`src/defaults/reading.lua`)
- [x] KOReader v2026.07.1 (kindlepw2 build), 2026-10-09
- [x] Start KOReader at boot (KUAL > Voyage), once per boot, `NO_KOREADER` escape hatch
- [x] SSH key-only login (`ssh voyage`, needs the Voyage's IP)
