#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include "macos_window.h"

void em_log(const char *fmt, ...) {
    FILE *f = fopen("./logs.log", "a");
    if (!f) return;
    va_list args;
    va_start(args, fmt);
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    char time_str[32];
    if (tm) {
        strftime(time_str, sizeof(time_str), "%H:%M:%S", tm);
    } else {
        snprintf(time_str, sizeof(time_str), "00:00:00");
    }
    fprintf(f, "[%s] ", time_str);
    vfprintf(f, fmt, args);
    fprintf(f, "\n");
    fflush(f);
    va_end(args);
    fclose(f);
}
