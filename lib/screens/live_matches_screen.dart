import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dpad/dpad.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../constants.dart';
import '../services/live_match_service.dart';

class LiveMatchesScreen extends StatefulWidget {
  const LiveMatchesScreen({super.key});

  @override
  State<LiveMatchesScreen> createState() => _LiveMatchesScreenState();
}

class _LiveMatchesScreenState extends State<LiveMatchesScreen> {
  List<SportCategory> _sports = [];
  List<LiveMatch> _matches = [];
  String _selectedSport = 'live';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSports();
    _loadMatches();
  }

  Future<void> _loadSports() async {
    final sports = await LiveMatchService.getSports();
    if (mounted) setState(() => _sports = sports);
  }

  Future<void> _loadMatches() async {
    setState(() => _loading = true);
    List<LiveMatch> matches;
    if (_selectedSport == 'live') {
      matches = await LiveMatchService.getLiveMatches();
    } else if (_selectedSport == 'all') {
      matches = await LiveMatchService.getAllMatches();
    } else {
      matches = await LiveMatchService.getMatches(_selectedSport);
    }
    if (mounted) setState(() { _matches = matches; _loading = false; });
  }

  void _selectSport(String sport) {
    if (sport == _selectedSport) return;
    _selectedSport = sport;
    _loadMatches();
  }

  void _openMatch(LiveMatch match) async {
    if (match.sources.isEmpty) return;

    // Get streams for first source
    final src = match.sources.first;
    final streams = await LiveMatchService.getStreams(src.source, src.id);
    if (streams.isEmpty || !mounted) return;

    // Pick first HD stream, fallback to first
    final stream = streams.firstWhere((s) => s.hd, orElse: () => streams.first);

    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _MatchPlayerPage(
        match: match,
        embedUrl: stream.embedUrl,
        allStreams: streams,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Sport filter tabs
        SizedBox(
          height: 50,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              _SportTab(label: 'LIVE', id: 'live', selected: _selectedSport == 'live', onTap: () => _selectSport('live')),
              _SportTab(label: 'All', id: 'all', selected: _selectedSport == 'all', onTap: () => _selectSport('all')),
              for (final s in _sports)
                _SportTab(label: s.name, id: s.id, selected: _selectedSport == s.id, onTap: () => _selectSport(s.id)),
            ],
          ),
        ),
        // Match grid
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : _matches.isEmpty
                  ? Center(child: Text('No matches found', style: TextStyle(color: AppColors.textSecondary, fontSize: 16)))
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        childAspectRatio: 2.2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: _matches.length,
                      itemBuilder: (_, i) => _MatchCard(
                        match: _matches[i],
                        onTap: () => _openMatch(_matches[i]),
                      ),
                    ),
        ),
      ],
    );
  }
}

// ─── Sport filter tab ───

class _SportTab extends StatelessWidget {
  final String label;
  final String id;
  final bool selected;
  final VoidCallback onTap;

