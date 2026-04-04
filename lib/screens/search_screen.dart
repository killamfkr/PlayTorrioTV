import 'dart:async';
import 'package:flutter/material.dart';
import 'package:dpad/dpad.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants.dart';
import '../services/tmdb_service.dart';
import '../services/stremio_addon_service.dart';
import '../services/settings_service.dart';
import '../main.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  String _query = '';
  bool _isSearching = false;
  Timer? _debounce;

  // TMDB results split by type
  List<dynamic> _tmdbMovies = [];
  List<dynamic> _tmdbShows = [];

  // Stremio addon results: addonName → items
  Map<String, List<Map<String, dynamic>>> _addonResults = {};

  static const _letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const _numbers = '0123456789';
  static const _gridCols = 6;

  @override
  void initState() {
    super.initState();
    MainShellState.pendingSearchQuery.addListener(_onPendingSearch);
  }

  @override
  void dispose() {
    MainShellState.pendingSearchQuery.removeListener(_onPendingSearch);
    _debounce?.cancel();
    super.dispose();
  }

  void _onPendingSearch() {
    final query = MainShellState.pendingSearchQuery.value;
    if (query != null && query.isNotEmpty) {
      MainShellState.pendingSearchQuery.value = null;
      setState(() => _query = query);
      _debounce?.cancel();
      _runSearch();
    }
  }

  void _addChar(String char) {
    setState(() => _query += char.toLowerCase());
    _triggerSearch();
  }

  void _backspace() {
    if (_query.isNotEmpty) {
      setState(() => _query = _query.substring(0, _query.length - 1));
      _triggerSearch();
    }
  }

  void _addSpace() {
    setState(() => _query += ' ');
    _triggerSearch();
  }

  void _clearQuery() {
    setState(() {
      _query = '';
      _tmdbMovies = [];
      _tmdbShows = [];
      _addonResults = {};
    });
  }

  void _triggerSearch() {
    _debounce?.cancel();
    if (_query.trim().isEmpty) {
      setState(() {
        _tmdbMovies = [];
        _tmdbShows = [];
        _addonResults = {};
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (_query.trim().isEmpty) return;
      _runSearch();
    });
  }

  Future<void> _runSearch() async {
    setState(() => _isSearching = true);

    final query = _query.trim();

    // Run TMDB + all Stremio addon searches in parallel
    final tmdbFuture = TmdbService.searchMulti(query).catchError((_) => <dynamic>[]);
    final addonFuture = SettingsService.instance.stremioAddonsRich.isNotEmpty
        ? StremioAddonService.searchAllAddons(query).catchError((_) => <String, List<Map<String, dynamic>>>{})
        : Future.value(<String, List<Map<String, dynamic>>>{});

    final results = await Future.wait([tmdbFuture, addonFuture]);

    if (!mounted || query != _query.trim()) return;

    final tmdbResults = results[0] as List<dynamic>;
    final addonMap = results[1] as Map<String, List<Map<String, dynamic>>>;

    setState(() {
      _tmdbMovies = tmdbResults.where((r) => r['media_type'] == 'movie').toList();
      _tmdbShows = tmdbResults.where((r) => r['media_type'] == 'tv').toList();
      _addonResults = addonMap;
      _isSearching = false;
    });
  }

  bool get _hasResults =>
      _tmdbMovies.isNotEmpty || _tmdbShows.isNotEmpty || _addonResults.isNotEmpty;

  int get _totalResults {
    int count = _tmdbMovies.length + _tmdbShows.length;
    for (final v in _addonResults.values) {
      count += v.length;
    }
    return count;
  }

  void _openTmdbItem(Map<String, dynamic> item) {
    Navigator.pushNamed(context, '/details', arguments: {
      'id': item['id'] as int,
      'media_type': (item['media_type'] ?? 'movie') as String,
    });
  }

  Future<void> _openStremioItem(Map<String, dynamic> item) async {
    final id = item['id']?.toString() ?? '';
    final type = item['type']?.toString() ?? 'movie';
    final name = (item['name'] ?? '') as String;

    // 1. IMDB ID → TMDB lookup
    if (id.startsWith('tt')) {
      final tmdbResult = await TmdbService.findByImdbId(id, mediaType: type == 'series' ? 'tv' : 'movie');
      if (tmdbResult != null && mounted) {
        Navigator.pushNamed(context, '/details', arguments: {
          'id': tmdbResult['id'] as int,
          'media_type': (tmdbResult['media_type'] ?? 'movie') as String,
        });
        return;
      }
    }

    // 2. Name search fallback
    if (name.isNotEmpty) {
      try {
        final results = await TmdbService.searchMulti(name);
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

    // 3. Custom ID — pass the raw Stremio item to details screen
    if (mounted) {
      Navigator.pushNamed(context, '/details', arguments: {
        'id': id.hashCode,
        'media_type': type == 'series' ? 'tv' : 'movie',
        'stremio_item': item,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final allChars = _letters.split('') + _numbers.split('');

    // Build result rows
    final List<Widget> resultRows = [];
    if (_tmdbMovies.isNotEmpty) {
      resultRows.add(_SearchResultRow(
        title: 'TMDB Movies',
        items: _tmdbMovies,
        isTmdb: true,
        onItemSelected: (item) => _openTmdbItem(item as Map<String, dynamic>),
      ));
    }
    if (_tmdbShows.isNotEmpty) {
      resultRows.add(_SearchResultRow(
        title: 'TMDB Shows',
        items: _tmdbShows,
        isTmdb: true,
        onItemSelected: (item) => _openTmdbItem(item as Map<String, dynamic>),
      ));
    }
    for (final entry in _addonResults.entries) {
      final movies = entry.value.where((i) {
        final t = i['type']?.toString() ?? '';
        return t == 'movie' || t == '';
      }).toList();
      final shows = entry.value.where((i) {
        final t = i['type']?.toString() ?? '';
        return t == 'series' || t == 'tv';
      }).toList();

      if (movies.isNotEmpty) {
        resultRows.add(_SearchResultRow(
          title: '${entry.key} — Movies',
          items: movies,
          isTmdb: false,
          onItemSelected: (item) => _openStremioItem(item as Map<String, dynamic>),
        ));
      }
      if (shows.isNotEmpty) {
        resultRows.add(_SearchResultRow(
          title: '${entry.key} — Shows',
          items: shows,
          isTmdb: false,
          onItemSelected: (item) => _openStremioItem(item as Map<String, dynamic>),
        ));
      }
      if (movies.isEmpty && shows.isEmpty && entry.value.isNotEmpty) {
        resultRows.add(_SearchResultRow(
          title: entry.key,
          items: entry.value,
          isTmdb: false,
          onItemSelected: (item) => _openStremioItem(item as Map<String, dynamic>),
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left: keyboard grid
          SizedBox(
            width: 280,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Search', style: TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),

                // Query display
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceLight,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.darkPurple, width: 1),
                  ),
                  child: Text(
                    _query.isEmpty ? 'Type to search...' : _query,
                    style: TextStyle(
                      color: _query.isEmpty ? AppColors.textDim : AppColors.textPrimary,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Letter grid
                Expanded(
                  child: GridView.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _gridCols,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                      childAspectRatio: 1.3,
                    ),
                    itemCount: allChars.length + 3,
                    itemBuilder: (context, index) {
                      if (index < allChars.length) {
                        return _KeyButton(
                          label: allChars[index],
                          onSelect: () => _addChar(allChars[index]),
                          autofocus: index == 0,
                        );
                      } else if (index == allChars.length) {
                        return _KeyButton(label: '␣', onSelect: _addSpace, isWide: false);
                      } else if (index == allChars.length + 1) {
                        return _KeyButton(label: '⌫', onSelect: _backspace, isWide: false);
                      } else {
                        return _KeyButton(label: 'CLR', onSelect: _clearQuery, isWide: false);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),

          // Right: result rows
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      !_hasResults && _query.isEmpty
                          ? 'Enter a search term'
                          : _isSearching
                              ? 'Searching...'
                              : '$_totalResults results',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
                    ),
                    if (_isSearching)
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.purpleLight)),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: !_hasResults
                      ? Center(
                          child: Text(
                            _query.isEmpty ? '' : (_isSearching ? '' : 'No results found'),
                            style: const TextStyle(color: AppColors.textDim, fontSize: 14),
                          ),
                        )
                      : ListView(children: resultRows),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Horizontal result row (slider)
// ═══════════════════════════════════════════════════════════════════════════

class _SearchResultRow extends StatefulWidget {
  final String title;
  final List<dynamic> items;
  final bool isTmdb;
  final ValueChanged<dynamic> onItemSelected;

  const _SearchResultRow({
    required this.title,
    required this.items,
    required this.isTmdb,
    required this.onItemSelected,
  });

  @override
  State<_SearchResultRow> createState() => _SearchResultRowState();
}

class _SearchResultRowState extends State<_SearchResultRow> {
  final ScrollController _scrollController = ScrollController();

  void _scrollToIndex(int index) {
    const itemWidth = 142.0;
    final offset = index * itemWidth;
    _scrollController.animateTo(
      (offset - 100).clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
          child: Text(
            widget.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
        SizedBox(
          height: 200,
          child: ListView.builder(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            itemCount: widget.items.length,
            itemBuilder: (context, index) {
              final item = widget.items[index];
              if (widget.isTmdb) {
                return _TmdbResultCard(
                  item: item as Map<String, dynamic>,
                  onFocused: () => _scrollToIndex(index),
                  onSelect: () => widget.onItemSelected(item),
                );
              } else {
                return _StremioResultCard(
                  item: item as Map<String, dynamic>,
                  onFocused: () => _scrollToIndex(index),
                  onSelect: () => widget.onItemSelected(item),
                );
              }
            },
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Keyboard Key Button
// ═══════════════════════════════════════════════════════════════════════════

class _KeyButton extends StatefulWidget {
  final String label;
  final VoidCallback onSelect;
  final bool isWide;
  final bool autofocus;

  const _KeyButton({
    required this.label,
    required this.onSelect,
    this.isWide = false,
    this.autofocus = false,
  });

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onSelect,
      child: DpadFocusable(
      autofocus: widget.autofocus,
      region: 'keyboard',
      onFocus: () => setState(() => _focused = true),
      onBlur: () => setState(() => _focused = false),
      onSelect: widget.onSelect,
      builder: (context, isFocused, child) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _focused ? AppColors.purple : AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: _focused ? AppColors.purpleLight : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
              fontSize: 15,
              fontWeight: _focused ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        );
      },
      child: const SizedBox.shrink(),
    ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  TMDB Result Card (poster from TMDB image API)
// ═══════════════════════════════════════════════════════════════════════════

class _TmdbResultCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final VoidCallback onFocused;
  final VoidCallback onSelect;

  const _TmdbResultCard({required this.item, required this.onFocused, required this.onSelect});

  @override
  State<_TmdbResultCard> createState() => _TmdbResultCardState();
}

class _TmdbResultCardState extends State<_TmdbResultCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final posterPath = widget.item['poster_path'] as String?;
    final title = (widget.item['title'] ?? widget.item['name'] ?? '') as String;
    final type = (widget.item['media_type'] ?? 'movie') as String;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: RepaintBoundary(
      child: GestureDetector(
        onTap: widget.onSelect,
        child: DpadFocusable(
          region: 'results',
          onFocus: () {
            setState(() => _focused = true);
            widget.onFocused();
          },
          onBlur: () => setState(() => _focused = false),
          onSelect: widget.onSelect,
          builder: (context, isFocused, child) {
            return AnimatedScale(
              scale: _focused ? 1.08 : 1.0,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              child: SizedBox(
                width: 120,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _focused ? AppColors.purpleLight : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: posterPath != null && posterPath.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: TmdbApi.posterUrl(posterPath),
                                  fit: BoxFit.cover,
                                  memCacheWidth: 240,
                                  placeholder: (_, __) => Container(color: AppColors.cardBg),
                                  errorWidget: (_, __, ___) => Container(
                                    color: AppColors.cardBg,
                                    child: const Icon(Icons.movie, color: AppColors.textDim),
                                  ),
                                )
                              : Container(color: AppColors.cardBg, child: const Icon(Icons.movie, color: AppColors.textDim)),
                        ),
                        Container(
                          color: _focused ? AppColors.darkPurple : AppColors.cardBg,
                          padding: const EdgeInsets.all(6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: TextStyle(
                                  color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                                  fontSize: 11,
                                  fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                type == 'tv' ? 'TV Show' : 'Movie',
                                style: const TextStyle(color: AppColors.textDim, fontSize: 9),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
          child: const SizedBox.shrink(),
        ),
      ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Stremio Result Card (poster from addon URL)
// ═══════════════════════════════════════════════════════════════════════════

class _StremioResultCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final VoidCallback onFocused;
  final VoidCallback onSelect;

  const _StremioResultCard({required this.item, required this.onFocused, required this.onSelect});

  @override
  State<_StremioResultCard> createState() => _StremioResultCardState();
}

class _StremioResultCardState extends State<_StremioResultCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final poster = (widget.item['poster'] ?? '') as String;
    final title = (widget.item['name'] ?? '') as String;
    final type = (widget.item['type'] ?? '') as String;
    final rating = widget.item['imdbRating']?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: RepaintBoundary(
      child: GestureDetector(
        onTap: widget.onSelect,
        child: DpadFocusable(
          region: 'results',
          onFocus: () {
            setState(() => _focused = true);
            widget.onFocused();
          },
          onBlur: () => setState(() => _focused = false),
          onSelect: widget.onSelect,
          builder: (context, isFocused, child) {
            return AnimatedScale(
              scale: _focused ? 1.08 : 1.0,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              child: SizedBox(
                width: 120,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _focused ? AppColors.purpleLight : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: Stack(
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: poster.isNotEmpty
                                  ? CachedNetworkImage(
                                      imageUrl: poster,
                                      fit: BoxFit.cover,
                                      memCacheWidth: 240,
                                      placeholder: (_, __) => Container(color: AppColors.cardBg),
                                      errorWidget: (_, __, ___) => Container(
                                        color: AppColors.cardBg,
                                        child: const Icon(Icons.movie, color: AppColors.textDim),
                                      ),
                                    )
                                  : Container(color: AppColors.cardBg, child: const Icon(Icons.movie, color: AppColors.textDim)),
                            ),
                            Container(
                              color: _focused ? AppColors.darkPurple : AppColors.cardBg,
                              padding: const EdgeInsets.all(6),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: TextStyle(
                                      color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                                      fontSize: 11,
                                      fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    type == 'series' ? 'TV Show' : (type.isNotEmpty ? type[0].toUpperCase() + type.substring(1) : ''),
                                    style: const TextStyle(color: AppColors.textDim, fontSize: 9),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        // Rating badge
                        if (rating.isNotEmpty)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.75),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.star_rounded, color: Colors.amber.shade400, size: 10),
                                  const SizedBox(width: 2),
                                  Text(rating, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
          child: const SizedBox.shrink(),
        ),
      ),
      ),
    );
  }
}
