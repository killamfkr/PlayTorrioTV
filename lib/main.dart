import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dpad/dpad.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'constants.dart';
import 'screens/home_screen.dart';
import 'screens/details_screen.dart';
import 'screens/search_screen.dart';
import 'screens/player_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/live_tv_screen.dart';
import 'screens/audiobook_screen.dart';
import 'screens/music_screen.dart';

import 'screens/stremio_catalog_screen.dart';
import 'screens/update_dialog.dart';
import 'services/stream_service.dart';
import 'services/settings_service.dart';
import 'services/tmdb_service.dart';
import 'services/continue_watching_service.dart';
import 'services/player_launcher.dart';
import 'services/local_proxy_service.dart';
import 'services/profile_service.dart';
import 'services/app_navigation_bridge.dart';
import 'screens/profile_screen.dart';
import 'build_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  AppNavigationBridge.init();
  await ProfileService.instance.init();
  await SettingsService.instance.init();
  await ContinueWatchingService.load();
  if (kLowRamStartup) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(LocalProxyService().start().catchError((_) {}));
    });
  } else {
    await LocalProxyService().start().catchError((_) {});
  }

  runApp(const PlayTorrioApp());
}

class PlayTorrioApp extends StatelessWidget {
  const PlayTorrioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return DpadNavigator(
      enabled: true,
      focusMemory: const FocusMemoryOptions(enabled: true),
      regionNavigation: RegionNavigationOptions(
        enabled: true,
        rules: [
          // Audiobook screen regions
          RegionNavigationRule(
            fromRegion: 'keyboard',
            toRegion: 'books',
            direction: TraversalDirection.right,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          RegionNavigationRule(
            fromRegion: 'controls',
            toRegion: 'books',
            direction: TraversalDirection.right,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          RegionNavigationRule(
            fromRegion: 'keyboard',
            toRegion: 'controls',
            direction: TraversalDirection.up,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          RegionNavigationRule(
            fromRegion: 'history',
            toRegion: 'books',
            direction: TraversalDirection.down,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          // Music screen regions — only keyboard↕controls needed;
          // all other cross-region nav uses dpad spatial fallback
          // (matching the proven TMDB search pattern)
          RegionNavigationRule(
            fromRegion: 'music_keyboard',
            toRegion: 'music_controls',
            direction: TraversalDirection.up,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          // Sidebar to content
          RegionNavigationRule(
            fromRegion: 'sidebar',
            toRegion: 'keyboard',
            direction: TraversalDirection.right,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          RegionNavigationRule(
            fromRegion: 'sidebar',
            toRegion: 'music_keyboard',
            direction: TraversalDirection.right,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          // Player screen regions
          RegionNavigationRule(
            fromRegion: 'player',
            toRegion: 'chapters',
            direction: TraversalDirection.right,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          RegionNavigationRule(
            fromRegion: 'music_player',
            toRegion: 'music_queue',
            direction: TraversalDirection.right,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          // Details screen — movie torrent mode
          RegionNavigationRule(
            fromRegion: 'tabs',
            toRegion: 'filters',
            direction: TraversalDirection.down,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          RegionNavigationRule(
            fromRegion: 'tabs',
            toRegion: 'sources',
            direction: TraversalDirection.down,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          RegionNavigationRule(
            fromRegion: 'tabs',
            toRegion: 'streams',
            direction: TraversalDirection.down,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          RegionNavigationRule(
            fromRegion: 'tabs',
            toRegion: 'recommendations',
            direction: TraversalDirection.down,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          RegionNavigationRule(
            fromRegion: 'filters',
            toRegion: 'sources',
            direction: TraversalDirection.down,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          RegionNavigationRule(
            fromRegion: 'filters',
            toRegion: 'streams',
            direction: TraversalDirection.down,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          // Details screen — movie streaming mode
          RegionNavigationRule(
            fromRegion: 'actions',
            toRegion: 'recommendations',
            direction: TraversalDirection.down,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          // Details screen — TV show mode
          RegionNavigationRule(
            fromRegion: 'controls',
            toRegion: 'episodes',
            direction: TraversalDirection.down,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          // Stremio catalog screen
          RegionNavigationRule(
            fromRegion: 'sidebar',
            toRegion: 'catalog-grid',
            direction: TraversalDirection.right,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
          RegionNavigationRule(
            fromRegion: 'sidebar',
            toRegion: 'live_channels',
            direction: TraversalDirection.right,
            strategy: RegionNavigationStrategy.memory,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
        ],
      ),
      child: MaterialApp(
        navigatorKey: AppNavigationBridge.navigatorKey,
        title: 'PlayTorrio TV',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: AppColors.background,
          colorScheme: const ColorScheme.dark(
            primary: AppColors.purple,
            surface: AppColors.surface,
          ),
          fontFamily: 'Roboto',
        ),
        home: const _SplashScreen(),
        onGenerateRoute: (settings) {
          if (settings.name == '/details') {
            final args = settings.arguments as Map<String, dynamic>;
            return PageRouteBuilder(
              settings: settings,
              pageBuilder: (context, animation, secondaryAnimation) => DetailsScreen(
                id: args['id'] as int,
                mediaType: args['media_type'] as String,
                stremioItem: args['stremio_item'] as Map<String, dynamic>?,
                autoPlayEpisode: args['auto_play_episode'] as Map<String, dynamic>?,
              ),
              transitionsBuilder: (context, animation, secondaryAnimation, child) {
                return FadeTransition(opacity: animation, child: child);
              },
              transitionDuration: const Duration(milliseconds: 300),
            );
          }
          if (settings.name == '/player') {
            final args = settings.arguments as Map<String, dynamic>;
            return PageRouteBuilder(
              settings: settings,
              pageBuilder: (context, animation, secondaryAnimation) => PlayerScreen(
                magnetUri: args['magnet'] as String,
                title: args['title'] as String,
                episode: args['episode'] as EpisodeTarget?,
                tmdbId: args['tmdbId'] as int?,
                imdbId: args['imdbId'] as String?,
                backdropPath: args['backdropPath'] as String?,
                posterPath: args['posterPath'] as String?,
                mediaType: args['mediaType'] as String? ?? 'movie',
                fileIdx: args['fileIdx'] as int?,
                resumePositionMs: args['resumePositionMs'] as int?,
                logoUrl: args['logoUrl'] as String?,
                nextEpisodePayload: args['nextEpisodePayload'] as String?,
              ),
              transitionsBuilder: (context, animation, secondaryAnimation, child) {
                return FadeTransition(opacity: animation, child: child);
              },
              transitionDuration: const Duration(milliseconds: 200),
            );
          }
          return null;
        },
      ),
    );
  }
}

// --- Splash / Loading Screen ---

class _SplashScreen extends StatefulWidget {
  const _SplashScreen();

  @override
  State<_SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<_SplashScreen> with TickerProviderStateMixin {
  late AnimationController _fadeCtrl;
  late AnimationController _pulseCtrl;
  late Animation<double> _fade;
  late Animation<double> _taglineFade;
  late Animation<double> _pulse;
  String _status = 'Starting engine...';

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(duration: const Duration(milliseconds: 1200), vsync: this);
    _fade = CurvedAnimation(parent: _fadeCtrl, curve: const Interval(0.0, 0.5, curve: Curves.easeOut));
    _taglineFade = CurvedAnimation(parent: _fadeCtrl, curve: const Interval(0.35, 0.75, curve: Curves.easeOut));

    _pulseCtrl = AnimationController(duration: const Duration(milliseconds: 1500), vsync: this);
    _pulse = Tween<double>(begin: 0.4, end: 1.0).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _pulseCtrl.repeat(reverse: true);

    _fadeCtrl.forward();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      setState(() => _status = 'Starting engine...');

      if (kLowRamStartup) {
        await PlayerLauncher.warmup().catchError((_) {});
        if (!mounted) {
          return;
        }
        List<dynamic> trending = [];
        try {
          trending = await TmdbService.getTrending()
              .timeout(const Duration(seconds: 15));
        } catch (_) {
          trending = [];
        }
        // Do not start TorrServer here — overlaps with Home's first TMDB burst on low RAM.
        if (!mounted) {
          return;
        }
        setState(() => _status = 'Loading posters...');
        final futures = <Future<void>>[];
        for (var i = 0; i < trending.length && i < 4; i++) {
          final item = trending[i] as Map<String, dynamic>;
          final poster = item['poster_path'] as String?;
          final backdrop = item['backdrop_path'] as String?;
          if (poster != null && poster.isNotEmpty) {
            futures.add(precacheImage(
              CachedNetworkImageProvider(TmdbApi.posterUrl(poster)),
              context,
            ).catchError((_) {}));
          }
          if (backdrop != null && backdrop.isNotEmpty) {
            futures.add(precacheImage(
              CachedNetworkImageProvider(TmdbApi.backdropUrl(backdrop)),
              context,
            ).catchError((_) {}));
          }
        }
        if (futures.isNotEmpty) {
          try {
            await Future.wait(futures).timeout(const Duration(seconds: 4));
          } catch (_) {}
        }
      } else {
        final tmdbFuture = TmdbService.getTrending();
        await Future.wait([
          StreamService.warmup(),
          PlayerLauncher.warmup(),
          tmdbFuture,
        ].map((f) => f.catchError((_) {})));
        if (!mounted) {
          return;
        }
        setState(() => _status = 'Loading posters...');
        final trending = await tmdbFuture.catchError((_) => <dynamic>[]);
        if (mounted) {
          final futures = <Future<void>>[];
          for (var i = 0; i < trending.length && i < 10; i++) {
            final item = trending[i] as Map<String, dynamic>;
            final poster = item['poster_path'] as String?;
            final backdrop = item['backdrop_path'] as String?;
            if (poster != null && poster.isNotEmpty) {
              futures.add(precacheImage(
                CachedNetworkImageProvider(TmdbApi.posterUrl(poster)),
                context,
              ).catchError((_) {}));
            }
            if (backdrop != null && backdrop.isNotEmpty) {
              futures.add(precacheImage(
                CachedNetworkImageProvider(TmdbApi.backdropUrl(backdrop)),
                context,
              ).catchError((_) {}));
            }
          }
          await Future.wait(futures).timeout(
            const Duration(seconds: 6),
            onTimeout: () => [],
          );
        }
      }
    } catch (_) {}

    if (!mounted) {
      return;
    }
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, _, _) => const ProfileScreen(),
        transitionsBuilder: (_, animation, _, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 600),
      ),
    );
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Logo
            FadeTransition(
              opacity: _fade,
              child: Image.asset(
                AppAssets.playtorrioMark,
                width: 88,
                height: 88,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              ),
            ),
            const SizedBox(height: 24),
            // Title
            FadeTransition(
              opacity: _fade,
              child: const Text(
                'PlayTorrio',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Tagline
            FadeTransition(
              opacity: _taglineFade,
              child: Text(
                'Your Cinema Universe',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 2,
                ),
              ),
            ),
            const SizedBox(height: 48),
            // Loading indicator
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) {
                return Text(
                  _status,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35 * _pulse.value),
                    fontSize: 12,
                    letterSpacing: 0.5,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// --- Main Shell ---

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => MainShellState();
}

class MainShellState extends State<MainShell> with SingleTickerProviderStateMixin {
  static MainShellState? instance;

  /// Notifier for triggering a search from deep links.
  static final ValueNotifier<String?> pendingSearchQuery = ValueNotifier<String?>(null);

  int _selectedNavIndex = 0;
  bool _navExpanded = false;
  late AnimationController _enterCtrl;
  late Animation<double> _navSlide;
  late Animation<double> _contentFade;

  @override
  void initState() {
    super.initState();
    instance = this;
    _enterCtrl = AnimationController(duration: const Duration(milliseconds: 700), vsync: this);
    _navSlide = CurvedAnimation(parent: _enterCtrl, curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic));
    _contentFade = CurvedAnimation(parent: _enterCtrl, curve: const Interval(0.2, 1.0, curve: Curves.easeOut));
    _enterCtrl.forward();
    if (kLowRamStartup) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(seconds: 3), () {
          unawaited(StreamService.warmup().catchError((_) {}));
        });
      });
    }
    // Low-RAM: delay update check so Home TMDB + images aren't concurrent with GitHub fetch.
    Future.delayed(Duration(seconds: kLowRamStartup ? 12 : 2), () {
      if (mounted) UpdateDialog.checkAndShow(context);
    });
  }

  @override
  void dispose() {
    if (instance == this) instance = null;
    _enterCtrl.dispose();
    super.dispose();
  }

  /// Switch to the Search tab and trigger a search with the given query.
  void switchToSearch(String query) {
    setState(() => _selectedNavIndex = 1);
    pendingSearchQuery.value = query;
  }

  final List<_NavItem> _navItems = [
    _NavItem(icon: Icons.home_rounded, label: 'Home'),
    _NavItem(icon: Icons.search_rounded, label: 'Search'),
    _NavItem(icon: Icons.extension_rounded, label: 'Catalogs'),
    _NavItem(icon: Icons.live_tv_rounded, label: 'Live TV'),
    _NavItem(icon: Icons.headphones_rounded, label: 'Audiobooks'),
    _NavItem(icon: Icons.music_note_rounded, label: 'Music'),
    _NavItem(icon: Icons.settings_rounded, label: 'Settings'),
  ];

  Widget _buildCurrentPage() {
    switch (_selectedNavIndex) {
      case 0:
        return const HomeScreen(category: 'home');
      case 1:
        return const SearchScreen();
      case 2:
        return const StremioCatalogScreen();
      case 3:
        return const LiveTvScreen();
      case 4:
        return const AudiobookScreen();
      case 5:
        return const MusicScreen();
      case 6:
        return const SettingsScreen();
      default:
        return const HomeScreen(category: 'home');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Row(
        children: [
          SlideTransition(
            position: Tween<Offset>(begin: const Offset(-1, 0), end: Offset.zero).animate(_navSlide),
            child: _SideNav(
              items: _navItems,
              selectedIndex: _selectedNavIndex,
              expanded: _navExpanded,
              onSelect: (i) => setState(() => _selectedNavIndex = i),
              onExpandChanged: (v) => setState(() => _navExpanded = v),
              onSwitchProfile: () {
                // Save current profile data before navigating away
                Navigator.of(context).pushReplacement(
                  PageRouteBuilder(
                    pageBuilder: (_, _, _) => const ProfileScreen(),
                    transitionsBuilder: (_, animation, _, child) =>
                        FadeTransition(opacity: animation, child: child),
                    transitionDuration: const Duration(milliseconds: 300),
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: FadeTransition(
              opacity: _contentFade,
              child: _buildCurrentPage(),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  _NavItem({required this.icon, required this.label});
}

class _SideNav extends StatelessWidget {
  final List<_NavItem> items;
  final int selectedIndex;
  final bool expanded;
  final ValueChanged<int> onSelect;
  final ValueChanged<bool> onExpandChanged;
  final VoidCallback? onSwitchProfile;

  const _SideNav({
    required this.items,
    required this.selectedIndex,
    required this.expanded,
    required this.onSelect,
    required this.onExpandChanged,
    this.onSwitchProfile,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: expanded ? 180 : 60,
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.95),
        border: Border(
          right: BorderSide(color: AppColors.darkPurple.withValues(alpha: 0.3), width: 1),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 24),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: EdgeInsets.symmetric(horizontal: expanded ? 16 : 8, vertical: 12),
            child: expanded
                ? const Text('PlayTorrio', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.5))
                : Image.asset(
                    AppAssets.playtorrioMark,
                    width: 32,
                    height: 32,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                  ),
          ),
          const SizedBox(height: 24),
          ...List.generate(items.length, (index) {
            return _NavButton(
              item: items[index],
              isSelected: selectedIndex == index,
              expanded: expanded,
              onSelect: () => onSelect(index),
              onFocus: () => onExpandChanged(true),
              onBlur: () => onExpandChanged(false),
            );
          }),
          const Spacer(),
          if (onSwitchProfile != null)
            _ProfileSwitchButton(
              expanded: expanded,
              onSelect: onSwitchProfile!,
              onFocus: () => onExpandChanged(true),
              onBlur: () => onExpandChanged(false),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _NavButton extends StatefulWidget {
  final _NavItem item;
  final bool isSelected;
  final bool expanded;
  final VoidCallback onSelect;
  final VoidCallback onFocus;
  final VoidCallback onBlur;

  const _NavButton({
    required this.item,
    required this.isSelected,
    required this.expanded,
    required this.onSelect,
    required this.onFocus,
    required this.onBlur,
  });

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.isSelected || _isFocused;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: GestureDetector(
        onTap: widget.onSelect,
        child: DpadFocusable(
        region: 'sidebar',
        onFocus: () {
          setState(() => _isFocused = true);
          widget.onFocus();
        },
        onBlur: () {
          setState(() => _isFocused = false);
          widget.onBlur();
        },
        onSelect: widget.onSelect,
        builder: (context, isFocused, child) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(vertical: 12, horizontal: widget.expanded ? 16 : 0),
            decoration: BoxDecoration(
              color: isActive ? AppColors.darkPurple.withValues(alpha: 0.6) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _isFocused ? AppColors.purpleLight : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: widget.expanded
                ? Row(
                    children: [
                      Icon(
                        widget.item.icon,
                        color: isActive ? AppColors.purpleLight : AppColors.textSecondary,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.item.label,
                          style: TextStyle(
                            color: isActive ? AppColors.textPrimary : AppColors.textSecondary,
                            fontSize: 14,
                            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  )
                : Center(
                    child: Icon(
                      widget.item.icon,
                      color: isActive ? AppColors.purpleLight : AppColors.textSecondary,
                      size: 22,
                    ),
                  ),
          );
        },
        child: const SizedBox.shrink(),
      ),
      ),
    );
  }
}

class _ProfileSwitchButton extends StatefulWidget {
  final bool expanded;
  final VoidCallback onSelect;
  final VoidCallback onFocus;
  final VoidCallback onBlur;

  const _ProfileSwitchButton({
    required this.expanded,
    required this.onSelect,
    required this.onFocus,
    required this.onBlur,
  });

  @override
  State<_ProfileSwitchButton> createState() => _ProfileSwitchButtonState();
}

class _ProfileSwitchButtonState extends State<_ProfileSwitchButton> {
  static const List<Color> _colors = [
    Color(0xFFE50914),
    Color(0xFF0071EB),
    Color(0xFF46D369),
    Color(0xFFF5C518),
    Color(0xFFB4A7D6),
  ];
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final profile = ProfileService.instance.activeProfile;
    final color = _colors[profile.colorIndex % _colors.length];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: GestureDetector(
        onTap: widget.onSelect,
        child: DpadFocusable(
          region: 'sidebar',
          onFocus: () {
            setState(() => _isFocused = true);
            widget.onFocus();
          },
          onBlur: () {
            setState(() => _isFocused = false);
            widget.onBlur();
          },
          onSelect: widget.onSelect,
          builder: (context, focused, child) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.symmetric(
                  vertical: 10, horizontal: widget.expanded ? 12 : 0),
              decoration: BoxDecoration(
                color: _isFocused
                    ? AppColors.darkPurple.withValues(alpha: 0.6)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      _isFocused ? AppColors.purpleLight : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: widget.expanded
                  ? Row(
                      children: [
                        Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Center(
                            child: Text(
                              profile.name.isNotEmpty
                                  ? profile.name[0].toUpperCase()
                                  : 'P',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            profile.name,
                            style: TextStyle(
                              color: _isFocused
                                  ? AppColors.textPrimary
                                  : AppColors.textSecondary,
                              fontSize: 13,
                              fontWeight: _isFocused
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    )
                  : Center(
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text(
                            profile.name.isNotEmpty
                                ? profile.name[0].toUpperCase()
                                : 'P',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
            );
          },
          child: const SizedBox.shrink(),
        ),
      ),
    );
  }
}
