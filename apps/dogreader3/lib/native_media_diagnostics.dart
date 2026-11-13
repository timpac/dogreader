import 'dart:io';

import 'package:flutter/services.dart';

import 'media_diagnostics.dart';

class NativeMediaDiagnostics {
  static const _channel = MethodChannel('dogreader/media_diagnostics');

  static Future<void> start(MediaDiagnostics diagnostics) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('start');
    } catch (_) {
      diagnostics.record(MediaDiagnosticEvent.nativeObserverUnavailable);
    }
  }

  static Future<void> share(MediaDiagnostics diagnostics) async {
    if (!Platform.isAndroid) throw UnsupportedError('Android sharing required');
    await _channel.invokeMethod<void>('share', await diagnostics.export());
  }
}
