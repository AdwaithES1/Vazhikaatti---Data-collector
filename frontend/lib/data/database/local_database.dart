import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../models/legacy_models.dart';

class LocalDatabase {
  LocalDatabase._();
  static final instance = LocalDatabase._();
  Database? _db;

  Future<Database> get database async => _db ??= await _open();
  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final db = await openDatabase(
      p.join(dir.path, 'vazhikatti.sqlite'),
      version: 3,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL, session_name TEXT NOT NULL, created_at TEXT NOT NULL, collector_id TEXT NOT NULL, status TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE captures (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, session_name TEXT, filename TEXT NOT NULL, image_path TEXT NOT NULL, metadata_json TEXT NOT NULL, created_at TEXT NOT NULL, sweep_id TEXT, sweep_index INTEGER, heading_at_capture REAL, sweep_trigger_interval_degrees REAL, sweep_direction TEXT, sweep_total_rotation_degrees REAL, ground_truth_local_x REAL, ground_truth_local_y REAL, ground_truth_local_z REAL, sync_state TEXT NOT NULL DEFAULT \'pending\', sync_attempt_count INTEGER NOT NULL DEFAULT 0, last_sync_attempt TEXT, last_sync_error TEXT, server_image_id TEXT, uploaded_at TEXT)',
        );
        await db.execute(
          'CREATE INDEX captures_session ON captures(session_id)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE captures ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'pending'",
          );
          await db.execute(
            'ALTER TABLE captures ADD COLUMN sync_attempt_count INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE captures ADD COLUMN last_sync_attempt TEXT',
          );
          await db.execute(
            'ALTER TABLE captures ADD COLUMN last_sync_error TEXT',
          );
          await db.execute(
            'ALTER TABLE captures ADD COLUMN server_image_id TEXT',
          );
          await db.execute('ALTER TABLE captures ADD COLUMN uploaded_at TEXT');
        }
        if (oldVersion < 3) {
          await db.execute(
            "ALTER TABLE sessions ADD COLUMN session_name TEXT NOT NULL DEFAULT ''",
          );
          await db.execute(
            "UPDATE sessions SET session_name = name WHERE session_name = ''",
          );
          await db.execute('ALTER TABLE captures ADD COLUMN session_name TEXT');
          await db.execute('ALTER TABLE captures ADD COLUMN sweep_id TEXT');
          await db.execute(
            'ALTER TABLE captures ADD COLUMN sweep_index INTEGER',
          );
          await db.execute(
            'ALTER TABLE captures ADD COLUMN heading_at_capture REAL',
          );
          await db.execute(
            'ALTER TABLE captures ADD COLUMN sweep_trigger_interval_degrees REAL',
          );
          await db.execute(
            'ALTER TABLE captures ADD COLUMN sweep_direction TEXT',
          );
          await db.execute(
            'ALTER TABLE captures ADD COLUMN sweep_total_rotation_degrees REAL',
          );
          await db.execute(
            'ALTER TABLE captures ADD COLUMN ground_truth_local_x REAL',
          );
          await db.execute(
            'ALTER TABLE captures ADD COLUMN ground_truth_local_y REAL',
          );
          await db.execute(
            'ALTER TABLE captures ADD COLUMN ground_truth_local_z REAL',
          );
        }
      },
    );
    return db;
  }

  Future<void> saveSession(CaptureSession session) async =>
      (await database).insert(
        'sessions',
        session.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
  Future<void> updateSessionName(String sessionId, String sessionName) async =>
      (await database).update(
        'sessions',
        {'name': sessionName, 'session_name': sessionName},
        where: 'id = ?',
        whereArgs: [sessionId],
      );
  Future<void> updateSessionStatus(String sessionId, String status) async =>
      (await database).update(
        'sessions',
        {'status': status},
        where: 'id = ?',
        whereArgs: [sessionId],
      );
  Future<List<CaptureSession>> sessions() async => (await database)
      .query('sessions', orderBy: 'created_at DESC')
      .then((rows) => rows.map(CaptureSession.fromMap).toList());

  Future<List<SessionSummary>> latestSessionSummaries({int limit = 10}) async {
    final rows = await (await database).rawQuery(
      '''SELECT s.*, COUNT(c.id) AS image_count,
        COUNT(DISTINCT NULLIF(c.sweep_id, '')) AS sweep_count,
        (SELECT image_path FROM captures representative
         WHERE representative.session_id = s.id
         ORDER BY representative.created_at DESC LIMIT 1) AS thumbnail_path
        FROM sessions s
        LEFT JOIN captures c ON c.session_id = s.id
        GROUP BY s.id
        ORDER BY s.created_at DESC
        LIMIT ?''',
      [limit],
    );
    return rows
        .map(
          (row) => SessionSummary(
            session: CaptureSession.fromMap(row),
            imageCount: (row['image_count'] as num?)?.toInt() ?? 0,
            sweepCount: (row['sweep_count'] as num?)?.toInt() ?? 0,
            thumbnailPath: row['thumbnail_path'] as String?,
          ),
        )
        .toList();
  }

  Future<void> saveCapture(CaptureRecord record) async =>
      (await database).insert(
        'captures',
        record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
  Future<void> deleteCapture(String id) async =>
      (await database).delete('captures', where: 'id = ?', whereArgs: [id]);
  Future<List<CaptureRecord>> captures([String? sessionId]) async {
    final rows = await (await database).query(
      'captures',
      where: sessionId == null ? null : 'session_id = ?',
      whereArgs: sessionId == null ? null : [sessionId],
      orderBy: 'created_at DESC',
    );
    return rows.map(CaptureRecord.fromMap).toList();
  }

  Future<int> captureCount() async =>
      Sqflite.firstIntValue(
        await (await database).rawQuery('SELECT COUNT(*) FROM captures'),
      ) ??
      0;

  Future<void> updateCaptureSync(CaptureRecord record) async =>
      (await database).update(
        'captures',
        record.toMap(),
        where: 'id = ?',
        whereArgs: [record.id],
      );

  Future<List<CaptureRecord>> syncCandidates() async {
    final rows = await (await database).query(
      'captures',
      where: "sync_state IN ('pending', 'failed')",
      orderBy: 'created_at ASC',
    );
    return rows.map(CaptureRecord.fromMap).toList();
  }

  Future<Map<String, int>> syncCounts() async {
    final rows = await (await database).rawQuery(
      'SELECT sync_state, COUNT(*) AS count FROM captures GROUP BY sync_state',
    );
    return {
      for (final row in rows)
        row['sync_state'] as String: (row['count'] as num).toInt(),
    };
  }
}
