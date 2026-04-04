import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class _CachedUrl {
  final String url;
  final DateTime cachedAt;
  _CachedUrl(this.url) : cachedAt = DateTime.now();
  bool get isExpired => DateTime.now().difference(cachedAt).inHours >= 5;
}

class MusicTrack {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String cover;
  final int duration;

  MusicTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.cover,
    required this.duration,
  });

  factory MusicTrack.fromJson(Map<String, dynamic> json) {
    final artistObj = json['artist'];
    final albumObj = json['album'];

    String artistName = 'Unknown Artist';
    if (artistObj is Map) {
      artistName = artistObj['name'] ?? 'Unknown Artist';
    } else if (artistObj is String) {
      artistName = artistObj;
    }

    String albumTitle = '';
    String coverUrl = '';
    if (albumObj is Map) {
      albumTitle = albumObj['title'] ?? '';
      coverUrl = albumObj['cover_xl'] ?? albumObj['cover_big'] ?? albumObj['cover_medium'] ?? albumObj['cover_small'] ?? '';
    } else if (albumObj is String) {
      albumTitle = albumObj;
      coverUrl = json['cover'] ?? '';
    }

    return MusicTrack(
      id: json['id'].toString(),
      title: json['title'] ?? 'Unknown Title',
      artist: artistName,
      album: albumTitle,
      cover: coverUrl.isNotEmpty ? coverUrl : (json['cover'] ?? ''),
      duration: json['duration'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'cover': cover,
    'duration': duration,
  };
}

class MusicAlbum {
  final String id;
  final String title;
  final String artist;
  final String cover;
  final int? nbTracks;

  MusicAlbum({
    required this.id,
    required this.title,
    required this.artist,
    required this.cover,
    this.nbTracks,
  });

  factory MusicAlbum.fromJson(Map<String, dynamic> json) {
    final artistObj = json['artist'] ?? {};
    return MusicAlbum(
      id: json['id'].toString(),
      title: json['title'] ?? '',
      artist: artistObj is Map ? (artistObj['name'] ?? 'Unknown Artist') : (artistObj is String ? artistObj : 'Unknown Artist'),
      cover: json['cover_xl'] ?? json['cover_big'] ?? json['cover_medium'] ?? json['cover_small'] ?? json['cover'] ?? '',
      nbTracks: json['nbTracks'] ?? json['nb_tracks'],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'cover': cover,
    'nbTracks': nbTracks,
  };
}

class MusicPlaylist {
  final String name;
  final List<MusicTrack> tracks;

  MusicPlaylist({required this.name, required this.tracks});

  factory MusicPlaylist.fromJson(Map<String, dynamic> json) {
    return MusicPlaylist(
      name: json['name'] ?? '',
      tracks: (json['tracks'] as List? ?? []).map((t) => MusicTrack.fromJson(t as Map<String, dynamic>)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'tracks': tracks.map((t) => t.toJson()).toList(),
  };
}

class MusicService {
  final _yt = YoutubeExplode();
  static const String _proxyUrl = 'https://deezer-proxy.aymanisthedude1.workers.dev/?url=';

  final Map<String, String> _videoIdCache = {};
  final Map<String, _CachedUrl> _streamUrlCache = {};

  Future<T> _withRetry<T>(Future<T> Function() fn, T fallback, {int maxRetries = 5}) async {
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final result = await fn();
        if (result is List && result.isEmpty && attempt < maxRetries) {
          debugPrint('MusicService: Attempt $attempt returned empty, retrying...');
          await Future.delayed(Duration(milliseconds: 300 * attempt));
          continue;
        }
        return result;
      } catch (e) {
        debugPrint('MusicService: Attempt $attempt failed: $e');
        if (attempt < maxRetries) {
          await Future.delayed(Duration(milliseconds: 300 * attempt));
        }
      }
    }
    return fallback;
  }

  Future<List<MusicTrack>> searchTracks(String query) => _withRetry(() async {
    final targetUri = Uri.https('api.deezer.com', '/search', {'q': query});
    final proxiedUrl = '$_proxyUrl${Uri.encodeComponent(targetUri.toString())}';
    final response = await http.get(Uri.parse(proxiedUrl));
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final items = data['data'] as List;
      return items.map((item) => MusicTrack.fromJson(item)).toList();
    }
    return <MusicTrack>[];
  }, <MusicTrack>[]);

  Future<List<MusicAlbum>> searchAlbums(String query) => _withRetry(() async {
    final targetUri = Uri.https('api.deezer.com', '/search/album', {'q': query});
    final proxiedUrl = '$_proxyUrl${Uri.encodeComponent(targetUri.toString())}';
    final response = await http.get(Uri.parse(proxiedUrl));
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final items = data['data'] as List;
      return items.map((item) => MusicAlbum.fromJson(item)).toList();
    }
    return <MusicAlbum>[];
  }, <MusicAlbum>[]);

  Future<List<MusicTrack>> getAlbumTracks(String albumId) => _withRetry(() async {
    final targetUri = Uri.https('api.deezer.com', '/album/$albumId/tracks');
    final proxiedUrl = '$_proxyUrl${Uri.encodeComponent(targetUri.toString())}';
    final response = await http.get(Uri.parse(proxiedUrl));
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final items = data['data'] as List;
      return items.map((item) => MusicTrack.fromJson(item)).toList();
    }
    return <MusicTrack>[];
  }, <MusicTrack>[]);

  Future<MusicAlbum?> getAlbumDetails(String albumId) async {
    try {
      final targetUri = Uri.https('api.deezer.com', '/album/$albumId');
      final proxiedUrl = '$_proxyUrl${Uri.encodeComponent(targetUri.toString())}';
      final response = await http.get(Uri.parse(proxiedUrl));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return MusicAlbum.fromJson(data);
      }
    } catch (e) {
      debugPrint('MusicService: Album detail error: $e');
    }
    return null;
  }

  Future<List<MusicTrack>> getTrendingTracks({int index = 0, int limit = 20}) => _withRetry(() async {
    final targetUri = Uri.https('api.deezer.com', '/chart/0/tracks', {
      'index': index.toString(),
      'limit': limit.toString(),
    });
    final proxiedUrl = '$_proxyUrl${Uri.encodeComponent(targetUri.toString())}';
    final response = await http.get(Uri.parse(proxiedUrl));
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final items = data['data'] as List;
      return items.map((item) => MusicTrack.fromJson(item)).toList();
    }
    return <MusicTrack>[];
  }, <MusicTrack>[]);

  Future<String?> getYoutubeVideoId(String title, String artist) async {
    final cacheKey = '$title|$artist';
    if (_videoIdCache.containsKey(cacheKey)) {
      debugPrint('MusicService: Video ID cache hit for "$title"');
      return _videoIdCache[cacheKey];
    }

    try {
      final searchQuery = '$title - $artist (Official Audio)';
      final searchList = await _yt.search.search(searchQuery);
      if (searchList.isNotEmpty) {
        for (final video in searchList) {
          if (video.duration != null && video.duration!.inSeconds > 60) {
            _videoIdCache[cacheKey] = video.id.value;
            return video.id.value;
          }
        }
        _videoIdCache[cacheKey] = searchList.first.id.value;
        return searchList.first.id.value;
      }
    } catch (e) {
      debugPrint('MusicService: YouTube matching error: $e');
    }
    return null;
  }

  Future<String?> getYoutubeStreamUrl(String videoId) async {
    final cached = _streamUrlCache[videoId];
    if (cached != null && !cached.isExpired) {
      debugPrint('MusicService: Stream URL cache hit');
      return cached.url;
    }

    final clientSets = [
      [YoutubeApiClient.androidVr],
      [YoutubeApiClient.tv],
    ];

    for (final clients in clientSets) {
      try {
        final manifest = await _yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: clients,
        );
        final audioStreams = manifest.audioOnly.toList();
        if (audioStreams.isEmpty) continue;
        audioStreams.sort((a, b) => b.bitrate.compareTo(a.bitrate));
        final url = audioStreams.first.url.toString();
        _streamUrlCache[videoId] = _CachedUrl(url);
        debugPrint('MusicService: Got stream URL via ${clients.first}');
        return url;
      } catch (e) {
        debugPrint('MusicService: ${clients.first} failed: $e');
      }
    }

    debugPrint('MusicService: All clients failed for $videoId');
    return null;
  }

  void dispose() {
    _yt.close();
  }
}
