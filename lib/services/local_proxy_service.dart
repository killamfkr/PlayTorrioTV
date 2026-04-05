import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Cached chapter audio data for instant seek support.
/// Chunks are stored incrementally so partial data can be served mid-download.
class _CachedAudio {
  final List<Uint8List> _chunks = [];
  Uint8List? _final; // assembled once download completes
  int totalBytes = 0;
  bool complete = false;
  bool downloading = false;
  int durationMs = 0;

  /// Broadcast stream so mid-download seek responses can receive live chunks.
  final StreamController<Uint8List> _newChunks = StreamController.broadcast();
  Stream<Uint8List> get newChunks => _newChunks.stream;

  void addChunk(Uint8List chunk) {
    _chunks.add(chunk);
    totalBytes += chunk.length;
    if (!_newChunks.isClosed) _newChunks.add(chunk);
  }

  void finish() {
    complete = true;
    downloading = false;
    if (!_newChunks.isClosed) _newChunks.close();
  }

  void dispose() {
    downloading = false;
    if (!_newChunks.isClosed) _newChunks.close();
  }

  Uint8List getBytes() {
    if (_final != null) return _final!;
    final b = BytesBuilder(copy: false);
    for (final c in _chunks) {
      b.add(c);
    }
    final result = b.toBytes();
    if (complete) _final = result;
    return result;
  }
}

/// Lightweight local HTTP proxy for Tokybook HLS streams.
/// Fetches the m3u8 playlist, then downloads and concatenates all .ts segments.
/// Caches the decoded audio so seeks don't re-download.
class LocalProxyService {
  static final LocalProxyService _instance = LocalProxyService._internal();
  factory LocalProxyService() => _instance;
  LocalProxyService._internal();

  HttpServer? _server;
  int _port = 0;

  http.Client _httpClient = http.Client();
  bool _cancelled = false;

  /// Per-chapter audio cache keyed by m3u8 target URL.
  final Map<String, _CachedAudio> _cache = {};

  int get port => _port;
  String get baseUrl => 'http://127.0.0.1:$_port';

