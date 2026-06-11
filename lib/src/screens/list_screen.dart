import 'dart:io';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/app_settings.dart';

// ── Beacon Palette — Lists Screen ────────────────────────────────────────────
//
//  Charcoal/wood base (matches My Videos tab)
//    _bgScaffold   #0E0C0A   near-black warm — page background
//    _bgAppBar     #140E08   Smoke900
//    _bgCard       #1E1C18   dark warm charcoal — list cards
//    _bgCardActive #2A1C10   Ember800 tint — active card wash
//    _bgAddTile    #2E2A24   slightly lighter charcoal — add button tile
//    _bgSheet      #1A1610   bottom sheet background
//    _bgMembersBox #28201A   members section container
//
//  Text
//    _textPrimary    #E8E4DC   warm off-white
//    _textSecondary  #B0A89E   Smoke200
//    _textMuted      #7A7068   Smoke400
//    _textAccent     #FFC875   Flame200 — active badge text, Done button
//
//  Accents
//    _accentOrange   #FE7E00   Brand orange — tab indicator, active tint
//    _accentAmber    #F59B30   Flame400 — icons, check marks
//    _accentAmberDim #C06A00   Flame600 — borders
//
//  Active card
//    _activeBadgeBg  #4A2200   Flame900
//    _activeBadgeText #FFC875  Flame200
//
//  Dividers / borders
//    _divider        #2A2820   subtle warm-gray line
//    _borderInput    #484038   Smoke600 — text field border
//
// ─────────────────────────────────────────────────────────────────────────────

const _bgScaffold = Color(0xFF0E0C0A);
const _bgAppBar = Color(0xFF140E08);
const _bgCard = Color(0xFF1E1C18);
const _bgCardActive = Color(0xFF2A1C10);
const _bgAddTile = Color(0xFF2E2A24);
const _bgSheet = Color(0xFF1A1610);
const _bgMembersBox = Color(0xFF28201A);

const _textPrimary = Color(0xFFE8E4DC);
const _textSecondary = Color(0xFFB0A89E);
const _textMuted = Color(0xFF7A7068);
const _textAccent = Color(0xFFFFC875);

const _accentOrange = Color(0xFFFE7E00);
const _accentAmber = Color(0xFFF59B30);
const _accentAmberDim = Color(0xFFC06A00);

const _activeBadgeBg = Color(0xFF4A2200);
const _activeBadgeText = Color(0xFFFFC875);

const _divider = Color(0xFF2A2820);
const _borderInput = Color(0xFF484038);

// ─────────────────────────────────────────────────────────────────────────────

class ListItem {
  final String id;
  final String title;

  const ListItem({required this.id, required this.title});

  factory ListItem.fromJson(Map<String, dynamic> json) {
    return ListItem(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? json['name'] ?? 'Untitled').toString(),
    );
  }

  ListItem copyWith({String? id, String? title}) {
    return ListItem(id: id ?? this.id, title: title ?? this.title);
  }
}

class ListMember {
  final String name;
  final String phone;

  ListMember({required this.name, required this.phone});

  Map<String, dynamic> toJson() => {'name': name, 'phone': phone};

  ListMember copyWith({String? name, String? phone}) {
    return ListMember(name: name ?? this.name, phone: phone ?? this.phone);
  }
}

class ListScreen extends StatefulWidget {
  const ListScreen({super.key});

  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen> {
  List<ListItem> _lists = [];
  String? _activeListId;

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await Future.wait([_loadLists(), _loadActiveList()]);
  }

