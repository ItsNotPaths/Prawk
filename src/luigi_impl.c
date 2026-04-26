#define UI_IMPLEMENTATION
#include "luigi.h"

UIWindow **prawk_ui_windows(void)     { return &ui.windows; }
UITheme   *prawk_ui_theme(void)       { return &ui.theme; }
UIFont   **prawk_ui_active_font(void) { return &ui.activeFont; }

/* Draws an arbitrary Unicode codepoint via FreeType, no caching. luigi's
 * built-in UIDrawGlyph caps at 0..127 (luigi.h:1288). Slower than the cached
 * path, but only invoked for non-ASCII cells in the terminal renderer. */
void prawk_draw_glyph_cp(UIPainter *painter, int x0, int y0, int cp,
                         uint32_t color)
{
#ifdef UI_FREETYPE
    UIFont *font = ui.activeFont;
    if (!font || !font->isFreeType) return;
    if (cp < 0 || cp == 0) return;

    if (FT_Load_Char(font->font, cp, FT_LOAD_RENDER) != 0) return;
    FT_GlyphSlot slot = font->font->glyph;
    FT_Bitmap *bitmap = &slot->bitmap;

    int ox = slot->bitmap_left;
    int oy = font->font->size->metrics.ascender / 64 - slot->bitmap_top;
    x0 += ox; y0 += oy;

    for (int y = 0; y < (int)bitmap->rows; y++) {
        if (y0 + y < painter->clip.t) continue;
        if (y0 + y >= painter->clip.b) break;
        int width = bitmap->width;
        for (int x = 0; x < width; x++) {
            if (x0 + x < painter->clip.l) continue;
            if (x0 + x >= painter->clip.r) break;
            uint32_t *destination = painter->bits + (x0 + x) +
                                    (y0 + y) * painter->width;
            uint32_t original = *destination;
            uint32_t a = ((uint8_t *)bitmap->buffer)[x + y * bitmap->pitch];
            uint32_t r2 = (255 - a) * ((original & 0x000000FF) >> 0);
            uint32_t g2 = (255 - a) * ((original & 0x0000FF00) >> 8);
            uint32_t b2 = (255 - a) * ((original & 0x00FF0000) >> 16);
            uint32_t r1 = a * ((color & 0x000000FF) >> 0);
            uint32_t g1 = a * ((color & 0x0000FF00) >> 8);
            uint32_t b1 = a * ((color & 0x00FF0000) >> 16);
            *destination = 0xFF000000 | (0x00FF0000 & ((b1 + b2) << 8))
                         | (0x0000FF00 & ((g1 + g2) << 0))
                         | (0x000000FF & ((r1 + r2) >> 8));
        }
    }
#else
    (void)painter; (void)x0; (void)y0; (void)cp; (void)color;
#endif
}
