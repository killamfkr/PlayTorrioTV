import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dpad/dpad.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants.dart';
import '../services/audiobook_service.dart';
import '../services/audiobook_player_service.dart';

class AudiobookPlayerScreen extends StatefulWidget {
  final Audiobook audiobook;
  final List<AudiobookChapter> chapters;
  final int initialChapterIndex;
  final Duration? initialPosition;

  const AudiobookPlayerScreen({
    super.key,
    required this.audiobook,
    required this.chapters,
    this.initialChapterIndex = 0,
    this.initialPosition,
  });

  @override
  State<AudiobookPlayerScreen> createState() => _AudiobookPlayerScreenState();
}

class _AudiobookPlayerScreenState extends State<AudiobookPlayerScreen> {
  final _service = AudiobookPlayerService();
  double _playbackSpeed = 1.0;
  bool _isLiked = false;
  final ScrollController _chapterScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _service.loadBook(
      widget.audiobook,
      widget.chapters,
      initialChapter: widget.initialChapterIndex,
      resumePosition: widget.initialPosition,
    );
    _checkLiked();
  }

  Future<void> _checkLiked() async {
    final liked = await _service.isBookLiked(widget.audiobook.audioBookId);
    if (mounted) setState(() => _isLiked = liked);
  }

  Future<void> _toggleLike() async {
    await _service.toggleLikeBook(widget.audiobook);
    await _checkLiked();
  }

  void _changeChapter(int index) async {
    await _service.changeChapter(index);
    _scrollToChapter(index);
  }

  void _scrollToChapter(int index) {
    final offset = index * 56.0;
    if (_chapterScrollController.hasClients) {
      _chapterScrollController.animateTo(
        (offset - 100).clamp(0, _chapterScrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _handleExit() async {
    await _service.saveManualProgress();
    await _service.stop();
    if (mounted) Navigator.pop(context);
  }

  void _cycleSpeed() {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];
    final currentIdx = speeds.indexOf(_playbackSpeed);
    final nextIdx = (currentIdx + 1) % speeds.length;
    setState(() => _playbackSpeed = speeds[nextIdx]);
    _service.setRate(_playbackSpeed);
  }

  String _formatDuration(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:' : ''}$m:$s';
  }

  @override
  void dispose() {
    _chapterScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleExit();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            // Background cover blur
            Positioned.fill(
              child: CachedNetworkImage(
                imageUrl: widget.audiobook.thumbUrl,
                fit: BoxFit.cover,
                color: Colors.black.withValues(alpha: 0.7),
                colorBlendMode: BlendMode.darken,
                errorWidget: (_, _, _) => Container(color: AppColors.background),
              ),
            ),
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                child: Container(color: Colors.black.withValues(alpha: 0.5)),
              ),
            ),

            // Main content - horizontal layout for TV
            SafeArea(
              child: Row(
                children: [
                  // Left panel: cover + info + controls (clipped so nothing overflows)
                  Expanded(
                    flex: 38,
                    child: ClipRect(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            // Top bar
                            FittedBox(fit: BoxFit.scaleDown, child: _buildTopBar()),
                            const SizedBox(height: 16),
                            // Cover art
                            Expanded(
                              child: Center(
                                child: _buildCoverArt(),
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Title + chapter info
                            _buildTitleInfo(),
                            const SizedBox(height: 16),
                            // Progress slider
                            _buildProgressBar(),
                            const SizedBox(height: 14),
                            // Playback controls
                            FittedBox(fit: BoxFit.scaleDown, child: _buildControls()),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Right panel: chapter list
                  Expanded(
                    flex: 62,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 24, 24, 24),
                      child: _buildChapterList(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _PlayerActionButton(
          icon: Icons.arrow_back_rounded,
          label: 'Back',
          onSelect: _handleExit,
          autofocus: false,
        ),
        const Text(
          'AUDIOBOOK PLAYER',
          style: TextStyle(
            color: AppColors.textDim,
            letterSpacing: 2,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        _PlayerActionButton(
          icon: _isLiked ? Icons.favorite : Icons.favorite_border,
          label: _isLiked ? 'Liked' : 'Like',
          onSelect: _toggleLike,
        ),
        const SizedBox(width: 8),
        _PlayerActionButton(
          icon: Icons.speed_rounded,
          label: '${_playbackSpeed}x',
          onSelect: _cycleSpeed,
        ),
      ],
    );
  }

  Widget _buildCoverArt() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220, maxHeight: 220),
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 30, spreadRadius: 5),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: CachedNetworkImage(
              imageUrl: widget.audiobook.thumbUrl,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => CachedNetworkImage(
                imageUrl: widget.audiobook.coverImage,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => Container(
                  color: AppColors.cardBg,
                  child: const Icon(Icons.headphones, color: AppColors.textDim, size: 64),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitleInfo() {
    return ValueListenableBuilder<int>(
      valueListenable: _service.currentChapterIndex,
      builder: (context, chapterIndex, _) {
        return Column(
          children: [
            Text(
              widget.audiobook.title,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            Text(
              'Chapter ${chapterIndex + 1}: ${widget.chapters[chapterIndex].title}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        );
      },
    );
  }

  Widget _buildProgressBar() {
    return ValueListenableBuilder<Duration>(
      valueListenable: _service.position,
      builder: (context, pos, _) {
        return ValueListenableBuilder<Duration>(
          valueListenable: _service.duration,
          builder: (context, dur, _) {
            final dValue = dur.inMilliseconds.toDouble();
            final pValue = pos.inMilliseconds.toDouble().clamp(0.0, dValue > 0 ? dValue : 1.0);

            return Column(
              children: [
                // D-pad focusable slider
                _DpadSlider(
                  value: pValue,
                  max: dValue > 0 ? dValue : 1.0,
                  onChanged: (v) => _service.seek(Duration(milliseconds: v.toInt())),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_formatDuration(pos), style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                      Text(_formatDuration(dur), style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Autoplay toggle
        ValueListenableBuilder<bool>(
          valueListenable: _service.autoplay,
          builder: (context, auto, _) {
            return _PlayerActionButton(
              icon: auto ? Icons.repeat_on_rounded : Icons.repeat_rounded,
              label: 'Auto',
              onSelect: () => _service.autoplay.value = !auto,
              isActive: auto,
            );
          },
        ),
        const SizedBox(width: 10),

        // Previous chapter
        ValueListenableBuilder<int>(
          valueListenable: _service.currentChapterIndex,
          builder: (context, index, _) {
            return _PlayerActionButton(
              icon: Icons.skip_previous_rounded,
              label: '',
              size: 32,
              onSelect: index > 0 ? () => _changeChapter(index - 1) : null,
            );
          },
        ),
        const SizedBox(width: 10),

        // Seek backward 15s
        _PlayerActionButton(
          icon: Icons.replay_10_rounded,
          label: '',
          size: 28,
          onSelect: () {
            final newPos = _service.position.value - const Duration(seconds: 15);
            _service.seek(newPos < Duration.zero ? Duration.zero : newPos);
          },
        ),
        const SizedBox(width: 8),

        // Play/Pause
        ValueListenableBuilder<bool>(
          valueListenable: _service.isBuffering,
          builder: (context, buffering, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: _service.isPlaying,
              builder: (context, playing, _) {
                if (buffering && !playing) {
                  return Container(
                    width: 56,
                    height: 56,
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(strokeWidth: 3, color: Colors.black),
                    ),
                  );
                }
                return _PlayPauseButton(
                  isPlaying: playing,
                  onSelect: () => _service.playOrPause(),
                );
              },
            );
          },
        ),
        const SizedBox(width: 8),

        // Seek forward 15s
        _PlayerActionButton(
          icon: Icons.forward_10_rounded,
          label: '',
          size: 28,
          onSelect: () {
            final newPos = _service.position.value + const Duration(seconds: 15);
            final maxDur = _service.duration.value;
            _service.seek(newPos > maxDur && maxDur > Duration.zero ? maxDur : newPos);
          },
        ),
        const SizedBox(width: 10),

        // Next chapter
        ValueListenableBuilder<int>(
          valueListenable: _service.currentChapterIndex,
          builder: (context, index, _) {
            return _PlayerActionButton(
              icon: Icons.skip_next_rounded,
              label: '',
              size: 32,
              onSelect: index < widget.chapters.length - 1 ? () => _changeChapter(index + 1) : null,
            );
          },
        ),
      ],
    );
  }

  Widget _buildChapterList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.list_rounded, color: AppColors.textDim, size: 18),
            const SizedBox(width: 6),
            Text(
              'CHAPTERS (${widget.chapters.length})',
              style: const TextStyle(
                color: AppColors.textDim,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ValueListenableBuilder<int>(
            valueListenable: _service.currentChapterIndex,
            builder: (context, currentIdx, _) {
              return ListView.builder(
                controller: _chapterScrollController,
                itemCount: widget.chapters.length,
                itemBuilder: (context, index) {
                  final isCurrent = currentIdx == index;
                  return _ChapterTile(
                    index: index,
                    title: widget.chapters[index].title,
                    isCurrent: isCurrent,
                    onSelect: () => _changeChapter(index),
                    onFocused: () => _scrollToChapter(index),
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

// --- Play/Pause button (large, focal) ---

class _PlayPauseButton extends StatefulWidget {
  final bool isPlaying;
  final VoidCallback onSelect;

  const _PlayPauseButton({required this.isPlaying, required this.onSelect});

  @override
  State<_PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<_PlayPauseButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onSelect,
      child: DpadFocusable(
        autofocus: true,
        region: 'player',
        onFocus: () => setState(() => _focused = true),
        onBlur: () => setState(() => _focused = false),
        onSelect: widget.onSelect,
        builder: (context, isFocused, child) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: _focused ? AppColors.purpleLight : Colors.white,
              shape: BoxShape.circle,
              border: Border.all(
                color: _focused ? AppColors.purpleLight : Colors.transparent,
                width: 3,
              ),
              boxShadow: _focused
                  ? [BoxShadow(color: Colors.white.withValues(alpha: 0.3), blurRadius: 16, spreadRadius: 2)]
                  : [],
            ),
            child: Icon(
              widget.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.black,
              size: 34,
            ),
          );
        },
        child: const SizedBox.shrink(),
      ),
    );
  }
}

// --- Generic player action button ---

class _PlayerActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onSelect;
  final double size;
  final bool isActive;
  final bool autofocus;

  const _PlayerActionButton({
    required this.icon,
    required this.label,
    this.onSelect,
    this.size = 24,
    this.isActive = false,
    this.autofocus = false,
  });

  @override
  State<_PlayerActionButton> createState() => _PlayerActionButtonState();
}

class _PlayerActionButtonState extends State<_PlayerActionButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onSelect != null;
    return GestureDetector(
      onTap: widget.onSelect,
      child: DpadFocusable(
        autofocus: widget.autofocus,
        region: 'player',
        onFocus: () => setState(() => _focused = true),
        onBlur: () => setState(() => _focused = false),
        onSelect: widget.onSelect ?? () {},
        builder: (context, isFocused, child) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: EdgeInsets.all(widget.label.isEmpty ? 8 : 10),
            decoration: BoxDecoration(
              color: _focused
                  ? AppColors.darkPurple.withValues(alpha: 0.8)
                  : widget.isActive
                      ? AppColors.darkPurple.withValues(alpha: 0.4)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(widget.label.isEmpty ? 24 : 8),
              border: Border.all(
                color: _focused ? AppColors.purpleLight : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.icon,
                  color: enabled
                      ? (_focused ? AppColors.purpleLight : (widget.isActive ? AppColors.purpleLight : Colors.white))
                      : AppColors.textDim,
                  size: widget.size,
                ),
                if (widget.label.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
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

// --- D-pad compatible slider ---

class _DpadSlider extends StatefulWidget {
  final double value;
  final double max;
  final ValueChanged<double> onChanged;

  const _DpadSlider({required this.value, required this.max, required this.onChanged});

  @override
  State<_DpadSlider> createState() => _DpadSliderState();
}

class _DpadSliderState extends State<_DpadSlider> {
  bool _focused = false;
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      final step = widget.max * 0.02;
      widget.onChanged((widget.value - step).clamp(0, widget.max));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      final step = widget.max * 0.02;
      widget.onChanged((widget.value + step).clamp(0, widget.max));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final fraction = widget.max > 0 ? (widget.value / widget.max).clamp(0.0, 1.0) : 0.0;

    return GestureDetector(
      onTap: () {},
      child: DpadFocusable(
        region: 'player',
        onFocus: () {
          setState(() => _focused = true);
          _focusNode.requestFocus();
        },
        onBlur: () => setState(() => _focused = false),
        onSelect: () {},
        builder: (context, isFocused, child) {
          return Focus(
            focusNode: _focusNode,
            onKeyEvent: _handleKey,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _focused ? AppColors.purpleLight : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Container(
                        height: 4,
                        width: constraints.maxWidth * fraction,
                        decoration: BoxDecoration(
                          color: _focused ? AppColors.purpleLight : Colors.white,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      if (_focused)
                        Positioned(
                          left: (constraints.maxWidth * fraction - 6).clamp(0, constraints.maxWidth - 12),
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: const BoxDecoration(
                              color: AppColors.purpleLight,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          );
        },
        child: const SizedBox.shrink(),
      ),
    );
  }
}

// --- Chapter tile ---

class _ChapterTile extends StatefulWidget {
  final int index;
  final String title;
  final bool isCurrent;
  final VoidCallback onSelect;
  final VoidCallback onFocused;

  const _ChapterTile({
    required this.index,
    required this.title,
    required this.isCurrent,
    required this.onSelect,
    required this.onFocused,
  });

  @override
  State<_ChapterTile> createState() => _ChapterTileState();
}

class _ChapterTileState extends State<_ChapterTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: GestureDetector(
        onTap: widget.onSelect,
        child: DpadFocusable(
          region: 'chapters',
          onFocus: () {
            setState(() => _focused = true);
            widget.onFocused();
          },
          onBlur: () => setState(() => _focused = false),
          onSelect: widget.onSelect,
          builder: (context, isFocused, child) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: widget.isCurrent
                    ? AppColors.darkPurple.withValues(alpha: 0.6)
                    : _focused
                        ? AppColors.surfaceLight
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _focused ? AppColors.purpleLight : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      '${widget.index + 1}',
                      style: TextStyle(
                        color: widget.isCurrent ? AppColors.purpleLight : AppColors.textDim,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        color: widget.isCurrent
                            ? Colors.white
                            : _focused
                                ? AppColors.textPrimary
                                : AppColors.textSecondary,
                        fontWeight: widget.isCurrent ? FontWeight.w600 : FontWeight.normal,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.isCurrent)
                    const Icon(Icons.graphic_eq_rounded, color: AppColors.purpleLight, size: 18),
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
