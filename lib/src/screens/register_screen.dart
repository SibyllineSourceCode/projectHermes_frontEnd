// lib/src/screens/register_screen.dart
import 'package:flutter/material.dart';
import '../services/auth_helpers.dart';
import '../services/auth_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/camera/camera_bloc.dart';
import '../services/camera/camera_state.dart';
import '../utils/camera_utils.dart';
import '../utils/permission_utils.dart';
import '../services/app_settings.dart';

// ── Beacon Palette (matches login_screen.dart) ─────────────────────────────
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

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _CountryCode {
  final String iso;
  final String name;
  final String dialCode; // e.g. "+1"
  const _CountryCode(this.iso, this.name, this.dialCode);
}

class _PhoneVerifyResult {
  final String code;
  const _PhoneVerifyResult(this.code);
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  // NEW: phone fields
  final _phone = TextEditingController();
  _CountryCode _country = const _CountryCode("US", "United States", "+1");

  bool _busy = false;
  String _busyLabel = 'Create Account';
  bool _obscure1 = true;
  bool _obscure2 = true;
  Future<void>? _inflight; // prevents concurrent submits

  static const List<_CountryCode> _countries = [
    _CountryCode("US", "United States", "+1"),
    _CountryCode("CA", "Canada", "+1"),
    _CountryCode("MX", "Mexico", "+52"),
    _CountryCode("GB", "United Kingdom", "+44"),
    _CountryCode("IE", "Ireland", "+353"),
    _CountryCode("AU", "Australia", "+61"),
    _CountryCode("NZ", "New Zealand", "+64"),
    _CountryCode("DE", "Germany", "+49"),
    _CountryCode("FR", "France", "+33"),
    _CountryCode("ES", "Spain", "+34"),
    _CountryCode("IT", "Italy", "+39"),
    _CountryCode("NL", "Netherlands", "+31"),
    _CountryCode("SE", "Sweden", "+46"),
    _CountryCode("NO", "Norway", "+47"),
    _CountryCode("DK", "Denmark", "+45"),
    _CountryCode("CH", "Switzerland", "+41"),
    _CountryCode("AT", "Austria", "+43"),
    _CountryCode("BR", "Brazil", "+55"),
    _CountryCode("AR", "Argentina", "+54"),
    _CountryCode("CL", "Chile", "+56"),
    _CountryCode("CO", "Colombia", "+57"),
    _CountryCode("PE", "Peru", "+51"),
    _CountryCode("IN", "India", "+91"),
    _CountryCode("JP", "Japan", "+81"),
    _CountryCode("KR", "South Korea", "+82"),
    _CountryCode("PH", "Philippines", "+63"),
    _CountryCode("SG", "Singapore", "+65"),
    _CountryCode("ZA", "South Africa", "+27"),
  ];

