import 'package:flutter/material.dart';
import 'package:dpad/dpad.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../constants.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsService.instance;

  @override
  void initState() {
    super.initState();
    _settings.startServer();
    _settings.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final url = _settings.settingsUrl;

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left side: QR code
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Remote Settings',
                style: TextStyle(
                  color: AppColors.purpleLight,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Scan with your phone to change settings',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 24),
              if (url != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: url,
                    version: QrVersions.auto,
                    size: 200,
                    backgroundColor: Colors.white,
                  ),
                )
              else
                const SizedBox(
                  width: 200,
                  height: 200,
                  child: Center(
                    child: CircularProgressIndicator(color: AppColors.purpleLight),
                  ),
                ),
              const SizedBox(height: 12),
              if (url != null)
                Text(
                  url,
                  style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                ),
            ],
          ),
          const SizedBox(width: 48),
          // Right side: settings list
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Settings',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _SettingToggle(
                    title: 'Streaming Mode',
                    subtitle: 'Use direct HTTP links instead of torrents',
                    value: _settings.streamingMode,
                    onChanged: (v) => _settings.setStreamingMode(v),
                  ),
                  const SizedBox(height: 8),
                  _SettingDropdown(
                    title: 'RAM Cache Size',
                    subtitle: 'How much RAM TorrServer can use for buffering',
                    value: _settings.cacheSizeMB.toString(),
                    options: const {
                      '128': '128 MB',
                      '256': '256 MB',
                      '512': '512 MB',
                      '768': '768 MB',
                      '1024': '1024 MB',
                    },
                    onChanged: (v) => _settings.setCacheSizeMB(int.parse(v)),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Player',
                    style: TextStyle(
                      color: AppColors.purpleLight,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _SettingDropdown(
                    title: 'Subtitle Size',
                    subtitle: 'Adjust subtitle font size in the player',
                    value: _settings.subtitleFontsize.toString(),
                    options: const {
                      '0': 'Default',
                      '14': 'Large',
                      '10': 'Extra Large',
                      '7': 'Huge',
                    },
                    onChanged: (v) => _settings.setSubtitleFontsize(int.parse(v)),
                  ),
                  const SizedBox(height: 8),
                  _SettingToggle(
                    title: 'Use Debrid for Torrents',
                    subtitle: 'Stream torrents via a debrid service',
                    value: _settings.useDebrid,
                    onChanged: (v) => _settings.setUseDebrid(v),
                  ),
                  if (_settings.useDebrid) ...[
                    const SizedBox(height: 8),
                    _SettingDropdown(
                      title: 'Debrid Provider',
                      subtitle: 'Choose your debrid service',
                      value: _settings.debridProvider,
                      options: const {'real-debrid': 'Real-Debrid', 'torbox': 'TorBox'},
                      onChanged: (v) => _settings.setDebridProvider(v),
                    ),
                    const SizedBox(height: 8),
                    _SettingInfo(
                      title: _settings.debridProvider == 'real-debrid' ? 'Real-Debrid API Key' : 'TorBox API Key',
                      subtitle: _settings.debridProvider == 'real-debrid'
                          ? (_settings.realDebridApiKey.isEmpty ? 'Not set — configure via phone' : 'Configured')
                          : (_settings.torboxApiKey.isEmpty ? 'Not set — configure via phone' : 'Configured'),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text(
                    'Live TV',
                    style: TextStyle(
                      color: AppColors.purpleLight,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _SettingInfo(
                    title: 'IPTV playlist (M3U)',
                    subtitle: _settings.iptvM3uUrl.isEmpty
                        ? 'Not set — add URL via phone QR code'
                        : 'Configured — open Live TV in the sidebar',
                  ),
                  const SizedBox(height: 8),
                  _SettingInfo(
                    title: 'EPG (XMLTV)',
                    subtitle: _settings.epgUrl.isEmpty
                        ? 'Optional — add XMLTV URL via phone'
                        : 'Configured',
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Stremio Addons',
                    style: TextStyle(
                      color: AppColors.purpleLight,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _SettingInfo(
                    title: 'Subtitle Addons',
                    subtitle: _settings.stremioAddons.isEmpty
                        ? 'None — add via phone'
                        : '${_settings.stremioAddons.length} addon${_settings.stremioAddons.length != 1 ? 's' : ''} configured',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingToggle extends StatefulWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingToggle({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_SettingToggle> createState() => _SettingToggleState();
}

class _SettingToggleState extends State<_SettingToggle> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return DpadFocusable(
      onFocus: () => setState(() => _focused = true),
      onBlur: () => setState(() => _focused = false),
      onSelect: () => widget.onChanged(!widget.value),
      builder: (context, isFocused, child) {
        return GestureDetector(
          onTap: () => widget.onChanged(!widget.value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: _focused ? AppColors.darkPurple.withValues(alpha: 0.5) : AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused ? AppColors.purpleLight : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: widget.value,
                  onChanged: widget.onChanged,
                  activeColor: AppColors.purpleLight,
                  activeTrackColor: AppColors.darkPurple,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SettingDropdown extends StatefulWidget {
  final String title;
  final String subtitle;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  const _SettingDropdown({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  State<_SettingDropdown> createState() => _SettingDropdownState();
}

class _SettingDropdownState extends State<_SettingDropdown> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final keys = widget.options.keys.toList();
    final currentIndex = keys.indexOf(widget.value);

    return DpadFocusable(
      onFocus: () => setState(() => _focused = true),
      onBlur: () => setState(() => _focused = false),
      onSelect: () {
        // Cycle to next option
        final nextIndex = (currentIndex + 1) % keys.length;
        widget.onChanged(keys[nextIndex]);
      },
      builder: (context, isFocused, child) {
        return GestureDetector(
          onTap: () {
            final nextIndex = (currentIndex + 1) % keys.length;
            widget.onChanged(keys[nextIndex]);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: _focused ? AppColors.darkPurple.withValues(alpha: 0.5) : AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused ? AppColors.purpleLight : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title, style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 2),
                      Text(widget.subtitle, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.darkPurple,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    widget.options[widget.value] ?? widget.value,
                    style: const TextStyle(color: AppColors.purpleLight, fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SettingInfo extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SettingInfo({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              ],
            ),
          ),
          Icon(
            subtitle.contains('Not set') ? Icons.warning_amber_rounded : Icons.check_circle_rounded,
            color: subtitle.contains('Not set') ? Colors.amber : Colors.green,
            size: 20,
          ),
        ],
      ),
    );
  }
}
