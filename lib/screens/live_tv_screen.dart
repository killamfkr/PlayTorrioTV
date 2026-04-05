import 'dart:async';

import 'package:flutter/material.dart';
import 'package:dpad/dpad.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../constants.dart';
import '../services/live_tv_service.dart';
import '../services/settings_service.dart';
import '../services/stremio_live_tv_service.dart';

class LiveTvScreen extends StatefulWidget {
  const LiveTvScreen({super.key});

  @override
  State<LiveTvScreen> createState() => _LiveTvScreenState();
}

class _LiveTvScreenState extends State<LiveTvScreen> {
  final _settings = SettingsService.instance;

  /// 0 = Stremio TV catalogs, 1 = M3U / XMLTV playlist
  int _sourceTab = 0;

  // --- IPTV (M3U) ---
  List<LiveTvChannel> _channels = [];
  Map<String, List<EpgProgramme>> _epg = {};
  String? _selectedGroup;
  int _selectedIndex = 0;
  bool _loading = true;
  String? _error;
  Timer? _epgClock;
  String _lastM3u = '';
  String _lastEpg = '';

  // --- Stremio ---
  List<StremioLiveChannel> _stremioChannels = [];
  bool _stremioLoading = false;
  String? _stremioError;
  String? _stremioGroup;
  int _stremioIndex = 0;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onSettingsChanged);
    SettingsService.addonChangeNotifier.addListener(_onAddonsChanged);
    _load();
    _loadStremio();
    _epgClock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _epgClock?.cancel();
    SettingsService.addonChangeNotifier.removeListener(_onAddonsChanged);
    _settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onAddonsChanged() {
    StremioLiveTvService.instance.clearCache();
    if (mounted && _sourceTab == 0) {
      _loadStremio();
    }
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    final m3u = _settings.iptvM3uUrl;
    final epgUrl = _settings.epgUrl;
    if (m3u != _lastM3u || epgUrl != _lastEpg) {
      _load();
    }
  }

  Future<void> _loadStremio() async {
    setState(() {
      _stremioLoading = true;
      _stremioError = null;
    });
    try {
      final list = await StremioLiveTvService.instance.loadAllTvChannels();
      if (!mounted) return;
      final groups = _stremioGroupTitles(list);
      final groupOk = _stremioGroup == null || groups.contains(_stremioGroup);
      setState(() {
        _stremioChannels = list;
        _stremioLoading = false;
        if (!groupOk) _stremioGroup = null;
        final filtered = _filteredStremioChannels;
        _stremioIndex =
            filtered.isEmpty ? 0 : _stremioIndex.clamp(0, filtered.length - 1);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _stremioLoading = false;
          _stremioError = e.toString();
          _stremioChannels = [];
        });
      }
    }
  }

  List<String> _stremioGroupTitles(List<StremioLiveChannel> ch) {
    final s = ch.map((c) => c.addonName).toSet().toList()..sort();
    return s;
  }

  List<StremioLiveChannel> get _filteredStremioChannels {
    final g = _stremioGroup;
    if (g == null) return _stremioChannels;
    return _stremioChannels.where((c) => c.addonName == g).toList();
  }

  StremioLiveChannel? get _selectedStremioChannel {
    final list = _filteredStremioChannels;
    if (list.isEmpty || _stremioIndex < 0 || _stremioIndex >= list.length) {
      return null;
    }
    return list[_stremioIndex];
  }

  Future<void> _load() async {
    final m3u = _settings.iptvM3uUrl;
    final epgUrl = _settings.epgUrl;
    if (m3u.isEmpty) {
      setState(() {
        _lastM3u = '';
        _lastEpg = '';
        _channels = [];
        _epg = {};
        _loading = false;
        _error = null;
        _selectedIndex = 0;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ch = await LiveTvService.instance.loadPlaylist(m3u);
      Map<String, List<EpgProgramme>> epg = {};
      if (epgUrl.isNotEmpty) {
        try {
          epg = await LiveTvService.instance.loadEpg(epgUrl);
        } catch (e) {
          epg = {};
        }
      }
      if (!mounted) return;
      final groups = _groupTitles(ch);
      final sel = _selectedGroup;
      final groupOk = sel == null || groups.contains(sel);
      setState(() {
        _lastM3u = m3u;
        _lastEpg = epgUrl;
        _channels = ch;
        _epg = epg;
        _loading = false;
        if (!groupOk) _selectedGroup = null;
        final g = _selectedGroup;
        final filtered = g == null
            ? ch
            : ch.where((c) => (c.groupTitle ?? '').trim() == g).toList();
        _selectedIndex =
            filtered.isEmpty ? 0 : _selectedIndex.clamp(0, filtered.length - 1);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
          _channels = [];
        });
      }
    }
  }

  List<String> _groupTitles(List<LiveTvChannel> ch) {
    final s = <String>{};
    for (final c in ch) {
      final g = c.groupTitle?.trim();
      if (g != null && g.isNotEmpty) s.add(g);
    }
    final list = s.toList()..sort();
    return list;
  }

  List<LiveTvChannel> get _filteredChannels {
    final g = _selectedGroup;
    if (g == null) return _channels;
    return _channels.where((c) => (c.groupTitle ?? '').trim() == g).toList();
  }

  LiveTvChannel? get _selectedChannel {
    final list = _filteredChannels;
    if (list.isEmpty || _selectedIndex < 0 || _selectedIndex >= list.length) {
      return null;
    }
    return list[_selectedIndex];
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Row(
            children: [
              const Text(
                'Live TV',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 20),
              _SourceTabChip(
                label: 'Stremio',
                selected: _sourceTab == 0,
                onSelect: () => setState(() => _sourceTab = 0),
              ),
              const SizedBox(width: 8),
              _SourceTabChip(
                label: 'IPTV playlist',
                selected: _sourceTab == 1,
                onSelect: () => setState(() => _sourceTab = 1),
              ),
            ],
          ),
        ),
        Expanded(
          child: _sourceTab == 0 ? _buildStremioBody() : _buildIptvBody(),
        ),
      ],
    );
  }

  Widget _buildIptvBody() {
    final m3u = _settings.iptvM3uUrl;
    if (m3u.isEmpty) {
      return _emptyState(
        icon: Icons.tv_outlined,
        title: 'IPTV playlist',
        message:
            'Add your M3U playlist URL under Remote Settings on your phone (scan the QR code in Settings). Optionally add an XMLTV EPG URL for the guide.',
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.purpleLight));
    }
    if (_error != null) {
      return _emptyState(
        icon: Icons.error_outline,
        title: 'Could not load playlist',
        message: _error!,
        action: TextButton(
          onPressed: _load,
          child: const Text('Retry'),
        ),
      );
    }
    final filtered = _filteredChannels;
    if (filtered.isEmpty) {
      return _emptyState(
        icon: Icons.list_alt,
        title: 'No channels',
        message: 'This group is empty or the playlist has no playable entries.',
      );
    }

    final ch = _selectedChannel ?? filtered.first;
    final now = DateTime.now();
    final cur = LiveTvService.currentProgramme(_epg, ch.tvgId, now);
    final next = LiveTvService.nextProgramme(_epg, ch.tvgId, now);
    final groups = _groupTitles(_channels);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Row(
            children: [
              if (_settings.epgUrl.isNotEmpty)
                Text(
                  _epg.isEmpty ? 'EPG: not loaded' : 'EPG loaded',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                ),
              const Spacer(),
              TextButton.icon(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 18, color: AppColors.purpleLight),
                label: const Text('Reload'),
              ),
            ],
          ),
        ),
        if (groups.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                _GroupChip(
                  label: 'All',
                  selected: _selectedGroup == null,
                  onSelect: () => setState(() {
                    _selectedGroup = null;
                    _selectedIndex = 0;
                  }),
                ),
                for (final g in groups)
                  _GroupChip(
                    label: g,
                    selected: _selectedGroup == g,
                    onSelect: () => setState(() {
                      _selectedGroup = g;
                      _selectedIndex = 0;
                    }),
                  ),
              ],
            ),
          ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 360,
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 24),
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final c = filtered[i];
                    final onNow = LiveTvService.currentProgramme(_epg, c.tvgId, DateTime.now());
                    return _ChannelRow(
                      channel: c,
                      selected: i == _selectedIndex,
                      subtitle: onNow?.title,
                      autofocus: i == 0,
                      onFocus: () => setState(() => _selectedIndex = i),
                      onSelect: () => _play(c),
                    );
                  },
                ),
              ),
              Expanded(
                child: _ChannelDetailPanel(
                  channel: ch,
                  nowPlaying: cur,
                  nextPlaying: next,
                  hasEpg: _epg.isNotEmpty && ch.tvgId != null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStremioBody() {
    if (_stremioLoading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.purpleLight));
    }
    if (_stremioError != null) {
      return _emptyState(
        icon: Icons.error_outline,
        title: 'Stremio channels',
        message: _stremioError!,
        action: TextButton(
          onPressed: _loadStremio,
          child: const Text('Retry'),
        ),
      );
    }
    if (StremioLiveTvService.getTvCatalogs().isEmpty) {
      return _emptyState(
        icon: Icons.extension_outlined,
        title: 'No Stremio TV addons',
        message:
            'Install a Stremio addon that provides live TV (catalog type "tv") using Remote Settings on your phone, same as subtitle addons. Then reopen Live TV.',
      );
    }
    final filtered = _filteredStremioChannels;
    if (filtered.isEmpty) {
      return _emptyState(
        icon: Icons.list_alt,
        title: 'No channels',
        message: 'TV catalogs returned no channels. Try another addon or check your network.',
      );
    }

    final sel = _selectedStremioChannel ?? filtered.first;
    final stGroups = _stremioGroupTitles(_stremioChannels);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Row(
            children: [
              Text(
                '${filtered.length} channels',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _stremioLoading ? null : _loadStremio,
                icon: const Icon(Icons.refresh, size: 18, color: AppColors.purpleLight),
                label: const Text('Reload'),
              ),
            ],
          ),
        ),
        if (stGroups.length > 1)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                _GroupChip(
                  label: 'All',
                  selected: _stremioGroup == null,
                  onSelect: () => setState(() {
                    _stremioGroup = null;
                    _stremioIndex = 0;
                  }),
                ),
                for (final g in stGroups)
                  _GroupChip(
                    label: g,
                    selected: _stremioGroup == g,
                    onSelect: () => setState(() {
                      _stremioGroup = g;
                      _stremioIndex = 0;
                    }),
                  ),
              ],
            ),
          ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 360,
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 24),
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final c = filtered[i];
                    return _StremioChannelRow(
                      channel: c,
                      selected: i == _stremioIndex,
                      autofocus: i == 0,
                      onFocus: () => setState(() => _stremioIndex = i),
                      onSelect: () => _playStremio(c),
                    );
                  },
                ),
              ),
              Expanded(
                child: _StremioDetailPanel(
                  channel: sel,
                  onWatch: () => _playStremio(sel),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _playStremio(StremioLiveChannel c) async {
    final url = await StremioLiveTvService.resolveStreamUrl(
      addonBaseUrl: c.addonBaseUrl,
      channelId: c.id,
    );
    if (!mounted) return;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No playable stream for this channel')),
      );
      return;
    }
    Navigator.pushNamed(context, '/player', arguments: {
      'magnet': url,
      'title': c.name,
      'mediaType': 'movie',
    });
  }

  void _play(LiveTvChannel c) {
    Navigator.pushNamed(context, '/player', arguments: {
      'magnet': c.streamUrl,
      'title': c.name,
      'mediaType': 'movie',
    });
  }

  Widget _emptyState({
    required IconData icon,
    required String title,
    required String message,
    Widget? action,
  }) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56, color: AppColors.textDim),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 15, height: 1.4),
                textAlign: TextAlign.center,
              ),
              if (action != null) ...[const SizedBox(height: 20), action],
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceTabChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelect;

  const _SourceTabChip({
    required this.label,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return DpadFocusable(
      onSelect: onSelect,
      builder: (context, focused, _) {
        return GestureDetector(
          onTap: onSelect,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: selected || focused
                  ? AppColors.darkPurple.withValues(alpha: 0.75)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: focused ? AppColors.purpleLight : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: selected || focused ? Colors.white : AppColors.textSecondary,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        );
      },
      child: const SizedBox.shrink(),
    );
  }
}

