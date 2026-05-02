import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'settings_service.dart';
import 'continue_watching_service.dart';
import 'playtorrio_cloud_sync_service.dart';
import 'music_player_service.dart';
import 'audiobook_player_service.dart';

class Profile {
  final String id;
  final String name;
  final int colorIndex;
  final bool isDefault;

  const Profile({
    required this.id,
    required this.name,
    required this.colorIndex,
    this.isDefault = false,
  });

  Profile copyWith({String? name, int? colorIndex}) => Profile(
        id: id,
        name: name ?? this.name,
        colorIndex: colorIndex ?? this.colorIndex,
        isDefault: isDefault,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'colorIndex': colorIndex,
        'isDefault': isDefault,
      };

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        id: json['id'] as String,
        name: json['name'] as String,
        colorIndex: json['colorIndex'] as int? ?? 0,
        isDefault: json['isDefault'] as bool? ?? false,
      );
}

class ProfileService {
  static final ProfileService instance = ProfileService._();
  ProfileService._();

  static const int maxProfiles = 5;

  late SharedPreferences _prefs;
  List<Profile> _profiles = [];
  String _activeProfileId = 'default';

  List<Profile> get profiles => List.unmodifiable(_profiles);
  String get activeProfileId => _activeProfileId;
  Profile get activeProfile => _profiles.firstWhere(
        (p) => p.id == _activeProfileId,
        orElse: () => _profiles.first,
      );

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs.getString('profiles');
    if (raw != null) {
      try {
        _profiles = (jsonDecode(raw) as List)
            .map((e) => Profile.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _profiles = [];
      }
    }
    if (_profiles.isEmpty) {
      _profiles = [
        const Profile(
            id: 'default', name: 'Profile 1', colorIndex: 0, isDefault: true),
      ];
      await _save();
    }
    _activeProfileId =
        _prefs.getString('active_profile') ?? _profiles.first.id;
  }

  /// Switch to a different profile. Saves current profile's data and loads
  /// the new profile's data into the standard SharedPreferences keys so that
  /// native (Kotlin) code and all services see the correct values.
  Future<void> selectProfile(String id) async {
    if (_activeProfileId == id) return;

    // Persist current profile's settings + continue-watching + music + audiobooks
    await SettingsService.instance.saveForProfile(_activeProfileId);
    await ContinueWatchingService.saveForProfile(_activeProfileId);
    await MusicPlayerService.saveForProfile(_activeProfileId);
    await AudiobookPlayerService.saveForProfile(_activeProfileId);

    // Switch
    _activeProfileId = id;
    await _prefs.setString('active_profile', id);

    // Load the new profile's data into the live keys
    await SettingsService.instance.loadForProfile(id);
    await ContinueWatchingService.loadForProfile(id);
    await MusicPlayerService.loadForProfile(id);
    await AudiobookPlayerService.loadForProfile(id);

    await SettingsService.instance.setPlaytorrioProfileSlotForTvProfile(id);
    if (await PlaytorrioCloudSyncService.instance.hasStoredSession()) {
      await PlaytorrioCloudSyncService.instance.pullOnStartup();
      await PlaytorrioCloudSyncService.instance.pushFullProfileBackup();
    }
  }

  Future<Profile?> addProfile() async {
    if (_profiles.length >= maxProfiles) return null;
    var number = _profiles.length + 1;
    var id = 'p$number';
    while (_profiles.any((p) => p.id == id)) {
      number++;
      id = 'p$number';
    }
    final colorIndex = _profiles.length % 5;
    final profile = Profile(
      id: id,
      name: 'Profile $number',
      colorIndex: colorIndex,
    );
    _profiles.add(profile);
    await _save();
    return profile;
  }

  Future<void> removeProfile(String id) async {
    if (id == 'default') return;
    _profiles.removeWhere((p) => p.id == id);
    if (_activeProfileId == id) {
      _activeProfileId = 'default';
      await _prefs.setString('active_profile', 'default');
    }
    // Clean up stored profile data
    await _prefs.remove('profile_settings_$id');
    await _prefs.remove('profile_cw_$id');
    await _prefs.remove('profile_music_$id');
    await _prefs.remove('profile_audiobook_$id');
    await _save();
  }

  Future<void> renameProfile(String id, String newName) async {
    final idx = _profiles.indexWhere((p) => p.id == id);
    if (idx < 0) return;
    _profiles[idx] = _profiles[idx].copyWith(name: newName);
    await _save();
  }

  Future<void> _save() async {
    await _prefs.setString(
        'profiles', jsonEncode(_profiles.map((p) => p.toJson()).toList()));
  }
}
