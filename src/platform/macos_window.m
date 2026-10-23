#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#include "macos_window.h"

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}
@end

@interface WindowDelegate : NSObject <NSWindowDelegate>
@property (nonatomic, assign) WindowCloseCallback closeCallback;
@end

@implementation WindowDelegate
- (void)windowWillClose:(NSNotification *)notification {
    if (self.closeCallback) {
        self.closeCallback();
    }
}
@end

@interface EditorView : NSView {
@public
    int _searchHighlights[256 * 3];
}
@property (nonatomic, assign) void *ctx;
@property (nonatomic, assign) GetLineCallback getLineCb;
@property (nonatomic, assign) GetLineCountCallback getLineCountCb;
@property (nonatomic, assign) KeyDownCallback keyDownCb;
@property (nonatomic, assign) int cursorLine;
@property (nonatomic, assign) int cursorCol;
@property (nonatomic, assign) int mode;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic, assign) BOOL hasSelection;
@property (nonatomic, assign) BOOL isLineSelection;
@property (nonatomic, assign) int selStartLine;
@property (nonatomic, assign) int selStartCol;
@property (nonatomic, assign) int selEndLine;
@property (nonatomic, assign) int selEndCol;
@property (nonatomic, assign) BOOL hasSearchHighlights;
@property (nonatomic, assign) int searchHighlightCount;
@property (nonatomic, assign) BOOL cursorVisible;
@property (nonatomic, strong) NSTimer *blinkTimer;
@property (nonatomic, assign) CTFontRef font;
@property (nonatomic, assign) CGFloat charWidth;
@property (nonatomic, assign) CGFloat lineHeight;
@property (nonatomic, assign) CGFloat ascent;
@end

@implementation EditorView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _cursorLine = 0;
        _cursorCol = 0;
        _mode = 0;
        _statusText = @"";
        _cursorVisible = YES;

        _font = CTFontCreateWithName(CFSTR("Menlo"), 14.0, NULL);
        if (_font) {
            _ascent = CTFontGetAscent(_font);
            CGFloat descent = CTFontGetDescent(_font);
            CGFloat leading = CTFontGetLeading(_font);
            _lineHeight = ceil(_ascent + descent + leading);

            CGGlyph glyphs[1];
            UniChar chars[1] = { 'M' };
            if (CTFontGetGlyphsForCharacters(_font, chars, glyphs, 1)) {
                CGSize advance;
                CTFontGetAdvancesForGlyphs(_font, kCTFontOrientationHorizontal, glyphs, &advance, 1);
                _charWidth = advance.width;
            } else {
                _charWidth = 8.0;
            }
        } else {
            _charWidth = 8.0;
            _lineHeight = 16.0;
            _ascent = 12.0;
        }

        _blinkTimer = [NSTimer scheduledTimerWithTimeInterval:0.55
                                                       target:self
                                                     selector:@selector(blinkCursor:)
                                                     userInfo:nil
                                                      repeats:YES];
    }
    return self;
}

- (void)blinkCursor:(NSTimer *)timer {
    _cursorVisible = !_cursorVisible;
    [self setNeedsDisplay:YES];
}

