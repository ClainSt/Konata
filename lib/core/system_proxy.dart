import 'dart:io';
import 'package:flutter/services.dart';

/// Resolve Android's current proxy per request, including PAC and exclusions.
/// The caller follows redirects explicitly so each destination is re-evaluated.
Future<void> configureSystemProxy(HttpClient client, Uri uri) async {
  if (!Platform.isAndroid) return;
  final route = await const MethodChannel(
    'ccplayer/network',
  ).invokeMethod<String>('proxy', uri.toString());
  if (route == null || route.isEmpty) {
    throw const HttpException('System proxy unavailable');
  }
  client.findProxy = (_) => route;
}
