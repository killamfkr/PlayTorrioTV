import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:dpad/dpad.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants.dart';
import '../services/tmdb_service.dart';
import '../services/source_service.dart';
import '../services/stream_service.dart' show EpisodeTarget, StreamService;
import '../services/settings_service.dart';
import '../services/player_launcher.dart';
import '../services/player_session_extras.dart';
import '../services/stremio_addon_service.dart';
import '../main.dart';

// ─── Pre-computed colors (avoid per-frame allocation) ───
const _kBlackOverlay = Color(0x59000000);
const _kBgH1 = Color(0xD1000000);
const _kBgH2 = Color(0x40000000);
const _kBgH3 = Color(0x8C000000);
const _kBgV2 = Color(0x33000000);
const _kBgV3 = Color(0xD9000000);
const _kBgDialog = Color(0xF7000000);
const _kWhite06 = Color(0x0FFFFFFF);
const _kWhite08 = Color(0x14FFFFFF);
const _kWhite10 = Color(0x1AFFFFFF);
const _kWhite05 = Color(0x0DFFFFFF);
const _kPurple15 = Color(0x26E5E5E5);
const _kPurple20 = Color(0x33E5E5E5);
const _kPurple30 = Color(0x4DE5E5E5);
const _kPurple40 = Color(0x66E5E5E5);
const _kPurpleLight50 = Color(0x80FFFFFF);
const _kGreen = Color(0xFF22C55E);
const _kGreen15 = Color(0x2622C55E);
const _kGreen30 = Color(0x4D22C55E);
const _kBlue = Color(0xFF3B82F6);
const _kBlue15 = Color(0x263B82F6);
const _kBlue30 = Color(0x4D3B82F6);
const _kDim40 = Color(0x66505050);
const _kDim70 = Color(0xB3505050);

const _kHGradient = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [_kBgH1, _kBgH2, _kBgH3],
    stops: [0.0, 0.5, 1.0],
  ),
);
const _kVGradient = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Colors.transparent, _kBgV2, _kBgV3],
    stops: [0.0, 0.5, 1.0],
  ),
);

/// Handle a stremio:// deep link — navigate to detail, search, or discover.
/// Can be called from any widget state in this file.
void handleStremioDeepLink(BuildContext context, String deepLink) {
  final parsed = StremioAddonService.parseMetaLink(deepLink);
  if (parsed == null) return;

  switch (parsed['action']) {
    case 'detail':
      final type = parsed['type'] as String? ?? 'movie';
      final id = parsed['id'] as String? ?? '';
      final mediaType = type == 'series' ? 'tv' : type;
      if (id.startsWith('tt')) {
        TmdbService.findByImdbId(id).then((tmdbResult) {
          if (!context.mounted) return;
          if (tmdbResult != null) {
            Navigator.pushNamed(context, '/details', arguments: {
              'id': tmdbResult['id'] as int,
              'media_type': tmdbResult['media_type'] ?? mediaType,
            });
          } else {
            Navigator.pushNamed(context, '/details', arguments: {
              'id': id.hashCode,
              'media_type': mediaType,
              'stremio_item': {'id': id, 'type': type, 'name': id},
            });
          }
        });
      } else {
        Navigator.pushNamed(context, '/details', arguments: {
          'id': id.hashCode,
          'media_type': mediaType,
          'stremio_item': {'id': id, 'type': type, 'name': id},
        });
      }
      break;
    case 'search':
      final query = parsed['query'] as String? ?? '';
      if (query.isEmpty) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        MainShellState.instance?.switchToSearch(query);
      });
      break;
  }
}

StremioStream? _pickAutoStremioStream(Map<String, List<StremioStream>> addonStreams) {
  return StremioAddonService.firstStreamForAutoPick(
    addonStreams,
    preferredAddonName: SettingsService.instance.autoPlayStremioAddon,
  );
}

class DetailsScreen extends StatefulWidget {
  final int id;
  final String mediaType;
  /// Optional Stremio meta item for custom (non-IMDB) addon content.
  final Map<String, dynamic>? stremioItem;
  /// From native player "next episode" — auto-start this TMDB episode when loaded.
  final Map<String, dynamic>? autoPlayEpisode;

  const DetailsScreen({
    super.key,
    required this.id,
    required this.mediaType,
    this.stremioItem,
    this.autoPlayEpisode,
  });

  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  Map<String, dynamic>? _details;
  Map<String, dynamic>? _seasonData;
  bool _isLoading = true;
  int _selectedSeason = 1;
  List<TorrentSource> _sources = [];
  bool _isLoadingSources = false;
  Map<String, List<StremioStream>> _addonStreams = {};
  bool _isLoadingAddons = false;
  String _activeFilter = 'all'; // 'all', 'PlayTorrio', or addon name
  int _moviePanelTab = 0; // 0 = sources, 1 = recommendations
  final GlobalKey _firstRightItemKey = GlobalKey();


  // Custom Stremio ID support
  bool _isCustomStremioId = false;
  bool _isCollection = false;
  List<Map<String, dynamic>> _collectionItems = [];
  Map<String, dynamic>? _customSeasonData; // {seasons: [int], episodesBySeason: Map<int, List>}
  List<Map<String, dynamic>> _customStremioStreams = []; // raw stream maps from addon

  // Cached unified source list
  List<_UnifiedSource>? _cachedUnified;
  String? _cachedUnifiedFilter;
  int _cachedUnifiedHash = 0;

  bool _movieAutoPlayDone = false;
  bool _nativeNextEpisodeAutoPlayDone = false;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  /// After native player "next episode" — season already loaded in [_loadDetails].
  Future<void> _runNativeNextEpisodeAutoPlay(Map<String, dynamic> map) async {
    if (_nativeNextEpisodeAutoPlayDone || widget.mediaType != 'tv') {
      return;
    }
    _nativeNextEpisodeAutoPlayDone = true;
    final epNum = map['episode'] as int? ?? 1;
    Map<String, dynamic>? ep;
    for (final e in _episodes) {
      final m = e as Map<String, dynamic>;
      if ((m['episode_number'] as int?) == epNum) {
        ep = m;
        break;
      }
    }
    if (ep != null) {
      await _showEpisodeSources(ep);
    }
  }

