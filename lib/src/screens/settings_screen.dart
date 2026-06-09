import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

// ── Beacon Palette — Settings Screen ─────────────────────────────────────────
//  Charcoal/wood base with ember accents showing through on setting items
// ─────────────────────────────────────────────────────────────────────────────

const _bgScaffold = Color(0xFF0E0C0A);
const _bgAppBar = Color(0xFF140E08);
const _bgSection = Color(0xFF1E1C18); // warm charcoal — setting group bg
const _bgItemHover = Color(0xFF2A1C10); // Ember800 — pressed/hover state

const _textPrimary = Color(0xFFE8E4DC); // warm off-white
const _textSecondary = Color(0xFFB0A89E); // Smoke200 — subtitles
const _textMuted = Color(0xFF7A7068); // Smoke400 — section headers
const _textAccent = Color(0xFFFFC875); // Flame200 — ember highlight
const _accentOrange = Color(0xFFFE7E00); // Brand orange
const _accentAmber = Color(0xFFF59B30); // Flame400 — leading icons

const _divider = Color(0xFF2A2820); // subtle warm-gray line
const _borderSection = Color(0xFF2E2A24); // card border

const _logoutRed = Color(
  0xFFE07060,
); // muted warm red — on-brand vs harsh Colors.red

// ─────────────────────────────────────────────────────────────────────────────

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _logout(BuildContext context) async {
    await FirebaseAuth.instance.signOut();
    Navigator.of(context).pushNamedAndRemoveUntil('/signup', (route) => false);
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
          // ── Video section ──────────────────────────────────────────────
          _SectionHeader(label: 'Video'),
          _SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.hd_outlined,
                title: 'Video quality',
                subtitle: '1080p (default)',
                onTap: () {},
              ),
              _SettingsDivider(),
              _SettingsTile(
                icon: Icons.timer_outlined,
                title: 'Record duration limit',
                subtitle: 'TBD',
                onTap: () {},
              ),
            ],
          ),

          const SizedBox(height: 28),

          // ── Account section ────────────────────────────────────────────
          _SectionHeader(label: 'Account'),
          _SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.logout,
                title: 'Log out',
                titleColor: _logoutRed,
                iconColor: _logoutRed,
                showChevron: false,
                onTap: () => _logout(context),
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
              // Icon in a warm ember-tinted container
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color:
                      iconColor == _logoutRed
                          ? const Color(0xFF2A1410) // dark red-brown for logout
                          : const Color(
                            0xFF2A1C10,
                          ), // Ember800 for normal items
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: iconColor, size: 18),
              ),
              const SizedBox(width: 14),
              // Title + subtitle
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
      padding: EdgeInsets.only(left: 64), // indented past the icon
      child: Divider(height: 1, color: _divider),
    );
  }
}
