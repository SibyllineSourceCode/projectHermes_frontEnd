import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Map common Firebase/Auth/backend errors to friendly text.
String errorMessage(Object error) {
  if (error is FirebaseAuthException) {
    switch (error.code) {
      case 'invalid-email':
        return 'That email address looks wrong.';
      case 'user-not-found':
        return 'No account found for that email.';
      case 'wrong-password':
        return 'Incorrect password.';
      case 'email-already-in-use':
        return 'Email already in use.';
      case 'weak-password':
        return 'Pick a stronger password.';
      case 'username-taken':
        return 'That username is taken.';
      case 'invalid-username':
        return error.message ?? 'Invalid username.';
      default:
        return error.message ?? 'Auth error: ${error.code}';
    }
  }

  // If ApiClient threw Exception('message-from-server')
  final s = error.toString();
  // Trim the generic 'Exception: ' prefix
  final trimmed = s.startsWith('Exception: ') ? s.substring(11) : s;

  // Optional: map a few backend strings to friendlier text
  switch (trimmed) {
    case 'username taken':
      return 'That username is taken.';
    case 'email already in use':
      return 'Email already in use.';
    case 'internal':
      return 'Something went wrong on the server. Please try again.';
    default:
      return trimmed.isEmpty ? 'Something went wrong.' : trimmed;
  }
}

void showErrorSnack(BuildContext context, Object error) {
  final msg = errorMessage(error);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg)),
  );
}

/// Optional convenience helper for success messages.
void showOkSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}
