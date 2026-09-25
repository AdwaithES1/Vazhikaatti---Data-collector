import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../data/database/local_database.dart';
import '../../data/models/capture_metadata.dart';
import '../../data/models/legacy_models.dart';

class StorageService {
  Future<Directory> root() async => Directory(
    p.join(
      (await getApplicationDocumentsDirectory()).path,
      'VazhikattiDataset',
    ),
  )..createSync(recursive: true);
  Future<String> saveImage(
    File source,
    String sessionId,
    String imageId,
  ) async {
    final dir = Directory(p.join((await root()).path, 'images', sessionId))
      ..createSync(recursive: true);
    final bytes = await source.readAsBytes();
    final checksum = sha256.convert(bytes).toString();
    final destination = File(p.join(dir.path, '$imageId.jpg'));
    await destination.writeAsBytes(bytes, flush: true);
    return '${destination.path}|$checksum';
  }

  Future<File> exportDataset({String? sessionId}) async {
    final base = await root();
    final captures = await LocalDatabase.instance.captures(sessionId);
    captures.sort((a, b) {
      final aPano = a.metadata['panorama_id'];
      final bPano = b.metadata['panorama_id'];
      if (aPano != null && aPano == bPano) {
        final aFrame = a.metadata['frame_index'];
        final bFrame = b.metadata['frame_index'];
        if (aFrame is num && bFrame is num) {
          return aFrame.compareTo(bFrame);
        }
      }
      return a.createdAt.compareTo(b.createdAt);
    });
    final sessions = sessionId == null
        ? await LocalDatabase.instance.sessions()
        : (await LocalDatabase.instance.sessions())
              .where((session) => session.id == sessionId)
              .toList();
    if (sessionId != null && sessions.isEmpty) {
      throw StateError('Session not found');
    }
    final sessionPrefix = sessionId == null
        ? ''
        : '${_exportName(sessions.single.name)}/';
    final archive = Archive();
    final metadata = captures
        .map(
          (c) => CaptureMetadata.fromJson({
            ...c.metadata,
            'image_id': c.id,
            'filename': c.filename,
            'capture_session_id': c.sessionId,
          }).toJson(),
        )
        .toList();
    archive.addFile(
      ArchiveFile(
        '${sessionPrefix}metadata.json',
        utf8.encode(jsonEncode(metadata)).length,
        utf8.encode(jsonEncode(metadata)),
      ),
    );
    archive.addFile(
      ArchiveFile(
        sessionId == null ? 'sessions.json' : '${sessionPrefix}session.json',
        utf8.encode(jsonEncode(sessions.map((s) => s.toMap()).toList())).length,
        utf8.encode(jsonEncode(sessions.map((s) => s.toMap()).toList())),
      ),
    );
    final rows = <List<dynamic>>[
      CaptureMetadata.fields,
      ...metadata.map(
        (m) => CaptureMetadata.fields.map((key) => m[key]).toList(),
      ),
    ];
    final csv = const ListToCsvConverter().convert(rows);
    archive.addFile(
      ArchiveFile(
        '${sessionPrefix}metadata.csv',
        utf8.encode(csv).length,
        utf8.encode(csv),
      ),
    );
    if (sessionId == null) {
      archive.addFile(
        ArchiveFile(
          'nodes.json',
          utf8.encode(jsonEncode(sampleNodes)).length,
          utf8.encode(jsonEncode(sampleNodes)),
        ),
      );
      archive.addFile(
        ArchiveFile(
          'README.txt',
          206,
          utf8.encode(
            'Vazhikatti Dataset Export\nGenerated fully offline. GPS is rough positioning only; floor and node are explicit ground truth.\n',
          ),
        ),
      );
    }
    for (final capture in captures) {
      final file = File(capture.imagePath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        archive.addFile(
          ArchiveFile(
            '${sessionPrefix}images/${capture.filename}',
            bytes.length,
            bytes,
          ),
        );
      }
    }
    final exportDir = Directory(p.join(base.path, 'exports'))
      ..createSync(recursive: true);
    final out = File(
      p.join(
        exportDir.path,
        'vazhikatti_${sessionId == null ? 'dataset' : 'session_$sessionId'}_${DateTime.now().millisecondsSinceEpoch}.zip',
      ),
    );
    final bytes = ZipEncoder().encode(archive);
    await out.writeAsBytes(bytes);
    return out;
  }

  Future<void> shareExport(File file) => Share.shareXFiles([
    XFile(file.path),
  ], subject: 'Vazhikatti offline dataset');

  String _exportName(String value) => value
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
}
