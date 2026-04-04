import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'settings_service.dart';

class EpisodeTarget {
  final int season;
  final int episode;
  const EpisodeTarget({required this.season, required this.episode});
}

class StreamResult {
  final String url;
  final String hash;
  final int fileIdx;
  final String fileName;
  final int fileSize;

  const StreamResult({
    required this.url,
    required this.hash,
    required this.fileIdx,
    required this.fileName,
    required this.fileSize,
  });
}

class TorrentStats {
  final double speedMbps;
  final int activePeers;
  final int totalPeers;
  final int loadedBytes;
  final int totalBytes;

  const TorrentStats({
    required this.speedMbps,
    required this.activePeers,
    required this.totalPeers,
    required this.loadedBytes,
    required this.totalBytes,
  });
}

/// Manages TorrServer engine (native subprocess) via its HTTP API.
class StreamService {
  static const _channel = MethodChannel('com.playtorrio/torrserver');
  static const int _port = 8090;
  static bool _started = false;
  static bool _configured = false;

  static String get _baseUrl => 'http://127.0.0.1:$_port';

  static const Map<String, String> _jsonHeaders = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  // Live-fetched trackers (populated on app launch)
  static List<String> _trackers = [];
  static List<String> get trackers => List.unmodifiable(_trackers);

  static const String _trackersUrl =
      'https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt';

  // Fallback trackers in case the fetch fails
  static const List<String> _fallbackTrackers = [
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://open.stealth.si:80/announce',
    'udp://exodus.desync.com:6969/announce',
    'udp://tracker.torrent.eu.org:451/announce',
    'udp://tracker.openbittorrent.com:6969/announce',
  ];

  /// Call on app launch to start TorrServer, configure it, and fetch trackers.
  /// Fire-and-forget — won't block the UI.
  static Future<void> warmup() async {
    // Fetch trackers and start server in parallel
    await Future.wait([
      _fetchTrackers(),
      ensureInitialized(),
    ].map((f) => f.catchError((_) {})));
  }

  /// Start TorrServer if not already running.
  static Future<void> ensureInitialized() async {
    if (_started) return;

    // Check if already running
    if (await _isEchoAlive()) {
      _started = true;
      if (!_configured) await _configureServer();
      return;
    }

    final port = await _channel.invokeMethod<int>('start', {'port': _port});
    if (port == null) throw Exception('Failed to start TorrServer');
    _started = true;

    // Wait for /echo endpoint
    final ready = await _waitForEcho(timeout: const Duration(seconds: 30));
    if (!ready) throw Exception('TorrServer did not respond in time');

    await _configureServer();
  }

