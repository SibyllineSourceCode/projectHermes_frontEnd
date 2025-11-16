import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';

class ApiClient {
  ApiClient(this.baseUrl);
  final String baseUrl; // e.g. https://us-central1-project-hermes-d667b.cloudfunctions.net/api

  Future<Map<String, dynamic>> _authedGet(String path) async {
    final idToken = await FirebaseAuth.instance.currentUser!.getIdToken();
    final res = await http.get(Uri.parse('$baseUrl$path'), headers: {
      'Authorization': 'Bearer $idToken',
    });
    return _decode(res);
  }

  Future<Map<String, dynamic>> _authedPost(String path, Map<String, dynamic> body) async {
    final idToken = await FirebaseAuth.instance.currentUser!.getIdToken();
    final res = await http.post(
      Uri.parse('$baseUrl$path'),
      headers: {
        'Authorization': 'Bearer $idToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
    final data = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 200 && res.statusCode < 300) return data;
    throw Exception(data['error'] ?? 'HTTP ${res.statusCode}');
  }

  // ==== Auth (signup returns custom token) ====
  Future<String> signup({required String email, required String password, required String username, String? fcmToken, String? platform}) async {
    final res = await http.post(
      Uri.parse('$baseUrl/auth/signup'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password, 'username': username, 'fcmToken': fcmToken, 'platform': platform}),
    );
    final data = _decode(res);
    return data['customToken'] as String;
  }

  // ==== Profile ====
  Future<Map<String, dynamic>> me() => _authedGet('/me');
  Future<Map<String, dynamic>> patchMe({required String username}) => _authedPost('/me', {'username': username});

  // ==== Devices ====
  Future<Map<String, dynamic>> registerDevice({required String token, required String platform})
    => _authedPost('/devices/register', {'token': token, 'platform': platform});

  // ==== Calls / TURN ====
  Future<Map<String, dynamic>> initiateCall(String calleeUsername)
    => _authedPost('/call/initiate', {'calleeUsername': calleeUsername});

  Future<Map<String, dynamic>> postOffer({required String callId, required Map<String, dynamic> offer})
    => _authedPost('/call/offer', {'callId': callId, 'offer': offer});

  Future<Map<String, dynamic>> postAnswer({required String callId, required Map<String, dynamic> answer})
    => _authedPost('/call/answer', {'callId': callId, 'answer': answer});

  Future<Map<String, dynamic>> turnCredentials() => _authedGet('/turn/credentials');
}
