import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform-level camera characteristics retrieved via Camera2 on Android.
class CameraPlatformCharacteristics {
  final String cameraId;
  final String lensFacing; // 'back', 'front', 'external', 'unknown'
  final int? sensorOrientation;
  final List<double> focalLengths;
  final double? sensorPhysicalWidth;
  final double? sensorPhysicalHeight;
  final int? pixelArrayWidth;
  final int? pixelArrayHeight;
  final List<double> apertures;
  final double? minimumFocusDistance;
  final String hardwareLevel;
  final bool isLogicalMultiCamera;
  final List<String> physicalCameraIds;
  final double? horizontalFov;
  final double? diagonalFov;
  final double? focalLength35mm;

  const CameraPlatformCharacteristics({
    required this.cameraId,
    required this.lensFacing,
    this.sensorOrientation,
    this.focalLengths = const [],
    this.sensorPhysicalWidth,
    this.sensorPhysicalHeight,
    this.pixelArrayWidth,
    this.pixelArrayHeight,
    this.apertures = const [],
    this.minimumFocusDistance,
    this.hardwareLevel = 'UNKNOWN',
    this.isLogicalMultiCamera = false,
    this.physicalCameraIds = const [],
    this.horizontalFov,
    this.diagonalFov,
    this.focalLength35mm,
  });

  factory CameraPlatformCharacteristics.fromMap(Map<String, dynamic> map) {
    final rawFocals = map['focalLengths'];
    final List<double> focals = [];
    if (rawFocals is List) {
      for (final f in rawFocals) {
        if (f is num) focals.add(f.toDouble());
      }
    }

    final rawPhysicalIds = map['physicalCameraIds'];
    final List<String> physicalIds = [];
    if (rawPhysicalIds is List) {
      for (final id in rawPhysicalIds) {
        if (id != null) physicalIds.add(id.toString());
      }
    }

    final rawApertures = map['apertures'];
    final List<double> aps = [];
    if (rawApertures is List) {
      for (final a in rawApertures) {
        if (a is num) aps.add(a.toDouble());
      }
    }

    return CameraPlatformCharacteristics(
      cameraId: map['cameraId']?.toString() ?? '',
      lensFacing: map['lensFacing']?.toString() ?? 'unknown',
      sensorOrientation: map['sensorOrientation'] as int?,
      focalLengths: focals,
      sensorPhysicalWidth: (map['sensorPhysicalWidth'] as num?)?.toDouble(),
      sensorPhysicalHeight: (map['sensorPhysicalHeight'] as num?)?.toDouble(),
      pixelArrayWidth: map['pixelArrayWidth'] as int?,
      pixelArrayHeight: map['pixelArrayHeight'] as int?,
      apertures: aps,
      minimumFocusDistance: (map['minimumFocusDistance'] as num?)?.toDouble(),
      hardwareLevel: map['hardwareLevel']?.toString() ?? 'UNKNOWN',
      isLogicalMultiCamera: map['isLogicalMultiCamera'] as bool? ?? false,
      physicalCameraIds: physicalIds,
      horizontalFov: (map['horizontalFov'] as num?)?.toDouble(),
      diagonalFov: (map['diagonalFov'] as num?)?.toDouble(),
      focalLength35mm: (map['focalLength35mm'] as num?)?.toDouble(),
    );
  }

  double? get minFocalLength {
    if (focalLengths.isEmpty) return null;
    return focalLengths.reduce((a, b) => a < b ? a : b);
  }

  bool get isBackFacing => lensFacing.toLowerCase() == 'back';

  /// Evaluates whether this camera has verifiable ultra-wide optical characteristics.
  /// Smartphone ultra-wide lenses typically feature:
  /// - Physical focal length <= 3.5mm (e.g. Galaxy S23 Ultra is 2.2mm, iPhone/Pixel ~1.8-2.2mm)
  /// - 35mm equivalent focal length <= 20mm (e.g. S23 Ultra is 13mm)
  /// - Diagonal FOV >= 95° or Horizontal FOV >= 85° (e.g. S23 Ultra is ~120° diagonal)
  bool get isVerifiableUltraWide {
    if (!isBackFacing) return false;

    // Check 35mm equivalent focal length if available
    if (focalLength35mm != null && focalLength35mm! > 0) {
      if (focalLength35mm! <= 20.0) return true;
      if (focalLength35mm! >= 22.0) return false; // Main (23-28mm) or Telephoto (>=50mm)
    }

    // Check FOV if available
    if (diagonalFov != null && diagonalFov! >= 95.0) return true;
    if (horizontalFov != null && horizontalFov! >= 85.0) return true;

    // Check physical focal length (smartphone ultra-wide lenses universally have focal length <= 3.5mm)
    final focal = minFocalLength;
    if (focal != null && focal > 0) {
      if (focal <= 3.5) return true;
    }

    return false;
  }

