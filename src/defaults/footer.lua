-- Kindle-style footer settings (merged into settings.reader.lua's ["footer"] table).
-- Item text comes from src/patches/2-kindle-footer.lua.
return {
    all_at_once          = true,  -- show every enabled item together, not one per tap
    page_progress        = true,
    dynamic_filler       = true,  -- pushes the percentage to the right edge
    percentage           = true,
    battery              = false,
    time                 = false,
    pages_left           = false,
    book_time_to_read    = false,
    chapter_time_to_read = false,
    disable_progress_bar = true,
    text_font_face       = "/usr/java/lib/fonts/Amazon-Ember-Regular.ttf",
    text_font_size       = 14,
    text_font_bold       = true,
    container_height     = 24,  -- footer area height (user-tuned 2026-10-09)
    container_bottom_padding = 1,
    -- Item order (0-based, as KOReader stores it); unlisted items follow.
    order = { [0] = "off", "page_progress", "dynamic_filler", "percentage" },
}
-- Also at the top level of settings.reader.lua: reader_footer_mode = 1 (footer visible).
