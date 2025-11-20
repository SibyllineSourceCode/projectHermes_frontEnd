import '../services/camera/camera_bloc.dart';
import '../utils/camera_utils.dart';
import '../utils/permission_utils.dart';
import '../services/camera/camera_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final CameraBloc _bloc;

  @override
  void initState() {
    super.initState();
    _bloc = CameraBloc(
      cameraUtils: CameraUtils(),
      permissionUtils: PermissionUtils(),
    )..add(const CameraInitialize(recordingLimit: 60));
  }

  @override
  void dispose() {
    // Let the bloc clean up the controller in its own close()
    _bloc.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Use .value so we DON'T recreate the bloc on rebuilds.
    return BlocProvider.value(
      value: _bloc,
      child: const CameraPage(),
    );
  }
}

