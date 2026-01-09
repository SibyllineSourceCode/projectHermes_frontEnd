import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';


class ListScreen extends StatefulWidget {
  const ListScreen({super.key});

  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen> {
  List<String> _lists = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLists();
  }

  Future<void> _loadLists() async {
    try {
      final data = await AuthService.instance.api.getLists();
      final raw = (data['lists'] as List?) ?? const [];

      final names = raw.map<String>((e) {
        if (e is String) return e;
        if (e is Map<String, dynamic>) {
          return (e['name'] ?? e['title'] ?? 'Untitled').toString();
        }
        return 'Untitled';
      }).toList();

      if (!mounted) return;
      setState(() {
        _lists = names;
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

  Future<void> _addList(String title) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await AuthService.instance.api.postLists(title: title);
      await _loadLists();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
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

    // Calls your POST + refresh
    await _addList(title);
  }

  Future<void> _openContactsSheet({required String listName}) async {
    // 1) Request permission first
    final status = await Permission.contacts.request();

    if (!mounted) return;

    if (!status.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contacts permission denied')),
      );
      return;
    }

    // 2) Fetch contacts (with properties so we can show phones/emails if needed)
    final contacts = await FlutterContacts.getContacts(
      withProperties: true,
      withPhoto: false,
    );

    if (!mounted) return;

    // 3) Show floating modal sheet
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
          contacts: contacts,
          onDone: (members) {
            Navigator.pop(ctx);

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Members: ${members.length}')),
            );

            // TODO: send members to backend, etc.
          },
        );
      },
    );
  }


  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).size.width * 0.04;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lists'),
        centerTitle: true,
      ),
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
                        FilledButton(onPressed: _loadLists, child: const Text('Retry')),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadLists,
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
                          final name = _lists[index - 1];
                          return _ListTileCard(
                            title: name,
                            onTap: () => _openContactsSheet(listName: name),
                            onLongPress: () => _showListActions(context, name, index - 1),
                          );
                        },
                      ),
                    ),
                  ),
      ),
    );
  }

  void _showListActions(BuildContext context, String name, int idx) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Rename'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final controller = TextEditingController(text: name);
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
                        FilledButton(
                          onPressed: () => Navigator.pop(context, controller.text),
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  );
                  if (!mounted) return;
                  if (newName != null && newName.trim().isNotEmpty) {
                    setState(() => _lists[idx] = newName.trim());
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

class _ContactsPickerSheet extends StatefulWidget {
  const _ContactsPickerSheet({
    required this.title,
    required this.contacts,
    required this.onDone,
  });

  final String title;
  final List<Contact> contacts;
  final ValueChanged<List<Contact>> onDone;

  @override
  State<_ContactsPickerSheet> createState() => _ContactsPickerSheetState();
}

class _ContactsPickerSheetState extends State<_ContactsPickerSheet> {
  final _search = TextEditingController();

  // Keep selections by ID so we can de-dupe and keep stable membership
  final Map<String, Contact> _selectedById = {};

  late List<Contact> _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = widget.contacts;

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
    final members = _selectedById.values.toList();

    return ConstrainedBox(
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
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: members.isEmpty ? null : () => widget.onDone(members),
                  child: Text(members.isEmpty ? 'Done' : 'Done (${members.length})'),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),

          // ===== Upper: Members section =====
          _MembersSection(
            members: members,
            onRemove: (c) {
              setState(() => _selectedById.remove(_contactKey(c)));
            },
          ),

          const SizedBox(height: 8),

          // ===== Lower: Search + Contacts list =====
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
                      final id = _contactKey(c);
                      final isSelected = _selectedById.containsKey(id);

                      final subtitle = _bestSubtitle(c);

                      return ListTile(
                        leading: CircleAvatar(
                          child: Text(
                            (c.displayName.isNotEmpty ? c.displayName[0] : '?')
                                .toUpperCase(),
                          ),
                        ),
                        title: Text(
                          c.displayName.isEmpty ? 'Unnamed contact' : c.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: subtitle == null
                            ? null
                            : Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        trailing: isSelected
                            ? const Icon(Icons.check_circle)
                            : const Icon(Icons.add_circle_outline),
                        onTap: () {
                          setState(() {
                            if (isSelected) {
                              // Toggle off if you want tap-to-remove
                              _selectedById.remove(id);
                            } else {
                              _selectedById[id] = c;
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

  // Prefer contact.id if present; fall back to a derived key
  String _contactKey(Contact c) {
    if (c.id.isNotEmpty) return c.id;

    // fallback: name + first phone/email
    final phone = c.phones.isNotEmpty ? c.phones.first.number : '';
    final email = c.emails.isNotEmpty ? c.emails.first.address : '';
    return '${c.displayName}|$phone|$email';
  }

  String? _bestSubtitle(Contact c) {
    if (c.phones.isNotEmpty) return c.phones.first.number;
    if (c.emails.isNotEmpty) return c.emails.first.address;
    return null;
  }
}

class _MembersSection extends StatelessWidget {
  const _MembersSection({
    required this.members,
    required this.onRemove,
  });

  final List<Contact> members;
  final ValueChanged<Contact> onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.4),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Members',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              if (members.isEmpty)
                Text(
                  'Tap a contact below to add them.',
                  style: Theme.of(context).textTheme.bodyMedium,
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: members.map((c) {
                    final label = c.displayName.isEmpty ? 'Unnamed' : c.displayName;
                    return InputChip(
                      label: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onDeleted: () => onRemove(c),
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
  const _ListTileCard({required this.title, this.onTap, this.onLongPress});

  final String title;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
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