  void _focusDownFromCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final currentFocus = FocusManager.instance.primaryFocus;
      if (currentFocus != null) {
        currentFocus.focusInDirection(TraversalDirection.down);
      }
    });
  }

  void _focusKey(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return;
    FocusNode? target;
    void visit(Element el) {
      if (target != null) return;
      if (el.widget is Focus) {
        final node = (el.widget as Focus).focusNode;
        if (node != null && node.canRequestFocus) {
          target = node;
          return;
        }
      }
      el.visitChildElements(visit);
    }
    (ctx as Element).visitChildElements(visit);
    target?.requestFocus();
  }

  Future<void> _loadDetails() async {
    setState(() => _isLoading = true);

    final stremioItem = widget.stremioItem;
    final bool isCustomId = stremioItem != null &&
        !(stremioItem['id']?.toString().startsWith('tt') ?? true);

    // Custom Stremio ID: skip TMDB fetch, use stremio meta directly
    if (isCustomId) {
      _isCustomStremioId = true;
      final customId = stremioItem['id']?.toString() ?? '';
      final type = stremioItem['type']?.toString() ?? (widget.mediaType == 'tv' ? 'series' : 'movie');
      final isCollectionItem = customId.startsWith('ctmdb.') || type == 'collections';

      // Build a synthetic _details map from the stremio item
      _details = {
        'title': stremioItem['name'] ?? 'Unknown',
        'name': stremioItem['name'] ?? 'Unknown',
        'overview': stremioItem['description'] ?? '',
        'poster_path': stremioItem['poster'] ?? '',
        'backdrop_path': stremioItem['background'] ?? stremioItem['poster'] ?? '',
        'vote_average': double.tryParse(stremioItem['imdbRating']?.toString() ?? '') ?? 0.0,
        'release_date': stremioItem['releaseInfo']?.toString() ?? '',
        'first_air_date': stremioItem['releaseInfo']?.toString() ?? '',
        'genres': (stremioItem['genres'] as List?)?.map((g) => {'name': g}).toList() ?? [],
        'id': widget.id,
        '_stremio_poster': stremioItem['poster'] ?? '',
        '_stremio_background': stremioItem['background'] ?? stremioItem['poster'] ?? '',
      };

      if (isCollectionItem) {
        _isCollection = true;
      }

      setState(() => _isLoading = false);
      _fetchStremioCustomIdContent(stremioItem);
      return;
    }

    try {
      final details = widget.mediaType == 'movie'
          ? await TmdbService.getMovieDetails(widget.id)
          : await TmdbService.getTvDetails(widget.id);

      if (mounted) {
        setState(() {
          _details = details;
          _isLoading = false;
        });

        if (widget.mediaType == 'movie') {
          if (!SettingsService.instance.streamingMode) {
            _loadSources();
            _loadAddonStreams();
          }
        }

        if (widget.mediaType == 'tv' && details['seasons'] != null) {
          final seasons = details['seasons'] as List;
          if (seasons.isNotEmpty) {
            final ap = widget.autoPlayEpisode;
            if (ap != null) {
              final s = ap['season'] as int? ?? 1;
              _selectedSeason = s;
              await _loadSeason(s);
              if (mounted) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    _runNativeNextEpisodeAutoPlay(Map<String, dynamic>.from(ap));
                  }
                });
              }
            } else {
              final firstReal = seasons.firstWhere(
                (s) => (s['season_number'] as int) > 0,
                orElse: () => seasons.first,
              );
              _selectedSeason = firstReal['season_number'] as int;
              _loadSeason(_selectedSeason);
            }
          }
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadSeason(int seasonNumber) async {
    try {
      final data = await TmdbService.getTvSeason(widget.id, seasonNumber);
      if (mounted) {
        setState(() => _seasonData = data);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusKey(_firstRightItemKey);
        });
      }
    } catch (_) {}
  }

  Future<void> _loadSources() async {
    if (widget.mediaType != 'movie' || _details == null) return;
    setState(() => _isLoadingSources = true);
    try {
      final sources = await SourceService.searchMovieSources(_title, _year);
      if (mounted) {
        setState(() {
          _sources = sources;
          _isLoadingSources = false;
        });
        _tryAutoPlayMovie();
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingSources = false);
    }
  }

  Future<void> _loadAddonStreams() async {
    final imdbId = _imdbId;
    if (imdbId == null || imdbId.isEmpty) return;
    if (SettingsService.instance.stremioAddons.isEmpty) {
      if (mounted && widget.mediaType == 'movie') {
        setState(() => _isLoadingAddons = false);
        _tryAutoPlayMovie();
      }
      return;
    }
    setState(() => _isLoadingAddons = true);
    try {
      final results = await StremioAddonService.fetchAllMovieStreams(imdbId);
      if (mounted) {
        setState(() {
          _addonStreams = results;
          _isLoadingAddons = false;
        });
        _tryAutoPlayMovie();
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingAddons = false);
    }
  }

  /// Auto-play when enabled: first PlayTorrio source, else first Stremio stream (addon order).
  bool get _autoPlaySourcesActive =>
      SettingsService.instance.stremioAutoPickStreams &&
      !SettingsService.instance.streamingMode;

  /// TMDB movie: order from Settings (PlayTorrio first vs Stremio first).
  void _tryAutoPlayMovie() {
    if (!_autoPlaySourcesActive || widget.mediaType != 'movie' || _isCustomStremioId) {
      return;
    }
    if (_movieAutoPlayDone) {
      return;
    }
    if (_isLoadingSources || _isLoadingAddons) {
      return;
    }
    final stremioFirst = SettingsService.instance.autoPlayStremioFirst;
    final pick = _pickAutoStremioStream(_addonStreams);
    final hasTorrents = _sources.isNotEmpty;

    if (stremioFirst) {
      if (pick != null) {
        _movieAutoPlayDone = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          _playStremioStream(pick);
        });
        return;
      }
      if (hasTorrents) {
        _movieAutoPlayDone = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          _playSource(_sources.first);
        });
      }
      return;
    }

    if (hasTorrents) {
      _movieAutoPlayDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _playSource(_sources.first);
      });
      return;
    }
    if (pick != null) {
      _movieAutoPlayDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _playStremioStream(pick);
      });
    }
  }

  /// Custom Stremio movie: first stream from addon JSON order.
  void _tryAutoPickCustomMovieStremio() {
    if (!_autoPlaySourcesActive || widget.mediaType != 'movie' || !_isCustomStremioId) {
      return;
    }
    if (_movieAutoPlayDone) {
      return;
    }
    if (_isLoadingAddons || _customStremioStreams.isEmpty) {
      return;
    }
    final pick = StremioAddonService.firstStreamFromRaw(_customStremioStreams);
    if (pick == null) {
      return;
    }
    _movieAutoPlayDone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _playStremioStream(pick);
    });
  }

  /// Fetches Stremio content for custom (non-IMDB) IDs.
  Future<void> _fetchStremioCustomIdContent(Map<String, dynamic> item) async {
    final customId = item['id']?.toString() ?? '';
    final addonBaseUrl = item['_addonBaseUrl']?.toString() ?? '';
    final type = item['type']?.toString() ?? (widget.mediaType == 'tv' ? 'series' : 'movie');

    if (customId.isEmpty || addonBaseUrl.isEmpty) return;

    setState(() => _isLoadingAddons = true);

    try {
      // For collections, fetch meta to get collection items
      if (_isCollection || type == 'collections') {
        final meta = await StremioAddonService.getMeta(
          baseUrl: addonBaseUrl, type: type, id: customId,
        );
        if (meta != null && meta['videos'] is List) {
          final videos = meta['videos'] as List;
          final items = <Map<String, dynamic>>[];
          for (final v in videos) {
            if (v is! Map) continue;
            items.add({
              'id': v['id'],
              'title': v['title'] ?? 'Unknown',
              'thumbnail': v['thumbnail'],
              'released': v['released'],
              'overview': v['overview'] ?? '',
            });
          }
          if (mounted) {
            setState(() {
              _collectionItems = items;
              _isCollection = true;
              _isLoadingAddons = false;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _focusKey(_firstRightItemKey);
            });
          }
          return;
        }
      }

      // For series, fetch meta to get season/episode structure
      if (type == 'series') {
        final meta = await StremioAddonService.getMeta(
          baseUrl: addonBaseUrl, type: type, id: customId,
        );
        if (meta != null && meta['videos'] is List) {
          final videos = meta['videos'] as List;
          final Map<int, List<Map<String, dynamic>>> seasonMap = {};
          for (final v in videos) {
            if (v is! Map) continue;
            final season = v['season'] as int? ?? 1;
            final episode = v['episode'] as int? ?? 1;
            seasonMap.putIfAbsent(season, () => []).add({
              'id': v['id'],
              'title': v['title'] ?? 'Episode $episode',
              'episode': episode,
              'season': season,
              'thumbnail': v['thumbnail'],
              'released': v['released'],
            });
          }
          for (final eps in seasonMap.values) {
            eps.sort((a, b) => (a['episode'] as int).compareTo(b['episode'] as int));
          }
          if (mounted) {
            final sortedSeasons = seasonMap.keys.toList()..sort();
            setState(() {
              _customSeasonData = {
                'seasons': sortedSeasons,
                'episodesBySeason': seasonMap,
              };
              if (!seasonMap.containsKey(_selectedSeason)) {
                _selectedSeason = sortedSeasons.first;
              }
              _isLoadingAddons = false;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _focusKey(_firstRightItemKey);
            });
          }
          return;
        }
      }

      // For movies or if meta fetch failed: fetch streams directly
      final streams = await StremioAddonService.getStreams(
        baseUrl: addonBaseUrl, type: type, id: customId,
      );
      if (mounted) {
        setState(() {
          _customStremioStreams = streams;
          _isLoadingAddons = false;
        });
        _tryAutoPickCustomMovieStremio();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusKey(_firstRightItemKey);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingAddons = false);
    }
  }

  /// Fetches streams for a custom Stremio ID episode.
  Future<void> _fetchCustomIdEpisodeStreams(String videoId) async {
    final item = widget.stremioItem;
    if (item == null) return;
    final addonBaseUrl = item['_addonBaseUrl']?.toString() ?? '';
    final type = item['type']?.toString() ?? 'series';

    if (addonBaseUrl.isEmpty) return;
    setState(() => _isLoadingAddons = true);

    try {
      final streams = await StremioAddonService.getStreams(
        baseUrl: addonBaseUrl, type: type, id: videoId,
      );
      if (mounted) {
        setState(() {
          _customStremioStreams = streams;
          _isLoadingAddons = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingAddons = false);
    }
  }

  // --- Data getters ---

  String get _title => (_details?['title'] ?? _details?['name'] ?? '') as String;
  String get _overview => (_details?['overview'] ?? '') as String;
  double get _rating => (_details?['vote_average'] as num?)?.toDouble() ?? 0;
  String get _backdropPath => (_details?['backdrop_path'] ?? '') as String;

  String? get _logoPath {
    final images = _details?['images'] as Map<String, dynamic>?;
    if (images == null) return null;
    final logos = images['logos'] as List?;
    if (logos == null || logos.isEmpty) return null;
    final enLogo = logos.firstWhere(
      (l) => l['iso_639_1'] == 'en',
      orElse: () => logos.first,
    );
    return enLogo['file_path'] as String?;
  }

  String get _year {
    final release = (_details?['release_date'] ?? '') as String;
    final firstAir = (_details?['first_air_date'] ?? '') as String;
    final lastAir = (_details?['last_air_date'] ?? '') as String;

    if (widget.mediaType == 'movie') {
      return release.length >= 4 ? release.substring(0, 4) : '';
    } else {
      final start = firstAir.length >= 4 ? firstAir.substring(0, 4) : '';
      final end = lastAir.length >= 4 ? lastAir.substring(0, 4) : '';
      if (start.isEmpty) return '';
      final status = (_details?['status'] ?? '') as String;
      if (status == 'Ended' || status == 'Canceled') {
        return end.isNotEmpty && end != start ? '$start\u2013$end' : start;
      }
      return '$start\u2013';
    }
  }

  String get _runtime {
    if (widget.mediaType == 'movie') {
      final mins = _details?['runtime'] as int?;
      if (mins != null && mins > 0) return '$mins min';
    } else {
      final epRuntime = _details?['episode_run_time'] as List?;
      if (epRuntime != null && epRuntime.isNotEmpty) return '${epRuntime[0]} min';
    }
    return '';
  }

  List<String> get _genreNames {
    final genres = _details?['genres'] as List?;
    if (genres == null) return [];
    return genres.map((g) => g['name'] as String).take(4).toList();
  }

  List<String> get _castNames {
    final credits = _details?['credits'] as Map<String, dynamic>?;
    if (credits == null) return [];
    final cast = credits['cast'] as List?;
    if (cast == null) return [];
    return cast.take(5).map((c) => c['name'] as String).toList();
  }

  List<String> get _directorNames {
    final credits = _details?['credits'] as Map<String, dynamic>?;
    if (credits == null) return [];
    final crew = credits['crew'] as List?;
    if (crew == null) return [];
    if (widget.mediaType == 'movie') {
      return crew
          .where((c) => c['job'] == 'Director')
          .take(3)
          .map((c) => c['name'] as String)
          .toList();
    } else {
      final creators = _details?['created_by'] as List?;
      if (creators != null && creators.isNotEmpty) {
        return creators.take(3).map((c) => c['name'] as String).toList();
      }
      return [];
    }
  }

  List<dynamic> get _recommendations {
    final recs = _details?['recommendations'] as Map<String, dynamic>?;
    if (recs == null) return [];
    return (recs['results'] as List?)?.take(20).toList() ?? [];
  }

  List<dynamic> get _similar {
    final sim = _details?['similar'] as Map<String, dynamic>?;
    if (sim == null) return [];
    return (sim['results'] as List?)?.take(20).toList() ?? [];
  }

  List<dynamic> get _seasons {
    if (_details == null || widget.mediaType != 'tv') return [];
    return (_details!['seasons'] as List?)?.where((s) => (s['season_number'] as int) > 0).toList() ?? [];
  }

  List<dynamic> get _episodes {
    if (_seasonData == null) return [];
    return (_seasonData!['episodes'] as List?) ?? [];
  }

  int get _totalSeasons => _seasons.length;

  int get _currentSeasonIndex =>
      _seasons.indexWhere((s) => (s['season_number'] as int) == _selectedSeason);

  void _prevSeason() {
    final idx = _currentSeasonIndex;
    if (idx > 0) {
      final sNum = _seasons[idx - 1]['season_number'] as int;
      setState(() => _selectedSeason = sNum);
      _loadSeason(sNum);
    }
  }

  void _nextSeason() {
    final idx = _currentSeasonIndex;
    if (idx < _totalSeasons - 1) {
      final sNum = _seasons[idx + 1]['season_number'] as int;
      setState(() => _selectedSeason = sNum);
      _loadSeason(sNum);
    }
  }

  Future<void> _showEpisodeSources(Map<String, dynamic> episode) async {
    final epNum = episode['episode_number'] as int;

    // In streaming mode, launch streaming directly
    if (SettingsService.instance.streamingMode) {
      _launchStreaming(season: _selectedSeason, episode: epNum);
      return;
    }

    final imdb = _imdbId ?? '';
    if (_autoPlaySourcesActive && imdb.isNotEmpty) {
      final stremioFirst = SettingsService.instance.autoPlayStremioFirst;
      final torrentsFuture =
          SourceService.searchTvSources(_title, _selectedSeason, epNum);
      final addonFuture =
          StremioAddonService.fetchAllEpisodeStreams(imdb, _selectedSeason, epNum);
      final torrents = await torrentsFuture;
      final addonMap = await addonFuture;
      if (!mounted) {
        return;
      }
      final pick = _pickAutoStremioStream(addonMap);
      final epTarget = EpisodeTarget(season: _selectedSeason, episode: epNum);
      if (stremioFirst) {
        if (pick != null) {
          _playStremioStream(pick, episode: epTarget);
          return;
        }
        if (torrents.isNotEmpty) {
          _playSource(torrents.first, episode: epTarget);
          return;
        }
      } else {
        if (torrents.isNotEmpty) {
          _playSource(torrents.first, episode: epTarget);
          return;
        }
        if (pick != null) {
          _playStremioStream(pick, episode: epTarget);
          return;
        }
      }
    }

    final epName = episode['name'] as String? ?? '';
    showDialog(
      context: context,
      builder: (_) => _EpisodeSourcesDialog(
        showName: _title,
        season: _selectedSeason,
        episode: epNum,
        episodeName: epName,
        tmdbId: widget.id,
        imdbId: _imdbId ?? '',
        backdropPath: _backdropPath,
        posterPath: (_details?['poster_path'] ?? '') as String,
      ),
    );
  }

  String? get _imdbId {
    if (_details == null) return null;
    // Movie: imdb_id at top level. TV: external_ids.imdb_id
    final direct = _details!['imdb_id'] as String?;
    if (direct != null && direct.isNotEmpty) return direct;
    final ext = _details!['external_ids'] as Map<String, dynamic>?;
    return ext?['imdb_id'] as String?;
  }

  String? get _logoUrl {
    final path = _logoPath;
    if (path == null) return null;
    return TmdbApi.logoUrl(path);
  }

  void _playSource(TorrentSource source, {EpisodeTarget? episode}) {
    final nextPayload = episode != null && widget.mediaType == 'tv'
        ? nextEpisodePayloadForPlayer(
            tmdbId: widget.id,
            mediaType: widget.mediaType,
            season: episode.season,
            episode: episode.episode,
            showTitle: _title,
            imdbId: _imdbId ?? '',
            backdropPath: _backdropPath,
            posterPath: (_details?['poster_path'] ?? '') as String,
            logoUrl: _logoUrl ?? '',
          )
        : null;
    Navigator.of(context).pushNamed('/player', arguments: {
      'magnet': source.magnet,
      'title': _title,
      'episode': episode,
      'tmdbId': widget.id,
      'imdbId': _imdbId ?? '',
      'backdropPath': _backdropPath,
      'posterPath': (_details?['poster_path'] ?? '') as String,
      'mediaType': widget.mediaType,
      'logoUrl': _logoUrl ?? '',
      'nextEpisodePayload': nextPayload,
    });
  }

  void _playStremioStream(StremioStream stream, {EpisodeTarget? episode}) {
    if (stream.isExternalLink) {
      handleStremioDeepLink(context, stream.externalUrl!);
      return;
    }
    if (stream.isTorrent) {
      // Build magnet and play via torrent engine / debrid
      final magnet = stream.buildMagnet(StremioAddonService.appTrackers);
      final nextPayload = episode != null && widget.mediaType == 'tv'
          ? nextEpisodePayloadForPlayer(
              tmdbId: widget.id,
              mediaType: widget.mediaType,
              season: episode.season,
              episode: episode.episode,
              showTitle: _title,
              imdbId: _imdbId ?? '',
              backdropPath: _backdropPath,
              posterPath: (_details?['poster_path'] ?? '') as String,
              logoUrl: _logoUrl ?? '',
            )
          : null;
      Navigator.of(context).pushNamed('/player', arguments: {
        'magnet': magnet,
        'title': _title,
        'episode': episode,
        'tmdbId': widget.id,
        'imdbId': _imdbId ?? '',
        'backdropPath': _backdropPath,
        'posterPath': (_details?['poster_path'] ?? '') as String,
        'mediaType': widget.mediaType,
        'fileIdx': stream.fileIdx,
        'logoUrl': _logoUrl ?? '',
        'nextEpisodePayload': nextPayload,
      });
    } else if (stream.url != null) {
      // Direct URL — launch player with URL
      final nextPayload = episode != null && widget.mediaType == 'tv'
          ? nextEpisodePayloadForPlayer(
              tmdbId: widget.id,
              mediaType: widget.mediaType,
              season: episode.season,
              episode: episode.episode,
              showTitle: _title,
              imdbId: _imdbId ?? '',
              backdropPath: _backdropPath,
              posterPath: (_details?['poster_path'] ?? '') as String,
              logoUrl: _logoUrl ?? '',
            )
          : null;
      PlayerLauncher.launch(
        stream.url!,
        title: _title,
        tmdbId: widget.id,
        imdbId: _imdbId ?? '',
        season: episode?.season,
        episode: episode?.episode,
        magnet: stream.url!, // save URL for continue watching
        backdropPath: _backdropPath,
        posterPath: (_details?['poster_path'] ?? '') as String,
        mediaType: widget.mediaType,
        logoUrl: _logoUrl ?? '',
        nextEpisodePayload: nextPayload,
      );
    }
  }

  void _launchStreaming({int season = -1, int episode = -1}) {
    final nextPayload = widget.mediaType == 'tv' && season > 0 && episode > 0
        ? nextEpisodePayloadForPlayer(
            tmdbId: widget.id,
            mediaType: widget.mediaType,
            season: season,
            episode: episode,
            showTitle: _title,
            imdbId: _imdbId ?? '',
            backdropPath: _backdropPath,
            posterPath: (_details?['poster_path'] ?? '') as String,
            logoUrl: _logoUrl ?? '',
          )
        : null;
    PlayerLauncher.launchStreaming(
      tmdbId: widget.id,
      imdbId: _imdbId ?? '',
      title: _title,
      mediaType: widget.mediaType,
      backdropPath: _backdropPath,
      posterPath: (_details?['poster_path'] ?? '') as String,
      season: season,
      episode: episode,
      logoUrl: _logoUrl ?? '',
      nextEpisodePayload: nextPayload,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: KeyboardListener(
        focusNode: FocusNode(),
        onKeyEvent: (event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.of(context).pop();
          }
        },
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: _isLoading
              ? const Center(child: CircularProgressIndicator(color: AppColors.purpleLight))
              : _details == null
                  ? const Center(child: Text('Failed to load', style: TextStyle(color: AppColors.textSecondary)))
                  : _buildContent(context),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    return Stack(
      children: [
        // Backdrop + gradients in RepaintBoundary (static after load)
        RepaintBoundary(
          child: Stack(
            children: [
              if (_backdropPath.isNotEmpty)
                Positioned.fill(
                  child: CachedNetworkImage(
                    imageUrl: _isCustomStremioId
                        ? _backdropPath
                        : TmdbApi.backdropUrl(_backdropPath),
                    fit: BoxFit.cover,
                    color: _kBlackOverlay,
                    colorBlendMode: BlendMode.darken,
                    memCacheWidth: 1280,
                  ),
                ),
              const Positioned.fill(child: DecoratedBox(decoration: _kHGradient)),
              const Positioned.fill(child: DecoratedBox(decoration: _kVGradient)),
            ],
          ),
        ),

        // Two-column layout
        Padding(
          padding: const EdgeInsets.fromLTRB(48, 32, 40, 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // LEFT PANEL — mostly static text, buttons at bottom
              Expanded(
                flex: 5,
                child: _buildLeftPanel(),
              ),
              const SizedBox(width: 32),
              // RIGHT PANEL — focusable list
              Expanded(
                flex: 5,
                child: _buildRightPanel(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLeftPanel() {
    final logo = _logoPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),

                // Logo or Title — NOT focusable
                if (logo != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 90, maxWidth: 340),
                    child: CachedNetworkImage(
                      imageUrl: TmdbApi.logoUrl(logo),
                      fit: BoxFit.contain,
                      alignment: Alignment.centerLeft,
                      memCacheWidth: 500,
                      placeholder: (_, _) => Text(
                        _title,
                        style: const TextStyle(color: AppColors.textPrimary, fontSize: 44, fontWeight: FontWeight.w800, height: 1.1),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      errorWidget: (_, _, _) => Text(
                        _title,
                        style: const TextStyle(color: AppColors.textPrimary, fontSize: 44, fontWeight: FontWeight.w800, height: 1.1),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                else
                  Text(
                    _title,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 44,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      height: 1.1,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 14),

                // Metadata — NOT focusable
                Row(
                  children: [
                    if (_runtime.isNotEmpty) ...[
                      Text(_runtime, style: const TextStyle(color: AppColors.textSecondary, fontSize: 16, fontWeight: FontWeight.w500)),
                      const SizedBox(width: 10),
                      const Text('\u2022', style: TextStyle(color: AppColors.textDim, fontSize: 16)),
                      const SizedBox(width: 10),
                    ],
                    if (_year.isNotEmpty) ...[
                      Text(_year, style: const TextStyle(color: AppColors.textSecondary, fontSize: 16, fontWeight: FontWeight.w500)),
                      const SizedBox(width: 10),
                    ],
                    if (_rating > 0) ...[
                      const Text('\u2022', style: TextStyle(color: AppColors.textDim, fontSize: 16)),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE6B91E),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star_rounded, color: Colors.black87, size: 14),
                            const SizedBox(width: 3),
                            Text(
                              _rating.toStringAsFixed(1),
                              style: const TextStyle(color: Colors.black87, fontSize: 14, fontWeight: FontWeight.w800),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 18),

        // Genres — NOT focusable, glassy pills
                if (_genreNames.isNotEmpty) ...[  
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: _genreNames.map((g) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: _kWhite06,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: _kWhite10, width: 1),
                          ),
                          child: Text(g, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w500)),
                        ),
                    ).toList(),
                  ),
                  const SizedBox(height: 16),
                ],

                // Overview — NOT focusable
                if (_overview.isNotEmpty) ...[
                  Text(
                    _overview,
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 15, height: 1.5),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 16),
                ],

                // Cast — NOT focusable
                if (_castNames.isNotEmpty) ...[
                  Text(
                    'Cast: ${_castNames.join(', ')}',
                    style: const TextStyle(color: AppColors.textDim, fontSize: 14),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                ],

                // Directors — NOT focusable
                if (_directorNames.isNotEmpty) ...[
                  Text(
                    '${widget.mediaType == 'tv' ? 'Created' : 'Directed'} by ${_directorNames.join(', ')}',
                    style: const TextStyle(color: AppColors.textDim, fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                ],
              ],
            ),
          ),
        ),


      ],
    );
  }

  Widget _buildRightPanel(BuildContext context) {
    // Custom Stremio ID content
    if (_isCustomStremioId) {
      if (_isCollection) return _buildCollectionPanel();
      if (_customSeasonData != null) return _buildCustomSeriesPanel();
      return _buildCustomMoviePanel();
    }
    if (widget.mediaType == 'tv') {
      return _buildEpisodeBrowser();
    } else {
      return _buildMovieRightPanel(context);
    }
  }

  /// Panel for Stremio collections — list of collection items.
  Widget _buildCollectionPanel() {
    if (_isLoadingAddons && _collectionItems.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: AppColors.purpleLight));
    }
    if (_collectionItems.isEmpty) {
      return const Center(child: Text('Empty collection', style: TextStyle(color: AppColors.textDim)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text('${_collectionItems.length} Items', style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.builder(
            cacheExtent: 2000,
            itemCount: _collectionItems.length,
            itemBuilder: (context, index) {
              final item = _collectionItems[index];
              final title = item['title'] ?? 'Unknown';
              final thumb = item['thumbnail'] as String?;
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: _CollectionItemRow(
                  title: title,
                  thumbnail: thumb,
                  key: index == 0 ? _firstRightItemKey : null,
                  onSelected: () => _openCollectionItem(item),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Navigate to a collection item (resolve its ID).
  Future<void> _openCollectionItem(Map<String, dynamic> item) async {
    final id = item['id']?.toString() ?? '';
    if (id.isEmpty) return;

    // IMDB IDs → resolve via TMDB
    if (id.startsWith('tt')) {
      final tmdb = await TmdbService.findByImdbId(id);
      if (tmdb != null && mounted) {
        Navigator.pushNamed(context, '/details', arguments: {
          'id': tmdb['id'] as int,
          'media_type': (tmdb['media_type'] ?? 'movie') as String,
        });
        return;
      }
    }

    // Non-IMDB: search by title
    final title = item['title']?.toString() ?? '';
    if (title.isNotEmpty) {
      try {
        final results = await TmdbService.searchMulti(title);
        if (results.isNotEmpty && mounted) {
          final match = results.first as Map<String, dynamic>;
          Navigator.pushNamed(context, '/details', arguments: {
            'id': match['id'] as int,
            'media_type': (match['media_type'] ?? 'movie') as String,
          });
          return;
        }
      } catch (_) {}
    }
  }

  /// Panel for custom Stremio series — season/episode structure from stremio meta.
  Widget _buildCustomSeriesPanel() {
    final seasons = (_customSeasonData!['seasons'] as List).cast<int>();
    final episodesBySeason = _customSeasonData!['episodesBySeason'] as Map<int, List<Map<String, dynamic>>>;
    final episodes = episodesBySeason[_selectedSeason] ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Row(
          children: [
            _FocusableIconButton(
              icon: Icons.chevron_left_rounded,
              enabled: seasons.indexOf(_selectedSeason) > 0,
              onSelect: () {
                final idx = seasons.indexOf(_selectedSeason);
                if (idx > 0) setState(() => _selectedSeason = seasons[idx - 1]);
              },
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: _kWhite06,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _kWhite10, width: 1),
              ),
              child: Text(
                'Season $_selectedSeason',
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            _FocusableIconButton(
              icon: Icons.chevron_right_rounded,
              enabled: seasons.indexOf(_selectedSeason) < seasons.length - 1,
              onSelect: () {
                final idx = seasons.indexOf(_selectedSeason);
                if (idx < seasons.length - 1) setState(() => _selectedSeason = seasons[idx + 1]);
              },
            ),
            const SizedBox(width: 16),
            Text('${episodes.length} Episodes', style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: episodes.isEmpty
              ? const Center(child: CircularProgressIndicator(color: AppColors.purpleLight))
              : ListView.builder(
                  cacheExtent: 2000,
                  itemCount: episodes.length,
                  itemBuilder: (context, index) {
                    final ep = episodes[index];
                    return _CustomEpisodeRow(
                      episode: ep,
                      key: index == 0 ? _firstRightItemKey : null,
                      onSelected: () => _showCustomEpisodeSources(ep),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Shows sources for a custom Stremio episode.
  Future<void> _showCustomEpisodeSources(Map<String, dynamic> ep) async {
    final videoId = ep['id']?.toString() ?? '';
    if (videoId.isEmpty) {
      return;
    }
    final item = widget.stremioItem;
    final addonBaseUrl = item?['_addonBaseUrl']?.toString() ?? '';
    final type = item?['type']?.toString() ?? 'series';

    if (_autoPlaySourcesActive && addonBaseUrl.isNotEmpty) {
      final season = ep['season'] as int? ?? 1;
      final epNum = ep['episode'] as int? ?? 1;
      final stremioFirst = SettingsService.instance.autoPlayStremioFirst;
      final torrentsFuture = SourceService.searchTvSources(_title, season, epNum);
      final streamsFuture = StremioAddonService.getStreams(
        baseUrl: addonBaseUrl,
        type: type,
        id: videoId,
      );
      final torrents = await torrentsFuture;
      final streams = await streamsFuture;
      if (!mounted) {
        return;
      }
      final best = StremioAddonService.firstRawStreamMap(streams);
      final epTarget = EpisodeTarget(season: season, episode: epNum);
      if (stremioFirst) {
        if (best != null) {
          _playCustomStream(best, episode: epTarget);
          return;
        }
        if (torrents.isNotEmpty) {
          _playSource(torrents.first, episode: epTarget);
          return;
        }
      } else {
        if (torrents.isNotEmpty) {
          _playSource(torrents.first, episode: epTarget);
          return;
        }
        if (best != null) {
          _playCustomStream(best, episode: epTarget);
          return;
        }
      }
    }

    _fetchCustomIdEpisodeStreams(videoId);
    final epTitle = ep['title'] ?? 'Episode ${ep['episode']}';
    showDialog(
      context: context,
      builder: (_) => _CustomStreamDialog(
        title: '$_title — $epTitle',
        videoId: videoId,
        stremioItem: widget.stremioItem!,
      ),
    );
  }

  /// Panel for custom Stremio movies — shows custom streams.
  Widget _buildCustomMoviePanel() {
    if (_isLoadingAddons && _customStremioStreams.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: AppColors.purpleLight));
    }
    if (_customStremioStreams.isEmpty) {
      return const Center(child: Text('No streams found', style: TextStyle(color: AppColors.textDim, fontSize: 16)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text('${_customStremioStreams.length} Streams', style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.builder(
            cacheExtent: 2000,
            itemCount: _customStremioStreams.length,
            itemBuilder: (context, index) {
              final s = _customStremioStreams[index];
              return _CustomStreamRow(
                stream: s,
                key: index == 0 ? _firstRightItemKey : null,
                onSelect: () => _playCustomStream(s),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Play a raw Stremio stream map.
  void _playCustomStream(Map<String, dynamic> s, {EpisodeTarget? episode}) {
    final extUrl = s['externalUrl'] as String?;
    if (extUrl != null && extUrl.isNotEmpty) {
      handleStremioDeepLink(context, extUrl);
      return;
    }
    final infoHash = s['infoHash'] as String?;
    final url = s['url'] as String?;
    final title = _title;
    final epTitle = episode != null
        ? '$title S${episode.season.toString().padLeft(2, '0')}E${episode.episode.toString().padLeft(2, '0')}'
        : title;

    if (infoHash != null && infoHash.isNotEmpty) {
      final buf = StringBuffer('magnet:?xt=urn:btih:$infoHash');
      final hints = s['behaviorHints'] as Map<String, dynamic>? ?? {};
      final fn = hints['filename'] as String?;
      if (fn != null && fn.isNotEmpty) buf.write('&dn=${Uri.encodeComponent(fn)}');
      final srcs = s['sources'] as List? ?? [];
      for (final src in srcs) {
        if (src is String && src.startsWith('tracker:')) {
          buf.write('&tr=${Uri.encodeComponent(src.substring('tracker:'.length))}');
        }
      }
      for (final t in StreamService.trackers) {
        buf.write('&tr=${Uri.encodeComponent(t)}');
      }
      Navigator.of(context).pushNamed('/player', arguments: {
        'magnet': buf.toString(),
        'title': epTitle,
        'episode': episode,
        'tmdbId': null,
        'imdbId': null,
        'backdropPath': _backdropPath,
        'posterPath': _details?['poster_path'] ?? '',
        'mediaType': widget.mediaType,
        'fileIdx': s['fileIdx'] as int?,
      });
    } else if (url != null && url.isNotEmpty) {
      PlayerLauncher.launch(
        url,
        title: epTitle,
        magnet: url,
        season: episode?.season,
        episode: episode?.episode,
        backdropPath: _backdropPath,
        posterPath: _details?['poster_path'] ?? '',
        mediaType: widget.mediaType,
      );
    }
  }

  Widget _buildEpisodeBrowser() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        // Season navigator — focusable buttons
        Row(
          children: [
            _FocusableIconButton(
              icon: Icons.chevron_left_rounded,
              enabled: _currentSeasonIndex > 0,
              onSelect: _prevSeason,
            ),
            const SizedBox(width: 12),
            Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  decoration: BoxDecoration(
                    color: _kWhite06,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _kWhite10, width: 1),
                  ),
                  child: Text(
                    'Season $_selectedSeason',
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
            const SizedBox(width: 12),
            _FocusableIconButton(
              icon: Icons.chevron_right_rounded,
              enabled: _currentSeasonIndex < _totalSeasons - 1,
              onSelect: _nextSeason,
            ),
            const SizedBox(width: 16),
            Text(
              '${_episodes.length} Episodes',
              style: const TextStyle(color: AppColors.textDim, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Episode list — focusable rows
        Expanded(
          child: _episodes.isEmpty
              ? const Center(child: CircularProgressIndicator(color: AppColors.purpleLight))
              : ListView.builder(
                  cacheExtent: 2000,
                  itemCount: _episodes.length,
                  itemBuilder: (context, index) {
                    final ep = _episodes[index] as Map<String, dynamic>;
                    return _EpisodeRow(
                      episode: ep,
                      key: index == 0 ? _firstRightItemKey : null,
                      onSelected: () => _showEpisodeSources(ep),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildMovieRightPanel(BuildContext context) {
    final items = _recommendations.isNotEmpty ? _recommendations : _similar;
    final isStreamingMode = SettingsService.instance.streamingMode;

    if (isStreamingMode) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          _FocusableButton(
            key: _firstRightItemKey,
            icon: Icons.play_arrow_rounded,
            label: 'Watch Now',
            autofocus: true,
            onSelect: () => _launchStreaming(),
          ),
          const SizedBox(height: 16),
          if (items.isNotEmpty) ...[
            const Text(
              'Recommendations',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Expanded(child: _buildRecommendationsList(context, items)),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Row(
          children: [
            _TabButton(
              key: _firstRightItemKey,
              label: 'Sources',
              active: _moviePanelTab == 0,
              autofocus: true,
              onSelect: () => setState(() => _moviePanelTab = 0),
            ),
            const SizedBox(width: 12),
            _TabButton(
              label: 'Recommendations',
              active: _moviePanelTab == 1,
              onSelect: () => setState(() => _moviePanelTab = 1),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _moviePanelTab == 0
              ? _buildSourcesList()
              : _buildRecommendationsList(context, items),
        ),
      ],
    );
  }

  /// Build available filter names (only sources that actually returned results).
  List<String> get _availableFilters {
    final filters = <String>['all'];
    if (_sources.isNotEmpty) filters.add('PlayTorrio');
    for (final name in _addonStreams.keys) {
      filters.add(name);
    }
    return filters;
  }

  Widget _buildSourcesList() {
    final isLoading = _isLoadingSources || _isLoadingAddons;
    final hasBuiltIn = _sources.isNotEmpty;
    final hasAddon = _addonStreams.isNotEmpty;

    if (isLoading && !hasBuiltIn && !hasAddon) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.purpleLight),
      );
    }

    // Cached unified source items — only rebuild when data or filter changes.
    final hash = Object.hash(_sources.length, _addonStreams.length, _addonStreams.keys.join(','));
    if (_cachedUnified == null || _cachedUnifiedFilter != _activeFilter || _cachedUnifiedHash != hash) {
      final items = <_UnifiedSource>[];
      if (_activeFilter == 'all' || _activeFilter == 'PlayTorrio') {
        for (final s in _sources) {
          items.add(_UnifiedSource.torrent(s));
        }
      }
      if (_activeFilter == 'all') {
        for (final entry in _addonStreams.entries) {
          for (final s in entry.value) {
            items.add(_UnifiedSource.addon(s));
          }
        }
      } else if (_activeFilter != 'PlayTorrio') {
        final addonList = _addonStreams[_activeFilter];
        if (addonList != null) {
          for (final s in addonList) {
            items.add(_UnifiedSource.addon(s));
          }
        }
      }
      _cachedUnified = items;
      _cachedUnifiedFilter = _activeFilter;
      _cachedUnifiedHash = hash;
    }
    final items = _cachedUnified!;

    if (items.isEmpty && !isLoading) {
      return const Center(
        child: Text(
          'No sources found',
          style: TextStyle(color: AppColors.textDim, fontSize: 16),
        ),
      );
    }

    final filters = _availableFilters;
    final showFilters = filters.length > 2; // more than just 'all' + one source

    return Column(
      children: [
        // Filter buttons row
        if (showFilters) ...[
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: filters.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, index) {
                final filter = filters[index];
                return _FilterChip(
                  label: filter == 'all' ? 'All' : filter,
                  active: _activeFilter == filter,
                  onSelect: () {
                    setState(() => _activeFilter = filter);
                    _focusDownFromCurrent();
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 10),
        ],
        // Source list
        Expanded(
          child: ListView.builder(
            key: ValueKey('sources_$_activeFilter'),
            cacheExtent: 2000,
            itemCount: items.length + (isLoading ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == items.length) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator(color: AppColors.purpleLight)),
                );
              }
              final item = items[index];
              if (item.torrentSource != null) {
                return _SourceRow(
                  source: item.torrentSource!,
                  onSelect: () => _playSource(item.torrentSource!),
                );
              } else {
                return _StremioStreamRow(
                  stream: item.stremioStream!,
                  onSelect: () => _playStremioStream(item.stremioStream!),
                );
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRecommendationsList(BuildContext context, List<dynamic> items) {
    if (items.isEmpty) {
      return const Center(
        child: Text(
          'No recommendations',
          style: TextStyle(color: AppColors.textDim, fontSize: 16),
        ),
      );
    }
    return ListView.builder(
      cacheExtent: 2000,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index] as Map<String, dynamic>;
        return _RecommendationRow(
          item: item,
          onSelected: () {
            final type = item['media_type'] ?? widget.mediaType;
            Navigator.pushReplacementNamed(context, '/details', arguments: {
              'id': item['id'] as int,
              'media_type': type as String,
            });
          },
        );
      },
    );
  }
}

// ─── Focusable Button ───

class _FocusableButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onSelect;
  final bool autofocus;

  const _FocusableButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onSelect,
    this.autofocus = false,
  });

  @override
  State<_FocusableButton> createState() => _FocusableButtonState();
}

class _FocusableButtonState extends State<_FocusableButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onSelect,
      child: DpadFocusable(
        region: 'actions',
        autofocus: widget.autofocus,
        onFocus: () => setState(() => _focused = true),
        onBlur: () => setState(() => _focused = false),
        onSelect: widget.onSelect,
        builder: (context, isFocused, child) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: _focused
                  ? _kPurple30
                  : _kWhite08,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _focused ? AppColors.purpleLight : _kWhite10,
                width: 1.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, color: _focused ? AppColors.textPrimary : AppColors.textSecondary, size: 20),
                const SizedBox(width: 8),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                    fontSize: 15,
                    fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          );
        },
        child: const SizedBox.shrink(),
      ),
    );
  }
}

// ─── Focusable Icon Button ───

class _FocusableIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onSelect;
  final bool enabled;

  const _FocusableIconButton({
    required this.icon,
    required this.onSelect,
    this.enabled = true,
  });

  @override
  State<_FocusableIconButton> createState() => _FocusableIconButtonState();
}

class _FocusableIconButtonState extends State<_FocusableIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.enabled ? widget.onSelect : null,
      child: DpadFocusable(
      region: 'controls',
      onFocus: () => setState(() => _focused = true),
      onBlur: () => setState(() => _focused = false),
      onSelect: widget.enabled ? widget.onSelect : () {},
      builder: (context, isFocused, child) {
        return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _focused && widget.enabled
                    ? _kPurple30
                    : _kWhite06,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _focused && widget.enabled
                      ? AppColors.purpleLight
                      : _kWhite08,
                  width: 1.5,
                ),
              ),
              child: Icon(
                widget.icon,
                color: widget.enabled
                    ? (_focused ? AppColors.textPrimary : AppColors.textSecondary)
                    : _kDim40,
                size: 20,
              ),
            );
      },
      child: const SizedBox.shrink(),
    ),
    );
  }
}

// ─── Episode Row ───

class _EpisodeRow extends StatefulWidget {
  final Map<String, dynamic> episode;
  final VoidCallback? onSelected;

  const _EpisodeRow({super.key, required this.episode, this.onSelected});

  @override
  State<_EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<_EpisodeRow> with AutomaticKeepAliveClientMixin {
  bool _focused = false;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final epNum = widget.episode['episode_number'] as int?;
    final name = widget.episode['name'] as String? ?? '';
    final stillPath = widget.episode['still_path'] as String?;
    final airDate = widget.episode['air_date'] as String? ?? '';

    String formattedDate = '';
    if (airDate.length >= 10) {
      final dt = DateTime.tryParse(airDate);
      if (dt != null) {
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        formattedDate = '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: GestureDetector(
          onTap: widget.onSelected ?? () {},
          child: DpadFocusable(
        region: 'episodes',
        onFocus: () => setState(() => _focused = true),
        onBlur: () => setState(() => _focused = false),
        onSelect: widget.onSelected ?? () {},
        builder: (context, isFocused, child) {
          return Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _focused
                      ? _kPurple15
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _focused ? _kPurpleLight50 : Colors.transparent,
                    width: 1,
                  ),
                ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 175,
                    height: 98,
                    child: stillPath != null && stillPath.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: TmdbApi.backdropUrl(stillPath, size: 'w300'),
                            fit: BoxFit.cover,
                            memCacheWidth: 300,
                            placeholder: (_, _) => const ColoredBox(color: AppColors.surfaceLight),
                          )
                        : const _StillPlaceholder(),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '$epNum. $name',
                        style: TextStyle(
                          color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                          fontSize: 14,
                          fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (formattedDate.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(formattedDate, style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
              );
        },
        child: const SizedBox.shrink(),
      ),
      ),
    );
  }
}

// ─── Recommendation Row ───

class _RecommendationRow extends StatefulWidget {
  final Map<String, dynamic> item;
  final VoidCallback onSelected;

  const _RecommendationRow({required this.item, required this.onSelected});

  @override
  State<_RecommendationRow> createState() => _RecommendationRowState();
}

class _RecommendationRowState extends State<_RecommendationRow> with AutomaticKeepAliveClientMixin {
  bool _focused = false;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final title = (widget.item['title'] ?? widget.item['name'] ?? '') as String;
    final posterPath = widget.item['poster_path'] as String?;
    final rating = (widget.item['vote_average'] as num?)?.toDouble() ?? 0;
    final releaseDate = (widget.item['release_date'] ?? widget.item['first_air_date'] ?? '') as String;
    final year = releaseDate.length >= 4 ? releaseDate.substring(0, 4) : '';
    final overview = (widget.item['overview'] ?? '') as String;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
          onTap: widget.onSelected,
          child: DpadFocusable(
        region: 'recommendations',
        onFocus: () => setState(() => _focused = true),
        onBlur: () => setState(() => _focused = false),
        onSelect: widget.onSelected,
        builder: (context, isFocused, child) {
          return Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _focused
                      ? _kPurple15
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _focused ? _kPurpleLight50 : Colors.transparent,
                    width: 1,
                  ),
                ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 85,
                    height: 125,
                    child: posterPath != null && posterPath.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: TmdbApi.posterUrl(posterPath, size: 'w185'),
                            fit: BoxFit.cover,
                            memCacheWidth: 185,
                            placeholder: (_, _) => const ColoredBox(color: AppColors.surfaceLight),
                          )
                        : const _PosterPlaceholder(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                          fontSize: 14,
                          fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (year.isNotEmpty) ...[
                            Text(year, style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                            const SizedBox(width: 8),
                          ],
                          if (rating > 0) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE6B91E),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                rating.toStringAsFixed(1),
                                style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (overview.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          overview,
                          style: const TextStyle(color: AppColors.textDim, fontSize: 12, height: 1.3),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
              );
        },
        child: const SizedBox.shrink(),
      ),
      ),
    );
  }
}

// ─── Tab Button ───

class _TabButton extends StatefulWidget {
  final String label;
  final bool active;
  final VoidCallback onSelect;
  final bool autofocus;

  const _TabButton({super.key, required this.label, required this.active, required this.onSelect, this.autofocus = false});

  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onSelect,
      child: DpadFocusable(
      region: 'tabs',
      autofocus: widget.autofocus,
      onFocus: () => setState(() => _focused = true),
      onBlur: () => setState(() => _focused = false),
      onSelect: widget.onSelect,
      builder: (context, isFocused, child) {
        return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: widget.active
                    ? _kPurple30
                    : _kWhite06,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _focused
                      ? AppColors.purpleLight
                      : widget.active
                          ? _kPurple40
                          : _kWhite08,
                  width: 1.5,
                ),
              ),
              child: Text(
                widget.label,
                style: TextStyle(
                  color: widget.active || _focused ? AppColors.textPrimary : AppColors.textSecondary,
                  fontSize: 14,
                  fontWeight: widget.active ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            );
      },
      child: const SizedBox.shrink(),
    ),
    );
  }
}

// ─── Source Row ───

class _SourceRow extends StatefulWidget {
  final TorrentSource source;
  final VoidCallback? onSelect;
  final bool autofocus;

  const _SourceRow({required this.source, this.onSelect, this.autofocus = false});

  @override
  State<_SourceRow> createState() => _SourceRowState();
}

class _SourceRowState extends State<_SourceRow> with AutomaticKeepAliveClientMixin {
  bool _focused = false;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: widget.onSelect ?? () {},
        child: DpadFocusable(
        region: 'sources',
        autofocus: widget.autofocus,
        onFocus: () => setState(() => _focused = true),
        onBlur: () => setState(() => _focused = false),
        onSelect: widget.onSelect ?? () {},
        builder: (context, isFocused, child) {
          return Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: _focused
                      ? _kPurple15
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _focused ? _kPurpleLight50 : Colors.transparent,
                    width: 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.source.name,
                      style: TextStyle(
                        color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        // Size
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: _kWhite08,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: _kWhite10),
                          ),
                          child: Text(
                            widget.source.size,
                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w500),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Seeders
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: _kGreen15,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: _kGreen30),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.arrow_upward_rounded, color: _kGreen, size: 12),
                              const SizedBox(width: 3),
                              Text(
                                '${widget.source.seeders}',
                                style: const TextStyle(color: _kGreen, fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        // Provider
                        Text(
                          widget.source.provider,
                          style: const TextStyle(
                            color: _kDim70,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
        },
        child: const SizedBox.shrink(),
      ),
      ),
    );
  }
}

// ─── Episode Sources Dialog ───

class _EpisodeSourcesDialog extends StatefulWidget {
  final String showName;
  final int season;
  final int episode;
  final String episodeName;
  final int tmdbId;
  final String imdbId;
  final String backdropPath;
  final String posterPath;

  const _EpisodeSourcesDialog({
    required this.showName,
    required this.season,
    required this.episode,
    required this.episodeName,
    required this.tmdbId,
    required this.imdbId,
    required this.backdropPath,
    required this.posterPath,
  });

  @override
  State<_EpisodeSourcesDialog> createState() => _EpisodeSourcesDialogState();
}

class _EpisodeSourcesDialogState extends State<_EpisodeSourcesDialog> {
  List<TorrentSource> _sources = [];
  Map<String, List<StremioStream>> _addonStreams = {};
  bool _isLoading = true;
  bool _isLoadingAddons = true;
  String _activeFilter = 'all';
  bool _episodeDialogAutoPickDone = false;

  @override
  void initState() {
    super.initState();
    _loadSources();
    _loadAddonStreams();
  }

  Future<void> _loadSources() async {
    try {
      final sources = await SourceService.searchTvSources(
        widget.showName,
        widget.season,
        widget.episode,
      );
      if (mounted) {
        setState(() {
          _sources = sources;
          _isLoading = false;
        });
        _tryAutoPickEpisodeDialog();
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadAddonStreams() async {
    if (widget.imdbId.isEmpty || SettingsService.instance.stremioAddons.isEmpty) {
      if (mounted) setState(() => _isLoadingAddons = false);
      return;
    }
    try {
      final results = await StremioAddonService.fetchAllEpisodeStreams(
        widget.imdbId,
        widget.season,
        widget.episode,
      );
      if (mounted) {
        setState(() {
          _addonStreams = results;
          _isLoadingAddons = false;
        });
        _tryAutoPickEpisodeDialog();
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingAddons = false);
    }
  }

  void _tryAutoPickEpisodeDialog() {
    if (!SettingsService.instance.stremioAutoPickStreams ||
        SettingsService.instance.streamingMode) {
      return;
    }
    if (_episodeDialogAutoPickDone) {
      return;
    }
    if (_isLoading || _isLoadingAddons) {
      return;
    }
    final stremioFirst = SettingsService.instance.autoPlayStremioFirst;
    final pick = _pickAutoStremioStream(_addonStreams);
    if (stremioFirst) {
      if (pick != null) {
        _episodeDialogAutoPickDone = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          _playAddonStream(pick);
        });
        return;
      }
      if (_sources.isNotEmpty) {
        _episodeDialogAutoPickDone = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          _playTorrentSource(_sources.first);
        });
      }
      return;
    }
    if (_sources.isNotEmpty) {
      _episodeDialogAutoPickDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _playTorrentSource(_sources.first);
      });
      return;
    }
    if (pick == null) {
      return;
    }
    _episodeDialogAutoPickDone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _playAddonStream(pick);
    });
  }

  List<String> get _filters {
    final f = <String>['all'];
    if (_sources.isNotEmpty) f.add('PlayTorrio');
    for (final name in _addonStreams.keys) {
      f.add(name);
    }
    return f;
  }

  void _playTorrentSource(TorrentSource source) {
    Navigator.of(context).pop();
    Navigator.of(context).pushNamed('/player', arguments: {
      'magnet': source.magnet,
      'title': '${widget.showName} S${widget.season.toString().padLeft(2, '0')}E${widget.episode.toString().padLeft(2, '0')}',
      'episode': EpisodeTarget(season: widget.season, episode: widget.episode),
      'tmdbId': widget.tmdbId,
      'imdbId': widget.imdbId,
      'backdropPath': widget.backdropPath,
      'posterPath': widget.posterPath,
      'mediaType': 'tv',
    });
  }

  void _playAddonStream(StremioStream stream) {
    if (stream.isExternalLink) {
      Navigator.of(context).pop();
      handleStremioDeepLink(context, stream.externalUrl!);
      return;
    }
    Navigator.of(context).pop();
    final epTarget = EpisodeTarget(season: widget.season, episode: widget.episode);
    if (stream.isTorrent) {
      final magnet = stream.buildMagnet(StremioAddonService.appTrackers);
      final nextPayload = nextEpisodePayloadForPlayer(
        tmdbId: widget.tmdbId,
        mediaType: 'tv',
        season: widget.season,
        episode: widget.episode,
        showTitle: widget.showName,
        imdbId: widget.imdbId,
        backdropPath: widget.backdropPath,
        posterPath: widget.posterPath,
        logoUrl: '',
      );
      Navigator.of(context).pushNamed('/player', arguments: {
        'magnet': magnet,
        'title': '${widget.showName} S${widget.season.toString().padLeft(2, '0')}E${widget.episode.toString().padLeft(2, '0')}',
        'episode': epTarget,
        'tmdbId': widget.tmdbId,
        'imdbId': widget.imdbId,
        'backdropPath': widget.backdropPath,
        'posterPath': widget.posterPath,
        'mediaType': 'tv',
        'fileIdx': stream.fileIdx,
        'nextEpisodePayload': nextPayload,
      });
    } else if (stream.url != null) {
      final nextPayload = nextEpisodePayloadForPlayer(
        tmdbId: widget.tmdbId,
        mediaType: 'tv',
        season: widget.season,
        episode: widget.episode,
        showTitle: widget.showName,
        imdbId: widget.imdbId,
        backdropPath: widget.backdropPath,
        posterPath: widget.posterPath,
        logoUrl: '',
      );
      PlayerLauncher.launch(
        stream.url!,
        title: '${widget.showName} S${widget.season.toString().padLeft(2, '0')}E${widget.episode.toString().padLeft(2, '0')}',
        tmdbId: widget.tmdbId,
        imdbId: widget.imdbId,
        season: widget.season,
        episode: widget.episode,
        magnet: stream.url!,
        backdropPath: widget.backdropPath,
        posterPath: widget.posterPath,
        mediaType: 'tv',
        nextEpisodePayload: nextPayload,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sTag = 'S${widget.season.toString().padLeft(2, '0')}E${widget.episode.toString().padLeft(2, '0')}';
    final anyLoading = _isLoading || _isLoadingAddons;

    // Build unified list
    final items = <_UnifiedSource>[];
    if (_activeFilter == 'all' || _activeFilter == 'PlayTorrio') {
      for (final s in _sources) {
        items.add(_UnifiedSource.torrent(s));
      }
    }
    if (_activeFilter == 'all') {
      for (final entry in _addonStreams.entries) {
        for (final s in entry.value) {
          items.add(_UnifiedSource.addon(s));
        }
      }
    } else if (_activeFilter != 'PlayTorrio') {
      final list = _addonStreams[_activeFilter];
      if (list != null) {
        for (final s in list) {
          items.add(_UnifiedSource.addon(s));
        }
      }
    }

    final totalCount = _sources.length + _addonStreams.values.fold(0, (sum, list) => sum + list.length);
    final filters = _filters;
    final showFilters = filters.length > 2;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 40),
      child: Container(
            decoration: BoxDecoration(
              color: _kBgDialog,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _kWhite08),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: _kPurple30,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          sTag,
                          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.episodeName,
                          style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (!anyLoading)
                        Text(
                          '$totalCount sources',
                          style: const TextStyle(color: AppColors.textDim, fontSize: 13),
                        ),
                    ],
                  ),
                ),
                // Filter chips
                if (showFilters)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: SizedBox(
                      height: 32,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: filters.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 6),
                        itemBuilder: (_, i) {
                          final f = filters[i];
                          return _FilterChip(
                            label: f == 'all' ? 'All' : f,
                            active: _activeFilter == f,
                            onSelect: () {
                              setState(() => _activeFilter = f);
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (!mounted) return;
                                final focus = FocusManager.instance.primaryFocus;
                                focus?.focusInDirection(TraversalDirection.down);
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ),
                Divider(color: _kWhite08, height: 1),
                Expanded(
                  child: anyLoading && items.isEmpty
                      ? const Center(child: CircularProgressIndicator(color: AppColors.purpleLight))
                      : items.isEmpty
                          ? const Center(
                              child: Text('No sources found', style: TextStyle(color: AppColors.textDim, fontSize: 15)),
                            )
                          : ListView.builder(
                              key: ValueKey('dialog_sources_$_activeFilter'),
                              padding: const EdgeInsets.all(16),
                              cacheExtent: 2000,
                              itemCount: items.length + (anyLoading ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (index == items.length) {
                                  return const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Center(child: CircularProgressIndicator(color: AppColors.purpleLight)),
                                  );
                                }
                                final item = items[index];
                                if (item.torrentSource != null) {
                                  return _SourceRow(
                                    source: item.torrentSource!,
                                    autofocus: index == 0,
                                    onSelect: () => _playTorrentSource(item.torrentSource!),
                                  );
                                } else {
                                  return _StremioStreamRow(
                                    stream: item.stremioStream!,
                                    autofocus: index == 0,
                                    onSelect: () => _playAddonStream(item.stremioStream!),
                                  );
                                }
                              },
                            ),
                ),
              ],
            ),
          ),
    );
  }
}

