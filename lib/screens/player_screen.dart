import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants.dart';
import '../services/stream_service.dart';
import '../services/player_launcher.dart';
import '../services/settings_service.dart';
import '../services/debrid_service.dart';

class PlayerScreen extends StatefulWidget {
  final String magnetUri;
  final String title;
  final EpisodeTarget? episode;
  final int? tmdbId;
  final String? imdbId;
  final String? backdropPath;
  final String? posterPath;
  final String mediaType;
  final int? fileIdx;
  final int? resumePositionMs;
  final String? logoUrl;

  const PlayerScreen({
    super.key,
    required this.magnetUri,
    required this.title,
    this.episode,
    this.tmdbId,
    this.imdbId,
    this.backdropPath,
    this.posterPath,
    this.mediaType = 'movie',
    this.fileIdx,
    this.resumePositionMs,
    this.logoUrl,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  StreamResult? _streamResult;
  Timer? _statsTimer;
  String? _debridUrl; // set when using debrid instead of torrent engine

  String _status = 'Connecting...';
  bool _isLoading = true;
  bool _hasError = false;
  String _errorMessage = '';
  bool _launched = false;
  double _bufferPct = 0;
  int _downloadSpeed = 0;
  int _peers = 0;

  bool get _usingDebrid => _debridUrl != null;

  String formatSpeed(int bytesPerSec) {
    if (bytesPerSec < 1024) return '$bytesPerSec B/s';
    if (bytesPerSec < 1024 * 1024) return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startStreaming();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _launched) {
      setState(() => _launched = false);
    }
  }

  Future<void> _startStreaming() async {
    // If the "magnet" is actually a direct HTTP URL (e.g. from a Stremio addon),
    // skip debrid/torrent and launch the player directly.
    final uri = widget.magnetUri;
    if (uri.startsWith('http://') || uri.startsWith('https://')) {
      _debridUrl = uri;
      setState(() {
        _status = 'Launching player...';
        _isLoading = false;
      });
      _launchExternalPlayer();
      return;
    }

    final settings = SettingsService.instance;
    final shouldUseDebrid = settings.useDebrid && !settings.streamingMode;

    if (shouldUseDebrid) {
      await _startDebrid();
    } else {
      await _startTorrent();
    }
  }

  Future<void> _startDebrid() async {
    try {
      setState(() => _status = 'Resolving via ${SettingsService.instance.debridProvider}...');

      final url = await DebridService.resolve(widget.magnetUri, episode: widget.episode, fileIdx: widget.fileIdx);
      if (!mounted) return;

      _debridUrl = url;
      setState(() {
        _status = 'Launching player...';
        _isLoading = false;
      });

      _launchExternalPlayer();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _startTorrent() async {
    try {
      setState(() => _status = 'Fetching metadata...');

      final result = await StreamService.startStreaming(
        widget.magnetUri,
        episode: widget.episode,
        fileIdx: widget.fileIdx,
      );

      if (!mounted) return;

      setState(() {
        _streamResult = result;
        _status = 'Launching player...';
        _isLoading = false;
      });

      // Poll TorrServer stats for display
      _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        final stats = await StreamService.getTorrentStats(result.hash);
        if (stats != null && mounted) {
          setState(() {
            _downloadSpeed = (stats.speedMbps * 1024 * 1024).toInt();
            _peers = stats.activePeers;
            _bufferPct = stats.totalBytes > 0 ? stats.loadedBytes / stats.totalBytes : 0;
          });
        }
      });

      _launchExternalPlayer();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }


  Future<void> _launchExternalPlayer() async {
    final url = _debridUrl ?? _streamResult?.url;
    if (url == null) return;
    try {
      await PlayerLauncher.launch(
        url,
        title: widget.title,
        tmdbId: widget.tmdbId,
        imdbId: widget.imdbId,
        season: widget.episode?.season,
        episode: widget.episode?.episode,
        magnet: widget.magnetUri,
        fileIdx: _streamResult?.fileIdx ?? widget.fileIdx,
        backdropPath: widget.backdropPath,
        posterPath: widget.posterPath,
        mediaType: widget.mediaType,
        resumePositionMs: widget.resumePositionMs,
        logoUrl: widget.logoUrl,
      );
      setState(() => _launched = true);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _errorMessage = e.message ?? 'Failed to launch player';
      });
    }
  }

