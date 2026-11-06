# CCPlayer native configuration patch

Vendored media_kit 1.2.6 retains its upstream license. Existing initialization patch exposes the isolated mpv.conf and input.conf paths with automatic script loading disabled before native initialization; see application docs/MPV_NATIVE_INTEGRATION.md.

This phase adds PlayerConfiguration.mpvRespectRenderingConfiguration, default false. When explicitly enabled, native initialization does not apply the four legacy runtime overrides correct-downscaling=no, linear-downscaling=no, sigmoid-upscaling=no and hdr-compute-peak=no. It does not change ownership of vo, surface, or other player lifecycle settings, and scripts/runtime profiles can still change options. CCPlayer only enables it with its custom decode/config choice. Real native regression verifies both legacy defaults and configured values; video integration checks initialization without deadlock. No MPV framework replacement or user configuration rewrite.

## Resource audit (2026-11-06)

In native/player/real.dart, free the UTF-8 property name on both success and missing-property returns. Leave cache-on-disk to the libmpv default or the loaded user profile. Keep the existing bounded demuxer settings. Re-run test/mpv_render_config_native_test.dart with CCPLAYER_TEST_MPV and the Windows/Android Range playback matrix when upgrading.

