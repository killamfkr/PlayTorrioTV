import 'package:flutter/material.dart';
import 'package:dpad/dpad.dart';

import '../constants.dart';
import '../services/playtorrio_cloud_sync_service.dart';
import 'profile_screen.dart';

/// Supabase email/password gate (PlayTorrioV2 parity) before profile picker.
class PlaytorrioTvSignInScreen extends StatefulWidget {
  const PlaytorrioTvSignInScreen({super.key});

  @override
  State<PlaytorrioTvSignInScreen> createState() => _PlaytorrioTvSignInScreenState();
}

class _PlaytorrioTvSignInScreenState extends State<PlaytorrioTvSignInScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _toProfiles() async {
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, _, _) => const ProfileScreen(),
        transitionsBuilder: (_, a, _, c) => FadeTransition(opacity: a, child: c),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  Future<void> _signIn() async {
    final e = _email.text.trim();
    final p = _pass.text;
    if (e.isEmpty || p.isEmpty) {
      setState(() => _error = 'Email and password required');
      return;
    }
    if (!PlaytorrioCloudSyncService.instance.isConfigured) {
      setState(() => _error = 'Supabase not configured. Set dart-defines or rebuild with URL/key.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await PlaytorrioCloudSyncService.instance.signInWithPassword(email: e, password: p);
      _pass.clear();
      await PlaytorrioCloudSyncService.instance.pullOnStartup();
      if (mounted) await _toProfiles();
    } on PlaytorrioCloudException catch (ex) {
      if (mounted) {
        setState(() {
          _error = ex.message;
          _busy = false;
        });
      }
    } catch (ex) {
      if (mounted) {
        setState(() {
          _error = '$ex';
          _busy = false;
        });
      }
    }
  }

  Future<void> _skip() async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    if (mounted) await _toProfiles();
  }

  @override
  Widget build(BuildContext context) {
    final configured = PlaytorrioCloudSyncService.instance.isConfigured;
    final jwtOk = PlaytorrioCloudSyncService.instance.isAnonKeyJwtFormat;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: DpadFocusable(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Image.asset(
                      AppAssets.playtorrioMark,
                      width: 72,
                      height: 72,
                      filterQuality: FilterQuality.medium,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'PlayTorrio account',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.purpleLight,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      configured
                          ? 'Sign in with the same Supabase email and password as the mobile app to sync continue watching and settings.'
                          : 'This build has no Supabase URL/key. You can skip and use the TV locally.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.35),
                    ),
                    if (configured && !jwtOk) ...[
                      const SizedBox(height: 12),
                      Text(
                        'The anon key should be the legacy JWT from Supabase (starts with eyJ…). '
                        'Otherwise cloud sync may fail.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.amber.shade200, fontSize: 12, height: 1.35),
                      ),
                    ],
                    const SizedBox(height: 24),
                    TextField(
                      controller: _email,
                      style: const TextStyle(color: Colors.white),
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: 'Email',
                        labelStyle: TextStyle(color: AppColors.textDim),
                        filled: true,
                        fillColor: AppColors.surfaceLight,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pass,
                      style: const TextStyle(color: Colors.white),
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        labelStyle: TextStyle(color: AppColors.textDim),
                        filled: true,
                        fillColor: AppColors.surfaceLight,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: (_busy || !configured) ? null : _signIn,
                      child: Text(_busy ? 'Please wait…' : 'Sign in'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: _busy ? null : _skip,
                      child: const Text('Skip (local only)'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
