import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// One channel from an M3U playlist.
class LiveTvChannel {
  final String name;
  final String streamUrl;
  final String? tvgId;
  final String? logoUrl;
  final String? groupTitle;

  const LiveTvChannel({
    required this.name,
    required this.streamUrl,
    this.tvgId,
    this.logoUrl,
    this.groupTitle,
  });
}

/// A single EPG programme slot.
class EpgProgramme {
  final DateTime start;
  final DateTime end;
  final String title;

  const EpgProgramme({
    required this.start,
    required this.end,
    required this.title,
  });
}

/// XMLTV `<channel id="...">` entry for manual Stremio ↔ EPG mapping.
class EpgChannel {
  final String id;
  final String displayName;

  const EpgChannel({required this.id, required this.displayName});
}

class LiveTvService {
  LiveTvService._();
  static final LiveTvService instance = LiveTvService._();

  List<LiveTvChannel>? _cachedChannels;
  String? _cachedM3uSource;
  Map<String, List<EpgProgramme>>? _epgByChannel;
  String? _cachedEpgSource;
  List<EpgChannel> _cachedEpgChannelList = [];

  List<EpgChannel> get cachedEpgChannelList => List.unmodifiable(_cachedEpgChannelList);

  void clearCache() {
    _cachedChannels = null;
    _cachedM3uSource = null;
    _epgByChannel = null;
    _cachedEpgSource = null;
    _cachedEpgChannelList = [];
  }