class _GroupChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelect;

  const _GroupChip({
    required this.label,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: DpadFocusable(
        onSelect: onSelect,
        builder: (context, focused, _) {
          return GestureDetector(
            onTap: onSelect,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: selected || focused
                    ? AppColors.darkPurple.withValues(alpha: 0.7)
                    : AppColors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: focused ? AppColors.purpleLight : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: selected || focused ? Colors.white : AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          );
        },
        child: const SizedBox.shrink(),
      ),
    );
  }
}

class _ChannelRow extends StatelessWidget {
  final LiveTvChannel channel;
  final bool selected;
  final String? subtitle;
  final bool autofocus;
  final VoidCallback onFocus;
  final VoidCallback onSelect;

  const _ChannelRow({
    required this.channel,
    required this.selected,
    this.subtitle,
    required this.autofocus,
    required this.onFocus,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final logo = channel.logoUrl;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: DpadFocusable(
        autofocus: autofocus,
        region: 'live_channels',
        onFocus: onFocus,
        onSelect: onSelect,
        builder: (context, focused, _) {
          final active = selected || focused;
          return GestureDetector(
            onTap: onSelect,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: active ? AppColors.darkPurple.withValues(alpha: 0.55) : AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: focused ? AppColors.purpleLight : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: logo != null && logo.startsWith('http')
                          ? CachedNetworkImage(
                              imageUrl: logo,
                              fit: BoxFit.cover,
                              memCacheWidth: 88,
                              errorWidget: (_, _, _) => Container(
                                color: AppColors.cardBg,
                                child: const Icon(Icons.tv, color: AppColors.textDim, size: 22),
                              ),
                            )
                          : Container(
                              color: AppColors.cardBg,
                              child: const Icon(Icons.tv, color: AppColors.textDim, size: 22),
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                        if (subtitle != null && subtitle!.isNotEmpty)
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.play_circle_outline,
                    color: active ? AppColors.purpleLight : AppColors.textDim,
                    size: 22,
                  ),
                ],
              ),
            ),
          );
        },
        child: const SizedBox.shrink(),
      ),
    );
  }
}