- (void)dealloc {
    [_blinkTimer invalidate];
    if (_font) {
        CFRelease(_font);
    }
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    NSUInteger flags = [event modifierFlags];
    int mods = 0;
    if (flags & NSEventModifierFlagShift) mods |= 1;
    if (flags & NSEventModifierFlagControl) mods |= 2;
    if (flags & NSEventModifierFlagOption) mods |= 4;
    if (flags & NSEventModifierFlagCommand) mods |= 8;

    NSString *chars = [event characters];
    const char *utf8 = chars ? [chars UTF8String] : "";
    unsigned short keyCode = [event keyCode];

    _cursorVisible = YES;

    if (_keyDownCb) {
        _keyDownCb(_ctx, utf8, (int)keyCode, mods);
    }
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef context = (CGContextRef)[[NSGraphicsContext currentContext] CGContext];
    if (!context) return;

    // 1. Draw background (#1e1e1e)
    CGContextSetRGBFillColor(context, 0.118, 0.118, 0.118, 1.0);
    CGContextFillRect(context, self.bounds);

    if (!_getLineCb || !_getLineCountCb || !_font) return;

    CGFloat statusHeight = _lineHeight + 6.0;
    CGFloat statusY = self.bounds.size.height - statusHeight;

    int totalLines = _getLineCountCb(_ctx);
    int visibleRows = (int)floor((statusY) / _lineHeight);
    int maxLine = totalLines < visibleRows ? totalLines : visibleRows;

    // Attributes for text rendering
    NSColor *textColor = [NSColor colorWithCalibratedRed:0.88 green:0.88 blue:0.88 alpha:1.0];
    NSDictionary *attributes = @{
        NSFontAttributeName: (__bridge id)_font,
        NSForegroundColorAttributeName: textColor
    };

    // 2. Draw visual selection highlight if active
    if (_hasSelection) {
        CGContextSetRGBFillColor(context, 0.22, 0.35, 0.55, 0.65);
        int startL = _selStartLine;
        int endL = _selEndLine;
        for (int i = startL; i <= endL && i < maxLine; i++) {
            NSRect selRect;
            if (_isLineSelection) {
                selRect = NSMakeRect(0, i * _lineHeight, self.bounds.size.width, _lineHeight);
            } else if (startL == endL) {
                CGFloat startX = 10.0 + _selStartCol * _charWidth;
                CGFloat width = (_selEndCol - _selStartCol + 1) * _charWidth;
                selRect = NSMakeRect(startX, i * _lineHeight, width, _lineHeight);
            } else if (i == startL) {
                CGFloat startX = 10.0 + _selStartCol * _charWidth;
                CGFloat width = self.bounds.size.width - startX;
                selRect = NSMakeRect(startX, i * _lineHeight, width, _lineHeight);
            } else if (i == endL) {
                CGFloat width = 10.0 + (_selEndCol + 1) * _charWidth;
                selRect = NSMakeRect(0, i * _lineHeight, width, _lineHeight);
            } else {
                selRect = NSMakeRect(0, i * _lineHeight, self.bounds.size.width, _lineHeight);
            }
            CGContextFillRect(context, selRect);
        }
    }

    // 2.5 Draw search highlights if active
    if (_hasSearchHighlights && _searchHighlightCount > 0) {
        CGContextSetRGBFillColor(context, 0.95, 0.75, 0.15, 0.40); // Soft amber gold
        for (int i = 0; i < _searchHighlightCount; i++) {
            int line = _searchHighlights[i * 3 + 0];
            int col = _searchHighlights[i * 3 + 1];
            int len = _searchHighlights[i * 3 + 2];
            if (line < maxLine) {
                CGFloat x = 10.0 + col * _charWidth;
                CGFloat y = line * _lineHeight;
                CGFloat w = len * _charWidth;
                CGContextFillRect(context, NSMakeRect(x, y, w, _lineHeight));
            }
        }
    }

    // 3. Draw lines of text
    for (int i = 0; i < maxLine; i++) {
        int len = 0;
        const char *bytes = _getLineCb(_ctx, i, &len);
        if (bytes && len > 0) {
            NSString *str = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
            if (str) {
                NSAttributedString *attrStr = [[NSAttributedString alloc] initWithString:str attributes:attributes];
                [attrStr drawAtPoint:NSMakePoint(10.0, i * _lineHeight)];
            }
        }
    }

    // 3. Draw cursor
    if (_cursorVisible) {
        if (_mode == 3) {
            // Command-line mode: draw bar cursor directly on the status bar
            CGFloat textLen = _statusText ? (CGFloat)[_statusText length] : 0.0;
            CGFloat cursorX = 10.0 + textLen * _charWidth;
            CGFloat cursorY = statusY + 3.0;
            NSRect cursorRect = NSMakeRect(cursorX, cursorY, 2.0, _lineHeight);
            CGContextSetRGBFillColor(context, 0.4, 0.7, 1.0, 0.9);
            CGContextFillRect(context, cursorRect);
        } else {
            // Buffer cursor (block for Normal, bar for Insert)
            CGFloat cursorX = 10.0 + _cursorCol * _charWidth;
            CGFloat cursorY = _cursorLine * _lineHeight;
            CGFloat cursorW = (_mode == 1) ? 2.0 : _charWidth;
            NSRect cursorRect = NSMakeRect(cursorX, cursorY, cursorW, _lineHeight);
            CGContextSetRGBFillColor(context, 0.32, 0.54, 1.0, 0.75);
            CGContextFillRect(context, cursorRect);
        }
    }

    // 4. Draw status line at bottom
    NSRect statusRect = NSMakeRect(0, statusY, self.bounds.size.width, statusHeight);
    CGContextSetRGBFillColor(context, 0.15, 0.17, 0.21, 1.0);
    CGContextFillRect(context, statusRect);

    CGContextSetRGBStrokeColor(context, 0.25, 0.28, 0.35, 1.0);
    CGContextSetLineWidth(context, 1.0);
    CGPoint points[2] = { CGPointMake(0, statusY), CGPointMake(self.bounds.size.width, statusY) };
    CGContextStrokeLineSegments(context, points, 2);

    if (_statusText && _statusText.length > 0) {
        NSColor *statusColor = (_mode == 1)
            ? [NSColor colorWithCalibratedRed:0.35 green:0.85 blue:0.45 alpha:1.0]
            : [NSColor colorWithCalibratedRed:0.85 green:0.85 blue:0.85 alpha:1.0];
        NSDictionary *statusAttrs = @{
            NSFontAttributeName: (__bridge id)_font,
            NSForegroundColorAttributeName: statusColor
        };
        NSAttributedString *attrStatus = [[NSAttributedString alloc] initWithString:_statusText attributes:statusAttrs];
        [attrStatus drawAtPoint:NSMakePoint(10.0, statusY + 3.0)];
    }
}

