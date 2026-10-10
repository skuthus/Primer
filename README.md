# KO-Plus

A curated, Kindle-feeling KOReader for the Kindle Voyage: KOReader as the whole OS, trimmed and restyled to look and behave like the stock Kindle software.

Target: Kindle Voyage, firmware 5.13.6, jailbroken, KOReader v2026.07.1 (`kindlepw2` build). See [CHANGES.md](CHANGES.md) for what's done and planned.

## What's here

| Path | What it is |
|---|---|
| `src/plugins/voyagepanel.koplugin/` | The main plugin: swipe-down quick panel, Kindle 2-style library (home), Kindle-style reading toolbar on top tap, Auto Brightness |
| `src/patches/2-kindle-footer.lua` | Kindle-style footer: "Page 9" left, "45%" right, aligned to the text margins |
| `src/defaults/` | Reading and footer settings to restore after a reinstall (merged into `settings.reader.lua`) |
| `src/extensions/voyage/` | KUAL menu: start KOReader at boot (once per boot, `/mnt/us/NO_KOREADER` skips it), find the device name |
| `tools/lint/` | Static checks (syntax, unknown globals, `_` shadowing). There's no KOReader for macOS, so these run before every deploy |
| `tools/deploy.sh` | Lint, then copy everything onto a USB-mounted Voyage |
| `design/` | Reference screenshots and icon previews |

## Deploy

Exit KOReader on the Voyage (so USB drive mode is available), plug in, then:

```sh
tools/deploy.sh
```

Restart KOReader to load the changes. Errors land in `koreader/crash.log` on the device.

## Dictionary

KO-Plus expects a StarDict dictionary in `koreader/data/dict/` on the Kindle. We use the English-English Wiktionary from [Vuizur/Wiktionary-Dictionaries](https://github.com/Vuizur/Wiktionary-Dictionaries) (`English-English Wiktionary dictionary stardict.tar.gz`, CC BY-SA); unpack it and copy its folder there. It isn't committed here (30 MB).

## Notes

- Fonts used (Amazon Ember, Bookerly, Caecilia) are the Voyage's built-in system fonts in `/usr/java/lib/fonts`; nothing is bundled.
- Never use `_` as a throwaway variable in plugin code: KOReader's gettext is `_`, and shadowing it breaks `_("…")` calls. The lint enforces this.
