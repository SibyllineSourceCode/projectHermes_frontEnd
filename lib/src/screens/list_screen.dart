import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

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
    await Future.wait([
      _loadLists(),
      _loadActiveList(),
    ]);
  }

  Future<void> _loadLists() async {
    try {
      final data = await AuthService.instance.api.getLists();
      final raw = (data['lists'] as List?) ?? const [];

      final items = raw.map<ListItem>((e) {
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
      // Expecting: { ok: true, active: { listId: "...", title: "..." } } (or null)
      final active = data['active'];
      final id = (active is Map<String, dynamic>) ? active['listId']?.toString() : null;

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
    } catch (e) {
      if (!mounted) return;
      setState(() => _activeListId = prev);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Set active list failed: $e')),
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

  Future<void> _populateList(String listId, List<ListMember> members) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await AuthService.instance.api.updateLists(
        listID: listId,
        contacts: members.map((m) => m.toJson()).toList(),
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

  Future<void> _showCreateListDialog() async {
    final controller = TextEditingController();

    final created = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create new list'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'List name',
            hintText: 'e.g., Security Logs',
          ),
          onSubmitted: (_) => Navigator.pop(ctx, controller.text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Create')),
        ],
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
        const SnackBar(content: Text('Contacts permission denied')),
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
          SnackBar(content: Text('Could not load existing members: $e')),
        );
      }
    }

    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
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
              SnackBar(content: Text('Saved ${members.length} members to "$listName"')),
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
        .map((m) => ListMember(
              name: (m['name'] ?? '').toString(),
              phone: normalizePhone((m['phone'] ?? '').toString()),
            ))
        .where((m) => m.name.trim().isNotEmpty && m.phone.trim().isNotEmpty)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).size.width * 0.04;

    return Scaffold(
      appBar: AppBar(title: const Text('Lists'), centerTitle: true),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Failed to load lists: $_error'),
                        const SizedBox(height: 8),
                        FilledButton(onPressed: _bootstrap, child: const Text('Retry')),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _bootstrap,
                    child: Padding(
                      padding: EdgeInsets.all(padding),
                      child: GridView.builder(
                        itemCount: _lists.length + 1,
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
                          final isActive = item.id.isNotEmpty && item.id == _activeListId;

                          return _ListTileCard(
                            title: item.title,
                            isActive: isActive,
                            onTap: () => _openContactsSheet(listId: item.id, listName: item.title),
                            onLongPress: () => _showListActions(context, item, index - 1),
                          );
                        },
                      ),
                    ),
                  ),
      ),
    );
  }

  void _showListActions(BuildContext context, ListItem item, int idx) {
    final isActive = item.id.isNotEmpty && item.id == _activeListId;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(isActive ? Icons.check_circle : Icons.star_outline),
                title: Text(isActive ? 'Active list' : 'Set as active list'),
                enabled: !isActive && item.id.isNotEmpty,
                onTap: (!isActive && item.id.isNotEmpty)
                    ? () async {
                        Navigator.pop(ctx);
                        await _setActiveList(item);
                      }
                    : null,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Rename'),
                onTap: () async {
                  Navigator.pop(ctx);

                  final controller = TextEditingController(text: item.title);
                  final newName = await showDialog<String>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Rename list'),
                      content: TextField(
                        controller: controller,
                        autofocus: true,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (v) => Navigator.pop(context, v),
                        decoration: const InputDecoration(hintText: 'Enter new name'),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
                      ],
                    ),
                  );

                  if (!mounted) return;

                  final trimmed = (newName ?? '').trim();
                  if (trimmed.isEmpty) return;

                  // optimistic UI
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
                      SnackBar(content: Text('Rename failed: $e')),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete'),
                onTap: () {
                  Navigator.pop(ctx);
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

String normalizePhone(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '';
  final hasPlus = s.startsWith('+');
  final digitsOnly = s.replaceAll(RegExp(r'[^\d]'), '');
  if (digitsOnly.isEmpty) return '';
  return hasPlus ? '+$digitsOnly' : digitsOnly;
}

/// =====================
/// CONTACT PICKER SHEET
/// (unchanged from your working version)
/// =====================

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
        if (q.isEmpty) {
          _filtered = widget.contacts;
        } else {
          _filtered = widget.contacts.where((c) {
            final name = c.displayName.toLowerCase();
            return name.contains(q);
          }).toList();
        }
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

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () async => widget.onDone(members),
                  child: Text(members.isEmpty ? 'Done' : 'Done (${members.length})'),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          _MembersSection(
            members: members,
            onRemove: (m) => setState(() => _selectedByPhone.remove(m.phone)),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search contacts',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: _filtered.isEmpty
                ? const Center(child: Text('No contacts found'))
                : ListView.separated(
                    itemCount: _filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final c = _filtered[i];
                      final name = c.displayName.trim();
                      final phoneRaw = c.phones.isNotEmpty ? c.phones.first.number : '';
                      final phone = normalizePhone(phoneRaw);

                      final isSelectable = name.isNotEmpty && phone.isNotEmpty;
                      final isSelected = phone.isNotEmpty && _selectedByPhone.containsKey(phone);

                      final subtitle = (phoneRaw.trim().isNotEmpty)
                          ? phoneRaw
                          : (c.emails.isNotEmpty ? c.emails.first.address : null);

                      return ListTile(
                        enabled: isSelectable,
                        leading: CircleAvatar(child: Text((name.isNotEmpty ? name[0] : '?').toUpperCase())),
                        title: Text(
                          name.isEmpty ? 'Unnamed contact' : name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: subtitle == null ? null : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: isSelected ? const Icon(Icons.check_circle) : const Icon(Icons.add_circle_outline),
                        onTap: !isSelectable
                            ? null
                            : () {
                                setState(() {
                                  if (isSelected) {
                                    _selectedByPhone.remove(phone);
                                  } else {
                                    _selectedByPhone[phone] = ListMember(name: name, phone: phone);
                                  }
                                });
                              },
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _MembersSection extends StatelessWidget {
  const _MembersSection({required this.members, required this.onRemove});

  final List<ListMember> members;
  final ValueChanged<ListMember> onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.4),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Members', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (members.isEmpty)
                Text('Tap a contact below to add them.', style: Theme.of(context).textTheme.bodyMedium)
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: members.map((m) {
                    final label = m.name.isEmpty ? 'Unnamed' : m.name;
                    return InputChip(
                      label: Text(label, overflow: TextOverflow.ellipsis),
                      onDeleted: () => onRemove(m),
                    );
                  }).toList(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

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
    final base = Theme.of(context).colorScheme.surface;
    final activeTint = Colors.lightBlue.withOpacity(0.18);

    return Material(
      color: isActive ? activeTint : base,
      elevation: 2,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Stack(
            children: [
              Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (isActive)
                Align(
                  alignment: Alignment.topRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.lightBlue.withOpacity(0.25),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text('Active', style: TextStyle(fontWeight: FontWeight.bold)),
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
      color: Colors.black.withOpacity(0.06),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Center(
          child: Icon(Icons.add, size: 48, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
        ),
      ),
    );
  }
}
