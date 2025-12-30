import 'package:flutter/material.dart';
import '../services/auth_service.dart';

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
                            onTap: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Open "$name"')),
                              );
                            },
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