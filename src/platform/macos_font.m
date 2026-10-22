#import <CoreText/CoreText.h>
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include "macos_font.h"

bool macos_font_load_monospace(const char *name, double point_size, MacFontMetrics *out_metrics) {
    if (!out_metrics) return false;
    CFStringRef cfName = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    if (!cfName) return false;
    CTFontRef font = CTFontCreateWithName(cfName, (CGFloat)point_size, NULL);
    CFRelease(cfName);
    if (!font) return false;

    CGFloat ascent = CTFontGetAscent(font);
    CGFloat descent = CTFontGetDescent(font);
    CGFloat leading = CTFontGetLeading(font);
    CGFloat lineHeight = ceil(ascent + descent + leading);

    CGGlyph glyphs[1];
    UniChar chars[1] = { 'M' };
    if (CTFontGetGlyphsForCharacters(font, chars, glyphs, 1)) {
        CGSize advance;
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, glyphs, &advance, 1);
        out_metrics->char_width = (float)advance.width;
        out_metrics->line_height = (float)lineHeight;
        out_metrics->ascent = (float)ascent;
        CFRelease(font);
        return true;
    }
    CFRelease(font);
    return false;
}
