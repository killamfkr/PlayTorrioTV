import 'dart:async';
import 'package:flutter/material.dart';
import 'package:dpad/dpad.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../build_config.dart';
import '../constants.dart';
import '../services/tmdb_service.dart';
import '../services/continue_watching_service.dart';
import '../services/stream_service.dart';
import '../services/player_launcher.dart';
import '../services/settings_service.dart';
import '../services/stremio_addon_service.dart';

class HomeScreen extends StatefulWidget {
  final String category;
  const HomeScreen({super.key, required this.category});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final ScrollController _scrollController = ScrollController();
  Map<String, dynamic>? _focusedItem;
  bool _isLoading = true;
  List<_ContentRow> _rows = [];
  String? _currentLogoPath;
  final Map<int, String?> _logoCache = {};
  List<WatchEntry> _cwEntries = [];
  bool _cwEditMode = false;
  Timer? _focusDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadContent();
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.category != widget.category) {
      _loadContent();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshContinueWatching();
    }
  }

  Future<void> _refreshContinueWatching() async {
    await ContinueWatchingService.load();
    if (mounted) {
      setState(() => _cwEntries = ContinueWatchingService.entries);
    }
  }

  /// Low-RAM: run TMDB calls in small batches to avoid OOM when many JSON + images load at once.
  Future<List<T>> _batched<T>(List<Future<T> Function()> jobs, {required int batchSize}) async {
    final out = <T>[];
    for (var i = 0; i < jobs.length; i += batchSize) {
      final end = (i + batchSize > jobs.length) ? jobs.length : i + batchSize;
      final chunk = jobs.sublist(i, end).map((f) => f()).toList();
      out.addAll(await Future.wait(chunk));
    }
    return out;
  }

  Future<void> _loadContent() async {
    setState(() => _isLoading = true);
    try {
      List<_ContentRow> rows = [];
      final low = kLowRamStartup;
      switch (widget.category) {
        case 'home':
          // Match PlayTorrioV2 mobile home: movie trending (not trending/all), same row order & labels.
          final results = low
              ? await _batched<dynamic>([
                  () => TmdbService.getTrendingMovies(),
                  () => TmdbService.getPopularMovies(),
                  () => TmdbService.getPopularTv(),
                  () => TmdbService.getTopRatedMovies(),
                  () => TmdbService.getTopRatedTv(),
                  () => TmdbService.getNowPlayingMovies(),
                ], batchSize: 2)
              : await Future.wait([
                  TmdbService.getTrendingMovies(),
                  TmdbService.getPopularMovies(),
                  TmdbService.getPopularTv(),
                  TmdbService.getTopRatedMovies(),
                  TmdbService.getTopRatedTv(),
                  TmdbService.getNowPlayingMovies(),
                ]);
          rows = [
            _ContentRow('Trending Now', results[0], useBackdrop: true),
            _ContentRow('Popular Movies', results[1]),
            _ContentRow('Popular Series', results[2]),
            _ContentRow('Top Rated Movies', results[3]),
            _ContentRow('Top Rated Series', results[4]),
            _ContentRow('New Releases', results[5], useBackdrop: true),
          ];
          break;
        case 'movies':
          final results = low
              ? await _batched<dynamic>([
                  () => TmdbService.getPopularMovies(),
                  () => TmdbService.getTopRatedMovies(),
                  () => TmdbService.getNowPlayingMovies(),
                  () => TmdbService.getTrendingMovies(timeWindow: 'week'),
                ], batchSize: 2)
              : await Future.wait([
                  TmdbService.getPopularMovies(),
                  TmdbService.getTopRatedMovies(),
                  TmdbService.getNowPlayingMovies(),
                  TmdbService.getTrendingMovies(timeWindow: 'week'),
                ]);
          rows = [
            _ContentRow('Popular Movies', results[0], useBackdrop: true),
            _ContentRow('Top Rated', results[1]),
            _ContentRow('Now Playing', results[2]),
            _ContentRow('Trending This Week', results[3]),
          ];
          break;
        case 'tv':
          final results = low
              ? await _batched<dynamic>([
                  () => TmdbService.getPopularTv(),
                  () => TmdbService.getTopRatedTv(),
                  () => TmdbService.getTrendingTv(timeWindow: 'week'),
                ], batchSize: 2)
              : await Future.wait([
                  TmdbService.getPopularTv(),
                  TmdbService.getTopRatedTv(),
                  TmdbService.getTrendingTv(timeWindow: 'week'),
                ]);
          rows = [
            _ContentRow('Popular Series', results[0], useBackdrop: true),
            _ContentRow('Top Rated', results[1]),
            _ContentRow('Trending This Week', results[2]),
          ];
          break;
      }
      if (mounted) {
        // Reload continue watching entries
        await ContinueWatchingService.load();
        _cwEntries = ContinueWatchingService.entries;

        setState(() {
          _rows = rows;
          _isLoading = false;
          // Set initial focused item from first TMDB row (skip CW row)
          if (rows.isNotEmpty && rows[0].items.isNotEmpty) {
            _focusedItem = rows[0].items[0];
          }
        });

        // Load Stremio catalog rows in the background (home category only)
        if (widget.category == 'home') {
          _loadStremioCatalogRows();
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadStremioCatalogRows() async {
    final addons = SettingsService.instance.stremioAddonsRich;
    if (addons.isEmpty) return;

    final catalogs = StremioAddonService.getAllCatalogs();
    // Limit to first 6 catalogs to avoid overwhelming the home screen
    final limited = catalogs.take(6).toList();

    final futures = limited.map((cat) async {
      try {
        final items = await StremioAddonService.getCatalog(
          baseUrl: cat['addonBaseUrl'] as String,
          type: cat['catalogType'] as String,
          id: cat['catalogId'] as String,
        );
        if (items.isEmpty) return null;
        final addonName = cat['addonName'] as String? ?? '';
        final catName = cat['catalogName'] as String? ?? cat['catalogId'] as String;
        final title = addonName.isNotEmpty ? '$addonName — $catName' : catName;
        // Normalize items: map poster→poster_path so cards work
        final normalized = items.map<Map<String, dynamic>>((item) {
          final m = Map<String, dynamic>.from(item as Map);
          m['_stremio'] = true;
          // Use poster field as poster_path if no poster_path exists
          if (m['poster_path'] == null && m['poster'] != null) {
            m['poster_path'] = m['poster'];
          }
          if (m['backdrop_path'] == null && m['background'] != null) {
            m['backdrop_path'] = m['background'];
          }
          // Ensure title/name exist
          if (m['title'] == null && m['name'] != null) {
            m['title'] = m['name'];
          }
          // Store addon base URL for later resolution
          m['_addonBaseUrl'] = cat['addonBaseUrl'];
          m['_addonType'] = cat['catalogType'];
          return m;
        }).toList();
        return _ContentRow(title, normalized);
      } catch (_) {
        return null;
      }
    });

    final results = await Future.wait(futures);
    final newRows = results.whereType<_ContentRow>().toList();
    if (newRows.isNotEmpty && mounted) {
      setState(() {
        _rows = [..._rows, ...newRows];
      });
    }
  }

  void _onItemFocused(Map<String, dynamic> item) {
    _focusDebounce?.cancel();
    _focusDebounce = Timer(const Duration(milliseconds: 50), () {
      if (!mounted) return;
      setState(() {
        _focusedItem = item;
        if (item['_stremio'] == true) {
          _currentLogoPath = null;
        }
      });
      if (item['_stremio'] != true) {
        _fetchLogo(item);
      }
    });
  }

  Future<void> _fetchLogo(Map<String, dynamic> item) async {
    final id = item['id'] as int;
    final mediaType = _getMediaType(item);

    // Already cached
    if (_logoCache.containsKey(id)) {
      if (mounted && _focusedItem?['id'] == id) {
        setState(() => _currentLogoPath = _logoCache[id]);
      }
      return;
    }

    try {
      final details = mediaType == 'tv'
          ? await TmdbService.getTvDetails(id)
          : await TmdbService.getMovieDetails(id);
      final images = details['images'] as Map<String, dynamic>?;
      String? logoPath;
      if (images != null) {
        final logos = images['logos'] as List?;
        if (logos != null && logos.isNotEmpty) {
          final enLogo = logos.firstWhere(
            (l) => l['iso_639_1'] == 'en',
            orElse: () => logos.first,
          );
          logoPath = enLogo['file_path'] as String?;
        }
      }
      _logoCache[id] = logoPath;
      if (mounted && _focusedItem?['id'] == id) {
        setState(() => _currentLogoPath = logoPath);
      }
    } catch (_) {
      _logoCache[id] = null;
      if (mounted && _focusedItem?['id'] == id) {
        setState(() => _currentLogoPath = null);
      }
    }
  }

  String _getTitle(Map<String, dynamic> item) {
    return (item['title'] ?? item['name'] ?? '') as String;
  }

  String _getYear(Map<String, dynamic> item) {
    final date = (item['release_date'] ?? item['first_air_date'] ?? '') as String;
    if (date.length >= 4) return date.substring(0, 4);
    return '';
  }

  String _getMediaType(Map<String, dynamic> item) {
    if (item['media_type'] != null) return item['media_type'] as String;
    if (item['first_air_date'] != null) return 'tv';
    return 'movie';
  }

  Future<void> _openItem(Map<String, dynamic> item) async {
    // TMDB items — have an int 'id'
    if (item['_stremio'] != true) {
      Navigator.pushNamed(context, '/details', arguments: {
        'id': item['id'] as int,
        'media_type': _getMediaType(item),
      });
      return;
    }

    // Stremio items — resolve IMDB → TMDB or fallback to custom detail
    final id = (item['id'] ?? item['imdb_id'] ?? '') as String;
    final type = (item['type'] ?? item['_addonType'] ?? 'movie') as String;
    final mediaType = type == 'series' ? 'tv' : 'movie';

    if (id.startsWith('tt')) {
      // IMDB id — try to find TMDB id
      final tmdb = await TmdbService.findByImdbId(id);
      if (tmdb != null && mounted) {
        Navigator.pushNamed(context, '/details', arguments: {
          'id': tmdb['id'] as int,
          'media_type': tmdb['media_type'] ?? mediaType,
        });
        return;
      }
    }

    // Try search by name
    final name = (item['name'] ?? item['title'] ?? '') as String;
    if (name.isNotEmpty) {
      final results = await TmdbService.searchMulti(name);
      if (results.isNotEmpty && mounted) {
        final match = results.first;
        Navigator.pushNamed(context, '/details', arguments: {
          'id': match['id'] as int,
          'media_type': match['media_type'] ?? mediaType,
        });
        return;
      }
    }

    // Custom ID fallback — pass raw stremio item
    if (mounted) {
      Navigator.pushNamed(context, '/details', arguments: {
        'id': id.hashCode,
        'media_type': mediaType,
        'stremio_item': item,
      });
    }
  }

  @override
  void dispose() {
    _focusDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }

    final screenHeight = MediaQuery.of(context).size.height;
    final heroHeight = screenHeight * 0.45;

    return PopScope(
      canPop: !_cwEditMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _cwEditMode) {
          setState(() => _cwEditMode = false);
        }
      },
      child: Stack(
      children: [
        // Hero backdrop — sharp, no blur, cinematic
        if (_focusedItem != null && _focusedItem!['backdrop_path'] != null)
          RepaintBoundary(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: SizedBox(
              key: ObjectKey(_focusedItem),
              height: heroHeight,
              width: double.infinity,
              child: CachedNetworkImage(
                imageUrl: (_focusedItem!['backdrop_path'] as String).startsWith('http')
                    ? _focusedItem!['backdrop_path'] as String
                    : TmdbApi.backdropUrl(_focusedItem!['backdrop_path'] as String?, size: 'w1280'),
                fit: BoxFit.fitWidth,
                alignment: Alignment.topCenter,
                memCacheWidth: 1280,
                fadeInDuration: const Duration(milliseconds: 150),
                fadeOutDuration: const Duration(milliseconds: 100),
              ),
            ),
          ),
          ),

        // Bottom gradient on hero
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: heroHeight,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.7),
                  Colors.black,
                ],
                stops: const [0.0, 0.3, 0.75, 1.0],
              ),
            ),
          ),
        ),

        // Left vignette for text readability
        Positioned(
          top: 0,
          left: 0,
          bottom: 0,
          width: MediaQuery.of(context).size.width * 0.45,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.black.withValues(alpha: 0.8),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),

        // Content
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Hero info
            SizedBox(
              height: heroHeight - 20,
              child: _focusedItem != null
                  ? _HeroInfo(
                      title: _getTitle(_focusedItem!),
                      year: _getYear(_focusedItem!),
                      rating: (_focusedItem!['vote_average'] as num?)?.toDouble() ?? 0,
                      overview: (_focusedItem!['overview'] ?? '') as String,
                      mediaType: _getMediaType(_focusedItem!),
                      logoPath: _currentLogoPath,
                    )
                  : const SizedBox.shrink(),
            ),

            // Content rows
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.only(bottom: 40),
                itemCount: _rows.length + (_cwEntries.isNotEmpty ? 1 : 0),
                itemBuilder: (context, index) {
                  // Continue Watching row at position 0
                  if (_cwEntries.isNotEmpty && index == 0) {
                    return _ContinueWatchingSlider(
                      entries: _cwEntries,
                      rowIndex: 0,
                      isFirstRow: true,
                      editMode: _cwEditMode,
                      onEditToggle: () {
                        setState(() => _cwEditMode = !_cwEditMode);
                      },
                      onItemFocused: (entry) {
                        // Update hero backdrop for CW items
                        if (entry.backdropPath != null && entry.backdropPath!.isNotEmpty) {
                          setState(() {
                            _focusedItem = {
                              'id': entry.tmdbId,
                              'backdrop_path': entry.backdropPath,
                              'title': entry.title,
                              'overview': '',
                              'vote_average': 0,
                              'media_type': entry.mediaType,
                            };
                            _currentLogoPath = null;
                          });
                          _fetchLogo({
                            'id': entry.tmdbId,
                            'media_type': entry.mediaType,
                            if (entry.mediaType == 'tv') 'first_air_date': '',
                          });
                        }
                      },
                      onItemSelected: (entry) {
                        if (entry.magnet == '__streaming__') {
                          PlayerLauncher.launchStreaming(
                            tmdbId: entry.tmdbId,
                            imdbId: entry.imdbId,
                            title: entry.title,
                            mediaType: entry.mediaType,
                            backdropPath: entry.backdropPath ?? '',
                            posterPath: entry.posterPath ?? '',
                            season: entry.season ?? -1,
                            episode: entry.episode ?? -1,
                            resumePositionMs: entry.positionMs,
                          );
                        } else {
                          Navigator.pushNamed(context, '/player', arguments: {
                            'magnet': entry.magnet,
                            'title': entry.title,
                            'episode': (entry.season != null && entry.episode != null)
                                ? EpisodeTarget(season: entry.season!, episode: entry.episode!)
                                : null,
                            'tmdbId': entry.tmdbId,
                            'imdbId': entry.imdbId,
                            'backdropPath': entry.backdropPath ?? '',
                            'posterPath': entry.posterPath ?? '',
                            'mediaType': entry.mediaType,
                            'fileIdx': entry.fileIdx,
                            'resumePositionMs': entry.positionMs,
                          });
                        }
                      },
                      onItemRemoved: (entry) async {
                        await ContinueWatchingService.remove(entry.key);
                        setState(() {
                          _cwEntries = ContinueWatchingService.entries;
                        });
                      },
                    );
                  }

                  final rowIdx = _cwEntries.isNotEmpty ? index - 1 : index;
                  return _ContentSlider(
                    title: _rows[rowIdx].title,
                    items: _rows[rowIdx].items,
                    useBackdrop: _rows[rowIdx].useBackdrop,
                    rowIndex: index,
                    onItemFocused: _onItemFocused,
                    onItemSelected: (item) => _openItem(item),
                    isFirstRow: _cwEntries.isEmpty && index == 0,
                  );
                },
              ),
            ),
          ],
        ),
      ],
    ),
    );
  }
}

