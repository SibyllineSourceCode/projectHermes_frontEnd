import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import '../utils/video_storage_utils.dart';
import '../services/auth_service.dart';

// ── Global / shared ──────────────────────────────────────────────────────────
const _bgPage = Color(0xFF0E0C0A);
const _bgAppBar = Color(0xFF140E08);
const _textPrimary = Color(0xFFF5F2EE);
const _playerThumb = Color(0xFFFE7E00);

// ── MY VIDEOS — Charcoal / wood ──────────────────────────────────────────────
const _ownBgRow = Color(0xFF1E1C18);
const _ownBgThumb = Color(0xFF2E2A24);
const _ownDivider = Color(0xFF2A2820);
const _ownTextPrimary = Color(0xFFE8E4DC);
const _ownTextSecondary = Color(0xFFB0A89E);
const _ownTextMuted = Color(0xFF7A7068);
const _ownIconAccent = Color(0xFFA8917A);
const _ownSplash = Color(0x0FFFFFFF);
const _ownLocalBadgeBg = Color(0xFF3A3228);
const _ownLocalBadgeText = Color(0xFFD8D0C8);
const _ownServerBadgeBg = Color(0xFF4A3010);
const _ownServerBadgeText = Color(0xFFFFC875);

// ── SHARED SESSIONS — Soft ember / firelight ─────────────────────────────────
const _sharedBgRow = Color(0xFF201408);
const _sharedBgThumb = Color(0xFF2E1A08);
const _sharedDivider = Color(0xFF3A2010);
const _sharedTextPrimary = Color(0xFFFAF0E0);
const _sharedTextSecondary = Color(0xFFD4A870);
const _sharedTextMuted = Color(0xFF8A6040);
const _sharedIconAccent = Color(0xFFF59B30);
const _sharedSplash = Color(0x1AFE7E00);

// ── Status badge palette ──────────────────────────────────────────────────────
// Ready  — amber, signals watchable
const _badgeReadyBg = Color(0xFF4A2200);
const _badgeReadyText = Color(0xFFFFC875);
// Uploading — blue-tinted, signals active transfer
const _badgeUploadingBg = Color(0xFF0D2340);
const _badgeUploadingText = Color(0xFF7EC8FF);
// Stalled — muted red, signals interruption
const _badgeStalledBg = Color(0xFF3A1010);
const _badgeStalledText = Color(0xFFFF9E9E);
// Completed — same as Ready (video is done, fully stitched)
const _badgeCompletedBg = Color(0xFF0D2E1A);
const _badgeCompletedText = Color(0xFF7EFFA8);
// Loading (no finalStoragePath yet, status unknown) — dim
const _badgeLoadingBg = Color(0xFF2A1C10);
const _badgeLoadingText = Color(0xFF8A6040);

// ── Download button ───────────────────────────────────────────────────────────
const _dlBg = Color(0xFF2A1C10);
const _dlBorder = Color(0xFFF59B30);
const _dlText = Color(0xFFFFC875);

// ── Geolocation banner ────────────────────────────────────────────────────────
const _geoBannerBg = Color(0xFF2A1C10);
const _geoBannerBorder = Color(0xFFC06A00);
const _geoText = Color(0xFFFFC875);
const _geoCopyIcon = Color(0xFFF59B30);

// ── Snackbars ────────────────────────────────────────────────────────────────
const _snackSuccessBg = Color(0xFF2A1C10);
const _snackSuccessIcon = Color(0xFFFFC875);
const _snackErrorBg = Color(0xFF3A1A08);
const _snackErrorIcon = Color(0xFFFFE0B0);

// ── Timing constants ──────────────────────────────────────────────────────────
const _pollInterval = Duration(seconds: 10);
const _stallThreshold = Duration(seconds: 30);

// ─────────────────────────────────────────────────────────────────────────────

/// Status values that mirror sos_sessions.status on the backend,
/// plus a client-derived "stalled" state.
enum _SessionStatus { live, uploading, stalled, completed }

/// Shared helper: derives the "stalled" state from raw status + lastChunkAt.
/// A session reads as "stalled" when it isn't completed, has received at
/// least one chunk, and no new chunk has arrived in the last 30 seconds.
/// Used by both _VideoEntry (sent videos) and _SharedEntry (received videos).
_SessionStatus _effectiveSessionStatus(
  _SessionStatus raw,
  DateTime? lastChunkAt,
) {
  if (raw == _SessionStatus.completed) return _SessionStatus.completed;
  if (lastChunkAt != null &&
      DateTime.now().difference(lastChunkAt) > _stallThreshold) {
    return _SessionStatus.stalled;
  }
  return raw;
}

class _VideoEntry {
  final File file;
  final bool isLocal;

  // Session linkage — null if this local file has no matching server session
  // (e.g. an old recording from before sessions were tracked, or a video
  // that was never uploaded).
  final String? sosId;
  _SessionStatus? sessionStatus;
  DateTime? lastChunkAt;

  Uint8List? thumbnail;
  bool thumbnailAttempted = false;

