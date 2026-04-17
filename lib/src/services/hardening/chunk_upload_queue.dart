import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../services/auth_service.dart';

/// A persistent, self-retrying upload queue for SOS video chunks.
///
/// Responsibilities:
///   - Persists pending chunks to disk so they survive app restarts and crashes.
///   - Retries failed uploads automatically using exponential back-off.
///   - Resumes uploading when connectivity is restored (call [onConnectivityRestored]).
///   - Is keyed per-[sosId] so multiple sessions never interfere.
///
/// Usage in CameraPage:
///   1. Call [ChunkUploadQueue.instance.enqueue] instead of uploading directly.
///   2. Call [ChunkUploadQueue.instance.onConnectivityRestored] from a
///      connectivity listener when network comes back.
///   3. Nothing else in the app needs to change.

class ChunkUploadQueue {
  ChunkUploadQueue._();
  static final ChunkUploadQueue instance = ChunkUploadQueue._();

  // ── Config ──────────────────────────────────────────────────────────────────

  /// How many upload attempts before a chunk is considered permanently failed
  /// (it stays on disk and can be retried on next app launch via [recoverAll]).
  static const int _maxAttempts = 8;

  /// Base delay for exponential back-off: attempt N waits [_baseDelay] * 2^N.
  static const Duration _baseDelay = Duration(seconds: 2);

  /// Maximum delay cap so we never wait more than this between retries.
  static const Duration _maxDelay = Duration(seconds: 60);

  // ── Internal state ──────────────────────────────────────────────────────────

  /// Active retry loops, keyed by sosId. Prevents double-starting a loop.
  final Map<String, bool> _loopRunning = {};

  /// In-memory pending queue per sosId: list of [_QueuedChunk].
  /// This mirrors what's on disk — disk is the source of truth on restart.
  final Map<String, List<_QueuedChunk>> _queues = {};

  /// Directory where queue manifests are stored.
  Future<Directory> get _queueDir async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'chunk_queue'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  // ── Public API ───────────────────────────────────────────────────────────────

  /// Add a chunk to the upload queue. Safe to call immediately after saving
  /// the chunk to disk — will upload as soon as [sosId] is known.
  ///
  /// [sosId]      — the server SOS session ID (may be null if not yet created;
  ///                in that case, hold the chunk in the pre-SOS buffer in
  ///                CameraPage as before, then call enqueue once sosId arrives).
  /// [index]      — chunk sequence number (000, 001, …).
  /// [chunkFile]  — the stable on-disk chunk file (already saved by VideoStorageUtils).
  Future<void> enqueue({
    required String sosId,
    required int index,
    required File chunkFile,
  }) async {
    final chunk = _QueuedChunk(sosId: sosId, index: index, filePath: chunkFile.path);

    _queues.putIfAbsent(sosId, () => []);
    // Avoid double-queueing the same index
    final already = _queues[sosId]!.any((c) => c.index == index);
    if (already) {
      debugPrint('[Queue] chunk $index for $sosId already queued, skipping');
      return;
    }

    _queues[sosId]!.add(chunk);
    await _persistQueue(sosId);

    debugPrint('[Queue] enqueued chunk $index for session $sosId');
    _ensureLoopRunning(sosId);
  }

  /// Call this when connectivity is restored (e.g. from connectivity_plus
  /// onConnectivityChanged listener). Restarts any stalled retry loops.
  void onConnectivityRestored() {
    debugPrint('[Queue] connectivity restored — resuming all stalled queues');
    for (final sosId in _queues.keys) {
      _ensureLoopRunning(sosId);
    }
    // Also re-hydrate from disk in case the app was restarted while offline
    recoverAll();
  }

  /// On app startup, scan disk for any unfinished queues from previous sessions
  /// and restart their upload loops. Call once from main() or a top-level init.
  Future<void> recoverAll() async {
    final dir = await _queueDir;
    final files = dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.queue.json'),
    );

