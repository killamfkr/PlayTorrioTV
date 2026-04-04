import 'dart:convert';
import 'package:http/http.dart' as http;
import 'settings_service.dart';
import 'stream_service.dart';

class DebridService {
  static const _rdBase = 'https://api.real-debrid.com/rest/1.0';
  static const _tbBase = 'https://api.torbox.app/v1/api';

  /// Resolves a magnet URI to a direct HTTP stream URL via the configured debrid provider.
  /// Returns the direct download/stream URL.
  static Future<String> resolve(String magnetUri, {EpisodeTarget? episode, int? fileIdx}) async {
    final settings = SettingsService.instance;
    if (settings.debridProvider == 'torbox') {
      return _resolveTorbox(magnetUri, settings.torboxApiKey, episode: episode, fileIdx: fileIdx);
    } else {
      return _resolveRealDebrid(magnetUri, settings.realDebridApiKey, episode: episode, fileIdx: fileIdx);
    }
  }

  // ── Real-Debrid ──────────────────────────────────────────────

  static Future<String> _resolveRealDebrid(String magnetUri, String apiKey, {EpisodeTarget? episode, int? fileIdx}) async {
    final headers = {'Authorization': 'Bearer $apiKey'};

    // 1. Add magnet
    final addRes = await http.post(
      Uri.parse('$_rdBase/torrents/addMagnet'),
      headers: headers,
      body: {'magnet': magnetUri},
    );
    if (addRes.statusCode != 201 && addRes.statusCode != 200) {
      throw DebridException('RD addMagnet failed: ${addRes.statusCode} ${addRes.body}');
    }
    final addData = jsonDecode(addRes.body) as Map<String, dynamic>;
    final torrentId = addData['id'] as String;

    // 2. Get torrent info to find files, then select the right one
    final filesInfoRes = await http.get(
      Uri.parse('$_rdBase/torrents/info/$torrentId'),
      headers: headers,
    );
    String selectedFileIds = 'all';
    if (filesInfoRes.statusCode == 200) {
      final filesInfo = jsonDecode(filesInfoRes.body) as Map<String, dynamic>;
      final rdFiles = (filesInfo['files'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final matchedId = _rdMatchFile(rdFiles, episode: episode, fileIdx: fileIdx);
      if (matchedId != null) {
        selectedFileIds = matchedId.toString();
      }
    }
    await http.post(
      Uri.parse('$_rdBase/torrents/selectFiles/$torrentId'),
      headers: headers,
      body: {'files': selectedFileIds},
    );

    // 3. Wait for torrent to be ready and get links
    String? downloadLink;
    for (int i = 0; i < 30; i++) {
      final infoRes = await http.get(
        Uri.parse('$_rdBase/torrents/info/$torrentId'),
        headers: headers,
      );
      if (infoRes.statusCode != 200) {
        throw DebridException('RD torrent info failed: ${infoRes.statusCode}');
      }
      final info = jsonDecode(infoRes.body) as Map<String, dynamic>;
      final status = info['status'] as String;

      if (status == 'downloaded') {
        final links = (info['links'] as List).cast<String>();
        if (links.isEmpty) throw DebridException('RD: no links available');

        if (links.length == 1) {
          // Only one file was selected — unrestrict it directly
          final res = await http.post(
            Uri.parse('$_rdBase/unrestrict/link'),
            headers: headers,
            body: {'link': links.first},
          );
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body) as Map<String, dynamic>;
            downloadLink = data['download'] as String?;
          }
        } else {
          downloadLink = await _rdUnrestrictBestVideo(links, headers);
        }
        break;
      } else if (status == 'magnet_error' || status == 'error' || status == 'virus' || status == 'dead') {
        throw DebridException('RD torrent error: $status');
      }

      await Future.delayed(const Duration(seconds: 2));
    }

    if (downloadLink == null) {
      throw DebridException('RD: torrent not ready after waiting');
    }

    return downloadLink;
  }

  static Future<String> _rdUnrestrictBestVideo(List<String> links, Map<String, String> headers) async {
    String? bestUrl;
    int bestSize = 0;

    for (final link in links) {
      final res = await http.post(
        Uri.parse('$_rdBase/unrestrict/link'),
        headers: headers,
        body: {'link': link},
      );
      if (res.statusCode != 200) continue;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final mimeType = (data['mimeType'] ?? '') as String;
      if (!mimeType.startsWith('video/')) continue;

      final size = (data['filesize'] ?? 0) as int;
      final dl = data['download'] as String?;
      if (dl != null && size > bestSize) {
        bestSize = size;
        bestUrl = dl;
      }
    }

    // If no video mime detected, just unrestrict the first link
    if (bestUrl == null && links.isNotEmpty) {
      final res = await http.post(
        Uri.parse('$_rdBase/unrestrict/link'),
        headers: headers,
        body: {'link': links.first},
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        bestUrl = data['download'] as String?;
      }
    }

    if (bestUrl == null) throw DebridException('RD: failed to unrestrict any link');
    return bestUrl;
  }