  _VideoEntry({
    required this.file,
    required this.isLocal,
    this.sosId,
    this.sessionStatus,
    this.lastChunkAt,
  });

  /// True if this video has any associated server session at all
  /// (regardless of status) — used to decide whether to show a second badge.
  bool get hasSession => sosId != null;

  /// Derived display status, applying the stall rule.
  _SessionStatus? get effectiveStatus {
    final raw = sessionStatus;
    if (raw == null) return null;
    return _effectiveSessionStatus(raw, lastChunkAt);
  }
}

class _SharedEntry {
  final String sessionId;
  final String hostUid;
  String senderName;
  final String? message;
  final String? listTitle;
  final DateTime? createdAt;
  final String? geolocation;

  // Updated in-place by poll diffs.
  String? finalStoragePath;
  String? streamUrl;
  _SessionStatus sessionStatus;
  DateTime? lastChunkAt;

  bool urlAttempted = false;
  bool thumbnailAttempted = false;
  bool isDownloading = false;
  Uint8List? thumbnail;

  _SharedEntry({
    required this.sessionId,
    required this.hostUid,
    this.senderName = '',
    this.message,
    this.listTitle,
    this.createdAt,
    this.finalStoragePath,
    this.streamUrl,
    this.geolocation,
    _SessionStatus? sessionStatus,
    this.lastChunkAt,
  }) : sessionStatus = sessionStatus ?? _SessionStatus.live;

  /// Derives the display status at render time. See _effectiveSessionStatus
  /// for the stall rule — shared with _VideoEntry.
  _SessionStatus get effectiveStatus =>
      _effectiveSessionStatus(sessionStatus, lastChunkAt);
}

// ─────────────────────────────────────────────────────────────────────────────