  const _SportTab({required this.label, required this.id, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: DpadFocusable(
        autofocus: id == 'live',
        onSelect: onTap,
        builder: (context, isFocused, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white
                : isFocused
                    ? Colors.white24
                    : AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(20),
            border: isFocused ? Border.all(color: Colors.white, width: 2) : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.black : Colors.white,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Match card ───

class _MatchCard extends StatelessWidget {
  final LiveMatch match;
  final VoidCallback onTap;

  const _MatchCard({required this.match, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final time = DateTime.fromMillisecondsSinceEpoch(match.date);
    final now = DateTime.now();
    final isLive = time.isBefore(now);
    final timeStr = isLive
        ? 'LIVE'
        : '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return DpadFocusable(
      onSelect: onTap,
      builder: (context, isFocused, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: isFocused ? AppColors.surfaceLight : AppColors.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isFocused ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // Home badge
            if (match.homeBadge != null)
              CachedNetworkImage(
                imageUrl: LiveMatchService.badgeUrl(match.homeBadge),
                width: 36,
                height: 36,
                errorWidget: (_, __, ___) => const Icon(Icons.sports, color: Colors.white54, size: 36),
              )
            else
              const Icon(Icons.sports, color: Colors.white54, size: 36),
            const SizedBox(width: 10),
            // Match info
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    match.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (isLive)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                        )
                      else
                        Text(timeStr, style: TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                      const SizedBox(width: 8),
                      Text(
                        match.category.toUpperCase(),
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 10),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Away badge
            if (match.awayBadge != null)
              CachedNetworkImage(
                imageUrl: LiveMatchService.badgeUrl(match.awayBadge),
                width: 36,
                height: 36,
                errorWidget: (_, __, ___) => const Icon(Icons.sports, color: Colors.white54, size: 36),
              )
            else
              const Icon(Icons.sports, color: Colors.white54, size: 36),
          ],
        ),
      ),
    );
  }
}

// ─── Match player page with WebView, virtual mouse, ad bypass, X button ───

/// Known ad / tracking domains to block inside the embed iframe.
const _adDomains = <String>[
  'doubleclick.net',
  'googlesyndication.com',
  'googleadservices.com',
  'adservice.google.com',
  'facebook.com/tr',
  'connect.facebook.net',
  'amazon-adsystem.com',
  'adnxs.com',
  'adsrvr.org',
  'ads-twitter.com',
  'taboola.com',
  'outbrain.com',
  'popads.net',
  'popcash.net',
  'propellerads.com',
  'pushame.com',
  'juicyads.com',
  'exoclick.com',
  'trafficjunky.com',
  'betrad.com',
  'marphezis.com',
  'tsyndicate.com',
  'a-ads.com',
  'ad.plus',
  'hilltopads.net',
  'clickadu.com',
  'onclkds.com',
  'vooservers.com',
  'acdn.adnxs.com',
  'cdn.adsafeprotected.com',
  'static.adsafeprotected.com',
  'pagead2.googlesyndication.com',
  'tpc.googlesyndication.com',
  'securepubads.g.doubleclick.net',
  'ad.doubleclick.net',
  'cm.g.doubleclick.net',
  'stats.wp.com',
  'pixel.wp.com',
  'scorecardresearch.com',
  'sb.scorecardresearch.com',
  'b.scorecardresearch.com',
];

/// JavaScript injected into the WebView to:
/// 1. Silently open ads in a hidden iframe so the stream thinks they loaded
/// 2. Block pop-ups / window.open
/// 3. Prevent overlay clicks from navigating away
const _adBypassJs = '''
(function() {
  // Intercept window.open — create a hidden iframe instead of opening a popup
  window.open = function(url) {
    if (!url) return null;
    try {
      var f = document.createElement('iframe');
      f.style.cssText = 'width:0;height:0;border:0;position:absolute;left:-9999px';
      f.src = url;
      document.body.appendChild(f);
      setTimeout(function() { try { f.remove(); } catch(e) {} }, 5000);
    } catch(e) {}
    // Return a fake window object so callers don't crash
    return { closed: false, close: function(){}, focus: function(){}, document: document };
  };

  // Block pop-under / popups via addEventListener
  var origAdd = EventTarget.prototype.addEventListener;
  EventTarget.prototype.addEventListener = function(type, fn, opts) {
    if (type === 'click' || type === 'mousedown' || type === 'pointerdown') {
      var wrapped = function(e) {
        // Let the event fire but suppress any window.open side-effects
        // (window.open is already patched above)
        return fn.call(this, e);
      };
      return origAdd.call(this, type, wrapped, opts);
    }
    return origAdd.call(this, type, fn, opts);
  };

  // Remove common ad overlay divs periodically
  setInterval(function() {
    var overlays = document.querySelectorAll(
      '[id*="ad"], [class*="ad-overlay"], [class*="popup"], [id*="overlay"],' +
      '[class*="banner"], [id*="banner"], [class*="modal"]'
    );
    overlays.forEach(function(el) {
      // Only remove if it looks like an ad (not the player itself)
      var rect = el.getBoundingClientRect();
      if (rect.width > 100 && rect.height > 100) {
        var vid = el.querySelector('video');
        if (!vid) el.style.display = 'none';
      }
    });
  }, 2000);
})();
''';

class _MatchPlayerPage extends StatefulWidget {
  final LiveMatch match;
  final String embedUrl;
  final List<MatchStream> allStreams;

  const _MatchPlayerPage({required this.match, required this.embedUrl, required this.allStreams});

  @override
  State<_MatchPlayerPage> createState() => _MatchPlayerPageState();
}

class _MatchPlayerPageState extends State<_MatchPlayerPage> {
  WebViewController? _webCtrl;
  bool _mouseMode = false;
  double _mouseX = 0;
  double _mouseY = 0;
  bool _showCloseBtn = true;
  String _currentUrl = '';
  final FocusNode _mouseFocus = FocusNode();
  static const double _mouseSpeed = 8.0;
  bool get _supportsWebView => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.embedUrl;
    if (_supportsWebView) _initWebView();
  }

  void _initWebView() {
    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) {
          final url = req.url.toLowerCase();
          for (final d in _adDomains) {
            if (url.contains(d)) {
              debugPrint('[LiveMatch] Blocked ad: ${req.url}');
              return NavigationDecision.prevent;
            }
          }
          return NavigationDecision.navigate;
        },
        onPageFinished: (_) {
          _webCtrl?.runJavaScript(_adBypassJs);
        },
      ))
      ..setUserAgent('Mozilla/5.0 (Linux; Android 12; TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36')
      ..loadRequest(Uri.parse(_currentUrl));
    _webCtrl = ctrl;
  }

  void _enterMouseMode() {
    final size = MediaQuery.of(context).size;
    setState(() {
      _mouseMode = true;
      _mouseX = size.width / 2;
      _mouseY = size.height / 2;
      _showCloseBtn = true;
    });
    _mouseFocus.requestFocus();
  }

  void _exitMouseMode() {
    setState(() {
      _mouseMode = false;
      _showCloseBtn = false;
    });
    Navigator.of(context).pop();
  }

  void _handleMouseKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;

    final size = MediaQuery.of(context).size;
    setState(() {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
          _mouseY = (_mouseY - _mouseSpeed).clamp(0, size.height);
          break;
        case LogicalKeyboardKey.arrowDown:
          _mouseY = (_mouseY + _mouseSpeed).clamp(0, size.height);
          break;
        case LogicalKeyboardKey.arrowLeft:
          _mouseX = (_mouseX - _mouseSpeed).clamp(0, size.width);
          break;
        case LogicalKeyboardKey.arrowRight:
          _mouseX = (_mouseX + _mouseSpeed).clamp(0, size.width);
          break;
        case LogicalKeyboardKey.select:
        case LogicalKeyboardKey.enter:
          // Check if clicking the X button
          if (_isOverCloseButton()) {
            _exitMouseMode();
            return;
          }
          // Simulate click in WebView
          _simulateClick();
          break;
        case LogicalKeyboardKey.escape:
        case LogicalKeyboardKey.goBack:
          _exitMouseMode();
          break;
        default:
          break;
      }
    });
  }

  bool _isOverCloseButton() {
    // X button is top-right, 48x48
    final size = MediaQuery.of(context).size;
    return _mouseX >= size.width - 64 && _mouseX <= size.width - 8 && _mouseY >= 8 && _mouseY <= 64;
  }

  void _simulateClick() {
    // Use JS to dispatch a click at the cursor coordinates relative to the WebView
    // The WebView takes the full screen, so coordinates map directly
    _webCtrl?.runJavaScript('''
      (function() {
        var el = document.elementFromPoint(${_mouseX.toInt()}, ${_mouseY.toInt()});
        if (el) {
          var evt = new MouseEvent('click', {
            bubbles: true, cancelable: true, view: window,
            clientX: ${_mouseX.toInt()}, clientY: ${_mouseY.toInt()}
          });
          el.dispatchEvent(evt);
        }
      })();
    ''');
  }

  void _switchStream(MatchStream stream) {
    setState(() => _currentUrl = stream.embedUrl);
    _webCtrl?.loadRequest(Uri.parse(stream.embedUrl));
  }

  @override
  void dispose() {
    _mouseFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: KeyboardListener(
        focusNode: _mouseFocus,
        autofocus: true,
        onKeyEvent: _mouseMode ? _handleMouseKey : _handleBrowseKey,
        child: Stack(
          children: [
            // WebView (full screen) or platform fallback
            Positioned.fill(
              child: _webCtrl != null
                  ? WebViewWidget(controller: _webCtrl!)
                  : Center(
                      child: Text(
                        'Live streams are only available on Android TV',
                        style: TextStyle(color: Colors.white54, fontSize: 16),
                      ),
                    ),
            ),

            // Stream source picker (top-left, only when not in mouse mode)
            if (!_mouseMode && widget.allStreams.length > 1)
              Positioned(
                top: 12,
                left: 12,
                child: Row(
                  children: [
                    for (final s in widget.allStreams)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: DpadFocusable(
                          onSelect: () => _switchStream(s),
                          builder: (_, focused, __) => Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: s.embedUrl == _currentUrl
                                  ? Colors.white
                                  : focused
                                      ? Colors.white30
                                      : Colors.black54,
                              borderRadius: BorderRadius.circular(8),
                              border: focused ? Border.all(color: Colors.white, width: 2) : null,
                            ),
                            child: Text(
                              '${s.source.toUpperCase()} ${s.hd ? "HD" : "SD"} ${s.language}',
                              style: TextStyle(
                                color: s.embedUrl == _currentUrl ? Colors.black : Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

            // Enter mouse mode button (bottom center)
            if (!_mouseMode)
              Positioned(
                bottom: 20,
                left: 0,
                right: 0,
                child: Center(
                  child: DpadFocusable(
                    onSelect: _enterMouseMode,
                    builder: (_, focused, __) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      decoration: BoxDecoration(
                        color: focused ? Colors.white : Colors.black54,
                        borderRadius: BorderRadius.circular(24),
                        border: focused ? Border.all(color: Colors.white, width: 2) : null,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.mouse, color: focused ? Colors.black : Colors.white, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'Enter Mouse Mode',
                            style: TextStyle(color: focused ? Colors.black : Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // Mouse cursor
            if (_mouseMode)
              Positioned(
                left: _mouseX - 12,
                top: _mouseY - 4,
                child: IgnorePointer(
                  child: CustomPaint(
                    size: const Size(24, 28),
                    painter: _CursorPainter(),
                  ),
                ),
              ),

            // X close button (top-right, always visible in mouse mode)
            if (_mouseMode && _showCloseBtn)
              Positioned(
                top: 12,
                right: 12,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: _isOverCloseButton() ? Colors.red : Colors.black54,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 28),
                ),
              ),

            // Back button hint (non-mouse mode)
            if (!_mouseMode)
              Positioned(
                top: 12,
                right: 12,
                child: DpadFocusable(
                  onSelect: () => Navigator.of(context).pop(),
                  builder: (_, focused, __) => Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: focused ? Colors.white : Colors.black54,
                      shape: BoxShape.circle,
                      border: focused ? Border.all(color: Colors.white, width: 2) : null,
                    ),
                    child: Icon(Icons.arrow_back, color: focused ? Colors.black : Colors.white, size: 20),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _handleBrowseKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.escape || event.logicalKey == LogicalKeyboardKey.goBack) {
      Navigator.of(context).pop();
    }
  }
}

// ─── Custom cursor painter ───

class _CursorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white..style = PaintingStyle.fill;
    final border = Paint()..color = Colors.black..style = PaintingStyle.stroke..strokeWidth = 1.5;

    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, size.height * 0.85)
      ..lineTo(size.width * 0.3, size.height * 0.65)
      ..lineTo(size.width * 0.5, size.height)
      ..lineTo(size.width * 0.65, size.height * 0.92)
      ..lineTo(size.width * 0.45, size.height * 0.6)
      ..lineTo(size.width * 0.75, size.height * 0.55)
      ..close();

    canvas.drawPath(path, paint);
    canvas.drawPath(path, border);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
