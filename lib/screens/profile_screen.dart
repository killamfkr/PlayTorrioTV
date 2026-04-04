import 'package:flutter/material.dart';
import 'package:dpad/dpad.dart';
import '../constants.dart';
import '../services/profile_service.dart';
import '../main.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  static const List<Color> profileColors = [
    Color(0xFFE50914), // Red
    Color(0xFF0071EB), // Blue
    Color(0xFF46D369), // Green
    Color(0xFFF5C518), // Yellow
    Color(0xFFB4A7D6), // Lavender
  ];

  late AnimationController _fadeCtrl;
  bool _manageMode = false;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    )..forward();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _selectProfile(String id) async {
    if (id != ProfileService.instance.activeProfileId) {
      await ProfileService.instance.selectProfile(id);
    }
    if (mounted) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const MainShell(),
          transitionsBuilder: (_, animation, __, child) =>
              FadeTransition(opacity: animation, child: child),
          transitionDuration: const Duration(milliseconds: 600),
        ),
      );
    }
  }

  Future<void> _addProfile() async {
    // Create profile then immediately open name editor
    final profile = await ProfileService.instance.addProfile();
    if (profile != null && mounted) {
      setState(() {});
      _openNameEditor(profile.id, profile.name);
    }
  }

  Future<void> _openNameEditor(String profileId, String currentName, {bool canDelete = false}) async {
    final result = await Navigator.of(context).push<String>(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, __, ___) =>
            _NameEditorOverlay(initialName: currentName, canDelete: canDelete),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
    if (result == _NameEditorOverlay.deleteResult) {
      await _deleteProfile(profileId);
    } else if (result != null && result.isNotEmpty && mounted) {
      await ProfileService.instance.renameProfile(profileId, result);
      setState(() {});
    }
  }

  Future<void> _editProfile(Profile p) async {
    _openNameEditor(p.id, p.name, canDelete: !p.isDefault);
  }

  Future<void> _deleteProfile(String id) async {
    await ProfileService.instance.removeProfile(id);
    if (mounted) {
      setState(() {
        if (ProfileService.instance.profiles.length <= 1) _manageMode = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ProfileService.instance.profiles;
    final canAdd = profiles.length < ProfileService.maxProfiles;

    return Scaffold(
      backgroundColor: Colors.black,
      body: FadeTransition(
        opacity: _fadeCtrl,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Who\'s watching?',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 36,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 48),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final p in profiles)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: _ProfileTile(
                        profile: p,
                        color:
                            profileColors[p.colorIndex % profileColors.length],
                        manageMode: _manageMode,
                        isActive:
                            p.id == ProfileService.instance.activeProfileId,
                        onSelect: () => _selectProfile(p.id),
                        onEdit: () => _editProfile(p),
                        onDelete:
                            p.isDefault ? null : () => _deleteProfile(p.id),
                      ),
                    ),
                  if (canAdd && !_manageMode)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: _AddProfileTile(onSelect: _addProfile),
                    ),
                ],
              ),
              const SizedBox(height: 48),
              if (profiles.length > 1)
                _ManageButton(
                  manageMode: _manageMode,
                  onSelect: () => setState(() => _manageMode = !_manageMode),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Profile tile
// ---------------------------------------------------------------------------

class _ProfileTile extends StatefulWidget {
  final Profile profile;
  final Color color;
  final bool manageMode;
  final bool isActive;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;

  const _ProfileTile({
    required this.profile,
    required this.color,
    required this.manageMode,
    required this.isActive,
    required this.onSelect,
    required this.onEdit,
    this.onDelete,
  });

  @override
  State<_ProfileTile> createState() => _ProfileTileState();
}

class _ProfileTileState extends State<_ProfileTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return DpadFocusable(
      autofocus: widget.isActive && !widget.manageMode,
      onSelect:
          widget.manageMode ? widget.onEdit : widget.onSelect,
      onFocus: () => setState(() => _focused = true),
      onBlur: () => setState(() => _focused = false),
      builder: (context, focused, child) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: _focused ? 120 : 110,
              height: _focused ? 120 : 110,
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _focused ? Colors.white : Colors.transparent,
                  width: 3,
                ),
              ),
              child: Stack(
                children: [
                  Center(
                    child: widget.manageMode
                        ? const Icon(Icons.edit, color: Colors.white, size: 36)
                        : Text(
                            widget.profile.name.isNotEmpty
                                ? widget.profile.name[0].toUpperCase()
                                : 'P',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 48,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              widget.profile.name,
              style: TextStyle(
                color: _focused ? Colors.white : Colors.grey,
                fontSize: 14,
                fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Add-profile tile
// ---------------------------------------------------------------------------

class _AddProfileTile extends StatefulWidget {
  final VoidCallback onSelect;
  const _AddProfileTile({required this.onSelect});

  @override
  State<_AddProfileTile> createState() => _AddProfileTileState();
}

class _AddProfileTileState extends State<_AddProfileTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return DpadFocusable(
      onSelect: widget.onSelect,
      onFocus: () => setState(() => _focused = true),
      onBlur: () => setState(() => _focused = false),
      builder: (context, focused, child) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: _focused ? 120 : 110,
              height: _focused ? 120 : 110,
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _focused
                      ? Colors.white
                      : Colors.grey.withValues(alpha: 0.4),
                  width: _focused ? 3 : 2,
                ),
              ),
              child: Center(
                child: Icon(
                  Icons.add,
                  color: _focused
                      ? Colors.white
                      : Colors.grey.withValues(alpha: 0.6),
                  size: 48,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Add Profile',
              style: TextStyle(
                color: _focused ? Colors.white : Colors.grey,
                fontSize: 14,
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Manage-profiles button
// ---------------------------------------------------------------------------

class _ManageButton extends StatefulWidget {
  final bool manageMode;
  final VoidCallback onSelect;
  const _ManageButton({required this.manageMode, required this.onSelect});

  @override
  State<_ManageButton> createState() => _ManageButtonState();
}

class _ManageButtonState extends State<_ManageButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return DpadFocusable(
      onSelect: widget.onSelect,
      onFocus: () => setState(() => _focused = true),
      onBlur: () => setState(() => _focused = false),
      builder: (context, focused, child) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(
              color: _focused
                  ? Colors.white
                  : Colors.grey.withValues(alpha: 0.5),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            widget.manageMode ? 'Done' : 'Manage Profiles',
            style: TextStyle(
              color: _focused ? Colors.white : Colors.grey,
              fontSize: 14,
              letterSpacing: 1,
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// On-screen keyboard overlay for naming profiles
// ---------------------------------------------------------------------------

class _NameEditorOverlay extends StatefulWidget {
  static const deleteResult = '\x00DELETE';

  final String initialName;
  final bool canDelete;
  const _NameEditorOverlay({required this.initialName, this.canDelete = false});

  @override
  State<_NameEditorOverlay> createState() => _NameEditorOverlayState();
}

class _NameEditorOverlayState extends State<_NameEditorOverlay> {
  static const _letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const _numbers = '0123456789';
  static const _gridCols = 6;

  late String _name;

  @override
  void initState() {
    super.initState();
    _name = widget.initialName;
  }

  void _addChar(String c) => setState(() {
        if (_name.length < 16) _name += c;
      });
  void _addSpace() => setState(() {
        if (_name.length < 16) _name += ' ';
      });
  void _backspace() => setState(() {
        if (_name.isNotEmpty) _name = _name.substring(0, _name.length - 1);
      });
  void _clear() => setState(() => _name = '');
  void _save() => Navigator.of(context).pop(_name.trim());
  void _cancel() => Navigator.of(context).pop(null);
  void _delete() => Navigator.of(context).pop(_NameEditorOverlay.deleteResult);

  @override
  Widget build(BuildContext context) {
    final allChars = _letters.split('') + _numbers.split('');

    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.85),
      body: Center(
        child: Container(
          width: 480,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Profile Name',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 20),
              // Name display
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.darkPurple, width: 1),
                ),
                child: Text(
                  _name.isEmpty ? 'Enter name...' : _name,
                  style: TextStyle(
                    color:
                        _name.isEmpty ? AppColors.textDim : AppColors.textPrimary,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Letter grid
              SizedBox(
                height: 260,
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _gridCols,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                    childAspectRatio: 1.5,
                  ),
                  itemCount: allChars.length + 3,
                  itemBuilder: (context, index) {
                    if (index < allChars.length) {
                      return _NameKey(
                        label: allChars[index],
                        onSelect: () => _addChar(allChars[index].toLowerCase()),
                        autofocus: index == 0,
                      );
                    } else if (index == allChars.length) {
                      return _NameKey(label: '␣', onSelect: _addSpace);
                    } else if (index == allChars.length + 1) {
                      return _NameKey(label: '⌫', onSelect: _backspace);
                    } else {
                      return _NameKey(label: 'CLR', onSelect: _clear);
                    }
                  },
                ),
              ),
              const SizedBox(height: 16),
              // Save / Cancel / Delete buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _ActionBtn(label: 'Save', onSelect: _save),
                  const SizedBox(width: 16),
                  _ActionBtn(label: 'Cancel', onSelect: _cancel),
                  if (widget.canDelete) ...[
                    const SizedBox(width: 16),
                    _ActionBtn(label: 'Delete', onSelect: _delete, destructive: true),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Keyboard key for name editor
// ---------------------------------------------------------------------------

class _NameKey extends StatefulWidget {
  final String label;
  final VoidCallback onSelect;
  final bool autofocus;
  const _NameKey({
    required this.label,
    required this.onSelect,
    this.autofocus = false,
  });

  @override
  State<_NameKey> createState() => _NameKeyState();
}

class _NameKeyState extends State<_NameKey> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onSelect,
      child: DpadFocusable(
        autofocus: widget.autofocus,
        onFocus: () => setState(() => _focused = true),
        onBlur: () => setState(() => _focused = false),
        onSelect: widget.onSelect,
        builder: (context, focused, child) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _focused ? AppColors.purple : AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: _focused ? AppColors.purpleLight : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                color:
                    _focused ? AppColors.textPrimary : AppColors.textSecondary,
                fontSize: 15,
                fontWeight: _focused ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          );
        },
        child: const SizedBox.shrink(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Action button (Save / Cancel)
// ---------------------------------------------------------------------------

class _ActionBtn extends StatefulWidget {
  final String label;
  final VoidCallback onSelect;
  final bool destructive;
  const _ActionBtn({required this.label, required this.onSelect, this.destructive = false});

  @override
  State<_ActionBtn> createState() => _ActionBtnState();
}

class _ActionBtnState extends State<_ActionBtn> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return DpadFocusable(
      onSelect: widget.onSelect,
      onFocus: () => setState(() => _focused = true),
      onBlur: () => setState(() => _focused = false),
      builder: (context, focused, child) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 10),
          decoration: BoxDecoration(
            color: _focused
                ? (widget.destructive
                    ? Colors.red.withValues(alpha: 0.3)
                    : Colors.white.withValues(alpha: 0.15))
                : Colors.transparent,
            border: Border.all(
              color: _focused
                  ? (widget.destructive ? Colors.red : Colors.white)
                  : Colors.grey.withValues(alpha: 0.5),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: _focused
                  ? (widget.destructive ? Colors.red[300]! : Colors.white)
                  : Colors.grey,
              fontSize: 14,
              fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
              letterSpacing: 1,
            ),
          ),
        );
      },
    );
  }
}
