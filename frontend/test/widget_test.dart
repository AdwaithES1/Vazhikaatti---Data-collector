// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vazhikatti_dataset_collector/data/models/capture_metadata.dart';
import 'package:vazhikatti_dataset_collector/data/models/ground_truth_options.dart';
import 'package:vazhikatti_dataset_collector/data/models/legacy_models.dart';
import 'package:vazhikatti_dataset_collector/services/validation/metadata_validator.dart';
import 'package:vazhikatti_dataset_collector/services/capture/gyro_sweep_tracker.dart';
import 'package:vazhikatti_dataset_collector/services/capture/gyro_sweep_page.dart';
import 'package:vazhikatti_dataset_collector/services/capture/manual_capture_page.dart';

Map<String, dynamic> _completeMetadata() => {
  'image_path': '/tmp/a.jpg',
  'session_name': 'Morning sweep',
  'latitude': 12.1,
  'longitude': 77.1,
  'gps_accuracy': 8.0,
  'heading': 90.0,
  'pitch': 1.0,
  'roll': 2.0,
  'building_name': 'Engineering Block',
  'floor_number': 'Ground Floor',
  'node_id': 'EB-N-G-001',
  'view_direction': 'Front',
  'dataset_split': 'reference',
  'ground_truth_campus': 'IIIT K',
  'ground_truth_building': 'New Academic Block',
  'ground_truth_floor': 'Ground',
  'ground_truth_node_name': 'Main Entrance',
};

