// DIAGNOSTIC ONLY: injected into an isolated MPV build, never normal staging.
// Read the default window framebuffer before eglSwapBuffers, not PixelCopy.
// Bounded to 64 swaps and five middle rows; no timing conclusions from this build.
#include "window_abi.h"
static void konata_probe_row(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    if (++p->probe_sequence > 64)
        return;
    GL *gl = &p->gl;
    EGLint w = 0, h = 0;
    eglQuerySurface(p->egl_display, p->egl_surface, EGL_WIDTH, &w);
    eglQuerySurface(p->egl_display, p->egl_surface, EGL_HEIGHT, &h);
    if (w < 1 || w > 8192 || h < 5)
        return;
    GLint fb, buffer, align, row_length, skip_rows, skip_pixels, read_buffer;
    gl->GetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &fb);
    gl->GetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &buffer);
    gl->GetIntegerv(GL_PACK_ALIGNMENT, &align);
    gl->GetIntegerv(GL_PACK_ROW_LENGTH, &row_length);
    gl->GetIntegerv(GL_PACK_SKIP_ROWS, &skip_rows);
    gl->GetIntegerv(GL_PACK_SKIP_PIXELS, &skip_pixels);
    gl->GetIntegerv(GL_READ_BUFFER, &read_buffer);
    GLenum prior_error = gl->GetError();
    gl->BindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    gl->ReadBuffer(GL_BACK);
    gl->BindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    gl->PixelStorei(GL_PACK_ALIGNMENT, 4);
    gl->PixelStorei(GL_PACK_ROW_LENGTH, 0);
    gl->PixelStorei(GL_PACK_SKIP_ROWS, 0);
    gl->PixelStorei(GL_PACK_SKIP_PIXELS, 0);
    GLint format = 0, type = 0, bits[4] = {0};
    gl->GetIntegerv(GL_IMPLEMENTATION_COLOR_READ_FORMAT, &format);
    gl->GetIntegerv(GL_IMPLEMENTATION_COLOR_READ_TYPE, &type);
    const GLenum names[] = {GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE,
        GL_FRAMEBUFFER_ATTACHMENT_GREEN_SIZE, GL_FRAMEBUFFER_ATTACHMENT_BLUE_SIZE,
        GL_FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE};
    for (int i = 0; i < 4; i++)
        gl->GetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_BACK,
                                                names[i], &bits[i]);
    GLenum setup_error = gl->GetError();
    uint32_t *pixels = talloc_array(NULL, uint32_t, w * 5);
    gl->ReadPixels(0, h / 2 - 2, w, 5, GL_RGBA,
                   GL_UNSIGNED_INT_2_10_10_10_REV, pixels);
    GLenum error = gl->GetError();
    gl->BindBuffer(GL_PIXEL_PACK_BUFFER, buffer);
    gl->PixelStorei(GL_PACK_ALIGNMENT, align);
    gl->PixelStorei(GL_PACK_ROW_LENGTH, row_length);
    gl->PixelStorei(GL_PACK_SKIP_ROWS, skip_rows);
    gl->PixelStorei(GL_PACK_SKIP_PIXELS, skip_pixels);
    gl->BindFramebuffer(GL_READ_FRAMEBUFFER, fb);
    gl->ReadBuffer(read_buffer);
    const char *file = "/data/user/0/com.anime.konata.acceptance/cache/konata-egl-probe.bin";
    const char *temp = "/data/user/0/com.anime.konata.acceptance/cache/konata-egl-probe.tmp";
    FILE *out = fopen(temp, "wb");
    if (out) {
        EGLint color_space = 0;
        eglQuerySurface(p->egl_display, p->egl_surface, EGL_GL_COLORSPACE_KHR, &color_space);
        ANativeWindow *window = vo_android_native_window(ctx->vo);
        struct kp_window *abi = (void *)window;
        int dataspace = -1;
        if (abi && abi->magic == 0x5f776e64 && abi->version == sizeof(*abi))
            abi->query(window, 20, &dataspace);
        fprintf(out, "{\"width\":%d,\"height\":%d,\"rows\":5,"
            "\"sequence\":%u,\"format\":%d,\"type\":%d,"
            "\"bits\":[%d,%d,%d,%d],\"priorError\":%u,\"setupError\":%u,"
            "\"readError\":%u,\"pq\":%s,\"eglColor\":%d,\"dataspace\":%d,\"stage\":\"before-eglSwapBuffers\"}\n",
            w, h, p->probe_sequence, format, type, bits[0], bits[1], bits[2], bits[3],
            prior_error, setup_error, error, p->pq ? "true" : "false", color_space, dataspace);
        if (!error) fwrite(pixels, 4, w * 5, out);
        fclose(out);
        rename(temp, file);
    }
    talloc_free(pixels);
}
