import 'dart:convert';

import 'settings_service.dart';

/// JSON for native player: next episode + skip intro (TMDB TV only).
String? nextEpisodePayloadForPlayer({
  required int tmdbId,
  required String mediaType,
  required int season,
  required int episode,
  required String showTitle,
  required String imdbId,
  required String backdropPath,
  required String posterPath,
  required String logoUrl,
}) {
  if (mediaType != 'tv') {
    return null;
  }
  final s = SettingsService.instance;
  final payload = <String, dynamic>{
    'tmdbId': tmdbId,
    'mediaType': mediaType,
    'season': season,
    'episode': episode + 1,
    'title': showTitle,
    'imdbId': imdbId,
    'backdropPath': backdropPath,
    'posterPath': posterPath,
    'logoUrl': logoUrl,
    'nextEpisodeAuto': s.nextEpisodeAutoEnabled,
    'nextEpisodeCountdownSec': s.nextEpisodeCountdownSec,
    'skipIntroSec': s.skipIntroSeconds,
  };
  return jsonEncode(payload);
}
