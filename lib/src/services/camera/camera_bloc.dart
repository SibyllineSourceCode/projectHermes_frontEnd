import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'camera_state.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../utils/camera_utils.dart';
import '../../utils/permission_utils.dart';
import '../../enums/camera_enums.dart';
part 'camera_event.dart';

// A BLoC class that handles camera-related operations
class CameraBloc extends Bloc<CameraEvent, CameraState> {
  //....... Dependencies ..............
  final CameraUtils cameraUtils;
  final PermissionUtils permissionUtils;

  //....... Internal variables ........
  int recordDurationLimit = 60;
  CameraController? _cameraController;
  CameraLensDirection currentLensDirection = CameraLensDirection.back;
  Timer? recordingTimer;
  ValueNotifier<int> recordingDuration = ValueNotifier(0);

  //....... Getters ..........
  CameraController? getController() => _cameraController;
  bool isInitialized() => _cameraController?.value.isInitialized ?? false;
  bool isRecording() => _cameraController?.value.isRecordingVideo ?? false;
  
  //........ Members ..........

  Timer? _segmentTimer;
  bool _segmentedMode = false;
  bool _segmentBusy = false;
  int _segmentIndex = 0;
  int _chunkSeconds = 4;

  //setters
  set setRecordDurationLimit(int val) {
    recordDurationLimit = val;
  }

  //....... Constructor ........
  CameraBloc({required this.cameraUtils, required this.permissionUtils})
    : super(CameraInitial()) {
    on<CameraReset>(_onCameraReset);
    on<CameraInitialize>(_onCameraInitialize);
    on<CameraSwitch>(_onCameraSwitch);
    on<CameraRecordingStart>(_onCameraRecordingStart);
    on<CameraRecordingStop>(_onCameraRecordingStop);
    on<CameraEnable>(_onCameraEnable);
    on<CameraDisable>(_onCameraDisable);
    on<CameraSegmentedStart>(_onSegmentedStart);
    on<CameraSegmentedStop>(_onSegmentedStop);
  }

  // ...................... event handler ..........................

  // Handle CameraReset event
  void _onCameraReset(CameraReset event, Emitter<CameraState> emit) async {
    await _disposeCamera(); // Dispose of the camera before resetting
    _resetCameraBloc(); // Reset the camera BLoC state
    emit(CameraInitial()); // Emit the initial state
  }

  // Handle CameraInitialize event
  void _onCameraInitialize(
    CameraInitialize event,
    Emitter<CameraState> emit,
  ) async {
    recordDurationLimit = event.recordingLimit;
    try {
      await _checkPermissionAndInitializeCamera(); // checking and asking for camera permission and initializing camera
      emit(CameraReady(isRecordingVideo: false));
    } catch (e) {
      emit(
        CameraError(
          error:
              e == CameraErrorType.permission
                  ? CameraErrorType.permission
                  : CameraErrorType.other,
        ),
      );
    }
  }

  // Handle CameraSwitch event
  void _onCameraSwitch(CameraSwitch event, Emitter<CameraState> emit) async {
    //stop segmented loop if active
    if (_segmentedMode) {
      add(const CameraSegmentedStop());
      await Future.delayed(const Duration(milliseconds: 200));
    }
    emit(CameraInitial());
    await _switchCamera();
    emit(CameraReady(isRecordingVideo: false));
  }

  // Handle CameraRecordingStart event
  void _onCameraRecordingStart(
    CameraRecordingStart event,
    Emitter<CameraState> emit,
  ) async {
    if (!isRecording()) {
      try {
        await _startRecording();
        recordingDuration.value = 0; // ensure clean start
        _startTimer(); // <-- start once here
        emit(CameraReady(isRecordingVideo: true));
      } catch (e) {
        await _reInitialize();
        emit(CameraReady(isRecordingVideo: false));
      }
    }
  }

  // Handle CameraRecordingStop event
  void _onCameraRecordingStop(
    CameraRecordingStop event,
    Emitter<CameraState> emit,
  ) async {
    if (!isRecording()) return;

    final hasRecordingLimitError = recordingDuration.value < 2;

    // Tell UI we are stopping and temporarily disable the record button
    emit(
      CameraReady(
        isRecordingVideo: false,
        hasRecordingError: hasRecordingLimitError,
        decativateRecordButton: true,
      ),
    );

    try {
      final videoFile = await _stopRecordingFinal();

      if (hasRecordingLimitError) {
        // Too short: do NOT save / do NOT emit success
        await Future.delayed(const Duration(milliseconds: 1500));
        emit(
          CameraReady(
            isRecordingVideo: false,
            hasRecordingError: false,
            decativateRecordButton: false,
          ),
        );
        return;
      }

      // Valid recording: emit success so listener can save/copy it
      emit(CameraRecordingSuccess(file: videoFile));

      // IMPORTANT: immediately return to ready state so preview doesn't get stuck
      emit(
        CameraReady(
          isRecordingVideo: false,
          hasRecordingError: false,
          decativateRecordButton: false,
        ),
      );
    } catch (e) {
      await _reInitialize();
      emit(CameraReady(isRecordingVideo: false));
    }
  }


  // Handle CameraEnable event on app resume
  void _onCameraEnable(CameraEnable event, Emitter<CameraState> emit) async {
    if (await permissionUtils.getCameraAndMicrophonePermissionStatus()) {
      if (_cameraController == null || !_cameraController!.value.isInitialized) {
        await _initializeCamera();
        emit(CameraReady(isRecordingVideo: false));
      }
    } else {
      emit(CameraError(error: CameraErrorType.permission));
    }
  }


