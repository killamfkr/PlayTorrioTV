import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'settings_service.dart';
import 'stream_service.dart';

/// A single stream result from a Stremio addon.
class StremioStream {
  final String addonName;
  final String name;      // e.g. "Torrentio\n4k DV | HDR"
  final String title;     // description with seeders, size, etc.
  final String? infoHash;
  final int? fileIdx;
  final String? url;      // direct URL (debrid-resolved or HTTP stream)
  final String? externalUrl; // deep link (stremio:///detail/..., stremio:///search?...)
  final String? filename;
  final List<String> sources; // tracker URLs

  const StremioStream({
    required this.addonName,
    required this.name,
    required this.title,
    this.infoHash,
    this.fileIdx,
    this.url,
    this.externalUrl,
    this.filename,
    this.sources = const [],
  });

  /// Whether this stream is a torrent (has infoHash) vs direct URL.
  bool get isTorrent => infoHash != null && infoHash!.isNotEmpty;

  /// Whether this stream is a deep link to another item/search.
  bool get isExternalLink => externalUrl != null && externalUrl!.isNotEmpty;

  /// Build a magnet URI from infoHash + sources + app trackers.
  String buildMagnet(List<String> appTrackers) {
    if (!isTorrent) return '';
    final buf = StringBuffer('magnet:?xt=urn:btih:$infoHash');
    if (filename != null && filename!.isNotEmpty) {
      buf.write('&dn=${Uri.encodeComponent(filename!)}');
    }
    final allTrackers = <String>{};
    for (final s in sources) {
      // sources come as "tracker:udp://..." or "dht:..." — strip prefix
      if (s.startsWith('tracker:')) {
        allTrackers.add(s.substring('tracker:'.length));
      }
    }
    for (final t in appTrackers) {
      allTrackers.add(t);
    }
    for (final t in allTrackers) {
      buf.write('&tr=${Uri.encodeComponent(t)}');
    }
    return buf.toString();
  }

  /// Display quality badge parsed from `name` field (second line).
  String get quality {
    final lines = name.split('\n');
    return lines.length > 1 ? lines.last.trim() : '';
  }

  /// Display addon label (first line of name, minus prefix like "[TB+] ").
  String get addonLabel {
    final lines = name.split('\n');
    var first = lines.first.trim();
    // Strip debrid prefixes like "[TB+] "
    first = first.replaceFirst(RegExp(r'^\[.*?\]\s*'), '');
    return first;
  }

  /// Parse size from title (e.g. "💾 11.58 GB").
  String get size {
    final match = RegExp(r'💾\s*([^\n⚙️]+)').firstMatch(title);
    return match?.group(1)?.trim() ?? '';
  }

  /// Parse seeders from title (e.g. "👤 880").
  int get seeders {
    final match = RegExp(r'👤\s*(\d+)').firstMatch(title);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  /// Parse provider/indexer from title (e.g. "⚙️ Rutracker").
  String get provider {
    final match = RegExp(r'⚙️\s*([^\n]+)').firstMatch(title);
    return match?.group(1)?.trim() ?? addonName;
  }
}

/// Cached manifest info for a Stremio addon.
class StremioAddonManifest {
  final String id;
  final String name;
  final String baseUrl;
  final bool hasStreamResource;
  final List<String> streamTypes; // "movie", "series", "anime"
  final List<String> idPrefixes; // "tt", "kitsu"

  const StremioAddonManifest({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.hasStreamResource,
    required this.streamTypes,
    required this.idPrefixes,
  });
}

class StremioAddonService {
  static final Map<String, StremioAddonManifest> _manifestCache = {};