class _StremioChannelRow extends StatelessWidget {
  final StremioLiveChannel channel;
  final bool selected;
  final bool autofocus;
  final VoidCallback onFocus;
  final VoidCallback onSelect;

  const _StremioChannelRow({
    required this.channel,
    required this.selected,
    required this.autofocus,
    required this.onFocus,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final logo = channel.poster;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: DpadFocusable(
        autofocus: autofocus,
        region: 'live_channels',
        onFocus: onFocus,
        onSelect: onSelect,
        builder: (context, focused, _) {
          final active = selected || focused;
          return GestureDetector(
            onTap: onSelect,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: active ? AppColors.darkPurple.withValues(alpha: 0.55) : AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: focused ? AppColors.purpleLight : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: logo != null && logo.startsWith('http')
                          ? CachedNetworkImage(
                              imageUrl: logo,
                              fit: BoxFit.cover,
                              memCacheWidth: 88,
                              errorWidget: (_, _, _) => Container(
                                color: AppColors.cardBg,
                                child: const Icon(Icons.tv, color: AppColors.textDim, size: 22),
                              ),
                            )
                          : Container(
                              color: AppColors.cardBg,
                              child: const Icon(Icons.tv, color: AppColors.textDim, size: 22),
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                        Text(
                          channel.addonName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.play_circle_outline,
                    color: active ? AppColors.purpleLight : AppColors.textDim,
                    size: 22,
                  ),
                ],
              ),
            ),
          );
        },
        child: const SizedBox.shrink(),
      ),
    );
  }
}

