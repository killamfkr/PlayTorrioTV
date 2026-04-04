import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dpad/dpad.dart';
import '../services/app_updater_service.dart';
import '../constants.dart';

class UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  const UpdateDialog({super.key, required this.info});

  /// Show the dialog if an update is available. Call from app startup.
  static Future<void> checkAndShow(BuildContext context) async {
    final info = await AppUpdaterService.checkForUpdate();
    if (info == null) return;
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateDialog(info: info),
    );
  }

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  static const _channel = MethodChannel('com.playtorrio/updater');
  bool _downloading = false;
  double _progress = 0;
  String? _error;

  Future<void> _install() async {
    if (widget.info.apkUrl == null) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
    });

    try {
      final path = await AppUpdaterService.downloadApk(
        widget.info.apkUrl!,
        widget.info.latestVersion,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );

      if (!mounted) return;

      // Trigger native install intent
      if (Platform.isAndroid) {
        await _channel.invokeMethod('installApk', {'path': path});
      }
    } catch (e) {
      if (mounted) setState(() { _downloading = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      autofocus: true,
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 480,
          decoration: BoxDecoration(
            color: const Color(0xFF121212),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 40),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(24),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Colors.white10)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.system_update_rounded, color: Colors.white70, size: 28),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Update Available',
                            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${AppUpdaterService.currentVersion}  →  ${widget.info.latestVersion}',
                            style: const TextStyle(color: Colors.white38, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Release notes
              if (widget.info.releaseNotes.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 160),
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  alignment: Alignment.topLeft,
                  child: SingleChildScrollView(
                    child: Text(
                      widget.info.releaseNotes,
                      style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.5),
                    ),
                  ),
                ),

              // Progress bar
              if (_downloading) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Downloading...', style: TextStyle(color: Colors.white60, fontSize: 13)),
                          Text('${(_progress * 100).toInt()}%', style: const TextStyle(color: Colors.white60, fontSize: 13)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _progress,
                          backgroundColor: Colors.white10,
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                          minHeight: 4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                  child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                ),

              // Buttons
              if (!_downloading)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Expanded(
                        child: DpadFocusable(
                          autofocus: false,
                          onTap: () => Navigator.of(context).pop(),
                          builder: (context, focused, _) => AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: focused ? Colors.white12 : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: focused ? Colors.white30 : Colors.white12),
                            ),
                            child: const Center(
                              child: Text('Later', style: TextStyle(color: Colors.white60, fontSize: 15, fontWeight: FontWeight.w500)),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: DpadFocusable(
                          autofocus: true,
                          onTap: widget.info.apkUrl != null ? _install : null,
                          builder: (context, focused, _) => AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: focused ? Colors.white : const Color(0xFF2A2A2A),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Center(
                              child: Text(
                                widget.info.apkUrl != null ? 'Update Now' : 'No APK Available',
                                style: TextStyle(
                                  color: focused ? Colors.black : Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                const SizedBox(height: 20),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
