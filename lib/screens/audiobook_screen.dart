import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dpad/dpad.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants.dart';
import '../services/audiobook_service.dart';
import '../services/audiobook_player_service.dart';
import 'audiobook_player_screen.dart';

class AudiobookScreen extends StatefulWidget {
  const AudiobookScreen({super.key});

  @override
  State<AudiobookScreen> createState() => _AudiobookScreenState();
}

class _AudiobookScreenState extends State<AudiobookScreen> {
  final AudiobookService _service = AudiobookService();
  final AudiobookPlayerService _playerService = AudiobookPlayerService();

  List<Audiobook> _books = [];
  List<Map<String, dynamic>> _history = [];
  List<Audiobook> _likedBooks = [];
  bool _isLoading = true;
  bool _isSearching = false;
  bool _showLiked = false;
  bool _historyEditMode = false;
  int _currentOffset = 0;
  static const _limit = 12;

  // Search keyboard state
  String _query = '';
  Timer? _debounce;
  static const _letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const _numbers = '0123456789';
  static const _gridCols = 6;

  // Focused book for hero display
  Audiobook? _focusedBook;

  @override
  void initState() {
    super.initState();
    _playerService.init();
    _loadBooks();
    _loadHistory();
    _loadLikedBooks();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadBooks() async {
    setState(() => _isLoading = true);
    final books = await _service.getAudiobooks(offset: _currentOffset, limit: _limit);
    if (mounted) {
      setState(() {
        _books = books;
        _isLoading = false;
        _isSearching = false;
        if (_focusedBook == null && books.isNotEmpty) _focusedBook = books[0];
      });
    }
  }

  Future<void> _loadHistory() async {
    final history = await _playerService.getHistory();
    if (mounted) setState(() => _history = history);
  }

  Future<void> _loadLikedBooks() async {
    final liked = await _playerService.getLikedBooks();
    if (mounted) setState(() => _likedBooks = liked);
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
      _isSearching = false;
      _showLiked = false;
    });
    _currentOffset = 0;
    _loadBooks();
  }

  void _triggerSearch() {
    _debounce?.cancel();
    if (_query.trim().isEmpty) {
      setState(() => _isSearching = false);
      _currentOffset = 0;
      _loadBooks();
      return;
    }
    setState(() => _showLiked = false);
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      if (_query.trim().isEmpty) return;
      setState(() {
        _isLoading = true;
        _isSearching = true;
      });
      final results = await _service.searchAudiobooks(_query);
      if (mounted) {
        setState(() {
          _books = results;
          _isLoading = false;
          if (results.isNotEmpty) _focusedBook = results[0];
        });
      }
    });
  }

  void _openAudiobook(Audiobook book, {int initialChapter = 0, Duration? initialPosition}) async {
    // Show loading overlay
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    final chapters = await _service.getChapters(book);

    if (mounted) {
      Navigator.pop(context); // Remove loading
      if (chapters.isNotEmpty) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AudiobookPlayerScreen(
              audiobook: book,
              chapters: chapters,
              initialChapterIndex: initialChapter,
              initialPosition: initialPosition,
            ),
          ),
        );
        // Refresh history on return
        _loadHistory();
        _loadLikedBooks();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load chapters. Book might be restricted.')),
        );
      }
    }
  }

  void _resumeAudiobook(Map<String, dynamic> progress) {
    final book = Audiobook.fromJson(progress['book'] as Map<String, dynamic>);
    _openAudiobook(
      book,
      initialChapter: progress['chapterIndex'] as int,
      initialPosition: Duration(milliseconds: progress['positionMs'] as int),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allChars = _letters.split('') + _numbers.split('');
    final displayBooks = _showLiked ? _likedBooks : _books;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left: keyboard + controls
          SizedBox(
            width: 280,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title row
                Row(
                  children: [
                    const Icon(Icons.headphones_rounded, color: AppColors.purpleLight, size: 22),
                    const SizedBox(width: 8),
                    const Text('Audiobooks', style: TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.bold)),
                  ],
                ),
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
                    _query.isEmpty ? 'Search audiobooks...' : _query,
                    style: TextStyle(
                      color: _query.isEmpty ? AppColors.textDim : AppColors.textPrimary,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // Action buttons row
                Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        icon: _showLiked ? Icons.favorite : Icons.favorite_border,
                        label: 'Liked',
                        isActive: _showLiked,
                        onSelect: () {
                          setState(() {
                            _showLiked = !_showLiked;
                            if (_showLiked) _isSearching = false;
                          });
                          if (_showLiked) _loadLikedBooks();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!_isSearching && !_showLiked) ...[
                      _ActionButton(
                        icon: Icons.arrow_back_ios,
                        label: '',
                        isActive: false,
                        onSelect: _currentOffset > 0
                            ? () {
                                _currentOffset -= _limit;
                                _loadBooks();
                              }
                            : null,
                      ),
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          'P${(_currentOffset / _limit).floor() + 1}',
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                        ),
                      ),
                      const SizedBox(width: 4),
                      _ActionButton(
                        icon: Icons.arrow_forward_ios,
                        label: '',
                        isActive: false,
                        onSelect: () {
                          _currentOffset += _limit;
                          _loadBooks();
                        },
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),

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
                        return _KeyButton(label: '␣', onSelect: _addSpace);
                      } else if (index == allChars.length + 1) {
                        return _KeyButton(label: '⌫', onSelect: _backspace);
                      } else {
                        return _KeyButton(label: 'CLR', onSelect: _clearQuery);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),

          // Right: results
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Status bar
                Row(
                  children: [
                    Text(
                      _showLiked
                          ? '${_likedBooks.length} liked'
                          : _isLoading
                              ? 'Loading...'
                              : '${displayBooks.length} audiobooks',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
                    ),
                    if (_isLoading)
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.purpleLight)),
                      ),
                  ],
                ),
                const SizedBox(height: 8),

                // Continue Listening row
                if (!_isSearching && !_showLiked && _history.isNotEmpty) ...[
                  Row(
                    children: [
                      const Text('CONTINUE LISTENING', style: TextStyle(color: AppColors.textDim, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.5)),
                      if (_historyEditMode)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            '— select to remove',
                            style: TextStyle(color: Colors.red.shade300, fontSize: 11, fontWeight: FontWeight.w500),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 76,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _history.length + 1, // +1 for edit button
                      itemBuilder: (context, index) {
                        // First item: edit/pen button
                        if (index == 0) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: DpadFocusable(
                              region: 'history',
                              onSelect: () => setState(() => _historyEditMode = !_historyEditMode),
                              builder: (context, isFocused, child) {
                                return GestureDetector(
                                  onTap: () => setState(() => _historyEditMode = !_historyEditMode),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 180),
                                    width: 48,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      color: _historyEditMode
                                          ? Colors.red.withValues(alpha: 0.3)
                                          : Colors.white.withValues(alpha: isFocused ? 0.15 : 0.08),
                                      border: Border.all(
                                        color: isFocused ? Colors.white : Colors.transparent,
                                        width: 2,
                                      ),
                                    ),
                                    child: Center(
                                      child: Icon(
                                        _historyEditMode ? Icons.close : Icons.edit,
                                        color: _historyEditMode ? Colors.red.shade300 : Colors.white70,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                                );
                              },
                              child: const SizedBox.shrink(),
                            ),
                          );
                        }

                        final progress = _history[index - 1];
                        final book = Audiobook.fromJson(progress['book'] as Map<String, dynamic>);
                        return _HistoryCard(
                          book: book,
                          chapterIndex: progress['chapterIndex'] as int,
                          editMode: _historyEditMode,
                          onSelect: _historyEditMode
                              ? () async {
                                  await _playerService.removeFromHistory(book.audioBookId);
                                  _loadHistory();
                                  // Exit edit mode if no more items
                                  if (_history.length <= 1) {
                                    setState(() => _historyEditMode = false);
                                  }
                                }
                              : () => _resumeAudiobook(progress),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                ],

                // Book grid
                Expanded(
                  child: _isLoading && displayBooks.isEmpty
                      ? const Center(child: CircularProgressIndicator(color: AppColors.purpleLight))
                      : displayBooks.isEmpty
                          ? Center(
                              child: Text(
                                _showLiked ? 'No liked audiobooks yet' : (_isSearching ? 'No results' : ''),
                                style: const TextStyle(color: AppColors.textDim, fontSize: 14),
                              ),
                            )
                          : GridView.builder(
                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 4,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                                childAspectRatio: 0.65,
                              ),
                              itemCount: displayBooks.length,
                              itemBuilder: (context, index) {
                                final book = displayBooks[index];
                                final isLiked = _likedBooks.any((b) => b.audioBookId == book.audioBookId);
                                return _AudiobookCard(
                                  book: book,
                                  isLiked: isLiked,
                                  onFocused: () => _focusedBook = book,
                                  onSelect: () => _openAudiobook(book),
                                  onToggleLike: () async {
                                    await _playerService.toggleLikeBook(book);
                                    _loadLikedBooks();
                                  },
                                );
                              },
                            ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Keyboard key button (matching TV app search style) ---

class _KeyButton extends StatefulWidget {
  final String label;
  final VoidCallback onSelect;
  final bool autofocus;

  const _KeyButton({required this.label, required this.onSelect, this.autofocus = false});

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

// --- Action button (liked, pagination) ---

class _ActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback? onSelect;

  const _ActionButton({required this.icon, required this.label, required this.isActive, this.onSelect});

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onSelect,
      child: DpadFocusable(
        region: 'controls',
        onFocus: () => setState(() => _focused = true),
        onBlur: () => setState(() => _focused = false),
        onSelect: widget.onSelect ?? () {},
        builder: (context, isFocused, child) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: widget.isActive
                  ? AppColors.darkPurple
                  : _focused
                      ? AppColors.surfaceLight
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _focused ? AppColors.purpleLight : AppColors.darkPurple,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 16, color: widget.isActive || _focused ? AppColors.purpleLight : AppColors.textSecondary),
                if (widget.label.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: widget.isActive || _focused ? AppColors.textPrimary : AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
        child: const SizedBox.shrink(),
      ),
    );
  }
}

// --- Continue Listening card ---

class _HistoryCard extends StatefulWidget {
  final Audiobook book;
  final int chapterIndex;
  final bool editMode;
  final VoidCallback onSelect;

  const _HistoryCard({required this.book, required this.chapterIndex, required this.onSelect, this.editMode = false});

  @override
  State<_HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends State<_HistoryCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: GestureDetector(
        onTap: widget.onSelect,
        child: DpadFocusable(
          region: 'history',
          onFocus: () => setState(() => _focused = true),
          onBlur: () => setState(() => _focused = false),
          onSelect: widget.onSelect,
          builder: (context, isFocused, child) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 260,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: widget.editMode
                    ? Colors.red.withValues(alpha: _focused ? 0.3 : 0.15)
                    : _focused
                        ? AppColors.darkPurple
                        : AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: widget.editMode
                      ? (_focused ? Colors.red.shade300 : Colors.red.withValues(alpha: 0.4))
                      : _focused
                          ? AppColors.purpleLight
                          : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  if (widget.editMode)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(
                        Icons.delete_outline,
                        color: _focused ? Colors.red.shade300 : Colors.red.withValues(alpha: 0.6),
                        size: 24,
                      ),
                    )
                  else
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CachedNetworkImage(
                        imageUrl: widget.book.thumbUrl,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                          width: 48,
                          height: 48,
                          color: AppColors.cardBg,
                          child: const Icon(Icons.headphones, color: AppColors.textDim, size: 20),
                        ),
                      ),
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.book.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: widget.editMode
                                ? (_focused ? Colors.red.shade300 : AppColors.textSecondary)
                                : (_focused ? AppColors.textPrimary : AppColors.textSecondary),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.editMode ? 'Tap to remove' : 'Chapter ${widget.chapterIndex + 1}',
                          style: TextStyle(
                            color: widget.editMode ? Colors.red.withValues(alpha: 0.5) : AppColors.textDim,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!widget.editMode)
                    Icon(
                      Icons.play_circle_fill_rounded,
                      color: _focused ? AppColors.purpleLight : AppColors.textDim,
                      size: 28,
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

// --- Audiobook card ---

class _AudiobookCard extends StatefulWidget {
  final Audiobook book;
  final bool isLiked;
  final VoidCallback onFocused;
  final VoidCallback onSelect;
  final VoidCallback onToggleLike;

  const _AudiobookCard({required this.book, required this.isLiked, required this.onFocused, required this.onSelect, required this.onToggleLike});

  @override
  State<_AudiobookCard> createState() => _AudiobookCardState();
}

class _AudiobookCardState extends State<_AudiobookCard> with SingleTickerProviderStateMixin {
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
    return GestureDetector(
      onTap: widget.onSelect,
      onLongPress: widget.onToggleLike,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.contextMenu ||
               event.logicalKey == LogicalKeyboardKey.info ||
               event.logicalKey == LogicalKeyboardKey.keyL)) {
            widget.onToggleLike();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: DpadFocusable(
          region: 'books',
          onFocus: () {
            setState(() => _focused = true);
            _scaleCtrl.forward();
          widget.onFocused();
        },
        onBlur: () {
          setState(() => _focused = false);
          _scaleCtrl.reverse();
        },
        onSelect: widget.onSelect,
        builder: (context, isFocused, child) {
          return AnimatedBuilder(
            animation: _scale,
            builder: (context, child) {
              return Transform.scale(
                scale: _scale.value,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _focused ? AppColors.purpleLight : Colors.transparent,
                      width: 2,
                    ),
                    boxShadow: _focused
                        ? [BoxShadow(color: Colors.white.withValues(alpha: 0.1), blurRadius: 12, spreadRadius: 1)]
                        : [],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CachedNetworkImage(
                                imageUrl: widget.book.thumbUrl,
                                fit: BoxFit.cover,
                                placeholder: (_, __) => Container(color: AppColors.cardBg),
                                errorWidget: (_, __, ___) => CachedNetworkImage(
                                  imageUrl: widget.book.coverImage,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, __, ___) => Container(
                                    color: AppColors.cardBg,
                                    child: const Icon(Icons.headphones, color: AppColors.textDim, size: 32),
                                  ),
                                ),
                              ),
                              if (widget.isLiked)
                                Positioned(
                                  top: 6,
                                  right: 6,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.favorite, color: Colors.redAccent, size: 16),
                                  ),
                                ),
                              if (_focused)
                                Positioned(
                                  bottom: 4,
                                  right: 4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      widget.isLiked ? 'L Unlike' : 'L Like',
                                      style: const TextStyle(color: AppColors.textDim, fontSize: 9),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Container(
                          color: _focused ? AppColors.darkPurple : AppColors.cardBg,
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.book.title,
                                style: TextStyle(
                                  color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                                  fontSize: 12,
                                  fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _sourceName(widget.book.source),
                                style: const TextStyle(color: AppColors.textDim, fontSize: 9),
                              ),
                            ],
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
    );
  }

  String _sourceName(String? source) {
    switch (source) {
      case 'tokybook':
        return 'Tokybook';
      case 'audiozaic':
        return 'Audiozaic';
      case 'goldenaudiobook':
        return 'GoldenAudiobook';
      case 'appaudiobooks':
        return 'AppAudiobooks';
      default:
        return '';
    }
  }
}