  Future<void> start() async {
    if (_server != null) return;

    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      debugPrint('[LocalProxy] Started on $baseUrl');

      _server!.listen(_handleRequest);
    } catch (e) {
      debugPrint('[LocalProxy] Error starting: $e');
    }
  }

  /// Cancel any in-flight segment downloads (e.g. when leaving the player).
  void cancelCurrentStream() {
    _cancelled = true;
    for (final c in _cache.values) {
      c.dispose();
    }
    _cache.clear();
    _httpClient.close();
    _httpClient = http.Client();
    debugPrint('[LocalProxy] Cancelled current stream & cleared cache');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.uri.path.startsWith('/toky-proxy')) {
        await _handleTokyProxy(request);
      } else if (request.uri.path == '/health') {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(json.encode({'status': 'ok', 'port': _port}));
        await request.response.close();
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    } catch (e) {
      debugPrint('[LocalProxy] Request error: $e');
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// Parse query parameters using Uri.decodeComponent (NOT form-url-encoded).
  /// This preserves '+' as '+' instead of converting it to space.
  Map<String, String> _parseQuery(String query) {
    final params = <String, String>{};
    for (final part in query.split('&')) {
      final idx = part.indexOf('=');
      if (idx == -1) continue;
      params[Uri.decodeComponent(part.substring(0, idx))] =
          Uri.decodeComponent(part.substring(idx + 1));
    }
    return params;
  }

  Future<void> _handleTokyProxy(HttpRequest request) async {
    // Use custom parser to avoid '+' → space conversion
    final params = _parseQuery(request.uri.query);
    final targetUrl = params['url'];
    final audiobookId = params['id'];
    final token = params['token'];
    final trackSrc = params['src'];
    final isHead = request.method == 'HEAD';

    if (targetUrl == null) {
      request.response
        ..statusCode = 404
        ..write('Missing url');
      await request.response.close();
      return;
    }

    final cacheKey = targetUrl;

    // ──── Serve from cache (complete → Range support, partial → live stream) ────
    if (!isHead) {
      final existing = _cache[cacheKey];
      if (existing != null && existing.totalBytes > 0) {
        if (existing.complete) {
          final data = existing.getBytes();
          debugPrint('[TokyProxy] Cache HIT – serving ${data.length} bytes');
          await _serveFromCache(request, data, existing.durationMs);
          return;
        }
        if (existing.downloading) {
          debugPrint('[TokyProxy] PARTIAL cache – streaming ${existing.totalBytes} cached + live chunks');
          await _streamFromPartialCache(request, existing);
          return;
        }
      }
      // Already downloading but zero bytes yet → fall through (shouldn't happen)
      if (existing != null && existing.downloading) return;
    }

    // ──── Fetch m3u8 playlist ────
    // Decode path to prevent double-encoding
    final baseUri = Uri.parse(targetUrl);
    final decodedPath = Uri.decodeComponent(baseUri.path);
    final m3u8Url = Uri.https('tokybook.com', decodedPath).toString();

    // Construct track source header — must re-encode via Uri.https().path
    final String baseSrcPath;
    if (trackSrc != null && trackSrc.isNotEmpty) {
      baseSrcPath = Uri.https('tokybook.com', Uri.decodeComponent(trackSrc)).path;
    } else {
      baseSrcPath = '';
    }

    Map<String, String> buildHeaders(String forTrackSrc) => {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36',
      'Referer': 'https://tokybook.com/',
      'Origin': 'https://tokybook.com',
      'Accept': '*/*',
      'x-audiobook-id': ?audiobookId,
      'x-stream-token': ?token,
      'x-track-src': forTrackSrc,
    };

    debugPrint('[TokyProxy] Fetching m3u8: $m3u8Url');
    debugPrint('[TokyProxy] x-audiobook-id: $audiobookId');
    debugPrint('[TokyProxy] x-track-src: $baseSrcPath');
    debugPrint('[TokyProxy] x-stream-token: ${token?.substring(0, token.length < 20 ? token.length : 20)}...');

    try {
      // 1) Fetch the m3u8 playlist
      final hdrs = buildHeaders(baseSrcPath);
      final m3u8Res = await _httpClient.get(Uri.parse(m3u8Url), headers: hdrs);
      if (m3u8Res.statusCode != 200) {
        debugPrint('[TokyProxy] m3u8 error: ${m3u8Res.statusCode}');
        debugPrint('[TokyProxy] Response body: ${m3u8Res.body.substring(0, m3u8Res.body.length < 500 ? m3u8Res.body.length : 500)}');
        request.response
          ..statusCode = m3u8Res.statusCode
          ..write(m3u8Res.body);
        await request.response.close();
        return;
      }

      debugPrint('[TokyProxy] m3u8 OK (${m3u8Res.body.length} chars)');

      // 2) Parse m3u8: extract segment URLs and total duration from EXTINF tags
      final baseDir = targetUrl.substring(0, targetUrl.lastIndexOf('/') + 1);
      final baseSrcDir = baseSrcPath.contains('/') ? baseSrcPath.substring(0, baseSrcPath.lastIndexOf('/') + 1) : '';

      final segmentUrls = <String>[];
      final segmentSrcs = <String>[];
      double totalDurationSecs = 0;
      for (final line in m3u8Res.body.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('#EXTINF:')) {
          final comma = trimmed.indexOf(',');
          final durStr = comma > 0 ? trimmed.substring(8, comma) : trimmed.substring(8);
          totalDurationSecs += double.tryParse(durStr) ?? 0;
        } else if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
          segmentUrls.add(trimmed.startsWith('http') ? trimmed : '$baseDir$trimmed');
          segmentSrcs.add(trimmed.startsWith('http') ? trimmed : '$baseSrcDir$trimmed');
        }
      }

      final totalDurationMs = (totalDurationSecs * 1000).round();
      debugPrint('[TokyProxy] Found ${segmentUrls.length} segments, duration: ${totalDurationSecs.toStringAsFixed(1)}s');

      // HEAD request: return only duration metadata, no segment data
      if (isHead) {
        request.response.statusCode = 200;
        request.response.headers.set('X-Duration-Ms', '$totalDurationMs');
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        await request.response.close();
        return;
      }

      // ──── 3) Download segments, cache incrementally, stream to first client ────
      final cached = _CachedAudio()
        ..durationMs = totalDurationMs
        ..downloading = true;
      _cache[cacheKey] = cached;
      _cancelled = false;

      request.response.statusCode = 200;
      request.response.headers.set('Content-Type', 'audio/aac');
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set('X-Duration-Ms', '$totalDurationMs');

      bool responseAlive = true;

      for (int i = 0; i < segmentUrls.length; i++) {
        if (_cancelled) {
          debugPrint('[TokyProxy] Cancelled at segment ${i + 1}/${segmentUrls.length}');
          break;
        }
        final segUrl = Uri.https('tokybook.com', Uri.decodeComponent(Uri.parse(segmentUrls[i]).path)).toString();
        final segSrc = segmentSrcs[i];
        debugPrint('[TokyProxy] Segment ${i + 1}/${segmentUrls.length}: $segUrl');

        final segRes = await _httpClient.get(Uri.parse(segUrl), headers: buildHeaders(segSrc));
        if (segRes.statusCode != 200) {
          debugPrint('[TokyProxy] Segment ${i + 1} error: ${segRes.statusCode}');
          break;
        }
        // Extract raw AAC audio frames from the MPEG-TS container
        final aacBytes = _extractAacFromTs(Uint8List.fromList(segRes.bodyBytes));
        debugPrint('[TokyProxy] Segment ${i + 1} OK: ${segRes.bodyBytes.length} TS → ${aacBytes.length} AAC bytes');

        // Store chunk in cache immediately so seeks can use it
        cached.addChunk(aacBytes);

        // Stream to the first client (may have disconnected on seek)
        if (responseAlive) {
          try {
            request.response.add(aacBytes);
          } catch (_) {
            debugPrint('[TokyProxy] Client disconnected – continuing download for cache');
            responseAlive = false;
          }
        }
      }

      // Finalise cache
      if (!_cancelled) {
        cached.finish();
        debugPrint('[TokyProxy] Cached ${cached.totalBytes} bytes for future seeks');
      } else {
        cached.dispose();
      }

      if (responseAlive) {
        try { await request.response.close(); } catch (_) {}
      }
      debugPrint('[TokyProxy] Stream complete');
    } catch (e) {
      debugPrint('[TokyProxy] Error: $e');
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// Serve fully cached audio bytes with Content-Length & Range support.
  Future<void> _serveFromCache(HttpRequest request, Uint8List data, int durationMs) async {
    final rangeHeader = request.headers.value('range');

    request.response.headers.set('Access-Control-Allow-Origin', '*');
    request.response.headers.set('Accept-Ranges', 'bytes');
    request.response.headers.set('X-Duration-Ms', '$durationMs');

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final spec = rangeHeader.substring(6);
      final dash = spec.indexOf('-');
      final start = int.parse(spec.substring(0, dash));
      final end = spec.substring(dash + 1).isNotEmpty
          ? int.parse(spec.substring(dash + 1))
          : data.length - 1;
      final cEnd = end.clamp(start, data.length - 1);

      request.response.statusCode = 206;
      request.response.headers.set('Content-Type', 'audio/aac');
      request.response.headers.set('Content-Range', 'bytes $start-$cEnd/${data.length}');
      request.response.headers.set('Content-Length', '${cEnd - start + 1}');
      request.response.add(data.sublist(start, cEnd + 1));
      debugPrint('[TokyProxy] Range $start-$cEnd/${data.length}');
    } else {
      request.response.statusCode = 200;
      request.response.headers.set('Content-Type', 'audio/aac');
      request.response.headers.set('Content-Length', '${data.length}');
      request.response.add(data);
    }

    await request.response.close();
  }

  /// Stream partial cache + live chunks while download is still in progress.
  /// No Content-Length — keeps the connection open until download finishes.
  Future<void> _streamFromPartialCache(HttpRequest request, _CachedAudio cached) async {
    request.response.statusCode = 200;
    request.response.headers.set('Content-Type', 'audio/aac');
    request.response.headers.set('Access-Control-Allow-Origin', '*');
    request.response.headers.set('X-Duration-Ms', '${cached.durationMs}');
    // No Content-Length — stream until done

    // Snapshot how many chunks exist NOW, subscribe to broadcast BEFORE any await.
    // Dart is single-threaded so no chunks can arrive between these two lines.
    final existingCount = cached._chunks.length;
    final liveStream = cached.newChunks;

    // Write all chunks downloaded so far
    for (int i = 0; i < existingCount; i++) {
      try {
        request.response.add(cached._chunks[i]);
      } catch (_) {
        return; // client disconnected
      }
    }

    // If download finished between our check and here, just close
    if (cached.complete) {
      // Write any chunks that arrived after our snapshot
      for (int i = existingCount; i < cached._chunks.length; i++) {
        try { request.response.add(cached._chunks[i]); } catch (_) { return; }
      }
      try { await request.response.close(); } catch (_) {}
      return;
    }

    // Pipe live chunks as they arrive from the background download
    try {
      await for (final chunk in liveStream) {
        request.response.add(chunk);
      }
    } catch (_) {
      // client disconnected or stream closed
    }

    try { await request.response.close(); } catch (_) {}
  }

  /// Extract raw ADTS AAC audio frames from MPEG-TS container data.
  /// Parses PAT → PMT to find the audio PID, then extracts PES payloads.
  static Uint8List _extractAacFromTs(Uint8List ts) {
    final output = BytesBuilder(copy: false);
    int pmtPid = -1;
    int audioPid = -1;
    final len = ts.length;
    int pos = 0;

    // Find first sync byte
    while (pos < len && ts[pos] != 0x47) {
      pos++;
    }

    while (pos + 188 <= len) {
      if (ts[pos] != 0x47) {
        pos++;
        continue;
      }

      final b1 = ts[pos + 1];
      final b2 = ts[pos + 2];
      final b3 = ts[pos + 3];
      final pusi = (b1 & 0x40) != 0; // payload_unit_start_indicator
      final pid = ((b1 & 0x1F) << 8) | b2;
      final afc = (b3 >> 4) & 0x03; // adaptation_field_control

      int p = pos + 4;
      // Skip adaptation field
      if (afc & 0x02 != 0 && p < pos + 188) {
        p += 1 + ts[p];
      }
      // No payload
      if ((afc & 0x01) == 0 || p >= pos + 188) { pos += 188; continue; }

      final pEnd = pos + 188;

      // PAT (PID 0) — find PMT PID
      if (pid == 0 && pusi && pmtPid < 0) {
        int t = p + 1 + ts[p]; // skip pointer field
        if (t + 8 <= pEnd) {
          final secLen = ((ts[t + 1] & 0x0F) << 8) | ts[t + 2];
          int e = t + 8;
          final secEnd = t + 3 + secLen - 4;
          while (e + 4 <= pEnd && e + 4 <= secEnd) {
            final progNum = (ts[e] << 8) | ts[e + 1];
            final pPid = ((ts[e + 2] & 0x1F) << 8) | ts[e + 3];
            if (progNum != 0) { pmtPid = pPid; break; }
            e += 4;
          }
        }
      }

      // PMT — find audio PID
      if (pmtPid > 0 && pid == pmtPid && pusi && audioPid < 0) {
        int t = p + 1 + ts[p];
        if (t + 12 <= pEnd) {
          final secLen = ((ts[t + 1] & 0x0F) << 8) | ts[t + 2];
          final progInfoLen = ((ts[t + 10] & 0x0F) << 8) | ts[t + 11];
          int e = t + 12 + progInfoLen;
          final secEnd = t + 3 + secLen - 4;
          while (e + 5 <= pEnd && e + 5 <= secEnd) {
            final sType = ts[e];
            final ePid = ((ts[e + 1] & 0x1F) << 8) | ts[e + 2];
            final esInfoLen = ((ts[e + 3] & 0x0F) << 8) | ts[e + 4];
            // 0x0F=AAC-ADTS, 0x11=AAC-LATM, 0x03/0x04=MP3
            if (sType == 0x0F || sType == 0x11 || sType == 0x03 || sType == 0x04) {
              audioPid = ePid;
              break;
            }
            e += 5 + esInfoLen;
          }
        }
      }

      // Audio PES data
      if (audioPid > 0 && pid == audioPid) {
        int d = p;
        if (pusi && d + 9 <= pEnd) {
          // Skip PES header: 3 start code + 1 stream_id + 2 length + 2 flags + 1 header_data_length
          d += 9 + ts[d + 8];
        }
        if (d < pEnd) {
          output.add(Uint8List.sublistView(ts, d, pEnd));
        }
      }

      pos += 188;
    }
    return output.toBytes();
  }

  String getTokyProxyUrl(String url, String id, String token, String src) {
    return '$baseUrl/toky-proxy?url=${Uri.encodeComponent(url)}&id=${Uri.encodeComponent(id)}&token=${Uri.encodeComponent(token)}&src=${Uri.encodeComponent(src)}';
  }
}
