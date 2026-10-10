-- Device settings (top level of settings.reader.lua), applied by patches/2-primer-setup.lua on
-- first run. These set Primer's look and behaviour, so they replace KOReader's values.
return {
    all = {
        -- Open the last book on startup (boot, and after the USB handoff relaunches Primer).
        start_with = "last",
        -- Kindle-style refresh: no forced flash every N pages (REAGL keeps pages clean),
        -- no black flashes on menus; the plugin flashes once at each chapter start.
        full_refresh_count = 0,
        night_full_refresh_count = 0,
        avoid_flashing_ui = true,
        -- Footer visible.
        reader_footer_mode = 1,
    },
    kindle = {
        -- Stock Kindle sleep screens: a random one of the Kindle's own illustrations, copied to
        -- /mnt/us/screensavers by the plugin. No "Sleeping" message over it.
        screensaver_type = "random_image",
        screensaver_dir = "/mnt/us/screensavers",
        screensaver_show_message = false,
        screensaver_stretch_images = false,
        screensaver_img_background = "white",
    },
}