// ─── Unified Source (wraps either TorrentSource or StremioStream) ───

class _UnifiedSource {
  final TorrentSource? torrentSource;
  final StremioStream? stremioStream;

  _UnifiedSource.torrent(TorrentSource source) : torrentSource = source, stremioStream = null;
  _UnifiedSource.addon(StremioStream stream) : torrentSource = null, stremioStream = stream;
}

// ─── Filter Chip ───

class _FilterChip extends StatefulWidget {
  final String label;
  final bool active;
  final VoidCallback onSelect;

  const _FilterChip({required this.label, required this.active, required this.onSelect});

  @override
  State<_FilterChip> createState() => _FilterChipState();
}

class _FilterChipState extends State<_FilterChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onSelect,
      child: DpadFocusable(
        region: 'filters',
        onFocus: () => setState(() => _focused = true),
        onBlur: () => setState(() => _focused = false),
        onSelect: widget.onSelect,
        builder: (context, isFocused, child) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: widget.active
                  ? _kPurple30
                  : _focused ? _kWhite10 : _kWhite05,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _focused
                    ? AppColors.purpleLight
                    : widget.active
                        ? _kPurple40
                        : Colors.transparent,
                width: 1,
              ),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                color: widget.active || _focused ? AppColors.textPrimary : AppColors.textSecondary,
                fontSize: 12,
                fontWeight: widget.active ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          );
        },
        child: const SizedBox.shrink(),
      ),
    );
  }
}

