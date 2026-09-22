import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:sensors_plus/sensors_plus.dart';
import 'package:uuid/uuid.dart';
import 'data/database/local_database.dart';
import 'data/models/ground_truth_options.dart';
import 'data/models/legacy_models.dart';
import 'services/panorama/panorama_stitcher.dart';
import 'services/storage/storage_service.dart';
import 'services/validation/metadata_validator.dart';
import 'services/api/api_client.dart';
import 'services/api/session_api.dart';
import 'services/sync/sync_page.dart';
import 'services/sync/sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VazhikattiApp());
}

class VazhikattiApp extends StatelessWidget {
  const VazhikattiApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Vazhikatti Dataset Collector',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff0b6e69)),
      scaffoldBackgroundColor: const Color(0xfff4f7f5),
      useMaterial3: true,
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  List<CaptureSession> sessions = [];
  int count = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    sessions = await LocalDatabase.instance.sessions();
    count = await LocalDatabase.instance.captureCount();
    if (mounted) setState(() {});
  }

  Future<void> newSession() async {
    final controller = TextEditingController(
      text:
          'Field session ${DateFormat('MMM d, HH:mm').format(DateTime.now())}',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New capture session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Session name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final session = CaptureSession(
      id: const Uuid().v4(),
      name: name,
      createdAt: DateTime.now(),
    );
    await LocalDatabase.instance.saveSession(session);
    try {
      await SessionApi(ApiClient()).create(session);
    } catch (_) {
      // Local session storage remains authoritative when the server is unavailable.
    }
    await load();
    if (mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => CapturePage(session: session)),
      );
    }
    await load();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [_overview(), _dataset(), const ExportPage()];
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'VAZHIKATTI',
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.4),
        ),
        actions: [
          IconButton(
            tooltip: 'Synchronization',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SyncPage()),
            ),
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: pages[tab],
      floatingActionButton: tab == 0
          ? FloatingActionButton.extended(
              onPressed: newSession,
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('New session'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (value) => setState(() => tab = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            label: 'Overview',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_library_outlined),
            label: 'Dataset',
          ),
          NavigationDestination(
            icon: Icon(Icons.ios_share_outlined),
            label: 'Export',
          ),
        ],
      ),
    );
  }

  Widget _overview() {
    final children = <Widget>[
      Text(
        'Field collection',
        style: Theme.of(
          context,
        ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
      ),
      const Text('Offline capture workspace for Visual Campus Navigator.'),
      const SizedBox(height: 24),
      Row(
        children: [
          _stat('$count', 'images'),
          const SizedBox(width: 12),
          _stat('${sessions.length}', 'sessions'),
          const SizedBox(width: 12),
          _stat('LOCAL', 'storage'),
        ],
      ),
      const SizedBox(height: 28),
      const Text(
        'RECENT SESSIONS',
        style: TextStyle(fontWeight: FontWeight.w800, color: Colors.black54),
      ),
      const SizedBox(height: 12),
    ];
    if (sessions.isEmpty) {
      children.add(
        const Card(
          child: ListTile(
            leading: Icon(Icons.camera_alt_outlined),
            title: Text('No sessions yet'),
            subtitle: Text(
              'Create a session to begin collecting reference images.',
            ),
          ),
        ),
      );
    } else {
      children.addAll(sessions.take(5).map(_sessionCard));
    }
    children.addAll([
      const SizedBox(height: 24),
      const Text(
        'COLLECTION CHECKLIST',
        style: TextStyle(fontWeight: FontWeight.w800, color: Colors.black54),
      ),
      _check('Explicit building, floor and node'),
      _check('GPS and orientation are stable'),
      _check('Original image retained on edits'),
      _check('Export only when you choose'),
    ]);
    return ListView(padding: const EdgeInsets.all(20), children: children);
  }

  Widget _sessionCard(CaptureSession session) => Card(
    elevation: 0,
    child: ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(session.name),
      subtitle: Text(DateFormat.yMMMd().add_jm().format(session.createdAt)),
    ),
  );
  Widget _stat(String value, String label) => Expanded(
    child: Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.analytics_outlined, color: Color(0xff0b6e69)),
            const SizedBox(height: 8),
            Text(
              value,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            Text(label, style: const TextStyle(color: Colors.black54)),
          ],
        ),
      ),
    ),
  );
  Widget _check(String text) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.check_circle, color: Colors.teal),
    title: Text(text),
  );
  Widget _dataset() => FutureBuilder<List<CaptureRecord>>(
    future: LocalDatabase.instance.captures(),
    builder: (context, snapshot) {
      final rows = snapshot.data ?? <CaptureRecord>[];
      final cards = rows
          .map<Widget>(
            (row) => Card(
              elevation: 0,
              child: ListTile(
                leading: const Icon(Icons.image_outlined),
                title: Text(row.filename),
                subtitle: Text(
                  '${row.metadata['building_name']} • ${row.metadata['floor_number']} • ${row.metadata['view_direction']}',
                ),
              ),
            ),
          )
          .toList();
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'DATASET BROWSER',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: Colors.black54,
            ),
          ),
          const SizedBox(height: 12),
          if (cards.isEmpty)
            const Card(
              child: ListTile(title: Text('No accepted captures yet.')),
            )
          else
            ...cards,
        ],
      );
    },
  );
}

