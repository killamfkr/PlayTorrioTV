import 'package:flutter/material.dart';
import 'package:dpad/dpad.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants.dart';
import '../services/stremio_addon_service.dart';
import '../services/tmdb_service.dart';

/// TV-optimized Stremio catalog browser with D-pad navigation.
class StremioCatalogScreen extends StatefulWidget {
  const StremioCatalogScreen({super.key});

  @override
  State<StremioCatalogScreen> createState() => _StremioCatalogScreenState();
}

class _StremioCatalogScreenState extends State<StremioCatalogScreen> {
  List<Map<String, dynamic>> _allCatalogs = [];
  Map<String, dynamic>? _selectedCatalog;
  List<Map<String, dynamic>> _items = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int _skip = 0;
  String? _selectedGenre;
  String _filterType = 'all'; // 'all', 'movie', 'series'

  final ScrollController _contentScroll = ScrollController();
  final ScrollController _sidebarScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _contentScroll.addListener(_onContentScroll);
    _loadCatalogs();
  }

  @override
  void dispose() {
    _contentScroll.dispose();
    _sidebarScroll.dispose();
    super.dispose();
  }

  void _onContentScroll() {
    if (_contentScroll.position.pixels >= _contentScroll.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadCatalogs() async {
    final catalogs = StremioAddonService.getAllCatalogs();
    if (!mounted) return;
    setState(() {
      _allCatalogs = catalogs;
      if (catalogs.isNotEmpty) _selectedCatalog = catalogs.first;
      _isLoading = false;
    });
    if (_selectedCatalog != null) _fetchItems();
  }

  List<Map<String, dynamic>> get _filteredCatalogs {
    if (_filterType == 'all') return _allCatalogs;
    return _allCatalogs.where((c) => c['catalogType'] == _filterType).toList();
  }

  Future<void> _fetchItems() async {
    if (_selectedCatalog == null) return;
    setState(() { _isLoading = true; _items = []; _skip = 0; _hasMore = true; });

    final cat = _selectedCatalog!;
    try {
      final results = await StremioAddonService.getCatalog(
        baseUrl: cat['addonBaseUrl'],
        type: cat['catalogType'],
        id: cat['catalogId'],
        genre: _selectedGenre,
      );
      for (final item in results) {
        item['_addonBaseUrl'] = cat['addonBaseUrl'];
        item['_addonName'] = cat['addonName'];
      }
      if (mounted) {
        setState(() {
          _items = results;
          _isLoading = false;
          _hasMore = results.length >= 100;
          _skip = results.length;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore || _selectedCatalog == null) return;
    final cat = _selectedCatalog!;
    if (cat['supportsSkip'] != true) return;

    setState(() => _isLoadingMore = true);
    try {
      final results = await StremioAddonService.getCatalog(
        baseUrl: cat['addonBaseUrl'],
        type: cat['catalogType'],
        id: cat['catalogId'],
        genre: _selectedGenre,
        skip: _skip,
      );
      for (final item in results) {
        item['_addonBaseUrl'] = cat['addonBaseUrl'];
        item['_addonName'] = cat['addonName'];
      }
      if (mounted) {
        setState(() {
          _items.addAll(results);
          _skip += results.length;
          _hasMore = results.length >= 100;
          _isLoadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  void _selectCatalog(Map<String, dynamic> catalog) {
    setState(() {
      _selectedCatalog = catalog;
      _selectedGenre = null;
    });
    _fetchItems();
  }

  void _selectGenre(String? genre) {
    setState(() => _selectedGenre = genre);
    _fetchItems();
  }

  Future<void> _openItem(Map<String, dynamic> item) async {
    final id = item['id']?.toString() ?? '';
    final type = item['type']?.toString() ?? 'movie';
    final name = item['name']?.toString() ?? '';

    // IMDB IDs → resolve via TMDB
    if (id.startsWith('tt')) {
      final tmdb = await TmdbService.findByImdbId(id, mediaType: type == 'series' ? 'tv' : 'movie');
      if (tmdb != null && mounted) {
        Navigator.pushNamed(context, '/details', arguments: {
          'id': tmdb['id'] as int,
          'media_type': (tmdb['media_type'] ?? 'movie') as String,
        });
        return;
      }
    }

    // Name search fallback for non-collections
    if (name.isNotEmpty && type != 'collections') {
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

    // Custom ID / collection → pass raw Stremio item
    if (mounted) {
      if (_selectedCatalog != null) {
        item['_addonBaseUrl'] ??= _selectedCatalog!['addonBaseUrl'];
        item['_addonName'] ??= _selectedCatalog!['addonName'];
      }
      Navigator.pushNamed(context, '/details', arguments: {
        'id': id.hashCode,
        'media_type': type == 'series' ? 'tv' : (type == 'collections' ? 'movie' : 'movie'),
        'stremio_item': item,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_allCatalogs.isEmpty && !_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.extension_off, size: 60, color: Colors.white.withValues(alpha: 0.1)),
            const SizedBox(height: 12),
            const Text('No catalog addons installed', style: TextStyle(color: AppColors.textDim, fontSize: 15)),
            const SizedBox(height: 4),
            const Text('Install Stremio addons in Settings', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
          ],
        ),
      );
    }

    return Row(
      children: [
        // Left sidebar — catalog list
        Container(
          width: 240,
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.8),
            border: Border(right: BorderSide(color: Colors.white.withValues(alpha: 0.06))),
          ),
          child: Column(
            children: [
              _buildTypeFilter(),
              Expanded(child: _buildCatalogList()),
            ],
          ),
        ),
        // Right content — grid of items
        Expanded(child: _buildContentArea()),
      ],
    );
  }

  Widget _buildTypeFilter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
      child: Row(
        children: [
          _FilterBtn(label: 'All', active: _filterType == 'all', onSelect: () => setState(() => _filterType = 'all')),
          const SizedBox(width: 4),
          _FilterBtn(label: 'Movies', active: _filterType == 'movie', onSelect: () => setState(() => _filterType = 'movie')),
          const SizedBox(width: 4),
          _FilterBtn(label: 'Series', active: _filterType == 'series', onSelect: () => setState(() => _filterType = 'series')),
        ],
      ),
    );
  }

  Widget _buildCatalogList() {
    final catalogs = _filteredCatalogs;
    // Group by addon name
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final c in catalogs) {
      final name = c['addonName'] as String;
      grouped.putIfAbsent(name, () => []).add(c);
    }

    final entries = grouped.entries.toList();

    return ListView.builder(
      controller: _sidebarScroll,
      padding: const EdgeInsets.all(6),
      itemCount: entries.length,
      itemBuilder: (context, groupIndex) {
        final entry = entries[groupIndex];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
              child: Text(
                entry.key,
                style: const TextStyle(color: AppColors.textDim, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5),
              ),
            ),
            ...entry.value.map((cat) {
              final isSelected = _selectedCatalog?['catalogId'] == cat['catalogId'] &&
                  _selectedCatalog?['addonBaseUrl'] == cat['addonBaseUrl'];
              return _CatalogButton(
                label: '${cat['catalogName']}',
                type: cat['catalogType'],
                isSelected: isSelected,
                autofocus: groupIndex == 0 && cat == entry.value.first,
                onSelect: () => _selectCatalog(cat),
              );
            }),
          ],
        );
      },
    );
  }

  Widget _buildContentArea() {
    final genres = (_selectedCatalog?['genres'] as List<String>?) ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Genre filter row
        if (genres.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SizedBox(
              height: 34,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: genres.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _GenreChip(
                        label: 'All',
                        active: _selectedGenre == null,
                        onSelect: () => _selectGenre(null),
                      ),
                    );
                  }
                  final genre = genres[index - 1];
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _GenreChip(
                      label: genre,
                      active: _selectedGenre == genre,
                      onSelect: () => _selectGenre(genre),
                    ),
                  );
                },
              ),
            ),
          ),
        const SizedBox(height: 8),
        // Content grid
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator(color: AppColors.purpleLight))
              : _items.isEmpty
                  ? const Center(child: Text('No items', style: TextStyle(color: AppColors.textDim)))
                  : LayoutBuilder(
                    builder: (context, constraints) {
                      final cols = (constraints.maxWidth / 180).floor().clamp(3, 8);
                      return GridView.builder(
                      controller: _contentScroll,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        childAspectRatio: 0.55,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                      ),
                      itemCount: _items.length + (_isLoadingMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == _items.length) {
                          return const Center(child: CircularProgressIndicator(color: AppColors.purpleLight));
                        }
                        final item = _items[index];
                        return _CatalogCard(
                          item: item,
                          onSelect: () => _openItem(item),
                        );
                      },
                    );
                    },
                  ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Sidebar filter buttons
