import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/local_database.dart';
import '../../data/models/ground_truth_options.dart';
import '../../data/models/legacy_models.dart';
import '../storage/storage_service.dart';
import '../sync/sync_service.dart';
import '../validation/metadata_validator.dart';
import 'gyro_sweep_page.dart';

Map<String, dynamic> manualPanoramaFields(
  String panoramaId,
  int frameIndex, {
  String status = 'completed',
}) => {
  'panorama_id': panoramaId,
  'panorama_sequence_id': panoramaId,
  'overlap_group_id': panoramaId,
  'is_panorama_source': true,
  'panorama_status': status,
  'frame_index': frameIndex,
};

class ManualCapturePage extends StatefulWidget {
  const ManualCapturePage({
    super.key,
    required this.session,
    this.selectedCamera,
    this.prefilledMetadata,
  });

  final CaptureSession session;
  final CameraDescription? selectedCamera;
  final Map<String, dynamic>? prefilledMetadata;

  @override
  State<ManualCapturePage> createState() => _ManualCapturePageState();
}

class _ManualCapturePageState extends State<ManualCapturePage> {
  static const int panoramaFrameCount = 8;

  CameraController? camera;
  CameraDescription? cameraDescription;
  String? cameraError;

  Position? position;
  double? heading;
  double? pitch;
  double? roll;
  String? deviceMake;
  String? deviceModel;

  StreamSubscription<Position>? locationSub;
  StreamSubscription<CompassEvent>? compassSub;
  StreamSubscription<AccelerometerEvent>? motionSub;

  late String panoramaId;
  final List<CaptureRecord> captured = [];

  bool busy = false;
  bool flash = false;
  String status = 'Initializing rear wide-angle camera...';

  // Metadata preserved from pre-capture state
  late String sessionName;
  late String groundTruthCampus;
  String? groundTruthBuilding;
  String? groundTruthFloor;
  late String groundTruthNodeName;
  double? groundTruthLocalX;
  double? groundTruthLocalY;
  double? groundTruthLocalZ;
  String? lightingCondition;
  String? crowdLevel;
  String? occlusionLevel;
  String? sceneCondition;
  bool? artificialLight;
  bool? naturalLight;

  bool get cameraReady => camera?.value.isInitialized == true;

  @override
  void initState() {
    super.initState();
    panoramaId = const Uuid().v4();
    _initMetadata();
    _startSensorsAndCamera();
  }

  void _initMetadata() {
    final meta = widget.prefilledMetadata;
    sessionName = meta?['session_name'] as String? ?? widget.session.name;
    groundTruthCampus =
        meta?['ground_truth_campus'] as String? ?? defaultGroundTruthCampus;
    groundTruthBuilding =
        meta?['ground_truth_building'] as String? ??
        groundTruthBuildingOptions.first;
    groundTruthFloor =
        meta?['ground_truth_floor'] as String? ?? groundTruthFloorOptions.first;
    groundTruthNodeName =
        meta?['ground_truth_node_name'] as String? ?? 'Node 1';
    groundTruthLocalX = meta?['ground_truth_local_x'] as double?;
    groundTruthLocalY = meta?['ground_truth_local_y'] as double?;
    groundTruthLocalZ = meta?['ground_truth_local_z'] as double?;
    lightingCondition =
        meta?['lighting_condition'] as String? ??
        lightingConditionOptions.first;
    crowdLevel = meta?['crowd_level'] as String? ?? crowdLevelOptions.first;
    occlusionLevel =
        meta?['occlusion_level'] as String? ?? occlusionLevelOptions.first;
    sceneCondition =
        meta?['scene_condition'] as String? ?? sceneConditionOptions.first;
    artificialLight = meta?['artificial_light'] as bool?;
    naturalLight = meta?['natural_light'] as bool?;
  }

  Future<void> _startSensorsAndCamera() async {
    // GPS
    try {
      if (await Geolocator.checkPermission() == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
      position = await Geolocator.getCurrentPosition();
      locationSub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: 1,
            ),
          ).listen((value) {
            if (mounted) setState(() => position = value);
          });
    } catch (_) {}

    // Compass for heading orientation metadata & display guidance
    try {
      compassSub = FlutterCompass.events?.listen((event) {
        if (mounted && event.heading != null && event.heading!.isFinite) {
          setState(() {
            heading = (event.heading! % 360 + 360) % 360;
          });
        }
      });
    } catch (_) {}

    // Accelerometer for pitch and roll orientation metadata & display guidance
    try {
      motionSub = accelerometerEventStream().listen((event) {
        if (mounted) {
          setState(() {
            pitch = event.x;
            roll = event.y;
          });
        }
      });
    } catch (_) {}

