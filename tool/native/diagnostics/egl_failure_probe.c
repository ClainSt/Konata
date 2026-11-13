// DIAGNOSTIC ONLY: bounded EGL failure injection and output-state trace.
#include <dlfcn.h>
#include "window_abi.h"
static bool konata_egl_fault(const char *name)
{
    char mode[32] = {0};
    FILE *f = fopen("/data/user/0/com.anime.konata.acceptance/cache/konata-egl-fault.txt", "rb");
    if (!f) return false;
    fread(mode, 1, sizeof(mode)-1, f);
    fclose(f);
    return strcmp(name, mode) == 0;
}

static void konata_egl_event(struct ra_ctx *ctx, const char *event, int detail)
{
    struct priv *p = ctx->priv;
    ANativeWindow *window = vo_android_native_window(ctx->vo);
    struct kp_window *abi = (void *)window;
    int space = -1;
    if (abi && abi->magic == 0x5f776e64 && abi->version == sizeof(*abi))
        abi->query(window, 20, &space);
    static int last_space = -2, last_pq = -1, last_latched = -1;
    if (strcmp(event, "submitted") == 0) {
        if (space == last_space && p->pq == last_pq && p->pq_failed == last_latched) return;
        last_space = space; last_pq = p->pq; last_latched = p->pq_failed;
    }
    FILE *f = fopen("/data/user/0/com.anime.konata.acceptance/cache/konata-egl-events.jsonl", "ab");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    if (ftell(f) < 32768) {
        EGLint actual = 0;
        int queried = p->egl_surface && eglQuerySurface(p->egl_display, p->egl_surface,
                                                       EGL_GL_COLORSPACE_KHR, &actual);
        fprintf(f, "{\"event\":\"%s\",\"detail\":%d,\"pq\":%s,\"latched\":%s,"
            "\"queried\":%d,\"eglColor\":%d,\"dataspace\":%d}\n", event, detail,
            p->pq ? "true" : "false", p->pq_failed ? "true" : "false", queried, actual,
            space);
    }
    fclose(f);
}