void main() {
  testWidgets('capture mode selector offers gyro and manual modes', (
    tester,
  ) async {
    final session = CaptureSession(
      id: 'session-1',
      name: 'Test session',
      createdAt: DateTime(2026, 9, 20),
    );
    await tester.pumpWidget(
      MaterialApp(home: CaptureModePage(session: session)),
    );

    expect(find.text('Select Capture Mode'), findsWidgets);
    expect(find.text('Gyro Triggered'), findsOneWidget);
    expect(find.text('Manual'), findsOneWidget);
  });

  test(
    'wide-angle selector chooses a rear wide camera, not the main rear camera',
    () async {
      final selected = await selectWideAngleRearCamera([
        const CameraDescription(
          name: '0',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        const CameraDescription(
          name: 'back-ultra-wide',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        const CameraDescription(
          name: 'front-wide',
          lensDirection: CameraLensDirection.front,
          sensorOrientation: 270,
        ),
      ]);

      expect(selected.name, 'back-ultra-wide');
    },
  );

  test(
    'wide-angle selector throws error when rear wide camera is absent',
    () async {
      expect(
        () => selectWideAngleRearCamera([
          const CameraDescription(
            name: '0',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          const CameraDescription(
            name: '1',
            lensDirection: CameraLensDirection.front,
            sensorOrientation: 270,
          ),
        ]),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'wide-angle selector identifies Galaxy S23 Ultra ultra-wide camera (ID 2) using Camera2 metadata',
    () {
      final cameras = [
        const CameraDescription(
          name: '0',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        const CameraDescription(
          name: '1',
          lensDirection: CameraLensDirection.front,
          sensorOrientation: 270,
        ),
        const CameraDescription(
          name: '2',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        const CameraDescription(
          name: '3',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        const CameraDescription(
          name: '4',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
      ];

      // Simulated Camera2 characteristics for Samsung Galaxy S23 Ultra
      final metadata = {
        '0': const CameraPlatformCharacteristics(
          cameraId: '0',
          lensFacing: 'back',
          focalLengths: [6.3],
          focalLength35mm: 22.7,
          horizontalFov: 74.6,
          diagonalFov: 87.2,
          sensorPhysicalWidth: 9.6,
          sensorPhysicalHeight: 7.2,
          isLogicalMultiCamera: true,
          physicalCameraIds: ['2', '3', '4'],
        ),
        '1': const CameraPlatformCharacteristics(
          cameraId: '1',
          lensFacing: 'front',
          focalLengths: [3.8],
          focalLength35mm: 25.0,
        ),
        '2': const CameraPlatformCharacteristics(
          cameraId: '2',
          lensFacing: 'back',
          focalLengths: [2.2], // 13mm equiv ultra-wide
          focalLength35mm: 13.5,
          horizontalFov: 104.1,
          diagonalFov: 116.3,
          sensorPhysicalWidth: 5.64,
          sensorPhysicalHeight: 4.23,
        ),
        '3': const CameraPlatformCharacteristics(
          cameraId: '3',
          lensFacing: 'back',
          focalLengths: [11.1], // 3x telephoto
          focalLength35mm: 70.0,
          horizontalFov: 17.9,
          diagonalFov: 22.2,
        ),
        '4': const CameraPlatformCharacteristics(
          cameraId: '4',
          lensFacing: 'back',
          focalLengths: [27.2], // 10x telephoto
          focalLength35mm: 230.0,
        ),
      };

      final selected = selectWideAngleRearCameraSync(
        cameras,
        platformMetadata: metadata,
      );

      // Must select Camera 2 (ultra-wide), NOT 0 (main 1x), NOT 3 or 4 (telephoto)
      expect(selected.name, '2');
    },
  );

  test(
    'wide-angle selector chooses shortest focal length / widest FOV when multiple qualify',
    () {
      final cameras = [
        const CameraDescription(
          name: '2',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        const CameraDescription(
          name: '5',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
      ];

      final metadata = {
        '2': const CameraPlatformCharacteristics(
          cameraId: '2',
          lensFacing: 'back',
          focalLengths: [2.2],
          focalLength35mm: 14.0,
          diagonalFov: 115.0,
        ),
        '5': const CameraPlatformCharacteristics(
          cameraId: '5',
          lensFacing: 'back',
          focalLengths: [1.8], // Wider than 2.2mm
          focalLength35mm: 12.0,
          diagonalFov: 125.0,
        ),
      };

      final selected = selectWideAngleRearCameraSync(
        cameras,
        platformMetadata: metadata,
      );

      expect(selected.name, '5');
    },
  );

  test(
    'wide-angle selector exposes diagnostic camera information in error when no camera qualifies',
    () {
      final cameras = [
        const CameraDescription(
          name: '0',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        const CameraDescription(
          name: '3',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
      ];

      final metadata = {
        '0': const CameraPlatformCharacteristics(
          cameraId: '0',
          lensFacing: 'back',
          focalLengths: [6.3],
          focalLength35mm: 23.0,
        ),
        '3': const CameraPlatformCharacteristics(
          cameraId: '3',
          lensFacing: 'back',
          focalLengths: [11.1],
          focalLength35mm: 70.0,
        ),
      };

      expect(
        () =>
            selectWideAngleRearCameraSync(cameras, platformMetadata: metadata),
        throwsA(
          predicate(
            (e) =>
                e is StateError &&
                e.message.contains('No rear ultra-wide camera identified') &&
                e.message.contains('Camera ID "0"') &&
                e.message.contains('6.3mm'),
          ),
        ),
      );
    },
  );

  test('manual panorama frames can continue across multiple groups', () {
    final fields = [
      for (var frameIndex = 0; frameIndex < 12; frameIndex++)
        manualPanoramaFields(
          frameIndex < 8 ? 'panorama-1' : 'panorama-2',
          frameIndex % 8,
        ),
    ];

    expect(fields.take(8).map((item) => item['frame_index']), [
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
    ]);
    expect(fields.skip(8).map((item) => item['frame_index']), [0, 1, 2, 3]);
    expect(fields.take(8).map((item) => item['panorama_id']).toSet(), {
      'panorama-1',
    });
    expect(fields.skip(8).map((item) => item['panorama_id']).toSet(), {
      'panorama-2',
    });
    expect(fields.map((item) => item['is_panorama_source']).toSet(), {true});
    expect(fields.map((item) => item['panorama_status']).toSet(), {
      'completed',
    });
  });

  group('gyro sweep tracking', () {
    test('normalizes movement across the 0/360 boundary', () {
      final tracker = GyroSweepTracker(initialHeading: 358);

      tracker.update(2);

      expect(tracker.cumulativeRotation, 4);
      expect(tracker.direction, 'Clockwise');
    });

    test('triggers each interval once and ignores reversal duplicates', () {
      final tracker = GyroSweepTracker(initialHeading: 0);

      expect(tracker.update(45).triggerInterval, 1);
      expect(tracker.update(90).triggerInterval, 2);
      expect(tracker.update(45).triggerInterval, isNull);
      expect(tracker.update(90).triggerInterval, isNull);
      expect(tracker.capturedIntervals, containsAll([1, 2]));
    });

    test('flags a movement gap larger than 1.5 intervals', () {
      final tracker = GyroSweepTracker(initialHeading: 0);

      expect(tracker.update(70).tooFast, isTrue);
    });
  });

  test('validation blocks incomplete metadata', () {
    expect(MetadataValidator.isReady({'image_path': '/tmp/a.jpg'}), isFalse);
  });

  test('validation accepts complete metadata', () {
    expect(MetadataValidator.isReady(_completeMetadata()), isTrue);
  });

  test('canonical metadata round trips and preserves unknown legacy keys', () {
    final original = CaptureMetadata.fromJson({
      'image_id': 'image-1',
      'ISO': 200,
      'view_direction': 'Front',
      'legacy_key': 'retained',
    });
    final restored = CaptureMetadata.fromJson(original.toJson());
    expect(restored.toJson()['image_id'], 'image-1');
    expect(restored.toJson()['ISO'], 200);
    expect(restored.toJson()['legacy_key'], 'retained');
  });

  test('sweep and ground-truth coordinate metadata round trips', () {
    final metadata = CaptureMetadata.fromJson({
      'image_path': '/tmp/sweep.jpg',
      'session_name': 'Atrium sweep',
      'sweep_id': 'sweep-1',
      'sweep_index': 0,
      'heading_at_capture': 358.5,
      'sweep_trigger_interval_degrees': 45.0,
      'sweep_direction': 'Clockwise',
      'sweep_total_rotation_degrees': 45.0,
      'ground_truth_local_x': -12.25,
      'ground_truth_local_y': 4.5,
      'ground_truth_local_z': 1.75,
    }).toJson();
    expect(metadata['session_name'], 'Atrium sweep');
    expect(metadata['sweep_index'], 0);
    expect(metadata['heading_at_capture'], 358.5);
    expect(metadata['ground_truth_local_x'], -12.25);
    expect(metadata['ground_truth_local_y'], 4.5);
    expect(metadata['ground_truth_local_z'], 1.75);
  });

  test('session model persists session_name', () {
    final session = CaptureSession(
      id: 'session-1',
      name: 'North wing',
      createdAt: DateTime(2026, 9, 20),
    );
    final restored = CaptureSession.fromMap(session.toMap());
    expect(restored.name, 'North wing');
    expect(session.toMap()['session_name'], 'North wing');
  });

  test('session summaries are newest first and limited to ten', () {
    final summaries = [
      for (var index = 0; index < 12; index++)
        SessionSummary(
          session: CaptureSession(
            id: 'session-$index',
            name: 'Session $index',
            createdAt: DateTime(2026, 1, 1).add(Duration(days: index)),
          ),
          imageCount: index,
          sweepCount: index == 0 ? 0 : 1,
        ),
    ];
    final latest = SessionSummary.latestTen(summaries);

    expect(latest, hasLength(10));
    expect(latest.first.session.name, 'Session 11');
    expect(latest.last.session.name, 'Session 2');
    expect(latest.first.imageCount, 11);
    expect(latest.first.sweepCount, 1);
  });

  test(
    'session export preserves complete metadata and sweep relationships',
    () {
      final metadata = CaptureMetadata.fromJson({
        'capture_session_id': 'session-1',
        'session_name': 'Session 1',
        'image_id': 'image-1',
        'filename': 'image-1.jpg',
        'sweep_id': 'sweep-1',
        'sweep_index': 0,
        'heading_at_capture': 90.0,
        'sweep_total_rotation_degrees': 45.0,
        'ground_truth_local_x': -1.5,
        'ground_truth_local_y': 2.25,
        'ground_truth_local_z': 0.0,
      }).toJson();

      expect(metadata['capture_session_id'], 'session-1');
      expect(metadata['sweep_id'], 'sweep-1');
      expect(metadata['sweep_index'], 0);
      expect(metadata['ground_truth_local_x'], -1.5);
      expect(CaptureMetadata.fields, contains('heading_at_capture'));
      expect(CaptureMetadata.fields, contains('sweep_direction'));
    },
  );

  test('capture persistence map contains sweep and coordinate columns', () {
    final record = CaptureRecord(
      id: 'image-1',
      sessionId: 'session-1',
      filename: 'image-1.jpg',
      imagePath: '/tmp/image-1.jpg',
      metadata: {
        'session_name': 'North wing',
        'sweep_id': 'sweep-1',
        'sweep_index': 0,
        'heading_at_capture': 45.0,
        'sweep_trigger_interval_degrees': 45.0,
        'sweep_direction': 'Clockwise',
        'sweep_total_rotation_degrees': 45.0,
        'ground_truth_local_x': -1.25,
        'ground_truth_local_y': 3.5,
        'ground_truth_local_z': -2.5,
      },
      createdAt: DateTime(2026, 9, 20),
    );
    final row = record.toMap();
    expect(row['session_name'], 'North wing');
    expect(row['sweep_id'], 'sweep-1');
    expect(row['sweep_index'], 0);
    expect(row['ground_truth_local_x'], -1.25);
    expect(row['ground_truth_local_y'], 3.5);
    expect(row['ground_truth_local_z'], -2.5);
  });

  group('ground truth dropdown options', () {
    test('campus has exactly one canonical value', () {
      expect(groundTruthCampusOptions, ['IIIT K']);
      expect(defaultGroundTruthCampus, 'IIIT K');
    });

    test('building options match the canonical list exactly', () {
      expect(groundTruthBuildingOptions, [
        'Old Academic Block',
        'New Academic Block',
        'Admin Block',
        'General Pathway',
      ]);
    });

    test('floor options match the canonical list exactly', () {
      expect(groundTruthFloorOptions, ['Basement', 'Ground', '1', '2']);
    });
  });

  group('ground truth validation', () {
    test('missing campus fails validation', () {
      final data = _completeMetadata()..remove('ground_truth_campus');
      expect(MetadataValidator.isReady(data), isFalse);
    });

    test('missing building fails validation', () {
      final data = _completeMetadata()..['ground_truth_building'] = null;
      expect(MetadataValidator.isReady(data), isFalse);
    });

    test('missing floor fails validation', () {
      final data = _completeMetadata()..['ground_truth_floor'] = null;
      expect(MetadataValidator.isReady(data), isFalse);
    });

    test('empty node name fails validation', () {
      final data = _completeMetadata()..['ground_truth_node_name'] = '';
      expect(MetadataValidator.isReady(data), isFalse);
    });

    test('whitespace-only node name fails validation', () {
      final data = _completeMetadata()..['ground_truth_node_name'] = '   ';
      expect(MetadataValidator.isReady(data), isFalse);
    });
  });

  test('ground truth fields survive export field list and JSON round trip', () {
    expect(CaptureMetadata.fields, contains('ground_truth_campus'));
    expect(CaptureMetadata.fields, contains('ground_truth_building'));
    expect(CaptureMetadata.fields, contains('ground_truth_floor'));
    expect(CaptureMetadata.fields, contains('ground_truth_node_name'));
    expect(CaptureMetadata.fields, contains('ground_truth_local_x'));
    expect(CaptureMetadata.fields, contains('ground_truth_local_y'));
    expect(CaptureMetadata.fields, contains('ground_truth_local_z'));
    expect(CaptureMetadata.fields, contains('sweep_total_rotation_degrees'));

    final metadata = CaptureMetadata.fromJson({
      'image_id': 'image-2',
      'ground_truth_campus': 'IIIT K',
      'ground_truth_building': 'Admin Block',
      'ground_truth_floor': '1',
      'ground_truth_node_name': 'Staircase',
    }).toJson();

    expect(metadata['ground_truth_campus'], 'IIIT K');
    expect(metadata['ground_truth_building'], 'Admin Block');
    expect(metadata['ground_truth_floor'], '1');
    expect(metadata['ground_truth_node_name'], 'Staircase');
  });
}