// ═══════════════════════════════════════════════════════════════════════════

class _FilterBtn extends StatefulWidget {
  final String label;
  final bool active;
  final VoidCallback onSelect;

  const _FilterBtn({required this.label, required this.active, required this.onSelect});

  @override
  State<_FilterBtn> createState() => _FilterBtnState();
}

class _FilterBtnState extends State<_FilterBtn> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: widget.onSelect,
        child: DpadFocusable(
          region: 'sidebar',
          onFocus: () => setState(() => _focused = true),
          onBlur: () => setState(() => _focused = false),
          onSelect: widget.onSelect,
          builder: (context, isFocused, child) {
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 7),
              decoration: BoxDecoration(
                color: widget.active ? AppColors.purple.withValues(alpha: 0.2) : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _focused ? AppColors.purpleLight : (widget.active ? AppColors.purple.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.08)),
                  width: _focused ? 1.5 : 1,
                ),
              ),
              child: Text(
                widget.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.active || _focused ? AppColors.textPrimary : AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: widget.active ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            );
          },
          child: const SizedBox.shrink(),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Sidebar catalog button
// ═══════════════════════════════════════════════════════════════════════════

class _CatalogButton extends StatefulWidget {
  final String label;
  final String type;
  final bool isSelected;
  final bool autofocus;
  final VoidCallback onSelect;

