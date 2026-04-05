import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dpad/dpad.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants.dart';
import '../services/music_service.dart';
import '../services/music_player_service.dart';
import 'music_player_screen.dart';

// View modes for the music screen
enum _MusicView { main, playlists, playlistDetail, albumDetail }

class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key});

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen> {
  final MusicService _service = MusicService();
  final MusicPlayerService _playerService = MusicPlayerService();

  List<MusicTrack> _tracks = [];
  List<MusicAlbum> _albums = [];
  List<Map<String, dynamic>> _history = [];
  List<MusicTrack> _likedTracks = [];
  List<MusicAlbum> _likedAlbums = [];
  List<MusicPlaylist> _playlists = [];
  bool _isLoading = true;
  bool _isSearching = false;
  bool _showLiked = false;
  bool _historyEditMode = false;
  bool _playlistEditMode = false;
  int _currentOffset = 0;
  static const _limit = 20;

  // View state
  _MusicView _currentView = _MusicView.main;
  MusicPlaylist? _selectedPlaylist;
  MusicAlbum? _selectedAlbum;
  List<MusicTrack> _albumTracks = [];
  bool _isAlbumLiked = false;
  bool _isLoadingAlbum = false;

  // Search keyboard state
  String _query = '';
  Timer? _debounce;
  static const _letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const _numbers = '0123456789';
  static const _gridCols = 6;

  @override
  void initState() {
    super.initState();
    _playerService.init();
    _loadTracks();
    _loadHistory();
    _loadLikedTracks();
    _loadPlaylists();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadTracks() async {
    setState(() => _isLoading = true);
    final tracks = await _service.getTrendingTracks(index: _currentOffset, limit: _limit);
    if (mounted) {
      setState(() {
        _tracks = tracks;
        _isLoading = false;
        _isSearching = false;
      });
    }
  }

  Future<void> _loadHistory() async {
    final history = await _playerService.getHistory();
    if (mounted) setState(() => _history = history);
  }

  Future<void> _loadLikedTracks() async {
    final liked = await _playerService.getLikedSongs();
    if (mounted) setState(() => _likedTracks = liked);
  }

  Future<void> _loadLikedAlbums() async {
    final albums = await _playerService.getLikedAlbums();
    if (mounted) setState(() => _likedAlbums = albums);
  }

  Future<void> _loadPlaylists() async {
    final playlists = await _playerService.getPlaylists();
    if (mounted) setState(() => _playlists = playlists);
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
    _loadTracks();
  }

  void _triggerSearch() {
    _debounce?.cancel();
    if (_query.trim().isEmpty) {
      setState(() {
        _isSearching = false;
        _albums = [];
      });
      _currentOffset = 0;
      _loadTracks();
      return;
    }
    setState(() => _showLiked = false);
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      if (_query.trim().isEmpty) return;
      setState(() {
        _isLoading = true;
        _isSearching = true;
      });
      final results = await Future.wait([
        _service.searchTracks(_query),
        _service.searchAlbums(_query),
      ]);
      if (mounted) {
        setState(() {
          _tracks = results[0] as List<MusicTrack>;
          _albums = results[1] as List<MusicAlbum>;
          _isLoading = false;
        });
      }
    });
  }

  void _playTrack(MusicTrack track, List<MusicTrack> trackList) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MusicPlayerScreen(
          track: track,
          playlist: trackList,
        ),
      ),
    );
    _loadHistory();
    _loadLikedTracks();
    _loadPlaylists();
  }

  void _playAllTracks(List<MusicTrack> tracks) {
    if (tracks.isEmpty) return;
    _playTrack(tracks.first, tracks);
  }

  void _shufflePlayTracks(List<MusicTrack> tracks) {
    if (tracks.isEmpty) return;
    final shuffled = List<MusicTrack>.from(tracks)..shuffle(Random());
    _playTrack(shuffled.first, shuffled);
  }

  void _resumeTrack(Map<String, dynamic> historyEntry) {
    final track = MusicTrack.fromJson(historyEntry['track'] as Map<String, dynamic>);
    _playTrack(track, [track]);
  }

  void _showCreatePlaylistDialog() async {
    final name = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _DpadKeyboardDialog(title: 'New Playlist')),
    );
    if (name != null && name.trim().isNotEmpty) {
      await _playerService.createPlaylist(name.trim());
      _loadPlaylists();
    }
  }

  void _showAddToPlaylistDialog(MusicTrack track) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Add to Playlist', style: TextStyle(color: AppColors.textPrimary)),
          content: SizedBox(
            width: 300,
            child: _playlists.isEmpty
                ? const Text('No playlists yet. Create one first.', style: TextStyle(color: AppColors.textDim))
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ..._playlists.map((pl) {
                        return ListTile(
                          leading: const Icon(Icons.playlist_play, color: AppColors.textSecondary),
                          title: Text(pl.name, style: const TextStyle(color: AppColors.textPrimary)),
                          subtitle: Text('${pl.tracks.length} tracks', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                          onTap: () async {
                            await _playerService.addTrackToPlaylist(pl.name, track);
                            _loadPlaylists();
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
                          _showCreatePlaylistDialog();
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

  void _openPlaylistDetail(MusicPlaylist pl) {
    setState(() {
      _currentView = _MusicView.playlistDetail;
      _selectedPlaylist = pl;
    });
  }

  Future<void> _openAlbum(MusicAlbum album) async {
    setState(() {
      _currentView = _MusicView.albumDetail;
      _selectedAlbum = album;
      _albumTracks = [];
      _isLoadingAlbum = true;
    });
    final liked = await _playerService.isAlbumLiked(album.id);
    final tracks = await _service.getAlbumTracks(album.id);
    // Deezer album track responses don't include album cover, so inject it
    final enriched = tracks.map((t) => MusicTrack(
      id: t.id,
      title: t.title,
      artist: t.artist.isNotEmpty ? t.artist : album.artist,
      album: t.album.isNotEmpty ? t.album : album.title,
      cover: t.cover.isNotEmpty ? t.cover : album.cover,
      duration: t.duration,
    )).toList();
    if (mounted) {
      setState(() {
        _albumTracks = enriched;
        _isAlbumLiked = liked;
        _isLoadingAlbum = false;
      });
    }
  }

  void _goBack() {
    setState(() {
      if (_currentView == _MusicView.playlistDetail) {
        _currentView = _MusicView.playlists;
        _selectedPlaylist = null;
        _loadPlaylists();
      } else if (_currentView == _MusicView.playlists) {
        _currentView = _MusicView.main;
      } else if (_currentView == _MusicView.albumDetail) {
        _currentView = _MusicView.main;
        _selectedAlbum = null;
        _albumTracks = [];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final allChars = _letters.split('') + _numbers.split('');

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
                    const Icon(Icons.music_note_rounded, color: AppColors.purpleLight, size: 22),
                    const SizedBox(width: 8),
                    const Text('Music', style: TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.bold)),
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
                    _query.isEmpty ? 'Search music...' : _query,
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
                        isActive: _showLiked && _currentView == _MusicView.main,
                        onSelect: () {
                          setState(() {
                            _currentView = _MusicView.main;
                            _showLiked = !_showLiked;
                            if (_showLiked) _isSearching = false;
                            _selectedPlaylist = null;
                          });
                          if (_showLiked) {
                            _loadLikedTracks();
                            _loadLikedAlbums();
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.playlist_play_rounded,
                        label: 'Playlists',
                        isActive: _currentView == _MusicView.playlists || _currentView == _MusicView.playlistDetail,
                        onSelect: () {
                          setState(() {
                            _showLiked = false;
                            _currentView = _currentView == _MusicView.playlists ? _MusicView.main : _MusicView.playlists;
                            _selectedPlaylist = null;
                          });
                          _loadPlaylists();
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),

                // Pagination (only in main/trending view)
                if (_currentView == _MusicView.main && !_isSearching && !_showLiked)
                  Row(
                    children: [
                      _ActionButton(
                        icon: Icons.arrow_back_ios,
                        label: '',
                        isActive: false,
                        onSelect: _currentOffset > 0
                            ? () {
                                _currentOffset -= _limit;
                                _loadTracks();
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
                          _loadTracks();
                        },
                      ),
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

          // Right panel: varies by view
          Expanded(
            child: _currentView == _MusicView.playlists
                ? _buildPlaylistsView()
                : _currentView == _MusicView.playlistDetail && _selectedPlaylist != null
                    ? _buildPlaylistDetailView(_selectedPlaylist!)
                    : _currentView == _MusicView.albumDetail && _selectedAlbum != null
                        ? _buildAlbumDetailView(_selectedAlbum!)
                        : _buildMainView(),
          ),
        ],
      ),
    );
  }

  // --- Main browse/search view ---
  Widget _buildMainView() {
    final displayTracks = _showLiked ? _likedTracks : _tracks;

    // When searching, split into Best Match / More Results / Albums
    if (_isSearching && !_isLoading) {
      return _buildSearchResultsView();
    }

    // When showing liked, use dedicated liked view with sliders
    if (_showLiked) {
      return _buildLikedView();
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status bar
          Row(
            children: [
              Text(
                _isLoading
                    ? 'Loading...'
                    : '${displayTracks.length} tracks',
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

          // Recently Played row
          if (!_isSearching && _history.isNotEmpty)
            _HistorySliderRow(
              history: _history,
              editMode: _historyEditMode,
              onToggleEditMode: () => setState(() => _historyEditMode = !_historyEditMode),
              onRemove: (trackId) async {
                await _playerService.removeFromHistory(trackId);
                _loadHistory();
                if (_history.length <= 1) setState(() => _historyEditMode = false);
              },
              onResume: _resumeTrack,
            ),

          // Trending tracks grid
          if (_isLoading && displayTracks.isEmpty)
            const SizedBox(
              height: 180,
              child: Center(child: CircularProgressIndicator(color: AppColors.purpleLight)),
            )
          else if (displayTracks.isNotEmpty)
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.72,
              children: displayTracks.map((track) {
                final isLiked = _likedTracks.any((t) => t.id == track.id);
                return _MusicTrackCard(
                  track: track,
                  isLiked: isLiked,
                  onSelect: () => _playTrack(track, displayTracks),
                  onToggleLike: () async {
                    await _playerService.toggleLikeTrack(track);
                    _loadLikedTracks();
                  },
                  onAddToPlaylist: () => _showAddToPlaylistDialog(track),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  // --- Liked view with track and album sliders ---
  Widget _buildLikedView() {
    final hasNothing = _likedTracks.isEmpty && _likedAlbums.isEmpty;
    if (hasNothing) {
      return const Center(
        child: Text('No liked songs or albums yet',
            style: TextStyle(color: AppColors.textDim, fontSize: 14)),
      );
    }
    return ListView(
      cacheExtent: 5000,
      children: [
          if (_likedTracks.isNotEmpty) ...[
            Row(
              children: [
                const Text('LIKED TRACKS',
                    style: TextStyle(
                        color: AppColors.textDim,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.5)),
                const SizedBox(width: 6),
                Text('${_likedTracks.length}',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                const Spacer(),
                _ActionButton(
                  icon: Icons.play_arrow_rounded,
                  label: 'Play All',
                  isActive: false,
                  onSelect: () => _playAllTracks(_likedTracks),
                ),
                const SizedBox(width: 6),
                _ActionButton(
                  icon: Icons.shuffle_rounded,
                  label: 'Shuffle',
                  isActive: false,
                  onSelect: () => _shufflePlayTracks(_likedTracks),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _TrackSliderRow(
              tracks: _likedTracks,
              likedTracks: _likedTracks,
              onPlay: (track) => _playTrack(track, _likedTracks),
              onToggleLike: (track) async {
                await _playerService.toggleLikeTrack(track);
                _loadLikedTracks();
              },
              onAddToPlaylist: _showAddToPlaylistDialog,
            ),
          ],
          if (_likedAlbums.isNotEmpty) ...[
            _AlbumSliderRow(
              label: 'LIKED ALBUMS',
              albums: _likedAlbums,
              onSelect: _openAlbum,
            ),
          ],
      ],
    );
  }

  // --- Search results with horizontal sliders ---
  Widget _buildSearchResultsView() {
    final queryLower = _query.trim().toLowerCase();

    // Split tracks: best match (title closely matches query) vs more results
    final bestTracks = <MusicTrack>[];
    final moreTracks = <MusicTrack>[];
    for (final t in _tracks) {
      if (t.title.toLowerCase().contains(queryLower) ||
          queryLower.contains(t.title.toLowerCase())) {
        bestTracks.add(t);
      } else {
        moreTracks.add(t);
      }
    }

    // Split albums: best match vs other
    final bestAlbums = <MusicAlbum>[];
    final moreAlbums = <MusicAlbum>[];
    for (final a in _albums) {
      if (a.title.toLowerCase().contains(queryLower) ||
          queryLower.contains(a.title.toLowerCase())) {
        bestAlbums.add(a);
      } else {
        moreAlbums.add(a);
      }
    }

    final hasAnyResults = bestTracks.isNotEmpty ||
        moreTracks.isNotEmpty ||
        bestAlbums.isNotEmpty ||
        moreAlbums.isNotEmpty;

    if (!hasAnyResults) {
      return const Center(
        child: Text('No results', style: TextStyle(color: AppColors.textDim, fontSize: 14)),
      );
    }

    return ListView(
      cacheExtent: 5000,
      children: [
          if (bestTracks.isNotEmpty)
            _TrackSliderRow(
              label: 'BEST MATCH',
              tracks: bestTracks,
              likedTracks: _likedTracks,
              onPlay: (track) => _playTrack(track, bestTracks),
              onToggleLike: (track) async {
                await _playerService.toggleLikeTrack(track);
                _loadLikedTracks();
              },
              onAddToPlaylist: _showAddToPlaylistDialog,
            ),
          if (moreTracks.isNotEmpty)
            _TrackSliderRow(
              label: 'MORE RESULTS',
              tracks: moreTracks,
              likedTracks: _likedTracks,
              onPlay: (track) => _playTrack(track, moreTracks),
              onToggleLike: (track) async {
                await _playerService.toggleLikeTrack(track);
                _loadLikedTracks();
              },
              onAddToPlaylist: _showAddToPlaylistDialog,
            ),
          if (bestAlbums.isNotEmpty)
            _AlbumSliderRow(
              label: 'BEST MATCHED ALBUMS',
              albums: bestAlbums,
              onSelect: _openAlbum,
            ),
          if (moreAlbums.isNotEmpty)
            _AlbumSliderRow(
              label: 'OTHER ALBUMS',
              albums: moreAlbums,
              onSelect: _openAlbum,
            ),
      ],
    );
  }

  // --- Album detail view ---
  Widget _buildAlbumDetailView(MusicAlbum album) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            _ActionButton(
              icon: Icons.arrow_back_rounded,
              label: 'Back',
              isActive: false,
              onSelect: _goBack,
            ),
            const SizedBox(width: 12),
            if (album.cover.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: album.cover,
                  width: 48, height: 48, fit: BoxFit.cover,
                  errorWidget: (_, _, _) => const SizedBox(width: 48, height: 48),
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.title,
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    album.artist,
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Text(
              '${_albumTracks.length} tracks',
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Play All / Shuffle / Like Album
        if (_albumTracks.isNotEmpty) ...[
          Row(
            children: [
              _ActionButton(
                icon: Icons.play_arrow_rounded,
                label: 'Play All',
                isActive: false,
                onSelect: () => _playAllTracks(_albumTracks),
              ),
              const SizedBox(width: 8),
              _ActionButton(
                icon: Icons.shuffle_rounded,
                label: 'Shuffle',
                isActive: false,
                onSelect: () => _shufflePlayTracks(_albumTracks),
              ),
              const SizedBox(width: 8),
              _ActionButton(
                icon: _isAlbumLiked ? Icons.favorite : Icons.favorite_border,
                label: _isAlbumLiked ? 'Liked' : 'Like Album',
                isActive: _isAlbumLiked,
                onSelect: () async {
                  await _playerService.toggleLikeAlbum(album);
                  final liked = await _playerService.isAlbumLiked(album.id);
                  if (mounted) setState(() => _isAlbumLiked = liked);
                  _loadLikedAlbums();
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],

        // Tracks list
        Expanded(
          child: _isLoadingAlbum
              ? const Center(child: CircularProgressIndicator(color: AppColors.purpleLight))
              : _albumTracks.isEmpty
                  ? const Center(
                      child: Text('No tracks found',
                          style: TextStyle(color: AppColors.textDim, fontSize: 14)),
                    )
                  : SingleChildScrollView(
                      child: Column(
                        children: List.generate(_albumTracks.length, (index) {
                          final track = _albumTracks[index];
                          return _PlaylistTrackTile(
                            index: index,
                            track: track,
                            onSelect: () => _playTrack(track, _albumTracks),
                            onRemove: () {},
                            showRemoveButton: false,
                          );
                        }),
                      ),
                    ),
        ),
      ],
    );
  }

  // --- Playlists list view ---
  Widget _buildPlaylistsView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('PLAYLISTS', style: TextStyle(color: AppColors.textDim, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.5)),
            const SizedBox(width: 8),
            Text('${_playlists.length}', style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
            if (_playlistEditMode)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '— select to delete',
                  style: TextStyle(color: Colors.red.shade300, fontSize: 11, fontWeight: FontWeight.w500),
                ),
              ),
            const Spacer(),
            if (_playlists.isNotEmpty)
              _ActionButton(
                icon: _playlistEditMode ? Icons.close : Icons.delete_outline,
                label: _playlistEditMode ? 'Done' : 'Delete',
                isActive: _playlistEditMode,
                onSelect: () => setState(() => _playlistEditMode = !_playlistEditMode),
              ),
            const SizedBox(width: 6),
            _ActionButton(
              icon: Icons.add_rounded,
              label: 'New',
              isActive: false,
              onSelect: _showCreatePlaylistDialog,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _playlists.isEmpty
              ? const Center(
                  child: Text('No playlists yet.\nPress "New" to create one.', style: TextStyle(color: AppColors.textDim, fontSize: 14), textAlign: TextAlign.center),
                )
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 160,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                          child: Row(
                            children: List.generate(_playlists.length, (index) {
                              final pl = _playlists[index];
                              return Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: SizedBox(
                                  width: 140,
                                  child: _PlaylistCard(
                                    playlist: pl,
                                    editMode: _playlistEditMode,
                                    onSelect: _playlistEditMode
                                        ? () async {
                                            await _playerService.deletePlaylist(pl.name);
                                            _loadPlaylists();
                                            if (_playlists.length <= 1) {
                                              setState(() => _playlistEditMode = false);
                                            }
                                          }
                                        : () => _openPlaylistDetail(pl),
                                  ),
                                ),
                              );
                            }),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  // --- Playlist detail view ---
  Widget _buildPlaylistDetailView(MusicPlaylist pl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            _ActionButton(
              icon: Icons.arrow_back_rounded,
              label: 'Back',
              isActive: false,
              onSelect: _goBack,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                pl.name,
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '${pl.tracks.length} tracks',
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Play All / Shuffle row
        if (pl.tracks.isNotEmpty) ...[
          Row(
            children: [
              _ActionButton(
                icon: Icons.play_arrow_rounded,
                label: 'Play All',
                isActive: false,
                onSelect: () => _playAllTracks(pl.tracks),
              ),
              const SizedBox(width: 8),
              _ActionButton(
                icon: Icons.shuffle_rounded,
                label: 'Shuffle',
                isActive: false,
                onSelect: () => _shufflePlayTracks(pl.tracks),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],

        // Track list
        Expanded(
          child: pl.tracks.isEmpty
              ? const Center(
                  child: Text('Playlist is empty.\nAdd tracks from search or trending.', style: TextStyle(color: AppColors.textDim, fontSize: 14), textAlign: TextAlign.center),
                )
              : SingleChildScrollView(
                  child: Column(
                    children: List.generate(pl.tracks.length, (index) {
                      final track = pl.tracks[index];
                      return _PlaylistTrackTile(
                        index: index,
                        track: track,
                        onSelect: () => _playTrack(track, pl.tracks),
                        onRemove: () async {
                          await _playerService.removeTrackFromPlaylist(pl.name, track.id);
                          final updated = await _playerService.getPlaylists();
                          final refreshed = updated.firstWhere((p) => p.name == pl.name, orElse: () => MusicPlaylist(name: pl.name, tracks: []));
                          setState(() => _selectedPlaylist = refreshed);
                          _loadPlaylists();
                        },
                        showRemoveButton: true,
                      );
                    }),
                  ),
                ),
        ),
      ],
    );
  }
}

// --- Keyboard key button ---

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
        region: 'music_keyboard',
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

// --- Action button ---

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
        region: 'music_controls',
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

// --- Recently Played card ---

// --- History slider row (with ScrollController + auto-scroll) ---

class _HistorySliderRow extends StatefulWidget {
  final List<Map<String, dynamic>> history;
  final bool editMode;
  final VoidCallback onToggleEditMode;
  final ValueChanged<String> onRemove;
  final ValueChanged<Map<String, dynamic>> onResume;

  const _HistorySliderRow({
    required this.history,
    required this.editMode,
    required this.onToggleEditMode,
    required this.onRemove,
    required this.onResume,
  });

  @override
  State<_HistorySliderRow> createState() => _HistorySliderRowState();
}

class _HistorySliderRowState extends State<_HistorySliderRow> {
  final ScrollController _scrollController = ScrollController();

  void _scrollToIndex(int index) {
    if (!_scrollController.hasClients) return;
    const itemWidth = 258.0; // 240 card + 10 padding + 8 gap
    final offset = index * itemWidth;
    _scrollController.animateTo(
      (offset - 50).clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
    _ensureRowVisible();
  }

  void _ensureRowVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
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
        Row(
          children: [
            const Text('RECENTLY PLAYED',
                style: TextStyle(
                    color: AppColors.textDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5)),
            if (widget.editMode)
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
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: DpadFocusable(
                    region: 'music_history',
                    onFocus: () => _scrollToIndex(0),
                    onSelect: widget.onToggleEditMode,
                    builder: (context, isFocused, child) {
                      return GestureDetector(
                        onTap: widget.onToggleEditMode,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 48,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
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
                              size: 20,
                            ),
                          ),
                        ),
                      );
                    },
                    child: const SizedBox.shrink(),
                  ),
                ),
                ...List.generate(widget.history.length, (i) {
                  final historyEntry = widget.history[i];
                  final track = MusicTrack.fromJson(historyEntry['track'] as Map<String, dynamic>);
                  return _HistoryCard(
                    track: track,
                    editMode: widget.editMode,
                    onFocused: () => _scrollToIndex(i + 1),
                    onSelect: widget.editMode
                        ? () => widget.onRemove(track.id)
                        : () => widget.onResume(historyEntry),
                  );
                }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }
}

// --- History card ---

class _HistoryCard extends StatefulWidget {
  final MusicTrack track;
  final bool editMode;
  final VoidCallback onSelect;
  final VoidCallback? onFocused;

  const _HistoryCard({required this.track, required this.onSelect, this.editMode = false, this.onFocused});

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
          region: 'music_history',
          onFocus: () {
            setState(() => _focused = true);
            widget.onFocused?.call();
          },
          onBlur: () => setState(() => _focused = false),
          onSelect: widget.onSelect,
          builder: (context, isFocused, child) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 240,
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
                      child: widget.track.cover.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: widget.track.cover,
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => _coverFallback(),
                            )
                          : _coverFallback(),
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.track.title,
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
                          widget.editMode ? 'Tap to remove' : widget.track.artist,
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

  Widget _coverFallback() => Container(
    width: 48,
    height: 48,
    color: AppColors.cardBg,
    child: const Icon(Icons.music_note, color: AppColors.textDim, size: 20),
  );
}

// --- Track slider row (with ScrollController + auto-scroll on focus) ---

class _TrackSliderRow extends StatefulWidget {
  final String? label;
  final List<MusicTrack> tracks;
  final List<MusicTrack> likedTracks;
  final ValueChanged<MusicTrack> onPlay;
  final ValueChanged<MusicTrack> onToggleLike;
  final ValueChanged<MusicTrack> onAddToPlaylist;

  const _TrackSliderRow({
    this.label,
    required this.tracks,
    required this.likedTracks,
    required this.onPlay,
    required this.onToggleLike,
    required this.onAddToPlaylist,
  });

  @override
  State<_TrackSliderRow> createState() => _TrackSliderRowState();
}

class _TrackSliderRowState extends State<_TrackSliderRow> {
  final ScrollController _scrollController = ScrollController();

  void _scrollToIndex(int index) {
    if (!_scrollController.hasClients) return;
    const itemWidth = 142.0;
    final offset = index * itemWidth;
    _scrollController.animateTo(
      (offset - 100).clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
    _ensureRowVisible();
  }

  void _ensureRowVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
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
        if (widget.label != null) ...[
          Text(widget.label!,
              style: const TextStyle(
                  color: AppColors.textDim,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.5)),
          const SizedBox(height: 8),
        ],
        SizedBox(
          height: 180,
          child: ListView.builder(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            cacheExtent: 10000,
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            itemCount: widget.tracks.length,
            itemBuilder: (context, index) {
              final track = widget.tracks[index];
              final isLiked = widget.likedTracks.any((t) => t.id == track.id);
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: 130,
                  child: _MusicTrackCard(
                    track: track,
                    isLiked: isLiked,
                    onSelect: () => widget.onPlay(track),
                    onToggleLike: () => widget.onToggleLike(track),
                    onAddToPlaylist: () => widget.onAddToPlaylist(track),
                    onFocused: () => _scrollToIndex(index),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }
}

// --- Album slider row (with ScrollController + auto-scroll on focus) ---

class _AlbumSliderRow extends StatefulWidget {
  final String? label;
  final List<MusicAlbum> albums;
  final ValueChanged<MusicAlbum> onSelect;

  const _AlbumSliderRow({
    this.label,
    required this.albums,
    required this.onSelect,
  });

  @override
  State<_AlbumSliderRow> createState() => _AlbumSliderRowState();
}

class _AlbumSliderRowState extends State<_AlbumSliderRow> {
  final ScrollController _scrollController = ScrollController();

  void _scrollToIndex(int index) {
    if (!_scrollController.hasClients) return;
    const itemWidth = 142.0;
    final offset = index * itemWidth;
    _scrollController.animateTo(
      (offset - 100).clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
    _ensureRowVisible();
  }

  void _ensureRowVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
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
        if (widget.label != null) ...[
          Text(widget.label!,
              style: const TextStyle(
                  color: AppColors.textDim,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.5)),
          const SizedBox(height: 8),
        ],
        SizedBox(
          height: 180,
          child: ListView.builder(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            cacheExtent: 10000,
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            itemCount: widget.albums.length,
            itemBuilder: (context, index) {
              final album = widget.albums[index];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: 130,
                  child: _AlbumCard(
                    album: album,
                    onSelect: () => widget.onSelect(album),
                    onFocused: () => _scrollToIndex(index),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }
}

// --- Music track card ---

class _MusicTrackCard extends StatefulWidget {
  final MusicTrack track;
  final bool isLiked;
  final VoidCallback onSelect;
  final VoidCallback onToggleLike;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onFocused;

  const _MusicTrackCard({required this.track, required this.isLiked, required this.onSelect, required this.onToggleLike, this.onAddToPlaylist, this.onFocused});

  @override
  State<_MusicTrackCard> createState() => _MusicTrackCardState();
}

class _MusicTrackCardState extends State<_MusicTrackCard> with SingleTickerProviderStateMixin {
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
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.keyP) {
            widget.onAddToPlaylist?.call();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: DpadFocusable(
          region: 'music_tracks',
          autoScroll: false,
          onFocus: () {
            setState(() => _focused = true);
            _scaleCtrl.forward();
            widget.onFocused?.call();
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
                                widget.track.cover.isNotEmpty
                                    ? CachedNetworkImage(
                                        imageUrl: widget.track.cover,
                                        fit: BoxFit.cover,
                                        placeholder: (_, _) => Container(color: AppColors.cardBg),
                                        errorWidget: (_, _, _) => Container(
                                          color: AppColors.cardBg,
                                          child: const Icon(Icons.music_note, color: AppColors.textDim, size: 32),
                                        ),
                                      )
                                    : Container(
                                        color: AppColors.cardBg,
                                        child: const Icon(Icons.music_note, color: AppColors.textDim, size: 32),
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
                                        '${widget.isLiked ? 'L Unlike' : 'L Like'} · P Playlist',
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
                                  widget.track.title,
                                  style: TextStyle(
                                    color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                                    fontSize: 12,
                                    fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  widget.track.artist,
                                  style: const TextStyle(color: AppColors.textDim, fontSize: 10),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
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
}

// --- Album card ---

class _AlbumCard extends StatefulWidget {
  final MusicAlbum album;
  final VoidCallback onSelect;
  final VoidCallback? onFocused;

  const _AlbumCard({required this.album, required this.onSelect, this.onFocused});

  @override
  State<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<_AlbumCard> with SingleTickerProviderStateMixin {
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
      child: DpadFocusable(
        region: 'music_tracks',
        autoScroll: false,
        onFocus: () {
          setState(() => _focused = true);
          _scaleCtrl.forward();
          widget.onFocused?.call();
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
                              widget.album.cover.isNotEmpty
                                  ? CachedNetworkImage(
                                      imageUrl: widget.album.cover,
                                      fit: BoxFit.cover,
                                      placeholder: (_, _) => Container(color: AppColors.cardBg),
                                      errorWidget: (_, _, _) => Container(
                                        color: AppColors.cardBg,
                                        child: const Icon(Icons.album, color: AppColors.textDim, size: 32),
                                      ),
                                    )
                                  : Container(
                                      color: AppColors.cardBg,
                                      child: const Icon(Icons.album, color: AppColors.textDim, size: 32),
                                    ),
                              if (_focused)
                                Container(
                                  color: Colors.black.withValues(alpha: 0.3),
                                  child: const Center(
                                    child: Icon(Icons.album_rounded, color: Colors.white70, size: 32),
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
                                widget.album.title,
                                style: TextStyle(
                                  color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                                  fontSize: 12,
                                  fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                widget.album.artist,
                                style: const TextStyle(color: AppColors.textDim, fontSize: 10),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
    );
  }
}

// --- Playlist card ---

class _PlaylistCard extends StatefulWidget {
  final MusicPlaylist playlist;
  final bool editMode;
  final VoidCallback onSelect;

  const _PlaylistCard({required this.playlist, required this.onSelect, this.editMode = false});

  @override
  State<_PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<_PlaylistCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onSelect,
      child: DpadFocusable(
        region: 'music_tracks',
        onFocus: () => setState(() => _focused = true),
        onBlur: () => setState(() => _focused = false),
        onSelect: widget.onSelect,
        builder: (context, isFocused, child) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              color: widget.editMode
                  ? Colors.red.withValues(alpha: _focused ? 0.3 : 0.15)
                  : _focused
                      ? AppColors.darkPurple
                      : AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: widget.editMode
                    ? (_focused ? Colors.red.shade300 : Colors.red.withValues(alpha: 0.4))
                    : _focused
                        ? AppColors.purpleLight
                        : Colors.transparent,
                width: 2,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  widget.editMode ? Icons.delete_outline : Icons.playlist_play_rounded,
                  color: widget.editMode
                      ? (_focused ? Colors.red.shade300 : Colors.red.withValues(alpha: 0.6))
                      : _focused
                          ? AppColors.purpleLight
                          : AppColors.textSecondary,
                  size: 40,
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    widget.playlist.name,
                    style: TextStyle(
                      color: widget.editMode
                          ? (_focused ? Colors.red.shade300 : AppColors.textSecondary)
                          : (_focused ? AppColors.textPrimary : AppColors.textSecondary),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.editMode ? 'Select to delete' : '${widget.playlist.tracks.length} tracks',
                  style: TextStyle(
                    color: widget.editMode ? Colors.red.withValues(alpha: 0.5) : AppColors.textDim,
                    fontSize: 11,
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

// --- Playlist track tile ---

class _PlaylistTrackTile extends StatefulWidget {
  final int index;
  final MusicTrack track;
  final VoidCallback onSelect;
  final VoidCallback onRemove;
  final bool showRemoveButton;

  const _PlaylistTrackTile({required this.index, required this.track, required this.onSelect, required this.onRemove, this.showRemoveButton = false});

  @override
  State<_PlaylistTrackTile> createState() => _PlaylistTrackTileState();
}

class _PlaylistTrackTileState extends State<_PlaylistTrackTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: widget.onSelect,
              child: DpadFocusable(
                region: 'music_tracks',
                onFocus: () => setState(() => _focused = true),
                onBlur: () => setState(() => _focused = false),
                onSelect: widget.onSelect,
                builder: (context, isFocused, child) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: _focused ? AppColors.darkPurple : AppColors.surfaceLight,
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
                              color: _focused ? AppColors.purpleLight : AppColors.textDim,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: widget.track.cover.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: widget.track.cover,
                                  width: 40,
                                  height: 40,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, _, _) => Container(
                                    width: 40,
                                    height: 40,
                                    color: AppColors.cardBg,
                                    child: const Icon(Icons.music_note, color: AppColors.textDim, size: 16),
                                  ),
                                )
                              : Container(
                                  width: 40,
                                  height: 40,
                                  color: AppColors.cardBg,
                                  child: const Icon(Icons.music_note, color: AppColors.textDim, size: 16),
                                ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.track.title,
                                style: TextStyle(
                                  color: _focused ? AppColors.textPrimary : AppColors.textSecondary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
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
                      ],
                    ),
                  );
                },
                child: const SizedBox.shrink(),
              ),
            ),
          ),
          if (widget.showRemoveButton) ...[
            const SizedBox(width: 6),
            _RemoveButton(onSelect: widget.onRemove),
          ],
        ],
      ),
    );
  }
}

// --- Small remove button for playlist tracks ---

class _RemoveButton extends StatefulWidget {
  final VoidCallback onSelect;
  const _RemoveButton({required this.onSelect});
  @override
  State<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends State<_RemoveButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onSelect,
      child: DpadFocusable(
        region: 'music_tracks',
        onFocus: () => setState(() => _focused = true),
        onBlur: () => setState(() => _focused = false),
        onSelect: widget.onSelect,
        builder: (context, isFocused, child) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _focused ? Colors.red.withValues(alpha: 0.3) : AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _focused ? Colors.red.shade300 : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Icon(
              Icons.close_rounded,
              color: _focused ? Colors.red.shade300 : AppColors.textDim,
              size: 18,
            ),
          );
        },
        child: const SizedBox.shrink(),
      ),
    );
  }
}

// --- D-pad keyboard dialog for text entry ---

class _DpadKeyboardDialog extends StatefulWidget {
  final String title;
  const _DpadKeyboardDialog({required this.title});

  @override
  State<_DpadKeyboardDialog> createState() => _DpadKeyboardDialogState();
}

class _DpadKeyboardDialogState extends State<_DpadKeyboardDialog> {
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
              // Text display
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
              // Keyboard grid
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
                    return _KeyButton(label: 'CLR', onSelect: _clear);
                  }
                },
              ),
              const SizedBox(height: 16),
              // Action buttons
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.close_rounded,
                      label: 'Cancel',
                      isActive: false,
                      onSelect: () => Navigator.pop(context),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.check_rounded,
                      label: 'Create',
                      isActive: _text.trim().isNotEmpty,
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
