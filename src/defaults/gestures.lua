-- Gesture overrides (koreader/settings/gestures.lua), applied to both gesture_fm and gesture_reader.
return {
    -- KOReader toggles the frontlight on a bottom-left corner tap; the Kindle doesn't.
    tap_left_bottom_corner = {},
    -- KOReader toggles page-flipping mode on a top-left corner tap (reader); easy to hit when reaching for the toolbar.
    tap_top_left_corner = {},
}