  const _CatalogButton({
    required this.label,
    required this.type,
    required this.isSelected,
    this.autofocus = false,
    required this.onSelect,
  });

  @override
  State<_CatalogButton> createState() => _CatalogButtonState();
}

class _CatalogButtonState extends State<_CatalogButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: GestureDetector(
        onTap: widget.onSelect,
        child: DpadFocusable(
          autofocus: widget.autofocus,
          region: 'sidebar',
          onFocus: () => setState(() => _focused = true),
          onBlur: () => setState(() => _focused = false),
          onSelect: widget.onSelect,
          builder: (context, isFocused, child) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: widget.isSelected
                    ? AppColors.purple.withValues(alpha: 0.2)
                    : (_focused ? AppColors.surfaceLight : Colors.transparent),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _focused ? AppColors.purpleLight : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        color: widget.isSelected || _focused ? AppColors.textPrimary : AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight: widget.isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    widget.type == 'series' ? 'TV' : widget.type[0].toUpperCase() + widget.type.substring(1),
                    style: const TextStyle(color: AppColors.textDim, fontSize: 10),
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

// ═══════════════════════════════════════════════════════════════════════════
//  Genre chip
// ═══════════════════════════════════════════════════════════════════════════

class _GenreChip extends StatefulWidget {
  final String label;
  final bool active;
  final VoidCallback onSelect;

  const _GenreChip({required this.label, required this.active, required this.onSelect});

  @override
  State<_GenreChip> createState() => _GenreChipState();
}

class _GenreChipState extends State<_GenreChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onSelect,
      child: DpadFocusable(
        onFocus: () => setState(() => _focused = true),
        onBlur: () => setState(() => _focused = false),
        onSelect: widget.onSelect,
        builder: (context, isFocused, child) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: widget.active ? AppColors.purple.withValues(alpha: 0.25) : Colors.white.withValues(alpha: _focused ? 0.1 : 0.04),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _focused ? AppColors.purpleLight : (widget.active ? AppColors.purple.withValues(alpha: 0.4) : Colors.transparent),
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

// ═══════════════════════════════════════════════════════════════════════════
//  Catalog card
// ═══════════════════════════════════════════════════════════════════════════

class _CatalogCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final VoidCallback onSelect;

  const _CatalogCard({required this.item, required this.onSelect});

  @override
  State<_CatalogCard> createState() => _CatalogCardState();
}

class _CatalogCardState extends State<_CatalogCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final poster = (widget.item['poster'] ?? '') as String;
    final title = (widget.item['name'] ?? '') as String;
    final type = (widget.item['type'] ?? '') as String;
    final rating = widget.item['imdbRating']?.toString() ?? '';

    return RepaintBoundary(
    child: GestureDetector(
      onTap: widget.onSelect,
      child: DpadFocusable(
        region: 'catalog-grid',
        onFocus: () => setState(() => _focused = true),
        onBlur: () => setState(() => _focused = false),
        onSelect: widget.onSelect,
        builder: (context, isFocused, child) {
          return AnimatedScale(
            scale: _focused ? 1.06 : 1.0,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
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
                                  memCacheWidth: 360,
                                  placeholder: (_, _) => Container(color: AppColors.cardBg),
                                  errorWidget: (_, _, _) => Container(
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
          );
        },
        child: const SizedBox.shrink(),
      ),
    ),
    );
  }
}
