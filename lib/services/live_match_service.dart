import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class LiveMatch {
  final String id;
  final String title;
  final String category;
  final int date;
  final String? poster;
  final bool popular;
  final String? homeTeam;
  final String? homeBadge;
  final String? awayTeam;
  final String? awayBadge;
  final List<MatchSource> sources;

  LiveMatch({
    required this.id,
    required this.title,
    required this.category,
    required this.date,
    this.poster,
    required this.popular,
    this.homeTeam,
    this.homeBadge,
    this.awayTeam,
    this.awayBadge,
    required this.sources,
  });

  factory LiveMatch.fromJson(Map<String, dynamic> json) {
    final teams = json['teams'] as Map<String, dynamic>?;
    final home = teams?['home'] as Map<String, dynamic>?;
    final away = teams?['away'] as Map<String, dynamic>?;

    return LiveMatch(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      category: json['category'] as String? ?? '',
      date: json['date'] as int? ?? 0,
      poster: json['poster'] as String?,
      popular: json['popular'] as bool? ?? false,
      homeTeam: home?['name'] as String?,
      homeBadge: home?['badge'] as String?,
      awayTeam: away?['name'] as String?,
      awayBadge: away?['badge'] as String?,
      sources: (json['sources'] as List<dynamic>?)
              ?.map((s) => MatchSource.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  bool get isLive => DateTime.fromMillisecondsSinceEpoch(date).isBefore(DateTime.now());

  String get badgeUrl {
    if (homeBadge != null) return 'https://streamed.pk/api/images/badge/$homeBadge.webp';
    return '';
  }
}

class MatchSource {
  final String source;
  final String id;

  MatchSource({required this.source, required this.id});

  factory MatchSource.fromJson(Map<String, dynamic> json) => MatchSource(
        source: json['source'] as String? ?? '',
        id: json['id'] as String? ?? '',
      );
}

class MatchStream {
  final String id;
  final int streamNo;
  final String language;
  final bool hd;
  final String embedUrl;
  final String source;

  MatchStream({
    required this.id,
    required this.streamNo,
    required this.language,
    required this.hd,
    required this.embedUrl,
    required this.source,
  });

  factory MatchStream.fromJson(Map<String, dynamic> json) => MatchStream(
        id: json['id'] as String? ?? '',
        streamNo: json['streamNo'] as int? ?? 0,
        language: json['language'] as String? ?? '',
        hd: json['hd'] as bool? ?? false,
        embedUrl: json['embedUrl'] as String? ?? '',
        source: json['source'] as String? ?? '',
      );
}

class SportCategory {
  final String id;
  final String name;

  SportCategory({required this.id, required this.name});

  factory SportCategory.fromJson(Map<String, dynamic> json) => SportCategory(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
      );
}

class LiveMatchService {
  static const String _baseUrl = 'https://streamed.pk/api';
  static final http.Client _client = http.Client();

  static Future<List<SportCategory>> getSports() async {
    try {
      final res = await _client.get(Uri.parse('$_baseUrl/sports'));
      if (res.statusCode != 200) return [];
      final list = json.decode(res.body) as List;
      return list.map((e) => SportCategory.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('[LiveMatch] getSports error: $e');
      return [];
    }
  }

  static Future<List<LiveMatch>> getMatches(String sport) async {
    try {
      final res = await _client.get(Uri.parse('$_baseUrl/matches/$sport'));
      if (res.statusCode != 200) return [];
      final list = json.decode(res.body) as List;
      return list.map((e) => LiveMatch.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('[LiveMatch] getMatches error: $e');
      return [];
    }
  }

  static Future<List<LiveMatch>> getLiveMatches() async {
    try {
      final res = await _client.get(Uri.parse('$_baseUrl/matches/live'));
      if (res.statusCode != 200) return [];
      final list = json.decode(res.body) as List;
      return list.map((e) => LiveMatch.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('[LiveMatch] getLiveMatches error: $e');
      return [];
    }
  }

  static Future<List<LiveMatch>> getAllMatches() async {
    try {
      final res = await _client.get(Uri.parse('$_baseUrl/matches/all'));
      if (res.statusCode != 200) return [];
      final list = json.decode(res.body) as List;
      return list.map((e) => LiveMatch.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('[LiveMatch] getAllMatches error: $e');
      return [];
    }
  }

  static Future<List<MatchStream>> getStreams(String source, String id) async {
    try {
      final res = await _client.get(Uri.parse('$_baseUrl/stream/$source/$id'));
      if (res.statusCode != 200) return [];
      final list = json.decode(res.body) as List;
      return list.map((e) => MatchStream.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('[LiveMatch] getStreams error: $e');
      return [];
    }
  }

  static String badgeUrl(String? badge) {
    if (badge == null || badge.isEmpty) return '';
    return 'https://streamed.pk/api/images/badge/$badge.webp';
  }

  static String posterUrl(String? poster) {
    if (poster == null || poster.isEmpty) return '';
    return 'https://streamed.pk/api/images/proxy/$poster.webp';
  }
}
