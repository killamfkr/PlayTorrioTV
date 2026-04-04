import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'audiobook_service.dart';
import 'local_proxy_service.dart';

class AudiobookPlayerService {
  static final AudiobookPlayerService _instance = AudiobookPlayerService._internal();
  factory AudiobookPlayerService() => _instance;
  AudiobookPlayerService._internal();

  final AudioPlayer _player = AudioPlayer();

  // State
  final ValueNotifier<Audiobook?> currentBook = ValueNotifier<Audiobook?>(null);
  final ValueNotifier<int> currentChapterIndex = ValueNotifier<int>(0);
  final ValueNotifier<Duration> position = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<Duration> duration = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<bool> isPlaying = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isBuffering = ValueNotifier<bool>(false);
  final ValueNotifier<bool> autoplay = ValueNotifier<bool>(true);

  List<AudiobookChapter> _currentChapters = [];
  final List<StreamSubscription> _subscriptions = [];
  bool _isResuming = false;
  bool _initialized = false;
  bool _durationLocked = false;

  void init() {
    if (_initialized) return;
    _initialized = true;

    _subscriptions.add(_player.positionStream.listen((p) {
      position.value = p;
      if (!_isResuming && p > Duration.zero) _saveProgress();
    }));

    _subscriptions.add(_player.durationStream.listen((d) {
      final dur = d ?? Duration.zero;
      // ADTS AAC streams report bogus duration; ignore > 24h AND ignore zero
      // if we already have a valid expected duration from the m3u8
      if (dur > Duration.zero && dur.inHours >= 24) return;
      if (dur == Duration.zero && duration.value > Duration.zero) return;
      // Once we have the m3u8 duration, keep it (partial cache has wrong size)
      if (_durationLocked) return;
      duration.value = dur;
    }));

    _subscriptions.add(_player.playingStream.listen((pl) {
      isPlaying.value = pl;
      debugPrint('AudiobookPlayer: playing = $pl');
    }));

    _subscriptions.add(_player.processingStateStream.listen((state) {
      isBuffering.value = state == ProcessingState.loading || state == ProcessingState.buffering;
      debugPrint('AudiobookPlayer: state = $state');

      if (state == ProcessingState.completed && autoplay.value) {
        final nextIdx = currentChapterIndex.value + 1;
        if (nextIdx < _currentChapters.length) {
          changeChapter(nextIdx);
        }
      }
    }));

    _player.playbackEventStream.listen((_) {}, onError: (Object e, StackTrace st) {
      debugPrint('AudiobookPlayer ERROR: $e');
    });
  }

  Future<void> loadBook(Audiobook book, List<AudiobookChapter> chapters, {int initialChapter = 0, Duration? resumePosition}) async {
    init();
    _isResuming = resumePosition != null && resumePosition > Duration.zero;
    currentBook.value = book;
    _currentChapters = chapters;
    currentChapterIndex.value = initialChapter;

    final chapter = chapters[initialChapter];
    final headers = (chapter.headers != null && chapter.headers!.isNotEmpty) ? chapter.headers : null;

    debugPrint('AudiobookPlayer: Opening ${chapter.url}');

    // Cancel any previous proxy download before starting new one
    LocalProxyService().cancelCurrentStream();
    _durationLocked = false;

    // For Tokybook proxy URLs, fetch duration from the response header
    Duration? expectedDuration;
    if (chapter.url.contains('/toky-proxy')) {
      try {
        final headRes = await http.head(Uri.parse(chapter.url));
        final durMs = int.tryParse(headRes.headers['x-duration-ms'] ?? '');
        if (durMs != null && durMs > 0) {
          expectedDuration = Duration(milliseconds: durMs);
          duration.value = expectedDuration;
          _durationLocked = true;
          debugPrint('AudiobookPlayer: expected duration from m3u8 = $expectedDuration');
        }
      } catch (_) {}
    }

    try {
      await _player.setAudioSource(
        AudioSource.uri(Uri.parse(chapter.url), headers: headers),
      );
    } catch (e) {
      debugPrint('AudiobookPlayer: Error setting source: $e');
      return;
    }

    if (_isResuming) {
      debugPrint('AudiobookPlayer: Resuming at $resumePosition');
      await _player.seek(resumePosition!);
      _isResuming = false;
    }

    _player.play();
    debugPrint('AudiobookPlayer: play() called');
  }

  void playOrPause() {
    if (_player.playing) {
      _player.pause();
    } else {
      _player.play();
    }
  }

  void seek(Duration p) => _player.seek(p);
  void setRate(double r) => _player.setSpeed(r);