const panoramaDirection = 'Panorama (8)';
const _panoramaShots = 8;
const _panoramaStepDegrees = 45;
// A typical rear camera's usable horizontal field of view is ~60-70deg, so a
// 45deg step leaves only ~15-25deg of true overlap between neighbouring
// shots to begin with. Real-world testing against actual phone captures
// showed +-12deg of drift on top of that (steps up to 57deg) was enough to
// erase that overlap entirely and make stitching geometrically impossible,
// no matter how the matching is tuned - so the tolerance is kept tight
// enough to protect that overlap budget rather than just user convenience.
const _panoramaToleranceDegrees = 6;

class CapturePage extends StatefulWidget {
  const CapturePage({super.key, required this.session});
  final CaptureSession session;
  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  CameraController? camera;
  Position? position;
  double? heading;
  double? pitch;
  double? roll;
  StreamSubscription<Position>? locationSub;
  StreamSubscription<CompassEvent>? compassSub;
  StreamSubscription<AccelerometerEvent>? motionSub;
  String direction = 'Front';
  String split = 'reference';
  String node = sampleNodes.first['node'] as String;
  String groundTruthCampus = defaultGroundTruthCampus;
  String? groundTruthBuilding;
  String? groundTruthFloor;
  final groundTruthNodeNameController = TextEditingController();
  bool busy = false;
  String status = 'Waiting for camera and sensors';
  String? panoramaId;
  double panoramaBaseHeading = 0;
  final panoramaFrames = <CaptureRecord>[];
  @override
  void initState() {
    super.initState();
    startSensors();
  }