  // ═══════════════════════════════════════════════════════════════════════════
  //  HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  /// Retry an HTTP GET with exponential backoff.
  /// Does NOT retry on 404.
  static Future<http.Response> _retryGet(Uri uri, {int retries = 2, Duration timeout = const Duration(seconds: 15)}) async {
    http.Response? lastResponse;
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final response = await http.get(uri, headers: {
          'User-Agent': 'PlayTorrio/1.0',
        }).timeout(timeout);
        if (response.statusCode == 200) return response;
        lastResponse = response;
        if (response.statusCode == 404) break;
      } catch (e) {
        lastError = e;
      }
      if (attempt < retries) {
        await Future.delayed(Duration(milliseconds: 500 * (1 << attempt)));
      }
    }
    if (lastResponse != null) return lastResponse;
    throw lastError ?? Exception('Request failed after $retries retries');
  }

  /// Extracts a clean base URL and optional query parameters from an addon URL.
  static ({String baseUrl, String? queryParams}) _splitAddonUrl(String url) {
    final qIdx = url.indexOf('?');
    String path = qIdx >= 0 ? url.substring(0, qIdx) : url;
    final query = qIdx >= 0 ? url.substring(qIdx + 1) : null;
    path = path.replaceAll(RegExp(r'/manifest\.json$'), '').replaceAll(RegExp(r'/$'), '');
    if (!path.startsWith('http')) path = 'https://$path';
    return (baseUrl: path, queryParams: query);
  }

  /// Builds a full resource URL, correctly re-appending any addon query params.
  static String _buildResourceUrl(String addonBaseUrl, String resourcePath) {
    final parts = _splitAddonUrl(addonBaseUrl);
    final qp = parts.queryParams;
    return qp != null
        ? '${parts.baseUrl}$resourcePath?$qp'
        : '${parts.baseUrl}$resourcePath';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  MANIFEST
  // ═══════════════════════════════════════════════════════════════════════════

  /// Fetch and cache the manifest for an addon base URL.
  static Future<StremioAddonManifest?> fetchManifest(String baseUrl) async {
    if (_manifestCache.containsKey(baseUrl)) return _manifestCache[baseUrl];

    try {
      final parts = _splitAddonUrl(baseUrl);
      final manifestPath = '/manifest.json';
      final url = _buildResourceUrl(baseUrl, manifestPath);
      final resp = await http.get(Uri.parse(url), headers: {
        'User-Agent': 'PlayTorrio/1.0',
      }).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) return null;

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final resources = json['resources'] as List? ?? [];

      bool hasStream = false;
      List<String> streamTypes = [];
      List<String> idPrefixes = [];

      for (final r in resources) {
        if (r is String && r == 'stream') {
          hasStream = true;
        } else if (r is Map<String, dynamic> && r['name'] == 'stream') {
          hasStream = true;
          streamTypes = (r['types'] as List?)?.cast<String>() ?? [];
          idPrefixes = (r['idPrefixes'] as List?)?.cast<String>() ?? [];
        }
      }

      final manifest = StremioAddonManifest(
        id: (json['id'] ?? '') as String,
        name: (json['name'] ?? 'Unknown Addon') as String,
        baseUrl: parts.baseUrl,
        hasStreamResource: hasStream,
        streamTypes: streamTypes,
        idPrefixes: idPrefixes,
      );

      _manifestCache[baseUrl] = manifest;
      return manifest;
    } catch (e) {
      debugPrint('[StremioAddon] Failed to fetch manifest from $baseUrl: $e');
      return null;
    }
  }

  /// Fetches and validates an addon manifest, returning the full manifest data
  /// as a rich map suitable for storage in SettingsService.
  static Future<Map<String, dynamic>?> fetchManifestRich(String url) async {
    String manifestUrl = url.trim();
    if (manifestUrl.isEmpty) return null;

    if (manifestUrl.startsWith('stremio://')) {
      manifestUrl = manifestUrl.replaceFirst('stremio://', 'https://');
    }

    if (!manifestUrl.endsWith('/manifest.json')) {
      manifestUrl = manifestUrl.endsWith('/')
          ? '${manifestUrl}manifest.json'
          : '$manifestUrl/manifest.json';
    }

    try {
      final response = await http.get(Uri.parse(manifestUrl), headers: {
        'User-Agent': 'PlayTorrio/1.0',
      }).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final manifest = jsonDecode(response.body);
        final parts = _splitAddonUrl(manifestUrl);
        final baseUrl = parts.queryParams != null
            ? '${parts.baseUrl}?${parts.queryParams}'
            : parts.baseUrl;

        return {
          'baseUrl': baseUrl,
          'manifest': manifest,
          'name': manifest['name'] ?? 'Unknown Addon',
          'icon': manifest['logo'] ?? '',
        };
      }
    } catch (e) {
      debugPrint('[StremioAddon] Manifest fetch error: $e');
    }
    return null;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  STREAMS
  // ═══════════════════════════════════════════════════════════════════════════

  /// Fetch streams from a single addon for a movie.
  static Future<List<StremioStream>> fetchMovieStreams(
    String baseUrl,
    String addonName,
    String imdbId,
  ) async {
    if (imdbId.isEmpty) return [];
    final url = _buildResourceUrl(baseUrl, '/stream/movie/$imdbId.json');
    return _fetchStreams(url, addonName);
  }

  /// Fetch streams from a single addon for a TV episode.
  static Future<List<StremioStream>> fetchEpisodeStreams(
    String baseUrl,
    String addonName,
    String imdbId,
    int season,
    int episode,
  ) async {
    if (imdbId.isEmpty) return [];
    final url = _buildResourceUrl(baseUrl, '/stream/series/$imdbId:$season:$episode.json');
    return _fetchStreams(url, addonName);
  }

  static Future<List<StremioStream>> _fetchStreams(
    String url,
    String addonName,
  ) async {
    try {
      final resp = await _retryGet(Uri.parse(url));

      if (resp.statusCode != 200) return [];

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final streams = json['streams'] as List? ?? [];

      return streams.map((s) {
        final map = s as Map<String, dynamic>;
        final hints = map['behaviorHints'] as Map<String, dynamic>? ?? {};
        final sourcesRaw = map['sources'] as List? ?? [];

        return StremioStream(
          addonName: addonName,
          name: (map['name'] ?? '') as String,
          title: (map['title'] ?? map['description'] ?? '') as String,
          infoHash: map['infoHash'] as String?,
          fileIdx: map['fileIdx'] as int?,
          url: map['url'] as String?,
          externalUrl: map['externalUrl'] as String?,
          filename: hints['filename'] as String?,
          sources: sourcesRaw.cast<String>(),
        );
      }).toList();
    } catch (e) {
      debugPrint('[StremioAddon] Failed to fetch streams from $url: $e');
      return [];
    }
  }

  /// Fetch streams from ALL configured addons (sequential = stable order for UI / auto-pick).
  static Future<Map<String, List<StremioStream>>> fetchAllMovieStreams(
    String imdbId,
  ) async {
    return _fetchAllStreams(imdbId: imdbId, mediaType: 'movie');
  }

  /// Fetch streams from ALL configured addons (sequential = stable order for UI / auto-pick).
  static Future<Map<String, List<StremioStream>>> fetchAllEpisodeStreams(
    String imdbId,
    int season,
    int episode,
  ) async {
    return _fetchAllStreams(
      imdbId: imdbId,
      mediaType: 'series',
      season: season,
      episode: episode,
    );
  }

  /// First Stremio row: [preferredAddonName] manifest name if it has streams, else first addon in map order.
  static StremioStream? firstStreamForAutoPick(
    Map<String, List<StremioStream>> byAddon, {
    String? preferredAddonName,
  }) {
    final pref = preferredAddonName?.trim();
    if (pref != null && pref.isNotEmpty) {
      final list = byAddon[pref];
      if (list != null && list.isNotEmpty) {
        return list.first;
      }
    }
    for (final list in byAddon.values) {
      if (list.isNotEmpty) {
        return list.first;
      }
    }
    return null;
  }

  /// Parse a raw Stremio stream map (e.g. from [getStreams]) into [StremioStream].
  static StremioStream streamFromRawMap(Map<String, dynamic> map, {String addonName = ''}) {
    final hints = map['behaviorHints'] as Map<String, dynamic>? ?? {};
    final sourcesRaw = map['sources'] as List? ?? [];
    return StremioStream(
      addonName: addonName,
      name: (map['name'] ?? '') as String,
      title: (map['title'] ?? map['description'] ?? '') as String,
      infoHash: map['infoHash'] as String?,
      fileIdx: map['fileIdx'] as int?,
      url: map['url'] as String?,
      externalUrl: map['externalUrl'] as String?,
      filename: hints['filename'] as String?,
      sources: sourcesRaw.cast<String>(),
    );
  }

  /// Top stream from a single-addon [getStreams] response (JSON array order).
  static StremioStream? firstStreamFromRaw(Iterable<Map<String, dynamic>> raw, {String addonName = ''}) {
    for (final m in raw) {
      return streamFromRawMap(m, addonName: addonName);
    }
    return null;
  }

  static Map<String, dynamic>? firstRawStreamMap(Iterable<Map<String, dynamic>> raw) {
    for (final m in raw) {
      return m;
    }
    return null;
  }

  static Future<Map<String, List<StremioStream>>> _fetchAllStreams({
    required String imdbId,
    required String mediaType,
    int? season,
    int? episode,
  }) async {
    final addons = SettingsService.instance.stremioAddons;
    if (addons.isEmpty || imdbId.isEmpty) return {};

    final results = <String, List<StremioStream>>{};
    for (final baseUrl in addons) {
      final entry = await _fetchFromAddon(
        baseUrl: baseUrl,
        imdbId: imdbId,
        mediaType: mediaType,
        season: season,
        episode: episode,
      );
      if (entry != null && entry.value.isNotEmpty) {
        results[entry.key] = entry.value;
      }
    }

    return results;
  }

  static Future<MapEntry<String, List<StremioStream>>?> _fetchFromAddon({
    required String baseUrl,
    required String imdbId,
    required String mediaType,
    int? season,
    int? episode,
  }) async {
    try {
      final manifest = await fetchManifest(baseUrl);
      if (manifest == null || !manifest.hasStreamResource) return null;

      if (manifest.streamTypes.isNotEmpty &&
          !manifest.streamTypes.contains(mediaType) &&
          !(mediaType == 'series' && manifest.streamTypes.contains('anime'))) {
        return null;
      }

      List<StremioStream> streams;
      if (mediaType == 'movie') {
        streams = await fetchMovieStreams(baseUrl, manifest.name, imdbId);
      } else {
        streams = await fetchEpisodeStreams(
          baseUrl,
          manifest.name,
          imdbId,
          season!,
          episode!,
        );
      }

      if (streams.isEmpty) return null;
      return MapEntry(manifest.name, streams);
    } catch (e) {
      debugPrint('[StremioAddon] Error fetching from $baseUrl: $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  ADDON RESOURCE FILTER
  // ═══════════════════════════════════════════════════════════════════════════

  /// Get all installed rich addons that support a specific resource.
  /// Optionally filters by content [type] (e.g. 'movie', 'series').
  static List<Map<String, dynamic>> getAddonsForResource(String resourceName, {String? type}) {
    final allAddons = SettingsService.instance.stremioAddonsRich;
    return allAddons.where((addon) {
      final manifest = addon['manifest'];
      if (manifest is! Map) return false;
      final resources = manifest['resources'] as List?;
      if (resources == null) return false;
      return resources.any((r) {
        if (r is String) {
          if (r != resourceName) return false;
          if (type != null) {
            final types = manifest['types'] as List?;
            return types != null && types.contains(type);
          }
          return true;
        }
        if (r is Map && r['name'] == resourceName) {
          if (type != null) {
            final types = r['types'] as List?;
            if (types != null && types.isNotEmpty) return types.contains(type);
            final mTypes = manifest['types'] as List?;
            return mTypes == null || mTypes.contains(type);
          }
          return true;
        }
        return false;
      });
    }).toList();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  CATALOG
  // ═══════════════════════════════════════════════════════════════════════════

  /// Returns all catalogs from installed addons, each annotated with the
  /// parent addon's baseUrl and name.
  static List<Map<String, dynamic>> getAllCatalogs() {
    final allAddons = SettingsService.instance.stremioAddonsRich;
    final catalogAddons = allAddons.where((addon) {
      final manifest = addon['manifest'];
      if (manifest is! Map) return false;
      final cats = manifest['catalogs'];
      return cats is List && cats.isNotEmpty;
    }).toList();
    final List<Map<String, dynamic>> result = [];
    for (final addon in catalogAddons) {
      final manifest = addon['manifest'] as Map<String, dynamic>;
      final catalogs = manifest['catalogs'] as List? ?? [];
      for (final cat in catalogs) {
        if (cat is! Map) continue;

        final extra = cat['extra'] as List? ?? [];
        final extraSupportedRaw = cat['extraSupported'] as List?;
        final extraRequiredRaw = cat['extraRequired'] as List?;

        final Set<String> supported = {};
        final Set<String> required = {};

        for (final e in extra) {
          if (e is Map) {
            final name = e['name']?.toString() ?? '';
            if (name.isNotEmpty) supported.add(name);
            if (e['isRequired'] == true) required.add(name);
          } else if (e is String) {
            supported.add(e);
          }
        }

        if (extraSupportedRaw != null) {
          for (final s in extraSupportedRaw) {
            if (s is String) supported.add(s);
          }
        }
        if (extraRequiredRaw != null) {
          for (final r in extraRequiredRaw) {
            if (r is String) required.add(r);
          }
        }

        // Skip catalogs that REQUIRE unfulfillable extras
        final unfulfillable = required.where((n) => n != 'genre' && n != 'search');
        if (unfulfillable.isNotEmpty) continue;

        List<String> genres = (cat['genres'] as List?)?.cast<String>() ?? <String>[];
        if (genres.isEmpty) {
          for (final e in extra) {
            if (e is Map && e['name'] == 'genre' && e['options'] is List) {
              genres = (e['options'] as List).cast<String>();
              break;
            }
          }
        }

        result.add({
          'addonBaseUrl': addon['baseUrl'],
          'addonName': addon['name'] ?? manifest['name'] ?? 'Unknown',
          'addonIcon': addon['icon'] ?? manifest['logo'] ?? '',
          'catalogId': cat['id'],
          'catalogName': cat['name'] ?? cat['id'],
          'catalogType': cat['type'],
          'genres': genres,
          'extra': extra,
          'supportsSearch': supported.contains('search'),
          'searchRequired': required.contains('search'),
          'supportsGenre': supported.contains('genre'),
          'supportsSkip': supported.contains('skip'),
        });
      }
    }
    return result;
  }

  /// Fetches a catalog feed with optional genre/skip/search.
  static Future<List<Map<String, dynamic>>> getCatalog({
    required String baseUrl,
    required String type,
    required String id,
    String? genre,
    int? skip,
    String? search,
  }) async {
    final parts = <String>[];
    if (search != null && search.isNotEmpty) {
      parts.add('search=${Uri.encodeComponent(search)}');
    }
    if (genre != null && genre.isNotEmpty) {
      parts.add('genre=${Uri.encodeComponent(genre)}');
    }
    if (skip != null && skip > 0) {
      parts.add('skip=$skip');
    }
    final extra = parts.isNotEmpty ? '/${parts.join('&')}' : '';
    final resourcePath = '/catalog/$type/$id$extra.json';
    final url = _buildResourceUrl(baseUrl, resourcePath);
    debugPrint('[StremioAddon.getCatalog] URL: $url');

    try {
      final response = await _retryGet(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final metas = data['metas'] as List? ?? [];
        return metas.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('[StremioAddon] Catalog fetch error ($url): $e');
    }
    return [];
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  METADATA
  // ═══════════════════════════════════════════════════════════════════════════

  /// Fetches full meta for a specific item.
  static Future<Map<String, dynamic>?> getMeta({
    required String baseUrl,
    required String type,
    required String id,
  }) async {
    final encodedId = id.contains('/') ? Uri.encodeComponent(id) : id;
    final resourcePath = '/meta/$type/$encodedId.json';
    final url = _buildResourceUrl(baseUrl, resourcePath);
    try {
      final response = await _retryGet(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final meta = data['meta'] as Map<String, dynamic>?;
        if (meta != null && meta['type'] == 'collections' && meta['videos'] is List) {
          meta['_isCollection'] = true;
        }
        return meta;
      }
    } catch (e) {
      debugPrint('[StremioAddon] Meta fetch error ($url): $e');
    }
    return null;
  }

  /// Fetches meta from ALL installed addons that can handle this id and type.
  /// Returns the first successful non-null response.
  static Future<Map<String, dynamic>?> getMetaFromAny({
    required String type,
    required String id,
  }) async {
    final addons = getAddonsForResource('meta', type: type);
    for (final addon in addons) {
      final manifest = addon['manifest'] as Map<String, dynamic>;
      final idPrefixes = _getIdPrefixes(manifest, 'meta');
      if (idPrefixes.isNotEmpty && !idPrefixes.any((p) => id.startsWith(p))) {
        continue;
      }
      final meta = await getMeta(baseUrl: addon['baseUrl'], type: type, id: id);
      if (meta != null && meta.isNotEmpty && meta['id'] != null) return meta;
    }
    return null;
  }

  /// Extracts idPrefixes for a specific resource from a manifest.
  static List<String> _getIdPrefixes(Map<String, dynamic> manifest, String resourceName) {
    final resources = manifest['resources'] as List? ?? [];
    for (final r in resources) {
      if (r is Map && r['name'] == resourceName && r['idPrefixes'] != null) {
        return (r['idPrefixes'] as List).cast<String>();
      }
    }
    final prefixes = manifest['idPrefixes'] as List?;
    return prefixes?.cast<String>() ?? [];
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SEARCH (catalog-based)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Searches across ALL installed addons that have catalogs with search support.
  /// Returns results grouped by addon name.
  static Future<Map<String, List<Map<String, dynamic>>>> searchAllAddons(String query) async {
    if (query.trim().isEmpty) return {};
    final catalogs = getAllCatalogs();
    final searchable = catalogs.where((c) => c['supportsSearch'] == true).toList();

    final Map<String, List<Map<String, dynamic>>> resultsByAddon = {};
    final futures = <Future>[];

    for (final cat in searchable) {
      futures.add(
        getCatalog(
          baseUrl: cat['addonBaseUrl'],
          type: cat['catalogType'],
          id: cat['catalogId'],
          search: query,
        ).then((metas) {
          if (metas.isEmpty) return;
          final addonName = cat['addonName'] as String;
          for (final m in metas) {
            m['_addonName'] = addonName;
            m['_addonBaseUrl'] = cat['addonBaseUrl'];
            m['_catalogType'] = cat['catalogType'];
          }
          resultsByAddon.putIfAbsent(addonName, () => []).addAll(metas);
        }).catchError((_) {}),
      );
    }
    await Future.wait(futures);
    return resultsByAddon;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  META LINK PARSING
  // ═══════════════════════════════════════════════════════════════════════════

  /// Parses a Stremio meta link URL and returns an action descriptor.
  static Map<String, dynamic>? parseMetaLink(String url) {
    String u = url.trim();
    if (u.startsWith('stremio://')) {
      u = u.replaceFirst('stremio://', 'stremio:///');
      u = u.replaceAll('stremio:////', 'stremio:///');
    }

    final detailMatch = RegExp(r'stremio:///detail/([^/]+)/([^/?]+)(?:/([^/?]+))?').firstMatch(u);
    if (detailMatch != null) {
      return {
        'action': 'detail',
        'type': detailMatch.group(1),
        'id': detailMatch.group(2),
        'videoId': detailMatch.group(3),
      };
    }

    final searchMatch = RegExp(r'stremio:///search\?search=(.+)').firstMatch(u);
    if (searchMatch != null) {
      return {
        'action': 'search',
        'query': Uri.decodeComponent(searchMatch.group(1)!),
      };
    }

    final discoverMatch = RegExp(r'stremio:///discover/([^/]+)/([^/]+)/([^/?]+)(.*)').firstMatch(u);
    if (discoverMatch != null) {
      return {
        'action': 'discover',
        'transportUrl': Uri.decodeComponent(discoverMatch.group(1)!),
        'type': discoverMatch.group(2),
        'catalogId': discoverMatch.group(3),
        'extra': discoverMatch.group(4),
      };
    }

    return null;
  }

  /// Fetch raw streams from a specific addon by type and arbitrary ID.
  /// Used for custom (non-IMDB) Stremio IDs.
  static Future<List<Map<String, dynamic>>> getStreams({
    required String baseUrl,
    required String type,
    required String id,
  }) async {
    final encodedId = id.contains('/') ? Uri.encodeComponent(id) : id;
    final resourcePath = '/stream/$type/$encodedId.json';
    final url = _buildResourceUrl(baseUrl, resourcePath);
    try {
      final response = await _retryGet(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final streams = data['streams'] as List? ?? [];
        return streams.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('[StremioAddon] Stream fetch error ($url): $e');
    }
    return [];
  }

  /// Resolves a Stremio meta ID to actionable data.
  static Future<Map<String, dynamic>?> resolveIdToMeta(String id, String type) async {
    if (id.startsWith('tt')) {
      return {'action': 'tmdb_lookup', 'imdbId': id, 'type': type};
    }
    final meta = await getMetaFromAny(type: type, id: id);
    if (meta != null) {
      return {'action': 'stremio_meta', 'meta': meta, 'type': type};
    }
    return null;
  }

  /// Get list of app-level trackers for magnet building.
  static List<String> get appTrackers => StreamService.trackers;
}
