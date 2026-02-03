import 'dart:io';
import 'package:flutter/material.dart';

class MyVideosScreen extends StatelessWidget {
  final List<File> videos;
  const MyVideosScreen({super.key, required this.videos});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Videos')),
      body: videos.isEmpty
          ? const Center(child: Text('No videos yet'))
          : ListView.builder(
              itemCount: videos.length,
              itemBuilder: (_, i) {
                final file = videos[videos.length - 1 - i]; // newest first
                return ListTile(
                  leading: const Icon(Icons.videocam),
                  title: Text(file.path.split('/').last),
                  subtitle: Text(file.path),
                  onTap: () {
                    // Optional later: open a playback screen if you still want manual playback
                    // Navigator.push(...);
                  },
                );
              },
            ),
    );
  }
}
