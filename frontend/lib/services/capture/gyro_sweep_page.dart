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
import 'camera_selection_service.dart';
import 'gyro_sweep_tracker.dart';
import 'manual_capture_page.dart';

export 'camera_selection_service.dart';

class CaptureModePage extends StatefulWidget {
  const CaptureModePage({
    super.key,
    required this.session,
    this.selectedCamera,
  });
  final CaptureSession session;
  final CameraDescription? selectedCamera;

  @override
  State<CaptureModePage> createState() => _CaptureModePageState();
}

class _CaptureModePageState extends State<CaptureModePage> {
  late final TextEditingController sessionNameController;
  late final TextEditingController groundTruthNodeNameController;
  late final TextEditingController groundTruthLocalXController;
  late final TextEditingController groundTruthLocalYController;
  late final TextEditingController groundTruthLocalZController;

  late String groundTruthCampus;
  String? groundTruthBuilding;
  String? groundTruthFloor;
  String? lightingCondition;
  String? crowdLevel;
  String? occlusionLevel;
  String? sceneCondition;
  String? artificialLight;
  String? naturalLight;

  @override
  void initState() {
    super.initState();
    sessionNameController = TextEditingController(text: widget.session.name);
    groundTruthCampus = defaultGroundTruthCampus;
    groundTruthBuilding = groundTruthBuildingOptions.first;
    groundTruthFloor = groundTruthFloorOptions.first;
    groundTruthNodeNameController = TextEditingController(text: 'Node 1');
    groundTruthLocalXController = TextEditingController();
    groundTruthLocalYController = TextEditingController();
    groundTruthLocalZController = TextEditingController();
    lightingCondition = lightingConditionOptions.first;
    crowdLevel = crowdLevelOptions.first;
    occlusionLevel = occlusionLevelOptions.first;
    sceneCondition = sceneConditionOptions.first;
    artificialLight = 'Unknown';
    naturalLight = 'Unknown';
  }

  @override
  void dispose() {
    sessionNameController.dispose();
    groundTruthNodeNameController.dispose();
    groundTruthLocalXController.dispose();
    groundTruthLocalYController.dispose();
    groundTruthLocalZController.dispose();
    super.dispose();
  }

  Map<String, dynamic> _gatherMetadata() => {
    'session_name': sessionNameController.text.trim(),
    'ground_truth_campus': groundTruthCampus,
    'ground_truth_building': groundTruthBuilding,
    'ground_truth_floor': groundTruthFloor,
    'ground_truth_node_name': groundTruthNodeNameController.text.trim(),
    'ground_truth_local_x': double.tryParse(
      groundTruthLocalXController.text.trim(),
    ),
    'ground_truth_local_y': double.tryParse(
      groundTruthLocalYController.text.trim(),
    ),
    'ground_truth_local_z': double.tryParse(
      groundTruthLocalZController.text.trim(),
    ),
    'lighting_condition': lightingCondition,
    'crowd_level': crowdLevel,
    'occlusion_level': occlusionLevel,
    'scene_condition': sceneCondition,
    'artificial_light': artificialLight == 'Yes'
        ? true
        : (artificialLight == 'No' ? false : null),
    'natural_light': naturalLight == 'Yes'
        ? true
        : (naturalLight == 'No' ? false : null),
  };

