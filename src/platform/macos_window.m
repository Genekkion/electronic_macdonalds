#import <Cocoa/Cocoa.h>
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

static AppDelegate *g_app_delegate = nil;

bool macos_app_init(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        g_app_delegate = [[AppDelegate alloc] init];
        [NSApp setDelegate:g_app_delegate];

        // Create basic menu bar for Cmd+Q quit support
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
