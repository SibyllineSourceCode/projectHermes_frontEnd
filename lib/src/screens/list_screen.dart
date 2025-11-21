import 'package:flutter/material.dart';

class ListScreen extends StatefulWidget {
  const ListScreen({super.key});

  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen> {
  // Seed data — replace with your data source later.
  final List<String> _lists = [
    'Home',
    'Work',
    'Important',
    'Archive',
  ];

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).size.width * 0.04;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lists'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(padding),
          child: GridView.builder(
            itemCount: _lists.length + 1, // +1 for the "Add" tile
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2, // tweak for your design
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.1,
            ),
            itemBuilder: (context, index) {
              if (index == 0) {
                // --- Add New List tile ---
                return _AddListTile(
                  onTap: () async {
                    // TODO: Replace with your "list management" flow.
                    // For now we push a stub page and optionally get a new name back.
                    final createdName = await Navigator.push<String>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ManageListPage(),
                      ),
                    );
                    if (createdName != null && createdName.trim().isNotEmpty) {
                      setState(() => _lists.insert(0, createdName.trim()));
                    }
                  },
                );
              }

              final name = _lists[index - 1];
              return _ListTileCard(
                title: name,
                onTap: () {
                  // TODO: Navigate to this list’s detail page
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Open "$name"')),
                  );
                },
                onLongPress: () {
                  // Optional: actions like rename/delete
                  _showListActions(context, name, index - 1);
                },
              );
            },
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
                        decoration: const InputDecoration(
                          hintText: 'Enter new name',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () =>
                              Navigator.pop(context, controller.text),
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  );
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
  const _ListTileCard({
    required this.title,
    this.onTap,
    this.onLongPress,
  });

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
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
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
      color: Colors.black.withOpacity(0.06), // semi-transparent tile
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Center(
          child: Icon(
            Icons.add,
            size: 48,
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
          ),
        ),
      ),
    );
  }
}

/// Stub management page — replace with your real "List Management" UI later.
class ManageListPage extends StatefulWidget {
  const ManageListPage({super.key});

  @override
  State<ManageListPage> createState() => _ManageListPageState();
}

class _ManageListPageState extends State<ManageListPage> {
  final TextEditingController _name = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create New List')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'List name',
                  hintText: 'e.g., Security Logs',
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Create'),
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    final value = _name.text.trim();
    if (value.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a list name.')),
      );
      return;
    }
    Navigator.pop(context, value);
  }
}

