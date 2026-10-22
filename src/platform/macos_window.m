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

@interface EditorView : NSView
@property (nonatomic, assign) void *ctx;
@property (nonatomic, assign) GetLineCallback getLineCb;
@property (nonatomic, assign) GetLineCountCallback getLineCountCb;
@property (nonatomic, assign) KeyDownCallback keyDownCb;
@property (nonatomic, assign) int cursorLine;
@property (nonatomic, assign) int cursorCol;
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

    int totalLines = _getLineCountCb(_ctx);
    int visibleRows = (int)ceil(self.bounds.size.height / _lineHeight);
    int maxLine = totalLines < visibleRows ? totalLines : visibleRows;

    // Attributes for text rendering
    NSColor *textColor = [NSColor colorWithCalibratedRed:0.88 green:0.88 blue:0.88 alpha:1.0];
    NSDictionary *attributes = @{
        NSFontAttributeName: (__bridge id)_font,
        NSForegroundColorAttributeName: textColor
    };

    // 2. Draw lines of text
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

    // 3. Draw cursor (block cursor #528bff with blinking)
    if (_cursorVisible) {
        CGFloat cursorX = 10.0 + _cursorCol * _charWidth;
        CGFloat cursorY = _cursorLine * _lineHeight;
        NSRect cursorRect = NSMakeRect(cursorX, cursorY, _charWidth, _lineHeight);
        CGContextSetRGBFillColor(context, 0.32, 0.54, 1.0, 0.65);
        CGContextFillRect(context, cursorRect);
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
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)win;
        if ([[window contentView] isKindOfClass:[EditorView class]]) {
            EditorView *view = (EditorView *)[window contentView];
            view.cursorLine = line;
            view.cursorCol = col;
            [view setNeedsDisplay:YES];
        }
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
