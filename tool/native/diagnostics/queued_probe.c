// DIAGNOSTIC ONLY. AOSP window ABI, fixed reference 91e3f29f369b58bfb18162b0786df85c110dacf3.
// Reads our own last queued buffer. Never changes window settings or buffer usage.
#include <android/hardware_buffer.h>
#include <dlfcn.h>
#include <poll.h>
#include <unistd.h>
#include "window_abi.h"

static void konata_probe_queued(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    if (!p->pq || p->probe_sequence > 64) return;
    ANativeWindow *window = vo_android_native_window(ctx->vo);
    struct kp_window *abi = (void *)window;
    AHardwareBuffer *buffer = NULL;
    int fence = -1, result = -1000, wait_result = 0, dataspace = 0;
    ARect crop = {0};
    uint32_t transform = 0;
    AHardwareBuffer_Desc desc = {0};
    void (*describe)(const AHardwareBuffer *, AHardwareBuffer_Desc *) =
        dlsym(RTLD_DEFAULT, "AHardwareBuffer_describe");
    void (*release)(AHardwareBuffer *) = dlsym(RTLD_DEFAULT, "AHardwareBuffer_release");
    PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC client_buffer =
        (void *)eglGetProcAddress("eglGetNativeClientBufferANDROID");
    PFNEGLCREATEIMAGEKHRPROC create_image = (void *)eglGetProcAddress("eglCreateImageKHR");
    PFNEGLDESTROYIMAGEKHRPROC destroy_image = (void *)eglGetProcAddress("eglDestroyImageKHR");
    void (*image_target)(GLenum, void *) = (void *)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    if (abi && abi->magic == 0x5f776e64 && abi->version == sizeof(*abi) &&
        describe && release && client_buffer && create_image && destroy_image && image_target) {
        result = abi->perform(window, 49, &buffer, &fence, &crop, &transform);
        abi->query(window, 20, &dataspace);
    }
    if (fence >= 0) {
        struct pollfd fd = {.fd = fence, .events = POLLIN};
        wait_result = poll(&fd, 1, 500);
        if (wait_result > 0 && !(fd.revents & POLLIN)) wait_result = -1;
        close(fence);
    }
    if (buffer) describe(buffer, &desc);
    GL *gl = &p->gl;
    GLuint texture = 0, fb = 0;
    EGLImageKHR image = EGL_NO_IMAGE_KHR;
    uint32_t *pixels = NULL;
    unsigned bytes = 0;
    GLenum prior = 0, setup = 0, error = 0, status = 0;
    EGLint egl_error = EGL_SUCCESS;
    if (!result && buffer && (fence < 0 || wait_result > 0) && desc.format == 43 &&
        desc.width >= 5 && desc.width <= 8192 && desc.height >= 5 && desc.height <= 8192 &&
        !(desc.usage & AHARDWAREBUFFER_USAGE_PROTECTED_CONTENT)) {
        GLint read_fb, read_buffer, binding, pack, align, row, sy, sx;
        gl->GetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_fb);
        gl->GetIntegerv(GL_READ_BUFFER, &read_buffer);
        gl->GetIntegerv(GL_TEXTURE_BINDING_2D, &binding);
        gl->GetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pack);
        gl->GetIntegerv(GL_PACK_ALIGNMENT, &align);
        gl->GetIntegerv(GL_PACK_ROW_LENGTH, &row);
        gl->GetIntegerv(GL_PACK_SKIP_ROWS, &sy);
        gl->GetIntegerv(GL_PACK_SKIP_PIXELS, &sx);
        prior = gl->GetError();
        const EGLint attrs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
        image = create_image(p->egl_display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID,
                             client_buffer(buffer), attrs);
        egl_error = eglGetError();
        if (image != EGL_NO_IMAGE_KHR) {
            gl->GenTextures(1, &texture);
            gl->BindTexture(GL_TEXTURE_2D, texture);
            image_target(GL_TEXTURE_2D, image);
            gl->GenFramebuffers(1, &fb);
            gl->BindFramebuffer(GL_READ_FRAMEBUFFER, fb);
            gl->FramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                    GL_TEXTURE_2D, texture, 0);
            gl->ReadBuffer(GL_COLOR_ATTACHMENT0);
            status = gl->CheckFramebufferStatus(GL_READ_FRAMEBUFFER);
            gl->BindBuffer(GL_PIXEL_PACK_BUFFER, 0);
            gl->PixelStorei(GL_PACK_ALIGNMENT, 4);
            gl->PixelStorei(GL_PACK_ROW_LENGTH, 0);
            gl->PixelStorei(GL_PACK_SKIP_ROWS, 0);
            gl->PixelStorei(GL_PACK_SKIP_PIXELS, 0);
            setup = gl->GetError();
            if (status == GL_FRAMEBUFFER_COMPLETE && !setup) {
                bytes = (desc.width + desc.height) * 5 * 4;
                pixels = talloc_zero_size(NULL, bytes);
                gl->ReadPixels(0, desc.height/2-2, desc.width, 5, GL_RGBA,
                               GL_UNSIGNED_INT_2_10_10_10_REV, pixels);
                gl->ReadPixels(desc.width/2-2, 0, 5, desc.height, GL_RGBA,
                               GL_UNSIGNED_INT_2_10_10_10_REV, pixels + desc.width*5);
                error = gl->GetError();
            }
        }
        gl->BindFramebuffer(GL_READ_FRAMEBUFFER, read_fb);
        gl->ReadBuffer(read_buffer);
        gl->BindTexture(GL_TEXTURE_2D, binding);
        gl->BindBuffer(GL_PIXEL_PACK_BUFFER, pack);
        gl->PixelStorei(GL_PACK_ALIGNMENT, align);
        gl->PixelStorei(GL_PACK_ROW_LENGTH, row);
        gl->PixelStorei(GL_PACK_SKIP_ROWS, sy);
        gl->PixelStorei(GL_PACK_SKIP_PIXELS, sx);
        if (fb) gl->DeleteFramebuffers(1, &fb);
        if (texture) gl->DeleteTextures(1, &texture);
        if (image != EGL_NO_IMAGE_KHR) destroy_image(p->egl_display, image);
    }
    if (buffer && release) release(buffer);
    const char *temp = "/data/user/0/com.anime.konata.acceptance/cache/konata-queued-probe.tmp";
    const char *file = "/data/user/0/com.anime.konata.acceptance/cache/konata-queued-probe.bin";
    FILE *out = fopen(temp, "wb");
    if (out) {
        fprintf(out, "{\"sequence\":%u,\"abiSize\":%d,\"expectedAbiSize\":%zu,"
            "\"result\":%d,\"fencePresent\":%s,\"wait\":%d,\"width\":%u,\"height\":%u,"
            "\"format\":%u,\"usage\":%llu,\"dataspace\":%d,\"transform\":%u,"
            "\"crop\":[%d,%d,%d,%d],\"prior\":%u,\"setup\":%u,\"error\":%u,"
            "\"status\":%u,\"eglError\":%d}\n", p->probe_sequence,
            abi ? abi->version : 0, sizeof(*abi), result, fence >= 0 ? "true" : "false",
            wait_result, desc.width, desc.height, desc.format, (unsigned long long)desc.usage,
            dataspace, transform, crop.left, crop.top, crop.right, crop.bottom,
            prior, setup, error, status, egl_error);
        if (pixels && !error) fwrite(pixels, 1, bytes, out);
        fclose(out);
        rename(temp, file);
    }
    talloc_free(pixels);
}