  Future<void> _loadLists() async {
    try {
      final data = await AuthService.instance.api.getLists();
      final raw = (data['lists'] as List?) ?? const [];

      final items =
          raw.map<ListItem>((e) {
            if (e is Map<String, dynamic>) return ListItem.fromJson(e);
            return ListItem(id: '', title: e.toString());
          }).toList();

      if (!mounted) return;
      setState(() {
        _lists = items;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadActiveList() async {
    try {
      final data = await AuthService.instance.api.getActiveList();
      final active = data['active'];
      final id =
          (active is Map<String, dynamic>)
              ? active['listId']?.toString()
              : null;

      if (!mounted) return;
      setState(() => _activeListId = (id != null && id.isNotEmpty) ? id : null);
    } catch (_) {
      // non-fatal
    }
  }

  Future<void> _setActiveList(ListItem item) async {
    final prev = _activeListId;
    setState(() => _activeListId = item.id);

    try {
      await AuthService.instance.api.setActiveList(
        listId: item.id,
        title: item.title,
      );
      await AppSettings.instance.setActiveList(item.id, item.title);
    } catch (e) {
      if (!mounted) return;
      setState(() => _activeListId = prev);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _bgSheet,
          content: Text(
            'Set active list failed: $e',
            style: const TextStyle(color: _textSecondary),
          ),
        ),
      );
    }
  }

  Future<void> _addList(String title) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await AuthService.instance.api.postLists(title: title);
      await _bootstrap();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _deleteList(ListItem list) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await AuthService.instance.api.deleteList(listId: list.id);
      await _bootstrap();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _getDeviceCountryCode() {
    final locale = Platform.localeName;
    final country = locale.split('_').last.toUpperCase();
    const countryDialCodes = {
      'US': '1',
      'CA': '1',
      'GB': '44',
      'AU': '61',
      'DE': '49',
      'FR': '33',
      'IN': '91',
      'MX': '52',
      'BR': '55',
    };
    return countryDialCodes[country] ?? '1';
  }

  String _normalizePhone(String raw, {String fallbackCountryCode = '1'}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final hasPlus = trimmed.startsWith('+');
    final digitsOnly = trimmed.replaceAll(RegExp(r'[^\d]'), '');
    if (digitsOnly.isEmpty) return '';
    if (hasPlus) return '+$digitsOnly';
    if (digitsOnly.length > 10) return digitsOnly;
    return '$fallbackCountryCode$digitsOnly';
  }

  List<ListMember> formatMembersPhone(List<ListMember> members) {
    final countryCode = _getDeviceCountryCode();
    return members.map((m) {
      final formatted = _normalizePhone(
        m.phone,
        fallbackCountryCode: countryCode,
      );
      return m.copyWith(phone: formatted);
    }).toList();
  }

  Future<void> _populateList(String listId, List<ListMember> members) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    List<ListMember> membersFormatted = formatMembersPhone(members);

    try {
      await AuthService.instance.api.updateLists(
        listID: listId,
        contacts: membersFormatted.map((m) => m.toJson()).toList(),
      );
      await _bootstrap();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  // ── Dialogs ────────────────────────────────────────────────────────────────

  Future<void> _showCreateListDialog() async {
    final controller = TextEditingController();

    final created = await showDialog<String>(
      context: context,
      builder:
          (ctx) => _BeaconDialog(
            title: 'Create new list',
            content: _beaconTextField(
              controller: controller,
              label: 'List name',
              hint: 'e.g., Security Logs',
              onSubmitted: (_) => Navigator.pop(ctx, controller.text),
            ),
            onCancel: () => Navigator.pop(ctx),
            onConfirm: () => Navigator.pop(ctx, controller.text),
            confirmLabel: 'Create',
          ),
    );

    final title = (created ?? '').trim();
    if (title.isEmpty) return;
    await _addList(title);
  }

  Future<void> _openContactsSheet({
    required String listId,
    required String listName,
  }) async {
    final status = await Permission.contacts.request();
    if (!mounted) return;

    if (!status.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: _bgSheet,
          content: Text(
            'Contacts permission denied',
            style: TextStyle(color: _textSecondary),
          ),
        ),
      );
      return;
    }

    final phoneContacts = await FlutterContacts.getContacts(
      withProperties: true,
      withPhoto: false,
    );
    if (!mounted) return;

    List<ListMember> existingMembers = [];
    try {
      existingMembers = await _fetchListMembers(listId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: _bgSheet,
            content: Text(
              'Could not load existing members: $e',
              style: const TextStyle(color: _textSecondary),
            ),
          ),
        );
      }
    }

    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: _bgSheet,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return _ContactsPickerSheet(
          title: 'Contacts for "$listName"',
          contacts: phoneContacts,
          initialMembers: existingMembers,
          onDone: (members) async {
            await _populateList(listId, members);
            if (!ctx.mounted) return;
            Navigator.pop(ctx);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: _bgSheet,
                content: Text(
                  'Saved ${members.length} members to "$listName"',
                  style: const TextStyle(color: _textPrimary),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<List<ListMember>> _fetchListMembers(String listId) async {
    final data = await AuthService.instance.api.getListContacts(listID: listId);
    final raw = (data['contacts'] as List?) ?? const [];

    return raw
        .whereType<Map<String, dynamic>>()
        .map(
          (m) => ListMember(
            name: (m['name'] ?? '').toString(),
            phone: normalizePhone((m['phone'] ?? '').toString()),
          ),
        )
        .where((m) => m.name.trim().isNotEmpty && m.phone.trim().isNotEmpty)
        .toList();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).size.width * 0.04;

    return Scaffold(
      backgroundColor: _bgScaffold,
      appBar: AppBar(
        backgroundColor: _bgAppBar,
        foregroundColor: _textPrimary,
        centerTitle: true,
        title: const Text(
          'Lists',
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontWeight: FontWeight.w600,
            color: _textPrimary,
          ),
        ),
      ),
      body: SafeArea(
        child:
            _loading
                ? const Center(
                  child: CircularProgressIndicator(color: _accentAmber),
                )
                : _error != null
                ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Failed to load lists: $_error',
                        style: const TextStyle(color: _textSecondary),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      _BeaconButton(label: 'Retry', onTap: _bootstrap),
                    ],
                  ),
                )
                : RefreshIndicator(
                  color: _accentAmber,
                  backgroundColor: _bgCard,
                  onRefresh: _bootstrap,
                  child: Padding(
                    padding: EdgeInsets.all(padding),
                    child: GridView.builder(
                      itemCount: _lists.length + 1,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 1.1,
                          ),
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return _AddListTile(onTap: _showCreateListDialog);
                        }

                        final item = _lists[index - 1];
                        final isActive =
                            item.id.isNotEmpty && item.id == _activeListId;

                        return _ListTileCard(
                          title: item.title,
                          isActive: isActive,
                          onTap:
                              () => _openContactsSheet(
                                listId: item.id,
                                listName: item.title,
                              ),
                          onLongPress:
                              () => _showListActions(context, item, index - 1),
                        );
                      },
                    ),
                  ),
                ),
      ),
    );
  }

  // ── List actions bottom sheet ──────────────────────────────────────────────

  void _showListActions(BuildContext context, ListItem item, int idx) {
    final isActive = item.id.isNotEmpty && item.id == _activeListId;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: _bgSheet,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SheetTile(
                icon: isActive ? Icons.check_circle : Icons.star_outline,
                iconColor: isActive ? _accentOrange : _accentAmber,
                label: isActive ? 'Active list' : 'Set as active list',
                enabled: !isActive && item.id.isNotEmpty,
                onTap:
                    (!isActive && item.id.isNotEmpty)
                        ? () async {
                          Navigator.pop(ctx);
                          await _setActiveList(item);
                        }
                        : null,
              ),
              Divider(height: 1, color: _divider),
              _SheetTile(
                icon: Icons.edit,
                iconColor: _accentAmber,
                label: 'Rename',
                onTap: () async {
                  Navigator.pop(ctx);

                  final controller = TextEditingController(text: item.title);
                  final newName = await showDialog<String>(
                    context: context,
                    builder:
                        (_) => _BeaconDialog(
                          title: 'Rename list',
                          content: _beaconTextField(
                            controller: controller,
                            hint: 'Enter new name',
                            onSubmitted: (v) => Navigator.pop(context, v),
                          ),
                          onCancel: () => Navigator.pop(context),
                          onConfirm:
                              () => Navigator.pop(context, controller.text),
                          confirmLabel: 'Save',
                        ),
                  );

                  if (!mounted) return;
                  final trimmed = (newName ?? '').trim();
                  if (trimmed.isEmpty) return;

                  final prev = _lists[idx];
                  setState(() => _lists[idx] = item.copyWith(title: trimmed));

                  try {
                    await AuthService.instance.api.renameList(
                      listID: item.id,
                      title: trimmed,
                    );
                    await _bootstrap();
                  } catch (e) {
                    if (!mounted) return;
                    setState(() => _lists[idx] = prev);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        backgroundColor: _bgSheet,
                        content: Text(
                          'Rename failed: $e',
                          style: const TextStyle(color: _textSecondary),
                        ),
                      ),
                    );
                  }
                },
              ),
              Divider(height: 1, color: _divider),
              _SheetTile(
                icon: Icons.delete_outline,
                iconColor: const Color(0xFFE07060), // muted warm red
                label: 'Delete',
                labelColor: const Color(0xFFE07060),
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteList(_lists[idx]);
                  setState(() => _lists.removeAt(idx));
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String normalizePhone(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '';
  final hasPlus = s.startsWith('+');
  final digitsOnly = s.replaceAll(RegExp(r'[^\d]'), '');
  if (digitsOnly.isEmpty) return '';
  return hasPlus ? '+$digitsOnly' : digitsOnly;
}

/// Styled text field for Beacon dialogs.
Widget _beaconTextField({
  required TextEditingController controller,
  String? label,
  String? hint,
  bool autofocus = true,
  ValueChanged<String>? onSubmitted,
}) {
  return TextField(
    controller: controller,
    autofocus: autofocus,
    textInputAction: TextInputAction.done,
    style: const TextStyle(color: _textPrimary, fontFamily: 'Montserrat'),
    cursorColor: _accentAmber,
    decoration: InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: _textMuted),
      hintText: hint,
      hintStyle: const TextStyle(color: _textMuted),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _borderInput, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _accentAmber, width: 1.5),
      ),
      filled: true,
      fillColor: _bgCard,
    ),
    onSubmitted: onSubmitted,
  );
}

