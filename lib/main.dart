// lib/main.dart
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';
import 'src/services/auth_service.dart';
import 'src/screens/login_screen.dart';
import 'src/screens/home_screen.dart';
import 'src/services/app_settings.dart';
import 'package:flutter/services.dart';

const _accentAmber = Color(0xFFF59B30);

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print("Background notification: ${message.notification?.title}");
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await AppSettings.instance.load();

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await FirebaseMessaging.instance.requestPermission();

  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    print("Foreground notification: ${message.notification?.title}");
  });

  AuthService.init(
    'https://us-central1-project-hermes-d667b.cloudfunctions.net/api',
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Beacon',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0E0C0A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF140E08),
          foregroundColor: Color(0xFFE8E4DC),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Color(0xFF1A1610),
        ),
        colorScheme: ColorScheme.dark(
          surface: const Color(0xFF1E1C18),
          onSurface: const Color(0xFFE8E4DC),
        ),
        dialogTheme: DialogThemeData(backgroundColor: const Color(0xFF1A1610)),
      ),
      home: StreamBuilder(
        stream: AuthService.instance.authStateChanges,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(color: _accentAmber),
              ),
            );
          }
          return snapshot.hasData ? const HomeScreen() : const LoginScreen();
        },
      ),
    );
  }
}
