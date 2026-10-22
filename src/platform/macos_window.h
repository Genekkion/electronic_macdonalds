#ifndef MACOS_WINDOW_H
#define MACOS_WINDOW_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*WindowCloseCallback)(void);

bool macos_app_init(void);
void *macos_window_create(const char *title, int width, int height);
void macos_window_set_close_callback(void *win, WindowCloseCallback cb);
bool macos_app_poll_events(void);
void macos_app_run(void);

#ifdef __cplusplus
}
#endif

#endif // MACOS_WINDOW_H
