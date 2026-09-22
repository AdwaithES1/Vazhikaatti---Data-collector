import hashlib
import json
from pathlib import Path
from threading import Lock
from typing import Any

ROOT = Path(__file__).resolve().parents[3] / 'data'
IMAGE_ROOT = ROOT / 'images'
METADATA_ROOT = ROOT / 'metadata'
_lock = Lock()
_captures_by_checksum: dict[str, dict[str, Any]] = {}
_sessions: dict[str, dict[str, Any]] = {}
_nodes: dict[str, dict[str, Any]] = {}

def register_session(payload: dict[str, Any]) -> dict[str, Any]:
    session_id = payload.get('id') or payload.get('name')
    record = {**payload, 'id': session_id}
    with _lock:
        _sessions[session_id] = record
    return record

def register_node(payload: dict[str, Any]) -> dict[str, Any]:
    with _lock:
        _nodes[payload['id']] = payload
    return payload

def _storage_filename(image_id: str, filename: str) -> str:
    """The filename already identifies the capture (e.g. the app's own
    '{image_id}.jpg' convention) as often as not, in which case prefixing
    image_id again just produces a redundant '{id}_{id}.jpg'. Only prefix
    when filename doesn't already start with image_id, to still avoid
    collisions between different captures that reused the same literal
    filename.
    """
    if filename.startswith(f'{image_id}_') or Path(filename).stem == image_id:
        return filename
    return f'{image_id}_{filename}'

def upload_capture(image_id: str | None, filename: str | None, checksum: str | None, metadata: dict[str, Any], image_bytes: bytes) -> dict[str, Any]:
    calculated = hashlib.sha256(image_bytes).hexdigest()
    if checksum and checksum != calculated:
        raise ValueError('checksum does not match image bytes')
    checksum = calculated
    with _lock:
        existing = _captures_by_checksum.get(checksum)
        if existing:
            return {'success': True, 'image_id': existing['image_id'], 'filename': existing['filename'], 'checksum': checksum, 'duplicate': True, 'relative_path': existing['relative_path']}
        image_id = image_id or checksum[:16]
        filename = filename or f'{image_id}.jpg'
        relative = Path('images') / _storage_filename(image_id, filename)
        destination = ROOT / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(image_bytes)
        METADATA_ROOT.mkdir(parents=True, exist_ok=True)
        (METADATA_ROOT / f'{image_id}.json').write_text(json.dumps(metadata, default=str, indent=2), encoding='utf-8')
        record = {'image_id': image_id, 'filename': filename, 'checksum': checksum, 'relative_path': relative.as_posix(), 'metadata': metadata}
        _captures_by_checksum[checksum] = record
        return {'success': True, 'image_id': image_id, 'filename': filename, 'checksum': checksum, 'duplicate': False, 'relative_path': relative.as_posix()}

def captures() -> list[dict[str, Any]]:
    return list(_captures_by_checksum.values())

def summary() -> dict[str, Any]:
    records = captures()
    return {'capture_count': len(records), 'session_count': len(_sessions), 'buildings': sorted({r['metadata'].get('building_name') for r in records if r['metadata'].get('building_name')}), 'floors': sorted({r['metadata'].get('floor_number') for r in records if r['metadata'].get('floor_number')}), 'nodes': sorted({r['metadata'].get('node_id') for r in records if r['metadata'].get('node_id')})}