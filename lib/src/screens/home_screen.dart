import '../services/camera/camera_bloc.dart';
import '../utils/camera_utils.dart';
import '../utils/permission_utils.dart';
import '../services/camera/camera_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text("Home"), centerTitle: true),
      body: Center(
        child: ElevatedButton(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder:
                    (context) => BlocProvider(
                      create: (context) {
                        return CameraBloc(
                          cameraUtils: CameraUtils(),
                          permissionUtils: PermissionUtils(),
                        )..add(const CameraInitialize(recordingLimit: 15));
                      },
                      child: const CameraPage(),
                    ),
              ),
            );
          },
          child: const Padding(
            padding: EdgeInsets.all(12.0),
            child: Text("Camera 📷", style: TextStyle(fontSize: 25)),
          ),
        ),
      ),
    );
  }
}
