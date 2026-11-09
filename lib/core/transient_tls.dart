import 'dart:io';

/// One new handshake for a connection interrupted before an HTTP response.
/// Never retries certificate rejection, HTTP statuses, timeouts or body errors.
Future<T> retryInterruptedTls<T>(Future<T> Function() open) async {
  try {
    return await open();
  } on HandshakeException catch (error) {
    if (!error.message.toLowerCase().contains(
      'connection terminated during handshake',
    )) {
      rethrow;
    }
    return open();
  }
}