// ─── Stremio Stream Row ───

class _StremioStreamRow extends StatefulWidget {
  final StremioStream stream;
  final VoidCallback? onSelect;
  final bool autofocus;

  const _StremioStreamRow({required this.stream, this.onSelect, this.autofocus = false});

  @override
  State<_StremioStreamRow> createState() => _StremioStreamRowState();
}

class _StremioStreamRowState extends State<_StremioStreamRow> with AutomaticKeepAliveClientMixin {
  bool _focused = false;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final stream = widget.stream;
    final quality = stream.quality;
    final size = stream.size;
    final seeders = stream.seeders;
    final provider = stream.provider;
    final filename = stream.filename ?? '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: widget.onSelect ?? () {},
        child: DpadFocusable(
            region: 'streams',
            autofocus: widget.autofocus,
            onFocus: () => setState(() => _focused = true),
            onBlur: () => setState(() => _focused = false),
            onSelect: widget.onSelect ?? () {},
            builder: (context, isFocused, child) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: _focused
                      ? _kPurple15
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _focused ? _kPurpleLight50 : Colors.transparent,
                    width: 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Stream name / filename
                    Text(
                      filename.isNotEmpty
                          ? filename
                          : stream.name.isNotEmpty
                              ? stream.name.split('\n').first
                              : stream.title.split('\n').first,
                      style: TextStyle(
                        color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                        fontSize: 14,
                        fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // Description line for external URL streams
                    if (stream.isExternalLink && stream.title.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          stream.title.split('\n').first,
                          style: const TextStyle(
                            color: _kDim70,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        // Quality badge
                        if (quality.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: _kPurple20,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: _kPurple40),
                            ),
                            child: Text(
                              quality,
                              style: const TextStyle(color: AppColors.purpleLight, fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ),
                        if (quality.isNotEmpty) const SizedBox(width: 8),
                        // Size
                        if (size.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: _kWhite08,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: _kWhite10),
                            ),
                            child: Text(
                              size,
                              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w500),
                            ),
                          ),
                        if (size.isNotEmpty) const SizedBox(width: 8),
                        // Seeders (only for torrents)
                        if (stream.isTorrent && seeders > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: _kGreen15,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: _kGreen30),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.arrow_upward_rounded, color: _kGreen, size: 12),
                                const SizedBox(width: 3),
                                Text(
                                  '$seeders',
                                  style: const TextStyle(color: _kGreen, fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        // URL indicator (for direct streams)
                        if (!stream.isTorrent)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: _kBlue15,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: _kBlue30),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.link_rounded, color: _kBlue, size: 12),
                                SizedBox(width: 3),
                                Text(
                                  'Direct',
                                  style: TextStyle(color: _kBlue, fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        const Spacer(),
                        // Provider
                        Text(
                          provider,
                          style: const TextStyle(
                            color: _kDim70,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
            child: const SizedBox.shrink(),
          ),
        ),
    );
  }
}

// ─── Collection Item Row ───

class _CollectionItemRow extends StatefulWidget {
  final String title;
  final String? thumbnail;
  final VoidCallback onSelected;