  @override
  void dispose() {
    _username.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    _phone.dispose();
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

  /// E164-ish validation:
  /// - We don't attempt full country-specific validation here.
  /// - We ensure user entered digits only (allow spaces/dashes) and a reasonable length.
  String? _validatePhone(String? v) {
    final raw = (v ?? '').trim();
    if (raw.isEmpty) return 'Required';

    // Strip everything except digits
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return 'Enter a valid phone number';

    // Very conservative bounds: E.164 max is 15 digits total (excluding +),
    // but local portion lengths vary; we keep it reasonably permissive.
    if (digits.length < 7) return 'Phone number is too short';
    if (digits.length > 15) return 'Phone number is too long';

    return null;
  }

  String _composePhoneE164() {
    var digits = _phone.text.trim().replaceAll(RegExp(r'\D'), '');
    final ccDigits = _country.dialCode.replaceAll(
      RegExp(r'\D'),
      '',
    ); // "1", "44", etc.

    // If user pasted a full international number including country code, avoid doubling it.
    if (digits.startsWith(ccDigits) && digits.length > ccDigits.length + 6) {
      digits = digits.substring(ccDigits.length);
    }

    return '+$ccDigits$digits';
  }

  Future<void> _handleRegister({
    required String username,
    required String email,
    required String password,
    required String phoneE164,
  }) async {
    if (_inflight != null) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() => _busy = true);
    _inflight = _doRegister(
      username: username,
      email: email,
      password: password,
      phoneE164: phoneE164,
    ).whenComplete(() {
      _inflight = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = 'Create Account';
        });
      }
    });
  }

  /// Runs a throwaway [CameraBloc] through initialization *before*
  /// navigating to the home screen, so the camera HAL/session is already
  /// warm by the time the home screen creates its own bloc during the
  /// pop transition.
  ///
  /// This avoids the freeze that occurs when CameraInitialize fires
  /// concurrently with the Navigator pop transition into the home
  /// screen — the camera HAL/session-configuration step can stall when
  /// it's asked to cold-start while the previous route's animation is
  /// still settling. By doing that cold-start here (while this screen's
  /// own "Setting up camera…" UI is on top, with no transition in
  /// flight), the subsequent init on the home screen is a warm re-open
  /// and completes quickly.
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
      // Swallow — if this probe times out, proceed anyway. The home
      // screen's own init + existing error UI remains the fallback.
    } finally {
      await bloc.close();
    }
  }

  Future<void> _doRegister({
    required String username,
    required String email,
    required String password,
    required String phoneE164,
  }) async {
    try {
      // Optional: add a debug print so you can verify nothing is empty
      debugPrint(
        'Register payload: u="$username" e="$email" pLen=${password.length} phone="$phoneE164"',
      );

      await AuthService.instance.register(
        email: email,
        password: password,
        username: username,
        phoneE164: phoneE164,
      );

      await FirebaseAuth.instance.authStateChanges().firstWhere(
        (u) => u != null,
      );
      if (!mounted) return;

      // Confirm the camera is operational *before* leaving this screen,
      // so the user never sees a frozen spinner on the home screen.
      // We dispose this probe bloc afterwards — its job is just to run
      // the camera HAL "cold start" while this screen (with its own
      // loading UI) is still on top, so that when HomeScreen creates
      // its own CameraBloc during the pop transition, the camera
      // service is already warm and initialize() resolves quickly.
      setState(() => _busyLabel = 'Setting up camera…');
      await _prewarmCamera();
      if (!mounted) return;

      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (AuthService.instance.currentUser != null) {
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
        return;
      }
      if (!mounted) return;
      showErrorSnack(context, e);
    }
  }

  Future<void> _verifyPhone({
    required String username,
    required String email,
    required String password,
    required String phone,
  }) async {
    // TODO: trigger SMS send here (Firebase Phone Auth or your backend)
    // await AuthService.instance.api.sendPhoneCode(phone: phone);

    if (!mounted) return;

    final result = await showModalBottomSheet<_PhoneVerifyResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return PhoneVerifySheet(
          phoneE164: phone,
          onResend: () async {
            // TODO: re-send SMS
            // await AuthService.instance.api.sendPhoneCode(phone: phone);
          },
        );
      },
    );

    // If user completed entry and pressed "Complete registration"
    if (result == null) return;

    final code = result.code; // 6 digits

    // TODO: verify code here, then complete registration
    // Example idea:
    // 1) verify SMS code (Firebase / backend)
    // 2) call your register() (or finalize it)
    // await AuthService.instance.verifyPhoneCode(phone: phone, code: code);
    // await AuthService.instance.register(...);

    // For now just debug:
    debugPrint('User entered SMS code: $code');
    await _handleRegister(
      username: username,
      email: email,
      password: password,
      phoneE164: phone,
    );
  }

  @override
  Widget build(BuildContext context) {
    final phonePreview = _composePhoneE164();

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

    InputDecoration deco({
      required String label,
      String? hint,
      String? prefixText,
      Widget? suffixIcon,
    }) {
      return InputDecoration(
        labelText: label,
        hintText: hint,
        prefixText: prefixText,
        labelStyle: const TextStyle(color: _textMuted),
        hintStyle: const TextStyle(color: _textMuted),
        prefixStyle: const TextStyle(color: _textPrimary),
        filled: true,
        fillColor: _inputFill,
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: focusedBorder,
        errorBorder: errorBorder,
        focusedErrorBorder: errorBorder,
        disabledBorder: inputBorder,
        suffixIcon: suffixIcon,
      );
    }

    return Scaffold(
      backgroundColor: _bgScaffold,
      appBar: AppBar(
        backgroundColor: _bgScaffold,
        foregroundColor: _textPrimary,
        elevation: 0,
        title: const Text(
          'Create Account',
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Join Beacon',
                  style: TextStyle(
                    color: _textPrimary,
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w600,
                    fontSize: 26,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Set up your account to get connected',
                  style: TextStyle(color: _textSecondary, fontSize: 14),
                ),
                const SizedBox(height: 24),
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
                          controller: _username,
                          enabled: !_busy,
                          style: const TextStyle(color: _textPrimary),
                          decoration: deco(label: 'Username'),
                          validator: _validateUsername,
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 14),

                        TextFormField(
                          controller: _email,
                          enabled: !_busy,
                          keyboardType: TextInputType.emailAddress,
                          style: const TextStyle(color: _textPrimary),
                          decoration: deco(label: 'Email'),
                          validator:
                              (v) =>
                                  v != null && v.contains('@')
                                      ? null
                                      : 'Enter a valid email',
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 14),

                        // Country dropdown + phone
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 2,
                              child: DropdownButtonFormField<_CountryCode>(
                                initialValue: _country,
                                dropdownColor: _bgCard,
                                style: const TextStyle(color: _textPrimary),
                                items:
                                    _countries.map((c) {
                                      return DropdownMenuItem<_CountryCode>(
                                        value: c,
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                '${c.name} (${c.dialCode})',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: _textPrimary,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }).toList(),

                                onChanged:
                                    _busy
                                        ? null
                                        : (v) {
                                          if (v == null) return;
                                          setState(() => _country = v);
                                        },
                                decoration: deco(label: 'Country'),
                                isExpanded: true,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: _phone,
                                enabled: !_busy,
                                keyboardType: TextInputType.phone,
                                style: const TextStyle(color: _textPrimary),
                                decoration: deco(
                                  label: 'Phone number',
                                  hint: '555 123 4567',
                                  prefixText: '${_country.dialCode} ',
                                ),
                                validator: _validatePhone,
                                textInputAction: TextInputAction.next,
                                onChanged: (_) {
                                  // live preview update
                                  setState(() {});
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Will be saved as: $phonePreview',
                            style: const TextStyle(
                              color: _textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),

                        TextFormField(
                          controller: _password,
                          enabled: !_busy,
                          obscureText: _obscure1,
                          style: const TextStyle(color: _textPrimary),
                          decoration: deco(
                            label: 'Password',
                            suffixIcon: IconButton(
                              onPressed:
                                  _busy
                                      ? null
                                      : () => setState(
                                        () => _obscure1 = !_obscure1,
                                      ),
                              icon: Icon(
                                _obscure1
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
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 14),

                        TextFormField(
                          controller: _confirm,
                          enabled: !_busy,
                          obscureText: _obscure2,
                          style: const TextStyle(color: _textPrimary),
                          decoration: deco(
                            label: 'Confirm Password',
                            suffixIcon: IconButton(
                              onPressed:
                                  _busy
                                      ? null
                                      : () => setState(
                                        () => _obscure2 = !_obscure2,
                                      ),
                              icon: Icon(
                                _obscure2
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                                color: _textMuted,
                              ),
                            ),
                          ),
                          validator:
                              (v) =>
                                  v == _password.text
                                      ? null
                                      : 'Passwords do not match',
                          // no onFieldSubmitted to avoid double submit races
                        ),
                        const SizedBox(height: 20),

                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _accentOrange,
                              foregroundColor: Colors.black,
                              disabledBackgroundColor: _accentOrange
                                  .withOpacity(0.4),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            onPressed:
                                _busy
                                    ? null
                                    : () async {
                                      if (!_formKey.currentState!.validate()) {
                                        return;
                                      }

                                      await _verifyPhone(
                                        username: _username.text.trim(),
                                        email: _email.text.trim(),
                                        password: _password.text,
                                        phone: _composePhoneE164(),
                                      );
                                    },
                            child:
                                _busy
                                    ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        const SizedBox(
                                          height: 18,
                                          width: 18,
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
                                      'Create Account',
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CodeBoxes extends StatelessWidget {
  const _CodeBoxes({required this.code, required this.length});

  final String code; // digits only
  final int length;

  @override
  Widget build(BuildContext context) {
    final chars = code.split('');

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(length, (i) {
        final String? ch = (i < chars.length) ? chars[i] : null;
        final bool filled = ch != null && ch.isNotEmpty;

        return Expanded(
          child: Container(
            margin: EdgeInsets.only(right: i == length - 1 ? 0 : 10),
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: _inputFill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                width: 1.4,
                color: filled ? _accentAmber : _inputBorder,
              ),
            ),
            child: Center(
              child: Text(
                filled ? ch : '',
                style: const TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 22,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class PhoneVerifySheet extends StatefulWidget {
  const PhoneVerifySheet({
    super.key,
    required this.phoneE164,
    required this.onResend,
  });

  final String phoneE164;
  final Future<void> Function() onResend;

  @override
  State<PhoneVerifySheet> createState() => _PhoneVerifySheetState();
}

class _PhoneVerifySheetState extends State<PhoneVerifySheet> {
  final _codeController = TextEditingController();
  final _focusNode = FocusNode();

  bool _submitting = false;
  bool _resending = false;

  String get _digits => _codeController.text.replaceAll(RegExp(r'\D'), '');

  bool get _isComplete => _digits.length == 6;

  @override
  void initState() {
    super.initState();
    // Auto focus after sheet animation
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    if (!_isComplete || _submitting) return;
    setState(() => _submitting = true);

    try {
      // Return code to caller
      Navigator.pop(context, _PhoneVerifyResult(_digits));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _resend() async {
    if (_resending) return;
    setState(() => _resending = true);
    try {
      await widget.onResend();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Verification code resent')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Resend failed: $e')));
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final maxH = MediaQuery.of(context).size.height * 0.82;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header row
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Verify your phone',
                      style: TextStyle(
                        color: _textPrimary,
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed:
                        _submitting ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: _textSecondary),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Enter the 6-digit code we sent to ${widget.phoneE164}.',
                  style: const TextStyle(color: _textSecondary, fontSize: 14),
                ),
              ),
              const SizedBox(height: 16),

              // Tap area that focuses the hidden input
              GestureDetector(
                onTap: () => _focusNode.requestFocus(),
                child: _CodeBoxes(code: _digits, length: 6),
              ),

              // Hidden text field that collects digits
              Opacity(
                opacity: 0,
                child: SizedBox(
                  height: 1,
                  child: TextField(
                    controller: _codeController,
                    focusNode: _focusNode,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    maxLength: 6,
                    decoration: const InputDecoration(counterText: ''),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _complete(),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              Row(
                children: [
                  TextButton(
                    onPressed: _resending ? null : _resend,
                    style: TextButton.styleFrom(foregroundColor: _accentAmber),
                    child: Text(_resending ? 'Resending…' : 'Resend code'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed:
                        _submitting ? null : () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      foregroundColor: _textSecondary,
                    ),
                    child: const Text('Change number'),
                  ),
                ],
              ),

              const SizedBox(height: 8),

              // Spacer pushes button to bottom (when there's room)
              const Spacer(),

              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accentOrange,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: _accentOrange.withOpacity(0.4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: (_isComplete && !_submitting) ? _complete : null,
                  child:
                      _submitting
                          ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black54,
                            ),
                          )
                          : const Text(
                            'Complete registration',
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
    );
  }
}
