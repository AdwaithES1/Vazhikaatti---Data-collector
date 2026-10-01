import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'camera_selection_service.dart';

typedef CameraSelected = void Function(
  BuildContext context,
  CameraDescription camera,
);

class CameraSetupPage extends StatefulWidget {
  const CameraSetupPage({super.key, required this.onSelected});

  final CameraSelected onSelected;

  @override
  State<CameraSetupPage> createState() => _CameraSetupPageState();
}

class _CameraSetupPageState extends State<CameraSetupPage> {
  List<CameraDescription> cameras = const [];
  CameraDescription? selectedCamera;
  String? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _loadCameras();
  }

  Future<void> _loadCameras() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final available = await availableCameras();
      if (available.isEmpty) {
        throw StateError('No cameras are available on this device.');
      }

      CameraDescription? recommended;
      try {
        recommended = await selectWideAngleRearCamera(
          available,
          debugLog: false,
        );
      } catch (_) {
        recommended = available.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.back,
          orElse: () => available.first,
        );
      }

      if (!mounted) return;
      setState(() {
        cameras = available;
        selectedCamera = recommended;
        loading = false;
      });
    } catch (value) {
      if (!mounted) return;
      setState(() {
        error = 'Unable to list cameras: $value';
        loading = false;
      });
    }
  }

  void _continue() {
    final camera = selectedCamera;
    if (camera == null) return;
    widget.onSelected(context, camera);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choose wide-angle camera')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? _ErrorView(message: error!, onRetry: _loadCameras)
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  'Select the camera to use for this launch.',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Camera numbering differs between phone models. Choose the rear wide-angle or ultra-wide camera from the list below. This choice is requested again after the app restarts.',
                ),
                const SizedBox(height: 20),
                ...cameras.indexed.map((entry) {
                  final index = entry.$1;
                  final camera = entry.$2;
                  final isSelected = camera == selectedCamera;
                  return Card(
                    child: ListTile(
                      onTap: () => setState(() => selectedCamera = camera),
                      leading: Checkbox(
                        value: isSelected,
                        onChanged: (_) =>
                            setState(() => selectedCamera = camera),
                      ),
                      title: Text('Camera index $index'),
                      subtitle: Text(
                        '${camera.name} · ${camera.lensDirection.name} · ${camera.sensorOrientation}° sensor',
                      ),
                      trailing: isSelected
                          ? const Icon(Icons.check_circle, color: Colors.teal)
                          : const Icon(Icons.camera_alt_outlined),
                    ),
                  );
                }),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _continue,
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Continue with selected camera'),
                ),
              ],
            ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    ),
  );
}