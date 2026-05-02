import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class WatchEntry {
  final int tmdbId;
  final String imdbId;
  final String title;
  final String magnet;
  final int fileIdx;
  final int positionMs;
  final int durationMs;
  final int? season;
  final int? episode;
  final String? backdropPath;
  final String? posterPath;
  final String mediaType; // 'movie' or 'tv'
  final int updatedAt; // epoch ms

  const WatchEntry({
    required this.tmdbId,
    required this.imdbId,
    required this.title,
    required this.magnet,
    required this.fileIdx,
    required this.positionMs,
    required this.durationMs,
    this.season,
    this.episode,
    this.backdropPath,
    this.posterPath,
    required this.mediaType,
    required this.updatedAt,
  });

  /// Same `uniqueId` shape as PlayTorrioV2 mobile (`WatchHistoryService`).
  String get uniqueId => season != null && episode != null
      ? '${tmdbId}_S${season}_E$episode'
      : '$tmdbId';

  /// One entry per show/movie, per episode for TV (lowercase — local key).
  String get key => season != null && episode != null
      ? '${tmdbId}_s${season}e$episode'
      : '$tmdbId';

  double get progress =>
      durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;

  Map<String, dynamic> toJson() => {
        'tmdbId': tmdbId,
        'imdbId': imdbId,
        'title': title,
        'magnet': magnet,
        'fileIdx': fileIdx,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'season': season,
        'episode': episode,
        'backdropPath': backdropPath,
        'posterPath': posterPath,
        'mediaType': mediaType,
        'updatedAt': updatedAt,
      };

  /// Row shape expected by Supabase `user_watch_history.entries` (mobile parity).
  Map<String, dynamic> toCloudRow() => {
        'uniqueId': uniqueId,
        'tmdbId': tmdbId,
        'imdbId': imdbId.isEmpty ? null : imdbId,
        'title': title,
        'posterPath': posterPath ?? '',
        'method': magnet == '__streaming__' ? 'stream' : 'torrent',
        'sourceId': magnet,
        'position': positionMs,
        'duration': durationMs,
        'season': season,
        'episode': episode,
        'magnetLink': magnet != '__streaming__' ? magnet : null,
        'fileIndex': fileIdx,
        'mediaType': mediaType,
        'updatedAt': updatedAt,
      };

  factory WatchEntry.fromJson(Map<String, dynamic> json) => WatchEntry(
        tmdbId: json['tmdbId'] as int,
        imdbId: (json['imdbId'] ?? '') as String,
        title: json['title'] as String,
        magnet: json['magnet'] as String,
        fileIdx: (json['fileIdx'] ?? 0) as int,
        positionMs: json['positionMs'] as int,
        durationMs: (json['durationMs'] ?? 0) as int,
        season: json['season'] as int?,
        episode: json['episode'] as int?,
        backdropPath: json['backdropPath'] as String?,
        posterPath: json['posterPath'] as String?,
        mediaType: (json['mediaType'] ?? 'movie') as String,
        updatedAt: (json['updatedAt'] ?? 0) as int,
      );

  /// Parse mobile / Supabase cloud row into TV [WatchEntry].
  factory WatchEntry.fromCloudMap(Map<String, dynamic> m) {
    int tid = (m['tmdbId'] is int) ? m['tmdbId'] as int : int.tryParse('${m['tmdbId']}') ?? 0;
    final uid = m['uniqueId']?.toString() ?? '';
    int? s;
    int? ep;
    if (tid <= 0 && uid.isNotEmpty) {
      final re = RegExp(r'^(\d+)_S(\d+)_E(\d+)$');
      final mm = re.firstMatch(uid);
      if (mm != null) {
        tid = int.parse(mm.group(1)!);
        s = int.parse(mm.group(2)!);
        ep = int.parse(mm.group(3)!);
      } else {
        tid = int.tryParse(uid) ?? 0;
      }
    } else {
      s = m['season'] as int? ?? (m['season'] is num ? (m['season'] as num).toInt() : null);
      ep = m['episode'] as int? ?? (m['episode'] is num ? (m['episode'] as num).toInt() : null);
    }
    final pos = (m['positionMs'] is int)
        ? m['positionMs'] as int
        : int.tryParse('${m['position'] ?? m['positionMs'] ?? 0}') ?? 0;
    final dur = (m['durationMs'] is int)
        ? m['durationMs'] as int
        : int.tryParse('${m['duration'] ?? m['durationMs'] ?? 0}') ?? 0;
    final mag = (m['magnet'] ?? m['magnetLink'] ?? m['sourceId'] ?? '') as String? ?? '';
    final method = m['method']?.toString() ?? '';
    final magnetOut =
        mag.isNotEmpty ? mag : (method == 'stream' ? '__streaming__' : '');
    final fi = (m['fileIdx'] is int)
        ? m['fileIdx'] as int
        : int.tryParse('${m['fileIndex'] ?? m['fileIdx'] ?? 0}') ?? 0;
    final mt = (m['mediaType'] ?? 'movie').toString();
    final upd = (m['updatedAt'] is int)
        ? m['updatedAt'] as int
        : int.tryParse('${m['updatedAt'] ?? 0}') ?? 0;
    final imdb = m['imdbId'];
    final imdbStr = imdb == null ? '' : imdb.toString();
    return WatchEntry(
      tmdbId: tid,
      imdbId: imdbStr,
      title: (m['title'] ?? '') as String? ?? 'Unknown',
      magnet: magnetOut,
      fileIdx: fi,
      positionMs: pos,
      durationMs: dur,
      season: s,
      episode: ep,
      backdropPath: m['backdropPath'] as String?,
      posterPath: m['posterPath'] as String?,
      mediaType: mt == 'tv' ? 'tv' : 'movie',
      updatedAt: upd,
    );
  }

  WatchEntry copyWith({int? positionMs, int? durationMs, int? updatedAt}) =>
      WatchEntry(
        tmdbId: tmdbId,
        imdbId: imdbId,
        title: title,
        magnet: magnet,
        fileIdx: fileIdx,
        positionMs: positionMs ?? this.positionMs,
        durationMs: durationMs ?? this.durationMs,
        season: season,
        episode: episode,
        backdropPath: backdropPath,
        posterPath: posterPath,
        mediaType: mediaType,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

class ContinueWatchingService {
  static const _key = 'continue_watching';
  static List<WatchEntry> _entries = [];

  /// Set from `main()` to push Supabase after local CW changes (avoids import cycle).
  static void Function()? onPersisted;

  static List<WatchEntry> get entries => List.unmodifiable(_entries);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _entries = list
            .map((e) => WatchEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        _entries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      } catch (_) {
        _entries = [];
      }
    }
  }

  static Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(_entries.map((e) => e.toJson()).toList());
    await prefs.setString(_key, json);
    await prefs.setString('${_key}_json', json);
  }

  static Future<void> upsert(WatchEntry entry) async {
    if (entry.durationMs > 0) {
      if (entry.positionMs < 30000) return;
      if (entry.progress > 0.93) {
        await remove(entry.key);
        return;
      }
    }

    final idx = _entries.indexWhere((e) => e.key == entry.key);
    if (idx >= 0) {
      _entries[idx] = entry;
    } else {
      _entries.insert(0, entry);
    }
    if (_entries.length > 30) _entries = _entries.sublist(0, 30);
    _entries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _save();
    onPersisted?.call();
  }

  static Future<void> remove(String key) async {
    _entries.removeWhere((e) => e.key == key);
    await _save();
    onPersisted?.call();
  }

  /// Replace list after Supabase merge (same semantics as mobile `replaceAll`).
  static Future<void> replaceFromCloudMaps(List<Map<String, dynamic>> rows) async {
    final parsed = <WatchEntry>[];
    for (final m in rows) {
      try {
        parsed.add(WatchEntry.fromCloudMap(m));
      } catch (_) {}
    }
    parsed.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (parsed.length > 30) {
      _entries = parsed.sublist(0, 30);
    } else {
      _entries = parsed;
    }
    await _save();
  }

  static Future<void> saveForProfile(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(_entries.map((e) => e.toJson()).toList());
    await prefs.setString('profile_cw_$profileId', json);
  }

  static Future<void> loadForProfile(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('profile_cw_$profileId');
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _entries = list
            .map((e) => WatchEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        _entries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      } catch (_) {
        _entries = [];
      }
    } else {
      _entries = [];
    }
    await _save();
  }
}
