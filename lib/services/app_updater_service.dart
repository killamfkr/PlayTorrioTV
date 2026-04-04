import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class AppUpdaterService {
  static const String currentVersion = '1.0.0';
  static const String _repo = 'ayman708-UX/PlayTorrioTV';
  static const String _apiUrl =
      'https://api.github.com/repos/$_repo/releases/latest';

  /// Check GitHub for a newer release. Returns null if up-to-date.
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final res = await http
          .get(Uri.parse(_apiUrl), headers: {'Accept': 'application/vnd.github.v3+json'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String?)?.replaceFirst('v', '') ?? '';
      if (tag.isEmpty || !_isNewer(currentVersion, tag)) return null;

      // Find the right APK for this device's ABI
      String? apkUrl;
      final assets = data['assets'] as List? ?? [];

      if (Platform.isAndroid) {
        final abis = await _getDeviceAbis();
        // Try to match an APK containing the device's primary ABI in its filename
        for (final abi in abis) {
          final normalized = abi.replaceAll('-', '_'); // arm64-v8a -> arm64_v8a
          for (final a in assets) {
            final name = ((a['name'] as String?) ?? '').toLowerCase();
            if (name.endsWith('.apk') &&
                (name.contains(abi) || name.contains(normalized))) {
              apkUrl = a['browser_download_url'] as String?;
              break;
            }
          }
          if (apkUrl != null) break;
        }
        // Fallback: grab the first APK (universal build)
        if (apkUrl == null) {
          for (final a in assets) {
            final name = ((a['name'] as String?) ?? '').toLowerCase();
            if (name.endsWith('.apk')) {
              apkUrl = a['browser_download_url'] as String?;
              break;
            }
          }
        }
      }

      return UpdateInfo(
        latestVersion: tag,
        releaseNotes: (data['body'] as String?) ?? '',
        apkUrl: apkUrl,
        htmlUrl: data['html_url'] as String? ?? '',
      );
    } catch (e) {
      debugPrint('Update check failed: $e');
      return null;
    }
  }

  /// Download the APK with progress callback. Returns the local file path.
  static Future<String> downloadApk(
    String url,
    String version, {
    void Function(double progress)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/PlayTorrioTV_$version.apk');

    final request = http.Request('GET', Uri.parse(url));
    final response = await request.send();
    final total = response.contentLength ?? 0;
    int received = 0;

    final sink = file.openWrite();
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress?.call(received / total);
    }
    await sink.close();

    return file.path;
  }

  static Future<List<String>> _getDeviceAbis() async {
    try {
      const channel = MethodChannel('com.playtorrio/updater');
      final result = await channel.invokeMethod('getDeviceAbi');
      return (result as List).cast<String>();
    } catch (_) {
      return ['arm64-v8a']; // safe default
    }
  }

  static bool _isNewer(String current, String latest) {
    final c = current.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final l = latest.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (int i = 0; i < 3; i++) {
      final cv = i < c.length ? c[i] : 0;
      final lv = i < l.length ? l[i] : 0;
      if (lv > cv) return true;
      if (lv < cv) return false;
    }
    return false;
  }
}

class UpdateInfo {
  final String latestVersion;
  final String releaseNotes;
  final String? apkUrl;
  final String htmlUrl;

  const UpdateInfo({
    required this.latestVersion,
    required this.releaseNotes,
    required this.apkUrl,
    required this.htmlUrl,
  });
}
