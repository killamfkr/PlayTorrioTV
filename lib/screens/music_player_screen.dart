import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dpad/dpad.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants.dart';
import '../services/music_service.dart';
import '../services/music_player_service.dart';

class MusicPlayerScreen extends StatefulWidget {
  final MusicTrack track;
  final List<MusicTrack> playlist;

  const MusicPlayerScreen({
    super.key,
    required this.track,
    required this.playlist,
  });

  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends State<MusicPlayerScreen> {
  final _service = MusicPlayerService();
  double _playbackSpeed = 1.0;
  bool _isLiked = false;
  final ScrollController _queueScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _service.init();
    _service.playTrack(widget.track, newPlaylist: widget.playlist);
    _checkLiked();
  }

  Future<void> _checkLiked() async {
    final liked = await _service.isTrackLiked(widget.track.id);
    if (mounted) setState(() => _isLiked = liked);
  }

  Future<void> _toggleLike() async {
    final track = _service.currentTrack.value;
    if (track == null) return;
    await _service.toggleLikeTrack(track);
    final liked = await _service.isTrackLiked(track.id);
    if (mounted) setState(() => _isLiked = liked);
  }

  void _playFromQueue(int index) {
    if (index >= 0 && index < widget.playlist.length) {
      _service.playTrack(widget.playlist[index]);
      _scrollToTrack(index);
      _recheckLike();
    }
  }

  void _recheckLike() async {
    // Delay slightly to let currentTrack update
    await Future.delayed(const Duration(milliseconds: 100));
    final track = _service.currentTrack.value;
    if (track != null && mounted) {
      final liked = await _service.isTrackLiked(track.id);
      setState(() => _isLiked = liked);
    }
  }

  void _scrollToTrack(int index) {
    final offset = index * 56.0;
    if (_queueScrollController.hasClients) {
      _queueScrollController.animateTo(
        (offset - 100).clamp(0, _queueScrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _handleExit() async {
    await _service.stop();
    if (mounted) Navigator.pop(context);
  }

  void _cycleSpeed() {
    const speeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
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

  Future<void> _addToPlaylist() async {
    final track = _service.currentTrack.value;
    if (track == null) return;
    final playlists = await _service.getPlaylists();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Add to Playlist', style: TextStyle(color: AppColors.textPrimary)),
          content: SizedBox(
            width: 300,
            child: playlists.isEmpty
                ? const Text('No playlists yet. Create one first.', style: TextStyle(color: AppColors.textDim))
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ...playlists.map((pl) {
                        return ListTile(
                          leading: const Icon(Icons.playlist_play, color: AppColors.textSecondary),
                          title: Text(pl.name, style: const TextStyle(color: AppColors.textPrimary)),
                          subtitle: Text('${pl.tracks.length} tracks', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                          onTap: () async {
                            await _service.addTrackToPlaylist(pl.name, track);
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Added to ${pl.name}'), duration: const Duration(seconds: 1)),
                              );
                            }
                          },
                        );
                      }),
                      const Divider(color: AppColors.darkPurple),
                      ListTile(
                        leading: const Icon(Icons.add, color: AppColors.purpleLight),
                        title: const Text('New Playlist', style: TextStyle(color: AppColors.purpleLight)),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showCreatePlaylistDialog(track);
                        },
                      ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
            ),
          ],
        );
      },
    );
  }

