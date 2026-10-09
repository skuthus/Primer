-- Device settings (top level of settings.reader.lua).
return {
    -- Shown in the quick panel and library header. The Kindle's own registered name
    -- (/var/local/java/prefs/reginfo, deviceName=) is "Skyler's 2nd Kindle"; the user prefers Kumba.
    voyage_device_name = "Kumba",
    -- Open the last book on startup (boot, and after the USB handoff relaunches KOReader).
    start_with = "last",
    -- Kindle-style refresh: no forced flash every N pages (REAGL keeps pages clean),
    -- no black flashes on menus; the plugin flashes once at each chapter start.
    full_refresh_count = 0,
    night_full_refresh_count = 0,
    avoid_flashing_ui = true,
}
