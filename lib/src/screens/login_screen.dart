// lib/src/screens/login_screen.dart
import 'package:flutter/material.dart';
import '../services/auth_helpers.dart';
import '../services/auth_service.dart';
import '../services/camera/camera_bloc.dart';
import '../services/camera/camera_state.dart';
import '../utils/camera_utils.dart';
import '../utils/permission_utils.dart';
import '../services/app_settings.dart';
import 'register_screen.dart';

// ── Beacon Palette ────────────────────────────────────────────────────────────
const _bgScaffold = Color(0xFF0E0C0A);
const _bgCard = Color(0xFF1E1C18);
const _borderCard = Color(0xFF2E2A24);
const _textPrimary = Color(0xFFE8E4DC);
const _textSecondary = Color(0xFFB0A89E);
const _textMuted = Color(0xFF7A7068);
const _accentOrange = Color(0xFFFE7E00);
const _accentAmber = Color(0xFFF59B30);
const _inputFill = Color(0xFF28221C);
const _inputBorder = Color(0xFF3A3228);
// ─────────────────────────────────────────────────────────────────────────────

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String _busyLabel = 'Sign In';

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _busyLabel = 'Requesting permissions…';
    });

    // ── FIX: Request camera/mic permissions *here*, before any camera
    // initialization is attempted.
    //
    // On a fresh install, Permission.request() triggers the real Android
    // system permission dialog — a separate Activity overlay. When it
    // dismisses, this Activity goes through onPause -> onResume again.
    //
    // Previously, the first permission prompt happened *inside*
    // CameraBloc's _checkPermissionAndInitializeCamera(), which called
    // _initializeCamera() (and therefore CameraController.initialize())
    // immediately after the dialog resolved — racing that lifecycle
    // transition. CameraX's session configuration would then hang waiting
    // on a not-yet-resumed Activity, freezing the main thread (see
    // "Frame skipped... too much work on the main thread" in logs).
    //
    // By requesting permissions here — with a settled UI and no pending
    // camera init — and then yielding a frame before _prewarmCamera()
    // runs, the camera HAL cold-start in _prewarmCamera() (and the bloc's
    // own init later) is no longer racing the dialog dismissal. On repeat
    // logins this is a no-op: permissions are already granted, so
    // askForPermission() resolves immediately with no dialog.
    await _requestCameraAndMicPermissions();
    if (!mounted) return;

    // Let the frame settle after the permission dialog (if any) closes,
    // so the Activity is fully resumed before we touch the camera HAL.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    setState(() => _busyLabel = 'Preparing camera…');

    // Warm up the camera HAL *before* signing in. Once signIn() resolves,
    // AuthService.instance.authStateChanges fires and MyApp's
    // StreamBuilder immediately swaps to HomeScreen, which creates its
    // own CameraBloc and calls CameraInitialize during that transition.
    // If the camera session has to cold-start at that exact moment, the
    // CameraX session-configuration step can stall (see Camera2CameraImpl
    // "Future ... is not done within 5000 ms" in logs), leaving HomeScreen
    // stuck on its loading spinner.
    //
    // Running a throwaway init here — while LoginScreen is still on
    // screen with nothing transitioning — warms the camera service so
    // that HomeScreen's subsequent init is a fast re-open.
    await _prewarmCamera();
    if (!mounted) return;
    setState(() => _busyLabel = 'Signing in…');

    try {
      await AuthService.instance.signIn(
        email: _email.text.trim(),
        password: _password.text,
      );
    } catch (e) {
      if (!mounted) return;
      showErrorSnack(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = 'Sign In';
        });
      }
    }
  }

  /// Requests camera + microphone permissions up front, on a settled UI
  /// with no camera initialization pending. Safe to call every login —
  /// if permissions are already granted (the normal case after first run),
  /// this resolves immediately with no dialog and no visible delay.
  Future<void> _requestCameraAndMicPermissions() async {
    final utils = PermissionUtils();
    if (await utils.getCameraAndMicrophonePermissionStatus()) {
      return; // already granted — nothing to do
    }
    await utils.askForPermission();
    // Result intentionally not checked here: if denied, _prewarmCamera()
    // and the bloc's own init will surface CameraError as before, and
    // HomeScreen's existing permission-error UI handles that case.
  }

  Future<void> _prewarmCamera() async {
    final bloc = CameraBloc(
      cameraUtils: CameraUtils(),
      permissionUtils: PermissionUtils(),
    );

    bloc.add(
      CameraInitialize(
        recordingLimit: AppSettings.instance.recordingDurationLimit,
      ),
    );

    try {
      await bloc.stream
          .firstWhere((s) => s is CameraReady || s is CameraError)
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      // Best-effort — if this stalls, proceed with sign-in anyway.
      // HomeScreen's own init + error UI remains the fallback.
    } finally {
      await bloc.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _inputBorder),
    );
    final focusedBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _accentAmber, width: 1.5),
    );
    final errorBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: Colors.red.shade700, width: 1.5),
    );

    return Scaffold(
      backgroundColor: _bgScaffold,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/images/Beacon_transparent_back.png',
                  width: 120,
                  height: 120,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Welcome back',
                  style: TextStyle(
                    color: _textPrimary,
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w600,
                    fontSize: 26,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Sign in to continue',
                  style: TextStyle(color: _textSecondary, fontSize: 14),
                ),
                const SizedBox(height: 28),
                Container(
                  decoration: BoxDecoration(
                    color: _bgCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _borderCard, width: 0.5),
                  ),
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      children: [
                        TextFormField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          style: const TextStyle(color: _textPrimary),
                          decoration: InputDecoration(
                            labelText: 'Email',
                            labelStyle: const TextStyle(color: _textMuted),
                            filled: true,
                            fillColor: _inputFill,
                            border: inputBorder,
                            enabledBorder: inputBorder,
                            focusedBorder: focusedBorder,
                            errorBorder: errorBorder,
                            focusedErrorBorder: errorBorder,
                          ),
                          validator:
                              (v) =>
                                  v != null && v.contains('@')
                                      ? null
                                      : 'Enter a valid email',
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _password,
                          obscureText: _obscure,
                          style: const TextStyle(color: _textPrimary),
                          decoration: InputDecoration(
                            labelText: 'Password',
                            labelStyle: const TextStyle(color: _textMuted),
                            filled: true,
                            fillColor: _inputFill,
                            border: inputBorder,
                            enabledBorder: inputBorder,
                            focusedBorder: focusedBorder,
                            errorBorder: errorBorder,
                            focusedErrorBorder: errorBorder,
                            suffixIcon: IconButton(
                              onPressed:
                                  () => setState(() => _obscure = !_obscure),
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                                color: _textMuted,
                              ),
                            ),
                          ),
                          validator:
                              (v) =>
                                  (v != null && v.length >= 6)
                                      ? null
                                      : 'Min 6 characters',
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton(
                            onPressed: _busy ? null : _handleLogin,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _accentOrange,
                              foregroundColor: Colors.black,
                              disabledBackgroundColor: _accentOrange
                                  .withOpacity(0.4),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child:
                                _busy
                                    ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.black54,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Text(
                                          _busyLabel,
                                          style: const TextStyle(
                                            fontFamily: 'Montserrat',
                                            fontWeight: FontWeight.w600,
                                            fontSize: 15,
                                          ),
                                        ),
                                      ],
                                    )
                                    : const Text(
                                      'Sign In',
                                      style: TextStyle(
                                        fontFamily: 'Montserrat',
                                        fontWeight: FontWeight.w600,
                                        fontSize: 15,
                                      ),
                                    ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'New here?',
                      style: TextStyle(color: _textSecondary),
                    ),
                    TextButton(
                      onPressed:
                          () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const RegisterScreen(),
                            ),
                          ),
                      style: TextButton.styleFrom(
                        foregroundColor: _accentAmber,
                      ),
                      child: const Text(
                        'Create an account',
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
