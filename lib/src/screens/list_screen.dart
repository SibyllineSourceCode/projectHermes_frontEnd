import 'package:flutter/material.dart';

class ListScreen extends StatelessWidget {
  const ListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("My List"),
        centerTitle: true,
      ),
      body: const Center(
        child: Text(
          "This page is empty for now.",
          style: TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
