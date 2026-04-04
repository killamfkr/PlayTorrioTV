import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as hp;
import 'local_proxy_service.dart';

class Audiobook {
  final String uuid;
  final String audioBookId;
  final String dynamicSlugId;
  final String title;
  final String coverImage;
  final String? source;
  final String? pageUrl;

  Audiobook({
    required this.uuid,
    required this.audioBookId,
    required this.dynamicSlugId,
    required this.title,
    required this.coverImage,
    this.source = 'tokybook',
    this.pageUrl,
  });

  String get thumbUrl {
    if (source == 'audiozaic' || source == 'goldenaudiobook' || source == 'appaudiobooks') return coverImage;
    return 'https://tokybook.com/images/$audioBookId';
  }

  factory Audiobook.fromJson(Map<String, dynamic> json) {
    final source = json['source'] ?? 'tokybook';
    final uuid = json['uuid'] ?? '';
    return Audiobook(
      uuid: uuid,
      audioBookId: json['audioBookId'] ?? '',
      dynamicSlugId: json['dynamicSlugId'] ?? '',
      title: json['title'] ?? '',
      coverImage: json['coverImage'] ?? '',
      source: source,
      pageUrl: json['pageUrl'] ?? ((source == 'audiozaic' || source == 'goldenaudiobook') ? uuid : null),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'uuid': uuid,
      'audioBookId': audioBookId,
      'dynamicSlugId': dynamicSlugId,
      'title': title,
      'coverImage': coverImage,
      'source': source,
      'pageUrl': pageUrl,
    };
  }
}

class AudiobookChapter {
  final String title;
  final String url;
  final Map<String, String>? headers;

  AudiobookChapter({required this.title, required this.url, this.headers});
}

class AudiobookService {
  static const String _baseUrl = 'https://tokybook.com/api/v1';

  Map<String, dynamic> _getUserIdentity() {
    return {
      "ipAddress": "",
      "userAgent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
      "timestamp": DateTime.now().toUtc().toIso8601String(),
    };
  }