@end

static AppDelegate *g_app_delegate = nil;

bool macos_app_init(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        g_app_delegate = [[AppDelegate alloc] init];
        [NSApp setDelegate:g_app_delegate];

        id menubar = [[NSMenu alloc] init];
        id appMenuItem = [[NSMenuItem alloc] init];
        [menubar addItem:appMenuItem];
        [NSApp setMainMenu:menubar];

        id appMenu = [[NSMenu alloc] init];
        id appName = [[NSProcessInfo processInfo] processName];
        id quitTitle = [@"Quit " stringByAppendingString:appName];
        id quitMenuItem = [[NSMenuItem alloc] initWithTitle:quitTitle
                                                     action:@selector(terminate:)
                                              keyEquivalent:@"q"];
        [appMenu addItem:quitMenuItem];
        [appMenuItem setSubmenu:appMenu];

        [NSApp finishLaunching];
        return true;
    }
}

void *macos_window_create(const char *title, int width, int height) {
    @autoreleasepool {
        NSRect frame = NSMakeRect(0, 0, width, height);
        NSUInteger styleMask = NSWindowStyleMaskTitled |
                               NSWindowStyleMaskClosable |
                               NSWindowStyleMaskMiniaturizable |
                               NSWindowStyleMaskResizable;

        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:styleMask
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];

        [window setTitle:[NSString stringWithUTF8String:title]];
        [window center];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        return (__bridge_retained void *)window;
    }
}

void macos_window_set_close_callback(void *win, WindowCloseCallback cb) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)win;
        WindowDelegate *delegate = [[WindowDelegate alloc] init];
        delegate.closeCallback = cb;
        [window setDelegate:delegate];
    }
}

void macos_window_attach_editor_view(
    void *win,
    void *ctx,
    GetLineCallback get_line,
    GetLineCountCallback get_line_count,
    KeyDownCallback on_key_down
) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)win;
        NSRect contentBounds = [[window contentView] bounds];
        EditorView *view = [[EditorView alloc] initWithFrame:contentBounds];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        view.ctx = ctx;
        view.getLineCb = get_line;
        view.getLineCountCb = get_line_count;
        view.keyDownCb = on_key_down;
        [window setContentView:view];
        [window makeFirstResponder:view];
    }
}

