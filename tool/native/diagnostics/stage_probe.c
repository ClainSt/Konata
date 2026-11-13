// DIAGNOSTIC ONLY. Injected into ra_gl.c; bounded to 192 raster passes.
#include <sys/stat.h>
#define KP_DIR "/data/user/0/com.anime.konata.acceptance/cache/konata-stages"
static void konata_stage_read(struct ra *ra, struct ra_tex *tex,
                              unsigned program, const char *name, unsigned seq)
{
    GL *gl = ra_gl_get(ra);
    struct ra_tex_gl *t = tex->priv;
    int w = tex->params.w, h = tex->params.h;
    if (w < 1 || w > 8192 || h < 1 || t->target == GL_TEXTURE_EXTERNAL_OES)
        return;
    GLint fb, pack, align, row, sy, sx, read;
    gl->GetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &fb);
    gl->GetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pack);
    gl->GetIntegerv(GL_PACK_ALIGNMENT, &align);
    gl->GetIntegerv(GL_PACK_ROW_LENGTH, &row);
    gl->GetIntegerv(GL_PACK_SKIP_ROWS, &sy);
    gl->GetIntegerv(GL_PACK_SKIP_PIXELS, &sx);
    gl->GetIntegerv(GL_READ_BUFFER, &read);
    GLenum prior = gl->GetError();
    GLuint temp = 0;
    if (t->texture) {
        gl->GenFramebuffers(1, &temp);
        gl->BindFramebuffer(GL_READ_FRAMEBUFFER, temp);
        gl->FramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                t->target, t->texture, 0);
    } else {
        gl->BindFramebuffer(GL_READ_FRAMEBUFFER, t->fbo);
    }
    gl->ReadBuffer(t->texture || t->fbo ? GL_COLOR_ATTACHMENT0 : GL_BACK);
    GLenum status = gl->CheckFramebufferStatus(GL_READ_FRAMEBUFFER);
    gl->BindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    gl->PixelStorei(GL_PACK_ALIGNMENT, 4);
    gl->PixelStorei(GL_PACK_ROW_LENGTH, 0);
    gl->PixelStorei(GL_PACK_SKIP_ROWS, 0);
    gl->PixelStorei(GL_PACK_SKIP_PIXELS, 0);
    bool integer = tex->params.format->ctype == RA_CTYPE_UINT;
    bool window = !t->texture && !t->fbo;
    GLenum fmt = integer ? GL_RGBA_INTEGER : GL_RGBA;
    GLenum type = integer ? GL_UNSIGNED_INT : window ? GL_UNSIGNED_INT_2_10_10_10_REV : GL_FLOAT;
    unsigned size = w * (window ? 4 : 16);
    void *pixels = talloc_zero_size(NULL, size);
    GLenum setup = gl->GetError();
    if (status == GL_FRAMEBUFFER_COMPLETE)
        gl->ReadPixels(0, h / 2, w, 1, fmt, type, pixels);
    GLenum error = gl->GetError();
    gl->BindFramebuffer(GL_READ_FRAMEBUFFER, fb);
    gl->ReadBuffer(read);
    if (temp) gl->DeleteFramebuffers(1, &temp);
    gl->BindBuffer(GL_PIXEL_PACK_BUFFER, pack);
    gl->PixelStorei(GL_PACK_ALIGNMENT, align);
    gl->PixelStorei(GL_PACK_ROW_LENGTH, row);
    gl->PixelStorei(GL_PACK_SKIP_ROWS, sy);
    gl->PixelStorei(GL_PACK_SKIP_PIXELS, sx);
    char path[256];
    snprintf(path, sizeof(path), KP_DIR "/p%u-%s.bin", program, name);
    FILE *f = fopen(path, "wb");
    if (f) {
        fprintf(f, "{\"seq\":%u,\"width\":%d,\"height\":%d,\"format\":\"%s\","
            "\"type\":%u,\"prior\":%u,\"setup\":%u,\"error\":%u,\"status\":%u}\n",
            seq, w, h, tex->params.format->name, type, prior, setup, error, status);
        if (!error && !setup && status == GL_FRAMEBUFFER_COMPLETE)
            fwrite(pixels, 1, size, f);
        fclose(f);
    }
    talloc_free(pixels);
}

static void konata_stage_probe(struct ra *ra,
                               const struct ra_renderpass_run_params *params)
{
    struct ra_gl *r = ra->priv;
    unsigned seq = ++r->konata_stage_sequence;
    if (seq > 192) return;
    mkdir(KP_DIR, 0700);
    struct ra_renderpass *pass = params->pass;
    struct ra_renderpass_gl *p = pass->priv;
    char path[256];
    snprintf(path, sizeof(path), KP_DIR "/p%u.frag", p->program);
    FILE *f = fopen(path, "wb");
    if (f) { fputs(pass->params.frag_shader, f); fclose(f); }
    snprintf(path, sizeof(path), KP_DIR "/p%u-uniforms.txt", p->program);
    f = fopen(path, "a");
    for (int n = 0; n < params->num_values; n++) {
        struct ra_renderpass_input_val *v = &params->values[n];
        struct ra_renderpass_input *in = &pass->params.inputs[v->index];
        if (in->type == RA_VARTYPE_TEX) {
            konata_stage_read(ra, *(struct ra_tex **)v->data, p->program, in->name, seq);
        } else if (in->type == RA_VARTYPE_FLOAT && f) {
            fprintf(f, "%u %s", seq, in->name);
            for (int j = 0; j < in->dim_v * in->dim_m; j++)
                fprintf(f, " %.9g", ((float *)v->data)[j]);
            fputc('\n', f);
        }
    }
    if (f) fclose(f);
    konata_stage_read(ra, params->target, p->program, "output", seq);
}
