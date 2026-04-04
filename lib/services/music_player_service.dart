import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'music_service.dart';

class MusicPlayerService {
  static final MusicPlayerService _instance = MusicPlayerService._internal();
  factory MusicPlayerService() => _instance;
  MusicPlayerService._internal();

  final AudioPlayer _player = AudioPlayer();
  final MusicService _musicService = MusicService();

  final ValueNotifier<MusicTrack?> currentTrack = ValueNotifier<MusicTrack?>(null);
  final ValueNotifier<List<MusicTrack>> playlist = ValueNotifier<List<MusicTrack>>([]);
  final ValueNotifier<bool> isPlaying = ValueNotifier<bool>(false);
  final ValueNotifier<Duration> position = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<Duration> duration = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<bool> isBuffering = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isShuffleEnabled = ValueNotifier<bool>(false);
  final ValueNotifier<int> loopMode = ValueNotifier<int>(0); // 0=off, 1=all, 2=one

  int _currentIndex = -1;
  bool _initialized = false;
  bool _isLoadingTrack = false;
  int _playGeneration = 0;
  final Set<String> _shufflePlayedIds = {};
  final Random _random = Random();

  void init() {
    if (_initialized) return;
    _initialized = true;

    _player.positionStream.listen((p) => position.value = p);
    _player.durationStream.listen((d) => duration.value = d ?? Duration.zero);
    _player.playingStream.listen((p) => isPlaying.value = p);
    _player.processingStateStream.listen((state) {
      if (!_isLoadingTrack) {
        isBuffering.value = state == ProcessingState.loading || state == ProcessingState.buffering;
      }
      if (state == ProcessingState.completed && !_isLoadingTrack) {
        _onTrackCompleted();
      }
    });

    _player.playbackEventStream.listen((_) {}, onError: (Object e, StackTrace st) {
      debugPrint('MusicPlayer ERROR: $e');
    });
  }

