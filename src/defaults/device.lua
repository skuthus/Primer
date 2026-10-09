-- Device settings (top level of settings.reader.lua).
return {
    -- Shown in the quick panel and library header. The Kindle's own registered name
    -- (/var/local/java/prefs/reginfo, deviceName=) is "Skyler's 2nd Kindle"; the user prefers Kumba.
    voyage_device_name = "Kumba",
    -- Open the last book on startup (boot, and after the USB handoff relaunches KOReader).
    start_with = "last",
}
