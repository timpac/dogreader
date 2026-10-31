import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class ThemePreferences extends ChangeNotifier {
  ThemePreferences({Future<File> Function()? preferencesFile})
      : _preferencesFile = preferencesFile ?? _defaultFile;

  final Future<File> Function() _preferencesFile;
  ThemeMode _mode = ThemeMode.light;
  Future<void> _pendingWrite = Future<void>.value();

  ThemeMode get mode => _mode;

  static Future<File> _defaultFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/appearance.json');
  }

  Future<void> load() async {
    try {
      final file = await _preferencesFile();
      final data = jsonDecode(await file.readAsString());
      _mode = data is Map && data['theme'] == 'dark'
          ? ThemeMode.dark : ThemeMode.light;
    } catch (_) {
      // Missing or unreadable preferences must never prevent opening a book.
      _mode = ThemeMode.light;
    }
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) {
    if (mode == ThemeMode.system) {
      throw ArgumentError.value(mode, 'mode', 'Choose light or dark');
    }
    _mode = mode;
    notifyListeners();
    final snapshot = jsonEncode({'theme': mode.name});
    _pendingWrite = _pendingWrite.catchError((Object _) {}).then((_) async {
      final file = await _preferencesFile();
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      await temporary.rename(file.path);
    });
    return _pendingWrite;
  }
}
