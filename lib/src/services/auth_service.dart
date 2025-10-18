import 'package:firebase_auth/firebase_auth.dart';
import 'api_client.dart';

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
  Future<void> register({required String email, required String password, required String username}) async {
    final customToken = await api.signup(email: email, password: password, username: username);
    await _auth.signInWithCustomToken(customToken);
  }

  // Normal Firebase login
  Future<void> signIn({required String email, required String password}) async {
    await _auth.signInWithEmailAndPassword(email: email, password: password);
  }

  Future<void> signOut() => _auth.signOut();
}
