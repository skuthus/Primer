# Primer

A modern UI frontend for [KOReader](https://github.com/koreader/koreader): a curated, Kindle-inspired interface (library, reading toolbar, quick panel, Aa, dictionary, notes, settings) over KOReader's engine. Developed on a Kindle Voyage, with the goal of running on any KOReader-compatible device.

The name: a first book; the interactive book in Neal Stephenson's *The Diamond Age*; and a quiet nod to Amazon (Prime → Primer).

Target: Kindle Voyage, firmware 5.13.6, jailbroken, KOReader v2026.07.1 (`kindlepw2` build). See [CHANGES.md](CHANGES.md) for what's done and planned.

## What's here

| Path | What it is |
|---|---|
| `src/plugins/voyagepanel.koplugin/` | The main plugin: swipe-down quick panel, Kindle 2-style library (home), Kindle-style reading toolbar on top tap, Auto Brightness |
| `src/plugins/voyagepanel.koplugin/defaults/` | Primer's default settings (look, footer, reading, gestures), applied on first run |
| `src/patches/2-primer-setup.lua` | First-run setup: applies the defaults (reading ones only where unset), skips KOReader's quickstart |
| `src/patches/2-primer-ui.lua` | Primer's interface font across KOReader's own screens, square windows, Kindle-style keyboard |
| `src/patches/2-kindle-footer.lua` | Kindle-style footer: "Page 9" left, "45%" right, aligned to the text margins |
| `src/patches/2-kindle-messages.lua` | Kindle-style message boxes; hides "Opening file" |
| `src/extensions/primer/` | KUAL menu: start Primer at boot (once per boot, `/mnt/us/NO_KOREADER` skips it). Primer's Settings and welcome screen use the same script |
| `src/screensavers/` | Public domain sleep screen collections (Doré, Tenniel, Hiroshige, Haeckel), installed to `koreader/screensavers/primer/`; sources in `CREDITS.md` |
| `INSTALL.txt` | End-user install guide, shipped in the release zip |
| `tools/package.sh` | Build the release zip (`dist/Primer-<version>.zip`) |
| `tools/deploy-remarkable.sh` | Lint, then copy Primer into KOReader on a reMarkable over SSH (USB, host `remarkable` in `~/.ssh/config`) |
| `tools/lint/` | Static checks (syntax, unknown globals, `_` shadowing). There's no KOReader for macOS, so these run before every deploy |
| `tools/deploy.sh` | Lint, then copy everything onto a USB-mounted Voyage |
| `design/` | Reference screenshots and icon previews |

## Install (users)

See [INSTALL.txt](INSTALL.txt). In short: on a jailbroken Kindle with KUAL and KOReader, copy the release zip's `koreader` and `extensions` folders onto the Kindle and start KOReader. Primer sets itself up on first start (defaults, gestures, no quickstart guide) and offers to start at boot.

## Release

```sh
tools/package.sh                                   # dist/Primer-<version>.zip
tools/package.sh --koreader koreader-kindlepw2-….zip   # …-with-KOReader.zip, KOReader included
```

A StarDict dictionary folder placed in `vendor/dict/` (git-ignored) is included in `koreader/data/dict/`. The version is in `VERSION`.

## Deploy (development)

Exit KOReader on the Voyage (so USB drive mode is available), plug in, then:

```sh
tools/deploy.sh
```

Restart KOReader to load the changes. Errors land in `koreader/crash.log` on the device.

## Dictionary

Primer expects a StarDict dictionary in `koreader/data/dict/` on the Kindle. We use the English-English Wiktionary from [Vuizur/Wiktionary-Dictionaries](https://github.com/Vuizur/Wiktionary-Dictionaries) (`English-English Wiktionary dictionary stardict.tar.gz`, CC BY-SA); unpack it and copy its folder there. It isn't committed here (30 MB).

## Fonts

On Kindles, Primer uses the device's built-in Amazon Ember (interface), Bookerly (reading) and Caecilia (library titles). Those are Amazon's proprietary fonts and aren't bundled. Everywhere else it uses the open fonts in `src/fonts/` (installed to `koreader/fonts/primer/`): Inter for the interface, Literata for reading, Bitter for library titles, each under the SIL Open Font License (licenses alongside). `fonts.lua` picks per role: Kindle font, else bundled, else KOReader's default.

## Notes

- Never use `_` as a throwaway variable in plugin code: KOReader's gettext is `_`, and shadowing it breaks `_("…")` calls. The lint enforces this.