_SessionStatus _parseStatus(String? raw) {
  switch (raw) {
    case 'uploading':
      return _SessionStatus.uploading;
    case 'completed':
      return _SessionStatus.completed;
    case 'live':
    default:
      return _SessionStatus.live;
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class MyVideosScreen extends StatefulWidget {
  final List<File> videos;
  const MyVideosScreen({super.key, required this.videos});

  @override
  State<MyVideosScreen> createState() => _MyVideosScreenState();
}

class _MyVideosScreenState extends State<MyVideosScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  List<_VideoEntry> _entries = [];
  bool _loadingOwn = true;
  Directory? _thumbCacheDir;

  List<_SharedEntry> _shared = [];
  bool _loadingShared = true;

  // Polling
  Timer? _pollTimer;
  bool _polling = false;
  bool _pollingOwn = false;

  _VideoEntry? _playingOwn;
  _SharedEntry? _playingShared;
  VideoPlayerController? _playerController;
  bool _playerReady = false;
  bool _showControls = true;

  /* ──────────────────────── Init / dispose ────────────────────────────────── */

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initThumbCache().then((_) {
      _initOwnVideos();
      _initSharedSessions();
    });
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tabController.dispose();
    _playerController?.dispose();
    super.dispose();
  }

  /* ──────────────────────── Polling ──────────────────────────────────────── */

  void _startPolling() {
    // Tick immediately so stalled badges update even with no network activity.
    // The actual network fetch is guarded by _polling and _loadingShared.
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      _pollSharedSessions();
      _pollOwnSessions();
    });
  }

  Future<void> _pollSharedSessions() async {
    if (_polling || _loadingShared || !mounted) return;
    _polling = true;

    try {
      final response = await AuthService.instance.api.getSharedSessions();
      if (!mounted) return;

      final rawList = response['sessions'] as List?;
      if (rawList == null) return;

      bool listChanged = false;

      final freshMap = <String, Map<String, dynamic>>{};
      for (final raw in rawList) {
        final d = raw as Map<String, dynamic>;
        if (d['error'] == true) continue;
        final id = (d['sessionId'] as String?) ?? '';
        if (id.isEmpty) continue;
        freshMap[id] = d;
      }

      // ── New sessions ──────────────────────────────────────────────────────
      final existingIds = _shared.map((e) => e.sessionId).toSet();
      for (final id in freshMap.keys) {
        if (!existingIds.contains(id)) {
          final d = freshMap[id]!;
          final newEntry = _buildEntryFromMap(id, d);
          _shared.add(newEntry);
          _loadSharedThumbnail(newEntry);
          listChanged = true;
          debugPrint('🔔 [Poll] New shared session: $id');
        }
      }

      // ── Existing sessions — diff on finalStoragePath, status, lastChunkAt ─
      for (final entry in _shared) {
        final fresh = freshMap[entry.sessionId];
        if (fresh == null) continue;

        final freshPath = fresh['finalStoragePath'] as String?;
        final freshUrl = fresh['streamUrl'] as String?;
        final freshStatus = _parseStatus(fresh['status'] as String?);
        final freshLastChunk =
            fresh['lastChunkAt'] != null
                ? DateTime.tryParse(fresh['lastChunkAt'] as String)
                : null;

        // Track whether we need to reinitialize the player.
        final pathChanged =
            freshPath != null &&
            freshPath.isNotEmpty &&
            freshPath != entry.finalStoragePath;

        // Track whether any field that affects the badge changed.
        final metaChanged =
            freshStatus != entry.sessionStatus ||
            freshLastChunk != entry.lastChunkAt ||
            pathChanged;

        if (metaChanged) {
          final wasPlaying = _playingShared?.sessionId == entry.sessionId;
          Duration resumeAt = Duration.zero;

          if (pathChanged && wasPlaying && _playerController != null) {
            resumeAt = _playerController!.value.position;
          }

          entry.finalStoragePath = freshPath ?? entry.finalStoragePath;
          entry.streamUrl = freshUrl ?? entry.streamUrl;
          entry.sessionStatus = freshStatus;
          entry.lastChunkAt = freshLastChunk ?? entry.lastChunkAt;

          if (pathChanged) {
            entry.thumbnailAttempted = false;
            _loadSharedThumbnail(entry);
          }

          listChanged = true;

          if (pathChanged && wasPlaying && freshUrl != null) {
            await _reinitializePlayer(entry, resumeAt: resumeAt);
          }

          debugPrint(
            '🔄 [Poll] ${entry.sessionId}: status=${entry.sessionStatus.name}'
            '  lastChunk=${entry.lastChunkAt}  pathChanged=$pathChanged',
          );
        }
      }

      _shared.sort((a, b) {
        if (a.createdAt == null && b.createdAt == null) return 0;
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });

      if (listChanged && mounted) setState(() {});
    } catch (e) {
      debugPrint('⚠️ [Poll] shared_sessions poll failed: $e');
    } finally {
      _polling = false;
    }
  }

  /// Polls /me/my_sessions and refreshes status/lastChunkAt on _entries
  /// whose sosId matches a returned session. Drives the Uploading /
  /// Stalled / Server badge on "My Videos".
  ///
  /// Lighter than _pollSharedSessions — there's no player or thumbnail to
  /// manage here, just badge state.
  Future<void> _pollOwnSessions() async {
    if (_pollingOwn || _loadingOwn || !mounted) return;
    _pollingOwn = true;

    try {
      final response = await AuthService.instance.api.getMySessions();
      if (!mounted) return;

      final sessionList = (response['sessions'] as List<dynamic>?) ?? [];
      if (sessionList.isEmpty) return;

      final sessionMeta =
          <String, ({_SessionStatus status, DateTime? lastChunkAt})>{};
      for (final raw in sessionList) {
        final d = raw as Map<String, dynamic>;
        final sosId = d['sosId'] as String?;
        if (sosId == null) continue;
        sessionMeta[sosId] = (
          status: _parseStatus(d['status'] as String?),
          lastChunkAt:
              d['lastChunkAt'] != null
                  ? DateTime.tryParse(d['lastChunkAt'] as String)
                  : null,
        );
      }

      bool changed = false;
      for (final entry in _entries) {
        final sosId = entry.sosId;
        if (sosId == null) continue;

        final fresh = sessionMeta[sosId];
        if (fresh == null) continue;

        if (fresh.status != entry.sessionStatus ||
            fresh.lastChunkAt != entry.lastChunkAt) {
          entry.sessionStatus = fresh.status;
          entry.lastChunkAt = fresh.lastChunkAt;
          changed = true;
          debugPrint(
            '🔄 [Poll] own session $sosId: status=${fresh.status.name}'
            '  lastChunk=${fresh.lastChunkAt}',
          );
        }
      }

      if (changed && mounted) setState(() {});
    } catch (e) {
      debugPrint('⚠️ [Poll] my_sessions poll failed: $e');
    } finally {
      _pollingOwn = false;
    }
  }

  _SharedEntry _buildEntryFromMap(String id, Map<String, dynamic> d) {
    return _SharedEntry(
      sessionId: id,
      hostUid: d['hostUid'] ?? '',
      message: d['message'] as String?,
      listTitle: d['listTitle'] as String?,
      finalStoragePath: d['finalStoragePath'] as String?,
      streamUrl: d['streamUrl'] as String?,
      senderName: d['senderName'] ?? '',
      geolocation: d['geolocation'] as String?,
      sessionStatus: _parseStatus(d['status'] as String?),
      lastChunkAt:
          d['lastChunkAt'] != null
              ? DateTime.tryParse(d['lastChunkAt'] as String)
              : null,
      createdAt:
          d['createdAt'] != null
              ? DateTime.tryParse(d['createdAt'] as String)
              : null,
    );
  }

  /* ──────────────────────── Player reinit ────────────────────────────────── */

  Future<void> _reinitializePlayer(
    _SharedEntry entry, {
    Duration resumeAt = Duration.zero,
  }) async {
    final url = entry.streamUrl;
    if (url == null) return;

    final oldCtrl = _playerController;
    _playerController = null;

    try {
      await oldCtrl?.pause();
      oldCtrl?.dispose();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _playerReady = false;
      _playingShared = entry;
    });

    final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
    _playerController = ctrl;

    try {
      await ctrl.initialize();
    } catch (e) {
      debugPrint('❌ [Poll] Player reinit failed: $e');
      return;
    }

    if (!mounted) return;

    ctrl.addListener(() {
      if (mounted) setState(() {});
    });

    if (resumeAt > Duration.zero && resumeAt < ctrl.value.duration) {
      await ctrl.seekTo(resumeAt);
    }

    setState(() => _playerReady = true);
    await ctrl.play();
  }

  /* ──────────────────────── My Videos loading ─────────────────────────────── */

  Future<void> _initThumbCache() async {
    final docs = await getApplicationDocumentsDirectory();
    _thumbCacheDir = Directory(p.join(docs.path, 'sos_video_thumbs'));
    if (!await _thumbCacheDir!.exists()) {
      await _thumbCacheDir!.create(recursive: true);
    }
  }

  Future<void> _initOwnVideos() async {
    final currentUser = await AuthService.instance.api.me();

    AuthService.instance.api
        .finalizeUser(userId: currentUser['uid'])
        .catchError((e) {
          debugPrint('[MyVideos] finalizeUser error: $e');
          return <String, dynamic>{};
        });

    final sessionsResult = await AuthService.instance.api.getMySessions();

    // New response shape: { ok, sessions: [{ sosId, status, lastChunkAt }] }
    // covering live/uploading/completed — not just completed as before.
    final sessionList = (sessionsResult['sessions'] as List<dynamic>?) ?? [];

    // Map sosId -> {status, lastChunkAt} for quick lookup while matching
    // local files below.
    final sessionMeta =
        <String, ({_SessionStatus status, DateTime? lastChunkAt})>{};
    for (final raw in sessionList) {
      final d = raw as Map<String, dynamic>;
      final sosId = d['sosId'] as String?;
      if (sosId == null) continue;
      sessionMeta[sosId] = (
        status: _parseStatus(d['status'] as String?),
        lastChunkAt:
            d['lastChunkAt'] != null
                ? DateTime.tryParse(d['lastChunkAt'] as String)
                : null,
      );
    }

    final diskVideos = await VideoStorageUtils.instance.loadFinalVideos();
    final entries =
        diskVideos.map((f) {
          // A local file's path embeds its sosId — find the matching session,
          // if any. Files with no match (pre-session recordings, or never
          // uploaded) get sosId == null and show only the "Local" badge.
          String? matchedSosId;
          for (final id in sessionMeta.keys) {
            if (f.path.contains(id)) {
              matchedSosId = id;
              break;
            }
          }

          final meta = matchedSosId != null ? sessionMeta[matchedSosId] : null;

          return _VideoEntry(
            file: f,
            isLocal: true,
            sosId: matchedSosId,
            sessionStatus: meta?.status,
            lastChunkAt: meta?.lastChunkAt,
          );
        }).toList();

    entries.sort(
      (a, b) => b.file.lastModifiedSync().compareTo(a.file.lastModifiedSync()),
    );

    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loadingOwn = false;
    });
    for (final e in _entries) {
      _loadThumbnail(e);
    }
  }

  /* ──────────────────────── Shared Sessions loading ───────────────────────── */

  Future<void> _initSharedSessions() async {
    try {
      final response = await AuthService.instance.api.getSharedSessions();
      final rawList = response['sessions'];

      if (rawList == null) {
        if (mounted) setState(() => _loadingShared = false);
        return;
      }

      final results =
          (rawList as List).map((d) {
            if (d['error'] == true) {
              return _SharedEntry(
                sessionId: d['sessionId'] ?? 'unknown',
                hostUid: '',
                message: 'Error — something went wrong with this video',
              );
            }
            return _buildEntryFromMap((d['sessionId'] as String?) ?? '', d);
          }).toList();

      results.sort((a, b) {
        if (a.createdAt == null && b.createdAt == null) return 0;
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });

      if (!mounted) return;
      setState(() {
        _shared = results;
        _loadingShared = false;
      });

      for (final entry in _shared) {
        _loadSharedThumbnail(entry);
      }
    } catch (e, stack) {
      debugPrint('[SharedSessions] ❌ load error: $e\n$stack');
      if (mounted) setState(() => _loadingShared = false);
    }
  }

  /* ──────────────────────── Download ─────────────────────────────────────── */

  Future<void> _downloadShared(_SharedEntry entry) async {
    final url = entry.streamUrl;
    if (url == null || entry.isDownloading) return;

    setState(() => entry.isDownloading = true);

    try {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(p.join(tempDir.path, '${entry.sessionId}.mp4'));

      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final sink = tempFile.openWrite();
      await response.pipe(sink);
      await sink.flush();
      await sink.close();
      client.close();

      await Gal.putVideo(tempFile.path);
      await tempFile.delete().catchError((_) => tempFile);

      if (!mounted) return;
      _showSnack(
        icon: Icons.check_circle_outline,
        iconColor: _snackSuccessIcon,
        text: 'Saved to your videos',
        bg: _snackSuccessBg,
      );
    } catch (e) {
      debugPrint('[Download] ❌ error: $e');
      if (!mounted) return;
      _showSnack(
        icon: Icons.error_outline,
        iconColor: _snackErrorIcon,
        text: 'Download failed — please try again',
        bg: _snackErrorBg,
        duration: const Duration(seconds: 3),
      );
    } finally {
      if (mounted) setState(() => entry.isDownloading = false);
    }
  }

  void _showSnack({
    required IconData icon,
    required Color iconColor,
    required String text,
    required Color bg,
    Duration duration = const Duration(seconds: 2),
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: bg,
        duration: duration,
        content: Row(
          children: [
            Icon(icon, color: iconColor, size: 16),
            const SizedBox(width: 8),
            Text(
              text,
              style: const TextStyle(color: _textPrimary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  /* ──────────────────────── Thumbnails ───────────────────────────────────── */

  Future<void> _loadThumbnail(_VideoEntry entry) async {
    if (entry.thumbnailAttempted) return;
    entry.thumbnailAttempted = true;

    final cacheDir = _thumbCacheDir;
    if (cacheDir == null) return;

    final cacheKey = entry.file.path.hashCode.toRadixString(16);
    final cacheFile = File(p.join(cacheDir.path, '$cacheKey.jpg'));

    Uint8List? bytes;
    if (await cacheFile.exists()) {
      bytes = await cacheFile.readAsBytes();
    } else {
      try {
        final generated = await VideoThumbnail.thumbnailData(
          video: entry.file.path,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 160,
          quality: 72,
        );
        if (generated != null) {
          bytes = generated;
          await cacheFile.writeAsBytes(generated);
        }
      } catch (_) {}
    }

    if (bytes != null && mounted) setState(() => entry.thumbnail = bytes);
  }

  Future<void> _loadSharedThumbnail(_SharedEntry entry) async {
    if (entry.thumbnailAttempted || entry.streamUrl == null) return;
    entry.thumbnailAttempted = true;

    final cacheDir = _thumbCacheDir;
    if (cacheDir == null) return;

    final cacheKey = (entry.finalStoragePath ?? entry.sessionId).hashCode
        .toRadixString(16);
    final cacheFile = File(p.join(cacheDir.path, 'shared_$cacheKey.jpg'));

    Uint8List? bytes;
    if (await cacheFile.exists()) {
      bytes = await cacheFile.readAsBytes();
    } else {
      try {
        final generated = await VideoThumbnail.thumbnailData(
          video: entry.streamUrl!,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 160,
          quality: 72,
        );
        if (generated != null) {
          bytes = generated;
          await cacheFile.writeAsBytes(generated);
        }
      } catch (_) {}
    }

    if (bytes != null && mounted) setState(() => entry.thumbnail = bytes);
  }

  /* ──────────────────────── Player ───────────────────────────────────────── */

  Future<void> _openOwnPlayer(_VideoEntry entry) async {
    await _playerController?.dispose();
    setState(() {
      _playingOwn = entry;
      _playingShared = null;
      _playerReady = false;
      _showControls = true;
    });

    final ctrl = VideoPlayerController.file(entry.file);
    _playerController = ctrl;
    await ctrl.initialize();
    if (!mounted) return;

    ctrl.addListener(() {
      if (mounted) setState(() {});
    });
    setState(() => _playerReady = true);
    await ctrl.play();
  }

  Future<void> _openSharedPlayer(_SharedEntry entry) async {
    final url = entry.streamUrl;
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Video not ready yet — try again shortly',
            style: TextStyle(color: _textPrimary),
          ),
          backgroundColor: _sharedBgRow,
        ),
      );
      return;
    }

    await _playerController?.dispose();
    setState(() {
      _playingShared = entry;
      _playingOwn = null;
      _playerReady = false;
      _showControls = true;
    });

    final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
    _playerController = ctrl;
    await ctrl.initialize();
    if (!mounted) return;

    ctrl.addListener(() {
      if (mounted) setState(() {});
    });
    setState(() => _playerReady = true);
    await ctrl.play();
  }

  Future<void> _closePlayer() async {
    final ctrl = _playerController;
    _playerController = null;

    if (mounted) {
      setState(() {
        _playingOwn = null;
        _playingShared = null;
        _playerReady = false;
      });
    }

    try {
      await ctrl?.pause();
      ctrl?.dispose();
    } catch (_) {}
  }

  void _toggleControls() => setState(() => _showControls = !_showControls);

  void _togglePlayPause() {
    final ctrl = _playerController;
    if (ctrl == null) return;
    ctrl.value.isPlaying ? ctrl.pause() : ctrl.play();
    setState(() {});
  }

  /* ──────────────────────── Formatting ───────────────────────────────────── */

  String _formatDate(File f) {
    try {
      final dt = f.lastModifiedSync();
      return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)}  '
          '${_pad(dt.hour)}:${_pad(dt.minute)}';
    } catch (_) {
      return '';
    }
  }

  String _formatDateFromDt(DateTime? dt) {
    if (dt == null) return '';
    return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)}  '
        '${_pad(dt.hour)}:${_pad(dt.minute)}';
  }

  String _formatSize(File f) {
    try {
      final bytes = f.lengthSync();
      return bytes < 1024 * 1024
          ? '${(bytes / 1024).toStringAsFixed(1)} KB'
          : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } catch (_) {
      return '';
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  /* ──────────────────────── Build ─────────────────────────────────────────── */

  @override
  Widget build(BuildContext context) {
    final isPlaying = _playingOwn != null || _playingShared != null;

    return Scaffold(
      backgroundColor: _bgPage,
      appBar:
          isPlaying
              ? null
              : AppBar(
                backgroundColor: _bgAppBar,
                foregroundColor: _textPrimary,
                title: const Text(
                  'Videos',
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w600,
                    color: _textPrimary,
                  ),
                ),
                bottom: TabBar(
                  controller: _tabController,
                  indicatorColor: _playerThumb,
                  indicatorWeight: 2,
                  labelColor: _textPrimary,
                  unselectedLabelColor: const Color(0xFF7A7068),
                  labelStyle: const TextStyle(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    letterSpacing: 0.3,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w400,
                    fontSize: 13,
                  ),
                  tabs: const [
                    Tab(text: 'My Videos'),
                    Tab(text: 'Shared Sessions'),
                  ],
                ),
              ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tabController,
            children: [_buildOwnTab(), _buildSharedTab()],
          ),
          if (isPlaying) _buildPlayerOverlay(context),
        ],
      ),
    );
  }

  /* ──────────────────────── My Videos tab ────────────────────────────────── */

  Widget _buildOwnTab() {
    if (_loadingOwn) {
      return const Center(
        child: CircularProgressIndicator(color: _ownIconAccent),
      );
    }
    if (_entries.isEmpty) {
      return const Center(
        child: Text(
          'No videos yet',
          style: TextStyle(color: _ownTextMuted, fontSize: 16),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _entries.length,
      separatorBuilder:
          (_, __) => const Divider(color: _ownDivider, height: 1, indent: 80),
      itemBuilder: (_, i) => _buildOwnRow(_entries[i]),
    );
  }

  Widget _buildOwnRow(_VideoEntry entry) {
    final name = entry.file.path.split('/').last;
    return Material(
      color: _ownBgRow,
      child: InkWell(
        onTap: () => _openOwnPlayer(entry),
        splashColor: _ownSplash,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 72,
                  height: 54,
                  child:
                      entry.thumbnail != null
                          ? Image.memory(entry.thumbnail!, fit: BoxFit.cover)
                          : Container(
                            color: _ownBgThumb,
                            child: const Icon(
                              Icons.videocam,
                              color: _ownIconAccent,
                              size: 28,
                            ),
                          ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: _ownTextPrimary,
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_formatDate(entry.file)}  ·  ${_formatSize(entry.file)}',
                      style: const TextStyle(
                        color: _ownTextSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _buildBadge(
                    icon: Icons.phone_android,
                    label: 'Local',
                    bg: _ownLocalBadgeBg,
                    textColor: _ownLocalBadgeText,
                  ),
                  if (entry.hasSession) ...[
                    const SizedBox(height: 6),
                    _buildSentStatusBadge(entry.effectiveStatus!),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /* ──────────────────────── Shared Sessions tab ───────────────────────────── */

  Widget _buildSharedTab() {
    if (_loadingShared) {
      return const Center(
        child: CircularProgressIndicator(color: _sharedIconAccent),
      );
    }
    if (_shared.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.group_outlined, color: _sharedTextMuted, size: 48),
            const SizedBox(height: 12),
            const Text(
              'No shared sessions yet',
              style: TextStyle(color: _sharedTextSecondary, fontSize: 16),
            ),
            const SizedBox(height: 6),
            const Text(
              'Videos sent to you will appear here',
              style: TextStyle(color: _sharedTextMuted, fontSize: 13),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _shared.length,
      separatorBuilder:
          (_, __) =>
              const Divider(color: _sharedDivider, height: 1, indent: 80),
      itemBuilder: (_, i) => _buildSharedRow(_shared[i]),
    );
  }

  Widget _buildSharedRow(_SharedEntry entry) {
    final status = entry.effectiveStatus;
    final isReady = entry.streamUrl != null;
    final sender =
        entry.senderName.isNotEmpty ? entry.senderName : entry.hostUid;

    return Material(
      color: _sharedBgRow,
      child: InkWell(
        onTap: () => _openSharedPlayer(entry),
        splashColor: _sharedSplash,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              // ── Thumbnail ──────────────────────────────────────────────
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 72,
                  height: 54,
                  child:
                      entry.thumbnail != null
                          ? Image.memory(entry.thumbnail!, fit: BoxFit.cover)
                          : Container(
                            color: _sharedBgThumb,
                            child:
                                isReady
                                    ? const Icon(
                                      Icons.play_circle_outline,
                                      color: _sharedIconAccent,
                                      size: 30,
                                    )
                                    : const Center(
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 1.5,
                                          color: _sharedTextMuted,
                                        ),
                                      ),
                                    ),
                          ),
                ),
              ),
              const SizedBox(width: 12),

              // ── Text column ────────────────────────────────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.person_outline,
                          color: _sharedIconAccent,
                          size: 13,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            sender,
                            style: const TextStyle(
                              color: _sharedTextPrimary,
                              fontFamily: 'Montserrat',
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if ((entry.message ?? entry.listTitle ?? '')
                        .isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        entry.message ?? entry.listTitle ?? '',
                        style: const TextStyle(
                          color: _sharedTextSecondary,
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      _formatDateFromDt(entry.createdAt),
                      style: const TextStyle(
                        color: _sharedTextMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),

              // ── Badge column ───────────────────────────────────────────
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _buildStatusBadge(status, hasStream: isReady),
                  if (isReady) ...[
                    const SizedBox(height: 6),
                    _buildDownloadButton(entry),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /* ──────────────────────── Status badge ─────────────────────────────────── */

  /// Renders the contextual status badge for a shared session.
  ///
  /// States and their meaning:
  ///   uploading  — chunks are actively arriving; more footage is coming
  ///   stalled    — chunk stream went quiet for >30s but session isn't done;
  ///                likely a connectivity interruption mid-recording
  ///   completed  — stitching finished; this is the full video
  ///   live/other — session exists but no chunks yet (just created)
  ///   fallback   — stream URL present but status not yet resolved
  Widget _buildStatusBadge(_SessionStatus status, {required bool hasStream}) {
    switch (status) {
      case _SessionStatus.uploading:
        return _buildBadge(
          icon: Icons.cloud_upload_outlined,
          label: 'Uploading',
          bg: _badgeUploadingBg,
          textColor: _badgeUploadingText,
          pulse: true,
        );
      case _SessionStatus.stalled:
        return _buildBadge(
          icon: Icons.cloud_off_outlined,
          label: 'Stalled',
          bg: _badgeStalledBg,
          textColor: _badgeStalledText,
        );
      case _SessionStatus.completed:
        return _buildBadge(
          icon: Icons.cloud_done_outlined,
          label: 'Completed',
          bg: _badgeCompletedBg,
          textColor: _badgeCompletedText,
        );
      case _SessionStatus.live:
        // Session created, no chunks uploaded yet.
        if (hasStream) {
          return _buildBadge(
            icon: Icons.cloud_done_outlined,
            label: 'Ready',
            bg: _badgeReadyBg,
            textColor: _badgeReadyText,
          );
        }
        return _buildBadge(
          icon: Icons.cloud_outlined,
          label: 'Waiting',
          bg: _badgeLoadingBg,
          textColor: _badgeLoadingText,
        );
    }
  }

  /// Renders the second badge for a video the user recorded and sent.
  ///
  /// States and their meaning:
  ///   uploading  — chunks are still being sent to the server
  ///   stalled    — upload went quiet for >30s but session isn't completed;
  ///                likely a connectivity interruption mid-upload
  ///   completed  — stitching finished; a full copy lives on the server
  ///   live       — session created but no chunks uploaded yet
  Widget _buildSentStatusBadge(_SessionStatus status) {
    switch (status) {
      case _SessionStatus.uploading:
        return _buildBadge(
          icon: Icons.cloud_upload_outlined,
          label: 'Uploading',
          bg: _badgeUploadingBg,
          textColor: _badgeUploadingText,
          pulse: true,
        );
      case _SessionStatus.stalled:
        return _buildBadge(
          icon: Icons.cloud_off_outlined,
          label: 'Stalled',
          bg: _badgeStalledBg,
          textColor: _badgeStalledText,
        );
      case _SessionStatus.completed:
        return _buildBadge(
          icon: Icons.cloud_done_outlined,
          label: 'Server',
          bg: _ownServerBadgeBg,
          textColor: _ownServerBadgeText,
        );
      case _SessionStatus.live:
        return _buildBadge(
          icon: Icons.cloud_outlined,
          label: 'Uploading',
          bg: _badgeUploadingBg,
          textColor: _badgeUploadingText,
          pulse: true,
        );
    }
  }

  /* ──────────────────────── Player overlay ────────────────────────────────── */

  Widget _buildPlayerOverlay(BuildContext context) {
    final ctrl = _playerController;
    final position = ctrl?.value.position ?? Duration.zero;
    final total = ctrl?.value.duration ?? Duration.zero;
    final progress =
        total.inMilliseconds > 0
            ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
            : 0.0;
    final isPlaying = ctrl?.value.isPlaying ?? false;

    String displayName = '';
    if (_playingOwn != null) {
      displayName = _playingOwn!.file.path.split('/').last;
    } else if (_playingShared != null) {
      final s = _playingShared!;
      displayName = s.senderName.isNotEmpty ? s.senderName : s.hostUid;
      if (s.message != null && s.message!.isNotEmpty) {
        displayName += '  ·  ${s.message}';
      }
    }

    return GestureDetector(
      onTap: _closePlayer,
      child: Container(
        color: const Color(0xED0A0602),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 60),

              // ── Geolocation banner ──────────────────────────────────────
              if (_playingShared?.geolocation != null) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GestureDetector(
                    onTap: () async {
                      await Clipboard.setData(
                        ClipboardData(text: _playingShared!.geolocation!),
                      );
                      if (!mounted) return;
                      _showSnack(
                        icon: Icons.check_circle_outline,
                        iconColor: _snackSuccessIcon,
                        text: 'Coordinates copied to clipboard',
                        bg: _snackSuccessBg,
                      );
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: _geoBannerBg.withOpacity(0.85),
                        border: Border.all(color: _geoBannerBorder, width: 1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.location_on,
                            color: _geoText,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _playingShared!.geolocation!,
                              style: const TextStyle(
                                color: _geoText,
                                fontSize: 13,
                                fontFamily: 'Montserrat',
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.copy, color: _geoCopyIcon, size: 14),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],

              // ── Video frame ─────────────────────────────────────────────
              Expanded(
                child: LayoutBuilder(
                  builder:
                      (context, constraints) => GestureDetector(
                        onTap: _toggleControls,
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: constraints.maxHeight - 16,
                            ),
                            child: Container(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: const Color(0x33FE7E00),
                                  width: 1,
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: AspectRatio(
                                aspectRatio:
                                    (_playerReady && ctrl != null)
                                        ? ctrl.value.aspectRatio
                                        : 16 / 9,
                                child:
                                    _playerReady && ctrl != null
                                        ? VideoPlayer(ctrl)
                                        : const Center(
                                          child: CircularProgressIndicator(
                                            color: _sharedIconAccent,
                                          ),
                                        ),
                              ),
                            ),
                          ),
                        ),
                      ),
                ),
              ),

              const SizedBox(height: 12),

              // ── Controls ────────────────────────────────────────────────
              AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 220),
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        Text(
                          displayName,
                          style: const TextStyle(
                            color: _textPrimary,
                            fontFamily: 'Montserrat',
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),

                        const SizedBox(height: 14),

                        if (_playerReady && ctrl != null) ...[
                          SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 14,
                              ),
                              activeTrackColor: _playerThumb,
                              inactiveTrackColor: const Color(0x33FE7E00),
                              thumbColor: _playerThumb,
                              overlayColor: const Color(0x33FE7E00),
                            ),
                            child: Slider(
                              value: progress,
                              onChanged: (v) {
                                final ms = (v * total.inMilliseconds).round();
                                ctrl.seekTo(Duration(milliseconds: ms));
                              },
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _formatDuration(position),
                                  style: const TextStyle(
                                    color: Color(0xFF8A6040),
                                    fontSize: 11,
                                  ),
                                ),
                                Text(
                                  _formatDuration(total),
                                  style: const TextStyle(
                                    color: Color(0xFF8A6040),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],

                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _iconButton(Icons.close, _closePlayer, size: 22),
                            const SizedBox(width: 28),
                            GestureDetector(
                              onTap: _togglePlayPause,
                              child: Container(
                                width: 62,
                                height: 62,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0x1AFE7E00),
                                  border: Border.all(
                                    color: const Color(0x66FE7E00),
                                    width: 1.5,
                                  ),
                                ),
                                child: Icon(
                                  isPlaying ? Icons.pause : Icons.play_arrow,
                                  color: _playerThumb,
                                  size: 34,
                                ),
                              ),
                            ),
                            const SizedBox(width: 28),
                            _iconButton(Icons.replay, () {
                              ctrl?.seekTo(Duration.zero);
                              ctrl?.play();
                            }, size: 22),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 60),
            ],
          ),
        ),
      ),
    );
  }

  /* ──────────────────────── Shared widgets ───────────────────────────────── */

  Widget _iconButton(IconData icon, VoidCallback onTap, {double size = 24}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0x1AFE7E00),
          border: Border.all(color: const Color(0x33FE7E00), width: 1),
        ),
        child: Icon(icon, color: _ownTextSecondary, size: size),
      ),
    );
  }

  Widget _buildDownloadButton(_SharedEntry entry) {
    return GestureDetector(
      onTap: () => _downloadShared(entry),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: _dlBg.withOpacity(0.5),
          border: Border.all(color: _dlBorder, width: 1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry.isDownloading)
              const SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: _dlText,
                ),
              )
            else
              const Icon(Icons.download_outlined, color: _dlText, size: 12),
            const SizedBox(width: 4),
            Text(
              entry.isDownloading ? 'Saving…' : 'Save',
              style: const TextStyle(
                color: _dlText,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBadge({
    required IconData icon,
    required String label,
    required Color bg,
    required Color textColor,
    bool pulse = false,
  }) {
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg.withOpacity(0.35),
        border: Border.all(color: bg, width: 1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: textColor, size: 12),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: textColor,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );

    // Uploading badge gets a subtle animated opacity pulse so it reads
    // as "live" without being distracting.
    if (pulse) return _PulseBadge(child: badge);
    return badge;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Subtle opacity pulse for the Uploading badge.
// Cycles between full opacity and 55% over 1.4 seconds.
// ─────────────────────────────────────────────────────────────────────────────

class _PulseBadge extends StatefulWidget {
  final Widget child;
  const _PulseBadge({required this.child});

  @override
  State<_PulseBadge> createState() => _PulseBadgeState();
}

class _PulseBadgeState extends State<_PulseBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _opacity = Tween<double>(
      begin: 1.0,
      end: 0.55,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _opacity, child: widget.child);
}
