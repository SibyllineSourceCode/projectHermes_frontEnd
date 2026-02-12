import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:project_hermes_front_end/src/screens/settings_screen.dart';
import 'camera_bloc.dart';
import 'camera_state.dart';
import '../../enums/camera_enums.dart';
import '../../utils/screenshot_utils.dart';
import '../../widgets/animated_bar.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../../screens/list_screen.dart';
import '../../widgets/active_list_pill.dart';
import '../../services/auth_service.dart';
import 'package:uuid/uuid.dart';
import '../../screens/my_videos_screen.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  late CameraBloc cameraBloc;
  final List<File> _savedVideos = [];
  final GlobalKey screenshotKey = GlobalKey();
  Uint8List? screenshotBytes;
  bool isThisPageVisibe = true;

  String? _activeListId;
  String? _activeListTitle;

  final Uuid _uuid = const Uuid();

  String? sessionId;
  DateTime? sessionStartTime;

  bool sosInitializing = false;   // UI state
  bool sosLive = false;           // becomes true after room ready

  bool _sosCreateStarted = false;
  bool _sosCreateDone = false;
  String? sosServerId; // optional: if backend returns one


  Future<void> _loadActiveList() async {
    try {
      final data = await AuthService.instance.api.getActiveList();
      final active = data['active'];

      final id = (active is Map<String, dynamic>) ? active['listId']?.toString() : null;
      final title = (active is Map<String, dynamic>) ? active['title']?.toString() : null;

      if (!mounted) return;
      setState(() {
        _activeListId = (id != null && id.isNotEmpty) ? id : null;
        _activeListTitle = (title != null && title.trim().isNotEmpty) ? title.trim() : null;
      });
    } catch (_) {
      // non-fatal
    }
  }

  Future<void> _loadSavedVideosFromDisk() async {
    final dir = await getApplicationDocumentsDirectory();
    final videosDir = Directory(p.join(dir.path, 'sos_videos'));
    if (!await videosDir.exists()) return;

    final files = videosDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp4'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

    if (!mounted) return;
    setState(() {
      _savedVideos
        ..clear()
        ..addAll(files);
    });
  }

  @override
  void initState() {
    cameraBloc = BlocProvider.of<CameraBloc>(context);
    WidgetsBinding.instance.addObserver(this);
    _loadActiveList();
    _loadSavedVideosFromDisk();
    super.initState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      cameraBloc.add(CameraDisable());
    } else if (state == AppLifecycleState.resumed) {
      if (isThisPageVisibe) {
        cameraBloc.add(CameraEnable());  // re-init if needed
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 54, 53, 53),
      extendBodyBehindAppBar: true,
      resizeToAvoidBottomInset: false,
      body: VisibilityDetector(
        key: const Key("my_camera"),
        onVisibilityChanged: _handleVisibilityChanged,
        child: BlocConsumer<CameraBloc, CameraState>(
          listener: _cameraBlocListener,
          builder: _cameraBlocBuilder,
        ),
      ),
    );
  }

  Future<File> _saveToAppDirectory(File recorded, String sessionId) async {
    final dir = await getApplicationDocumentsDirectory();
    final videosDir = Directory(p.join(dir.path, 'sos_videos'));
    if (!await videosDir.exists()) await videosDir.create(recursive: true);

    final targetPath = p.join(videosDir.path, '$sessionId.mp4');

    try {
      return await recorded.rename(targetPath); // move
    } catch (_) {
      final copied = await recorded.copy(targetPath);
      // optional: best-effort cleanup of original
      try { await recorded.delete(); } catch (_) {}
      return copied;
    }
  }


  void _cameraBlocListener(BuildContext context, CameraState state) async {

    //Setting the camera chunk to be ready

    if (state is CameraChunkReady) {
      final sosId = sosServerId;
      if (sosId == null) return;

      // upload chunk
      try {
        await AuthService.instance.api.uploadSosChunk(
          sosId: sosId,
          index: state.index,
          file: state.file,
        );
        debugPrint("Uploaded chunk ${state.index}");
      } catch (e) {
        debugPrint("Chunk upload failed ${state.index}: $e");
        // TODO: queue + retry (we can add next)
      }
      return;
    }

    // ---- Existing: recording success saves file ----
    if (state is CameraRecordingSuccess) {
      final sid = sessionId ?? _uuid.v4();
      final savedFile = await _saveToAppDirectory(state.file, sid);
      if (!mounted) return;

      setState(() {
        final already = _savedVideos.any((f) => f.path == savedFile.path);
        if (!already) _savedVideos.add(savedFile);
        sosInitializing = false;
        sosLive = false;

        // reset SOS flags for next session
        _sosCreateStarted = false;
        _sosCreateDone = false;
        sosServerId = null;
        sessionId = null;
        sessionStartTime = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.black45,
          duration: Duration(milliseconds: 1200),
          content: Text('Saved to My Videos.', style: TextStyle(color: Colors.white)),
        ),
      );
      return;
    }

    // ---- Existing: too-short recording ----
    if (state is CameraReady && state.hasRecordingError) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.black45,
          duration: Duration(milliseconds: 1000),
          content: Text('Please record for at least 2 seconds.', style: TextStyle(color: Colors.white)),
        ),
      );
      // also reset sos ui if you want:
      if (mounted) {
        setState(() {
          sosInitializing = false;
          sosLive = false;
          _sosCreateStarted = false;
          _sosCreateDone = false;
          sosServerId = null;
        });
      }
      return;
    }

    // ---- NEW: When recording truly starts, create SOS session on backend (ghost call) ----
    if (state is CameraReady && state.isRecordingVideo) {
      if (_sosCreateStarted || _sosCreateDone) return;

      final listId = _activeListId;
      final listTitle = _activeListTitle ?? 'Active list';
      final sid = sessionId;
      final startedAt = sessionStartTime;

      if (listId == null || listId.isEmpty || sid == null || startedAt == null) {
        // Can't create SOS; keep recording locally anyway
        if (mounted) setState(() => sosInitializing = false);
        return;
      }

      _sosCreateStarted = true;

      try {
        final recipientsRes = await AuthService.instance.api.getActiveListRecipients(listId: listId);
        final recipients = (recipientsRes['recipients'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();

        final res = await AuthService.instance.api.createSos(
          listId: listId,
          listTitle: listTitle,
          message: 'SOS started',
          recipients: recipients,
          extraContext: {
            'sessionId': sid,
            'startedAtUtc': startedAt.toIso8601String(),
            'type': 'webrtc_room_placeholder',
          },
        );

        if (!mounted) return;
        setState(() {
          _sosCreateDone = true;
          sosInitializing = false;
          sosLive = true; // this will become "room ready" later
          sosServerId = res['sosId']?.toString(); // if backend returns it (optional)
        });
      } catch (e) {
        // Backend failed — keep local recording alive
        if (!mounted) return;
        setState(() {
          sosInitializing = false;
          sosLive = false;
          _sosCreateStarted = false; // allow a retry if you want
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.black45,
            duration: const Duration(milliseconds: 1500),
            content: Text('SOS backend not ready (still recording locally): $e',
                style: const TextStyle(color: Colors.white)),
          ),
        );
      }
    }
  }



  void _handleVisibilityChanged(VisibilityInfo info) {
    final nowVisible = info.visibleFraction > 0.0;
    if (nowVisible == isThisPageVisibe) return; // avoid spamming
    isThisPageVisibe = nowVisible;
    cameraBloc.add(nowVisible ? CameraEnable() : CameraDisable());
  }



  void startRecording() async {
    // -1) grab screenshot early for smooth UX
    try {
      final bytes = await takeCameraScreenshot(key: screenshotKey);
      if (mounted) setState(() => screenshotBytes = bytes);
    } catch (_) {
      // ignore screenshot errors
    }

    // 0) PRE-FLIGHT SESSION SETUP
    sessionId = _uuid.v4();                 // globally unique session key
    sessionStartTime = DateTime.now().toUtc(); // use UTC for backend alignment

    if (mounted) {
      setState(() {
        sosInitializing = true;  // show spinner / "Starting SOS..."
        sosLive = false;
      });
    }

    debugPrint("SOS PRE-FLIGHT");
    debugPrint("Session ID: $sessionId");
    debugPrint("Start Time (UTC): $sessionStartTime");

    // 1) Start local recording
    cameraBloc.add(const CameraSegmentedStart(chunkSeconds: 4));
  }


  void stopRecording() async {
    cameraBloc.add(const CameraSegmentedStop());
  }

  Widget _cameraBlocBuilder(BuildContext context, CameraState state) {
  final bool isReady = state is CameraReady;
  final bool disableButtons = !(isReady && !state.isRecordingVideo);

  final hasActiveList = (_activeListId != null && _activeListId!.isNotEmpty);
  final pillTitle = hasActiveList ? (_activeListTitle ?? 'Active list') : 'No active list';

  // Get the controller once
  final controller = cameraBloc.getController();

  // Keep the preview subtree mounted; do NOT wrap in AnimatedSwitcher.
  final Widget preview = (controller != null && controller.value.isInitialized)
      ? Transform.scale(
          key: const ValueKey('stable_camera_preview'),
          scale: 1 /
              (controller.value.aspectRatio *
                  MediaQuery.of(context).size.aspectRatio),
          child: CameraPreview(controller),
        )
      : const SizedBox.shrink();

  return Column(
    children: [
      Expanded(
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Preview surface that should remain alive
            RepaintBoundary(
              key: screenshotKey,
              child: preview,
            ),

            // Optional blurred screenshot backdrop while not ready
            if (!isReady && screenshotBytes != null)
              Container(
                constraints: const BoxConstraints.expand(),
                decoration: BoxDecoration(
                  image: DecorationImage(
                    image: MemoryImage(screenshotBytes!),
                    fit: BoxFit.cover,
                  ),
                ),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0),
                  child: const SizedBox.shrink(),
                ),
              ),

            // Loader overlay for ANY non-ready state
            if (!isReady) const Center(child: CircularProgressIndicator()),

            // Error overlay (on top)
            if (state is CameraError) errorWidget(state),

            //----- Top Left My Videos Screen
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 12,
              child: Visibility(
                visible: !disableButtons,
                child: CircleAvatar(
                  backgroundColor: Colors.white.withOpacity(0.5),
                  radius: 25,
                  child: IconButton(
                    tooltip: 'My Videos',
                    icon: const Icon(Icons.video_library, color: Colors.black, size: 28),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => MyVideosScreen(videos: _savedVideos),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            // ---- Top-right Settings button (outside bottom control box) ----
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              right: 12,
              child: Visibility(
                visible: !disableButtons,
                child: CircleAvatar(
                  backgroundColor: Colors.white.withOpacity(0.5),
                  radius: 25,
                  child: IconButton(
                    tooltip: 'Settings',
                    icon: const Icon(Icons.settings, color: Colors.black, size: 28),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SettingsScreen()),
                      );
                    },
                  ),
                ),
              ),
            ),
            // ---- Active List pill (above record button) ----
            Positioned(
              left: 0,
              right: 0,
              bottom: 30 + 90 + 12, // bottomControls(30) + max record btn size(90) + gap(12)
              child: Visibility(
                visible: !disableButtons, // hide if camera not ready
                child: Center(
                  child: ActiveListPill(
                    title: pillTitle,
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ListScreen()),
                      );
                      await _loadActiveList(); // refresh when returning
                    },
                  ),
                ),
              ),
            ),
            // ---- Bottom controls (unchanged structure) ----
            Positioned(
              bottom: 30,
              child: SizedBox(
                width: 250,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    IgnorePointer(
                      ignoring: state is! CameraReady || state.decativateRecordButton,
                      child: Opacity(
                        opacity: (state is! CameraReady || state.decativateRecordButton) ? 0.4 : 1,
                        child: animatedProgressButton(state),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      child: Visibility(
                        visible: !disableButtons,
                        child: CircleAvatar(
                          backgroundColor: Colors.white.withOpacity(0.5),
                          radius: 25,
                          // -------- CAMERA SWITCH BUTTON ----------
                          child: IconButton(
                            onPressed: () async {
                              try {
                                final bytes = await takeCameraScreenshot(key: screenshotKey);
                                if (!mounted) return;
                                setState(() => screenshotBytes = bytes);
                                cameraBloc.add(CameraSwitch());
                              } catch (_) {
                                // screenshot error - ignore for now
                              }
                            },
                            icon: const Icon(Icons.cameraswitch, color: Colors.black, size: 28),
                          ),
                        ),
                      ),
                    ),
                    // -------------------------------List Screen Nav button------------------------
                    Positioned(
                      left: 0,
                      child: Visibility(
                        visible: !disableButtons,
                        child: StatefulBuilder(
                          // RECORD DURATION BUTTON - changed to Lists button
                          builder: (context, localSetState) {
                            return GestureDetector(
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const ListScreen(),
                                  ),
                                );
                                await _loadActiveList();
                                // If you later want to cycle duration limits, restore that code here.
                              },
                              child: CircleAvatar(
                                backgroundColor: Colors.white.withOpacity(0.5),
                                radius: 25,
                                child: const Icon(Icons.list, color: Colors.black, size: 28),
                              ),
                            );
                          },
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
    ],
  );
}


  Widget animatedProgressButton(CameraState state) {
    bool isRecording = state is CameraReady && state.isRecordingVideo;
    return GestureDetector(
      onTap: () async {
        if (isRecording) {
          stopRecording();
        } else {
          startRecording();
        }
      },
      onLongPress: () {
        startRecording();
      },
      onLongPressEnd: (_) {
        stopRecording();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: isRecording ? 90 : 80,
        width: isRecording ? 90 : 80,
        child: Stack(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF978B8B).withOpacity(0.8),
              ),
            ),
            ValueListenableBuilder(
              valueListenable: cameraBloc.recordingDuration,
              builder: (context, val, child) {
                return TweenAnimationBuilder<double>(
                  duration: Duration(milliseconds: isRecording ? 1100 : 0),
                  tween: Tween<double>(
                    begin: isRecording ? 1 : 0, //val.toDouble(),,
                    end: isRecording ? val.toDouble() + 1 : 0,
                  ),
                  curve: Curves.linear,
                  builder: (context, value, _) {
                    return Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        height: isRecording ? 90 : 30,
                        width: isRecording ? 90 : 30,
                        child: RecordingProgressIndicator(
                          value: value,
                          maxValue: cameraBloc.recordDurationLimit.toDouble(),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
            Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.linear,
                    height: isRecording ? 25 : 64,
                    width: isRecording ? 25 : 64,
                    decoration: BoxDecoration(
                      color: const Color.fromARGB(
                        255,
                        255,
                        255,
                        255,
                      ), //Color(0xffe80415),
                      borderRadius:
                          isRecording
                              ? BorderRadius.circular(6)
                              : BorderRadius.circular(100),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget errorWidget(CameraState state) {
    bool isPermissionError =
        state is CameraError && state.error == CameraErrorType.permission;
    return Container(
      color: Colors.black,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              isPermissionError
                  ? "Please grant access to your camera and microphone to proceed."
                  : "Something went wrong",
              style: const TextStyle(
                color: Color(0xFF959393),
                fontFamily: "Montserrat",
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    onPressed: () async {
                      openAppSettings();
                      Navigator.maybePop(context);
                    },
                    child: Container(
                      height: 35,
                      decoration: BoxDecoration(
                        color: const Color.fromARGB(
                          136,
                          76,
                          75,
                          75,
                        ).withOpacity(0.4),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Center(
                        child: FittedBox(
                          child: Text(
                            "Open Setting",
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.9),
                              fontSize: 14,
                              fontFamily: "Montserrat",
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