  /// Identifies if this is the primary 1x main rear camera (which must NOT be selected)
  bool get isPrimaryMainCamera {
    if (!isBackFacing) return false;
    if (focalLength35mm != null && focalLength35mm! >= 22.0 && focalLength35mm! <= 35.0) {
      return true;
    }
    final focal = minFocalLength;
    if (focal != null && focal >= 4.5 && focal <= 7.5) {
      return true;
    }
    if (diagonalFov != null && diagonalFov! >= 68.0 && diagonalFov! < 95.0) {
      return true;
    }
    return false;
  }

  /// Identifies if this is a telephoto camera (which must NOT be selected)
  bool get isTelephotoCamera {
    if (!isBackFacing) return false;
    if (focalLength35mm != null && focalLength35mm! >= 45.0) {
      return true;
    }
    final focal = minFocalLength;
    if (focal != null && focal >= 8.0) {
      return true;
    }
    if (diagonalFov != null && diagonalFov! < 65.0) {
      return true;
    }
    return false;
  }
}

/// Service to query Android Camera2 platform characteristics via MethodChannel.
class CameraPlatformService {
  const CameraPlatformService();
  static const CameraPlatformService instance = CameraPlatformService();

  static const MethodChannel _channel = MethodChannel(
    'com.vazhikatti.vazhikatti_dataset_collector/camera_info',
  );

  /// Fetches Camera2 characteristics for all available cameras on Android.
  Future<Map<String, CameraPlatformCharacteristics>> getCharacteristics() async {
    if (!Platform.isAndroid) {
      return {};
    }
    try {
      final List<dynamic>? rawList = await _channel.invokeMethod<List<dynamic>>(
        'getCameraCharacteristicsList',
      );
      if (rawList == null) return {};

      final map = <String, CameraPlatformCharacteristics>{};
      for (final item in rawList) {
        if (item is Map) {
          final chars = CameraPlatformCharacteristics.fromMap(
            Map<String, dynamic>.from(item),
          );
          map[chars.cameraId] = chars;
        }
      }
      return map;
    } catch (e) {
      debugPrint('[CameraDiscovery] Platform channel call failed: $e');
      return {};
    }
  }
}

class _QualifiedCamera {
  final CameraDescription camera;
  final CameraPlatformCharacteristics? characteristics;
  final int score; // 0 = verified Camera2 ultra-wide, 1 = name ultra/0.5, 2 = name wide
  final double focalLength;
  final double fov;
  final String reason;

  _QualifiedCamera({
    required this.camera,
    this.characteristics,
    required this.score,
    required this.focalLength,
    required this.fov,
    required this.reason,
  });
}