  void _exit() {
    if (!_usingDebrid && _streamResult != null) {
      StreamService.removeTorrent(_streamResult!.hash);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statsTimer?.cancel();
    if (!_usingDebrid && _streamResult != null) {
      StreamService.removeTorrent(_streamResult!.hash);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final backdropUrl = widget.backdropPath != null && widget.backdropPath!.isNotEmpty
        ? (widget.backdropPath!.startsWith('http')
            ? widget.backdropPath!
            : TmdbApi.backdropUrl(widget.backdropPath, size: 'w1280'))
        : null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: KeyboardListener(
          focusNode: FocusNode()..requestFocus(),
          autofocus: true,
          onKeyEvent: (event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter) {
                if (!_isLoading && !_hasError) {
                  _launchExternalPlayer();
                }
              }
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Backdrop
              if (backdropUrl != null)
                CachedNetworkImage(
                  imageUrl: backdropUrl,
                  fit: BoxFit.cover,
                  color: Colors.black.withValues(alpha: 0.55),
                  colorBlendMode: BlendMode.darken,
                  memCacheWidth: 1280,
                ),
              // Gradient overlays
              Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 1.2,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.85),
                    ],
                  ),
                ),
              ),
              // Content
              _hasError ? _buildError() : _buildStreamInfo(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStreamInfo() {
    final hasLogo = widget.logoUrl != null && widget.logoUrl!.isNotEmpty;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Logo or title
          if (hasLogo)
            _PulsingWidget(
              animate: _isLoading,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 80, maxWidth: 350),
                child: CachedNetworkImage(
                  imageUrl: widget.logoUrl!,
                  fit: BoxFit.contain,
                  memCacheWidth: 500,
                  errorWidget: (_, __, ___) => Text(
                    widget.title,
                    style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            _PulsingWidget(
              animate: _isLoading,
              child: Text(
                widget.title,
                style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                textAlign: TextAlign.center,
              ),
            ),

          const SizedBox(height: 32),

          // Status text
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(
              _isLoading ? _status : (_launched ? 'Playing...' : 'Press OK to launch player'),
              key: ValueKey(_status + _launched.toString()),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 14,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3,
              ),
            ),
          ),

          if (_streamResult != null) ...[
            const SizedBox(height: 20),
            SizedBox(
              width: 500,
              child: Text(
                _streamResult!.fileName,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
            if (_isLoading)
              SizedBox(
                width: 260,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: _bufferPct,
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                    minHeight: 3,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              '${formatSpeed(_downloadSpeed)}  ·  $_peers peers  ·  ${formatBytes(_streamResult!.fileSize)}',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.25), fontSize: 12),
            ),
          ],

          const SizedBox(height: 32),
          Text(
            'BACK to return',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.15), fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, color: Colors.red.withValues(alpha: 0.7), size: 48),
          const SizedBox(height: 20),
          const Text(
            'Playback Error',
            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: 400,
            child: Text(
              _errorMessage,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 14),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'BACK to return',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Widget that pulses opacity when [animate] is true (loading indicator).
class _PulsingWidget extends StatefulWidget {
  final Widget child;
  final bool animate;
  const _PulsingWidget({required this.child, required this.animate});
  @override
  State<_PulsingWidget> createState() => _PulsingWidgetState();
}

class _PulsingWidgetState extends State<_PulsingWidget> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 1800), vsync: this);
    _opacity = Tween<double>(begin: 1.0, end: 0.3).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
    if (widget.animate) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_PulsingWidget old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.animate && _ctrl.isAnimating) {
      _ctrl.animateTo(1.0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}