  /// Match the right file ID from RD's file list.
  static int? _rdMatchFile(List<Map<String, dynamic>> files, {EpisodeTarget? episode, int? fileIdx}) {
    // Filter to video files only
    final videoFiles = files.where((f) {
      final path = (f['path'] ?? '') as String;
      return _isVideoFile(path);
    }).toList();

    // 1. Episode match by S##E## in filename
    if (episode != null) {
      for (final f in videoFiles) {
        final path = (f['path'] ?? '') as String;
        if (_isEpisodeMatch(path, episode.season, episode.episode)) {
          return f['id'] as int;
        }
      }
    }

    // 2. Preferred file index
    if (fileIdx != null) {
      // RD file IDs are 1-based; fileIdx from the torrent may be 0-based
      for (final f in files) {
        final id = f['id'] as int;
        if (id == fileIdx || id == fileIdx + 1) {
          return id;
        }
      }
    }

    // 3. Largest video — return null to select all and let unrestrict pick
    return null;
  }

  static bool _isEpisodeMatch(String name, int season, int episode) {
    final t = name.toLowerCase();
    if (RegExp('s0*$season[ ._-]*e0*$episode\\b', caseSensitive: false).hasMatch(t)) return true;
    if (RegExp('\\b0*${season}x0*$episode\\b', caseSensitive: false).hasMatch(t)) return true;
    return false;
  }

  // ── TorBox ───────────────────────────────────────────────────

  static Future<String> _resolveTorbox(String magnetUri, String apiKey, {EpisodeTarget? episode, int? fileIdx}) async {
    final headers = {'Authorization': 'Bearer $apiKey'};

    // 1. Create torrent from magnet
    final createReq = http.MultipartRequest('POST', Uri.parse('$_tbBase/torrents/createtorrent'));
    createReq.headers.addAll(headers);
    createReq.fields['magnet'] = magnetUri;
    final createStreamedRes = await createReq.send();
    final createRes = await http.Response.fromStream(createStreamedRes);

    if (createRes.statusCode != 200) {
      throw DebridException('TB createTorrent failed: ${createRes.statusCode} ${createRes.body}');
    }
    final createData = jsonDecode(createRes.body) as Map<String, dynamic>;
    final torrentId = (createData['data'] as Map<String, dynamic>)['torrent_id'] as int;

    // 2. Wait for torrent to be ready
    int? bestFileId;
    for (int i = 0; i < 30; i++) {
      final listRes = await http.get(
        Uri.parse('$_tbBase/torrents/mylist?id=$torrentId'),
        headers: headers,
      );
      if (listRes.statusCode != 200) {
        throw DebridException('TB mylist failed: ${listRes.statusCode}');
      }
      final listData = jsonDecode(listRes.body) as Map<String, dynamic>;
      final data = listData['data'] as dynamic;

      // data can be a single torrent object or list
      Map<String, dynamic>? torrent;
      if (data is List && data.isNotEmpty) {
        torrent = data.first as Map<String, dynamic>;
      } else if (data is Map<String, dynamic>) {
        torrent = data;
      }

      if (torrent == null) {
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }

      final downloadFinished = torrent['download_finished'] as bool? ?? false;
      if (downloadFinished) {
        final files = (torrent['files'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        final videoFiles = files.where((f) => _isVideoFile((f['name'] ?? '') as String)).toList();

        // 1. Episode match by S##E##
        if (episode != null) {
          for (final f in videoFiles) {
            final name = (f['name'] ?? '') as String;
            if (_isEpisodeMatch(name, episode.season, episode.episode)) {
              bestFileId = f['id'] as int;
              break;
            }
          }
        }

        // 2. Preferred file index
        if (bestFileId == null && fileIdx != null) {
          for (final f in files) {
            final id = f['id'] as int;
            if (id == fileIdx || id == fileIdx + 1) {
              bestFileId = id;
              break;
            }
          }
        }

        // 3. Largest video fallback
        if (bestFileId == null) {
          int bestSize = 0;
          for (final f in videoFiles) {
            final size = (f['size'] ?? 0) as int;
            if (size > bestSize) {
              bestSize = size;
              bestFileId = f['id'] as int;
            }
          }
        }

        bestFileId ??= files.isNotEmpty ? (files.first['id'] as int) : 0;
        break;
      }

      await Future.delayed(const Duration(seconds: 2));
    }

    if (bestFileId == null) {
      throw DebridException('TB: torrent not ready after waiting');
    }

    // 3. Request download link
    final dlRes = await http.get(
      Uri.parse('$_tbBase/torrents/requestdl?token=$apiKey&torrent_id=$torrentId&file_id=$bestFileId'),
    );
    if (dlRes.statusCode != 200) {
      throw DebridException('TB requestdl failed: ${dlRes.statusCode} ${dlRes.body}');
    }
    final dlData = jsonDecode(dlRes.body) as Map<String, dynamic>;
    final downloadUrl = dlData['data'] as String?;
    if (downloadUrl == null || downloadUrl.isEmpty) {
      throw DebridException('TB: no download URL returned');
    }

    return downloadUrl;
  }

  static bool _isVideoFile(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.mkv') || lower.endsWith('.mp4') || lower.endsWith('.avi') ||
        lower.endsWith('.mov') || lower.endsWith('.wmv') || lower.endsWith('.flv') ||
        lower.endsWith('.m4v') || lower.endsWith('.ts');
  }
}

class DebridException implements Exception {
  final String message;
  DebridException(this.message);
  @override
  String toString() => 'DebridException: $message';
}