  Future<void> startSensors() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled() && mounted) {
        setState(() => status = 'Location disabled. Enable it before capture.');
      }
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
        setState(() => status = 'GPS unavailable. Wait for a location fix.');
      }
    }
    compassSub = FlutterCompass.events?.listen((event) {
      if (mounted) {
        setState(() => heading = event.heading);
      }
    });
    motionSub = accelerometerEventStream().listen((event) {
      if (mounted) {
        setState(() {
          pitch = event.x;
          roll = event.y;
        });
      }
    });
    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        camera = CameraController(
          cameras.first,
          ResolutionPreset.high,
          enableAudio: false,
        );
        await camera!.initialize();
        if (mounted) setState(() {});
      }
    } catch (_) {
      if (mounted) {
        setState(() => status = 'Camera permission or camera unavailable.');
      }
    }
  }

  @override
  void dispose() {
    camera?.dispose();
    locationSub?.cancel();
    compassSub?.cancel();
    motionSub?.cancel();
    groundTruthNodeNameController.dispose();
    super.dispose();
  }

  Map<String, dynamic> metadata(String path, String checksum) => {
    'image_path': path,
    'checksum': checksum,
    'timestamp': DateTime.now().toIso8601String(),
    'gps_timestamp': position?.timestamp.toIso8601String(),
    'latitude': position?.latitude,
    'longitude': position?.longitude,
    'altitude': position?.altitude,
    'gps_accuracy': position?.accuracy,
    'location_source': 'native GPS',
    'heading': heading,
    'pitch': pitch,
    'roll': roll,
    'direction': direction,
    'view_angle': direction,
    'camera_facing': 'back',
    'view_direction': direction,
    'building_name': 'Engineering Block',
    'building_id': 'ENG',
    'campus_name': 'Main Campus',
    'floor_number': 'Ground Floor',
    'floor_id': 'G',
    'wing_name': 'North Wing',
    'area_type': 'Corridor',
    'node_id': node,
    'node_name': 'Selected node',
    'dataset_split': split,
    'capture_type': 'single',
    'collector_id': 'local-collector',
    'is_usable': true,
    'panorama_status': 'not_panorama',
    'preprocessing_version': 'unprocessed',
    'feature_method': null,
    'matching_method': null,
    'ground_truth_campus': groundTruthCampus,
    'ground_truth_building': groundTruthBuilding,
    'ground_truth_floor': groundTruthFloor,
    'ground_truth_node_name': groundTruthNodeNameController.text.trim(),
    'predicted_floor': null,
  };
  Future<void> capture() async {
    if (camera == null || !camera!.value.isInitialized || busy) return;
    if (direction == panoramaDirection) return capturePanorama();
    setState(() => busy = true);
    try {
      final photo = await camera!.takePicture();
      final id = const Uuid().v4();
      final saved = (await StorageService().saveImage(
        File(photo.path),
        widget.session.id,
        id,
      )).split('|');
      final data = metadata(saved[0], saved[1]);
      final invalid = MetadataValidator.validate(
        data,
      ).where((item) => !item.valid).toList();
      if (invalid.isNotEmpty) {
        if (mounted) await showValidation(invalid);
      } else {
        await LocalDatabase.instance.saveCapture(
          CaptureRecord(
            id: id,
            sessionId: widget.session.id,
            filename: '$id.jpg',
            imagePath: saved[0],
            metadata: data,
            createdAt: DateTime.now(),
          ),
        );
        unawaited(SyncService().syncPending());
        if (mounted) setState(() => status = 'Saved $id.jpg locally');
      }
    } catch (error) {
      if (mounted) setState(() => status = 'Capture failed: $error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  double _relativeHeading() =>
      ((heading! - panoramaBaseHeading) % 360 + 360) % 360;

  Future<void> capturePanorama() async {
    if (panoramaFrames.length == _panoramaShots) {
      // All 8 frames are stored; a previous stitch failed, so retry it.
      return stitchPanorama();
    }
    final index = panoramaFrames.length;
    final target = index * _panoramaStepDegrees;
    // Validate with the existing validator before taking the picture.
    final invalid = MetadataValidator.validate(
      metadata('pending', ''),
    ).where((item) => !item.valid).toList();
    if (index > 0 && heading != null) {
      final diff = (_relativeHeading() - target + 540) % 360 - 180;
      if (diff.abs() > _panoramaToleranceDegrees) {
        invalid.add(
          ValidationItem(
            'Panorama angle',
            false,
            'Turn to $target° (now ${_relativeHeading().toStringAsFixed(0)}°) '
                'without moving from this spot',
          ),
        );
      }
    }
    if (invalid.isNotEmpty) {
      if (mounted) await showValidation(invalid);
      return;
    }
    setState(() => busy = true);
    try {
      if (index == 0) {
        panoramaId = const Uuid().v4();
        panoramaBaseHeading = heading!;
      }
      final photo = await camera!.takePicture();
      final id = const Uuid().v4();
      final saved = (await StorageService().saveImage(
        File(photo.path),
        widget.session.id,
        id,
      )).split('|');
      final data = {
        ...metadata(saved[0], saved[1]),
        'view_angle': '$target',
        'capture_type': 'panorama',
        'panorama_id': panoramaId,
        'panorama_sequence_id': panoramaId,
        'overlap_group_id': panoramaId,
        'frame_index': index,
        'is_panorama_source': true,
        'panorama_status': 'capturing',
      };
      final record = CaptureRecord(
        id: id,
        sessionId: widget.session.id,
        filename: '$id.jpg',
        imagePath: saved[0],
        metadata: data,
        createdAt: DateTime.now(),
      );
      await LocalDatabase.instance.saveCapture(record);
      panoramaFrames.add(record);
      if (panoramaFrames.length == _panoramaShots) {
        await stitchPanorama();
      } else if (mounted) {
        setState(
          () => status =
              'Panorama ${panoramaFrames.length}/$_panoramaShots saved. '
              'Turn to ${panoramaFrames.length * _panoramaStepDegrees}°',
        );
      }
    } catch (error) {
      if (mounted) setState(() => status = 'Capture failed: $error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> stitchPanorama() async {
    if (mounted) setState(() => busy = true);
    final output = File(
      p.join(Directory.systemTemp.path, '${panoramaId}_panorama.jpg'),
    );
    try {
      await _setPanoramaStatus('stitching');
      final result = await PanoramaStitcher.stitch(
        panoramaFrames.map((f) => f.imagePath).toList(),
        output.path,
      );
      final id = const Uuid().v4();
      final saved = (await StorageService().saveImage(
        output,
        widget.session.id,
        id,
      )).split('|');
      await LocalDatabase.instance.saveCapture(
        CaptureRecord(
          id: id,
          sessionId: widget.session.id,
          filename: '$id.jpg',
          imagePath: saved[0],
          metadata: {
            ...panoramaFrames.first.metadata,
            'image_path': saved[0],
            'checksum': saved[1],
            'timestamp': DateTime.now().toIso8601String(),
            'view_angle': '360',
            'capture_type': 'panorama',
            'frame_index': null,
            'is_panorama_source': false,
            'panorama_status': 'completed',
            'image_width': result.width,
            'image_height': result.height,
            'feature_method': 'SIFT',
            'descriptor_dimension': PanoramaStitcher.descriptorDimension,
            'keypoint_count': result.keypointCount,
            'reference_image_id': panoramaFrames.first.id,
            'matching_method': 'BFMatcher kNN + Lowe ratio, matched between '
                'every image pair (order-independent)',
            'ratio_test_threshold': PanoramaStitcher.ratioThreshold,
            'total_matches': result.totalMatches,
            'good_matches': result.goodMatches,
            'geometric_model': 'homography (RANSAC)',
            'ransac_threshold': PanoramaStitcher.ransacThreshold,
            'inlier_count': result.inlierCount,
            'inlier_ratio': result.inlierRatio,
            // Every image placed in the panorama is backed by a validated
            // homography - there is no non-visual fallback - so this is
            // always true for a panorama that reached 'completed'.
            'homography_valid': true,
          },
          createdAt: DateTime.now(),
        ),
      );
      // Only images with real, verified overlap end up in the panorama; any
      // others are marked separately rather than silently left as-is.
      final droppedIds = result.droppedImages
          .map((oneBased) => panoramaFrames[oneBased - 1].id)
          .toSet();
      await _setPanoramaStatus(
        'completed',
        onlyIds: panoramaFrames.map((f) => f.id).toSet().difference(droppedIds),
      );
      if (droppedIds.isNotEmpty) {
        await _setPanoramaStatus('excluded_no_overlap', onlyIds: droppedIds);
      }
      panoramaFrames.clear();
      panoramaId = null;
      unawaited(SyncService().syncPending());
      if (mounted) {
        setState(
          () => status =
              'Panorama saved: $id.jpg (${result.width}x${result.height}) '
              'from ${result.usedImageCount} of $_panoramaShots images'
              '${droppedIds.isEmpty ? '' : ' (${droppedIds.length} shared no overlap and were left out)'}',
        );
      }
    } on PanoramaStitchException catch (error) {
      await _setPanoramaStatus('failed');
      if (mounted) {
        setState(
          () => status = 'Stitching failed. Press capture to retry stitching.',
        );
        await showValidation([
          ValidationItem(
            'Panorama stitching',
            false,
            '$error. Your $_panoramaShots images are kept; press capture to retry.',
          ),
        ]);
      }
    } catch (error) {
      await _setPanoramaStatus('failed');
      if (mounted) setState(() => status = 'Stitching failed: $error');
    } finally {
      if (await output.exists()) await output.delete();
      if (mounted) setState(() => busy = false);
    }
  }

  /// Updates panorama_status on the stored source frames (fresh DB rows, so
  /// sync state written meanwhile is preserved). Defaults to every frame in
  /// the current panorama; pass [onlyIds] to update just a subset (e.g. the
  /// images actually placed vs. the ones dropped for lacking overlap).
  Future<void> _setPanoramaStatus(String value, {Set<String>? onlyIds}) async {
    final ids = onlyIds ?? panoramaFrames.map((f) => f.id).toSet();
    final rows = await LocalDatabase.instance.captures(widget.session.id);
    for (final row in rows.where((r) => ids.contains(r.id))) {
      await LocalDatabase.instance.updateCaptureSync(
        CaptureRecord(
          id: row.id,
          sessionId: row.sessionId,
          filename: row.filename,
          imagePath: row.imagePath,
          metadata: {...row.metadata, 'panorama_status': value},
          createdAt: row.createdAt,
          syncState: row.syncState,
          syncAttemptCount: row.syncAttemptCount,
          lastSyncAttempt: row.lastSyncAttempt,
          lastSyncError: row.lastSyncError,
          serverImageId: row.serverImageId,
          uploadedAt: row.uploadedAt,
        ),
      );
    }
  }

  Future<void> _changeDirection(String value) async {
    if (direction == panoramaDirection && panoramaFrames.isNotEmpty) {
      await _setPanoramaStatus('incomplete');
    }
    panoramaFrames.clear();
    panoramaId = null;
    if (mounted) setState(() => direction = value);
  }

  Future<void> showValidation(
    List<ValidationItem> invalid,
  ) => showModalBottomSheet<void>(
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
          const Text(
            'This image is not in the dataset. Fix the items below and recapture.',
          ),
          ...invalid.map(
            (item) => ListTile(
              leading: const Icon(Icons.error_outline, color: Colors.orange),
              title: Text(item.label),
              subtitle: Text(item.detail),
            ),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.refresh),
            label: const Text('Recapture / try another angle'),
          ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final ready = camera?.value.isInitialized == true;
    final preview = ready
        ? CameraPreview(camera!)
        : Container(
            color: const Color(0xff142422),
            child: Center(
              child: Text(status, style: const TextStyle(color: Colors.white)),
            ),
          );
    return Scaffold(
      appBar: AppBar(title: Text(widget.session.name)),
      body: Column(
        children: [
          Expanded(child: preview),
          _controls(),
        ],
      ),
    );
  }

  Widget _controls() => Container(
    color: const Color(0xff142422),
    padding: const EdgeInsets.all(14),
    child: SingleChildScrollView(
      child: Column(
        children: [
          _sensorBar(),
          if (direction == panoramaDirection) _panoramaGuide(),
          const SizedBox(height: 10),
          Row(
            children: [
              _menu(direction, [
                'Front',
                'Right',
                'Back',
                'Left',
                'Custom',
                panoramaDirection,
              ], _changeDirection, enabled: !busy),
              const SizedBox(width: 8),
              _menu(
                node,
                sampleNodes.map((item) => item['node'] as String).toList(),
                (value) => setState(() => node = value),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _groundTruthSection(),
          const SizedBox(height: 10),
          Row(
            children: [
              _menu(split, [
                'reference',
                'query',
                'test',
              ], (value) => setState(() => split = value)),
              const Spacer(),
              FloatingActionButton(
                onPressed: capture,
                child: busy
                    ? const CircularProgressIndicator()
                    : const Icon(Icons.camera_alt),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  Widget _panoramaGuide() {
    final done = panoramaFrames.length >= _panoramaShots;
    final target = panoramaFrames.length * _panoramaStepDegrees;
    final now = heading == null || panoramaFrames.isEmpty
        ? '--'
        : '${_relativeHeading().toStringAsFixed(0)}°';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        done
            ? 'Panorama: press capture to retry stitching'
            : 'Panorama ${panoramaFrames.length + 1}/$_panoramaShots — '
                  'face $target° (now $now)',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _groundTruthSection() => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'GROUND TRUTH',
          style: TextStyle(
            color: Colors.white60,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _groundTruthDropdown(
                label: 'Ground Truth Campus',
                value: groundTruthCampus,
                options: groundTruthCampusOptions,
                onChanged: (value) =>
                    setState(() => groundTruthCampus = value!),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _groundTruthDropdown(
                label: 'Ground Truth Building',
                value: groundTruthBuilding,
                hint: 'Select Building',
                options: groundTruthBuildingOptions,
                onChanged: (value) =>
                    setState(() => groundTruthBuilding = value),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _groundTruthDropdown(
                label: 'Ground Truth Floor',
                value: groundTruthFloor,
                hint: 'Select Floor',
                options: groundTruthFloorOptions,
                onChanged: (value) => setState(() => groundTruthFloor = value),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: groundTruthNodeNameController,
          style: const TextStyle(color: Colors.black),
          decoration: const InputDecoration(
            filled: true,
            fillColor: Colors.white,
            labelText: 'Ground Truth Node Name',
            hintText: 'Enter node/location name',
          ),
        ),
      ],
    ),
  );
  Widget _groundTruthDropdown({
    required String label,
    required String? value,
    required List<String> options,
    required ValueChanged<String?> onChanged,
    String? hint,
  }) => DropdownButtonFormField<String>(
    initialValue: value,
    decoration: InputDecoration(
      filled: true,
      fillColor: Colors.white,
      labelText: label,
      hintText: hint,
    ),
    items: options
        .map((option) => DropdownMenuItem(value: option, child: Text(option)))
        .toList(),
    onChanged: onChanged,
  );
  Widget _sensorBar() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      _metric(
        'GPS',
        position == null ? '--' : '${position!.accuracy.toStringAsFixed(1)} m',
      ),
      _metric(
        'HEADING',
        heading == null ? '--' : '${heading!.toStringAsFixed(0)}°',
      ),
      _metric('PITCH', pitch == null ? '--' : pitch!.toStringAsFixed(1)),
      _metric('ROLL', roll == null ? '--' : roll!.toStringAsFixed(1)),
    ],
  );
  Widget _metric(String label, String value) => Column(
    children: [
      Text(label, style: const TextStyle(color: Colors.white60, fontSize: 10)),
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    ],
  );
  Widget _menu(
    String value,
    List<String> values,
    ValueChanged<String> onChanged, {
    bool enabled = true,
  }) => Expanded(
    child: DropdownButtonFormField<String>(
      initialValue: value,
      decoration: const InputDecoration(
        filled: true,
        fillColor: Colors.white,
        labelText: 'Direction / selection',
      ),
      items: values
          .map((value) => DropdownMenuItem(value: value, child: Text(value)))
          .toList(),
      onChanged: enabled
          ? (value) {
              if (value != null) onChanged(value);
            }
          : null,
    ),
  );
}

class SessionGallery extends StatelessWidget {
  const SessionGallery({super.key, required this.sessionId});
  final String sessionId;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Session gallery')),
    body: FutureBuilder<List<CaptureRecord>>(
      future: LocalDatabase.instance.captures(sessionId),
      builder: (context, snapshot) {
        final rows = snapshot.data ?? [];
        if (rows.isEmpty) {
          return const Center(child: Text('No accepted captures yet.'));
        }
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: rows.length,
          itemBuilder: (_, index) =>
              Image.file(File(rows[index].imagePath), fit: BoxFit.cover),
        );
      },
    ),
  );
}

class ExportPage extends StatefulWidget {
  const ExportPage({super.key});
  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  bool busy = false;
  String? message;
  Future<void> export() async {
    setState(() => busy = true);
    try {
      final file = await StorageService().exportDataset();
      await StorageService().shareExport(file);
      message = 'ZIP created locally and opened in the share sheet.';
    } catch (error) {
      message = 'Export failed: $error';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        'Export dataset',
        style: Theme.of(
          context,
        ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 8),
      const Text('Everything stays on this phone until you explicitly export.'),
      const SizedBox(height: 24),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.inventory_2_outlined,
                size: 34,
                color: Color(0xff0b6e69),
              ),
              const SizedBox(height: 12),
              const Text(
                'ZIP contents',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
              ),
              const SizedBox(height: 8),
              const Text(
                'images/ • metadata.csv • metadata.json\nsessions.json • nodes.json • README.txt',
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: busy ? null : export,
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(),
                      )
                    : const Icon(Icons.ios_share),
                label: const Text('Create and share ZIP'),
              ),
            ],
          ),
        ),
      ),
      if (message != null)
        Padding(padding: const EdgeInsets.only(top: 16), child: Text(message!)),
    ],
  );
}