  /// Fetch the latest tracker list from GitHub.
  static Future<void> _fetchTrackers() async {
    try {
      final resp = await http.get(Uri.parse(_trackersUrl))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final lines = resp.body
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
        if (lines.isNotEmpty) {
          _trackers = lines;
          debugPrint('[TorrServer] Fetched ${lines.length} trackers');
          return;
        }
      }
    } catch (e) {
      debugPrint('[TorrServer] Tracker fetch failed: $e');
    }
    // Use fallback if fetch failed
    if (_trackers.isEmpty) {
      _trackers = List.from(_fallbackTrackers);
      debugPrint('[TorrServer] Using ${_fallbackTrackers.length} fallback trackers');
    }
  }

  static Future<bool> _isEchoAlive() async {
    try {
      final resp = await http.get(Uri.parse('$_baseUrl/echo'))
          .timeout(const Duration(milliseconds: 800));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _waitForEcho({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _isEchoAlive()) return true;
      await Future.delayed(const Duration(milliseconds: 150));
    }
    return false;
  }

  /// Apply optimized streaming configuration to TorrServer.
  static Future<void> _configureServer() async {
    final settingsUri = Uri.parse('$_baseUrl/settings');
    try {
      Map<String, dynamic> current = {};
      try {
        final getResp = await http.post(
          settingsUri,
          headers: _jsonHeaders,
          body: jsonEncode({'action': 'get'}),
        ).timeout(const Duration(seconds: 5));
        if (getResp.statusCode == 200 && getResp.body.isNotEmpty) {
          current = jsonDecode(getResp.body) as Map<String, dynamic>;
        }
      } catch (_) {}

      // Cache: use user-configured RAM size
      final cacheMB = SettingsService.instance.cacheSizeMB;
      current['CacheSize'] = cacheMB * 1024 * 1024;
      current['UseDisk'] = false;
      current['RemoveCacheOnDrop'] = false;

      // Preload: 2% of cache (~10MB) before playback starts
      current['PreloadCache'] = 2;
      current['ReaderReadAHead'] = 95;

      // CRITICAL: prioritize pieces near reader position
      current['ResponsiveMode'] = true;

      // Fastest piece request strategy
      current['Strategy'] = 2;

      // Connections
      current['ConnectionsLimit'] = 200;
      current['DhtConnectionLimit'] = 0;
      current['PeersListenPort'] = 0;

      // Protocols
      current['DisableTCP'] = false;
      current['DisableUTP'] = false;
      current['DisableDHT'] = false;
      current['DisablePEX'] = false;
      current['EnableIPv6'] = false;
      current['DisableUPNP'] = false;

      // Leech mode — all bandwidth to download
      current['DisableUpload'] = true;
      current['DownloadRateLimit'] = 0;
      current['UploadRateLimit'] = 0;

      // Trackers
      current['RetrackersMode'] = 1;

      current['ForceEncrypt'] = false;
      current['TorrentDisconnectTimeout'] = 86400;
      current['EnableDLNA'] = false;
      current['EnableDebug'] = false;

      await http.post(
        settingsUri,
        headers: _jsonHeaders,
        body: jsonEncode({'action': 'set', 'sets': current}),
      ).timeout(const Duration(seconds: 8));

      _configured = true;
      debugPrint('[TorrServer] Configuration applied');
    } catch (e) {
      debugPrint('[TorrServer] Configuration error (non-fatal): $e');
    }
  }

  /// Boost a magnet link with additional trackers.
  static String _boostMagnet(String magnet) {
    final existingTrackers = <String>{};
    final uri = Uri.tryParse(magnet);
    if (uri != null) {
      for (final tr in uri.queryParametersAll['tr'] ?? []) {
        existingTrackers.add(Uri.decodeComponent(tr));
      }
    }

    final buffer = StringBuffer(magnet);
    for (final tracker in _trackers) {
      if (!existingTrackers.contains(tracker)) {
        buffer.write('&tr=${Uri.encodeComponent(tracker)}');
      }
    }
    return buffer.toString();
  }

  /// Extract info-hash from a magnet URI or bare hash.
  static String? _extractHash(String magnetOrHash) {
    if (RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(magnetOrHash) ||
        RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(magnetOrHash)) {
      return magnetOrHash.toLowerCase();
    }
    if (magnetOrHash.startsWith('magnet:?')) {
      final uri = Uri.tryParse(magnetOrHash);
      final xt = uri?.queryParameters['xt'] ?? '';
      if (xt.startsWith('urn:btih:')) {
        return xt.substring('urn:btih:'.length).toLowerCase();
      }
    }
    return null;
  }

  /// Add a magnet and start streaming the appropriate file.
  static Future<StreamResult> startStreaming(
    String magnetUri, {
    EpisodeTarget? episode,
    int? fileIdx,
  }) async {
    await ensureInitialized();

    final hash = _extractHash(magnetUri);
    if (hash == null) throw Exception('Cannot extract info-hash from magnet');

    final boostedMagnet = _boostMagnet(magnetUri);
    final torrentsUri = Uri.parse('$_baseUrl/torrents');

    // Step 1: Add torrent
    await _addTorrentWithRetry(torrentsUri, boostedMagnet, hash);

    // Step 2: Poll for metadata and select video file
    final fileInfo = await _resolveFileIndex(
      torrentsUri: torrentsUri,
      hash: hash,
      season: episode?.season,
      episode: episode?.episode,
      preferredIdx: fileIdx,
    );
    if (fileInfo == null) throw Exception('No video file found in torrent');

    // Step 3: Build stream URL
    final encodedFilename = Uri.encodeComponent(fileInfo.filename);
    final streamUrl = '$_baseUrl/stream/$encodedFilename?link=$hash&index=${fileInfo.index}&play';
    debugPrint('[TorrServer] Stream URL: $streamUrl');

    return StreamResult(
      url: streamUrl,
      hash: hash,
      fileIdx: fileInfo.index,
      fileName: fileInfo.filename,
      fileSize: fileInfo.size,
    );
  }

  static Future<void> _addTorrentWithRetry(
    Uri torrentsUri, String magnet, String hash,
  ) async {
    // Check if already exists
    if (await _torrentExists(torrentsUri, hash)) return;

    for (int attempt = 0; attempt < 6; attempt++) {
      try {
        final response = await http.post(
          torrentsUri,
          headers: _jsonHeaders,
          body: jsonEncode({
            'action': 'add',
            'link': magnet,
            'save_to_db': false,
          }),
        ).timeout(const Duration(seconds: 8));

        if (response.body.contains('BT client not connected')) {
          debugPrint('[TorrServer] BT client not connected, retrying...');
          await Future.delayed(Duration(milliseconds: 500 * (1 << attempt.clamp(0, 4))));
          continue;
        }

        if (response.statusCode == 200) return;

        if (response.statusCode == 400 && await _torrentExists(torrentsUri, hash)) return;
      } catch (e) {
        debugPrint('[TorrServer] Add attempt $attempt error: $e');
      }
      await Future.delayed(Duration(milliseconds: 500 * (1 << attempt.clamp(0, 4))));
    }
    throw Exception('Failed to add torrent after retries');
  }

  static Future<bool> _torrentExists(Uri torrentsUri, String hash) async {
    try {
      final resp = await http.post(
        torrentsUri,
        headers: _jsonHeaders,
        body: jsonEncode({'action': 'get', 'hash': hash}),
      ).timeout(const Duration(seconds: 4));
      return resp.statusCode == 200 && resp.body.isNotEmpty && !resp.body.contains('null');
    } catch (_) {
      return false;
    }
  }

  static Future<({int index, String filename, int size})?> _resolveFileIndex({
    required Uri torrentsUri,
    required String hash,
    int? season,
    int? episode,
    int? preferredIdx,
  }) async {
    const pollInterval = Duration(milliseconds: 250);
    final deadline = DateTime.now().add(const Duration(seconds: 30));

    while (DateTime.now().isBefore(deadline)) {
      try {
        final resp = await http.post(
          torrentsUri,
          headers: _jsonHeaders,
          body: jsonEncode({'action': 'get', 'hash': hash}),
        ).timeout(const Duration(seconds: 4));

        if (resp.statusCode != 200) {
          await Future.delayed(pollInterval);
          continue;
        }

        final data = jsonDecode(resp.body) as Map<String, dynamic>?;
        if (data == null) {
          await Future.delayed(pollInterval);
          continue;
        }

        final rawFiles = (data['file_stats'] ?? data['files']) as List<dynamic>?;
        if (rawFiles == null || rawFiles.isEmpty) {
          await Future.delayed(pollInterval);
          continue;
        }

        final files = rawFiles.cast<Map<String, dynamic>>();

        // File selection
        int? bestIdx;
        String? bestName;
        int bestSize = -1;
        int? largestIdx;
        String? largestName;
        int largestSize = -1;

        for (final f in files) {
          final name = (f['path'] ?? f['name'] ?? '') as String;
          final size = (f['length'] ?? 0) as int;
          final id = f['id'] as int;

          if (!_isVideoFile(name)) continue;

          // Episode match
          if (season != null && episode != null && _isEpisodeMatch(name, season, episode)) {
            if (size > bestSize) {
              bestSize = size;
              bestIdx = id;
              bestName = name;
            }
          }

          // Track largest video
          if (size > largestSize) {
            largestSize = size;
            largestIdx = id;
            largestName = name;
          }
        }

        // Priority: episode match > preferred > largest
        int? selectedIdx = bestIdx;
        String? selectedName = bestName;
        int selectedSize = bestSize;

        if (selectedIdx == null && preferredIdx != null) {
          final match = files.where((f) =>
              f['id'] == preferredIdx && _isVideoFile((f['path'] ?? f['name'] ?? '') as String)
          ).toList();
          if (match.isNotEmpty) {
            selectedIdx = preferredIdx;
            selectedName = (match.first['path'] ?? match.first['name'] ?? '') as String;
            selectedSize = (match.first['length'] ?? 0) as int;
          }
        }

        selectedIdx ??= largestIdx;
        selectedName ??= largestName;
        if (selectedSize <= 0) selectedSize = largestSize;

        if (selectedIdx != null && selectedName != null) {
          // Set download priority — only download the selected file
          final priorities = files.map((f) =>
            (f['id'] as int) == selectedIdx ? 1 : 0
          ).toList();

          try {
            await http.post(
              torrentsUri,
              headers: _jsonHeaders,
              body: jsonEncode({
                'action': 'set',
                'hash': hash,
                'priority': priorities,
              }),
            ).timeout(const Duration(seconds: 4));
          } catch (_) {}

          return (index: selectedIdx, filename: selectedName, size: selectedSize);
        }
      } catch (e) {
        debugPrint('[TorrServer] Metadata poll error: $e');
      }
      await Future.delayed(pollInterval);
    }
    return null;
  }

  /// Get torrent stats for display.
  static Future<TorrentStats?> getTorrentStats(String hash) async {
    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/torrents'),
        headers: _jsonHeaders,
        body: jsonEncode({'action': 'get', 'hash': hash}),
      ).timeout(const Duration(seconds: 4));

      if (resp.statusCode != 200 || resp.body.isEmpty) return null;

      final json = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (json == null) return null;

      final rawSpeed = (json['download_speed'] ?? 0.0) as num;
      final speedMbps = rawSpeed.toDouble() / 1024 / 1024;
      final activePeers = (json['active_peers'] ?? 0) as int;
      final totalPeers = (json['total_peers'] ?? 0) as int;
      final loadedBytes = (json['preload_size'] ?? 0) as int;
      final totalBytes = (json['total_size'] ?? 0) as int;

      return TorrentStats(
        speedMbps: speedMbps,
        activePeers: activePeers,
        totalPeers: totalPeers,
        loadedBytes: loadedBytes,
        totalBytes: totalBytes,
      );
    } catch (_) {
      return null;
    }
  }

  static bool _isEpisodeMatch(String name, int season, int episode) {
    final t = name.toLowerCase();
    if (RegExp('s0*$season[ ._-]*e0*$episode\\b', caseSensitive: false).hasMatch(t)) return true;
    if (RegExp('\\b0*${season}x0*$episode\\b', caseSensitive: false).hasMatch(t)) return true;
    return false;
  }

  static bool _isVideoFile(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.mkv') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.wmv') ||
        lower.endsWith('.flv') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.m2ts') ||
        lower.endsWith('.vob');
  }

  /// Remove torrent from TorrServer.
  static Future<void> removeTorrent(String hash) async {
    try {
      await http.post(
        Uri.parse('$_baseUrl/torrents'),
        headers: _jsonHeaders,
        body: jsonEncode({'action': 'rem', 'hash': hash}),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// Drop torrent (disconnect peers but keep DB entry).
  static Future<void> dropTorrent(String hash) async {
    try {
      await http.post(
        Uri.parse('$_baseUrl/torrents'),
        headers: _jsonHeaders,
        body: jsonEncode({'action': 'drop', 'hash': hash}),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  // Legacy aliases for backward compat (rqbit used int torrentId)
  static Future<void> deleteTorrent(dynamic torrentIdOrHash) async {
    if (torrentIdOrHash is String) {
      await removeTorrent(torrentIdOrHash);
    }
  }

  static Future<void> forgetTorrent(dynamic torrentIdOrHash) async {
    if (torrentIdOrHash is String) {
      await dropTorrent(torrentIdOrHash);
    }
  }
}
