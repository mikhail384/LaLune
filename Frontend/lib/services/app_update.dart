// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

const updateRepository = 'mikhail384/LaLune';
const _maxBytes = 2 * 1024 * 1024 * 1024;

class UpdateAsset {
  const UpdateAsset(this.tag, this.name, this.url, this.size, this.digest);
  final String tag, name, url, digest;
  final int size;
}

/// Only names published for known architectures are accepted. Never choose an
/// arbitrary APK or an OpenWrt backend when updating the client itself.
UpdateAsset selectUpdateAsset(Map<String, dynamic> release, String platform) {
  final tag = release['tag_name'];
  final names = switch (platform) {
    'android' => ['LaLune-Android-Universal.apk', 'LaLune-Android.apk'],
    'windows-x64' => ['LaLune-Windows.zip'],
    'linux-x64' => ['LaLune-Linux.zip'],
    'macos-arm64' => [
        'LaLune-macOS-arm64.dmg',
        'LaLune-macOS-arm64.zip',
        'LaLune-macOS-universal.zip'
      ],
    'macos-x64' => [
        'LaLune-macOS-x64.dmg',
        'LaLune-macOS-x64.zip',
        'LaLune-macOS-universal.zip'
      ],
    _ => <String>[],
  };
  if (tag is! String ||
      tag.isEmpty ||
      release['draft'] == true ||
      release['prerelease'] == true) {
    throw const FormatException('Некорректный стабильный релиз');
  }
  final assets = release['assets'];
  if (assets is! List) throw const FormatException('В релизе нет файлов');
  for (final name in names) {
    for (final item in assets) {
      if (item is! Map || item['name'] != name) continue;
      final url = Uri.tryParse('${item['browser_download_url']}');
      final size = item['size'];
      if (url == null ||
          url.scheme != 'https' ||
          url.host != 'github.com' ||
          !url.path.startsWith('/$updateRepository/releases/download/') ||
          url.pathSegments.last != name ||
          size is! int ||
          size <= 0 ||
          size > _maxBytes) {
        throw const FormatException('Недопустимые параметры файла обновления');
      }
      final digest = item['digest'];
      if (digest != null &&
          (digest is! String ||
              !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest))) {
        throw const FormatException('Неизвестная контрольная сумма обновления');
      }
      return UpdateAsset(
          tag, name, url.toString(), size, digest as String? ?? '');
    }
  }
  throw const FormatException(
      'Для этой системы подходящая сборка в релизе не найдена');
}

String currentUpdatePlatform() {
  if (Platform.isAndroid) return 'android';
  final abi = Abi.current();
  if (Platform.isWindows && abi == Abi.windowsX64) return 'windows-x64';
  if (Platform.isLinux && abi == Abi.linuxX64) return 'linux-x64';
  if (Platform.isMacOS && abi == Abi.macosArm64) return 'macos-arm64';
  if (Platform.isMacOS && abi == Abi.macosX64) return 'macos-x64';
  return 'unsupported';
}

class AppUpdater {
  AppUpdater({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<UpdateAsset> check() async {
    final response = await _client.get(
      Uri.https('api.github.com', '/repos/$updateRepository/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 25));
    if (response.statusCode != 200 ||
        response.bodyBytes.length > 2 * 1024 * 1024) {
      throw const FormatException('Не удалось получить сведения о релизе');
    }
    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>)
      throw const FormatException('Некорректный ответ GitHub');
    return selectUpdateAsset(data, currentUpdatePlatform());
  }

  Future<String> download(UpdateAsset asset,
      {void Function(double)? onProgress, String? directory}) async {
    final String root;
    if (directory != null) {
      root = directory;
    } else if (Platform.isAndroid) {
      root = await const MethodChannel('com.lalune/native')
              .invokeMethod<String>('getUpdateDownloadDirectory') ??
          '';
    } else {
      final home =
          Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
      root = home == null ? '' : '$home${Platform.pathSeparator}Downloads';
    }
    if (root.isEmpty)
      throw const FileSystemException('Папка загрузок недоступна');
    final targetDirectory = Directory(root);
    if (!await targetDirectory.exists())
      await targetDirectory.create(recursive: true);
    // A timestamp prevents replacing an earlier user download or partial file.
    final base = '${DateTime.now().millisecondsSinceEpoch}-${asset.name}';
    final output =
        File('${targetDirectory.path}${Platform.pathSeparator}$base');
    final partial = File('${output.path}.part');
    RandomAccessFile? sink;
    try {
      final response = await _client
          .send(http.Request('GET', Uri.parse(asset.url)))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200)
        throw HttpException('HTTP ${response.statusCode}');
      sink = await partial.open(mode: FileMode.writeOnly);
      var received = 0;
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 45))) {
        received += chunk.length;
        if (received > asset.size || received > _maxBytes)
          throw const FormatException('Размер файла превышен');
        await sink.writeFrom(chunk);
        onProgress?.call(received / asset.size);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (received != asset.size)
        throw const FormatException('Файл загружен не полностью');
      if (asset.digest.isNotEmpty) {
        final digest = await sha256.bind(partial.openRead()).first;
        if (digest.toString() != asset.digest.substring(7).toLowerCase()) {
          throw const FormatException('Контрольная сумма файла не совпала');
        }
      }
      await partial.rename(output.path);
      return output.path;
    } catch (_) {
      await sink?.close();
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  void dispose() => _client.close();
}