  void _onSelectGyro() {
    LocalDatabase.instance.updateSessionName(
      widget.session.id,
      sessionNameController.text.trim(),
    );
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => GyroSweepPage(
          session: widget.session,
          selectedCamera: widget.selectedCamera,
          prefilledMetadata: _gatherMetadata(),
        ),
      ),
    );
  }

  void _onSelectManual() {
    if (sessionNameController.text.trim().isEmpty ||
        groundTruthBuilding == null ||
        groundTruthFloor == null ||
        groundTruthNodeNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please fill session name, building, floor, and node name.',
          ),
        ),
      );
      return;
    }
    LocalDatabase.instance.updateSessionName(
      widget.session.id,
      sessionNameController.text.trim(),
    );
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ManualCapturePage(
          session: widget.session,
          selectedCamera: widget.selectedCamera,
          prefilledMetadata: _gatherMetadata(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Select Capture Mode')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Select Capture Mode',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        const Text(
          'Set metadata below, then choose Gyro Triggered or Manual panorama capture.',
          style: TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 0,
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: _onSelectGyro,
                  icon: const Icon(Icons.explore),
                  label: const Text('Gyro Triggered'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _onSelectManual,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Manual'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'CAPTURE METADATA',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.black54,
            fontSize: 12,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 10),
        Card(
          elevation: 0,
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: sessionNameController,
                  decoration: const InputDecoration(labelText: 'Session name'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: groundTruthCampus,
                  decoration: const InputDecoration(
                    labelText: 'Ground Truth Campus',
                  ),
                  items: groundTruthCampusOptions
                      .map(
                        (value) =>
                            DropdownMenuItem(value: value, child: Text(value)),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setState(() => groundTruthCampus = value!),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: groundTruthBuilding,
                        decoration: const InputDecoration(
                          labelText: 'Building',
                        ),
                        items: groundTruthBuildingOptions
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(),
                        onChanged: (value) =>
                            setState(() => groundTruthBuilding = value),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: groundTruthFloor,
                        decoration: const InputDecoration(labelText: 'Floor'),
                        items: groundTruthFloorOptions
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(),
                        onChanged: (value) =>
                            setState(() => groundTruthFloor = value),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: groundTruthNodeNameController,
                  decoration: const InputDecoration(
                    labelText: 'Ground Truth Node Name',
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: groundTruthLocalXController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: const InputDecoration(labelText: 'Local X'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: groundTruthLocalYController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: const InputDecoration(labelText: 'Local Y'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: groundTruthLocalZController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: const InputDecoration(labelText: 'Local Z'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: lightingCondition,
                  decoration: const InputDecoration(
                    labelText: 'Lighting Condition',
                  ),
                  items: lightingConditionOptions
                      .map(
                        (val) => DropdownMenuItem(value: val, child: Text(val)),
                      )
                      .toList(),
                  onChanged: (val) => setState(() => lightingCondition = val),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: crowdLevel,
                        decoration: const InputDecoration(
                          labelText: 'Crowd Level',
                        ),
                        items: crowdLevelOptions
                            .map(
                              (val) => DropdownMenuItem(
                                value: val,
                                child: Text(val),
                              ),
                            )
                            .toList(),
                        onChanged: (val) => setState(() => crowdLevel = val),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: occlusionLevel,
                        decoration: const InputDecoration(
                          labelText: 'Occlusion Level',
                        ),
                        items: occlusionLevelOptions
                            .map(
                              (val) => DropdownMenuItem(
                                value: val,
                                child: Text(val),
                              ),
                            )
                            .toList(),
                        onChanged: (val) =>
                            setState(() => occlusionLevel = val),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: sceneCondition,
                  decoration: const InputDecoration(
                    labelText: 'Scene Condition',
                  ),
                  items: sceneConditionOptions
                      .map(
                        (val) => DropdownMenuItem(value: val, child: Text(val)),
                      )
                      .toList(),
                  onChanged: (val) => setState(() => sceneCondition = val),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class GyroSweepPage extends StatefulWidget {
  const GyroSweepPage({
    super.key,
    required this.session,
    this.selectedCamera,
    this.prefilledMetadata,
  });
  final CaptureSession session;
  final CameraDescription? selectedCamera;
  final Map<String, dynamic>? prefilledMetadata;

  @override
  State<GyroSweepPage> createState() => _GyroSweepPageState();
}

class _GyroSweepPageState extends State<GyroSweepPage>
    with WidgetsBindingObserver {
  CameraController? camera;
  CameraDescription? cameraDescription;
  Position? position;
  double? heading;
  double? pitch;
  double? roll;
  GyroSweepTracker? tracker;
  StreamSubscription<Position>? locationSub;
  StreamSubscription<CompassEvent>? compassSub;
  StreamSubscription<AccelerometerEvent>? motionSub;
  final groundTruthNodeNameController = TextEditingController();
  final sessionNameController = TextEditingController();
  final groundTruthLocalXController = TextEditingController();
  final groundTruthLocalYController = TextEditingController();
  final groundTruthLocalZController = TextEditingController();
  final List<CaptureRecord> captured = [];
  String groundTruthCampus = defaultGroundTruthCampus;
  String? groundTruthBuilding;
  String? groundTruthFloor;
  String? lightingCondition = lightingConditionOptions.first;
  String? crowdLevel = crowdLevelOptions.first;
  String? occlusionLevel = occlusionLevelOptions.first;
  String? sceneCondition = sceneConditionOptions.first;
  String? artificialLight = 'Unknown';
  String? naturalLight = 'Unknown';
  String status = 'Preparing camera and compass';
  String? sweepId;
  String? errorMessage;
  bool sweepActive = false;
  bool stoppingSession = false;
  bool busy = false;
  bool flash = false;
  int sweepCaptureCount = 0;
  Future<void> _captureQueue = Future<void>.value();

  bool get cameraReady => camera?.value.isInitialized == true;
  bool get sensorReady => heading != null;
  bool get manualMetadataReady =>
      sessionNameController.text.trim().isNotEmpty &&
      groundTruthBuilding != null &&
      groundTruthFloor != null &&
      groundTruthNodeNameController.text.trim().isNotEmpty &&
      _coordinatesValid;

  bool get _coordinatesValid =>
      [
        groundTruthLocalXController,
        groundTruthLocalYController,
        groundTruthLocalZController,
      ].every((controller) {
        final value = controller.text.trim();
        return value.isEmpty || double.tryParse(value) != null;
      });

  @override
  void initState() {
    super.initState();
    sessionNameController.text =
        widget.prefilledMetadata?['session_name'] as String? ??
        widget.session.name;
    groundTruthCampus =
        widget.prefilledMetadata?['ground_truth_campus'] as String? ??
        defaultGroundTruthCampus;
    groundTruthBuilding =
        widget.prefilledMetadata?['ground_truth_building'] as String?;
    groundTruthFloor =
        widget.prefilledMetadata?['ground_truth_floor'] as String?;
    if (widget.prefilledMetadata?['ground_truth_node_name'] != null) {
      groundTruthNodeNameController.text =
          widget.prefilledMetadata!['ground_truth_node_name'] as String;
    }
    if (widget.prefilledMetadata?['ground_truth_local_x'] != null) {
      groundTruthLocalXController.text = widget
          .prefilledMetadata!['ground_truth_local_x']
          .toString();
    }
    if (widget.prefilledMetadata?['ground_truth_local_y'] != null) {
      groundTruthLocalYController.text = widget
          .prefilledMetadata!['ground_truth_local_y']
          .toString();
    }
    if (widget.prefilledMetadata?['ground_truth_local_z'] != null) {
      groundTruthLocalZController.text = widget
          .prefilledMetadata!['ground_truth_local_z']
          .toString();
    }
    lightingCondition =
        widget.prefilledMetadata?['lighting_condition'] as String? ??
        lightingConditionOptions.first;
    crowdLevel =
        widget.prefilledMetadata?['crowd_level'] as String? ??
        crowdLevelOptions.first;
    occlusionLevel =
        widget.prefilledMetadata?['occlusion_level'] as String? ??
        occlusionLevelOptions.first;
    sceneCondition =
        widget.prefilledMetadata?['scene_condition'] as String? ??
        sceneConditionOptions.first;
    WidgetsBinding.instance.addObserver(this);
    _startSensors();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && sweepActive && mounted) {
      setState(() {
        sweepActive = false;
        errorMessage =
            'Sweep interrupted. Redo the sweep when the camera is ready.';
        status = errorMessage!;
      });
    }
  }

  Future<void> _startSensors() async {
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
    } catch (_) {
      if (mounted) {
        setState(
          () => status =
              'GPS unavailable. Capture can continue when it recovers.',
        );
      }
    }

    final compassEvents = FlutterCompass.events;
    if (compassEvents == null) {
      if (mounted) {
        setState(() => status = 'Compass unavailable on this device.');
      }
    } else {
      compassSub = compassEvents.listen((event) {
        final nextHeading = event.heading;
        if (nextHeading == null || !nextHeading.isFinite) return;
        if (!mounted) return;
        setState(
          () => heading = GyroSweepTracker.normalizeHeading(nextHeading),
        );
        _handleHeading(nextHeading);
      });
    }
    try {
      motionSub = accelerometerEventStream().listen((event) {
        if (mounted) {
          setState(() {
            pitch = event.x;
            roll = event.y;
          });
        }
      });
    } catch (_) {
      if (mounted) setState(() => status = 'Orientation sensor unavailable.');
    }
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty && widget.selectedCamera == null) {
        throw StateError('No camera found');
      }
      cameraDescription =
          widget.selectedCamera ?? await selectWideAngleRearCamera(cameras);
      camera = CameraController(
        cameraDescription!,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await camera!.initialize();
      if (mounted) setState(() => status = 'Ready to start a gyro sweep.');
    } catch (error) {
      if (mounted) {
        setState(() {
          status = error is StateError
              ? error.message
              : 'Camera permission or camera unavailable: $error';
        });
      }
    }
  }

  void _handleHeading(double nextHeading) {
    final currentTracker = tracker;
    if (!sweepActive || currentTracker == null) return;
    final update = currentTracker.update(nextHeading);
    if (update.tooFast) {
      _stopForSpeed();
      return;
    }
    if (update.triggerInterval != null) {
      _queueCapture(update);
    }
    if (update.cumulativeRotation >= 350 && update.triggerInterval == null) {
      unawaited(_captureQueue.then((_) => _finishSweep(currentTracker)));
    }
  }

  Future<void> _startSweep() async {
    final initialHeading = heading;
    if (!cameraReady || initialHeading == null || !manualMetadataReady) return;
    await LocalDatabase.instance.updateSessionName(
      widget.session.id,
      sessionNameController.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      sweepId = const Uuid().v4();
      tracker = GyroSweepTracker(initialHeading: initialHeading);
      sweepCaptureCount = 0;
      sweepActive = true;
      errorMessage = null;
      status = 'Rotate slowly through each 45° interval.';
    });
  }

  void _stopForSpeed() {
    if (!sweepActive) return;
    setState(() {
      sweepActive = false;
      errorMessage =
          'Rotation too fast — possible gap detected. Slow down and redo this segment.';
      status = errorMessage!;
    });
    unawaited(_showSpeedDialog());
  }

  Future<void> _showSpeedDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Sweep interrupted'),
        content: const Text(
          'Rotation too fast — possible gap detected. Slow down and redo this segment.',
        ),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _redoSweep();
            },
            child: const Text('Redo Sweep'),
          ),
        ],
      ),
    );
  }

  void _redoSweep() {
    if (heading == null || !cameraReady) return;
    setState(() {
      sweepId = const Uuid().v4();
      tracker = GyroSweepTracker(initialHeading: heading!);
      sweepCaptureCount = 0;
      sweepActive = true;
      errorMessage = null;
      status = 'Rotate slowly through each 45° interval.';
    });
  }

  void _queueCapture(SweepUpdate update) {
    final activeSweepId = sweepId;
    final currentTracker = tracker;
    if (activeSweepId == null || currentTracker == null) return;
    _captureQueue = _captureQueue.then((_) async {
      await _capture(update, activeSweepId, currentTracker);
      if (currentTracker.cumulativeRotation >= 350) {
        _finishSweep(currentTracker);
      }
    });
  }

  Future<void> _capture(
    SweepUpdate update,
    String activeSweepId,
    GyroSweepTracker currentTracker,
  ) async {
    if (!cameraReady || busy) return;
    setState(() => busy = true);
    try {
      final photo = await camera!.takePicture();
      final id = const Uuid().v4();
      final saved = (await StorageService().saveImage(
        File(photo.path),
        widget.session.id,
        id,
      )).split('|');
      final automatic = await _automaticCameraMetadata();
      final data = _metadata(
        saved[0],
        saved[1],
        id,
        activeSweepId,
        update,
        currentTracker,
        automatic,
      );
      final invalid = MetadataValidator.validate(
        data,
      ).where((item) => !item.valid).toList();
      if (invalid.isNotEmpty) {
        if (mounted) await _showValidation(invalid);
        return;
      }
      final record = CaptureRecord(
        id: id,
        sessionId: widget.session.id,
        filename: '$id.jpg',
        imagePath: saved[0],
        metadata: data,
        createdAt: DateTime.now(),
      );
      await LocalDatabase.instance.saveCapture(record);
      captured.add(record);
      sweepCaptureCount++;
      unawaited(_flashCapture());
      unawaited(SyncService().syncPending());
      if (mounted) {
        setState(() => status = 'Captured interval ${update.triggerInterval}.');
      }
    } catch (error) {
      if (mounted) setState(() => status = 'Capture failed: $error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Map<String, dynamic> _metadata(
    String path,
    String checksum,
    String imageId,
    String activeSweepId,
    SweepUpdate update,
    GyroSweepTracker currentTracker,
    Map<String, dynamic> automatic,
  ) => {
    'image_path': path,
    'checksum': checksum,
    'timestamp': DateTime.now().toIso8601String(),
    'gps_timestamp': position?.timestamp.toIso8601String(),
    'latitude': position?.latitude,
    'longitude': position?.longitude,
    'altitude': position?.altitude,
    'gps_accuracy': position?.accuracy,
    'location_source': 'native GPS',
    'heading': update.heading,
    'pitch': pitch,
    'roll': roll,
    ...automatic,
    'direction': currentTracker.direction,
    'view_angle': '${update.heading.toStringAsFixed(1)}°',
    'view_direction': currentTracker.direction,
    'building_name': groundTruthBuilding,
    'campus_name': groundTruthCampus,
    'floor_number': groundTruthFloor,
    'wing_name': 'North Wing',
    'area_type': 'Corridor',
    'node_id': null,
    'node_name': groundTruthNodeNameController.text.trim(),
    'dataset_split': 'reference',
    'capture_type': 'gyro_sweep',
    'collector_id': 'local-collector',
    'is_usable': true,
    'panorama_id': activeSweepId,
    'panorama_sequence_id': activeSweepId,
    'overlap_group_id': activeSweepId,
    'is_panorama_source': true,
    'panorama_status': 'in_progress',
    'frame_index': sweepCaptureCount,
    'preprocessing_version': 'unprocessed',
    'feature_method': null,
    'matching_method': null,
    'ground_truth_campus': groundTruthCampus,
    'ground_truth_building': groundTruthBuilding,
    'ground_truth_floor': groundTruthFloor,
    'ground_truth_node_name': groundTruthNodeNameController.text.trim(),
    'ground_truth_local_x': _numberValue(groundTruthLocalXController),
    'ground_truth_local_y': _numberValue(groundTruthLocalYController),
    'ground_truth_local_z': _numberValue(groundTruthLocalZController),
    'lighting_condition': lightingCondition,
    'crowd_level': crowdLevel,
    'occlusion_level': occlusionLevel,
    'artificial_light': _booleanValue(artificialLight),
    'natural_light': _booleanValue(naturalLight),
    'scene_condition': sceneCondition,
    'session_name': sessionNameController.text.trim(),
    'predicted_floor': null,
    'sweep_id': activeSweepId,
    'sweep_index': sweepCaptureCount,
    'heading_at_capture': update.heading,
    'sweep_trigger_interval_degrees': triggerIntervalDegrees,
    'sweep_direction': currentTracker.direction,
    'sweep_total_rotation_degrees': update.cumulativeRotation,
    'image_id': imageId,
  };

  double? _numberValue(TextEditingController controller) {
    final value = controller.text.trim();
    return value.isEmpty ? null : double.tryParse(value);
  }

  bool? _booleanValue(String? value) => switch (value) {
    'Yes' => true,
    'No' => false,
    _ => null,
  };

  Future<Map<String, dynamic>> _automaticCameraMetadata() async {
    final previewSize = camera?.value.previewSize;
    String? deviceMake;
    String? deviceModel;
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
    return {
      'device_make': deviceMake,
      'device_model': deviceModel,
      'camera_id': cameraDescription?.name,
      'image_width': previewSize?.width.round(),
      'image_height': previewSize?.height.round(),
      'camera_facing': cameraDescription?.lensDirection.name,
    };
  }

  Future<void> _flashCapture() async {
    if (!mounted) return;
    setState(() => flash = true);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (mounted) setState(() => flash = false);
  }

  void _finishSweep(GyroSweepTracker completedTracker) {
    if (!sweepActive || !identical(tracker, completedTracker)) return;
    setState(() {
      sweepId = const Uuid().v4();
      tracker = GyroSweepTracker(initialHeading: heading ?? 0);
      sweepCaptureCount = 0;
      status = 'Full rotation captured. Continue rotating for the next sweep.';
    });
  }

  Future<void> _stopAndSaveSession() async {
    if (stoppingSession) return;
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
            child: const Text('Continue capturing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop and save'),
          ),
        ],
      ),
    );
    if (shouldStop != true || !mounted) return;
    setState(() {
      stoppingSession = true;
      sweepActive = false;
      status = 'Saving session...';
    });
    try {
      await _captureQueue;
      await LocalDatabase.instance.updateSessionStatus(
        widget.session.id,
        'completed',
      );
      unawaited(SyncService().syncPending());
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          stoppingSession = false;
          status = 'Failed to save session: $error';
        });
      }
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
              const Text('Capture needs attention'),
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
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    camera?.dispose();
    locationSub?.cancel();
    compassSub?.cancel();
    motionSub?.cancel();
    groundTruthNodeNameController.dispose();
    sessionNameController.dispose();
    groundTruthLocalXController.dispose();
    groundTruthLocalYController.dispose();
    groundTruthLocalZController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (sweepActive || stoppingSession) return _activeSweepScreen();
    return Scaffold(
      appBar: AppBar(title: Text(widget.session.name)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _preview(height: 230),
          const SizedBox(height: 12),
          _metadataEntryControls(),
        ],
      ),
    );
  }

  Widget _activeSweepScreen() => PopScope<void>(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_stopAndSaveSession());
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Gyro Sweep'),
        actions: [
          TextButton.icon(
            onPressed: stoppingSession ? null : _stopAndSaveSession,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Stop & Save'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _preview()),
          _sweepControls(),
        ],
      ),
    ),
  );

  Widget _preview({double? height}) => SizedBox(
    height: height,
    child: Stack(
      fit: StackFit.expand,
      children: [
        cameraReady
            ? CameraPreview(camera!)
            : Container(
                color: const Color(0xff142422),
                alignment: Alignment.center,
                padding: const EdgeInsets.all(24),
                child: Text(
                  status,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
        if (sweepActive)
          Positioned(top: 18, left: 18, right: 18, child: _headingOverlay()),
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: flash ? 1 : 0,
            duration: const Duration(milliseconds: 120),
            child: const Center(
              child: Icon(Icons.check_circle, color: Colors.white, size: 82),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _headingOverlay() {
    final rotation = tracker?.cumulativeRotation ?? 0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _overlayMetric(
          'HEADING',
          heading == null ? '--' : '${heading!.toStringAsFixed(0)}°',
        ),
        _overlayMetric('ROTATION', '${rotation.toStringAsFixed(0)}° / 350°'),
      ],
    );
  }

  Widget _overlayMetric(String label, String value) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .65),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _sweepControls() {
    final rotation = tracker?.cumulativeRotation ?? 0;
    return Container(
      color: const Color(0xff142422),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 86,
                  height: 86,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: (rotation / 350).clamp(0, 1),
                        strokeWidth: 7,
                        color: Colors.tealAccent,
                        backgroundColor: Colors.white24,
                      ),
                      Text(
                        '${rotation.toStringAsFixed(0)}°',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${captured.length} images captured',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        tracker?.direction ?? 'Direction pending',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        status,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Rotate slowly',
              style: TextStyle(
                color: Colors.tealAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metadataEntryControls() => Column(
    children: [
      _groundTruthSection(),
      const SizedBox(height: 12),
      _startButton(),
    ],
  );

  Widget _startButton() => FilledButton.icon(
    onPressed: cameraReady && sensorReady && manualMetadataReady
        ? _startSweep
        : null,
    icon: const Icon(Icons.explore),
    label: const Text('Start Gyro Sweep'),
  );

  Widget _groundTruthSection() => Column(
    children: [
      TextField(
        controller: sessionNameController,
        onChanged: (_) => setState(() {}),
        style: const TextStyle(color: Colors.black),
        decoration: const InputDecoration(
          labelText: 'Session name',
          filled: true,
          fillColor: Colors.white,
        ),
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        initialValue: groundTruthCampus,
        decoration: const InputDecoration(
          labelText: 'Ground Truth Campus',
          filled: true,
          fillColor: Colors.white,
        ),
        items: groundTruthCampusOptions
            .map((value) => DropdownMenuItem(value: value, child: Text(value)))
            .toList(),
        onChanged: (value) => setState(() => groundTruthCampus = value!),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: _dropdown(
              'Ground-truth building',
              groundTruthBuilding,
              groundTruthBuildingOptions,
              (value) => setState(() => groundTruthBuilding = value),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _dropdown(
              'Ground-truth floor',
              groundTruthFloor,
              groundTruthFloorOptions,
              (value) => setState(() => groundTruthFloor = value),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      TextField(
        controller: groundTruthNodeNameController,
        onChanged: (_) => setState(() {}),
        style: const TextStyle(color: Colors.black),
        decoration: const InputDecoration(
          labelText: 'Ground Truth Node Name',
          filled: true,
          fillColor: Colors.white,
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: _numberField('Ground-truth X', groundTruthLocalXController),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _numberField('Ground-truth Y', groundTruthLocalYController),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _numberField('Ground-truth Z', groundTruthLocalZController),
          ),
        ],
      ),
      const SizedBox(height: 8),
      _dropdown(
        'Lighting',
        lightingCondition,
        lightingConditionOptions,
        (value) => setState(() => lightingCondition = value),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: _dropdown(
              'Crowd',
              crowdLevel,
              crowdLevelOptions,
              (value) => setState(() => crowdLevel = value),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _dropdown(
              'Occlusion',
              occlusionLevel,
              occlusionLevelOptions,
              (value) => setState(() => occlusionLevel = value),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: _dropdown('Artificial light', artificialLight, const [
              'Unknown',
              'Yes',
              'No',
            ], (value) => setState(() => artificialLight = value)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _dropdown('Natural light', naturalLight, const [
              'Unknown',
              'Yes',
              'No',
            ], (value) => setState(() => naturalLight = value)),
          ),
        ],
      ),
      const SizedBox(height: 8),
      _dropdown(
        'Scene condition',
        sceneCondition,
        sceneConditionOptions,
        (value) => setState(() => sceneCondition = value),
      ),
    ],
  );

  Widget _numberField(String label, TextEditingController controller) =>
      TextField(
        controller: controller,
        onChanged: (_) => setState(() {}),
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        style: const TextStyle(color: Colors.black),
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: Colors.white,
        ),
      );

  Widget _dropdown(
    String label,
    String? value,
    List<String> values,
    ValueChanged<String?> onChanged,
  ) => DropdownButtonFormField<String>(
    initialValue: value,
    decoration: InputDecoration(
      labelText: label,
      filled: true,
      fillColor: Colors.white,
    ),
    items: values
        .map((option) => DropdownMenuItem(value: option, child: Text(option)))
        .toList(),
    onChanged: onChanged,
  );
}
