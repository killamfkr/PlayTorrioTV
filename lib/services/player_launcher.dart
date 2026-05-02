import 'package:flutter/services.dart';

class PlayerLauncher {
  static const _channel = MethodChannel('com.playtorrio/player');

  /// Pre-load LibVLC on Android so the first video starts faster.
  /// No-op on platforms without the native channel (e.g. Windows).
  static Future<void> warmup() async {
    try {
      await _channel.invokeMethod('warmup');
    } on MissingPluginException {
      // Not on Android — ignore
    } catch (_) {
      // Best-effort; don't block app startup
    }
  }

  /// Launch the bundled VLC player activity.
  /// Returns true if launched, throws on failure.
  static Future<bool> launch(
    String url, {
    String? title,
    int? tmdbId,
    String? imdbId,
    int? season,
    int? episode,
    String? magnet,
    int? fileIdx,
    String? backdropPath,
    String? posterPath,
    String? mediaType,
    int? resumePositionMs,
    String? logoUrl,
    String? nextEpisodePayload,
  }) async {
    final result = await _channel.invokeMethod<bool>('launchPlayer', {
      'url': url,
      'title': title,
      'tmdbId': tmdbId ?? -1,
      'imdbId': imdbId ?? '',
      'season': season ?? -1,
      'episode': episode ?? -1,
      'magnet': magnet ?? '',
      'fileIdx': fileIdx ?? -1,
      'backdropPath': backdropPath ?? '',
      'posterPath': posterPath ?? '',
      'mediaType': mediaType ?? 'movie',
      'resumePositionMs': resumePositionMs ?? -1,
      'logoUrl': logoUrl ?? '',
      'nextEpisodePayload': nextEpisodePayload ?? '',
    });
    return result ?? false;
  }

  /// Launch the player in streaming mode (no URL — player extracts sources internally).
  static Future<bool> launchStreaming({
    required int tmdbId,
    String? imdbId,
    String? title,
    int? season,
    int? episode,
    String? backdropPath,
    String? posterPath,
    String? mediaType,
    int? resumePositionMs,
    String? logoUrl,
    String? nextEpisodePayload,
  }) async {
    final result = await _channel.invokeMethod<bool>('launchStreamingPlayer', {
      'tmdbId': tmdbId,
      'imdbId': imdbId ?? '',
      'title': title ?? '',
      'season': season ?? -1,
      'episode': episode ?? -1,
      'backdropPath': backdropPath ?? '',
      'posterPath': posterPath ?? '',
      'mediaType': mediaType ?? 'movie',
      'resumePositionMs': resumePositionMs ?? 0,
      'logoUrl': logoUrl ?? '',
      'nextEpisodePayload': nextEpisodePayload ?? '',
    });
    return result ?? false;
  }
}
