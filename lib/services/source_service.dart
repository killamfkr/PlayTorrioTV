import 'package:http/http.dart' as http;

class TorrentSource {
  final String name;
  final String magnet;
  final String size;
  final int seeders;
  final String provider;

  TorrentSource({
    required this.name,
    required this.magnet,
    required this.size,
    required this.seeders,
    required this.provider,
  });

  String get btihHash {
    final match = RegExp(r'btih:([A-Fa-f0-9]+)', caseSensitive: false).firstMatch(magnet);
    return match?.group(1)?.toUpperCase() ?? '';
  }
}

class SourceService {
  static Future<List<TorrentSource>> searchMovieSources(String movieName, String year) async {
    final query = '$movieName $year';
    final results = await Future.wait([
      _fetchUIndex(query, category: 'movie'),
      _fetchKnaben(query, category: 'movie'),
    ]);
    return _deduplicateAndSort([...results[0], ...results[1]]);
  }

  static Future<List<TorrentSource>> searchTvSources(String showName, int season, int episode) async {
    final sTag = 'S${season.toString().padLeft(2, '0')}';
    final eTag = 'E${episode.toString().padLeft(2, '0')}';
    final episodeQuery = '$showName $sTag$eTag';
    final seasonQuery = '$showName $sTag';
    final results = await Future.wait([
      _fetchUIndex(episodeQuery, category: 'tv'),
      _fetchKnaben(episodeQuery, category: 'tv'),
      _fetchUIndex(seasonQuery, category: 'tv'),
      _fetchKnaben(seasonQuery, category: 'tv'),
    ]);
    final all = [...results[0], ...results[1], ...results[2], ...results[3]];
    final filtered = _filterTvResults(all, showName, season, episode);
    return _deduplicateAndSort(filtered);
  }

  // ── Smart TV filtering ──

  static List<TorrentSource> _filterTvResults(
    List<TorrentSource> sources,
    String showName,
    int season,
    int episode,
  ) {
    final normalizedShow = _normalize(showName);
    final sTag = 's${season.toString().padLeft(2, '0')}';
    final seTag = '${sTag}e${episode.toString().padLeft(2, '0')}';

    return sources.where((source) {
      final name = _normalize(source.name);
      if (!name.startsWith(normalizedShow)) return false;
      final afterShow = name.substring(normalizedShow.length).trimLeft();
      // Strip optional year
      final afterYear = afterShow.replaceFirst(RegExp(r'^\d{4}\s+'), '');
      // Must start with exact S##E## (episode match) or S## followed by
      // non-episode content (season pack — no E## after S##)
      if (afterYear.startsWith(seTag)) return true;
      if (afterYear.startsWith(sTag) && !RegExp(r'^s\d{1,2}e\d{1,2}\b').hasMatch(afterYear)) return true;
      return false;
    }).toList();
  }