class _ContentRow {
  final String title;
  final List<dynamic> items;
  final bool useBackdrop;
  _ContentRow(this.title, this.items, {this.useBackdrop = false});
}

class _HeroInfo extends StatelessWidget {
  final String title;
  final String year;
  final double rating;
  final String overview;
  final String mediaType;
  final String? logoPath;

  const _HeroInfo({
    required this.title,
    required this.year,
    required this.rating,
    required this.overview,
    required this.mediaType,
    this.logoPath,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Media type chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              mediaType == 'tv' ? 'SERIES' : 'MOVIE',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: logoPath != null
                ? ConstrainedBox(
                    key: ValueKey('logo_$logoPath'),
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.1,
                      maxWidth: MediaQuery.of(context).size.width * 0.25,
                    ),
                    child: CachedNetworkImage(
                      imageUrl: TmdbApi.logoUrl(logoPath),
                      fit: BoxFit.contain,
                      alignment: Alignment.centerLeft,
                      errorWidget: (_, _, _) => Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          height: 1.1,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                : Text(
                    title,
                    key: ValueKey('title_$title'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      height: 1.1,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (year.isNotEmpty)
                Text(year, style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 15, fontWeight: FontWeight.w500)),
              if (year.isNotEmpty && rating > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Container(width: 4, height: 4, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.4), shape: BoxShape.circle)),
                ),
              if (rating > 0) ...[
                Icon(Icons.star_rounded, color: Colors.amber.shade400, size: 18),
                const SizedBox(width: 4),
                Text(rating.toStringAsFixed(1), style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: MediaQuery.of(context).size.width * 0.35,
            child: Text(
              overview,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13, height: 1.4),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ContentSlider extends StatefulWidget {
  final String title;
  final List<dynamic> items;
  final bool useBackdrop;
  final int rowIndex;
  final ValueChanged<Map<String, dynamic>> onItemFocused;
  final ValueChanged<Map<String, dynamic>> onItemSelected;
  final bool isFirstRow;

  const _ContentSlider({
    required this.title,
    required this.items,
    required this.useBackdrop,
    required this.rowIndex,
    required this.onItemFocused,
    required this.onItemSelected,
    required this.isFirstRow,
  });

  @override
  State<_ContentSlider> createState() => _ContentSliderState();
}

class _ContentSliderState extends State<_ContentSlider> with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late AnimationController _enterCtrl;
  late Animation<double> _fadeIn;
  late Animation<Offset> _slideIn;

  @override
  void initState() {
    super.initState();
    final delay = (widget.rowIndex * 0.12).clamp(0.0, 0.5);
    _enterCtrl = AnimationController(duration: const Duration(milliseconds: 500), vsync: this);
    _fadeIn = CurvedAnimation(parent: _enterCtrl, curve: Curves.easeOut);
    _slideIn = Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero).animate(
      CurvedAnimation(parent: _enterCtrl, curve: Curves.easeOutCubic),
    );
    Future.delayed(Duration(milliseconds: (delay * 1000).toInt()), () {
      if (mounted) _enterCtrl.forward();
    });
  }

  void _scrollToIndex(int index) {
    final itemWidth = widget.useBackdrop ? 262.0 : 142.0;
    final offset = index * itemWidth;
    _scrollController.animateTo(
      (offset - 100).clamp(0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _enterCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rowContext = context;
    final sliderHeight = widget.useBackdrop ? 170.0 : 220.0;

    return FadeTransition(
      opacity: _fadeIn,
      child: SlideTransition(
        position: _slideIn,
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
          child: Text(
            widget.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
        ClipRect(
          child: SizedBox(
            height: sliderHeight,
            child: ListView.builder(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              cacheExtent: 500,
              itemCount: widget.items.length,
              itemBuilder: (_, index) {
                final item = widget.items[index] as Map<String, dynamic>;
                void onFocused() {
                  widget.onItemFocused(item);
                  _scrollToIndex(index);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (rowContext.mounted) {
                      Scrollable.ensureVisible(
                        rowContext,
                        alignment: 0.3,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOutCubic,
                      );
                    }
                  });
                }
                if (widget.useBackdrop) {
                  return _BackdropCard(
                    item: item,
                    onFocused: onFocused,
                    onSelected: () => widget.onItemSelected(item),
                    autofocus: widget.isFirstRow && index == 0,
                  );
                }
                return _PosterCard(
                  item: item,
                  onFocused: onFocused,
                  onSelected: () => widget.onItemSelected(item),
                  autofocus: widget.isFirstRow && index == 0,
                );
              },
            ),
          ),
        ),
      ],
    ),
      ),
    );
  }
}

// --- Backdrop card (wide, landscape) ---

class _BackdropCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final VoidCallback onFocused;
  final VoidCallback onSelected;
  final bool autofocus;

  const _BackdropCard({
    required this.item,
    required this.onFocused,
    required this.onSelected,
    this.autofocus = false,
  });

  @override
  State<_BackdropCard> createState() => _BackdropCardState();
}

class _BackdropCardState extends State<_BackdropCard> with SingleTickerProviderStateMixin {
  bool _focused = false;
  late AnimationController _scaleCtrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _scaleCtrl = AnimationController(duration: const Duration(milliseconds: 180), vsync: this);
    _scale = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOutCubic),
    );
  }

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final backdrop = widget.item['backdrop_path'] as String?;
    final title = (widget.item['title'] ?? widget.item['name'] ?? '') as String;
    final isFullUrl = backdrop != null && backdrop.startsWith('http');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: RepaintBoundary(
      child: GestureDetector(
        onTap: widget.onSelected,
        child: DpadFocusable(
          autofocus: widget.autofocus,
          region: 'content',
          onFocus: () {
            setState(() => _focused = true);
            _scaleCtrl.forward();
            widget.onFocused();
          },
          onBlur: () {
            setState(() => _focused = false);
            _scaleCtrl.reverse();
          },
          onSelect: widget.onSelected,
          builder: (context, isFocused, child) {
            return AnimatedBuilder(
              animation: _scale,
              builder: (context, child) {
                return Transform.scale(
                  scale: _scale.value,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 250,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: _focused ? Colors.white : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          backdrop != null && backdrop.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: isFullUrl ? backdrop : TmdbApi.backdropUrl(backdrop, size: 'w780'),
                                  fit: BoxFit.cover,
                                  memCacheWidth: 500,
                                  placeholder: (_, _) => Container(color: AppColors.cardBg),
                                  errorWidget: (_, _, _) => Container(
                                    color: AppColors.cardBg,
                                    child: const Icon(Icons.movie, color: AppColors.textDim),
                                  ),
                                )
                              : Container(color: AppColors.cardBg),
                          // Bottom gradient for title
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            height: 60,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Colors.transparent, Colors.black.withValues(alpha: 0.85)],
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 8,
                            left: 10,
                            right: 10,
                            child: Text(
                              title,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: _focused ? FontWeight.w700 : FontWeight.w500,
                                shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
          child: const SizedBox.shrink(),
        ),
      ),
      ),
    );
  }
}

