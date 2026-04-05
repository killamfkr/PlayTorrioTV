import 'live_tv_service.dart';
import 'stremio_addon_service.dart';

/// One row from a Stremio TV catalog (live channel).
class StremioLiveChannel {
  final String id;
  final String name;
  final String? poster;
  final String addonBaseUrl;
  final String addonName;

  const StremioLiveChannel({
    required this.id,
    required this.name,
    this.poster,
    required this.addonBaseUrl,
    required this.addonName,
  });

  /// Group label for filtering (addon name).
  String get groupTitle => addonName;
}

/// Loads TV catalog channels from installed Stremio addons and builds EPG from meta `videos`.
class StremioLiveTvService {
  StremioLiveTvService._();
  static final StremioLiveTvService instance = StremioLiveTvService._();

  final Map<String, Map<String, List<EpgProgramme>>> _epgCache = {};
  final Map<String, Map<String, dynamic>?> _metaCache = {};

  void clearCache() {
    _epgCache.clear();
    _metaCache.clear();
  }

  /// Catalog entries where [catalogType] is `tv` (live TV addons).
  static List<Map<String, dynamic>> getTvCatalogs() {
    return StremioAddonService.getAllCatalogs()
        .where((c) => (c['catalogType'] as String?) == 'tv')
        .toList();
  }

  /// Fetch channel list for one catalog definition.
  Future<List<StremioLiveChannel>> loadCatalogChannels(Map<String, dynamic> cat) async {
    final baseUrl = cat['addonBaseUrl'] as String? ?? '';
    final type = cat['catalogType'] as String? ?? 'tv';
    final id = cat['catalogId'] as String? ?? '';
    final addonName = cat['addonName'] as String? ?? 'Addon';
    if (baseUrl.isEmpty || id.isEmpty) return [];

    final metas = await StremioAddonService.getCatalog(
      baseUrl: baseUrl,
      type: type,
      id: id,
    );
    final out = <StremioLiveChannel>[];
    for (final m in metas) {
      final cid = m['id']?.toString() ?? '';
      if (cid.isEmpty) continue;
      final title = (m['name'] ?? m['title'] ?? cid).toString();
      String? poster = m['poster'] as String?;
      if (poster == null || poster.isEmpty) {
        poster = m['logo'] as String?;
      }
      out.add(StremioLiveChannel(
        id: cid,
        name: title,
        poster: poster,
        addonBaseUrl: baseUrl,
        addonName: addonName,
      ));
    }
    return out;
  }

  /// All channels from every TV catalog (merged).
  Future<List<StremioLiveChannel>> loadAllTvChannels() async {
    final cats = getTvCatalogs();
    if (cats.isEmpty) return [];
    final futures = cats.map(loadCatalogChannels);
    final lists = await Future.wait(futures);
    return lists.expand((e) => e).toList();
  }

  /// Full meta + EPG map for [channelId] on [addonBaseUrl] (cached).
  Future<({Map<String, dynamic>? meta, Map<String, List<EpgProgramme>> epg})> getMetaAndEpg({
    required String addonBaseUrl,
    required String channelId,
  }) async {
    final cacheKey = '$addonBaseUrl|$channelId';
    if (_metaCache.containsKey(cacheKey) && _epgCache.containsKey(cacheKey)) {
      return (meta: _metaCache[cacheKey], epg: _epgCache[cacheKey]!);
    }

    final meta = await StremioAddonService.getMeta(
      baseUrl: addonBaseUrl,
      type: 'tv',
      id: channelId,
    );
    _metaCache[cacheKey] = meta;

    final epg = <String, List<EpgProgramme>>{};
    if (meta != null) {
      final programmes = _videosToProgrammes(meta['videos']);
      if (programmes.isNotEmpty) {
        epg[channelId] = programmes;
      }
    }
    _epgCache[cacheKey] = epg;

    return (meta: meta, epg: epg);
  }

  static List<EpgProgramme> _videosToProgrammes(dynamic videosRaw) {
    if (videosRaw is! List) return [];
    final items = <({DateTime start, String title})>[];
    for (final v in videosRaw) {
      if (v is! Map) continue;
      final title = (v['title'] ?? v['name'] ?? 'Programme').toString();
      DateTime? start;
      final released = v['released'];
      if (released is String && released.isNotEmpty) {
        start = DateTime.tryParse(released);
      }
      if (start == null) continue;
      items.add((start: start, title: title));
    }
    items.sort((a, b) => a.start.compareTo(b.start));
    if (items.isEmpty) return [];

    final programmes = <EpgProgramme>[];
    for (var i = 0; i < items.length; i++) {
      final start = items[i].start;
      final end = i + 1 < items.length ? items[i + 1].start : start.add(const Duration(hours: 1));
      programmes.add(EpgProgramme(start: start, end: end, title: items[i].title));
    }
    return programmes;
  }

  /// First direct HTTP playable stream for this channel, if any.
  static Future<String?> resolveStreamUrl({
    required String addonBaseUrl,
    required String channelId,
  }) async {
    final raw = await StremioAddonService.getStreams(
      baseUrl: addonBaseUrl,
      type: 'tv',
      id: channelId,
    );
    for (final s in raw) {
      final url = s['url'] as String?;
      if (url != null &&
          url.isNotEmpty &&
          (url.startsWith('http://') || url.startsWith('https://'))) {
        return url;
      }
    }
    return null;
  }
}