  const _CollectionItemRow({super.key, required this.title, this.thumbnail, required this.onSelected});

  @override
  State<_CollectionItemRow> createState() => _CollectionItemRowState();
}

class _CollectionItemRowState extends State<_CollectionItemRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onSelected,
      child: DpadFocusable(
        region: 'collection',
        onFocus: () => setState(() => _focused = true),
        onBlur: () => setState(() => _focused = false),
        onSelect: widget.onSelected,
        builder: (context, isFocused, child) {
          return Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _focused ? _kPurple15 : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _focused ? _kPurpleLight50 : Colors.transparent,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 85,
                    height: 125,
                    child: widget.thumbnail != null && widget.thumbnail!.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: widget.thumbnail!,
                            fit: BoxFit.cover,
                            memCacheWidth: 170,
                            placeholder: (_, _) => const ColoredBox(color: AppColors.surfaceLight),
                          )
                        : const _PosterPlaceholder(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                      fontSize: 14,
                      fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        },
        child: const SizedBox.shrink(),
      ),
    );
  }
}

// ─── Custom Episode Row (for Stremio series with custom IDs) ───

class _CustomEpisodeRow extends StatefulWidget {
  final Map<String, dynamic> episode;
  final VoidCallback? onSelected;

  const _CustomEpisodeRow({super.key, required this.episode, this.onSelected});

