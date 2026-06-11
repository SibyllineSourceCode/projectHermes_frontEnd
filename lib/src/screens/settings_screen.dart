import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/app_settings.dart';

// ── Beacon Palette — Settings Screen ─────────────────────────────────────────
const _bgScaffold = Color(0xFF0E0C0A);
const _bgAppBar = Color(0xFF140E08);
const _bgSection = Color(0xFF1E1C18);
const _bgItemHover = Color(0xFF2A1C10);
const _textPrimary = Color(0xFFE8E4DC);
const _textSecondary = Color(0xFFB0A89E);
const _textMuted = Color(0xFF7A7068);
const _accentAmber = Color(0xFFF59B30);
const _divider = Color(0xFF2A2820);
const _borderSection = Color(0xFF2E2A24);
const _logoutRed = Color(0xFFE07060);

// ─────────────────────────────────────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _durationOptions = [
    (label: '15s', seconds: 15),
    (label: '30s', seconds: 30),
    (label: '1 min', seconds: 60),
    (label: '5 min', seconds: 300),
    (label: '15 min', seconds: 900),
    (label: '30 min', seconds: 1800),
  ];

  Future<void> _logout() async {
    final navigator = Navigator.of(context);
    await FirebaseAuth.instance.signOut();
    navigator.popUntil((route) => route.isFirst);
  }

  void _showDurationPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1610),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 4, bottom: 16),
                    child: Text(
                      'MAX RECORD DURATION',
                      style: TextStyle(
                        color: _textMuted,
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children:
                        _durationOptions.map((opt) {
                          final selected =
                              AppSettings.instance.recordingDurationLimit ==
                              opt.seconds;
                          return GestureDetector(
                            onTap: () async {
                              await AppSettings.instance
                                  .setRecordingDurationLimit(opt.seconds);
                              setSheetState(() {});
                              setState(() {});
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    selected
                                        ? const Color(0xFF4A3010)
                                        : const Color(0xFF2A2820),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color:
                                      selected
                                          ? const Color(0xFFF59B30)
                                          : const Color(0xFF3A3228),
                                  width: selected ? 1.5 : 1,
                                ),
                              ),
                              child: Text(
                                opt.label,
                                style: TextStyle(
                                  color:
                                      selected
                                          ? const Color(0xFFFFC875)
                                          : _textSecondary,
                                  fontFamily: 'Montserrat',
                                  fontWeight:
                                      selected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String get _currentDurationLabel {
    final current = AppSettings.instance.recordingDurationLimit;
    return _durationOptions
        .firstWhere(
          (o) => o.seconds == current,
          orElse: () => (label: '${current}s', seconds: current),
        )
        .label;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgScaffold,
      appBar: AppBar(
        backgroundColor: _bgAppBar,
        foregroundColor: _textPrimary,
        centerTitle: true,
        title: const Text(
          'Settings',
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontWeight: FontWeight.w600,
            color: _textPrimary,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        children: [
          _SectionHeader(label: 'Video'),
          _SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.hd_outlined,
                title: 'Video quality',
                subtitle: '1080p (default)',
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      backgroundColor: Colors.black54,
                      duration: Duration(seconds: 2),
                      content: Text('Resolution changes coming soon.'),
                    ),
                  );
                },
              ),
              _SettingsDivider(),
              _SettingsTile(
                icon: Icons.timer_outlined,
                title: 'Record duration limit',
                subtitle: _currentDurationLabel,
                onTap: _showDurationPicker,
              ),
            ],
          ),
          const SizedBox(height: 28),
          _SectionHeader(label: 'Account'),
          _SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.logout,
                title: 'Log out',
                titleColor: _logoutRed,
                iconColor: _logoutRed,
                showChevron: false,
                onTap: _logout,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Section header label ──────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: _textMuted,
          fontFamily: 'Montserrat',
          fontWeight: FontWeight.w600,
          fontSize: 11,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

// ── Grouped settings card ─────────────────────────────────────────────────────

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _bgSection,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _borderSection, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

// ── Individual setting row ────────────────────────────────────────────────────

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.titleColor = _textPrimary,
    this.iconColor = _accentAmber,
    this.showChevron = true,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color titleColor;
  final Color iconColor;
  final bool showChevron;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashColor: const Color(0x1AFE7E00),
        highlightColor: _bgItemHover.withOpacity(0.4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color:
                      iconColor == _logoutRed
                          ? const Color(0xFF2A1410)
                          : const Color(0xFF2A1C10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: iconColor, size: 18),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: titleColor,
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          color: _textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (showChevron)
                const Icon(Icons.chevron_right, color: _textMuted, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Divider between tiles inside a group ─────────────────────────────────────

class _SettingsDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(left: 64),
      child: Divider(height: 1, color: _divider),
    );
  }
}
