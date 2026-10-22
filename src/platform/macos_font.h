#ifndef MACOS_FONT_H
#define MACOS_FONT_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float char_width;
    float line_height;
    float ascent;
} MacFontMetrics;

bool macos_font_load_monospace(const char *name, double point_size, MacFontMetrics *out_metrics);

#ifdef __cplusplus
}
#endif

#endif // MACOS_FONT_H