  Future<void> stop() async {
    LocalProxyService().cancelCurrentStream();
    await _player.stop();
  }

  Future<void> changeChapter(int index) async {
    if (index < 0 || index >= _currentChapters.length) return;
    currentChapterIndex.value = index;
    final chapter = _currentChapters[index];
    final headers = (chapter.headers != null && chapter.headers!.isNotEmpty) ? chapter.headers : null;

    // Cancel any previous proxy download before starting new chapter
    LocalProxyService().cancelCurrentStream();
    _durationLocked = false;

    // Pre-fetch duration from proxy for Tokybook chapters
    if (chapter.url.contains('/toky-proxy')) {
      try {
        final headRes = await http.head(Uri.parse(chapter.url));
        final durMs = int.tryParse(headRes.headers['x-duration-ms'] ?? '');
        if (durMs != null && durMs > 0) {
          duration.value = Duration(milliseconds: durMs);
          _durationLocked = true;
        }
      } catch (_) {}
    }

    try {
      await _player.setAudioSource(
        AudioSource.uri(Uri.parse(chapter.url), headers: headers),
      );
      _player.play();
    } catch (e) {
      debugPrint('AudiobookPlayer: Error changing chapter: $e');
    }
  }

  // --- Persistence (History) ---

  Future<void> _saveProgress() async {
    if (currentBook.value == null || _isResuming) return;
    final prefs = await SharedPreferences.getInstance();

    List<String> historyStrings = prefs.getStringList('audiobook_history') ?? [];
    List<Map<String, dynamic>> history = historyStrings.map((s) => json.decode(s) as Map<String, dynamic>).toList();

    final bookData = {
      'book': currentBook.value!.toJson(),
      'chapterIndex': currentChapterIndex.value,
      'positionMs': position.value.inMilliseconds,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    history.removeWhere((item) => item['book']['audioBookId'] == currentBook.value!.audioBookId);
    history.insert(0, bookData);
    if (history.length > 10) history = history.sublist(0, 10);

    await prefs.setStringList('audiobook_history', history.map((e) => json.encode(e)).toList());
  }

  Future<void> saveManualProgress() async => _saveProgress();

  Future<List<Map<String, dynamic>>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> history = prefs.getStringList('audiobook_history') ?? [];
    return history.map((s) => json.decode(s) as Map<String, dynamic>).toList();
  }

  Future<void> removeFromHistory(String audioBookId) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> historyStrings = prefs.getStringList('audiobook_history') ?? [];
    historyStrings.removeWhere((s) {
      final data = json.decode(s);
      return data['book']['audioBookId'] == audioBookId;
    });
    await prefs.setStringList('audiobook_history', historyStrings);
  }

  // --- Liked Books ---

  Future<List<Audiobook>> getLikedBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> liked = prefs.getStringList('audiobook_liked') ?? [];
    return liked.map((s) => Audiobook.fromJson(json.decode(s) as Map<String, dynamic>)).toList();
  }

  Future<bool> isBookLiked(String audioBookId) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> liked = prefs.getStringList('audiobook_liked') ?? [];
    return liked.any((s) => (json.decode(s) as Map<String, dynamic>)['audioBookId'] == audioBookId);
  }

  Future<void> toggleLikeBook(Audiobook book) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> likedStrings = prefs.getStringList('audiobook_liked') ?? [];
    final index = likedStrings.indexWhere((s) => (json.decode(s) as Map<String, dynamic>)['audioBookId'] == book.audioBookId);
    if (index >= 0) {
      likedStrings.removeAt(index);
    } else {
      likedStrings.add(json.encode(book.toJson()));
    }
    await prefs.setStringList('audiobook_liked', likedStrings);
  }

  void dispose() {
    for (var s in _subscriptions) { s.cancel(); }
    _player.dispose();
  }

  // --- Profile data isolation ---

  static Future<void> saveForProfile(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final data = {
      'history': prefs.getStringList('audiobook_history') ?? [],
      'liked': prefs.getStringList('audiobook_liked') ?? [],
    };
    await prefs.setString('profile_audiobook_$profileId', json.encode(data));
  }

  static Future<void> loadForProfile(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('profile_audiobook_$profileId');
    if (raw != null) {
      try {
        final data = json.decode(raw) as Map<String, dynamic>;
        await prefs.setStringList('audiobook_history',
            (data['history'] as List).map((e) => e as String).toList());
        await prefs.setStringList('audiobook_liked',
            (data['liked'] as List).map((e) => e as String).toList());
        return;
      } catch (_) {}
    }
    // New profile — start empty
    await prefs.setStringList('audiobook_history', []);
    await prefs.setStringList('audiobook_liked', []);
  }
}
