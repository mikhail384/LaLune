import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lalune/services/app_update.dart';

Map<String, dynamic> release(List<Map<String, dynamic>> assets) => {
      'tag_name': '0.9.13',
      'draft': false,
      'prerelease': false,
      'assets': assets,
    };
Map<String, dynamic> asset(String name, {String? url}) => {
      'name': name,
      'size': 3,
      'browser_download_url': url ??
          'https://github.com/mikhail384/LaLune/releases/download/0.9.13/$name',
    };

void main() {
  test('selects the correct client asset and rejects unsupported platforms',
      () {
    final r =
        release([asset('LaLune-Windows.zip'), asset('LaLune-Android.apk')]);
    expect(selectUpdateAsset(r, 'android').name, 'LaLune-Android.apk');
    expect(selectUpdateAsset(r, 'windows-x64').name, 'LaLune-Windows.zip');
    expect(() => selectUpdateAsset(r, 'linux-arm64'), throwsFormatException);
  });
  test('rejects untrusted URLs and prereleases', () {
    final r = release(
        [asset('LaLune-Android.apk', url: 'https://example.com/app.apk')]);
    expect(() => selectUpdateAsset(r, 'android'), throwsFormatException);
    expect(() => selectUpdateAsset({...r, 'prerelease': true}, 'android'),
        throwsFormatException);
  });
  test('downloads and verifies size and SHA256, removes incomplete files',
      () async {
    final dir = await Directory.systemTemp.createTemp('lalune-update-test-');
    final updater =
        AppUpdater(client: MockClient((_) async => http.Response('abc', 200)));
    try {
      final item = UpdateAsset(
          'v1',
          'LaLune-Android.apk',
          'https://github.com/test',
          3,
          'sha256:${sha256.convert([97, 98, 99])}');
      final path = await updater.download(item, directory: dir.path);
      expect(await File(path).readAsString(), 'abc');
      await expectLater(
          updater.download(
              UpdateAsset('v1', 'bad.apk', 'https://github.com/test', 4, ''),
              directory: dir.path),
          throwsFormatException);
      expect(await dir.list().where((f) => f.path.endsWith('.part')).isEmpty,
          isTrue);
      await expectLater(
          updater.download(
              UpdateAsset('v1', 'bad.apk', 'https://github.com/test', 3,
                  'sha256:${'0' * 64}'),
              directory: dir.path),
          throwsFormatException);
    } finally {
      updater.dispose();
      await dir.delete(recursive: true);
    }
  });
}