class _StremioDetailPanel extends StatelessWidget {
  final StremioLiveChannel channel;
  final VoidCallback onWatch;

  const _StremioDetailPanel({
    required this.channel,
    required this.onWatch,
  });

  static String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final logo = channel.poster;
    final key = ValueKey('${channel.addonBaseUrl}|${channel.id}');

    return FutureBuilder<({Map<String, dynamic>? meta, Map<String, List<EpgProgramme>> epg})>(
      key: key,
      future: StremioLiveTvService.instance.getMetaAndEpg(
        addonBaseUrl: channel.addonBaseUrl,
        channelId: channel.id,
      ),
      builder: (context, snap) {
        final epgMap = snap.data?.epg ?? {};
        final now = DateTime.now();
        final cur = LiveTvService.currentProgramme(epgMap, channel.id, now);
        final next = LiveTvService.nextProgramme(epgMap, channel.id, now);
        final hasEpg = epgMap.isNotEmpty && epgMap[channel.id] != null && epgMap[channel.id]!.isNotEmpty;
        final desc = (snap.data?.meta?['description'] ?? '') as String;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 32, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (logo != null && logo.startsWith('http'))
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CachedNetworkImage(
                        imageUrl: logo,
                        width: 120,
                        height: 120,
                        fit: BoxFit.cover,
                        memCacheWidth: 240,
                        errorWidget: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  if (logo != null && logo.startsWith('http')) const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          channel.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            channel.addonName,
                            style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (desc.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  desc,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.textDim, fontSize: 13, height: 1.4),
                ),
              ],
              const SizedBox(height: 28),
              const Text(
                'Guide',
                style: TextStyle(
                  color: AppColors.purpleLight,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              if (snap.connectionState == ConnectionState.waiting)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(color: AppColors.purpleLight, strokeWidth: 2),
                )
              else if (!hasEpg)
                Text(
                  'No schedule in addon meta for this channel. The addon may only expose a live stream.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.45),
                )
              else ...[
                if (cur != null)
                  _GuideBlock(
                    label: 'Now',
                    title: cur.title,
                    timeRange: '${_fmtTime(cur.start)} – ${_fmtTime(cur.end)}',
                  )
                else
                  Text(
                    'No programme listed for now.',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                  ),
                if (next != null) ...[
                  const SizedBox(height: 16),
                  _GuideBlock(
                    label: 'Next',
                    title: next.title,
                    timeRange: '${_fmtTime(next.start)} – ${_fmtTime(next.end)}',
                  ),
                ],
              ],
              const SizedBox(height: 32),
              DpadFocusable(
                region: 'live_detail',
                onSelect: onWatch,
                builder: (context, focused, _) {
                  return GestureDetector(
                    onTap: onWatch,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      decoration: BoxDecoration(
                        color: focused
                            ? AppColors.purple.withValues(alpha: 0.35)
                            : AppColors.darkPurple,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: focused ? AppColors.purpleLight : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
                          SizedBox(width: 8),
                          Text(
                            'Watch channel',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                child: const SizedBox.shrink(),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ChannelDetailPanel extends StatelessWidget {
  final LiveTvChannel channel;
  final EpgProgramme? nowPlaying;
  final EpgProgramme? nextPlaying;
  final bool hasEpg;

  const _ChannelDetailPanel({
    required this.channel,
    required this.nowPlaying,
    required this.nextPlaying,
    required this.hasEpg,
  });

  static String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final logo = channel.logoUrl;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (logo != null && logo.startsWith('http'))
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CachedNetworkImage(
                    imageUrl: logo,
                    width: 120,
                    height: 120,
                    fit: BoxFit.cover,
                    memCacheWidth: 240,
                    errorWidget: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              if (logo != null && logo.startsWith('http')) const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      channel.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (channel.groupTitle != null && channel.groupTitle!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          channel.groupTitle!,
                          style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          const Text(
            'Guide',
            style: TextStyle(
              color: AppColors.purpleLight,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          if (!hasEpg)
            Text(
              channel.tvgId == null
                  ? 'No tvg-id on this channel — add tvg-id in your M3U and an XMLTV URL in settings for the guide.'
                  : 'No programme data for this channel. Check that EPG channel ids match tvg-id in your M3U.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.45),
            )
          else ...[
            if (nowPlaying != null)
              _GuideBlock(
                label: 'Now',
                title: nowPlaying!.title,
                timeRange:
                    '${_fmtTime(nowPlaying!.start)} – ${_fmtTime(nowPlaying!.end)}',
              )
            else
              Text(
                'No programme listed for now.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
              ),
            if (nextPlaying != null) ...[
              const SizedBox(height: 16),
              _GuideBlock(
                label: 'Next',
                title: nextPlaying!.title,
                timeRange:
                    '${_fmtTime(nextPlaying!.start)} – ${_fmtTime(nextPlaying!.end)}',
              ),
            ],
          ],
          const SizedBox(height: 32),
          DpadFocusable(
            region: 'live_detail',
            onSelect: () {
              Navigator.pushNamed(context, '/player', arguments: {
                'magnet': channel.streamUrl,
                'title': channel.name,
                'mediaType': 'movie',
              });
            },
            builder: (context, focused, _) {
              return GestureDetector(
                onTap: () {
                  Navigator.pushNamed(context, '/player', arguments: {
                    'magnet': channel.streamUrl,
                    'title': channel.name,
                    'mediaType': 'movie',
                  });
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  decoration: BoxDecoration(
                    color: focused
                        ? AppColors.purple.withValues(alpha: 0.35)
                        : AppColors.darkPurple,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: focused ? AppColors.purpleLight : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
                      SizedBox(width: 8),
                      Text(
                        'Watch channel',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
            child: const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _GuideBlock extends StatelessWidget {
  final String label;
  final String title;
  final String timeRange;

  const _GuideBlock({
    required this.label,
    required this.title,
    required this.timeRange,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.darkPurple.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: AppColors.purpleLight,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            timeRange,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
