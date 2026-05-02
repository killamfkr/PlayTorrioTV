import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'continue_watching_service.dart';
import 'settings_service.dart';

/// Supabase auth + sync — same contract as PlayTorrioV2 `playtorrio_cloud_sync_service.dart`.
/// Override URL/key with `--dart-define=PLAYTORRIO_SUPABASE_URL=...` and
/// `--dart-define=PLAYTORRIO_SUPABASE_ANON_KEY=...` (legacy anon JWT, `eyJ…`).
const String kPlaytorrioSupabaseUrl = String.fromEnvironment(
  'PLAYTORRIO_SUPABASE_URL',
  defaultValue: 'https://lxapazzlduwwecatebti.supabase.co',
);
const String kPlaytorrioSupabaseAnonKey = String.fromEnvironment(
  'PLAYTORRIO_SUPABASE_ANON_KEY',
  defaultValue:
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx4YXBhenpsZHV3d2VjYXRlYnRpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzcyOTI2NDQsImV4cCI6MjA5Mjg2ODY0NH0.a9e7zUEdWDmf4Qor-rbYZ6G0sMTEYcfKnwTrXjVrBWY',
);

class PlaytorrioCloudSyncService {
  PlaytorrioCloudSyncService._();
  static final PlaytorrioCloudSyncService instance = PlaytorrioCloudSyncService._();

  static const _accessKey = 'pt_supabase_access_token';
  static const _refreshKey = 'pt_supabase_refresh_token';

  static const _restWatch = '/rest/v1/user_watch_history';
  static const _restSettings = '/rest/v1/user_settings';

  final _secure = const FlutterSecureStorage();

  String? _access;
  String? _refresh;

  String? get _base {
    final u = kPlaytorrioSupabaseUrl.trim();
    if (u.isEmpty) return null;
    return u.replaceAll(RegExp(r'/+$'), '');
  }

  String? get _anon {
    final k = kPlaytorrioSupabaseAnonKey.trim();
    return k.isEmpty ? null : k;
  }

  bool get isConfigured => _base != null && _anon != null;

  bool get isAnonKeyJwtFormat {
    final k = _anon;
    if (k == null || k.isEmpty) return false;
    return k.split('.').length == 3 && k.startsWith('eyJ');
  }

  void _requireConfig() {
    if (!isConfigured) {
      throw const PlaytorrioCloudException(
        'Supabase URL/key missing. Set PLAYTORRIO_SUPABASE_URL and '
        'PLAYTORRIO_SUPABASE_ANON_KEY (legacy anon JWT from Project → API).',
      );
    }
  }

  Future<String?> get _accessToken async {
    if (_access != null && _access!.isNotEmpty) return _access;
    _access = await _secure.read(key: _accessKey);
    return _access;
  }

  Future<String?> get _refreshToken async {
    if (_refresh != null && _refresh!.isNotEmpty) return _refresh;
    _refresh = await _secure.read(key: _refreshKey);
    return _refresh;
  }

  Future<void> _saveSession(String access, String? refresh) async {
    _access = access;
    await _secure.write(key: _accessKey, value: access);
    if (refresh != null && refresh.isNotEmpty) {
      _refresh = refresh;
      await _secure.write(key: _refreshKey, value: refresh);
    }
  }

