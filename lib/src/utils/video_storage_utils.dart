import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
/// Manages local storage of SOS video chunks and final stitched videos.
///
/// Directory structure:
///   <appDocs>/sos_videos/                     ← final videos live here
///   <appDocs>/sos_videos/{sessionId}/         ← temp chunk folder per session
///   <appDocs>/sos_videos/{sessionId}/chunk_000.mp4
///   <appDocs>/sos_videos/{sessionId}/chunk_001.mp4
///   ...
///   <appDocs>/sos_videos/{sessionId}.mp4      ← stitched output
class VideoStorageUtils {
  // ── Singleton ──────────────────────────────────────────────────────────────

  VideoStorageUtils._();
  static final VideoStorageUtils instance = VideoStorageUtils._();

  // ── Paths ──────────────────────────────────────────────────────────────────

  Future<Directory> get _sosVideosDir async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'sos_videos'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _chunkDir(String sessionId) async {
    final base = await _sosVideosDir;
    final dir = Directory(p.join(base.path, sessionId));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Saves a raw chunk [file] into the session's temp folder.
  ///
  /// Returns the saved [File], or null if the write failed.
  Future<File?> saveChunk({
    required String sessionId,
    required int index,
    required File file,
  }) async {
    try {
      final dir = await _chunkDir(sessionId);
      final chunkName = 'chunk_${index.toString().padLeft(3, '0')}.mp4';
      final targetPath = p.join(dir.path, chunkName);

      File saved;
      try {
        saved = await file.rename(targetPath);
      } catch (_) {
        // Cross-device rename (e.g. temp → docs) – fall back to copy+delete.
        saved = await file.copy(targetPath);
        try {
          await file.delete();
        } catch (_) {}
      }

      debugPrint('[VideoStorage] Saved chunk $index → ${saved.path}');
      return saved;
    } catch (e) {
      debugPrint('[VideoStorage] saveChunk error (index=$index): $e');
      return null;
    }
  }

  /// Stitches all chunks for [sessionId] into a single MP4, deletes the chunk
  /// folder, and returns the final [File].
  ///
  /// Returns null if stitching fails (chunks are preserved so nothing is lost).
  Future<File?> stitchSession(String sessionId) async {
    try {
      final dir = await _chunkDir(sessionId);
      final base = await _sosVideosDir;

      // Collect chunks in order.
      final chunks = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.mp4'))
          .toList()
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

      if (chunks.isEmpty) {
        debugPrint('[VideoStorage] No chunks found for session $sessionId');
        return null;
      }

      // If there's only one chunk, just move it – no ffmpeg needed.
      if (chunks.length == 1) {
        final output = await _moveToFinal(chunks.first, base, sessionId);
        await _deleteChunkDir(dir);
        return output;
      }

      // Write the ffmpeg concat list.
      final listFile = File(p.join(dir.path, 'filelist.txt'));
      final lines = chunks.map((f) => "file '${f.path}'").join('\n');
      await listFile.writeAsString(lines);

      final outputPath = p.join(base.path, '$sessionId.mp4');

      // Run ffmpeg concat (stream-copy – no re-encode, very fast).
      final command =
          '-f concat -safe 0 -i "${listFile.path}" -c copy "$outputPath"';

      debugPrint('[VideoStorage] Running ffmpeg: $command');
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getAllLogsAsString();
        debugPrint('[VideoStorage] ffmpeg failed:\n$logs');
        // Do NOT delete chunks – keep them so nothing is lost.
        return null;
      }

      // Success – clean up temp folder.
      await _deleteChunkDir(dir);

      final output = File(outputPath);
      debugPrint('[VideoStorage] Stitched → ${output.path}');
      return output;
    } catch (e) {
      debugPrint('[VideoStorage] stitchSession error: $e');
      return null;
    }
  }

  /// Returns all finalised (stitched) videos, newest first.
  Future<List<File>> loadFinalVideos() async {
    final dir = await _sosVideosDir;
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp4'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  }

  /// Finds any leftover chunk folders from previous sessions (e.g. app crash).
  /// Returns a map of sessionId → chunk files so the caller can decide what
  /// to do with them (re-stitch, discard, etc.).
  Future<Map<String, List<File>>> findOrphanedSessions() async {
    final dir = await _sosVideosDir;
    final Map<String, List<File>> orphans = {};

    for (final entry in dir.listSync().whereType<Directory>()) {
      final sessionId = p.basename(entry.path);
      final chunks = entry
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.mp4'))
          .toList()
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

      if (chunks.isNotEmpty) {
        orphans[sessionId] = chunks;
      }
    }

    return orphans;
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  Future<File> _moveToFinal(
    File chunk,
    Directory base,
    String sessionId,
  ) async {
    final outputPath = p.join(base.path, '$sessionId.mp4');
    try {
      return await chunk.rename(outputPath);
    } catch (_) {
      final copied = await chunk.copy(outputPath);
      try {
        await chunk.delete();
      } catch (_) {}
      return copied;
    }
  }

  Future<void> _deleteChunkDir(Directory dir) async {
    try {
      await dir.delete(recursive: true);
      debugPrint('[VideoStorage] Deleted chunk dir: ${dir.path}');
    } catch (e) {
      debugPrint('[VideoStorage] Could not delete chunk dir: $e');
    }
  }
}