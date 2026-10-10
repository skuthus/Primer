-- Gesture overrides (koreader/settings/gestures.lua), applied to both gesture_fm and gesture_reader
-- on first run.
return {
    -- KOReader toggles the frontlight on a bottom-left corner tap; the Kindle doesn't.
    tap_left_bottom_corner = {},
    -- KOReader toggles page-flipping mode on a top-left corner tap (reader); easy to hit when reaching for the toolbar.
    tap_top_left_corner = {},
    -- KOReader's brightness gestures; the Kindle has none, and swipes near the left edge set them off.
    -- Brightness lives in the quick panel.
    one_finger_swipe_left_edge_down = {},
    one_finger_swipe_left_edge_up = {},
    two_finger_swipe_south = {},
    two_finger_swipe_north = {},
    multiswipe_south_west = {},
}