// --- Poster card (portrait) ---

class _PosterCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final VoidCallback onFocused;
  final VoidCallback onSelected;
  final bool autofocus;

  const _PosterCard({
    required this.item,
    required this.onFocused,
    required this.onSelected,
    this.autofocus = false,
  });

  @override
  State<_PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<_PosterCard> with SingleTickerProviderStateMixin {
  bool _focused = false;
  late AnimationController _scaleCtrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _scaleCtrl = AnimationController(duration: const Duration(milliseconds: 180), vsync: this);
    _scale = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOutCubic),
    );
  }

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final posterPath = widget.item['poster_path'] as String?;
    final isFullUrl = posterPath != null && posterPath.startsWith('http');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: RepaintBoundary(
      child: GestureDetector(
        onTap: widget.onSelected,
        child: DpadFocusable(
          autofocus: widget.autofocus,
          region: 'content',
          onFocus: () {
            setState(() => _focused = true);
            _scaleCtrl.forward();
            widget.onFocused();
          },
          onBlur: () {
            setState(() => _focused = false);
            _scaleCtrl.reverse();
          },
          onSelect: widget.onSelected,
          builder: (context, isFocused, child) {
            return AnimatedBuilder(
              animation: _scale,
              builder: (context, child) {
                return Transform.scale(
                  scale: _scale.value,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 130,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: _focused ? Colors.white : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: posterPath != null && posterPath.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: isFullUrl ? posterPath : TmdbApi.posterUrl(posterPath),
                              fit: BoxFit.cover,
                              memCacheWidth: 260,
                              placeholder: (_, _) => Container(color: AppColors.cardBg),
                              errorWidget: (_, _, _) => Container(
                                color: AppColors.cardBg,
                                child: const Icon(Icons.movie, color: AppColors.textDim),
                              ),
                            )
                          : Container(
                              color: AppColors.cardBg,
                              child: const Icon(Icons.movie, color: AppColors.textDim),
                            ),
                    ),
                  ),
                );
              },
            );
          },
          child: const SizedBox.shrink(),
        ),
      ),
      ),
    );
  }
}