  /// Fetches and parses the M3U at [url]. Uses cache when [url] unchanged.
  Future<List<LiveTvChannel>> loadPlaylist(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return [];
    if (_cachedChannels != null && _cachedM3uSource == trimmed) {
      return _cachedChannels!;
    }
    final res = await http.get(Uri.parse(trimmed)).timeout(const Duration(seconds: 45));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Playlist HTTP ${res.statusCode}');
    }
    final body = res.body;
    // Handle UTF-8 BOM
    final text = body.startsWith('\uFEFF') ? body.substring(1) : body;
    final channels = parseM3u(text);
    _cachedChannels = channels;
    _cachedM3uSource = trimmed;
    return channels;
  }

  static List<LiveTvChannel> parseM3u(String text) {
    final lines = const LineSplitter().convert(text);
    final out = <LiveTvChannel>[];
    String? pendingExtInf;

    for (var raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF')) {
        pendingExtInf = line;
        continue;
      }
      if (line.startsWith('#')) continue;
      if (pendingExtInf != null) {
        final parsed = _parseExtInf(pendingExtInf, line);
        if (parsed != null) out.add(parsed);
        pendingExtInf = null;
      }
    }
    return out;
  }

  static LiveTvChannel? _parseExtInf(String extInf, String urlLine) {
    if (!urlLine.startsWith('http://') && !urlLine.startsWith('https://')) {
      return null;
    }
    var tvgId = _attr(extInf, 'tvg-id');
    var tvgLogo = _attr(extInf, 'tvg-logo');
    final group = _attr(extInf, 'group-title');

    var namePart = extInf;
    final comma = extInf.lastIndexOf(',');
    if (comma >= 0 && comma < extInf.length - 1) {
      namePart = extInf.substring(comma + 1).trim();
    } else {
      namePart = 'Channel';
    }

    if (tvgId != null && tvgId.isEmpty) tvgId = null;
    if (tvgLogo != null && tvgLogo.isEmpty) tvgLogo = null;

    return LiveTvChannel(
      name: namePart,
      streamUrl: urlLine.trim(),
      tvgId: tvgId,
      logoUrl: tvgLogo,
      groupTitle: group,
    );
  }

  static String? _attr(String line, String key) {
    final re = RegExp('$key="([^"]*)"', caseSensitive: false);
    final m = re.firstMatch(line);
    if (m != null) return m.group(1);
    final re2 = RegExp("$key='([^']*)'", caseSensitive: false);
    final m2 = re2.firstMatch(line);
    return m2?.group(1);
  }

  /// Loads XMLTV from [url]. Uses cache when [url] unchanged.
  Future<Map<String, List<EpgProgramme>>> loadEpg(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return {};
    if (_epgByChannel != null && _cachedEpgSource == trimmed) {
      return _epgByChannel!;
    }
    final res = await http.get(Uri.parse(trimmed)).timeout(const Duration(seconds: 60));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('EPG HTTP ${res.statusCode}');
    }
    var xmlStr = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (xmlStr.startsWith('\uFEFF')) xmlStr = xmlStr.substring(1);
    final map = parseXmltv(xmlStr);
    _epgByChannel = map;
    _cachedEpgChannelList = parseXmltvChannels(xmlStr);
    _cachedEpgSource = trimmed;
    return map;
  }

  static List<EpgChannel> parseXmltvChannels(String xmlStr) {
    final doc = XmlDocument.parse(xmlStr);
    final out = <EpgChannel>[];
    for (final node in doc.findAllElements('channel')) {
      final id = node.getAttribute('id');
      if (id == null || id.isEmpty) continue;
      var name = id;
      for (final dn in node.findAllElements('display-name')) {
        final t = dn.innerText.trim();
        if (t.isNotEmpty) {
          name = t;
          break;
        }
      }
      out.add(EpgChannel(id: id, displayName: name));
    }
    out.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return out;
  }

  static Map<String, List<EpgProgramme>> parseXmltv(String xmlStr) {
    final doc = XmlDocument.parse(xmlStr);
    final byChannel = <String, List<EpgProgramme>>{};

    for (final node in doc.findAllElements('programme')) {
      final ch = node.getAttribute('channel');
      if (ch == null || ch.isEmpty) continue;
      final start = _parseXmltvDate(node.getAttribute('start'));
      final stop = _parseXmltvDate(node.getAttribute('stop'));
      if (start == null || stop == null) continue;

      String title = 'Programme';
      final titleEl = node.getElement('title');
      if (titleEl != null) {
        final t = titleEl.innerText.trim();
        if (t.isNotEmpty) title = t;
      }

      byChannel.putIfAbsent(ch, () => []).add(
            EpgProgramme(start: start, end: stop, title: title),
          );
    }

    for (final list in byChannel.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }
    return byChannel;
  }

  static DateTime? _parseXmltvDate(String? raw) {
    if (raw == null) return null;
    final head = raw.split(RegExp(r'\s+')).first;
    if (head.length < 14) return null;
    final digits = head.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 14) return null;
    try {
      final y = int.parse(digits.substring(0, 4));
      final mo = int.parse(digits.substring(4, 6));
      final d = int.parse(digits.substring(6, 8));
      final h = int.parse(digits.substring(8, 10));
      final mi = int.parse(digits.substring(10, 12));
      final s = int.parse(digits.substring(12, 14));
      return DateTime(y, mo, d, h, mi, s);
    } catch (_) {
      return null;
    }
  }

  /// Current programme for [tvgId], if EPG is loaded and a match exists.
  static EpgProgramme? currentProgramme(
    Map<String, List<EpgProgramme>> epg,
    String? tvgId,
    DateTime now,
  ) {
    if (tvgId == null || tvgId.isEmpty) return null;
    final list = epg[tvgId];
    if (list == null || list.isEmpty) return null;
    for (final p in list) {
      if (!now.isBefore(p.start) && now.isBefore(p.end)) return p;
    }
    return null;
  }

  /// Next programme after [now] on [tvgId].
  static EpgProgramme? nextProgramme(
    Map<String, List<EpgProgramme>> epg,
    String? tvgId,
    DateTime now,
  ) {
    if (tvgId == null || tvgId.isEmpty) return null;
    final list = epg[tvgId];
    if (list == null || list.isEmpty) return null;
    for (final p in list) {
      if (p.start.isAfter(now)) return p;
    }
    return null;
  }

  /// 0–1 through the current slot, or null if not in range.
  static double? programmeProgress(EpgProgramme? p, DateTime now) {
    if (p == null) return null;
    if (now.isBefore(p.start) || !now.isBefore(p.end)) return null;
    final total = p.end.difference(p.start).inMilliseconds;
    if (total <= 0) return null;
    final elapsed = now.difference(p.start).inMilliseconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  static String _normEpgName(String s) {
    var t = s.toLowerCase().trim();
    t = t.replaceAll(RegExp(r'[\s_\-–—.,|]+'), ' ');
    t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), '');
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Best-effort XMLTV `channel id` for a Stremio channel name/id when auto-match is on.
  static String? matchEpgChannelId(
    String stremioName,
    String stremioId,
    List<EpgChannel> epgChannels,
  ) {
    if (epgChannels.isEmpty) return null;
    final nameNorm = _normEpgName(stremioName);
    final idTrim = stremioId.trim();

    for (final ch in epgChannels) {
      if (ch.id == idTrim || ch.id.toLowerCase() == idTrim.toLowerCase()) {
        return ch.id;
      }
    }
    for (final ch in epgChannels) {
      if (ch.displayName.toLowerCase().trim() == stremioName.toLowerCase().trim()) {
        return ch.id;
      }
    }
    if (nameNorm.isNotEmpty) {
      for (final ch in epgChannels) {
        if (_normEpgName(ch.displayName) == nameNorm) return ch.id;
      }
    }
    if (nameNorm.length >= 4) {
      for (final ch in epgChannels) {
        final dn = _normEpgName(ch.displayName);
        if (dn.isEmpty) continue;
        if (dn.contains(nameNorm) || nameNorm.contains(dn)) {
          if (dn.length >= 4 && nameNorm.length >= 4) return ch.id;
        }
      }
    }
    final stTokens = nameNorm.split(' ').where((t) => t.length > 2).toSet();
    if (stTokens.length >= 2) {
      String? bestId;
      var bestScore = 0;
      for (final ch in epgChannels) {
        final dn = _normEpgName(ch.displayName);
        final chTokens = dn.split(' ').where((t) => t.length > 2).toSet();
        final overlap = stTokens.intersection(chTokens).length;
        if (overlap > bestScore) {
          bestScore = overlap;
          bestId = ch.id;
        }
      }
      if (bestScore >= 2 && bestId != null) return bestId;
    }
    return null;
  }
}
