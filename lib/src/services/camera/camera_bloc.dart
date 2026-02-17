import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:equatable/equatable.dart';

import '../../enums/camera_enums.dart';
import '../../utils/camera_utils.dart';
import '../../utils/permission_utils.dart';
import 'camera_state.dart';

part 'camera_event.dart';

class CameraBloc extends Bloc<CameraEvent, CameraState> {
  final CameraUtils cameraUtils;
  final PermissionUtils permissionUtils;

  CameraController? _cameraController;
  CameraLensDirection currentLensDirection = CameraLensDirection.back;

  // UI timer (progress ring)
  Timer? recordingTimer;
  final ValueNotifier<int> recordingDuration = ValueNotifier(0);
  int recordDurationLimit = 60;

  // Segmentation
  Timer? _segmentTimer;
  int _segmentIndex = 0;
  int _chunkSeconds = 4;

  // Prevent stop/start overlap
  bool _opBusy = false;

  // Prevent double-init
  bool _isInitializing = false;

  CameraBloc({required this.cameraUtils, required this.permissionUtils})
      : super(CameraInitial()) {
    on<CameraReset>(_onCameraReset);
    on<CameraInitialize>(_onCameraInitialize);
    on<CameraSwitch>(_onCameraSwitch);
    on<CameraEnable>(_onCameraEnable);
    on<CameraDisable>(_onCameraDisable);

    // segmented-only
    on<CameraSegmentedStart>(_onSegmentedStart);
    on<CameraSegmentedStop>(_onSegmentedStop);
    on<CameraSegmentTick>(_onSegmentTick);
  }

  CameraController? getController() => _cameraController;
  bool isInitialized() => _cameraController?.value.isInitialized ?? false;
  bool isRecording() => _cameraController?.value.isRecordingVideo ?? false;

  /* ---------------- Small helper ---------------- */

  void _safeEmit(Emitter<CameraState> emit, CameraState state) {
    if (!emit.isDone) emit(state);
  }

  /* ---------------- Events ---------------- */

  Future<void> _onCameraReset(CameraReset event, Emitter<CameraState> emit) async {
    await _stopSegmentedInternal(emit, emitFinalChunk: false);
    await _disposeCamera();
    _safeEmit(emit, CameraInitial());
  }

  Future<void> _onCameraInitialize(
    CameraInitialize event,
    Emitter<CameraState> emit,
  ) async {
    recordDurationLimit = event.recordingLimit;
    try {
      await _checkPermissionAndInitializeCamera();
      _safeEmit(emit, CameraReady(isRecordingVideo: false));
    } catch (_) {
      _safeEmit(emit, CameraError(error: CameraErrorType.other));
    }
  }

  Future<void> _onCameraEnable(CameraEnable event, Emitter<CameraState> emit) async {
    if (await permissionUtils.getCameraAndMicrophonePermissionStatus()) {
      if (_cameraController == null || !_cameraController!.value.isInitialized) {
        await _initializeCamera();
      }
      _safeEmit(emit, CameraReady(isRecordingVideo: false));
    } else {
      _safeEmit(emit, CameraError(error: CameraErrorType.permission));
    }
  }

  Future<void> _onCameraDisable(CameraDisable event, Emitter<CameraState> emit) async {
    // If app backgrounds while recording, stop cleanly and emit last chunk.
    await _stopSegmentedInternal(emit, emitFinalChunk: true);
    await _disposeCamera();
    _safeEmit(emit, CameraInitial());
  }

  Future<void> _onCameraSwitch(CameraSwitch event, Emitter<CameraState> emit) async {
    // Stop segmented first; don't emit chunk for a lens switch.
    await _stopSegmentedInternal(emit, emitFinalChunk: false);

    _safeEmit(emit, CameraInitial());

    currentLensDirection = currentLensDirection == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;

    await _reInitialize();

    _safeEmit(emit, CameraReady(isRecordingVideo: false));
  }

  Future<void> _onSegmentedStart(
    CameraSegmentedStart event,
    Emitter<CameraState> emit,
  ) async {
    if (!isInitialized()) {
      await _checkPermissionAndInitializeCamera();
    }
    if (isRecording()) return;

    _segmentIndex = 0;
    _chunkSeconds = event.chunkSeconds;

    recordingDuration.value = 0;
    _startUiTimer();

    try {
      await _startRecording();
      _safeEmit(emit, CameraReady(isRecordingVideo: true));
    } catch (_) {
      await _reInitialize();
      _stopUiTimer();
      _safeEmit(emit, CameraReady(isRecordingVideo: false));
      return;
    }

    _segmentTimer?.cancel();
    _segmentTimer = Timer.periodic(Duration(seconds: _chunkSeconds), (_) {
      if (isClosed) return;
      add(const CameraSegmentTick());
    });
  }