    // Device Info
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        deviceMake = info.manufacturer;
        deviceModel = info.model;
      } else if (Platform.isIOS) {
        final info = await deviceInfo.iosInfo;
        deviceMake = 'Apple';
        deviceModel = info.utsname.machine;
      }
    } catch (_) {}

    // Rear wide-angle camera strictly required
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw StateError('No cameras available on this device');
      }
      cameraDescription =
          widget.selectedCamera ?? await selectWideAngleRearCamera(cameras);
      final controller = CameraController(
        cameraDescription!,
        ResolutionPreset.high,
        enableAudio: false,
      );
      camera = controller;
      await controller.initialize();
      if (mounted) {
        setState(() {
          cameraError = null;
          status = 'Ready to capture. Rotate clockwise between photos.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          cameraError = error is StateError
              ? error.message
              : 'Rear wide-angle camera unavailable: $error';
          status = cameraError!;
        });
      }
    }
  }

  @override
  void dispose() {
    camera?.dispose();
    locationSub?.cancel();
    compassSub?.cancel();
    motionSub?.cancel();
    super.dispose();
  }

  Future<void> _capture() async {
    if (!cameraReady || busy) return;
    setState(() => busy = true);

    try {
      final frameIndex = captured.length % panoramaFrameCount;
      final photo = await camera!.takePicture();
      final imageId = const Uuid().v4();
      final saved = (await StorageService().saveImage(
        File(photo.path),
        widget.session.id,
        imageId,
      )).split('|');

      final data = _buildMetadata(
        imagePath: saved[0],
        checksum: saved[1],
        imageId: imageId,
        frameIndex: frameIndex,
      );

      final invalid = MetadataValidator.validate(
        data,
      ).where((item) => !item.valid).toList();
      if (invalid.isNotEmpty) {
        if (mounted) await _showValidation(invalid);
        return;
      }

      final record = CaptureRecord(
        id: imageId,
        sessionId: widget.session.id,
        filename: '$imageId.jpg',
        imagePath: saved[0],
        metadata: data,
        createdAt: DateTime.now(),
      );

      await LocalDatabase.instance.saveCapture(record);
      captured.add(record);
      unawaited(SyncService().syncPending());
      final panoramaComplete = frameIndex == panoramaFrameCount - 1;
      if (panoramaComplete) panoramaId = const Uuid().v4();

      if (mounted) {
        setState(() {
          flash = true;
          status = panoramaComplete
              ? 'Panorama saved. Continue capturing the next panorama.'
              : 'Photo saved. ${captured.length} captured this session.';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (mounted) setState(() => flash = false);
    } catch (error) {
      if (mounted) setState(() => status = 'Capture failed: $error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Map<String, dynamic> _buildMetadata({
    required String imagePath,
    required String checksum,
    required String imageId,
    required int frameIndex,
  }) {
    final previewSize = camera?.value.previewSize;
    final currentHeading = heading;
    final currentPitch = pitch;
    final currentRoll = roll;
    final viewAngleStr =
        '${(currentHeading ?? (frameIndex * 45.0)).toStringAsFixed(1)}°';

    return {
      'image_path': imagePath,
      'checksum': checksum,
      'timestamp': DateTime.now().toIso8601String(),
      'gps_timestamp': position?.timestamp.toIso8601String(),
      'latitude': position?.latitude,
      'longitude': position?.longitude,
      'altitude': position?.altitude,
      'gps_accuracy': position?.accuracy,
      'location_source': 'native GPS',

      // Orientation metadata preserved (Requirement 7)
      'heading': currentHeading,
      'pitch': currentPitch,
      'roll': currentRoll,
      'direction': 'Clockwise',
      'view_angle': viewAngleStr,
      'camera_facing': cameraDescription?.lensDirection.name ?? 'back',
      'view_direction': 'Clockwise',

      // Camera metadata
      'device_make': deviceMake,
      'device_model': deviceModel,
      'camera_id': cameraDescription?.name,
      'image_width': previewSize?.width.round(),
      'image_height': previewSize?.height.round(),

      // Session & Location
      'session_name': sessionName,
      'building_name': groundTruthBuilding,
      'campus_name': groundTruthCampus,
      'floor_number': groundTruthFloor,
      'wing_name': 'North Wing',
      'area_type': 'Corridor',
      'node_id': null,
      'node_name': groundTruthNodeName,
      'dataset_split': 'reference',
      'capture_type': 'manual_panorama',
      'collector_id': 'local-collector',
      'is_usable': true,

      // Existing panorama grouping fields (Requirement 6)
      ...manualPanoramaFields(panoramaId, frameIndex, status: 'completed'),

      'preprocessing_version': 'unprocessed',
      'feature_method': null,
      'matching_method': null,

      // Ground truth fields
      'ground_truth_campus': groundTruthCampus,
      'ground_truth_building': groundTruthBuilding,
      'ground_truth_floor': groundTruthFloor,
      'ground_truth_node_name': groundTruthNodeName,
      'ground_truth_local_x': groundTruthLocalX,
      'ground_truth_local_y': groundTruthLocalY,
      'ground_truth_local_z': groundTruthLocalZ,

      // Environmental fields
      'lighting_condition': lightingCondition,
      'crowd_level': crowdLevel,
      'occlusion_level': occlusionLevel,
      'artificial_light': artificialLight,
      'natural_light': naturalLight,
      'scene_condition': sceneCondition,
      'predicted_floor': null,

      // Sweep compatibility fields
      'sweep_id': panoramaId,
      'sweep_index': frameIndex,
      'heading_at_capture': currentHeading,
      'sweep_trigger_interval_degrees': 45.0,
      'sweep_direction': 'Clockwise',
      'sweep_total_rotation_degrees': frameIndex * 45.0,
      'image_id': imageId,
    };
  }

  Future<void> _stopAndSaveSession() async {
    if (busy) return;
    final shouldStop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop and save session?'),
        content: Text(
          '${captured.length} photo(s) have been saved to this session. Stop capturing now?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop and save'),
          ),
        ],
      ),
    );

    if (shouldStop != true || !mounted) return;
    setState(() => busy = true);
    try {
      await LocalDatabase.instance.updateSessionStatus(
        widget.session.id,
        'completed',
      );
      unawaited(SyncService().syncPending());
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save session: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _showValidation(List<ValidationItem> invalid) =>
      showModalBottomSheet<void>(
        context: context,
        builder: (context) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Capture needs attention',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              ...invalid.map(
                (item) => ListTile(
                  leading: const Icon(
                    Icons.error_outline,
                    color: Colors.orange,
                  ),
                  title: Text(item.label),
                  subtitle: Text(item.detail),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => _buildCaptureScreen();

  Widget _buildCaptureScreen() => PopScope<void>(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_stopAndSaveSession());
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Manual Panorama'),
        leading: IconButton(
          icon: const Icon(Icons.stop_circle_outlined),
          tooltip: 'Stop and save session',
          onPressed: busy ? null : _stopAndSaveSession,
        ),
        actions: [
          TextButton.icon(
            onPressed: busy ? null : _stopAndSaveSession,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Stop & Save'),
          ),
        ],
      ),
      body: cameraError != null
          ? _buildCameraErrorView()
          : Column(
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      cameraReady
                          ? CameraPreview(camera!)
                          : Container(
                              color: const Color(0xff142422),
                              alignment: Alignment.center,
                              child: const CircularProgressIndicator(
                                color: Colors.white,
                              ),
                            ),
                      Positioned(
                        top: 14,
                        left: 14,
                        right: 14,
                        child: _buildSensorHud(),
                      ),
                      IgnorePointer(
                        child: AnimatedOpacity(
                          opacity: flash ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 120),
                          child: const Center(
                            child: Icon(
                              Icons.check_circle,
                              color: Colors.tealAccent,
                              size: 80,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _buildCaptureControls(),
              ],
            ),
    ),
  );

  Widget _buildSensorHud() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _metric(
          'HEADING',
          heading == null ? '--' : '${heading!.toStringAsFixed(0)}°',
        ),
        _metric('PITCH', pitch == null ? '--' : pitch!.toStringAsFixed(1)),
        _metric('ROLL', roll == null ? '--' : roll!.toStringAsFixed(1)),
        _metric(
          'GPS',
          position == null ? '--' : '${position!.accuracy.toStringAsFixed(1)}m',
        ),
      ],
    ),
  );

  Widget _metric(String label, String value) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10)),
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    ],
  );

  Widget _buildCaptureControls() => Container(
    color: const Color(0xff142422),
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Photo ${(captured.length % panoramaFrameCount) + 1} in panorama',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '${captured.length} captured this session',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Rotate clockwise between photos. Session has no photo limit.',
            style: const TextStyle(
              color: Colors.tealAccent,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 76,
            height: 76,
            child: FloatingActionButton(
              onPressed: busy || !cameraReady ? null : _capture,
              backgroundColor: Colors.tealAccent.shade700,
              elevation: 4,
              shape: const CircleBorder(),
              child: busy
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Icon(Icons.camera_alt, size: 38, color: Colors.white),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildCameraErrorView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Card(
        color: Colors.red.shade50,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.red.shade200),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.no_photography_outlined,
                color: Colors.red.shade700,
                size: 56,
              ),
              const SizedBox(height: 12),
              Text(
                'Wide-Angle Camera Required',
                style: TextStyle(
                  color: Colors.red.shade900,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                cameraError ??
                    'Rear wide-angle / ultra-wide camera could not be identified or initialized.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.red.shade800),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () => Navigator.pop(context),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
