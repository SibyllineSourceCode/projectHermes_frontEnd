import 'package:flutter/material.dart';
import '../services/auth_service.dart';


class HomeScreen extends StatelessWidget {
const HomeScreen({super.key});


  @override
  Widget build(BuildContext context) {
    final user = AuthService.instance.currentUser!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(
            onPressed: () async {
              await AuthService.instance.signOut();
            },
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.verified_user_outlined, size: 72),
            const SizedBox(height: 8),
            Text('Signed in as', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            Text(user.email ?? '(no email)'),
          ],
        ),
      ),
    );
  }
}