  Future<void> _onSegmentedStop(
    CameraSegmentedStop event,
    Emitter<CameraState> emit,
  ) async {
    await _stopSegmentedInternal(emit, emitFinalChunk: true);
    _safeEmit(emit, CameraReady(isRecordingVideo: false));
  }

  Future<void> _onSegmentTick(
    CameraSegmentTick event,
    Emitter<CameraState> emit,
  ) async {
    if (isClosed) return;
    if (!isRecording()) return;
    await _cutSegmentAndContinue(emit);
  }

  /* ---------------- Segmented core ---------------- */

  Future<void> _cutSegmentAndContinue(Emitter<CameraState> emit) async {
    if (_opBusy) return;
    if (!isRecording()) return;

    _opBusy = true;
    try {
      final f = await _stopRecordingOnce();
      _safeEmit(emit, CameraChunkReady(file: f, index: _segmentIndex));
      _segmentIndex++;

      // Start next segment
      await _startRecording();
      _safeEmit(emit, CameraReady(isRecordingVideo: true));
    } catch (_) {
      // Recover: reinit and try restart
      try {
        await _reInitialize();
        await _startRecording();
        _safeEmit(emit, CameraReady(isRecordingVideo: true));
      } catch (_) {
        // Give up cleanly
        await _stopSegmentedInternal(emit, emitFinalChunk: false);
        _safeEmit(emit, CameraReady(isRecordingVideo: false));
      }
    } finally {
      _opBusy = false;
    }
  }

  Future<void> _stopSegmentedInternal(
    Emitter<CameraState> emit, {
    required bool emitFinalChunk,
  }) async {
    _segmentTimer?.cancel();
    _segmentTimer = null;
    _stopUiTimer();

    // Wait for any in-flight cut
    while (_opBusy) {
      await Future.delayed(const Duration(milliseconds: 30));
    }

    if (!isRecording()) return;

    _opBusy = true;
    try {
      final f = await _stopRecordingOnce();
      if (emitFinalChunk) {
        _safeEmit(emit, CameraChunkReady(file: f, index: _segmentIndex));
      }
    } catch (_) {
      // ignore
    } finally {
      _opBusy = false;
    }
  }

  /* ---------------- Camera ops ---------------- */

  Future<void> _startRecording() async {
    final ctrl = _cameraController;
    if (ctrl == null) throw StateError("CameraController is null");
    await ctrl.startVideoRecording();
  }

  Future<File> _stopRecordingOnce() async {
    final ctrl = _cameraController;
    if (ctrl == null) throw StateError("CameraController is null");
    final XFile video = await ctrl.stopVideoRecording();
    return File(video.path);
  }

  Future<void> _checkPermissionAndInitializeCamera() async {
    if (await permissionUtils.getCameraAndMicrophonePermissionStatus()) {
      await _initializeCamera();
      return;
    }
    if (await permissionUtils.askForPermission()) {
      await _initializeCamera();
      return;
    }
    throw CameraErrorType.permission;
  }

  Future<void> _initializeCamera() async {
    if (_isInitializing) return;
    if (_cameraController != null && _cameraController!.value.isInitialized) return;

    _isInitializing = true;
    try {
      _cameraController = await cameraUtils.getCameraController(
        lensDirection: currentLensDirection,
      );
      await _cameraController!.initialize();
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> _reInitialize() async {
    await _disposeCamera();
    await _initializeCamera();
  }

  Future<void> _disposeCamera() async {
    _segmentTimer?.cancel();
    _segmentTimer = null;
    _stopUiTimer();

    final ctrl = _cameraController;
    _cameraController = null; // detach first to reduce UI races

    try {
      await ctrl?.dispose();
    } catch (_) {
      // ignore
    }

    _opBusy = false; // safe reset
  }

  /* ---------------- UI timer ---------------- */

  void _startUiTimer() {
    if (recordingTimer?.isActive ?? false) return;

    recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      recordingDuration.value++;

      if (recordingDuration.value >= recordDurationLimit) {
        add(const CameraSegmentedStop());
      }
    });
  }

  void _stopUiTimer() {
    recordingTimer?.cancel();
    recordingTimer = null;
    recordingDuration.value = 0;
  }
}