  Map<String, String> _headers(String token) => {
        'apikey': _anon!,
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  static const _preferUpsert = 'return=minimal,resolution=merge-duplicates';

  static bool isJwtAccessExpired(String jwt, {int leewaySeconds = 60}) {
    final exp = jwtExpUnixSeconds(jwt);
    if (exp == null) return true;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= exp - leewaySeconds;
  }

  static int? jwtExpUnixSeconds(String jwt) {
    final parts = jwt.split('.');
    if (parts.length < 2) return null;
    var seg = parts[1];
    final m = seg.length % 4;
    if (m > 0) seg += '=' * (4 - m);
    try {
      final map = json.decode(utf8.decode(base64Url.decode(seg)))
          as Map<String, dynamic>;
      final exp = map['exp'];
      if (exp is int) return exp;
      if (exp is num) return exp.toInt();
    } catch (_) {
      return null;
    }
    return null;
  }

  static String? userIdFromJwt(String jwt) {
    final parts = jwt.split('.');
    if (parts.length < 2) return null;
    var seg = parts[1];
    final m = seg.length % 4;
    if (m > 0) seg += '=' * (4 - m);
    try {
      final jsonMap = json.decode(utf8.decode(base64Url.decode(seg)))
          as Map<String, dynamic>;
      return jsonMap['sub'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearAccessTokenOnly() async {
    _access = null;
    await _secure.delete(key: _accessKey);
  }

  Future<http.Response> _withAccessRetry(
    Future<http.Response> Function(String accessToken) send,
  ) async {
    await _ensureAccess();
    var token = await _accessToken;
    if (token == null || token.isEmpty) {
      throw const PlaytorrioCloudException('Not signed in');
    }
    var res = await send(token);
    if (res.statusCode != 401) return res;
    await _clearAccessTokenOnly();
    try {
      await _ensureAccess();
    } catch (_) {
      await signOut();
      return res;
    }
    token = await _accessToken;
    if (token == null || token.isEmpty) {
      await signOut();
      return res;
    }
    res = await send(token);
    if (res.statusCode == 401) await signOut();
    return res;
  }

  Future<void> _ensureAccess() async {
    final existing = await _accessToken;
    if (existing != null &&
        existing.isNotEmpty &&
        !isJwtAccessExpired(existing)) {
      return;
    }
    _access = null;
    final rt = await _refreshToken;
    if (rt == null || rt.isEmpty) {
      throw const PlaytorrioCloudException('Not signed in');
    }
    _requireConfig();
    final res = await http.post(
      Uri.parse('$_base/auth/v1/token?grant_type=refresh_token'),
      headers: {
        'apikey': _anon!,
        'Content-Type': 'application/json',
      },
      body: json.encode({'refresh_token': rt}),
    );
    if (res.statusCode != 200) {
      await signOut();
      throw const PlaytorrioCloudException('Session expired. Sign in again.');
    }
    final data = json.decode(res.body) as Map<String, dynamic>;
    await _saveSession(
      data['access_token'] as String,
      data['refresh_token'] as String?,
    );
  }

  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    _requireConfig();
    final res = await http.post(
      Uri.parse('$_base/auth/v1/token?grant_type=password'),
      headers: {
        'apikey': _anon!,
        'Content-Type': 'application/json',
      },
      body: json.encode({'email': email.trim(), 'password': password}),
    );
    if (res.statusCode != 200) {
      var msg = res.body;
      try {
        final m = json.decode(res.body) as Map<String, dynamic>?;
        msg = m?['error_description']?.toString() ??
            m?['message']?.toString() ??
            msg;
      } catch (_) {}
      throw PlaytorrioCloudException(msg);
    }
    final data = json.decode(res.body) as Map<String, dynamic>;
    await _saveSession(
      data['access_token'] as String,
      data['refresh_token'] as String?,
    );
  }

  Future<void> signOut() async {
    final token = await _accessToken;
    if (token != null && token.isNotEmpty && isConfigured) {
      try {
        unawaited(http.post(
          Uri.parse('$_base/auth/v1/logout'),
          headers: {
            'apikey': _anon!,
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        ));
      } catch (_) {}
    }
    _access = null;
    _refresh = null;
    await _secure.delete(key: _accessKey);
    await _secure.delete(key: _refreshKey);
  }

  Future<bool> hasStoredSession() async =>
      (await _accessToken)?.isNotEmpty == true ||
      (await _refreshToken)?.isNotEmpty == true;

  Future<bool> isProgressSyncEnabled() =>
      SettingsService.instance.isPlaytorrioCloudProgressSyncEnabled();

  Future<bool> isSettingsSyncEnabled() =>
      SettingsService.instance.isPlaytorrioCloudSettingsSyncEnabled();

  Future<void> pullAndMergeProgress() async {
    if (!isConfigured) return;
    if (!await isProgressSyncEnabled()) return;
    if (!await hasStoredSession()) return;

    final pid = SettingsService.instance.playtorrioCloudProfileSlot;
    final res = await _withAccessRetry(
      (t) {
        final userId = userIdFromJwt(t);
        if (userId == null) {
          return Future.value(
            http.Response('{"message":"no sub in access token"}', 400),
          );
        }
        return http.get(
          Uri.parse(
            '$_base$_restWatch?select=entries&user_id=eq.$userId&profile_id=eq.$pid',
          ),
          headers: _headers(t),
        );
      },
    );
    if (res.statusCode != 200) {
      debugPrint('[PT Cloud] pull history FAILED: ${res.statusCode} ${res.body}');
      return;
    }
    final decoded = json.decode(res.body);
    if (decoded is! List || decoded.isEmpty) return;
    final first = decoded.first;
    if (first is! Map) return;
    final entriesRaw = first['entries'];
    if (entriesRaw is! List) return;

    final local = ContinueWatchingService.entries
        .map((e) => e.toCloudRow())
        .toList();
    final byUnique = {
      for (final m in local)
        if (m['uniqueId'] != null) m['uniqueId'] as String: m,
    };

    int updatedAtMs(Map<String, dynamic> m) {
      final v = m['updatedAt'] ?? m['updated_at'];
      if (v is int) return v;
      return int.tryParse('$v') ?? 0;
    }

    for (final raw in entriesRaw) {
      if (raw is! Map) continue;
      final e = Map<String, dynamic>.from(
        raw.map((k, v) => MapEntry(k.toString(), v)),
      );
      final entryUid = e['uniqueId']?.toString();
      if (entryUid == null || entryUid.isEmpty) continue;

      final old = byUnique[entryUid];
      if (old == null) {
        byUnique[entryUid] = e;
        continue;
      }
      if (updatedAtMs(e) >= updatedAtMs(old)) {
        byUnique[entryUid] = e;
      } else {
        byUnique[entryUid] = old;
      }
    }

    var merged = byUnique.values.toList();
    merged.sort(
      (a, b) => updatedAtMs(b).compareTo(updatedAtMs(a)),
    );
    await ContinueWatchingService.replaceFromCloudMaps(merged);
  }

  Future<void> pushProgressList() async {
    if (!isConfigured) return;
    if (!await hasStoredSession()) return;
    if (!await isProgressSyncEnabled()) return;
    if (!isAnonKeyJwtFormat) {
      debugPrint('[PT Cloud] push skipped: anon key must be legacy JWT (eyJ…)');
      return;
    }

    final pid = SettingsService.instance.playtorrioCloudProfileSlot;
    var list = ContinueWatchingService.entries.map((e) => e.toCloudRow()).toList();
    if (list.length > 50) list = list.sublist(0, 50);

    final res = await _withAccessRetry(
      (t) {
        final uid = userIdFromJwt(t);
        if (uid == null) {
          return Future.value(
            http.Response('{"message":"no sub in access token"}', 400),
          );
        }
        return http.post(
          Uri.parse('$_base$_restWatch?on_conflict=user_id,profile_id'),
          headers: {
            ..._headers(t),
            'Prefer': _preferUpsert,
          },
          body: json.encode({
            'user_id': uid,
            'profile_id': pid,
            'entries': list,
          }),
        );
      },
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      debugPrint('[PT Cloud] push history FAILED: ${res.statusCode} ${res.body}');
    }
  }

  void scheduleProgressPush() {
    unawaited(() async {
      try {
        await pushProgressList();
      } catch (e, st) {
        debugPrint('[PT Cloud] push: $e $st');
      }
    }());
  }

  Future<void> pullUserSettings() async {
    if (!isConfigured) return;
    if (!await isSettingsSyncEnabled()) return;
    if (!await hasStoredSession()) return;

    final pid = SettingsService.instance.playtorrioCloudProfileSlot;
    final res = await _withAccessRetry(
      (t) {
        final userId = userIdFromJwt(t);
        if (userId == null) {
          return Future.value(
            http.Response('{"message":"no sub in access token"}', 400),
          );
        }
        return http.get(
          Uri.parse(
            '$_base$_restSettings?select=prefs&user_id=eq.$userId&profile_id=eq.$pid',
          ),
          headers: _headers(t),
        );
      },
    );
    if (res.statusCode != 200) {
      debugPrint('[PT Cloud] pull settings: ${res.statusCode}');
      return;
    }
    final decoded = json.decode(res.body);
    if (decoded is! List || decoded.isEmpty) return;
    final first = decoded.first;
    if (first is! Map) return;
    final p = first['prefs'];
    if (p is! Map) return;
    await SettingsService.instance.applyCloudPreferenceMap(
      p.map((k, v) => MapEntry(k.toString(), v)),
    );
  }

  Future<void> pushUserSettings() async {
    if (!isConfigured) return;
    if (!await isSettingsSyncEnabled()) return;
    if (!await hasStoredSession()) return;
    if (!isAnonKeyJwtFormat) return;

    final pid = SettingsService.instance.playtorrioCloudProfileSlot;
    final map = await SettingsService.instance.exportForCloudSync();

    final res = await _withAccessRetry(
      (t) {
        final uid = userIdFromJwt(t);
        if (uid == null) {
          return Future.value(
            http.Response('{"message":"no sub in access token"}', 400),
          );
        }
        return http.post(
          Uri.parse('$_base$_restSettings?on_conflict=user_id,profile_id'),
          headers: {
            ..._headers(t),
            'Prefer': _preferUpsert,
          },
          body: json.encode({
            'user_id': uid,
            'profile_id': pid,
            'prefs': map,
          }),
        );
      },
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      debugPrint('[PT Cloud] push settings FAILED: ${res.statusCode} ${res.body}');
    }
  }

  void scheduleSettingsPush() {
    unawaited(() async {
      try {
        await pushUserSettings();
      } catch (e) {
        debugPrint('[PT Cloud] settings push: $e');
      }
    }());
  }

  Future<void> pushFullProfileBackup() async {
    if (!isConfigured) return;
    if (!await hasStoredSession()) return;
    try {
      await _ensureAccess();
      await pushProgressList();
      if (await isSettingsSyncEnabled()) await pushUserSettings();
    } catch (e) {
      debugPrint('[PT Cloud] full backup: $e');
    }
  }

  Future<void> pullOnStartup() async {
    if (!isConfigured) return;
    if (!await hasStoredSession()) return;
    if (!isAnonKeyJwtFormat) {
      debugPrint('[PT Cloud] pullOnStartup skipped: use legacy anon JWT');
      return;
    }
    try {
      if (await isProgressSyncEnabled()) {
        await pullAndMergeProgress();
      }
      if (await isSettingsSyncEnabled()) {
        await pullUserSettings();
      }
    } catch (e) {
      debugPrint('[PT Cloud] startup pull: $e');
    }
  }
}

class PlaytorrioCloudException implements Exception {
  const PlaytorrioCloudException(this.message);
  final String message;
  @override
  String toString() => message;
}
