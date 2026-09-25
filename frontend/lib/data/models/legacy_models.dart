import 'dart:convert';

class CaptureSession {
  const CaptureSession({
    required this.id,
    required this.name,
    required this.createdAt,
    this.collectorId = 'local-collector',
    this.status = 'active',
  });
  final String id;
  final String name;
  final DateTime createdAt;
  final String collectorId;
  final String status;
  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'session_name': name,
    'created_at': createdAt.toIso8601String(),
    'collector_id': collectorId,
    'status': status,
  };
  factory CaptureSession.fromMap(Map<String, dynamic> map) => CaptureSession(
    id: map['id'] as String,
    name: map['session_name'] as String? ?? map['name'] as String,
    createdAt: DateTime.parse(map['created_at'] as String),
    collectorId: map['collector_id'] as String? ?? 'local-collector',
    status: map['status'] as String? ?? 'active',
  );
}

class SessionSummary {
  const SessionSummary({
    required this.session,
    required this.imageCount,
    required this.sweepCount,
    this.thumbnailPath,
  });

  final CaptureSession session;
  final int imageCount;
  final int sweepCount;
  final String? thumbnailPath;

  static List<SessionSummary> latestTen(Iterable<SessionSummary> values) =>
      (values.toList()..sort(
            (a, b) => b.session.createdAt.compareTo(a.session.createdAt),
          ))
          .take(10)
          .toList();
}

class CaptureRecord {
  CaptureRecord({
    required this.id,
    required this.sessionId,
    required this.filename,
    required this.imagePath,
    required this.metadata,
    required this.createdAt,
    this.syncState = 'pending',
    this.syncAttemptCount = 0,
    this.lastSyncAttempt,
    this.lastSyncError,
    this.serverImageId,
    this.uploadedAt,
  });
  final String id;
  final String sessionId;
  final String filename;
  final String imagePath;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;
  final String syncState;
  final int syncAttemptCount;
  final DateTime? lastSyncAttempt;
  final String? lastSyncError;
  final String? serverImageId;
  final DateTime? uploadedAt;
  CaptureRecord copyWith({
    String? syncState,
    int? syncAttemptCount,
    DateTime? lastSyncAttempt,
    String? lastSyncError,
    String? serverImageId,
    DateTime? uploadedAt,
  }) => CaptureRecord(
    id: id,
    sessionId: sessionId,
    filename: filename,
    imagePath: imagePath,
    metadata: metadata,
    createdAt: createdAt,
    syncState: syncState ?? this.syncState,
    syncAttemptCount: syncAttemptCount ?? this.syncAttemptCount,
    lastSyncAttempt: lastSyncAttempt ?? this.lastSyncAttempt,
    lastSyncError: lastSyncError ?? this.lastSyncError,
    serverImageId: serverImageId ?? this.serverImageId,
    uploadedAt: uploadedAt ?? this.uploadedAt,
  );
  Map<String, dynamic> toMap() => {
    'id': id,
    'session_id': sessionId,
    'filename': filename,
    'image_path': imagePath,
    'metadata_json': jsonEncode(metadata),
    'created_at': createdAt.toIso8601String(),
    'sync_state': syncState,
    'sync_attempt_count': syncAttemptCount,
    'last_sync_attempt': lastSyncAttempt?.toIso8601String(),
    'last_sync_error': lastSyncError,
    'server_image_id': serverImageId,
    'uploaded_at': uploadedAt?.toIso8601String(),
    'session_name': metadata['session_name'],
    'sweep_id': metadata['sweep_id'],
    'sweep_index': metadata['sweep_index'],
    'heading_at_capture': metadata['heading_at_capture'],
    'sweep_trigger_interval_degrees':
        metadata['sweep_trigger_interval_degrees'],
    'sweep_direction': metadata['sweep_direction'],
    'sweep_total_rotation_degrees': metadata['sweep_total_rotation_degrees'],
    'ground_truth_local_x': metadata['ground_truth_local_x'],
    'ground_truth_local_y': metadata['ground_truth_local_y'],
    'ground_truth_local_z': metadata['ground_truth_local_z'],
  };
  factory CaptureRecord.fromMap(Map<String, dynamic> map) => CaptureRecord(
    id: map['id'] as String,
    sessionId: map['session_id'] as String,
    filename: map['filename'] as String,
    imagePath: map['image_path'] as String,
    metadata:
        jsonDecode(map['metadata_json'] as String) as Map<String, dynamic>,
    createdAt: DateTime.parse(map['created_at'] as String),
    syncState: map['sync_state'] as String? ?? 'pending',
    syncAttemptCount: (map['sync_attempt_count'] as num?)?.toInt() ?? 0,
    lastSyncAttempt: map['last_sync_attempt'] == null
        ? null
        : DateTime.tryParse(map['last_sync_attempt'] as String),
    lastSyncError: map['last_sync_error'] as String?,
    serverImageId: map['server_image_id'] as String?,
    uploadedAt: map['uploaded_at'] == null
        ? null
        : DateTime.tryParse(map['uploaded_at'] as String),
  );
}

const sampleNodes = <Map<String, dynamic>>[
  {
    'campus': 'Main Campus',
    'building': 'Engineering Block',
    'wing': 'North Wing',
    'floor': 'Ground Floor',
    'area': 'Corridor',
    'node': 'EB-N-G-001',
    'name': 'North Entrance',
  },
  {
    'campus': 'Main Campus',
    'building': 'Engineering Block',
    'wing': 'North Wing',
    'floor': 'First Floor',
    'area': 'Laboratory',
    'node': 'EB-N-1-101',
    'name': 'Computer Vision Lab',
  },
  {
    'campus': 'Main Campus',
    'building': 'Library',
    'wing': 'Central',
    'floor': 'Ground Floor',
    'area': 'Reading Hall',
    'node': 'LIB-C-G-001',
    'name': 'Main Reading Hall',
  },
];