void macos_window_set_cursor(void *win, int line, int col) {
    macos_window_set_cursor_mode(win, line, col, 0);
}

void macos_window_set_cursor_mode(void *win, int line, int col, int mode) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)win;
        if ([[window contentView] isKindOfClass:[EditorView class]]) {
            EditorView *view = (EditorView *)[window contentView];
            view.cursorLine = line;
            view.cursorCol = col;
            view.mode = mode;
            [view setNeedsDisplay:YES];
        }
    }
}

void macos_window_set_status_line(void *win, const char *status_text) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)win;
        if ([[window contentView] isKindOfClass:[EditorView class]]) {
            EditorView *view = (EditorView *)[window contentView];
            view.statusText = status_text ? [NSString stringWithUTF8String:status_text] : @"";
            [view setNeedsDisplay:YES];
        }
    }
}

void macos_window_set_selection(
    void *win,
    int start_line,
    int start_col,
    int end_line,
    int end_col,
    bool is_active,
    bool is_line
) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)win;
        if ([[window contentView] isKindOfClass:[EditorView class]]) {
            EditorView *view = (EditorView *)[window contentView];
            view.hasSelection = is_active;
            view.isLineSelection = is_line;
            view.selStartLine = start_line;
            view.selStartCol = start_col;
            view.selEndLine = end_line;
            view.selEndCol = end_col;
            [view setNeedsDisplay:YES];
        }
    }
}

void macos_window_set_search_highlights(
    void *win_ptr,
    bool active,
    const int *line_col_len,
    int count
) {
    if (!win_ptr) return;
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)win_ptr;
        if ([[window contentView] isKindOfClass:[EditorView class]]) {
            EditorView *view = (EditorView *)[window contentView];
            view.hasSearchHighlights = active;
            view.searchHighlightCount = (count < 256) ? count : 256;
            if (active && line_col_len && count > 0) {
                int copyCount = view.searchHighlightCount * 3;
                for (int i = 0; i < copyCount; i++) {
                    view->_searchHighlights[i] = line_col_len[i];
                }
            }
            [view setNeedsDisplay:YES];
        }
    }
}

void macos_clipboard_set(const char *text, int len) {
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        if (text && len > 0) {
            NSString *str = [[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding];
            if (str) {
                [pb setString:str forType:NSPasteboardTypeString];
            }
        }
    }
}

static char *g_clipboard_cache = NULL;

const char *macos_clipboard_get(int *out_len) {
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        NSString *str = [pb stringForType:NSPasteboardTypeString];
        if (!str) {
            if (out_len) *out_len = 0;
            return NULL;
        }
        NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
        if (!data || data.length == 0) {
            if (out_len) *out_len = 0;
            return NULL;
        }
        if (g_clipboard_cache) {
            free(g_clipboard_cache);
            g_clipboard_cache = NULL;
        }
        g_clipboard_cache = (char *)malloc(data.length + 1);
        if (!g_clipboard_cache) {
            if (out_len) *out_len = 0;
            return NULL;
        }
        memcpy(g_clipboard_cache, data.bytes, data.length);
        g_clipboard_cache[data.length] = '\0';
        if (out_len) *out_len = (int)data.length;
        return g_clipboard_cache;
    }
}

void macos_window_redraw(void *win) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)win;
        [[window contentView] setNeedsDisplay:YES];
    }
}

bool macos_app_poll_events(void) {
    @autoreleasepool {
        NSEvent *event;
        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                           untilDate:[NSDate distantPast]
                                              inMode:NSDefaultRunLoopMode
                                             dequeue:YES])) {
            [NSApp sendEvent:event];
            [NSApp updateWindows];
        }
        return ![NSApp isRunning];
    }
}

void macos_app_run(void) {
    @autoreleasepool {
        [NSApp run];
    }
}
