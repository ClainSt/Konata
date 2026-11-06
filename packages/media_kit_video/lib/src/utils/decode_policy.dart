/// No fixed GPU backend. Software decoding leaves hardware rendering enabled.
Future<String> resolveHwdec(
    {required String fallback,
    required bool emulator,
    required String? requested,
    required bool respectConfig,
    required Future<String> Function() readConfig}) async {
  if (emulator) return 'no';
  if (requested != null) return requested;
  if (respectConfig) {
    try {
      final value = await readConfig();
      if (value.isNotEmpty) return value;
    } catch (_) {/* Use the platform's safe default. */}
  }
  return fallback;
}

/// Invalid/unavailable options must not prevent creating a video controller.
Future<bool> applyHwdec(String value, Future<void> Function(String) write,
    {Future<String> Function()? read}) async {
  try {
    await write(value);
    if (read != null) {
      final actual = await read();
      const automatic = {'auto', 'auto-safe', 'yes'};
      if (actual != value &&
          !(automatic.contains(actual) && automatic.contains(value))) {
        throw StateError('Decoding option was not applied');
      }
    }
    return false;
  } catch (_) {
    await write('no');
    if (read != null && await read() != 'no') {
      throw StateError('Software decoding could not be enabled');
    }
    return true;
  }
}