  @override
  State<_CustomEpisodeRow> createState() => _CustomEpisodeRowState();
}

class _CustomEpisodeRowState extends State<_CustomEpisodeRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final epNum = widget.episode['episode'] as int?;
    final name = widget.episode['title'] as String? ?? '';
    final thumb = widget.episode['thumbnail'] as String?;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: GestureDetector(
        onTap: widget.onSelected ?? () {},
        child: DpadFocusable(
          region: 'episodes',
          onFocus: () => setState(() => _focused = true),
          onBlur: () => setState(() => _focused = false),
          onSelect: widget.onSelected ?? () {},
          builder: (context, isFocused, child) {
            return Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: _focused ? _kPurple15 : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _focused ? _kPurpleLight50 : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 175,
                      height: 98,
                      child: thumb != null && thumb.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: thumb,
                              fit: BoxFit.cover,
                              memCacheWidth: 350,
                              placeholder: (_, _) => const ColoredBox(color: AppColors.surfaceLight),
                            )
                          : const _StillPlaceholder(),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      '$epNum. $name',
                      style: TextStyle(
                        color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                        fontSize: 14,
                        fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          },
          child: const SizedBox.shrink(),
        ),
      ),
    );
  }
}

// ─── Custom Stream Row (raw Stremio stream map) ───

