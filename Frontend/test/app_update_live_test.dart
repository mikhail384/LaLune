import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/services/app_update.dart';

void main() {
  test('downloads the current published package from GitHub', () async {
    final updater = AppUpdater();
    final directory =
        await Directory.systemTemp.createTemp('lalune-update-live-');
    try {
      final asset = await updater.check();
      expect(asset.name, 'LaLune-Windows.zip');
      final path = await updater.download(asset, directory: directory.path);
      expect(await File(path).length(), asset.size);
    } finally {
      updater.dispose();
      await directory.delete(recursive: true);
    }
  },
      skip: Platform.environment['LALUNE_LIVE_UPDATE_TEST'] != '1',
      timeout: const Timeout(Duration(minutes: 5)));
}