  Map<String, String> _getHeaders() {
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Origin': 'https://tokybook.com',
      'Referer': 'https://tokybook.com/',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36',
    };
  }

  static const _webUA = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  };

  Future<List<Audiobook>> getAudiobooks({int offset = 0, int limit = 12}) async {
    try {
      final payload = {
        "offset": offset,
        "limit": limit,
        "typeFilter": "audiobook",
        "slugIdFilter": null,
        "userIdentity": _getUserIdentity()
      };

      final response = await http.post(
        Uri.parse('$_baseUrl/search/audiobooks'),
        headers: _getHeaders(),
        body: json.encode(payload),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List items = data['content'] ?? [];
        return items.map((j) => Audiobook.fromJson(j as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      debugPrint('AudiobookService Error (getAudiobooks): $e');
    }
    return [];
  }

  String _cleanTitle(String title) {
    return title
        .replaceAll(RegExp(r'\[Listen\]', caseSensitive: false), '')
        .replaceAll(RegExp(r'\[Download\]', caseSensitive: false), '')
        .replaceAll(RegExp(r'Audiobook', caseSensitive: false), '')
        .replaceAll(RegExp(r'Online', caseSensitive: false), '')
        .split('–').last
        .split('-').last
        .trim();
  }

  String _normalizeTitle(String title) {
    return _cleanTitle(title).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  int _relevanceScore(String title, String query) {
    final titleLower = title.toLowerCase();
    if (titleLower == query) return 0;
    if (titleLower.startsWith(query)) return 1;
    if (titleLower.contains(query)) return 2;
    final queryWords = query.split(RegExp(r'\s+'));
    int matches = queryWords.where((w) => titleLower.contains(w)).length;
    if (matches == queryWords.length) return 3;
    return 4 + (queryWords.length - matches);
  }

  Future<List<Audiobook>> searchAudiobooks(String query) async {
    try {
      final results = await Future.wait([
        _searchGoldenAudiobook(query),
        _searchAppAudiobooks(query),
        _searchTokybook(query),
        _searchAudiozaic(query),
      ]);

      final goldenResults = results[0];
      final appAudioResults = results[1];
      final tokyResults = results[2];
      final audiozaicResults = results[3];

      final Map<String, Audiobook> uniqueBooks = {};

      for (var book in goldenResults) {
        final key = _normalizeTitle(book.title);
        if (key.isNotEmpty) uniqueBooks[key] = book;
      }
      for (var book in appAudioResults) {
        final key = _normalizeTitle(book.title);
        if (key.isNotEmpty && !uniqueBooks.containsKey(key)) uniqueBooks[key] = book;
      }
      for (var book in tokyResults) {
        final key = _normalizeTitle(book.title);
        if (key.isNotEmpty && !uniqueBooks.containsKey(key)) uniqueBooks[key] = book;
      }
      for (var book in audiozaicResults) {
        final key = _normalizeTitle(book.title);
        if (key.isNotEmpty && !uniqueBooks.containsKey(key)) uniqueBooks[key] = book;
      }

      final queryNorm = query.toLowerCase().trim();
      final bookList = uniqueBooks.values.toList();
      bookList.sort((a, b) => _relevanceScore(a.title, queryNorm).compareTo(_relevanceScore(b.title, queryNorm)));
      return bookList;
    } catch (e) {
      debugPrint('AudiobookService Error (searchAudiobooks): $e');
    }
    return [];
  }

  Future<List<Audiobook>> _searchTokybook(String query) async {
    try {
      final payload = {
        "query": query,
        "offset": 0,
        "limit": 20,
        "userIdentity": _getUserIdentity()
      };

      final response = await http.post(
        Uri.parse('$_baseUrl/search/instant'),
        headers: _getHeaders(),
        body: json.encode(payload),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List items = data['content'] ?? [];
        return items.map((j) => Audiobook.fromJson(j as Map<String, dynamic>)).toList();
      }
    } catch (e) {
      debugPrint('AudiobookService Error (_searchTokybook): $e');
    }
    return [];
  }

  Future<List<Audiobook>> _searchAudiozaic(String query) async {
    try {
      final searchUrl = 'https://audiozaic.com/?s=${Uri.encodeComponent(query)}';
      final response = await http.get(Uri.parse(searchUrl), headers: _webUA);
      if (response.statusCode != 200) return [];

      final document = hp.parse(response.body);
      final articles = document.querySelectorAll('article.vce-post');

      List<Audiobook> results = [];
      for (var article in articles) {
        final titleElement = article.querySelector('h2.entry-title a');
        final pageUrl = titleElement?.attributes['href'] ?? '';
        var title = _cleanTitle(titleElement?.text ?? '');

        final imgElement = article.querySelector('div.meta-image img');
        var coverUrl = imgElement?.attributes['data-src'] ?? imgElement?.attributes['src'] ?? '';
        if (coverUrl.contains('-') && coverUrl.contains('x')) {
          coverUrl = coverUrl.replaceFirstMapped(RegExp(r'-\d+x\d+\.(jpg|jpeg|png|webp)'), (match) => '.${match.group(1)}');
        }

        if (pageUrl.isNotEmpty) {
          final uri = Uri.parse(pageUrl);
          final pathSegments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
          final slug = pathSegments.isNotEmpty ? pathSegments.last : pageUrl.hashCode.toString();

          results.add(Audiobook(
            uuid: pageUrl,
            audioBookId: 'az_$slug',
            dynamicSlugId: pageUrl,
            title: title,
            coverImage: coverUrl,
            source: 'audiozaic',
            pageUrl: pageUrl,
          ));
        }
      }
      return results;
    } catch (e) {
      debugPrint('AudiobookService Error (_searchAudiozaic): $e');
    }
    return [];
  }

  Future<List<Audiobook>> _searchGoldenAudiobook(String query) async {
    try {
      final searchUrl = 'https://goldenaudiobook.net/?s=${Uri.encodeComponent(query)}';
      final response = await http.get(Uri.parse(searchUrl), headers: _webUA);
      if (response.statusCode != 200) return [];

      final document = hp.parse(response.body);
      final articles = document.querySelectorAll('li.ilovewp-post');

      List<Audiobook> results = [];
      for (var article in articles) {
        final titleElement = article.querySelector('h2.title-post a');
        final pageUrl = titleElement?.attributes['href'] ?? '';
        var title = _cleanTitle(titleElement?.text ?? '');

        final imgElement = article.querySelector('div.post-cover img');
        var coverUrl = imgElement?.attributes['data-src'] ?? imgElement?.attributes['src'] ?? '';
        if (coverUrl.contains('-') && coverUrl.contains('x')) {
          coverUrl = coverUrl.replaceFirstMapped(RegExp(r'-\d+x\d+\.(jpg|jpeg|png|webp)'), (match) => '.${match.group(1)}');
        }

        if (pageUrl.isNotEmpty) {
          final uri = Uri.parse(pageUrl);
          final pathSegments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
          final slug = pathSegments.isNotEmpty ? pathSegments.last : pageUrl.hashCode.toString();

          results.add(Audiobook(
            uuid: pageUrl,
            audioBookId: 'ga_$slug',
            dynamicSlugId: pageUrl,
            title: title,
            coverImage: coverUrl,
            source: 'goldenaudiobook',
            pageUrl: pageUrl,
          ));
        }
      }
      return results;
    } catch (e) {
      debugPrint('AudiobookService Error (_searchGoldenAudiobook): $e');
    }
    return [];
  }

  Future<List<Audiobook>> _searchAppAudiobooks(String query) async {
    try {
      final searchUrl = 'https://appaudiobooks.net/wp-admin/admin-ajax.php'
          '?s=${Uri.encodeComponent(query)}'
          '&action=searchwp_live_search'
          '&swpengine=default'
          '&swpquery=${Uri.encodeComponent(query)}'
          '&origin_id=0';

      final response = await http.get(Uri.parse(searchUrl), headers: {
        ..._webUA,
        'Referer': 'https://appaudiobooks.net/',
      });
      if (response.statusCode != 200) return [];

      final document = hp.parse(response.body);
      final links = document.querySelectorAll('a[href]');

      List<Audiobook> results = [];
      final seen = <String>{};

      for (var link in links) {
        final pageUrl = link.attributes['href'] ?? '';
        if (pageUrl.isEmpty || !pageUrl.contains('appaudiobooks.net')) continue;
        if (seen.contains(pageUrl)) continue;
        seen.add(pageUrl);

        var title = _cleanTitle(link.text.trim());
        if (title.isEmpty) continue;

        final uri = Uri.parse(pageUrl);
        final pathSegments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
        final slug = pathSegments.isNotEmpty ? pathSegments.last : pageUrl.hashCode.toString();

        results.add(Audiobook(
          uuid: pageUrl,
          audioBookId: 'aab_$slug',
          dynamicSlugId: pageUrl,
          title: title,
          coverImage: '',
          source: 'appaudiobooks',
          pageUrl: pageUrl,
        ));
      }

      // Fetch covers in parallel
      final futures = results.map((book) async {
        try {
          final cover = await _fetchAppAudiobookCover(book.pageUrl!);
          if (cover.isNotEmpty) {
            return Audiobook(
              uuid: book.uuid,
              audioBookId: book.audioBookId,
              dynamicSlugId: book.dynamicSlugId,
              title: book.title,
              coverImage: cover,
              source: book.source,
              pageUrl: book.pageUrl,
            );
          }
        } catch (_) {}
        return book;
      }).toList();

      return await Future.wait(futures);
    } catch (e) {
      debugPrint('AudiobookService Error (_searchAppAudiobooks): $e');
    }
    return [];
  }

  Future<String> _fetchAppAudiobookCover(String pageUrl) async {
    try {
      final res = await http.get(Uri.parse(pageUrl), headers: _webUA);
      if (res.statusCode != 200) return '';
      final doc = hp.parse(res.body);
      final img = doc.querySelector('.wp-caption img') ?? doc.querySelector('.entry img');
      return img?.attributes['src'] ?? '';
    } catch (_) {}
    return '';
  }

  // --- Chapter fetching ---

  Future<List<AudiobookChapter>> getChapters(Audiobook book) async {
    if (book.source == 'goldenaudiobook') return _getGoldenChapters(book);
    if (book.source == 'audiozaic') return _getAudiozaicChapters(book);
    if (book.source == 'appaudiobooks') return _getAppAudiobooksChapters(book);
    return _getTokyChapters(book);
  }

  Future<List<AudiobookChapter>> _getTokyChapters(Audiobook book) async {
    try {
      final detailsPayload = {
        "dynamicSlugId": book.dynamicSlugId,
        "userIdentity": _getUserIdentity()
      };

      final detailsRes = await http.post(
        Uri.parse('$_baseUrl/search/post-details'),
        headers: _getHeaders(),
        body: json.encode(detailsPayload),
      );
      if (detailsRes.statusCode != 200) return [];

      final detailsData = json.decode(detailsRes.body);
      final String? token = detailsData['postDetailToken'];
      if (token == null) return [];

      final playlistPayload = {
        "audioBookId": book.audioBookId,
        "postDetailToken": token,
        "userIdentity": _getUserIdentity()
      };

      final playlistRes = await http.post(
        Uri.parse('$_baseUrl/playlist'),
        headers: _getHeaders(),
        body: json.encode(playlistPayload),
      );
      if (playlistRes.statusCode != 200) return [];

      final data = json.decode(playlistRes.body);
      final String streamToken = data['streamToken'] ?? '';
      final List tracks = data['tracks'] ?? [];

      const baseAudioUrl = 'https://tokybook.com/api/v1/public/audio/';
      final proxy = LocalProxyService();

      return tracks.map((t) {
        final src = t['src'] ?? '';
        final title = t['trackTitle'] ?? 'Track';
        final finalUrl = '$baseAudioUrl$src';

        // Encode each segment of the path to match browser behavior exactly
        final encodedSrc = src.split('/').map((p) => Uri.encodeComponent(p)).join('/');
        final fullTrackSrc = '/api/v1/public/audio/$encodedSrc';

        final proxyUrl = proxy.getTokyProxyUrl(
          finalUrl,
          book.audioBookId,
          streamToken,
          fullTrackSrc,
        );

        return AudiobookChapter(
          title: title,
          url: proxyUrl,
          headers: const {},
        );
      }).toList();
    } catch (e) {
      debugPrint('AudiobookService Error (_getTokyChapters): $e');
    }
    return [];
  }

  Future<List<AudiobookChapter>> _getGoldenChapters(Audiobook book) async {
    try {
      if (book.pageUrl == null) return [];
      final pageRes = await http.get(Uri.parse(book.pageUrl!), headers: _webUA);
      if (pageRes.statusCode != 200) return [];

      final document = hp.parse(pageRes.body);
      final audios = document.querySelectorAll('audio.wp-audio-shortcode');

      List<AudiobookChapter> chapters = [];
      for (int i = 0; i < audios.length; i++) {
        final sourceTag = audios[i].querySelector('source');
        final streamUrl = sourceTag?.attributes['src'] ?? '';
        if (streamUrl.isNotEmpty) {
          chapters.add(AudiobookChapter(title: 'Part ${i + 1}', url: streamUrl));
        }
      }
      return chapters;
    } catch (e) {
      debugPrint('AudiobookService Error (_getGoldenChapters): $e');
    }
    return [];
  }

  Future<List<AudiobookChapter>> _getAudiozaicChapters(Audiobook book) async {
    try {
      if (book.pageUrl == null) return [];

      final pageRes = await http.get(Uri.parse(book.pageUrl!), headers: _webUA);
      if (pageRes.statusCode != 200) return [];

      final document = hp.parse(pageRes.body);

      final listenBtn = document.querySelector('button#listen-button');
      final onclick = listenBtn?.attributes['onclick'] ?? '';
      final urlMatch = RegExp(r"window\.open\('([^']+)'").firstMatch(onclick);
      var listenUrl = urlMatch?.group(1);
      if (listenUrl == null) return [];

      if (listenUrl.startsWith('/')) {
        listenUrl = 'https://audiozaic.com$listenUrl';
      } else if (!listenUrl.startsWith('http')) {
        listenUrl = 'https://audiozaic.com/$listenUrl';
      }

      final audioPageRes = await http.get(Uri.parse(listenUrl), headers: {
        ..._webUA,
        'Referer': book.pageUrl!,
      });
      if (audioPageRes.statusCode != 200) return [];

      final audioDoc = hp.parse(audioPageRes.body);
      final tracks = audioDoc.querySelectorAll('div.track');

      List<AudiobookChapter> chapters = [];
      for (var track in tracks) {
        final title = track.querySelector('span.songtitle')?.text ?? 'Part';
        final audioSource = track.querySelector('audio source');
        var streamUrl = audioSource?.attributes['src'] ?? '';
        if (streamUrl.isEmpty) {
          final link = track.querySelector('div.albumtrack a');
          streamUrl = link?.attributes['href'] ?? '';
        }
        if (streamUrl.isNotEmpty) {
          chapters.add(AudiobookChapter(
            title: title,
            url: streamUrl,
            headers: {
              'Referer': 'https://audiozaic.com/',
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            },
          ));
        }
      }
      return chapters;
    } catch (e) {
      debugPrint('AudiobookService Error (_getAudiozaicChapters): $e');
    }
    return [];
  }

  Future<List<AudiobookChapter>> _getAppAudiobooksChapters(Audiobook book) async {
    try {
      if (book.pageUrl == null) return [];
      final pageRes = await http.get(Uri.parse(book.pageUrl!), headers: _webUA);
      if (pageRes.statusCode != 200) return [];

      final document = hp.parse(pageRes.body);
      final audios = document.querySelectorAll('audio.wp-audio-shortcode');

      List<AudiobookChapter> chapters = [];
      for (int i = 0; i < audios.length; i++) {
        final sourceTag = audios[i].querySelector('source');
        var streamUrl = sourceTag?.attributes['src'] ?? '';
        if (streamUrl.contains('?')) {
          streamUrl = streamUrl.substring(0, streamUrl.indexOf('?'));
        }
        if (streamUrl.isNotEmpty) {
          chapters.add(AudiobookChapter(title: 'Chapter ${i + 1}', url: streamUrl));
        }
      }
      return chapters;
    } catch (e) {
      debugPrint('AudiobookService Error (_getAppAudiobooksChapters): $e');
    }
    return [];
  }
}
