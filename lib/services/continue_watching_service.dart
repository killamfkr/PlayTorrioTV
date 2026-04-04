import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'stream_service.dart';

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

  /// Unique key: one entry per show/movie, per episode for TV
  String get key => season != null && episode != null
      ? '${tmdbId}_s${season}e${episode}'
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
        // Sort by most recently updated first
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
    // Also write for native Kotlin to read
    await prefs.setString('${_key}_json', json);
  }

  static Future<void> upsert(WatchEntry entry) async {
    // Don't save if near the beginning (< 30s) or near the end (> 93%)
    if (entry.durationMs > 0) {
      if (entry.positionMs < 30000) return;
      if (entry.progress > 0.93) {
        // Finished watching — remove entry
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
    // Keep max 30 entries
    if (_entries.length > 30) _entries = _entries.sublist(0, 30);
    _entries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _save();
  }

  static Future<void> remove(String key) async {
    _entries.removeWhere((e) => e.key == key);
    await _save();
  }

  /// Persist current entries to a profile-specific key for later restoration.
  static Future<void> saveForProfile(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(_entries.map((e) => e.toJson()).toList());
    await prefs.setString('profile_cw_$profileId', json);
  }

  /// Restore entries from a profile-specific key and write them into the
  /// standard key so that native code and the home screen see the right data.
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
    // Sync to standard keys for native Kotlin
    await _save();
  }
}
