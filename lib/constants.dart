import 'package:flutter/material.dart';

/// Bundled brand assets (see `tool/gen_playtorrio_launcher_pngs.py`).
class AppAssets {
  static const String playtorrioMark = 'assets/images/playtorrio_mark.png';
}

class AppColors {
  static const Color background = Color(0xFF000000);
  static const Color surface = Color(0xFF0D0D0D);
  static const Color surfaceLight = Color(0xFF1A1A1A);
  static const Color darkPurple = Color(0xFF2A2A2A);
  static const Color purple = Color(0xFFE5E5E5);
  static const Color purpleLight = Color(0xFFFFFFFF);
  static const Color darkBlue = Color(0xFF141414);
  static const Color blue = Color(0xFF1E1E1E);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFA0A0A0);
  static const Color textDim = Color(0xFF505050);
  static const Color focusBorder = Color(0xFFFFFFFF);
  static const Color cardBg = Color(0xFF141414);
}

class TmdbApi {
  /// Same key as PlayTorrioV2 (`lib/api/tmdb_api.dart`) so list ordering matches mobile.
  static const String apiKey = 'c3515fdc674ea2bd7b514f4bc3616a4a';
  static const String baseUrl = 'https://api.themoviedb.org/3';
  static const String imageBase = 'https://image.tmdb.org/t/p';

  static String posterUrl(String? path, {String size = 'w342'}) {
    if (path == null || path.isEmpty) return '';
    return '$imageBase/$size$path';
  }

  static String backdropUrl(String? path, {String size = 'w1280'}) {
    if (path == null || path.isEmpty) return '';
    return '$imageBase/$size$path';
  }

  static String profileUrl(String? path, {String size = 'w185'}) {
    if (path == null || path.isEmpty) return '';
    return '$imageBase/$size$path';
  }

  static String logoUrl(String? path, {String size = 'w500'}) {
    if (path == null || path.isEmpty) return '';
    return '$imageBase/$size$path';
  }
}
