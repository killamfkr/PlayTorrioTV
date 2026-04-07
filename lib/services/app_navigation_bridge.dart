import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Receives intents from Android when the native player triggers "next episode".
class AppNavigationBridge {
  AppNavigationBridge._();

  static const _channel = MethodChannel('com.playtorrio/app_nav');
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  static void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'playNextEpisode') {
        final raw = call.arguments;
        if (raw is String) {
          _handleNextEpisodeJson(raw);
        }
      }
    });
  }

  static void _handleNextEpisodeJson(String jsonPayload) {
    try {
      final map = jsonDecode(jsonPayload) as Map<String, dynamic>;
      final tmdbId = map['tmdbId'] as int?;
      if (tmdbId == null) {
        return;
      }
      final season = map['season'] as int? ?? 1;
      final episode = map['episode'] as int? ?? 1;
      final title = map['title'] as String? ?? '';
      final imdbId = map['imdbId'] as String? ?? '';
      final backdropPath = map['backdropPath'] as String? ?? '';
      final posterPath = map['posterPath'] as String? ?? '';
      final mediaType = map['mediaType'] as String? ?? 'tv';
      final logoUrl = map['logoUrl'] as String? ?? '';

      final nav = navigatorKey.currentState;
      if (nav == null) {
        return;
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        nav.pushNamedAndRemoveUntil(
          '/details',
          (route) => route.isFirst,
          arguments: {
            'id': tmdbId,
            'media_type': mediaType,
            'auto_play_episode': {
              'season': season,
              'episode': episode,
              'show_title': title,
              'imdb_id': imdbId,
              'backdrop_path': backdropPath,
              'poster_path': posterPath,
              'logo_url': logoUrl,
            },
          },
        );
      });
    } catch (_) {}
  }
}
