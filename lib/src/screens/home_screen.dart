import '../services/camera/camera_bloc.dart';
import '../utils/camera_utils.dart';
import '../utils/permission_utils.dart';
import '../services/camera/camera_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) {
        return CameraBloc(
          cameraUtils: CameraUtils(),
          permissionUtils: PermissionUtils(),
        )..add(const CameraInitialize(recordingLimit: 60));
      },
      child: const CameraPage(),
    );
  }
}
