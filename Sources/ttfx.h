/* C surface of the ttfx engine (src/lib.rs), for the Swift screensaver. */
#ifndef TTFX_H
#define TTFX_H

typedef struct ttfx_session ttfx_session;

/* Comma-joined effect names; borrowed, never freed. */
const char *ttfx_effect_list(void);

/* One effect run over input_utf8, text centered on a canvas of exactly
 * canvas_width x canvas_height cells. color_mode handles SGR color already in
 * the input (ANSI art): 0 ignore, 1 keep where the effect isn't coloring,
 * 2 always keep. NULL on invalid arguments. */
ttfx_session *ttfx_session_new(const char *effect, const char *input_utf8,
                               long long canvas_width, long long canvas_height,
                               long long frame_rate, unsigned long long seed,
                               unsigned char color_mode);

/* Next frame: canvas rows top-first joined by '\n', SGR-colored. NULL when
 * the effect is complete. Valid until the next call or _free. */
const char *ttfx_session_next_frame(ttfx_session *s);

void ttfx_session_free(ttfx_session *s);

#endif