  Future<void> playTrack(MusicTrack track, {List<MusicTrack>? newPlaylist}) async {
    debugPrint('MusicPlayerService: Preparing to play: ${track.title} by ${track.artist}');

    _isLoadingTrack = true;
    isBuffering.value = true;
    final generation = ++_playGeneration;

    try {
      await _player.stop();

      if (newPlaylist != null) {
        playlist.value = newPlaylist;
        _currentIndex = newPlaylist.indexWhere((t) => t.id == track.id);
        _shufflePlayedIds.clear();
      }

      if (isShuffleEnabled.value) {
        _shufflePlayedIds.add(track.id);
      }

      currentTrack.value = track;
      position.value = Duration.zero;
      duration.value = Duration.zero;

      // Resolve YouTube URL
      final videoId = await _musicService.getYoutubeVideoId(track.title, track.artist);
      if (_playGeneration != generation) return;
      if (videoId == null) {
        debugPrint('MusicPlayerService: No YouTube match for ${track.title}');
        _isLoadingTrack = false;
        isBuffering.value = false;
        Future.delayed(const Duration(milliseconds: 500), () => next());
        return;
      }

      final streamUrl = await _musicService.getYoutubeStreamUrl(videoId);
      if (_playGeneration != generation) return;
      if (streamUrl == null) {
        debugPrint('MusicPlayerService: Failed to get stream URL');
        _isLoadingTrack = false;
        isBuffering.value = false;
        Future.delayed(const Duration(milliseconds: 500), () => next());
        return;
      }

      await _player.setAudioSource(AudioSource.uri(Uri.parse(streamUrl)));

      if (loopMode.value == 2) {
        await _player.setLoopMode(LoopMode.one);
      } else {
        await _player.setLoopMode(LoopMode.off);
      }

      _player.play();
      _saveHistory(track);
      _prefetchNext();

    } catch (e) {
      debugPrint('MusicPlayerService: Error playing track: $e');
    } finally {
      _isLoadingTrack = false;
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!_isLoadingTrack) {
          isBuffering.value = _player.processingState == ProcessingState.loading ||
              _player.processingState == ProcessingState.buffering;
        }
      });
    }
  }

  void _prefetchNext() async {
    if (playlist.value.isEmpty || _currentIndex == -1) return;
    final nextIndex = (_currentIndex + 1) % playlist.value.length;
    final nextTrack = playlist.value[nextIndex];
    final videoId = await _musicService.getYoutubeVideoId(nextTrack.title, nextTrack.artist);
    if (videoId != null) {
      await _musicService.getYoutubeStreamUrl(videoId);
    }
  }

  void _onTrackCompleted() {
    if (loopMode.value == 2) return; // LoopMode.one handled by just_audio
    next();
  }

  void play() => _player.play();
  void pause() => _player.pause();
  void togglePlay() {
    if (_player.playing) {
      _player.pause();
    } else {
      _player.play();
    }
  }

  void seek(Duration pos) => _player.seek(pos);
  void setRate(double rate) => _player.setSpeed(rate);

  void toggleShuffle() {
    isShuffleEnabled.value = !isShuffleEnabled.value;
    _shufflePlayedIds.clear();
    if (isShuffleEnabled.value && currentTrack.value != null) {
      _shufflePlayedIds.add(currentTrack.value!.id);
    }
  }

  void cycleLoop() {
    loopMode.value = (loopMode.value + 1) % 3;
    if (loopMode.value == 2) {
      _player.setLoopMode(LoopMode.one);
    } else {
      _player.setLoopMode(LoopMode.off);
    }
  }

  void next() {
    if (playlist.value.isEmpty) return;

    if (isShuffleEnabled.value) {
      final unplayed = <int>[];
      for (int i = 0; i < playlist.value.length; i++) {
        if (!_shufflePlayedIds.contains(playlist.value[i].id)) {
          unplayed.add(i);
        }
      }
      if (unplayed.isEmpty) {
        if (loopMode.value == 1) {
          _shufflePlayedIds.clear();
          if (currentTrack.value != null) _shufflePlayedIds.add(currentTrack.value!.id);
          next();
        } else {
          pause();
        }
        return;
      }
      final nextIndex = unplayed[_random.nextInt(unplayed.length)];
      _currentIndex = nextIndex;
      playTrack(playlist.value[nextIndex]);
    } else {
      final nextIdx = _currentIndex + 1;
      if (nextIdx >= playlist.value.length) {
        if (loopMode.value == 1) {
          _currentIndex = 0;
          playTrack(playlist.value[0]);
        } else {
          pause();
        }
      } else {
        _currentIndex = nextIdx;
        playTrack(playlist.value[nextIdx]);
      }
    }
  }

  void previous() {
    if (playlist.value.isEmpty) return;
    if (position.value.inSeconds > 3) {
      seek(Duration.zero);
      return;
    }
    _currentIndex = (_currentIndex - 1) % playlist.value.length;
    if (_currentIndex < 0) _currentIndex = playlist.value.length - 1;
    playTrack(playlist.value[_currentIndex]);
  }

  // --- History ---

  Future<void> _saveHistory(MusicTrack track) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> historyStrings = prefs.getStringList('music_history') ?? [];
    List<Map<String, dynamic>> history = historyStrings.map((s) => json.decode(s) as Map<String, dynamic>).toList();

    final data = {
      'track': track.toJson(),
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    history.removeWhere((item) => item['track']['id'] == track.id);
    history.insert(0, data);
    if (history.length > 10) history = history.sublist(0, 10);

    await prefs.setStringList('music_history', history.map((e) => json.encode(e)).toList());
  }

  Future<List<Map<String, dynamic>>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> history = prefs.getStringList('music_history') ?? [];
    return history.map((s) => json.decode(s) as Map<String, dynamic>).toList();
  }

  Future<void> removeFromHistory(String trackId) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> historyStrings = prefs.getStringList('music_history') ?? [];
    historyStrings.removeWhere((s) {
      final data = json.decode(s);
      return data['track']['id'] == trackId;
    });
    await prefs.setStringList('music_history', historyStrings);
  }

  // --- Liked Songs ---

  Future<List<MusicTrack>> getLikedSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> liked = prefs.getStringList('music_liked_songs') ?? [];
    return liked.map((s) => MusicTrack.fromJson(json.decode(s))).toList();
  }

  Future<bool> isTrackLiked(String trackId) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> liked = prefs.getStringList('music_liked_songs') ?? [];
    return liked.any((s) {
      try { return json.decode(s)['id'] == trackId; } catch (_) { return false; }
    });
  }

  Future<void> toggleLikeTrack(MusicTrack track) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> liked = prefs.getStringList('music_liked_songs') ?? [];
    final index = liked.indexWhere((s) {
      try { return json.decode(s)['id'] == track.id; } catch (_) { return false; }
    });
    if (index >= 0) {
      liked.removeAt(index);
    } else {
      liked.insert(0, json.encode(track.toJson()));
    }
    await prefs.setStringList('music_liked_songs', liked);
  }

  // --- Playlists ---

  Future<List<MusicPlaylist>> getPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> playlists = prefs.getStringList('music_playlists') ?? [];
    return playlists.map((p) => MusicPlaylist.fromJson(json.decode(p))).toList();
  }

  Future<void> createPlaylist(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> playlists = prefs.getStringList('music_playlists') ?? [];
    // Don't allow duplicate names
    final exists = playlists.any((p) {
      try { return json.decode(p)['name'] == name; } catch (_) { return false; }
    });
    if (!exists) {
      playlists.add(json.encode(MusicPlaylist(name: name, tracks: []).toJson()));
      await prefs.setStringList('music_playlists', playlists);
    }
  }

  Future<void> addTrackToPlaylist(String playlistName, MusicTrack track) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> playlists = prefs.getStringList('music_playlists') ?? [];
    for (int i = 0; i < playlists.length; i++) {
      final pl = MusicPlaylist.fromJson(json.decode(playlists[i]));
      if (pl.name == playlistName) {
        if (pl.tracks.any((t) => t.id == track.id)) return; // already in playlist
        final updated = MusicPlaylist(name: pl.name, tracks: [...pl.tracks, track]);
        playlists[i] = json.encode(updated.toJson());
        await prefs.setStringList('music_playlists', playlists);
        return;
      }
    }
  }

  Future<void> removeTrackFromPlaylist(String playlistName, String trackId) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> playlists = prefs.getStringList('music_playlists') ?? [];
    for (int i = 0; i < playlists.length; i++) {
      final pl = MusicPlaylist.fromJson(json.decode(playlists[i]));
      if (pl.name == playlistName) {
        final updated = MusicPlaylist(
          name: pl.name,
          tracks: pl.tracks.where((t) => t.id != trackId).toList(),
        );
        playlists[i] = json.encode(updated.toJson());
        await prefs.setStringList('music_playlists', playlists);
        return;
      }
    }
  }

  Future<void> deletePlaylist(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> playlists = prefs.getStringList('music_playlists') ?? [];
    playlists.removeWhere((p) {
      try { return json.decode(p)['name'] == name; } catch (_) { return false; }
    });
    await prefs.setStringList('music_playlists', playlists);
  }

  // --- Liked Albums ---

  Future<List<MusicAlbum>> getLikedAlbums() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> liked = prefs.getStringList('music_liked_albums') ?? [];
    return liked.map((s) => MusicAlbum.fromJson(json.decode(s))).toList();
  }

  Future<bool> isAlbumLiked(String albumId) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> liked = prefs.getStringList('music_liked_albums') ?? [];
    return liked.any((s) {
      try { return json.decode(s)['id'].toString() == albumId; } catch (_) { return false; }
    });
  }

  Future<void> toggleLikeAlbum(MusicAlbum album) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> liked = prefs.getStringList('music_liked_albums') ?? [];
    final index = liked.indexWhere((s) {
      try { return json.decode(s)['id'].toString() == album.id; } catch (_) { return false; }
    });
    if (index >= 0) {
      liked.removeAt(index);
    } else {
      liked.insert(0, json.encode(album.toJson()));
    }
    await prefs.setStringList('music_liked_albums', liked);
  }

  Future<void> stop() async {
    await _player.stop();
    currentTrack.value = null;
    playlist.value = [];
    _currentIndex = -1;
    isPlaying.value = false;
  }

  void dispose() {
    _player.dispose();
    _musicService.dispose();
  }

  // --- Profile data isolation ---

  static Future<void> saveForProfile(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final data = {
      'history': prefs.getStringList('music_history') ?? [],
      'liked_songs': prefs.getStringList('music_liked_songs') ?? [],
      'playlists': prefs.getStringList('music_playlists') ?? [],
      'liked_albums': prefs.getStringList('music_liked_albums') ?? [],
    };
    await prefs.setString('profile_music_$profileId', json.encode(data));
  }

  static Future<void> loadForProfile(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('profile_music_$profileId');
    if (raw != null) {
      try {
        final data = json.decode(raw) as Map<String, dynamic>;
        await prefs.setStringList('music_history',
            (data['history'] as List).map((e) => e as String).toList());
        await prefs.setStringList('music_liked_songs',
            (data['liked_songs'] as List).map((e) => e as String).toList());
        await prefs.setStringList('music_playlists',
            (data['playlists'] as List).map((e) => e as String).toList());
        await prefs.setStringList('music_liked_albums',
            (data['liked_albums'] as List).map((e) => e as String).toList());
        return;
      } catch (_) {}
    }
    // New profile — start empty
    await prefs.setStringList('music_history', []);
    await prefs.setStringList('music_liked_songs', []);
    await prefs.setStringList('music_playlists', []);
    await prefs.setStringList('music_liked_albums', []);
  }
}