  static String _normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r"[''`]"), '')
        .replaceAll(RegExp(r'[._\-\[\](){}:,!?]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // ── Deduplication ──

  static List<TorrentSource> _deduplicateAndSort(List<TorrentSource> sources) {
    final seen = <String>{};
    final unique = <TorrentSource>[];
    for (final source in sources) {
      final hash = source.btihHash;
      if (hash.isNotEmpty && !seen.contains(hash)) {
        seen.add(hash);
        unique.add(source);
      }
    }
    unique.sort((a, b) => b.seeders.compareTo(a.seeders));
    return unique;
  }

  static Future<List<TorrentSource>> _fetchUIndex(String query, {required String category}) async {
    try {
      final url = Uri.parse(
        'https://uindex.org/search.php?search=${Uri.encodeComponent(query)}&c=0&sort=seeders&order=DESC',
      );
      final response = await http
          .get(url, headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          })
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return [];
      return _parseUIndex(response.body, category: category);
    } catch (_) {
      return [];
    }
  }

  static List<TorrentSource> _parseUIndex(String html, {required String category}) {
    final sources = <TorrentSource>[];
    // Match rows inside <tbody>
    final tbodyMatch = RegExp(r'<tbody>(.*?)</tbody>', dotAll: true).firstMatch(html);
    if (tbodyMatch == null) return sources;
    final tbody = tbodyMatch.group(1)!;
    final rowPattern = RegExp(r'<tr>(.*?)</tr>', dotAll: true);

    for (final rowMatch in rowPattern.allMatches(tbody)) {
      final row = rowMatch.group(1)!;

      // Category filter — check sr-cat-badge text
      if (category == 'movie') {
        final catMatch = RegExp(r'class="sr-cat-badge"[^>]*>[\s\S]*?</svg>\s*(\w+)', dotAll: true).firstMatch(row);
        final catText = catMatch?.group(1)?.trim().toLowerCase() ?? '';
        if (catText != 'movies') continue;
      }

      // Extract magnet link (href="magnet:...")
      final magnetMatch =
          RegExp(r'href="(magnet:\?xt=urn:btih:[^"]*)"').firstMatch(row);
      if (magnetMatch == null) continue;
      final magnet = _decodeHtml(magnetMatch.group(1)!);

      // Extract name from sr-torrent-link title attribute (clean, no <mark> tags)
      final nameMatch =
          RegExp(r'class="sr-torrent-link"\s+title="([^"]+)"').firstMatch(row);
      if (nameMatch == null) continue;
      final name = _decodeHtml(nameMatch.group(1)!.trim());

      // Extract size from sr-col-size td
      final sizeMatch =
          RegExp(r'class="sr-col-size">([^<]+)</td>').firstMatch(row);
      final size = sizeMatch?.group(1)?.trim() ?? '';

      // Extract seeders from sr-seed span
      final seedersMatch =
          RegExp(r'class="sr-seed">([^<]+)</span>').firstMatch(row);
      final seedersStr =
          seedersMatch?.group(1)?.replaceAll(',', '').trim() ?? '0';
      final seeders = int.tryParse(seedersStr) ?? 0;

      sources.add(TorrentSource(
        name: name,
        magnet: magnet,
        size: size,
        seeders: seeders,
        provider: 'UIndex',
      ));
    }
    return sources;
  }

  static Future<List<TorrentSource>> _fetchKnaben(String query, {required String category}) async {
    try {
      final url = Uri.parse(
        'https://knaben.org/search/${Uri.encodeComponent(query)}/0/1/seeders',
      );
      final response = await http
          .get(url, headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          })
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return [];
      return _parseKnaben(response.body, category: category);
    } catch (_) {
      return [];
    }
  }

  static List<TorrentSource> _parseKnaben(String html, {required String category}) {
    final sources = <TorrentSource>[];
    final rowPattern =
        RegExp(r'<tr[^>]*data-id="[^"]*"[^>]*>(.*?)</tr>', dotAll: true);

    for (final rowMatch in rowPattern.allMatches(html)) {
      final row = rowMatch.group(1)!;

      // Category filter — only for movies
      if (category == 'movie' && !row.contains('/browse/3000000/1">Movies</a>')) continue;

      // Extract title and magnet
      final magnetMatch = RegExp(
        r'<a\s+title="([^"]+)"\s+href="(magnet:\?xt=urn:btih:[^"]+)"',
      ).firstMatch(row);
      if (magnetMatch == null) continue;
      final name = _decodeHtml(magnetMatch.group(1)!);
      final magnet = _decodeHtml(magnetMatch.group(2)!);

      // Extract size from td with "Bytes" in title
      final sizeMatch =
          RegExp(r'<td\s+title="\d+\s+Bytes">([^<]+)</td>').firstMatch(row);
      final size = sizeMatch?.group(1)?.trim() ?? '';

      // Extract seeders — 5th <td> in the row
      final tdPattern = RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true);
      final tds = tdPattern.allMatches(row).toList();
      int seeders = 0;
      if (tds.length >= 5) {
        final seedersText =
            tds[4].group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
        seeders = int.tryParse(seedersText.replaceAll(',', '')) ?? 0;
      }

      sources.add(TorrentSource(
        name: name,
        magnet: magnet,
        size: size,
        seeders: seeders,
        provider: 'Knaben',
      ));
    }
    return sources;
  }

  static String _decodeHtml(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
  }
}
