import 'package:flutter/material.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          ListTile(
            title: Text('Video quality'),
            subtitle: Text('1080p (default)'),
          ),
          Divider(),
          ListTile(
            title: Text('Record duration limit'),
            subtitle: Text('tbd'),
          ),
        ],
      ),
    );
  }
}
