// lib/src/screens/register_screen.dart
import 'package:flutter/material.dart';
import '../services/auth_helpers.dart';
import '../services/auth_service.dart';
import 'package:firebase_auth/firebase_auth.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  bool _obscure1 = true;
  bool _obscure2 = true;
  Future<void>? _inflight; // prevents concurrent submits

  @override
  void dispose() {
    _username.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String? _validateUsername(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    final trimmed = v.trim();
    final r = RegExp(r'^[A-Za-z][A-Za-z0-9._-]{2,23}$'); // 3–24 chars
    if (!r.hasMatch(trimmed)) {
      return '3–24 chars: letters, numbers, . _ - (start with a letter)';
    }
    return null;
  }

  Future<void> _handleRegister() async {
    if (_inflight != null) return; // guard against double tap/submit
    if (!_formKey.currentState!.validate()) return;

    setState(() => _busy = true);
    _inflight = _doRegister().whenComplete(() {
      _inflight = null;
      if (mounted) setState(() => _busy = false);
    });
  }

  Future<void> _doRegister() async {
    try {
      await AuthService.instance.register(
        email: _email.text.trim(),
        password: _password.text,
        username: _username.text.trim(),
      );
      await FirebaseAuth.instance
        .authStateChanges()
        .firstWhere((u) => u != null);
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);

    } catch (e) {
      // If another concurrent request already signed us in, swallow stale error.
      if (AuthService.instance.currentUser != null) {
        if (mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
        return;
      }
      if (!mounted) return;
      showErrorSnack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Account')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Card(
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _username,
                        enabled: !_busy,
                        decoration: const InputDecoration(labelText: 'Username'),
                        validator: _validateUsername,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _email,
                        enabled: !_busy,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(labelText: 'Email'),
                        validator: (v) =>
                            v != null && v.contains('@') ? null : 'Enter a valid email',
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: _obscure1,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          suffixIcon: IconButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() => _obscure1 = !_obscure1),
                            icon: Icon(_obscure1
                                ? Icons.visibility
                                : Icons.visibility_off),
                          ),
                        ),
                        validator: (v) =>
                            (v != null && v.length >= 6) ? null : 'Min 6 characters',
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _confirm,
                        enabled: !_busy,
                        obscureText: _obscure2,
                        decoration: InputDecoration(
                          labelText: 'Confirm Password',
                          suffixIcon: IconButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() => _obscure2 = !_obscure2),
                            icon: Icon(_obscure2
                                ? Icons.visibility
                                : Icons.visibility_off),
                          ),
                        ),
                        validator: (v) =>
                            v == _password.text ? null : 'Passwords do not match',
                        // no onFieldSubmitted to avoid double submit races
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: FilledButton(
                          onPressed: _busy ? null : _handleRegister,
                          child: _busy
                              ? const CircularProgressIndicator(strokeWidth: 2)
                              : const Text('Create Account'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
