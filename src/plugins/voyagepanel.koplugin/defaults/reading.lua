-- Reading defaults (tuned on the Voyage, 2026-10-09). Applied on first run only where the reader
-- has no value of their own; off-Kindle the font is Literata (Bookerly is Amazon's).
return {
    cre_font                  = "Bookerly",
    copt_font_size            = 22,
    copt_line_spacing         = 115,
    copt_h_page_margins       = { 30, 30 },
    copt_t_page_margin        = 30,
    copt_b_page_margin        = 12,
    copt_sync_t_b_page_margins = 0,
    copt_word_spacing         = { 95, 75 },
    copt_word_expansion       = 0,
    copt_font_base_weight     = 0,
    copt_font_gamma           = 15,
    copt_font_hinting         = 2,
    copt_font_kerning         = 3,
    copt_block_rendering_mode = 3,  -- 0 legacy, 1 flat, 2 book, 3 web
    copt_embedded_css         = 1,
    copt_embedded_fonts       = 0,
    copt_render_dpi           = 96,
}