/// Temporary debug logging showing, for every available camera:
/// - camera identifier/name
/// - lens direction
/// - sensor orientation
/// - available focal length(s), if available
/// - relevant Android Camera2 characteristics
void _logCameraDiscovery(
  List<CameraDescription> cameras,
  Map<String, CameraPlatformCharacteristics> meta,
) {
  debugPrint('================================================================');
  debugPrint('[CameraDiscovery] Inspecting Available Cameras (${cameras.length} found):');
  for (final camera in cameras) {
    final chars = meta[camera.name];
    debugPrint('----------------------------------------------------------------');
    debugPrint('  Camera Identifier / Name: ${camera.name}');
    debugPrint('  Lens Direction:          ${camera.lensDirection}');
    debugPrint('  Sensor Orientation:      ${camera.sensorOrientation}°');
    if (chars != null) {
      debugPrint('  Android Camera2 Characteristics:');
      debugPrint('    Lens Facing:             ${chars.lensFacing}');
      debugPrint('    Sensor Orientation:      ${chars.sensorOrientation}°');
      debugPrint('    Available Focal Lengths: ${chars.focalLengths.map((f) => '${f.toStringAsFixed(2)}mm').toList()}');
      if (chars.focalLength35mm != null) {
        debugPrint('    35mm Equivalent Focal:   ${chars.focalLength35mm!.toStringAsFixed(1)}mm');
      }
      if (chars.horizontalFov != null && chars.diagonalFov != null) {
        debugPrint('    Calculated FOV:          Horizontal: ${chars.horizontalFov!.toStringAsFixed(1)}°, Diagonal: ${chars.diagonalFov!.toStringAsFixed(1)}°');
      }
      if (chars.sensorPhysicalWidth != null && chars.sensorPhysicalHeight != null) {
        debugPrint('    Sensor Physical Size:    ${chars.sensorPhysicalWidth} x ${chars.sensorPhysicalHeight} mm');
      }
      if (chars.pixelArrayWidth != null && chars.pixelArrayHeight != null) {
        debugPrint('    Pixel Array Size:        ${chars.pixelArrayWidth} x ${chars.pixelArrayHeight}');
      }
      debugPrint('    Hardware Level:          ${chars.hardwareLevel}');
      debugPrint('    Logical Multi-Camera:    ${chars.isLogicalMultiCamera}');
      if (chars.physicalCameraIds.isNotEmpty) {
        debugPrint('    Physical Camera IDs:     ${chars.physicalCameraIds}');
      }
      if (chars.apertures.isNotEmpty) {
        debugPrint('    Available Apertures:     ${chars.apertures}');
      }
      if (chars.minimumFocusDistance != null) {
        debugPrint('    Min Focus Distance:      ${chars.minimumFocusDistance}');
      }
      if (chars.isVerifiableUltraWide) {
        debugPrint('    Classification:          ULTRA-WIDE (Qualifies)');
      } else if (chars.isPrimaryMainCamera) {
        debugPrint('    Classification:          PRIMARY MAIN 1x (Excluded)');
      } else if (chars.isTelephotoCamera) {
        debugPrint('    Classification:          TELEPHOTO (Excluded)');
      } else {
        debugPrint('    Classification:          OTHER / UNKNOWN');
      }
    } else {
      debugPrint('  Android Camera2 Characteristics: None available for "${camera.name}"');
    }
  }

  // Also log any Camera2 cameras discovered on Android that are not in Flutter's list
  final unlistedIds = meta.keys.where(
    (id) => !cameras.any((c) => c.name == id),
  ).toList();
  if (unlistedIds.isNotEmpty) {
    debugPrint('----------------------------------------------------------------');
    debugPrint('  Additional Camera2 IDs detected on device not in Flutter list:');
    for (final id in unlistedIds) {
      final chars = meta[id]!;
      debugPrint('    Camera2 ID "$id": facing=${chars.lensFacing}, focalLengths=${chars.focalLengths}, 35mm=${chars.focalLength35mm?.toStringAsFixed(1)}mm');
    }
  }
  debugPrint('================================================================');
}