  void _showCreatePlaylistDialog(MusicTrack track) async {
    final name = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _DpadNameEntryScreen(title: 'New Playlist')),
    );
    if (name != null && name.trim().isNotEmpty) {
      await _service.createPlaylist(name.trim());
      await _service.addTrackToPlaylist(name.trim(), track);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Created "${name.trim()}" and added track'), duration: const Duration(seconds: 1)),
        );
      }
    }
  }

  @override
  void dispose() {
    _queueScrollController.dispose();
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
              child: ValueListenableBuilder<MusicTrack?>(
                valueListenable: _service.currentTrack,
                builder: (context, track, _) {
                  final coverUrl = track?.cover ?? widget.track.cover;
                  return coverUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: coverUrl,
                          fit: BoxFit.cover,
                          color: Colors.black.withValues(alpha: 0.7),
                          colorBlendMode: BlendMode.darken,
                          errorWidget: (_, __, ___) => Container(color: AppColors.background),
                        )
                      : Container(color: AppColors.background);
                },
              ),
            ),
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                child: Container(color: Colors.black.withValues(alpha: 0.5)),
              ),
            ),

            // Main content
            SafeArea(
              child: Row(
                children: [
                  // Left panel: cover + info + controls
                  Expanded(
                    flex: 38,
                    child: ClipRect(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            FittedBox(fit: BoxFit.scaleDown, child: _buildTopBar()),
                            const SizedBox(height: 16),
                            Expanded(child: Center(child: _buildCoverArt())),
                            const SizedBox(height: 12),
                            _buildTrackInfo(),
                            const SizedBox(height: 16),
                            _buildProgressBar(),
                            const SizedBox(height: 14),
                            FittedBox(fit: BoxFit.scaleDown, child: _buildControls()),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Right panel: queue
                  Expanded(
                    flex: 62,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 24, 24, 24),
                      child: _buildQueueList(),
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
          'MUSIC PLAYER',
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
          icon: Icons.playlist_add_rounded,
          label: 'Playlist',
          onSelect: _addToPlaylist,
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
    return ValueListenableBuilder<MusicTrack?>(
      valueListenable: _service.currentTrack,
      builder: (context, track, _) {
        final coverUrl = track?.cover ?? widget.track.cover;
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
                child: coverUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: coverUrl,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                          color: AppColors.cardBg,
                          child: const Icon(Icons.music_note, color: AppColors.textDim, size: 64),
                        ),
                      )
                    : Container(
                        color: AppColors.cardBg,
                        child: const Icon(Icons.music_note, color: AppColors.textDim, size: 64),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTrackInfo() {
    return ValueListenableBuilder<MusicTrack?>(
      valueListenable: _service.currentTrack,
      builder: (context, track, _) {
        return Column(
          children: [
            Text(
              track?.title ?? widget.track.title,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            Text(
              track?.artist ?? widget.track.artist,
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
        // Shuffle toggle
        ValueListenableBuilder<bool>(
          valueListenable: _service.isShuffleEnabled,
          builder: (context, shuffle, _) {
            return _PlayerActionButton(
              icon: Icons.shuffle_rounded,
              label: '',
              onSelect: () => _service.toggleShuffle(),
              isActive: shuffle,
            );
          },
        ),
        const SizedBox(width: 10),

        // Previous track
        _PlayerActionButton(
          icon: Icons.skip_previous_rounded,
          label: '',
          size: 32,
          onSelect: () {
            _service.previous();
            _recheckLike();
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
                  onSelect: () => _service.togglePlay(),
                );
              },
            );
          },
        ),
        const SizedBox(width: 8),

        // Next track
        _PlayerActionButton(
          icon: Icons.skip_next_rounded,
          label: '',
          size: 32,
          onSelect: () {
            _service.next();
            _recheckLike();
          },
        ),
        const SizedBox(width: 10),

        // Loop toggle
        ValueListenableBuilder<int>(
          valueListenable: _service.loopMode,
          builder: (context, mode, _) {
            IconData icon;
            switch (mode) {
              case 1:
                icon = Icons.repeat_on_rounded;
                break;
              case 2:
                icon = Icons.repeat_one_on_rounded;
                break;
              default:
                icon = Icons.repeat_rounded;
            }
            return _PlayerActionButton(
              icon: icon,
              label: '',
              onSelect: () => _service.cycleLoop(),
              isActive: mode > 0,
            );
          },
        ),
      ],
    );
  }

  Widget _buildQueueList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.queue_music_rounded, color: AppColors.textDim, size: 18),
            const SizedBox(width: 6),
            Text(
              'QUEUE (${widget.playlist.length})',
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
          child: ValueListenableBuilder<MusicTrack?>(
            valueListenable: _service.currentTrack,
            builder: (context, currentTrack, _) {
              return ListView.builder(
                controller: _queueScrollController,
                itemCount: widget.playlist.length,
                itemBuilder: (context, index) {
                  final track = widget.playlist[index];
                  final isCurrent = currentTrack?.id == track.id;
                  return _QueueTile(
                    index: index,
                    track: track,
                    isCurrent: isCurrent,
                    onSelect: () => _playFromQueue(index),
                    onFocused: () => _scrollToTrack(index),
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

// --- Play/Pause button ---

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
        region: 'music_player',
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
        region: 'music_player',
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
        region: 'music_player',
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

// --- Queue track tile ---

class _QueueTile extends StatefulWidget {
  final int index;
  final MusicTrack track;
  final bool isCurrent;
  final VoidCallback onSelect;
  final VoidCallback onFocused;

  const _QueueTile({
    required this.index,
    required this.track,
    required this.isCurrent,
    required this.onSelect,
    required this.onFocused,
  });

  @override
  State<_QueueTile> createState() => _QueueTileState();
}

class _QueueTileState extends State<_QueueTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: GestureDetector(
        onTap: widget.onSelect,
        child: DpadFocusable(
          region: 'music_queue',
          onFocus: () {
            setState(() => _focused = true);
            widget.onFocused();
          },
          onBlur: () => setState(() => _focused = false),
          onSelect: widget.onSelect,
          builder: (context, isFocused, child) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                  // Small album art
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: widget.track.cover.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: widget.track.cover,
                            width: 36,
                            height: 36,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => Container(
                              width: 36,
                              height: 36,
                              color: AppColors.cardBg,
                              child: const Icon(Icons.music_note, color: AppColors.textDim, size: 16),
                            ),
                          )
                        : Container(
                            width: 36,
                            height: 36,
                            color: AppColors.cardBg,
                            child: const Icon(Icons.music_note, color: AppColors.textDim, size: 16),
                          ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.track.title,
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
                        Text(
                          widget.track.artist,
                          style: const TextStyle(color: AppColors.textDim, fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
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

// --- D-pad keyboard name entry screen ---

class _DpadNameEntryScreen extends StatefulWidget {
  final String title;
  const _DpadNameEntryScreen({required this.title});

  @override
  State<_DpadNameEntryScreen> createState() => _DpadNameEntryScreenState();
}

class _DpadNameEntryScreenState extends State<_DpadNameEntryScreen> {
  String _text = '';
  static const _chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  static const _cols = 6;

  void _addChar(String c) => setState(() => _text += c.toLowerCase());
  void _backspace() {
    if (_text.isNotEmpty) setState(() => _text = _text.substring(0, _text.length - 1));
  }
  void _addSpace() => setState(() => _text += ' ');
  void _clear() => setState(() => _text = '');
  void _submit() {
    if (_text.trim().isNotEmpty) Navigator.pop(context, _text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final allChars = _chars.split('');
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Container(
          width: 420,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.darkPurple, width: 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.title, style: const TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.darkPurple, width: 1),
                ),
                child: Text(
                  _text.isEmpty ? 'Type a name...' : _text,
                  style: TextStyle(
                    color: _text.isEmpty ? AppColors.textDim : AppColors.textPrimary,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _cols,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                  childAspectRatio: 1.4,
                ),
                itemCount: allChars.length + 3,
                itemBuilder: (context, index) {
                  if (index < allChars.length) {
                    return _KbKey(
                      label: allChars[index],
                      onSelect: () => _addChar(allChars[index]),
                      autofocus: index == 0,
                    );
                  } else if (index == allChars.length) {
                    return _KbKey(label: '␣', onSelect: _addSpace);
                  } else if (index == allChars.length + 1) {
                    return _KbKey(label: '⌫', onSelect: _backspace);
                  } else {
                    return _KbKey(label: 'CLR', onSelect: _clear);
                  }
                },
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _KbActionButton(
                      icon: Icons.close_rounded,
                      label: 'Cancel',
                      onSelect: () => Navigator.pop(context),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _KbActionButton(
                      icon: Icons.check_rounded,
                      label: 'Create',
                      isHighlighted: _text.trim().isNotEmpty,
                      onSelect: _submit,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KbKey extends StatefulWidget {
  final String label;
  final VoidCallback onSelect;
  final bool autofocus;
  const _KbKey({required this.label, required this.onSelect, this.autofocus = false});
  @override
  State<_KbKey> createState() => _KbKeyState();
}

class _KbKeyState extends State<_KbKey> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onSelect,
      child: DpadFocusable(
        autofocus: widget.autofocus,
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
              border: Border.all(color: _focused ? AppColors.purpleLight : Colors.transparent, width: 1.5),
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

class _KbActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onSelect;
  final bool isHighlighted;
  const _KbActionButton({required this.icon, required this.label, required this.onSelect, this.isHighlighted = false});
  @override
  State<_KbActionButton> createState() => _KbActionButtonState();
}

class _KbActionButtonState extends State<_KbActionButton> {
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
          return AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: widget.isHighlighted ? AppColors.darkPurple : (_focused ? AppColors.surfaceLight : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _focused ? AppColors.purpleLight : AppColors.darkPurple, width: 1),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(widget.icon, size: 18, color: widget.isHighlighted || _focused ? AppColors.purpleLight : AppColors.textSecondary),
                const SizedBox(width: 6),
                Text(widget.label, style: TextStyle(color: widget.isHighlighted || _focused ? AppColors.textPrimary : AppColors.textSecondary, fontSize: 14)),
              ],
            ),
          );
        },
        child: const SizedBox.shrink(),
      ),
    );
  }
}