  // Handle CameraDisable event when camera is not in use
  void _onCameraDisable(CameraDisable event, Emitter<CameraState> emit) async {
    _segmentedMode = false;
    _segmentTimer?.cancel();
    _segmentTimer = null;

    if (isInitialized() && isRecording()) {
      try {
        await _stopRecordingFinal();
      } catch (_) {
        // ignore, we're disabling anyway
      }
    }
    await _disposeCamera();
    emit(CameraInitial());
  }

  //Handle Camera segment start event

  Future<void> _onSegmentedStart(
    CameraSegmentedStart event,
    Emitter<CameraState> emit,
  ) async {
    if (_segmentedMode) return;
    _segmentedMode = true;
    _segmentBusy = false;
    _segmentIndex = 0;
    _chunkSeconds = event.chunkSeconds;

    // Start the first segment
    try {
      await _startRecording();
      recordingDuration.value = 0;
      _startTimer(); // your existing duration UI timer is fine
      emit(CameraReady(isRecordingVideo: true));
    } catch (e) {
      _segmentedMode = false;
      await _reInitialize();
      emit(CameraReady(isRecordingVideo: false));
      return;
    }

    _segmentTimer?.cancel();
    _segmentTimer = Timer.periodic(Duration(seconds: _chunkSeconds), (_) async {
      await _cutSegmentAndContinue(emit);
    });
  }

  Future<void> _onSegmentedStop(
    CameraSegmentedStop event,
    Emitter<CameraState> emit,
  ) async {
    _segmentedMode = false;
    _segmentTimer?.cancel();
    _segmentTimer = null;

    if (isRecording()) {
      try {
        final f = await _stopRecordingFinal();
        emit(CameraChunkReady(file: f, index: _segmentIndex));
      } catch (_) {}
    }
    _segmentBusy = false;
    emit(CameraReady(isRecordingVideo: false));
  }


  // ................... Other methods ......................

  // Reset the camera BLoC to its initial state
  void _resetCameraBloc() {
    _cameraController = null;
    currentLensDirection = CameraLensDirection.front;
    _stopTimerAndResetDuration();
  }

  // Start the recording timer
  void _startTimer() {
    if (recordingTimer?.isActive ?? false) return; // guard
    recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      recordingDuration.value++;
      if (recordingDuration.value >= recordDurationLimit) {
        add(_segmentedMode ? const CameraSegmentedStop() : CameraRecordingStop());
      }
    });
  }


  // Stop the recording timer and reset the duration
  void _stopTimerAndResetDuration() async {
    recordingTimer?.cancel();
    recordingDuration.value = 0;
  }

  // Start video recording
  Future<void> _startRecording() async {
    try {
      await _cameraController!.startVideoRecording();
    } catch (e) {
      return Future.error(e);
    }
  }

  // Stop video recording and return the recorded video file
  Future<File> _stopRecordingChunk() async {
    try {
      XFile video = await _cameraController!.stopVideoRecording();
      return File(video.path);
    } catch (e) {
      return Future.error(e);
    }
  }

  Future<File> _stopRecordingFinal() async {
  try {
    final XFile video = await _cameraController!.stopVideoRecording();
    _stopTimerAndResetDuration(); // <-- only here
    return File(video.path);
  } catch (e) {
    return Future.error(e);
  }
}

  // Check and ask for camera permission and initialize camera
  Future<void> _checkPermissionAndInitializeCamera() async {
    if (await permissionUtils.getCameraAndMicrophonePermissionStatus()) {
      await _initializeCamera();
    } else {
      if (await permissionUtils.askForPermission()) {
        await _initializeCamera();
      } else {
        return Future.error(
          CameraErrorType.permission,
        ); // Throw the specific error type for permission denial
      }
    }
  }

  bool _isInitializing = false;
  // Initialize the camera controller
  Future<void> _initializeCamera() async {
    if (_isInitializing) return;
    if (_cameraController != null && _cameraController!.value.isInitialized) return;

    _isInitializing = true;
    try {
      _cameraController = await cameraUtils.getCameraController(
        lensDirection: currentLensDirection,
      );
      await _cameraController?.initialize();
    } on CameraException catch (error) {
      return Future.error(error);
    } finally {
      _isInitializing = false;
    }
  }

  // Switch between front and back cameras
  Future<void> _switchCamera() async {
    currentLensDirection =
        currentLensDirection == CameraLensDirection.back
            ? CameraLensDirection.front
            : CameraLensDirection.back;
    await _reInitialize();
  }

  // Reinitialize the camera
  Future<void> _reInitialize() async {
    await _disposeCamera();
    await _initializeCamera();
  }

  Future<void> _disposeCamera() async {
    _segmentedMode = false;
    _segmentTimer?.cancel();
    _segmentTimer = null;

    await _cameraController?.dispose();
    _stopTimerAndResetDuration();
    _cameraController = null;
  }

  Future<void> _cutSegmentAndContinue(Emitter<CameraState> emit) async {
    if (!_segmentedMode || _segmentBusy) return;
    if (!isRecording()) return;

    _segmentBusy = true;
    try {
      // stop current segment
      final f = await _stopRecordingChunk();
      emit(CameraChunkReady(file: f, index: _segmentIndex));
      _segmentIndex++;

      // start next segment immediately
      if (_segmentedMode) {
        await _startRecording();
        // don’t restart your 1s UI timer here; it’s tracking overall.
        emit(CameraReady(isRecordingVideo: true));
      }
    } catch (_) {
      // best effort recover
      try { await _reInitialize(); } catch (_) {}
      if (_segmentedMode) {
        try {
          await _startRecording();
          emit(CameraReady(isRecordingVideo: true));
        } catch (_) {
          _segmentedMode = false;
          emit(CameraReady(isRecordingVideo: false));
        }
      }
    } finally {
      _segmentBusy = false;
    }
  }

}