/// Synchronous camera selection using provided [platformMetadata] or name heuristics.
CameraDescription selectWideAngleRearCameraSync(
  List<CameraDescription> cameras, {
  Map<String, CameraPlatformCharacteristics>? platformMetadata,
  bool debugLog = true,
}) {
  final meta = platformMetadata ?? const {};

  if (debugLog) {
    _logCameraDiscovery(cameras, meta);
  }

  // Filter rear cameras
  final rearCameras = cameras.where((camera) {
    if (camera.lensDirection == CameraLensDirection.back) return true;
    final chars = meta[camera.name];
    if (chars != null && chars.isBackFacing) return true;
    return false;
  }).toList();

  if (rearCameras.isEmpty) {
    final reason = 'No rear-facing cameras found on device. Total available cameras: ${cameras.length}';
    if (debugLog) debugPrint('[CameraDiscovery] FAILED: $reason');
    throw StateError(reason);
  }

  // Priority 1: Check for verifiable ultra-wide characteristics using Camera2 metadata
  final qualifying = <_QualifiedCamera>[];

  for (final camera in rearCameras) {
    final chars = meta[camera.name];
    if (chars != null) {
      if (chars.isVerifiableUltraWide) {
        qualifying.add(_QualifiedCamera(
          camera: camera,
          characteristics: chars,
          score: 0,
          focalLength: chars.minFocalLength ?? 0.0,
          fov: chars.diagonalFov ?? chars.horizontalFov ?? 0.0,
          reason: 'Verifiable ultra-wide: focal=${chars.minFocalLength}mm, 35mm=${chars.focalLength35mm}mm, FOV=${chars.diagonalFov}°',
        ));
      } else if (chars.isPrimaryMainCamera) {
        if (debugLog) {
          debugPrint('[CameraDiscovery] Camera "${camera.name}" is PRIMARY 1x MAIN camera (focal=${chars.minFocalLength}mm, 35mm=${chars.focalLength35mm}mm) -> EXCLUDED');
        }
      } else if (chars.isTelephotoCamera) {
        if (debugLog) {
          debugPrint('[CameraDiscovery] Camera "${camera.name}" is TELEPHOTO camera (focal=${chars.minFocalLength}mm, 35mm=${chars.focalLength35mm}mm) -> EXCLUDED');
        }
      }
    }
  }

  // If no camera qualified via Camera2 metadata, check for name hints (e.g. in tests or iOS)
  if (qualifying.isEmpty) {
    for (final camera in rearCameras) {
      final name = camera.name.toLowerCase();
      final chars = meta[camera.name];

      // If Camera2 metadata explicitly identifies it as main or telephoto, exclude it
      if (chars != null && (chars.isPrimaryMainCamera || chars.isTelephotoCamera)) {
        continue;
      }

      if (name.contains('ultra') || name.contains('0.5') || name.contains('ultrawide')) {
        qualifying.add(_QualifiedCamera(
          camera: camera,
          characteristics: chars,
          score: 1,
          focalLength: chars?.minFocalLength ?? 1.0,
          fov: chars?.diagonalFov ?? 120.0,
          reason: 'Name indicates ultra-wide: "${camera.name}"',
        ));
      } else if (name.contains('wide')) {
        qualifying.add(_QualifiedCamera(
          camera: camera,
          characteristics: chars,
          score: 2,
          focalLength: chars?.minFocalLength ?? 2.0,
          fov: chars?.diagonalFov ?? 100.0,
          reason: 'Name contains wide: "${camera.name}"',
        ));
      }
    }
  }

  // Priority 2: If multiple rear cameras qualify, select the one with the shortest appropriate focal length / widest FOV
  if (qualifying.isNotEmpty) {
    qualifying.sort((a, b) {
      // First sort by score (metadata-verified=0, name ultra=1, name wide=2)
      final scoreCmp = a.score.compareTo(b.score);
      if (scoreCmp != 0) return scoreCmp;

      // Then sort by shortest focal length (if available and positive)
      if (a.focalLength > 0 && b.focalLength > 0) {
        final focalCmp = a.focalLength.compareTo(b.focalLength);
        if (focalCmp != 0) return focalCmp;
      }

      // Then sort by widest FOV
      if (a.fov > 0 && b.fov > 0) {
        final fovCmp = b.fov.compareTo(a.fov);
        if (fovCmp != 0) return fovCmp;
      }

      return 0;
    });

    final selected = qualifying.first;
    if (debugLog) {
      debugPrint('[CameraDiscovery] >>> SELECTED CAMERA: "${selected.camera.name}" (${selected.reason}) <<<');
    }
    return selected.camera;
  }

  // Priority 3: If the platform cannot determine which camera is ultra-wide,
  // do NOT falsely report "no wide angle camera" immediately without diagnostic info.
  // Expose the available camera information so the implementation can determine the correct physical camera.
  final diagnosticLines = <String>[];
  for (final camera in rearCameras) {
    final chars = meta[camera.name];
    if (chars != null) {
      final focalStr = chars.focalLengths.isNotEmpty
          ? chars.focalLengths.map((f) => '${f.toStringAsFixed(1)}mm').join(', ')
          : 'unknown';
      final equivStr = chars.focalLength35mm != null
          ? ' (35mm equiv: ${chars.focalLength35mm!.toStringAsFixed(1)}mm)'
          : '';
      final fovStr = chars.diagonalFov != null
          ? ', FOV: ${chars.diagonalFov!.toStringAsFixed(1)}°'
          : '';
      final typeStr = chars.isPrimaryMainCamera
          ? ' [Primary 1x Main]'
          : (chars.isTelephotoCamera ? ' [Telephoto]' : '');
      diagnosticLines.add('Camera ID "${camera.name}": focal=[$focalStr]$equivStr$fovStr$typeStr');
    } else {
      diagnosticLines.add('Camera ID "${camera.name}": lensDirection=${camera.lensDirection}, orientation=${camera.sensorOrientation}° (no Camera2 metadata)');
    }
  }

  final errorMsg =
      'No rear ultra-wide camera identified.\n'
      'Inspected rear cameras:\n  ${diagnosticLines.join('\n  ')}\n'
      'Requirement: Rear-facing ultra-wide camera (focal length <= 3.5mm, 35mm equiv <= 20mm, or FOV >= 95°). Main 1x and telephoto lenses are excluded.';

  if (debugLog) {
    debugPrint('[CameraDiscovery] FAILED: $errorMsg');
  }

  throw StateError(errorMsg);
}

/// Asynchronous camera selection. Queries Android Camera2 characteristics when on Android,
/// outputs full debug logging, and identifies the physical rear ultra-wide camera.
Future<CameraDescription> selectWideAngleRearCamera(
  List<CameraDescription> cameras, {
  CameraPlatformService? platformService,
  Map<String, CameraPlatformCharacteristics>? platformMetadata,
  bool debugLog = true,
}) async {
  final meta = platformMetadata ??
      await (platformService ?? CameraPlatformService.instance).getCharacteristics();
  return selectWideAngleRearCameraSync(
    cameras,
    platformMetadata: meta,
    debugLog: debugLog,
  );
}