    for (final file in files) {
      try {
        final sosId = p.basename(file.path).replaceFirst('.queue.json', '');
        final chunks = await _loadQueue(sosId);
        if (chunks.isEmpty) {
          file.deleteSync();
          continue;
        }
        _queues[sosId] = chunks;
        debugPrint('[Queue] recovered ${chunks.length} chunks for session $sosId');
        _ensureLoopRunning(sosId);
      } catch (e) {
        debugPrint('[Queue] error recovering queue file ${file.path}: $e');
      }
    }
  }

  // ── Internal ─────────────────────────────────────────────────────────────────

  void _ensureLoopRunning(String sosId) {
    if (_loopRunning[sosId] == true) return;
    _loopRunning[sosId] = true;
    _runUploadLoop(sosId);
  }

  Future<void> _runUploadLoop(String sosId) async {
    debugPrint('[Queue] upload loop started for $sosId');

    while (true) {
      final queue = _queues[sosId];
      if (queue == null || queue.isEmpty) {
        debugPrint('[Queue] upload loop finished for $sosId — queue empty');
        _loopRunning.remove(sosId);
        _queues.remove(sosId);
        await _deleteQueueFile(sosId);
        return;
      }

      // Always process in index order
      queue.sort((a, b) => a.index.compareTo(b.index));
      final chunk = queue.first;

      final success = await _attemptUpload(chunk);

      if (success) {
        queue.removeAt(0);
        await _persistQueue(sosId);
        debugPrint('[Queue] ✅ chunk ${chunk.index} uploaded for $sosId');
        // Continue immediately to next chunk
        continue;
      }

      // Upload failed — apply back-off and retry (up to _maxAttempts)
      chunk.attempts++;

      if (chunk.attempts >= _maxAttempts) {
        debugPrint(
          '[Queue] ⚠️ chunk ${chunk.index} for $sosId exceeded max attempts — '
          'leaving on disk for manual recovery',
        );
        // Move it to the back so the rest of the queue can still upload
        queue.removeAt(0);
        queue.add(chunk);
        await _persistQueue(sosId);
        // If ALL remaining chunks are maxed out, stop the loop
        if (queue.every((c) => c.attempts >= _maxAttempts)) {
          debugPrint('[Queue] all remaining chunks maxed out for $sosId — stopping loop');
          _loopRunning.remove(sosId);
          return;
        }
        continue;
      }

      final delay = _backOffDelay(chunk.attempts);
      debugPrint(
        '[Queue] ❌ chunk ${chunk.index} failed (attempt ${chunk.attempts}) — '
        'retrying in ${delay.inSeconds}s',
      );
      await _persistQueue(sosId); // persist updated attempt count
      await Future.delayed(delay);
    }
  }

  Future<bool> _attemptUpload(_QueuedChunk chunk) async {
    final file = File(chunk.filePath);
    if (!file.existsSync()) {
      debugPrint('[Queue] chunk file missing at ${chunk.filePath} — skipping');
      return true; // treat as "done" so we don't loop forever on a missing file
    }

    try {
      await AuthService.instance.api.uploadSosChunk(
        sosId: chunk.sosId,
        index: chunk.index,
        file: file,
      );
      return true;
    } catch (e) {
      debugPrint('[Queue] upload error for chunk ${chunk.index}: $e');
      return false;
    }
  }

  Duration _backOffDelay(int attempt) {
    final ms = _baseDelay.inMilliseconds * (1 << attempt); // 2^attempt
    return Duration(
      milliseconds: ms.clamp(0, _maxDelay.inMilliseconds),
    );
  }

  // ── Persistence ───────────────────────────────────────────────────────────────

  Future<File> _queueFile(String sosId) async {
    final dir = await _queueDir;
    return File(p.join(dir.path, '$sosId.queue.json'));
  }

  Future<void> _persistQueue(String sosId) async {
    try {
      final file = await _queueFile(sosId);
      final chunks = _queues[sosId] ?? [];
      final json = jsonEncode(chunks.map((c) => c.toJson()).toList());
      await file.writeAsString(json);
    } catch (e) {
      debugPrint('[Queue] failed to persist queue for $sosId: $e');
    }
  }

  Future<List<_QueuedChunk>> _loadQueue(String sosId) async {
    try {
      final file = await _queueFile(sosId);
      if (!file.existsSync()) return [];
      final raw = await file.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((j) => _QueuedChunk.fromJson(j as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('[Queue] failed to load queue for $sosId: $e');
      return [];
    }
  }

  Future<void> _deleteQueueFile(String sosId) async {
    try {
      final file = await _queueFile(sosId);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}

// ── Data model ────────────────────────────────────────────────────────────────

class _QueuedChunk {
  final String sosId;
  final int index;
  final String filePath;
  int attempts;

  _QueuedChunk({
    required this.sosId,
    required this.index,
    required this.filePath,
    this.attempts = 0,
  });

  Map<String, dynamic> toJson() => {
    'sosId': sosId,
    'index': index,
    'filePath': filePath,
    'attempts': attempts,
  };

  factory _QueuedChunk.fromJson(Map<String, dynamic> j) => _QueuedChunk(
    sosId: j['sosId'] as String,
    index: j['index'] as int,
    filePath: j['filePath'] as String,
    attempts: (j['attempts'] as int?) ?? 0,
  );
}