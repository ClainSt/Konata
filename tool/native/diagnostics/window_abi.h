// Diagnostic-only AOSP window ABI; see README.md for fixed reference and scope.
#ifndef KONATA_DIAGNOSTIC_WINDOW_ABI
#define KONATA_DIAGNOSTIC_WINDOW_ABI
struct kp_window {
    int magic, version;
    void *reserved[4];
    void (*inc)(void *), (*dec)(void *);
    int flags, min_swap, max_swap;
    float xdpi, ydpi;
    intptr_t oem[4];
    void (*legacy[4])(void);
    int (*query)(const ANativeWindow *, int, int *);
    int (*perform)(ANativeWindow *, int, ...);
    void (*tail[4])(void);
};
#endif
