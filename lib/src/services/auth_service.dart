import 'package:firebase_auth/firebase_auth.dart';
import 'api_client.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:io';


class AuthService {
  AuthService._(this.api);
  static late final AuthService instance;

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ApiClient api;

  static void init(String baseUrl) {
    instance = AuthService._(ApiClient(baseUrl));
  }

  Stream<User?> get authStateChanges => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  // Backend signup -> customToken -> sign in
  Future<void> register({required String email, required String password, required String username, required String phoneE164}) async {
    await FirebaseMessaging.instance.requestPermission();
    final fcmToken = await FirebaseMessaging.instance.getToken();   
    final platform = Platform.isAndroid
        ? 'android'
        : Platform.isIOS
            ? 'ios'
            : 'unknown';
    final customToken = await api.signup(email: email, password: password, username: username, fcmToken: fcmToken, phoneE164: phoneE164, platform: platform);
    await _auth.signInWithCustomToken(customToken);
  }

  // Normal Firebase login
  Future<void> signIn({required String email, required String password}) async {
    await _auth.signInWithEmailAndPassword(email: email, password: password);
  }

  Future<void> signOut() => _auth.signOut();
}
