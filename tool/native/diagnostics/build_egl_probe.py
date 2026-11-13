"""WSL-only isolated probe build. Restore original source and build in finally."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess

workspace = Path('/mnt/d/Codex-Projects/Konata')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--highp-sampler', action='store_true')
parser.add_argument('--stages', action='store_true')
parser.add_argument('--precise-multiplier', action='store_true')
parser.add_argument('--queued', action='store_true')
parser.add_argument('--failures', action='store_true')
parser.add_argument('--capture-gate', action='store_true')
args = parser.parse_args()
build = Path('/opt/konata-build/mpv-android-255901dd586fa750000fa0075f69d6ffdd26cd9c/buildscripts')
source = build / 'deps/mpv/video/out/opengl/context_android.c'
original = source.read_bytes()
shader = build / 'deps/mpv/video/out/gpu/shader_cache.c'
shader_original = shader.read_bytes()
ra_source = build / 'deps/mpv/video/out/opengl/ra_gl.c'
ra_original = ra_source.read_bytes()
video_source = build / 'deps/mpv/video/out/gpu/video.c'
video_original = video_source.read_bytes()
def read_fragment(name):
    directory = workspace / 'tool/native/diagnostics'
    return (directory / name).read_text().replace('#include "window_abi.h"',
                                                  (directory / 'window_abi.h').read_text())

fragment = read_fragment('egl_probe.c')
if args.capture_gate:
    fragment = fragment.replace('    struct priv *p = ctx->priv;',
        '    FILE *gate = fopen("/data/user/0/com.anime.konata.acceptance/cache/konata-egl-capture", "rb");\n'
        '    if (!gate) return;\n    fclose(gate);\n    struct priv *p = ctx->priv;', 1)
if args.queued:
    fragment += '\n' + read_fragment('queued_probe.c')
text = original.decode()
assert 'probe_sequence' not in text
# GL must remain first: MPV uses its address as the ta allocation parent.
text = text.replace('    struct GL gl;', '    struct GL gl;\n    unsigned probe_sequence;', 1)
anchor = 'static void android_swap_buffers(struct ra_ctx *ctx)'
assert text.count(anchor) == 1
text = text.replace(anchor, fragment + '\n' + anchor)
text = text.replace('    eglSwapBuffers(p->egl_display, p->egl_surface);',
                    '    konata_probe_row(ctx);\n    eglSwapBuffers(p->egl_display, p->egl_surface);')
if args.queued:
    text = text.replace('    eglSwapBuffers(p->egl_display, p->egl_surface);',
                        '    eglSwapBuffers(p->egl_display, p->egl_surface);\n    konata_probe_queued(ctx);')
if args.failures:
    # Keep the ordinary renderer and inject only at native EGL failure seams.
    text = original.decode()
    helper = read_fragment('egl_failure_probe.c')
    text = text.replace('static struct pl_color_space android_color_space', helper + '\nstatic struct pl_color_space android_color_space', 1)
    text = text.replace('    p->egl_surface = eglCreateWindowSurface',
        '    if (pq && konata_egl_fault("create")) attributes[1] = 0x7fffffff;\n    p->egl_surface = eglCreateWindowSurface', 1)
    text = text.replace('    if (p->egl_surface == EGL_NO_SURFACE)\n        return false;',
        '    if (p->egl_surface == EGL_NO_SURFACE) {\n        konata_egl_event(ctx, "create-rejected", eglGetError());\n        return false;\n    }', 1)
    text = text.replace('EGL_GL_COLORSPACE_KHR, &actual) ||',
        '(konata_egl_fault("query") ? 0x7fffffff : EGL_GL_COLORSPACE_KHR), &actual) ||', 1)
    text = text.replace('actual != EGL_GL_COLORSPACE_BT2020_PQ_EXT)\n            return false;',
        'actual != EGL_GL_COLORSPACE_BT2020_PQ_EXT || konata_egl_fault("mismatch")) {\n            konata_egl_event(ctx, "query-rejected", eglGetError());\n            return false;\n        }', 1)
    text = text.replace('                        p->egl_context))\n        return false;',
        '                        pq && konata_egl_fault("current") ? EGL_NO_CONTEXT : p->egl_context)) {\n        konata_egl_event(ctx, "current-rejected", eglGetError());\n        return false;\n    }', 1)
    text = text.replace('    p->pq = pq;', '    p->pq = pq;\n    konata_egl_event(ctx, "surface-ready", pq);', 1)
    text = text.replace('        p->pq_failed = true;', '        p->pq_failed = true;\n        konata_egl_event(ctx, "fallback", 0);', 1)
    text = text.replace('        MP_ERR(ctx, "Explicit HDR target', '        konata_egl_event(ctx, "explicit-rejected", 0);\n        MP_ERR(ctx, "Explicit HDR target', 1)
    text = text.replace('    eglSwapBuffers(p->egl_display, p->egl_surface);',
        '    eglSwapBuffers(p->egl_display, p->egl_surface);\n    konata_egl_event(ctx, "submitted", 0);', 1)
env = dict(os.environ)
ndk = build / 'sdk/android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/bin'
env['PATH'] = str(ndk) + ':/opt/konata-build/venv/bin:' + env['PATH']
output = args.output.resolve()
assert output.is_relative_to(workspace / '.dart_tool')
assert not output.exists(), 'Use a fresh isolated output, never overwrite a candidate'
try:
    source.write_text(text)
    if args.precise_multiplier:
        old = 'GLSLF("color.%s = %f * vec4(texture(texture%d, texcoord%d)).%s;\\n",'
        assert video_original.decode().count(old) == 1
        video_source.write_text(video_original.decode().replace(old, old.replace('%f', '%.9e')))
    if args.stages:
        ra_text = ra_original.decode().replace('    bool debug_enable;',
            '    unsigned konata_stage_sequence;\n    bool debug_enable;', 1)
        anchor = 'static void gl_renderpass_run(struct ra *ra,'
        assert ra_text.count(anchor) == 1
        stage_fragment = (workspace / 'tool/native/diagnostics/stage_probe.c').read_text()
        ra_text = ra_text.replace(anchor, stage_fragment + '\n' + anchor)
        anchor = '        gl->Disable(GL_SCISSOR_TEST);'
        assert ra_text.count(anchor) == 1
        ra_text = ra_text.replace(anchor, '        konata_stage_probe(ra, params);\n' + anchor)
        ra_source.write_text(ra_text)
    if args.highp_sampler:
        old = 'precision mediump sampler2D;'
        assert shader_original.decode().count(old) == 1
        shader.write_text(shader_original.decode().replace(old, 'precision highp sampler2D;'))
    subprocess.run(['ninja', '-C', str(build / 'deps/mpv/_build_arm64'), '-j2', 'libmpv.so'], env=env, check=True)
    shutil.copytree(workspace / '.dart_tool/konata-native/android', output / 'android')
    library = output / 'android/arm64-v8a/libmpv.so'
    shutil.copy2(build / 'deps/mpv/_build_arm64/libmpv.so', library)
    subprocess.run([str(ndk / 'llvm-strip'), '--strip-unneeded', str(library)], check=True)
    manifest = json.loads((workspace / '.dart_tool/konata-native/android-manifest.json').read_text())
    manifest['files']['android/arm64-v8a/libmpv.so'] = {
        'sha256': hashlib.sha256(library.read_bytes()).hexdigest(), 'bytes': library.stat().st_size}
    manifest['diagnosticOnly'] = {'probe': 'egl-before-swap',
        'highpSampler2D': args.highp_sampler,
        'stageProbe': args.stages,
        'preciseTextureMultiplier': args.precise_multiplier,
        'queuedBufferProbe': args.queued,
        'eglFailureProbe': args.failures,
        'captureGate': args.capture_gate,
        'sourceSha256': hashlib.sha256(original).hexdigest(),
        'probeSha256': hashlib.sha256((helper if args.failures else fragment).encode()).hexdigest()}
    (output / 'android-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest['files']['android/arm64-v8a/libmpv.so']), flush=True)
finally:
    source.write_bytes(original)
    shader.write_bytes(shader_original)
    ra_source.write_bytes(ra_original)
    video_source.write_bytes(video_original)
    subprocess.run(['ninja', '-C', str(build / 'deps/mpv/_build_arm64'), '-j2', 'libmpv.so'], env=env, check=True)
    assert source.read_bytes() == original
    assert shader.read_bytes() == shader_original
    assert ra_source.read_bytes() == ra_original
    assert video_source.read_bytes() == video_original