// ── Shared UI components ──────────────────────────────────────────────────────

/// Beacon-styled AlertDialog.
class _BeaconDialog extends StatelessWidget {
  const _BeaconDialog({
    required this.title,
    required this.content,
    required this.onCancel,
    required this.onConfirm,
    required this.confirmLabel,
  });

  final String title;
  final Widget content;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _bgSheet,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: _textPrimary,
                fontFamily: 'Montserrat',
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 16),
            content,
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(foregroundColor: _textMuted),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(fontFamily: 'Montserrat'),
                  ),
                ),
                const SizedBox(width: 8),
                _BeaconButton(label: confirmLabel, onTap: onConfirm),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Beacon-styled filled button.
class _BeaconButton extends StatelessWidget {
  const _BeaconButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: _accentOrange,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFF1E1008), // Ember900 — dark text on orange
            fontFamily: 'Montserrat',
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

/// A single tile row for the actions bottom sheet.
class _SheetTile extends StatelessWidget {
  const _SheetTile({
    required this.icon,
    required this.label,
    this.iconColor = _accentAmber,
    this.labelColor = _textPrimary,
    this.enabled = true,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color iconColor;
  final Color labelColor;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = enabled ? labelColor : _textMuted;
    final effectiveIcon = enabled ? iconColor : _textMuted;

    return InkWell(
      onTap: enabled ? onTap : null,
      splashColor: const Color(0x1AFE7E00),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: effectiveIcon, size: 20),
            const SizedBox(width: 16),
            Text(
              label,
              style: TextStyle(
                color: effectiveColor,
                fontFamily: 'Montserrat',
                fontWeight: FontWeight.w500,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Contact Picker Sheet ──────────────────────────────────────────────────────

class _ContactsPickerSheet extends StatefulWidget {
  const _ContactsPickerSheet({
    required this.title,
    required this.contacts,
    required this.initialMembers,
    required this.onDone,
  });

  final String title;
  final List<Contact> contacts;
  final List<ListMember> initialMembers;
  final Future<void> Function(List<ListMember>) onDone;

  @override
  State<_ContactsPickerSheet> createState() => _ContactsPickerSheetState();
}

class _ContactsPickerSheetState extends State<_ContactsPickerSheet> {
  final _search = TextEditingController();

  late final Map<String, ListMember> _selectedByPhone;
  late List<Contact> _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = widget.contacts;
    _selectedByPhone = {for (final m in widget.initialMembers) m.phone: m};

    _search.addListener(() {
      final q = _search.text.trim().toLowerCase();
      setState(() {
        _filtered =
            q.isEmpty
                ? widget.contacts
                : widget.contacts
                    .where((c) => c.displayName.toLowerCase().contains(q))
                    .toList();
      });
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.75;
    final members = _selectedByPhone.values.toList();

    // Wrap everything in a local Theme override so Material widgets
    // (CircleAvatar, InputChip, ListTile, TextButton) stop pulling
    // the global ColorScheme's purple and use Beacon colors instead.
    return Theme(
      data: Theme.of(context).copyWith(
        // Kills the purple avatar / chip background
        colorScheme: Theme.of(context).colorScheme.copyWith(
          primary: _accentOrange,
          onPrimary: const Color(0xFF1E1008),
          secondary: _accentAmber,
          onSecondary: const Color(0xFF1E1008),
          surface: _bgSheet,
          onSurface: _textPrimary,
          // This is the one Flutter uses for CircleAvatar & chip backgrounds
          primaryContainer: _bgCard,
          onPrimaryContainer: _textAccent,
        ),
        // ListTile background & text
        listTileTheme: const ListTileThemeData(
          tileColor: _bgSheet,
          selectedTileColor: _bgCardActive,
          textColor: _textPrimary,
          subtitleTextStyle: TextStyle(color: _textSecondary, fontSize: 12),
          iconColor: _textMuted,
        ),
        // InputChip styling
        chipTheme: ChipThemeData(
          backgroundColor: _bgCard,
          selectedColor: _bgCardActive,
          labelStyle: const TextStyle(
            color: _textPrimary,
            fontFamily: 'Montserrat',
            fontSize: 12,
          ),
          side: const BorderSide(color: _accentAmberDim, width: 1),
          deleteIconColor: _textMuted,
          padding: const EdgeInsets.symmetric(horizontal: 4),
        ),
        // TextButton (the Done button)
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: _textAccent),
        ),
        // Dividers between rows
        dividerColor: _divider,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        color: _textPrimary,
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () async => widget.onDone(members),
                    child: Text(
                      members.isEmpty ? 'Done' : 'Done (${members.length})',
                      style: const TextStyle(
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: _textMuted),
                  ),
                ],
              ),
            ),

            // Members chips
            _MembersSection(
              members: members,
              onRemove: (m) => setState(() => _selectedByPhone.remove(m.phone)),
            ),
            const SizedBox(height: 8),

            // Search field
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                style: const TextStyle(
                  color: _textPrimary,
                  fontFamily: 'Montserrat',
                ),
                cursorColor: _accentAmber,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, color: _textMuted),
                  hintText: 'Search contacts',
                  hintStyle: const TextStyle(color: _textMuted),
                  filled: true,
                  fillColor: _bgCard,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: _borderInput, width: 1),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(
                      color: _accentAmber,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            ),

            // Contact list
            Expanded(
              child:
                  _filtered.isEmpty
                      ? const Center(
                        child: Text(
                          'No contacts found',
                          style: TextStyle(color: _textMuted),
                        ),
                      )
                      : ListView.separated(
                        itemCount: _filtered.length,
                        separatorBuilder:
                            (_, __) =>
                                const Divider(height: 1, color: _divider),
                        itemBuilder: (context, i) {
                          final c = _filtered[i];
                          final name = c.displayName.trim();
                          final phoneRaw =
                              c.phones.isNotEmpty ? c.phones.first.number : '';
                          final phone = normalizePhone(phoneRaw);

                          final isSelectable =
                              name.isNotEmpty && phone.isNotEmpty;
                          final isSelected =
                              phone.isNotEmpty &&
                              _selectedByPhone.containsKey(phone);

                          final subtitle =
                              phoneRaw.trim().isNotEmpty
                                  ? phoneRaw
                                  : (c.emails.isNotEmpty
                                      ? c.emails.first.address
                                      : null);

                          // Wrap each row in Material so tileColor is respected
                          return Material(
                            color: isSelected ? _bgCardActive : _bgSheet,
                            child: ListTile(
                              enabled: isSelectable,
                              leading: CircleAvatar(
                                // Alternate avatar bg by first letter bucket
                                // for visual warmth — odd letters get Ember,
                                // even letters get a slightly deeper charcoal
                                backgroundColor:
                                    name.isNotEmpty && name.codeUnitAt(0).isOdd
                                        ? const Color(0xFF3A2518) // Ember800
                                        : const Color(0xFF2E2A24), // _bgAddTile
                                child: Text(
                                  (name.isNotEmpty ? name[0] : '?')
                                      .toUpperCase(),
                                  style: TextStyle(
                                    // Selected contacts get orange initial,
                                    // others get Flame200 amber
                                    color:
                                        isSelected
                                            ? _accentOrange
                                            : _textAccent,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'Montserrat',
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                              title: Text(
                                name.isEmpty ? 'Unnamed contact' : name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color:
                                      isSelectable ? _textPrimary : _textMuted,
                                  fontFamily: 'Montserrat',
                                  fontWeight: FontWeight.w500,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle:
                                  subtitle == null
                                      ? null
                                      : Text(
                                        subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: _textSecondary,
                                          fontSize: 12,
                                        ),
                                      ),
                              trailing: Icon(
                                isSelected
                                    ? Icons.check_circle
                                    : Icons.add_circle_outline,
                                color: isSelected ? _accentOrange : _textMuted,
                                size: 22,
                              ),
                              onTap:
                                  !isSelectable
                                      ? null
                                      : () {
                                        setState(() {
                                          if (isSelected) {
                                            _selectedByPhone.remove(phone);
                                          } else {
                                            _selectedByPhone[phone] =
                                                ListMember(
                                                  name: name,
                                                  phone: phone,
                                                );
                                          }
                                        });
                                      },
                            ),
                          );
                        },
                      ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ── Members section ───────────────────────────────────────────────────────────

class _MembersSection extends StatelessWidget {
  const _MembersSection({required this.members, required this.onRemove});

  final List<ListMember> members;
  final ValueChanged<ListMember> onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: _bgMembersBox,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _divider, width: 0.5),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Members',
              style: TextStyle(
                color: _textSecondary,
                fontFamily: 'Montserrat',
                fontWeight: FontWeight.w700,
                fontSize: 12,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            if (members.isEmpty)
              const Text(
                'Tap a contact below to add them.',
                style: TextStyle(color: _textMuted, fontSize: 13),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children:
                    members.map((m) {
                      final label = m.name.isEmpty ? 'Unnamed' : m.name;
                      return InputChip(
                        label: Text(
                          label,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _textPrimary,
                            fontFamily: 'Montserrat',
                            fontSize: 12,
                          ),
                        ),
                        backgroundColor: _bgCard,
                        side: const BorderSide(
                          color: _accentAmberDim,
                          width: 1,
                        ),
                        deleteIconColor: _textMuted,
                        onDeleted: () => onRemove(m),
                      );
                    }).toList(),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Grid cards ────────────────────────────────────────────────────────────────

class _ListTileCard extends StatelessWidget {
  const _ListTileCard({
    required this.title,
    required this.isActive,
    this.onTap,
    this.onLongPress,
  });

  final String title;
  final bool isActive;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isActive ? _bgCardActive : _bgCard,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onLongPress,
        splashColor: const Color(0x1AFE7E00),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isActive ? _accentAmberDim : _divider,
              width: isActive ? 1.5 : 0.5,
            ),
          ),
          padding: const EdgeInsets.all(16),
          child: Stack(
            children: [
              Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isActive ? _textPrimary : _textSecondary,
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              if (isActive)
                Align(
                  alignment: Alignment.topRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: _activeBadgeBg,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _accentAmberDim, width: 1),
                    ),
                    child: const Text(
                      'Active',
                      style: TextStyle(
                        color: _activeBadgeText,
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                )
              else
                Align(
                  alignment: Alignment.topRight,
                  child: Icon(
                    Icons.list_alt_outlined,
                    color: _textMuted.withOpacity(0.4),
                    size: 20,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddListTile extends StatelessWidget {
  const _AddListTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _bgAddTile,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        splashColor: const Color(0x1AFE7E00),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _accentAmberDim.withOpacity(0.4),
              width: 1,
            ),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 36, color: _accentAmber),
                const SizedBox(height: 6),
                const Text(
                  'New list',
                  style: TextStyle(
                    color: _textMuted,
                    fontFamily: 'Montserrat',
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
