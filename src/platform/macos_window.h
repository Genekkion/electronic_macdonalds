#ifndef MACOS_WINDOW_H
#define MACOS_WINDOW_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*WindowCloseCallback)(void);
typedef const char *(*GetLineCallback)(void *ctx, int line_idx, int *out_len);
typedef int (*GetLineCountCallback)(void *ctx);
typedef void (*KeyDownCallback)(void *ctx, const char *chars, int key_code, int mods);

bool macos_app_init(void);
void *macos_window_create(const char *title, int width, int height);
void macos_window_set_close_callback(void *win, WindowCloseCallback cb);
void macos_window_attach_editor_view(
    void *win,
    void *ctx,
    GetLineCallback get_line,
    GetLineCountCallback get_line_count,
    KeyDownCallback on_key_down
);
void macos_window_set_cursor(void *win, int line, int col);
void macos_window_set_cursor_mode(void *win, int line, int col, int mode);
void macos_window_set_status_line(void *win, const char *status_text);
void macos_window_redraw(void *win);
bool macos_app_poll_events(void);
void macos_app_run(void);

#ifdef __cplusplus
}
#endif

#endif // MACOS_WINDOW_H
