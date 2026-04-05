import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'live_tv_service.dart';
import 'stremio_addon_service.dart';
import 'stremio_live_tv_service.dart';

class SettingsService extends ChangeNotifier {
  static final SettingsService instance = SettingsService._();
  SettingsService._();

  late SharedPreferences _prefs;

  // --- Settings ---
  bool _streamingMode = false;
  bool get streamingMode => _streamingMode;

  bool _useDebrid = false;
  bool get useDebrid => _useDebrid;

  String _debridProvider = 'real-debrid'; // 'real-debrid' or 'torbox'
  String get debridProvider => _debridProvider;

  String _realDebridApiKey = '';
  String get realDebridApiKey => _realDebridApiKey;

  String _torboxApiKey = '';
  String get torboxApiKey => _torboxApiKey;

  int _cacheSizeMB = 512;
  int get cacheSizeMB => _cacheSizeMB;

  int _subtitleFontsize = 0; // 0=auto (VLC default)
  int get subtitleFontsize => _subtitleFontsize;

  List<String> _stremioAddons = [];
  List<String> get stremioAddons => List.unmodifiable(_stremioAddons);

  /// Rich addon objects: { baseUrl, manifest, name, icon }
  List<Map<String, dynamic>> _stremioAddonsRich = [];
  List<Map<String, dynamic>> get stremioAddonsRich => List.unmodifiable(_stremioAddonsRich);

  /// M3U playlist URL for Live TV (IPTV). Configured from the phone settings page.
  String _iptvM3uUrl = '';
  String get iptvM3uUrl => _iptvM3uUrl;

  /// XMLTV EPG URL (optional). Paired with the M3U `tvg-id` attributes.
  String _epgUrl = '';
  String get epgUrl => _epgUrl;

  /// When true, match Stremio TV channels to XMLTV by name/id when no manual link exists.
  bool _stremioEpgAutoMatch = false;
  bool get stremioEpgAutoMatch => _stremioEpgAutoMatch;

  void setStremioEpgAutoMatch(bool value) {
    _stremioEpgAutoMatch = value;
    _prefs.setBool('stremio_epg_auto_match', value);
    notifyListeners();
    _broadcastSettings();
  }

  /// When true, auto-select the best Stremio addon stream for movies/series (no list pick).
  bool _stremioAutoPickStreams = false;
  bool get stremioAutoPickStreams => _stremioAutoPickStreams;

  void setStremioAutoPickStreams(bool value) {
    _stremioAutoPickStreams = value;
    _prefs.setBool('stremio_auto_pick_streams', value);
    notifyListeners();
    _broadcastSettings();
  }

  /// Stremio TV channel → XMLTV `channel id` (manual EPG link). Key: `baseUrl|||channelId`
  final Map<String, String> _stremioEpgMap = {};

  Map<String, String> get stremioEpgMap => Map.unmodifiable(_stremioEpgMap);

  static String stremioEpgMapKey(String addonBaseUrl, String channelId) =>
      '$addonBaseUrl|||$channelId';

  String? stremioEpgMapping(String addonBaseUrl, String channelId) =>
      _stremioEpgMap[stremioEpgMapKey(addonBaseUrl, channelId)];

  void setStremioEpgMapping(String addonBaseUrl, String channelId, String? xmltvChannelId) {
    final k = stremioEpgMapKey(addonBaseUrl, channelId);
    if (xmltvChannelId == null || xmltvChannelId.isEmpty) {
      _stremioEpgMap.remove(k);
    } else {
      _stremioEpgMap[k] = xmltvChannelId;
    }
    _prefs.setString('live_tv_stremio_epg_map', jsonEncode(_stremioEpgMap));
    notifyListeners();
    _broadcastSettings();
  }

  List<String> _iptvFavoriteStreamUrls = [];
  List<String> get iptvFavoriteStreamUrls => List.unmodifiable(_iptvFavoriteStreamUrls);

  bool isIptvFavorite(String streamUrl) => _iptvFavoriteStreamUrls.contains(streamUrl);

  void setIptvFavorite(String streamUrl, bool favorite) {
    if (favorite) {
      if (!_iptvFavoriteStreamUrls.contains(streamUrl)) {
        _iptvFavoriteStreamUrls.add(streamUrl);
      }
    } else {
      _iptvFavoriteStreamUrls.remove(streamUrl);
    }
    _prefs.setStringList('iptv_favorite_stream_urls', _iptvFavoriteStreamUrls);
    notifyListeners();
    _broadcastSettings();
  }

  void toggleIptvFavorite(String streamUrl) {
    setIptvFavorite(streamUrl, !isIptvFavorite(streamUrl));
  }

  /// Notifier for addon changes (catalogs, home screen, etc.)
  static final ValueNotifier<int> addonChangeNotifier = ValueNotifier<int>(0);

  // --- Server ---
  HttpServer? _server;
  int? _serverPort;
  String? _localIp;
  int? get serverPort => _serverPort;
  String? get localIp => _localIp;
  String? get settingsUrl =>
      _localIp != null && _serverPort != null ? 'http://$_localIp:$_serverPort' : null;