class _CustomStreamRow extends StatefulWidget {
  final Map<String, dynamic> stream;
  final VoidCallback? onSelect;
  final bool autofocus;

  const _CustomStreamRow({super.key, required this.stream, this.onSelect, this.autofocus = false});

  @override
  State<_CustomStreamRow> createState() => _CustomStreamRowState();
}

class _CustomStreamRowState extends State<_CustomStreamRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final name = (widget.stream['name'] ?? '') as String;
    final title = (widget.stream['title'] ?? '') as String;
    final infoHash = widget.stream['infoHash'] as String?;
    final isTorrent = infoHash != null && infoHash.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: widget.onSelect ?? () {},
        child: DpadFocusable(
          region: 'streams',
          autofocus: widget.autofocus,
          onFocus: () => setState(() => _focused = true),
          onBlur: () => setState(() => _focused = false),
          onSelect: widget.onSelect ?? () {},
          builder: (context, isFocused, child) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: _focused ? _kPurple15 : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _focused ? _kPurpleLight50 : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name.isNotEmpty ? name : (title.isNotEmpty ? title.split('\n').first : 'Stream'),
                    style: TextStyle(
                      color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                      fontSize: 14,
                      fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (title.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      title.replaceAll('\n', ' · '),
                      style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: isTorrent
                              ? _kGreen15
                              : _kBlue15,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          isTorrent ? 'Torrent' : 'Direct',
                          style: TextStyle(
                            color: isTorrent ? _kGreen : _kBlue,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
          child: const SizedBox.shrink(),
        ),
      ),
    );
  }
}

