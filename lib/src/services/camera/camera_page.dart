import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:project_hermes_front_end/src/enums/camera_enums.dart';
import 'package:project_hermes_front_end/src/utils/video_storage_utils.dart';
import 'package:uuid/uuid.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'camera_bloc.dart';
import 'camera_state.dart';
import '../../utils/screenshot_utils.dart';
import '../../widgets/animated_bar.dart';
import '../../screens/list_screen.dart';
import '../../widgets/active_list_pill.dart';
import '../../services/auth_service.dart';
import '../../screens/settings_screen.dart';
import '../../screens/my_videos_screen.dart';
import '../../services/hardening/chunk_upload_queue.dart';

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  late final CameraBloc cameraBloc;

  final List<File> _savedVideos = [];
  final GlobalKey screenshotKey = GlobalKey();
  Uint8List? screenshotBytes;

  bool isThisPageVisibe = true;

  String? _activeListId;
  String? _activeListTitle;

  final Uuid _uuid = const Uuid();

  String? sessionId;
  DateTime? sessionStartTime;

  bool _creatingSos = false;
  String? sosServerId;

  // Chunks that arrived before the SOS ID was ready.
  final List<CameraChunkReady> _pendingChunks = [];

  /* ---------------- Helpers ---------------- */

  Future<void> _loadActiveList() async {
    try {
      final data = await AuthService.instance.api.getActiveList();
      final active = data['active'];

      final id =
          (active is Map<String, dynamic>) ? active['listId']?.toString() : null;
      final title =
          (active is Map<String, dynamic>) ? active['title']?.toString() : null;

      if (!mounted) return;
      setState(() {
        _activeListId = (id != null && id.isNotEmpty) ? id : null;
        _activeListTitle =
            (title != null && title.trim().isNotEmpty) ? title.trim() : null;
      });
    } catch (_) {
      // non-fatal
    }
  }

  Future<void> _loadSavedVideosFromDisk() async {
    final videos = await VideoStorageUtils.instance.loadFinalVideos();
    if (!mounted) return;
    setState(() {
      _savedVideos
        ..clear()
        ..addAll(videos);
    });
  }

  /// Recovers any chunk folders left behind by a previous crash/interruption
  /// and attempts to re-stitch them into final videos.
  Future<void> _recoverOrphanedSessions() async {
    final orphans = await VideoStorageUtils.instance.findOrphanedSessions();
    for (final sessionId in orphans.keys) {
      debugPrint('[CameraPage] Recovering orphaned session: $sessionId');
      final file = await VideoStorageUtils.instance.stitchSession(sessionId);
      if (file != null && mounted) {
        setState(() {
          final already = _savedVideos.any((f) => f.path == file.path);
          if (!already) _savedVideos.insert(0, file);
        });
      }
    }
  }

  void _resetSessionFlags() {
    _creatingSos = false;
    sosServerId = null;
    sessionId = null;
    sessionStartTime = null;
    _pendingChunks.clear();
  }

  /* ---------------- Lifecycle ---------------- */

  @override
  void initState() {
    super.initState();
    cameraBloc = BlocProvider.of<CameraBloc>(context);
    WidgetsBinding.instance.addObserver(this);
 
    _loadActiveList();
    _loadSavedVideosFromDisk();
    _recoverOrphanedSessions();
 
    // Resume any uploads that were interrupted by a crash or signal loss.
    ChunkUploadQueue.instance.recoverAll();           // <-- add this line
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
        cameraBloc.add(CameraEnable());
      }
    }
  }

  /* ---------------- Listener ---------------- */

  void _cameraBlocListener(BuildContext context, CameraState state) async {
    // ── 1. Chunk ready → save locally, then try to upload ──────────────────
    if (state is CameraChunkReady) {
      final sid = sessionId;
      if (sid == null) return;

      // Save to disk first — copies from temp path to stable location
      final savedFile = await VideoStorageUtils.instance.saveChunk(
        sessionId: sid,
        index: state.index,
        file: state.file,
      );

      // Only queue if save succeeded — use stable path, not the temp file
      if (savedFile != null) {
        _pendingChunks.add(
          CameraChunkReady(file: savedFile, index: state.index),
        );
        await _flushPendingChunks();
      } else {
        debugPrint('[CameraPage] saveChunk failed for index=${state.index}, skipping upload');
      }
      return;
    }

    // ── 2. Recording stopped → stitch chunks into final video ───────────────
    if (state is CameraReady && !state.isRecordingVideo && sessionId != null) {
      final sid = sessionId!;

      // Stitch runs in the background; UI stays responsive.
      final stitched = await VideoStorageUtils.instance.stitchSession(sid);

      if (!mounted) return;

      if (stitched != null) {
        setState(() {
          final already = _savedVideos.any((f) => f.path == stitched.path);
          if (!already) _savedVideos.insert(0, stitched);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.black45,
            duration: Duration(milliseconds: 1200),
            content: Text(
              'Saved to My Videos.',
              style: TextStyle(color: Colors.white),
            ),
          ),
        );
      } else {
        // Stitching failed – chunks are still on disk, nothing lost.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.black45,
            duration: Duration(milliseconds: 2000),
            content: Text(
              'Video saved in segments. Will recover on next launch.',
              style: TextStyle(color: Colors.white),
            ),
          ),
        );
      }

      setState(_resetSessionFlags);
      return;
    }

    // ── 3. Too-short recording error ────────────────────────────────────────
    if (state is CameraReady && state.hasRecordingError) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.black45,
          duration: Duration(milliseconds: 1000),
          content: Text(
            'Please record for at least 2 seconds.',
            style: TextStyle(color: Colors.white),
          ),
        ),
      );

      if (!mounted) return;
      setState(_resetSessionFlags);
      return;
    }

    // ── 4. Recording started → create SOS session on server (once) ──────────
    if (state is CameraReady && state.isRecordingVideo) {
      if (_creatingSos || sosServerId != null) return;

      final listId = _activeListId;
      final listTitle = _activeListTitle ?? 'Active list';
      final sid = sessionId;
      final startedAt = sessionStartTime;

      if (listId == null || listId.isEmpty || sid == null || startedAt == null) {
        return;
      }

      _creatingSos = true;

      try {
        final recipientsRes =
            await AuthService.instance.api.getActiveListRecipients(
          listId: listId,
        );
        debugPrint('RAW RECIPIENTS RESPONSE: $recipientsRes');

        final recipients = (recipientsRes['contacts'] as List<dynamic>? ?? [])
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
            'type': 'segmented_upload',
          },
        );

        if (!mounted) return;
        setState(() {
          sosServerId = res['sosId']?.toString();
        });

        debugPrint('[CameraPage] sosServerId set to: $sosServerId');
        debugPrint('[CameraPage] pending chunks: ${_pendingChunks.length}');

        // Drain any chunks that arrived before the SOS ID was ready.
        await _flushPendingChunks();
        debugPrint('[CameraPage] flush complete');
      } catch (e) {
        _creatingSos = false;
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.black45,
            duration: const Duration(milliseconds: 1500),
            content: Text(
              'SOS backend not ready (recording locally): $e',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        );
      }
    }
  }

  /* ---------------- Upload helper ---------------- */

  /// Uploads all queued chunks that arrived before [sosServerId] was set.
  Future<void> _flushPendingChunks() async {
    final sosId = sosServerId;
    debugPrint('[CameraPage] _flushPendingChunks: sosId=$sosId, pending=${_pendingChunks.length}');
    if (sosId == null || _pendingChunks.isEmpty) return;
 
    final toUpload = List<CameraChunkReady>.from(_pendingChunks);
    _pendingChunks.clear();
 
    for (final chunk in toUpload) {
      await ChunkUploadQueue.instance.enqueue(
        sosId: sosId,
        index: chunk.index,
        chunkFile: chunk.file,
      );
    }
  }

  /* ---------------- Visibility ---------------- */

  void _handleVisibilityChanged(VisibilityInfo info) {
    final nowVisible = info.visibleFraction > 0.0;
    if (nowVisible == isThisPageVisibe) return;
    isThisPageVisibe = nowVisible;

    if (!nowVisible && cameraBloc.isRecording()) return;

    cameraBloc.add(nowVisible ? CameraEnable() : CameraDisable());
  }

  /* ---------------- Actions ---------------- */

  Future<void> startRecording() async {
    try {
      final bytes = await takeCameraScreenshot(key: screenshotKey);
      if (mounted) setState(() => screenshotBytes = bytes);
    } catch (_) {}

    sessionId = _uuid.v4();
    sessionStartTime = DateTime.now().toUtc();
    _creatingSos = false;
    sosServerId = null;
    _pendingChunks.clear();

    cameraBloc.add(const CameraSegmentedStart(chunkSeconds: 4));
  }

  void stopRecording() {
    cameraBloc.add(const CameraSegmentedStop());
  }

  /* ---------------- UI ---------------- */

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

  Widget _cameraBlocBuilder(BuildContext context, CameraState state) {
    final bool isReady = state is CameraReady || state is CameraChunkReady;
    final bool isRecording = switch (state) {
      CameraReady s => s.isRecordingVideo,
      CameraChunkReady _ => true,
      _ => false,
    };

    final bool disableButtons = !(isReady && !isRecording);

    final hasActiveList = (_activeListId != null && _activeListId!.isNotEmpty);
    final pillTitle =
        hasActiveList ? (_activeListTitle ?? 'Active list') : 'No active list';

    final controller = cameraBloc.getController();
    final canPreview = isReady && _controllerUsable(controller);

    final Widget preview = canPreview
        ? KeyedSubtree(
            key: ValueKey(controller!.hashCode),
            child: Transform.scale(
              scale: 1 /
                  (controller.value.aspectRatio *
                      MediaQuery.of(context).size.aspectRatio),
              child: CameraPreview(controller),
            ),
          )
        : const SizedBox.shrink();

    return Column(
      children: [
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              RepaintBoundary(key: screenshotKey, child: preview),

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

              if (!isReady) const Center(child: CircularProgressIndicator()),
              if (state is CameraError) errorWidget(state),

              // --- Top-left: My Videos ---
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
                      icon: const Icon(Icons.video_library,
                          color: Colors.black, size: 28),
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

              // --- Top-right: Settings ---
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
                      icon: const Icon(Icons.settings,
                          color: Colors.black, size: 28),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),

              // --- Active List pill ---
              Positioned(
                left: 0,
                right: 0,
                bottom: 30 + 90 + 12,
                child: Visibility(
                  visible: !disableButtons,
                  child: Center(
                    child: ActiveListPill(
                      title: pillTitle,
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const ListScreen()),
                        );
                        await _loadActiveList();
                      },
                    ),
                  ),
                ),
              ),

              // --- Bottom controls ---
              Positioned(
                bottom: 30,
                child: SizedBox(
                  width: 250,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      IgnorePointer(
                        ignoring: state is! CameraReady ||
                            state.decativateRecordButton,
                        child: Opacity(
                          opacity: (state is! CameraReady ||
                                  state.decativateRecordButton)
                              ? 0.4
                              : 1,
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
                            child: IconButton(
                              onPressed: () async {
                                if (cameraBloc.isRecording()) return;
                                try {
                                  final bytes = await takeCameraScreenshot(
                                      key: screenshotKey);
                                  if (!mounted) return;
                                  setState(() => screenshotBytes = bytes);
                                  cameraBloc.add(CameraSwitch());
                                } catch (_) {}
                              },
                              icon: const Icon(Icons.cameraswitch,
                                  color: Colors.black, size: 28),
                            ),
                          ),
                        ),
                      ),

                      Positioned(
                        left: 0,
                        child: Visibility(
                          visible: !disableButtons,
                          child: GestureDetector(
                            onTap: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const ListScreen(),
                                ),
                              );
                              await _loadActiveList();
                            },
                            child: CircleAvatar(
                              backgroundColor: Colors.white.withOpacity(0.5),
                              radius: 25,
                              child: const Icon(Icons.list,
                                  color: Colors.black, size: 28),
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
      ],
    );
  }

  Widget animatedProgressButton(CameraState state) {
    final bool isRecording = switch (state) {
      CameraReady s => s.isRecordingVideo,
      CameraChunkReady _ => true,
      _ => false,
    };

    return GestureDetector(
      onTap: () => isRecording ? stopRecording() : startRecording(),
      onLongPress: startRecording,
      onLongPressEnd: (_) => stopRecording(),
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
              valueListenable: cameraBloc.totalDuration,
              builder: (context, val, _) {
                return Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: isRecording ? 90 : 30,
                    width: isRecording ? 90 : 30,
                    child: RecordingProgressIndicator(
                      value: val.toDouble(),
                      maxValue: cameraBloc.recordDurationLimit.toDouble(),
                    ),
                  ),
                );
              },
            ),

            Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.linear,
                height: isRecording ? 25 : 64,
                width: isRecording ? 25 : 64,
                decoration: BoxDecoration(
                  color: const Color.fromARGB(255, 255, 255, 255),
                  borderRadius: isRecording
                      ? BorderRadius.circular(6)
                      : BorderRadius.circular(100),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget errorWidget(CameraState state) {
    final bool isPermissionError =
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
                        color: const Color.fromARGB(136, 76, 75, 75)
                            .withOpacity(0.4),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Center(
                        child: FittedBox(
                          child: Text(
                            "Open Settings",
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

bool _controllerUsable(CameraController? c) {
  if (c == null) return false;
  try {
    return c.value.isInitialized;
  } catch (_) {
    return false;
  }
}