// --- Continue Watching Slider ---

class _ContinueWatchingSlider extends StatefulWidget {
  final List<WatchEntry> entries;
  final int rowIndex;
  final bool isFirstRow;
  final bool editMode;
  final VoidCallback onEditToggle;
  final ValueChanged<WatchEntry> onItemFocused;
  final ValueChanged<WatchEntry> onItemSelected;
  final ValueChanged<WatchEntry> onItemRemoved;

  const _ContinueWatchingSlider({
    required this.entries,
    required this.rowIndex,
    required this.isFirstRow,
    required this.editMode,
    required this.onEditToggle,
    required this.onItemFocused,
    required this.onItemSelected,
    required this.onItemRemoved,
  });

  @override
  State<_ContinueWatchingSlider> createState() => _ContinueWatchingSliderState();
}

class _ContinueWatchingSliderState extends State<_ContinueWatchingSlider>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late AnimationController _enterCtrl;
  late Animation<double> _fadeIn;
  late Animation<Offset> _slideIn;

  @override
  void initState() {
    super.initState();
    _enterCtrl = AnimationController(
        duration: const Duration(milliseconds: 500), vsync: this);
    _fadeIn = CurvedAnimation(parent: _enterCtrl, curve: Curves.easeOut);
    _slideIn = Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
        .animate(CurvedAnimation(parent: _enterCtrl, curve: Curves.easeOutCubic));
    _enterCtrl.forward();
  }

  void _scrollToIndex(int index) {
    const itemWidth = 262.0;
    final offset = index * itemWidth;
    _scrollController.animateTo(
      (offset - 100).clamp(0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _enterCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rowContext = context;

    return FadeTransition(
      opacity: _fadeIn,
      child: SlideTransition(
        position: _slideIn,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
              child: Row(
                children: [
                  Text(
                    'Continue Watching',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                  if (widget.editMode)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        '— tap to remove',
                        style: TextStyle(
                          color: Colors.red.shade300,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            ClipRect(
              child: SizedBox(
                height: 170,
                child: ListView.builder(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  cacheExtent: 500,
                  itemCount: widget.entries.length + 1,
                  itemBuilder: (_, index) {
                    // First item: pen/edit button
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: DpadFocusable(
                          autofocus: false,
                          region: 'content',
                          onSelect: widget.onEditToggle,
                          builder: (context, isFocused, child) {
                            return GestureDetector(
                              onTap: widget.onEditToggle,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: 48,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6),
                                  color: widget.editMode
                                      ? Colors.red.withValues(alpha: 0.3)
                                      : Colors.white.withValues(alpha: isFocused ? 0.15 : 0.08),
                                  border: Border.all(
                                    color: isFocused ? Colors.white : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                                child: Center(
                                  child: Icon(
                                    widget.editMode ? Icons.close : Icons.edit,
                                    color: widget.editMode ? Colors.red.shade300 : Colors.white70,
                                    size: 22,
                                  ),
                                ),
                              ),
                            );
                          },
                          child: const SizedBox.shrink(),
                        ),
                      );
                    }

                    final entry = widget.entries[index - 1];
                    return _ContinueWatchingCard(
                      entry: entry,
                      editMode: widget.editMode,
                      autofocus: widget.isFirstRow && index == 1,
                      onFocused: () {
                        widget.onItemFocused(entry);
                        _scrollToIndex(index);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (rowContext.mounted) {
                            Scrollable.ensureVisible(
                              rowContext,
                              alignment: 0.3,
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeOutCubic,
                            );
                          }
                        });
                      },
                      onSelected: () {
                        if (widget.editMode) {
                          widget.onItemRemoved(entry);
                        } else {
                          widget.onItemSelected(entry);
                        }
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Continue Watching Card (backdrop with progress bar + episode badge) ---

class _ContinueWatchingCard extends StatefulWidget {
  final WatchEntry entry;
  final bool autofocus;
  final bool editMode;
  final VoidCallback onFocused;
  final VoidCallback onSelected;

  const _ContinueWatchingCard({
    required this.entry,
    required this.onFocused,
    required this.onSelected,
    this.editMode = false,
    this.autofocus = false,
  });

  @override
  State<_ContinueWatchingCard> createState() => _ContinueWatchingCardState();
}

class _ContinueWatchingCardState extends State<_ContinueWatchingCard>
    with SingleTickerProviderStateMixin {
  bool _focused = false;
  late AnimationController _scaleCtrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _scaleCtrl = AnimationController(
        duration: const Duration(milliseconds: 180), vsync: this);
    _scale = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOutCubic),
    );
  }

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final backdrop = entry.backdropPath;
    final hasEpisode = entry.season != null && entry.episode != null;
    final episodeLabel = hasEpisode
        ? 'S${entry.season.toString().padLeft(2, '0')}E${entry.episode.toString().padLeft(2, '0')}'
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: RepaintBoundary(
      child: GestureDetector(
        onTap: widget.onSelected,
        child: DpadFocusable(
          autofocus: widget.autofocus,
          region: 'content',
          onSelect: widget.onSelected,
          onFocus: () {
            setState(() => _focused = true);
            _scaleCtrl.forward();
            widget.onFocused();
          },
          onBlur: () {
            setState(() => _focused = false);
            _scaleCtrl.reverse();
          },
          builder: (context, isFocused, child) {
            return AnimatedBuilder(
              animation: _scale,
              builder: (context, child) {
                return Transform.scale(
                  scale: _scale.value,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 250,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: _focused ? Colors.white : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Backdrop image
                          backdrop != null && backdrop.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: TmdbApi.backdropUrl(backdrop, size: 'w780'),
                                  fit: BoxFit.cover,
                                  memCacheWidth: 500,
                                  placeholder: (_, _) =>
                                      Container(color: AppColors.cardBg),
                                  errorWidget: (_, _, _) => Container(
                                    color: AppColors.cardBg,
                                    child: const Icon(Icons.movie,
                                        color: AppColors.textDim),
                                  ),
                                )
                              : Container(color: AppColors.cardBg),

                          // Bottom gradient for title/progress
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            height: 70,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Colors.black.withValues(alpha: 0.9),
                                  ],
                                ),
                              ),
                            ),
                          ),

                          // Edit mode red overlay
                          if (widget.editMode)
                            Positioned.fill(
                              child: Container(
                                color: Colors.red.withValues(alpha: _focused ? 0.4 : 0.25),
                                child: Center(
                                  child: Icon(
                                    Icons.delete_outline,
                                    color: Colors.white.withValues(alpha: _focused ? 1.0 : 0.7),
                                    size: 32,
                                  ),
                                ),
                              ),
                            ),

                          // Episode badge (top-right)
                          if (episodeLabel != null)
                            Positioned(
                              top: 6,
                              right: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  episodeLabel,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                            ),

                          // Title
                          Positioned(
                            bottom: 14,
                            left: 10,
                            right: 10,
                            child: Text(
                              entry.title,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight:
                                    _focused ? FontWeight.w700 : FontWeight.w500,
                                shadows: const [
                                  Shadow(color: Colors.black, blurRadius: 4)
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),

                          // Progress bar
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            height: 3,
                            child: LinearProgressIndicator(
                              value: entry.progress,
                              backgroundColor: Colors.white.withValues(alpha: 0.2),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                  Colors.white),
                              minHeight: 3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
          child: const SizedBox.shrink(),
        ),
      ),
      ),
    );
  }
}