// ─── Custom Stream Dialog (for custom ID episodes) ───

class _CustomStreamDialog extends StatefulWidget {
  final String title;
  final String videoId;
  final Map<String, dynamic> stremioItem;

  const _CustomStreamDialog({
    required this.title,
    required this.videoId,
    required this.stremioItem,
  });

  @override
  State<_CustomStreamDialog> createState() => _CustomStreamDialogState();
}

class _CustomStreamDialogState extends State<_CustomStreamDialog> {
  List<Map<String, dynamic>> _streams = [];
  bool _isLoading = true;
  bool _customDialogAutoPickDone = false;

  @override
  void initState() {
    super.initState();
    _loadStreams();
  }

  Future<void> _loadStreams() async {
    final addonBaseUrl = widget.stremioItem['_addonBaseUrl']?.toString() ?? '';
    final type = widget.stremioItem['type']?.toString() ?? 'series';
    if (addonBaseUrl.isEmpty) {
      setState(() => _isLoading = false);
      return;
    }
    try {
      final streams = await StremioAddonService.getStreams(
        baseUrl: addonBaseUrl, type: type, id: widget.videoId,
      );
      if (mounted) {
        setState(() {
          _streams = streams;
          _isLoading = false;
        });
        _tryAutoPickCustomDialog();
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _tryAutoPickCustomDialog() {
    if (!SettingsService.instance.stremioAutoPickStreams ||
        SettingsService.instance.streamingMode ||
        _isLoading) {
      return;
    }
    if (_customDialogAutoPickDone) {
      return;
    }
    final best = StremioAddonService.firstRawStreamMap(_streams);
    if (best == null) {
      return;
    }
    _customDialogAutoPickDone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _playStream(best);
    });
  }

  void _playStream(Map<String, dynamic> s) {
    final extUrl = s['externalUrl'] as String?;
    if (extUrl != null && extUrl.isNotEmpty) {
      Navigator.of(context).pop();
      handleStremioDeepLink(context, extUrl);
      return;
    }
    Navigator.of(context).pop();
    final infoHash = s['infoHash'] as String?;
    final url = s['url'] as String?;

    if (infoHash != null && infoHash.isNotEmpty) {
      final buf = StringBuffer('magnet:?xt=urn:btih:$infoHash');
      final hints = s['behaviorHints'] as Map<String, dynamic>? ?? {};
      final fn = hints['filename'] as String?;
      if (fn != null && fn.isNotEmpty) buf.write('&dn=${Uri.encodeComponent(fn)}');
      final srcs = s['sources'] as List? ?? [];
      for (final src in srcs) {
        if (src is String && src.startsWith('tracker:')) {
          buf.write('&tr=${Uri.encodeComponent(src.substring('tracker:'.length))}');
        }
      }
      for (final t in StreamService.trackers) {
        buf.write('&tr=${Uri.encodeComponent(t)}');
      }
      Navigator.of(context).pushNamed('/player', arguments: {
        'magnet': buf.toString(),
        'title': widget.title,
        'episode': null,
        'tmdbId': null,
        'imdbId': null,
        'backdropPath': null,
        'posterPath': null,
        'mediaType': 'tv',
        'fileIdx': s['fileIdx'] as int?,
      });
    } else if (url != null && url.isNotEmpty) {
      PlayerLauncher.launch(url, title: widget.title, magnet: url, mediaType: 'tv');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 40),
      child: Container(
        decoration: BoxDecoration(
          color: _kBgDialog,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kWhite08),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
              child: Text(
                widget.title,
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Divider(color: _kWhite08, height: 1),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: AppColors.purpleLight))
                  : _streams.isEmpty
                      ? const Center(child: Text('No streams found', style: TextStyle(color: AppColors.textDim, fontSize: 15)))
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          cacheExtent: 2000,
                          itemCount: _streams.length,
                          itemBuilder: (context, index) {
                            return _CustomStreamRow(
                              stream: _streams[index],
                              autofocus: index == 0,
                              onSelect: () => _playStream(_streams[index]),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Const placeholder widgets ───

class _StillPlaceholder extends StatelessWidget {
  const _StillPlaceholder();
  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: AppColors.surfaceLight,
    child: Center(child: Icon(Icons.play_circle_outline, color: AppColors.textDim, size: 36)),
  );
}

class _PosterPlaceholder extends StatelessWidget {
  const _PosterPlaceholder();
  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: AppColors.surfaceLight,
    child: Center(child: Icon(Icons.movie, color: AppColors.textDim, size: 32)),
  );
}