  final List<WebSocket> _wsClients = [];

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _streamingMode = _prefs.getBool('streaming_mode') ?? false;
    _useDebrid = _prefs.getBool('use_debrid') ?? false;
    _debridProvider = _prefs.getString('debrid_provider') ?? 'real-debrid';
    _realDebridApiKey = _prefs.getString('rd_api_key') ?? '';
    _torboxApiKey = _prefs.getString('tb_api_key') ?? '';
    _cacheSizeMB = _prefs.getInt('cache_size_mb') ?? 512;
    _subtitleFontsize = _prefs.getInt('subtitle_fontsize') ?? 0;
    // Migrate old absolute pixel values to new relative divisor values
    const oldToNewSubtitleSize = {28: 14, 36: 10, 48: 7};
    if (oldToNewSubtitleSize.containsKey(_subtitleFontsize)) {
      _subtitleFontsize = oldToNewSubtitleSize[_subtitleFontsize]!;
      _prefs.setInt('subtitle_fontsize', _subtitleFontsize);
    }
    _iptvM3uUrl = _prefs.getString('iptv_m3u_url') ?? '';
    _epgUrl = _prefs.getString('epg_url') ?? '';
    _stremioEpgAutoMatch = _prefs.getBool('stremio_epg_auto_match') ?? false;
    _stremioAutoPickStreams = _prefs.getBool('stremio_auto_pick_streams') ?? false;
    final epgMapRaw = _prefs.getString('live_tv_stremio_epg_map');
    if (epgMapRaw != null && epgMapRaw.isNotEmpty) {
      try {
        final m = jsonDecode(epgMapRaw) as Map<String, dynamic>;
        _stremioEpgMap
          ..clear()
          ..addAll(m.map((k, v) => MapEntry(k, v.toString())));
      } catch (_) {}
    }
    _iptvFavoriteStreamUrls = _prefs.getStringList('iptv_favorite_stream_urls') ?? [];
    _stremioAddons = _prefs.getStringList('stremio_addons') ?? [];
    // Also keep a JSON copy for native Kotlin to read
    _prefs.setString('stremio_addons_json', jsonEncode(_stremioAddons));
    // Load rich addon objects
    final richList = _prefs.getStringList('stremio_addons_rich') ?? [];
    _stremioAddonsRich = richList
        .map((s) { try { return jsonDecode(s) as Map<String, dynamic>; } catch (_) { return null; } })
        .whereType<Map<String, dynamic>>()
        .toList();
    // Fetch manifests for any plain addon URLs missing rich data
    unawaited(_syncRichAddons());
    // Sync subtitle-capable addon URLs for native player
    _syncSubtitleAddonUrls();
  }

  /// Fetches manifests for any addon URLs in the plain list that don't have
  /// a corresponding rich entry. This bridges phone-synced URLs with the
  /// rich addon data needed for catalogs, search, and meta.
  Future<void> _syncRichAddons() async {
    final richBaseUrls = _stremioAddonsRich
        .map((a) => a['baseUrl']?.toString() ?? '')
        .toSet();

    for (final addonUrl in List.of(_stremioAddons)) {
      // Normalize to the form used by fetchManifestRich: strip trailing slash
      final compareUrl = addonUrl.endsWith('/')
          ? addonUrl.substring(0, addonUrl.length - 1)
          : addonUrl;
      if (richBaseUrls.contains(compareUrl) || richBaseUrls.contains(addonUrl)) {
        continue;
      }
      try {
        final rich = await StremioAddonService.fetchManifestRich(addonUrl);
        if (rich != null) {
          saveStremioAddonRich(rich);
          debugPrint('[SettingsService] Synced rich addon: ${rich['name']}');
        }
      } catch (e) {
        debugPrint('[SettingsService] Failed to sync addon $addonUrl: $e');
      }
    }
    // Update subtitle-capable addon list after syncing
    _syncSubtitleAddonUrls();
  }

  void setStreamingMode(bool value) {
    _streamingMode = value;
    _prefs.setBool('streaming_mode', value);
    notifyListeners();
    _broadcastSettings();
  }

  void setUseDebrid(bool value) {
    _useDebrid = value;
    _prefs.setBool('use_debrid', value);
    notifyListeners();
    _broadcastSettings();
  }

  void setDebridProvider(String value) {
    _debridProvider = value;
    _prefs.setString('debrid_provider', value);
    notifyListeners();
    _broadcastSettings();
  }

  void setRealDebridApiKey(String value) {
    _realDebridApiKey = value;
    _prefs.setString('rd_api_key', value);
    notifyListeners();
    _broadcastSettings();
  }

  void setTorboxApiKey(String value) {
    _torboxApiKey = value;
    _prefs.setString('tb_api_key', value);
    notifyListeners();
    _broadcastSettings();
  }

  void setCacheSizeMB(int value) {
    _cacheSizeMB = value;
    _prefs.setInt('cache_size_mb', value);
    notifyListeners();
    _broadcastSettings();
  }

  void setSubtitleFontsize(int value) {
    _subtitleFontsize = value;
    _prefs.setInt('subtitle_fontsize', value);
    notifyListeners();
    _broadcastSettings();
  }

  void setIptvM3uUrl(String value) {
    _iptvM3uUrl = value.trim();
    _prefs.setString('iptv_m3u_url', _iptvM3uUrl);
    LiveTvService.instance.clearCache();
    notifyListeners();
    _broadcastSettings();
  }

  void setEpgUrl(String value) {
    _epgUrl = value.trim();
    _prefs.setString('epg_url', _epgUrl);
    LiveTvService.instance.clearCache();
    notifyListeners();
    _broadcastSettings();
  }

  void addStremioAddon(String url) {
    final normalized = _normalizeAddonUrl(url);
    if (normalized.isEmpty || _stremioAddons.contains(normalized)) return;
    _stremioAddons.add(normalized);
    _prefs.setStringList('stremio_addons', _stremioAddons);
    _prefs.setString('stremio_addons_json', jsonEncode(_stremioAddons));
    // Fetch manifest for the newly added addon
    unawaited(_syncRichAddons());
    notifyListeners();
    _broadcastSettings();
  }

  void removeStremioAddon(int index) {
    if (index < 0 || index >= _stremioAddons.length) return;
    _stremioAddons.removeAt(index);
    _prefs.setStringList('stremio_addons', _stremioAddons);
    _prefs.setString('stremio_addons_json', jsonEncode(_stremioAddons));
    _syncSubtitleAddonUrls();
    notifyListeners();
    _broadcastSettings();
  }

  /// Write only subtitle-capable addon URLs to SharedPreferences for native player.
  void _syncSubtitleAddonUrls() {
    final subtitleAddons = StremioAddonService.getAddonsForResource('subtitles');
    final urls = subtitleAddons
        .map((a) => _normalizeAddonUrl(a['baseUrl']?.toString() ?? ''))
        .where((u) => u.isNotEmpty)
        .toList();
    _prefs.setString('stremio_subtitle_addons_json', jsonEncode(urls));
  }

  /// Save a rich addon object { baseUrl, manifest, name, icon }.
  void saveStremioAddonRich(Map<String, dynamic> addon) {
    final baseUrl = addon['baseUrl'] as String? ?? '';
    if (baseUrl.isEmpty) return;
    _stremioAddonsRich.removeWhere((a) => a['baseUrl'] == baseUrl);
    _stremioAddonsRich.add(addon);
    _prefs.setStringList('stremio_addons_rich',
        _stremioAddonsRich.map((e) => jsonEncode(e)).toList());
    // Also keep the plain URL list in sync for stream fetching
    final normalizedUrl = _normalizeAddonUrl(baseUrl);
    if (!_stremioAddons.contains(normalizedUrl)) {
      _stremioAddons.add(normalizedUrl);
      _prefs.setStringList('stremio_addons', _stremioAddons);
      _prefs.setString('stremio_addons_json', jsonEncode(_stremioAddons));
    }
    _syncSubtitleAddonUrls();
    addonChangeNotifier.value++;
    notifyListeners();
    _broadcastSettings();
  }

  /// Remove a rich addon by baseUrl.
  void removeStremioAddonRich(String baseUrl) {
    _stremioAddonsRich.removeWhere((a) => a['baseUrl'] == baseUrl);
    _prefs.setStringList('stremio_addons_rich',
        _stremioAddonsRich.map((e) => jsonEncode(e)).toList());
    // Also remove from plain URL list
    final normalizedUrl = _normalizeAddonUrl(baseUrl);
    _stremioAddons.remove(normalizedUrl);
    _prefs.setStringList('stremio_addons', _stremioAddons);
    _prefs.setString('stremio_addons_json', jsonEncode(_stremioAddons));
    _syncSubtitleAddonUrls();
    addonChangeNotifier.value++;
    notifyListeners();
    _broadcastSettings();
  }

  /// Normalize addon URL: strip manifest.json, convert stremio:// to https://, ensure trailing /
  String _normalizeAddonUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return '';
    // Convert stremio:// protocol to https://
    if (u.startsWith('stremio://')) {
      u = u.replaceFirst('stremio://', 'https://');
    }
    // Remove trailing manifest.json
    if (u.endsWith('/manifest.json')) {
      u = u.substring(0, u.length - '/manifest.json'.length);
    }
    // Ensure trailing slash
    if (!u.endsWith('/')) u += '/';
    return u;
  }

  Map<String, dynamic> _toJson() => {
        'streaming_mode': _streamingMode,
        'use_debrid': _useDebrid,
        'debrid_provider': _debridProvider,
        'rd_api_key': _realDebridApiKey,
        'tb_api_key': _torboxApiKey,
        'cache_size_mb': _cacheSizeMB,
        'subtitle_fontsize': _subtitleFontsize,
        'stremio_addons': _stremioAddons,
        'iptv_m3u_url': _iptvM3uUrl,
        'epg_url': _epgUrl,
        'stremio_epg_auto_match': _stremioEpgAutoMatch,
        'stremio_auto_pick_streams': _stremioAutoPickStreams,
        'live_tv_stremio_epg_map': _stremioEpgMap,
        'iptv_favorite_stream_urls': _iptvFavoriteStreamUrls,
      };

  /// Persist every profile-scoped setting into a single JSON blob keyed by
  /// the profile id so it can be restored later when switching back.
  Future<void> saveForProfile(String profileId) async {
    final data = <String, dynamic>{
      ..._toJson(),
      'stremio_addons_rich':
          _stremioAddonsRich.map((e) => jsonEncode(e)).toList(),
    };
    await _prefs.setString('profile_settings_$profileId', jsonEncode(data));
  }

  /// Load a previously-saved profile blob and write its values into the
  /// standard (un-prefixed) SharedPreferences keys so that native code and
  /// all services pick them up transparently.
  Future<void> loadForProfile(String profileId) async {
    final raw = _prefs.getString('profile_settings_$profileId');
    if (raw != null) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        _applyJson(json);
        if (json.containsKey('stremio_addons_rich')) {
          final richList = (json['stremio_addons_rich'] as List).cast<String>();
          _stremioAddonsRich = richList
              .map((s) {
                try {
                  return jsonDecode(s) as Map<String, dynamic>;
                } catch (_) {
                  return null;
                }
              })
              .whereType<Map<String, dynamic>>()
              .toList();
          _prefs.setStringList('stremio_addons_rich', richList);
        }
        if (!json.containsKey('iptv_m3u_url')) {
          _iptvM3uUrl = '';
          _prefs.setString('iptv_m3u_url', '');
        }
        if (!json.containsKey('epg_url')) {
          _epgUrl = '';
          _prefs.setString('epg_url', '');
        }
        if (!json.containsKey('stremio_epg_auto_match')) {
          _stremioEpgAutoMatch = false;
          _prefs.setBool('stremio_epg_auto_match', false);
        }
        if (!json.containsKey('stremio_auto_pick_streams')) {
          _stremioAutoPickStreams = false;
          _prefs.setBool('stremio_auto_pick_streams', false);
        }
        if (!json.containsKey('live_tv_stremio_epg_map')) {
          _stremioEpgMap.clear();
          _prefs.setString('live_tv_stremio_epg_map', '{}');
        }
        if (!json.containsKey('iptv_favorite_stream_urls')) {
          _iptvFavoriteStreamUrls = [];
          _prefs.setStringList('iptv_favorite_stream_urls', []);
        }
        _syncSubtitleAddonUrls();
        LiveTvService.instance.clearCache();
        notifyListeners();
      } catch (_) {
        _resetToDefaults();
      }
    } else {
      // Brand-new profile — start with defaults
      _resetToDefaults();
    }
  }

  void _resetToDefaults() {
    _streamingMode = false;
    _useDebrid = false;
    _debridProvider = 'real-debrid';
    _realDebridApiKey = '';
    _torboxApiKey = '';
    _cacheSizeMB = 512;
    _subtitleFontsize = 0;
    _stremioAddons = [];
    _stremioAddonsRich = [];
    _iptvM3uUrl = '';
    _epgUrl = '';
    _prefs.setBool('streaming_mode', false);
    _prefs.setBool('use_debrid', false);
    _prefs.setString('debrid_provider', 'real-debrid');
    _prefs.setString('rd_api_key', '');
    _prefs.setString('tb_api_key', '');
    _prefs.setInt('cache_size_mb', 512);
    _prefs.setInt('subtitle_fontsize', 0);
    _prefs.setStringList('stremio_addons', []);
    _prefs.setString('stremio_addons_json', '[]');
    _prefs.setStringList('stremio_addons_rich', []);
    _prefs.setString('stremio_subtitle_addons_json', '[]');
    _iptvM3uUrl = '';
    _epgUrl = '';
    _stremioEpgAutoMatch = false;
    _stremioEpgMap.clear();
    _iptvFavoriteStreamUrls = [];
    _prefs.setString('iptv_m3u_url', '');
    _prefs.setString('epg_url', '');
    _prefs.setBool('stremio_epg_auto_match', false);
    _stremioAutoPickStreams = false;
    _prefs.setBool('stremio_auto_pick_streams', false);
    _prefs.setString('live_tv_stremio_epg_map', '{}');
    _prefs.setStringList('iptv_favorite_stream_urls', []);
    notifyListeners();
  }

  void _applyJson(Map<String, dynamic> json) {
    if (json.containsKey('streaming_mode')) {
      _streamingMode = json['streaming_mode'] as bool;
      _prefs.setBool('streaming_mode', _streamingMode);
    }
    if (json.containsKey('use_debrid')) {
      _useDebrid = json['use_debrid'] as bool;
      _prefs.setBool('use_debrid', _useDebrid);
    }
    if (json.containsKey('debrid_provider')) {
      _debridProvider = json['debrid_provider'] as String;
      _prefs.setString('debrid_provider', _debridProvider);
    }
    if (json.containsKey('rd_api_key')) {
      _realDebridApiKey = json['rd_api_key'] as String;
      _prefs.setString('rd_api_key', _realDebridApiKey);
    }
    if (json.containsKey('tb_api_key')) {
      _torboxApiKey = json['tb_api_key'] as String;
      _prefs.setString('tb_api_key', _torboxApiKey);
    }
    if (json.containsKey('cache_size_mb')) {
      _cacheSizeMB = json['cache_size_mb'] as int;
      _prefs.setInt('cache_size_mb', _cacheSizeMB);
    }
    if (json.containsKey('subtitle_fontsize')) {
      var size = json['subtitle_fontsize'] as int;
      // Migrate old absolute pixel values to new relative divisor values
      const oldToNew = {28: 14, 36: 10, 48: 7};
      if (oldToNew.containsKey(size)) size = oldToNew[size]!;
      _subtitleFontsize = size;
      _prefs.setInt('subtitle_fontsize', _subtitleFontsize);
    }
    if (json.containsKey('stremio_addons')) {
      _stremioAddons = (json['stremio_addons'] as List).cast<String>();
      _prefs.setStringList('stremio_addons', _stremioAddons);
      _prefs.setString('stremio_addons_json', jsonEncode(_stremioAddons));
      // Remove rich entries for addons no longer in the plain list
      final normalizedSet = _stremioAddons.toSet();
      _stremioAddonsRich.removeWhere((a) {
        final base = a['baseUrl']?.toString() ?? '';
        return !normalizedSet.contains(_normalizeAddonUrl(base));
      });
      _prefs.setStringList('stremio_addons_rich',
          _stremioAddonsRich.map((e) => jsonEncode(e)).toList());
      // Fetch manifests for newly added URLs
      unawaited(_syncRichAddons());
    }
    if (json.containsKey('iptv_m3u_url')) {
      _iptvM3uUrl = (json['iptv_m3u_url'] as String? ?? '').trim();
      _prefs.setString('iptv_m3u_url', _iptvM3uUrl);
      LiveTvService.instance.clearCache();
    }
    if (json.containsKey('epg_url')) {
      _epgUrl = (json['epg_url'] as String? ?? '').trim();
      _prefs.setString('epg_url', _epgUrl);
      LiveTvService.instance.clearCache();
    }
    if (json.containsKey('stremio_epg_auto_match')) {
      _stremioEpgAutoMatch = json['stremio_epg_auto_match'] as bool;
      _prefs.setBool('stremio_epg_auto_match', _stremioEpgAutoMatch);
    }
    if (json.containsKey('stremio_auto_pick_streams')) {
      _stremioAutoPickStreams = json['stremio_auto_pick_streams'] as bool;
      _prefs.setBool('stremio_auto_pick_streams', _stremioAutoPickStreams);
    }
    if (json.containsKey('live_tv_stremio_epg_map')) {
      final m = json['live_tv_stremio_epg_map'];
      _stremioEpgMap.clear();
      if (m is Map) {
        m.forEach((k, v) {
          if (k != null && v != null) {
            _stremioEpgMap[k.toString()] = v.toString();
          }
        });
      }
      _prefs.setString('live_tv_stremio_epg_map', jsonEncode(_stremioEpgMap));
      StremioLiveTvService.instance.clearCache();
    }
    if (json.containsKey('iptv_favorite_stream_urls')) {
      _iptvFavoriteStreamUrls =
          (json['iptv_favorite_stream_urls'] as List).map((e) => e.toString()).toList();
      _prefs.setStringList('iptv_favorite_stream_urls', _iptvFavoriteStreamUrls);
    }
    notifyListeners();
  }

  void _broadcastSettings() {
    final msg = jsonEncode({'type': 'settings', 'data': _toJson()});
    for (final ws in List.of(_wsClients)) {
      try {
        ws.add(msg);
      } catch (_) {
        _wsClients.remove(ws);
      }
    }
  }

  // --- Embedded HTTP + WebSocket server ---

  Future<void> startServer() async {
    if (_server != null) return;

    // Primary: connected-socket trick — works on ALL platforms & connection types
    // (WiFi, ethernet, USB tethering, etc.)
    // Connects a TCP socket toward a public IP; OS should reveal the local IP that
    // would route there. Connection is closed immediately, no data is sent.
    //
    // Dart SDK bug: on some platforms `Socket.address` wrongly equals
    // `Socket.remoteAddress`, so the QR showed 8.8.8.8 instead of the LAN IP.
    // Only accept when local ≠ remote and the address looks like a private LAN IP.
    try {
      final socket = await Socket.connect('8.8.8.8', 53,
          timeout: const Duration(seconds: 2));
      final localAddr = socket.address.address;
      final remoteAddr = socket.remoteAddress.address;
      socket.destroy();
      if (localAddr != remoteAddr &&
          localAddr != '0.0.0.0' &&
          localAddr != '127.0.0.1' &&
          _isPrivateLanIpv4(localAddr)) {
        _localIp = localAddr;
      }
    } catch (_) {}

    // Fallback 1: scan network interfaces (works on Windows, sometimes Android)
    if (_localIp == null) {
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        final lanIps = <String>[];
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            final ip = addr.address;
            if (!addr.isLoopback &&
                ip != '0.0.0.0' &&
                !ip.startsWith('169.254.') &&
                !ip.startsWith('127.')) {
              lanIps.add(ip);
            }
          }
        }
        _localIp = _pickBestLanIp(lanIps);
      } catch (_) {}
    }

    // Fallback 2: network_info_plus WiFi IP (reliable on Android WiFi)
    if (_localIp == null) {
      try {
        final wifiIp = await NetworkInfo().getWifiIP();
        if (wifiIp != null &&
            wifiIp.isNotEmpty &&
            wifiIp != '0.0.0.0' &&
            !wifiIp.startsWith('169.254.')) {
          _localIp = wifiIp;
        }
      } catch (_) {}
    }

    _localIp ??= 'localhost';

    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _serverPort = _server!.port;
    notifyListeners();

    _server!.listen((HttpRequest request) {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        _handleWebSocket(request);
      } else {
        _handleHttp(request);
      }
    });
  }

  /// True for RFC1918 / typical LAN IPv4 (what we want in the remote-settings QR).
  static bool _isPrivateLanIpv4(String ip) {
    if (ip.startsWith('10.')) return true;
    if (ip.startsWith('192.168.')) return true;
    if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) return true;
    return false;
  }

  /// Pick the most likely reachable LAN IP from a list of candidates.
  static String? _pickBestLanIp(List<String> ips) {
    if (ips.isEmpty) return null;
    // 192.168.x.x — most common home/office networks
    for (final ip in ips) {
      if (ip.startsWith('192.168.')) return ip;
    }
    // 10.x.x.x — corporate / some ISPs
    for (final ip in ips) {
      if (ip.startsWith('10.')) return ip;
    }
    // 172.16-31.x.x — private range
    for (final ip in ips) {
      if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) return ip;
    }
    // Anything else that made it through the filters
    return ips.first;
  }

  void _handleHttp(HttpRequest request) {
    final response = request.response;
    response.headers.set('Content-Type', 'text/html; charset=utf-8');
    response.headers.set('Cache-Control', 'no-cache');
    response.write(_settingsHtml());
    response.close();
  }

  Future<void> _handleWebSocket(HttpRequest request) async {
    final ws = await WebSocketTransformer.upgrade(request);
    _wsClients.add(ws);

    // Send current settings immediately
    ws.add(jsonEncode({'type': 'settings', 'data': _toJson()}));

    ws.listen(
      (data) {
        try {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          if (msg['type'] == 'update') {
            _applyJson(msg['data'] as Map<String, dynamic>);
            // Echo to all other clients
            _broadcastSettings();
          }
        } catch (_) {}
      },
      onDone: () => _wsClients.remove(ws),
      onError: (_) => _wsClients.remove(ws),
    );
  }

  Future<void> stopServer() async {
    for (final ws in _wsClients) {
      try {
        await ws.close();
      } catch (_) {}
    }
    _wsClients.clear();
    await _server?.close(force: true);
    _server = null;
    _serverPort = null;
  }

  String _settingsHtml() => '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
<title>PlayTorrio Settings</title>
<style>
  :root {
    --bg: #0A0A0F;
    --surface: #12121A;
    --surface-light: #1A1A2E;
    --purple: #6C3FB5;
    --purple-light: #8B5CF6;
    --text: #E8E8F0;
    --text-sec: #9898B0;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
    padding: 24px 16px;
  }
  .header {
    text-align: center;
    margin-bottom: 32px;
  }
  .header h1 {
    font-size: 22px;
    color: var(--purple-light);
    font-weight: 700;
  }
  .header p {
    font-size: 13px;
    color: var(--text-sec);
    margin-top: 4px;
  }
  .status {
    text-align: center;
    font-size: 12px;
    padding: 8px;
    border-radius: 8px;
    margin-bottom: 24px;
  }
  .status.connected { background: #0d2818; color: #4ade80; }
  .status.disconnected { background: #2d1215; color: #f87171; }
  .card {
    background: var(--surface);
    border-radius: 12px;
    padding: 16px;
    margin-bottom: 12px;
  }
  .setting-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .setting-info h3 {
    font-size: 16px;
    font-weight: 600;
  }
  .setting-info p {
    font-size: 13px;
    color: var(--text-sec);
    margin-top: 2px;
  }
  /* Toggle switch */
  .toggle {
    position: relative;
    width: 52px;
    height: 28px;
    flex-shrink: 0;
    margin-left: 16px;
  }
  .toggle input { opacity: 0; width: 0; height: 0; }
  .toggle .slider {
    position: absolute;
    inset: 0;
    background: var(--surface-light);
    border-radius: 14px;
    cursor: pointer;
    transition: background 0.2s;
  }
  .toggle .slider::before {
    content: '';
    position: absolute;
    width: 22px;
    height: 22px;
    left: 3px;
    top: 3px;
    background: var(--text-sec);
    border-radius: 50%;
    transition: transform 0.2s, background 0.2s;
  }
  .toggle input:checked + .slider {
    background: var(--purple);
  }
  .toggle input:checked + .slider::before {
    transform: translateX(24px);
    background: var(--text);
  }
  select {
    background: var(--surface-light);
    color: var(--text);
    border: 1px solid #333;
    border-radius: 8px;
    padding: 8px 12px;
    font-size: 14px;
    width: 100%;
    margin-top: 8px;
    outline: none;
  }
  select:focus { border-color: var(--purple-light); }
  .text-input {
    background: var(--surface-light);
    color: var(--text);
    border: 1px solid #333;
    border-radius: 8px;
    padding: 10px 12px;
    font-size: 14px;
    width: 100%;
    margin-top: 8px;
    outline: none;
    font-family: monospace;
  }
  .text-input:focus { border-color: var(--purple-light); }
  .text-input::placeholder { color: var(--text-sec); }
  .section-title {
    font-size: 13px;
    color: var(--purple-light);
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin: 20px 0 8px;
  }
  .hidden { display: none; }
  .addon-input-row {
    display: flex;
    gap: 8px;
    margin-top: 8px;
  }
  .addon-input-row .text-input {
    flex: 1;
    margin-top: 0;
  }
  .addon-btn {
    background: var(--purple);
    color: #fff;
    border: none;
    border-radius: 8px;
    padding: 10px 16px;
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
  }
  .addon-btn:active { opacity: 0.8; }
  .addon-list { margin-top: 12px; }
  .addon-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: var(--surface-light);
    border-radius: 8px;
    padding: 10px 12px;
    margin-bottom: 6px;
    word-break: break-all;
  }
  .addon-item span {
    font-size: 13px;
    color: var(--text);
    flex: 1;
    margin-right: 8px;
  }
  .addon-remove {
    background: #3d1215;
    color: #f87171;
    border: none;
    border-radius: 6px;
    padding: 4px 10px;
    font-size: 12px;
    cursor: pointer;
  }
  .export-import-row {
    display: flex;
    gap: 8px;
  }
  .export-import-row button {
    flex: 1;
    padding: 12px;
    font-size: 14px;
    font-weight: 600;
    border: none;
    border-radius: 8px;
    cursor: pointer;
  }
  .btn-export {
    background: var(--surface-light);
    color: var(--text);
    border: 1px solid #333 !important;
  }
  .btn-import {
    background: var(--purple);
    color: #fff;
  }
  .btn-export:active, .btn-import:active { opacity: 0.8; }
  .import-file { display: none; }
</style>
</head>
<body>
  <div class="header">
    <h1>PlayTorrio Settings</h1>
    <p>Changes sync instantly to your TV</p>
  </div>
  <div id="status" class="status disconnected">Connecting...</div>

  <div class="card">
    <div class="setting-row">
      <div class="setting-info">
        <h3>Streaming Mode</h3>
        <p>Use direct HTTP links instead of torrents</p>
      </div>
      <label class="toggle">
        <input type="checkbox" id="streamingMode">
        <span class="slider"></span>
      </label>
    </div>
  </div>

  <div class="section-title">Performance</div>

  <div class="card">
    <div class="setting-info">
      <h3>RAM Cache Size</h3>
      <p>How much RAM TorrServer can use for buffering</p>
    </div>
    <select id="cacheSizeMB">
      <option value="128">128 MB</option>
      <option value="256">256 MB</option>
      <option value="512">512 MB (Default)</option>
      <option value="768">768 MB</option>
      <option value="1024">1024 MB</option>
    </select>
  </div>

  <div class="section-title">Debrid</div>

  <div class="card">
    <div class="setting-row">
      <div class="setting-info">
        <h3>Use Debrid for Torrents</h3>
        <p>Stream torrents via a debrid service instead of P2P</p>
      </div>
      <label class="toggle">
        <input type="checkbox" id="useDebrid">
        <span class="slider"></span>
      </label>
    </div>
  </div>

  <div id="debridOptions" class="hidden">
    <div class="card">
      <div class="setting-info">
        <h3>Debrid Provider</h3>
        <p>Choose your debrid service</p>
      </div>
      <select id="debridProvider">
        <option value="real-debrid">Real-Debrid</option>
        <option value="torbox">TorBox</option>
      </select>
    </div>

    <div class="card" id="rdKeyCard">
      <div class="setting-info">
        <h3>Real-Debrid API Key</h3>
        <p>Get it from real-debrid.com/apitoken</p>
      </div>
      <input type="text" class="text-input" id="rdApiKey" placeholder="Paste your API key here" autocomplete="off">
    </div>

    <div class="card hidden" id="tbKeyCard">
      <div class="setting-info">
        <h3>TorBox API Key</h3>
        <p>Get it from torbox.app/settings</p>
      </div>
      <input type="text" class="text-input" id="tbApiKey" placeholder="Paste your API key here" autocomplete="off">
    </div>
  </div>

  <div class="section-title">Player</div>

  <div class="card">
    <div class="setting-info">
      <h3>Subtitle Size</h3>
      <p>Adjust subtitle font size in the player</p>
    </div>
    <select id="subtitleFontsize">
      <option value="0">Default</option>
      <option value="14">Large</option>
      <option value="10">Extra Large</option>
      <option value="7">Huge</option>
    </select>
  </div>

  <div class="section-title">Live TV (IPTV)</div>

  <div class="card">
    <div class="setting-info">
      <h3>M3U playlist URL</h3>
      <p>HTTP(S) link to your IPTV M3U playlist. Channels appear under Live TV on the TV app.</p>
    </div>
    <input type="text" class="text-input" id="iptvM3uUrl" placeholder="https://example.com/playlist.m3u" autocomplete="off">
  </div>

  <div class="card">
    <div class="setting-info">
      <h3>EPG (XMLTV) URL</h3>
      <p>Optional guide data (XMLTV). Must match <code style="color:var(--purple-light)">tvg-id</code> in your M3U.</p>
    </div>
    <input type="text" class="text-input" id="epgUrl" placeholder="https://example.com/epg.xml" autocomplete="off">
  </div>

  <div class="card">
    <div class="setting-row">
      <div class="setting-info">
        <h3>Auto-link Stremio channels to EPG</h3>
        <p>Guess XMLTV channel from name when no manual link is set (needs EPG URL above)</p>
      </div>
      <label class="toggle">
        <input type="checkbox" id="stremioEpgAutoMatch">
        <span class="slider"></span>
      </label>
    </div>
  </div>

  <div class="card">
    <div class="setting-row">
      <div class="setting-info">
        <h3>Auto-play movie &amp; episodes</h3>
        <p>When you choose a movie or episode, play the first link (PlayTorrio first if any, else first Stremio).</p>
      </div>
      <label class="toggle">
        <input type="checkbox" id="stremioAutoPickStreams">
        <span class="slider"></span>
      </label>
    </div>
  </div>

  <div class="section-title">Stremio Addons</div>

  <div class="card">
    <div class="setting-info">
      <h3>Subtitle Addons</h3>
      <p>Add Stremio addon URLs for extra subtitle sources</p>
    </div>
    <div class="addon-input-row">
      <input type="text" class="text-input" id="addonInput" placeholder="Paste addon URL or stremio:// link" autocomplete="off">
      <button class="addon-btn" id="addAddonBtn">Add</button>
    </div>
    <div id="addonList" class="addon-list"></div>
  </div>

  <div class="section-title">Backup</div>

  <div class="card">
    <div class="setting-info">
      <h3>Export / Import Settings</h3>
      <p>Save or restore all settings including addons and API keys</p>
    </div>
    <div class="export-import-row" style="margin-top:12px">
      <button class="btn-export" id="exportBtn">Export JSON</button>
      <button class="btn-import" id="importBtn">Import JSON</button>
    </div>
    <input type="file" accept=".json,application/json" class="import-file" id="importFile">
  </div>

  <script>
    let ws;
    let reconnectTimer;
    const statusEl = document.getElementById('status');
    let currentAddons = [];
    let liveTvStremioEpgMap = {};
    let iptvFavoriteUrls = [];

    function renderAddons() {
      const list = document.getElementById('addonList');
      list.innerHTML = '';
      currentAddons.forEach((url, i) => {
        const item = document.createElement('div');
        item.className = 'addon-item';
        item.innerHTML = '<span>' + url.replace(/</g,'&lt;') + '</span><button class="addon-remove" data-index="' + i + '">Remove</button>';
        list.appendChild(item);
      });
      list.querySelectorAll('.addon-remove').forEach(btn => {
        btn.addEventListener('click', () => {
          const idx = parseInt(btn.dataset.index);
          currentAddons.splice(idx, 1);
          sendUpdate({ stremio_addons: currentAddons });
          renderAddons();
        });
      });
    }

    function normalizeAddonUrl(url) {
      let u = url.trim();
      if (!u) return '';
      if (u.startsWith('stremio://')) u = u.replace('stremio://', 'https://');
      if (u.endsWith('/manifest.json')) u = u.slice(0, -'/manifest.json'.length);
      if (!u.endsWith('/')) u += '/';
      return u;
    }

    function updateDebridUI() {
      const on = document.getElementById('useDebrid').checked;
      document.getElementById('debridOptions').classList.toggle('hidden', !on);
      const provider = document.getElementById('debridProvider').value;
      document.getElementById('rdKeyCard').classList.toggle('hidden', provider !== 'real-debrid');
      document.getElementById('tbKeyCard').classList.toggle('hidden', provider !== 'torbox');
    }

    function sendUpdate(data) {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'update', data }));
      }
    }

    function connect() {
      const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      ws = new WebSocket(proto + '//' + location.host + '/ws');

      ws.onopen = () => {
        statusEl.textContent = 'Connected';
        statusEl.className = 'status connected';
      };

      ws.onclose = () => {
        statusEl.textContent = 'Disconnected \\u2014 reconnecting...';
        statusEl.className = 'status disconnected';
        reconnectTimer = setTimeout(connect, 2000);
      };

      ws.onerror = () => ws.close();

      ws.onmessage = (e) => {
        const msg = JSON.parse(e.data);
        if (msg.type === 'settings') {
          document.getElementById('streamingMode').checked = msg.data.streaming_mode;
          document.getElementById('useDebrid').checked = msg.data.use_debrid;
          document.getElementById('debridProvider').value = msg.data.debrid_provider;
          document.getElementById('rdApiKey').value = msg.data.rd_api_key || '';
          document.getElementById('tbApiKey').value = msg.data.tb_api_key || '';
          document.getElementById('cacheSizeMB').value = msg.data.cache_size_mb || 512;
          document.getElementById('subtitleFontsize').value = msg.data.subtitle_fontsize || 0;
          document.getElementById('iptvM3uUrl').value = msg.data.iptv_m3u_url || '';
          document.getElementById('epgUrl').value = msg.data.epg_url || '';
          document.getElementById('stremioEpgAutoMatch').checked = !!msg.data.stremio_epg_auto_match;
          document.getElementById('stremioAutoPickStreams').checked = !!msg.data.stremio_auto_pick_streams;
          currentAddons = msg.data.stremio_addons || [];
          liveTvStremioEpgMap = msg.data.live_tv_stremio_epg_map || {};
          iptvFavoriteUrls = msg.data.iptv_favorite_stream_urls || [];
          renderAddons();
          updateDebridUI();
        }
      };
    }

    document.getElementById('streamingMode').addEventListener('change', (e) => {
      sendUpdate({ streaming_mode: e.target.checked });
    });

    document.getElementById('useDebrid').addEventListener('change', (e) => {
      sendUpdate({ use_debrid: e.target.checked });
      updateDebridUI();
    });

    document.getElementById('debridProvider').addEventListener('change', (e) => {
      sendUpdate({ debrid_provider: e.target.value });
      updateDebridUI();
    });

    document.getElementById('cacheSizeMB').addEventListener('change', (e) => {
      sendUpdate({ cache_size_mb: parseInt(e.target.value) });
    });

    document.getElementById('subtitleFontsize').addEventListener('change', (e) => {
      sendUpdate({ subtitle_fontsize: parseInt(e.target.value) });
    });

    let iptvTimer, epgTimer;
    document.getElementById('iptvM3uUrl').addEventListener('input', (e) => {
      clearTimeout(iptvTimer);
      iptvTimer = setTimeout(() => sendUpdate({ iptv_m3u_url: e.target.value }), 500);
    });
    document.getElementById('epgUrl').addEventListener('input', (e) => {
      clearTimeout(epgTimer);
      epgTimer = setTimeout(() => sendUpdate({ epg_url: e.target.value }), 500);
    });

    document.getElementById('stremioEpgAutoMatch').addEventListener('change', (e) => {
      sendUpdate({ stremio_epg_auto_match: e.target.checked });
    });

    document.getElementById('stremioAutoPickStreams').addEventListener('change', (e) => {
      sendUpdate({ stremio_auto_pick_streams: e.target.checked });
    });

    let rdTimer, tbTimer;
    document.getElementById('rdApiKey').addEventListener('input', (e) => {
      clearTimeout(rdTimer);
      rdTimer = setTimeout(() => sendUpdate({ rd_api_key: e.target.value }), 500);
    });
    document.getElementById('tbApiKey').addEventListener('input', (e) => {
      clearTimeout(tbTimer);
      tbTimer = setTimeout(() => sendUpdate({ tb_api_key: e.target.value }), 500);
    });

    document.getElementById('addAddonBtn').addEventListener('click', () => {
      const input = document.getElementById('addonInput');
      const url = normalizeAddonUrl(input.value);
      if (url && !currentAddons.includes(url)) {
        currentAddons.push(url);
        sendUpdate({ stremio_addons: currentAddons });
        renderAddons();
      }
      input.value = '';
    });

    document.getElementById('addonInput').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') document.getElementById('addAddonBtn').click();
    });

    document.getElementById('exportBtn').addEventListener('click', () => {
      const data = {
        streaming_mode: document.getElementById('streamingMode').checked,
        use_debrid: document.getElementById('useDebrid').checked,
        debrid_provider: document.getElementById('debridProvider').value,
        rd_api_key: document.getElementById('rdApiKey').value,
        tb_api_key: document.getElementById('tbApiKey').value,
        cache_size_mb: parseInt(document.getElementById('cacheSizeMB').value),
        subtitle_fontsize: parseInt(document.getElementById('subtitleFontsize').value),
        iptv_m3u_url: document.getElementById('iptvM3uUrl').value,
        epg_url: document.getElementById('epgUrl').value,
        stremio_epg_auto_match: document.getElementById('stremioEpgAutoMatch').checked,
        stremio_auto_pick_streams: document.getElementById('stremioAutoPickStreams').checked,
        stremio_addons: currentAddons,
        live_tv_stremio_epg_map: liveTvStremioEpgMap,
        iptv_favorite_stream_urls: iptvFavoriteUrls
      };
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'playtorrio_settings.json';
      a.click();
      URL.revokeObjectURL(a.href);
    });

    document.getElementById('importBtn').addEventListener('click', () => {
      document.getElementById('importFile').click();
    });

    document.getElementById('importFile').addEventListener('change', (e) => {
      const file = e.target.files[0];
      if (!file) return;
      const reader = new FileReader();
      reader.onload = (ev) => {
        try {
          const data = JSON.parse(ev.target.result);
          sendUpdate(data);
          if (data.stremio_addons) { currentAddons = data.stremio_addons; renderAddons(); }
        } catch (err) {
          alert('Invalid JSON file');
        }
      };
      reader.readAsText(file);
      e.target.value = '';
    });

    connect();
  </script>
</body>
</html>
''';
}
