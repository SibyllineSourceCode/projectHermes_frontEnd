import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../utils/video_storage_utils.dart';
import '../services/auth_service.dart';

// ── Colours ──────────────────────────────────────────────────────────────────

const _syncedBadgeBg   = Color(0xFF1E6B9E);
const _syncedBadgeText = Color(0xFFADD8F7);
const _localBg         = Color(0xFF2A2020);
const _localBadgeBg    = Color(0xFF7A3B1E);
const _localBadgeText  = Color(0xFFF7C9AD);
const _sharedBg        = Color(0xFF1A2030);
const _sharedBadgeBg   = Color(0xFF1E4D6B);
const _sharedBadgeText = Color(0xFFADD8F7);

// ─────────────────────────────────────────────────────────────────────────────

/// A local video entry carrying its file, sync status, and lazily-loaded thumbnail.
class _VideoEntry {
  final File file;
  final bool isLocal;
  final bool isServer;
  Uint8List? thumbnail;
  bool thumbnailAttempted = false;

  _VideoEntry({required this.file, required this.isLocal, required this.isServer});
}

/// A shared session entry from another user's SOS broadcast.
class _SharedEntry {
  final String sessionId;
  final String hostUid;
  String senderName = '';         // resolved async
  final String? message;
  final String? listTitle;
  final DateTime? createdAt;
  final String? finalStoragePath;
  String? streamUrl;         // resolved async (signed GCS URL)
  bool urlAttempted = false;

  _SharedEntry({
    required this.sessionId,
    required this.hostUid,
    this.message,
    this.listTitle,
    this.createdAt,
    this.finalStoragePath,
  });
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

  // ── Tab controller ──────────────────────────────────────────────────────────
  late final TabController _tabController;

  // ── My Videos state ────────────────────────────────────────────────────────
  List<_VideoEntry> _entries = [];
  bool _loadingOwn = true;
  Directory? _thumbCacheDir;

  // ── Shared Sessions state ───────────────────────────────────────────────────
  List<_SharedEntry> _shared = [];
  bool _loadingShared = true;

  // ── Player state (shared across both tabs) ──────────────────────────────────
  _VideoEntry?   _playingOwn;
  _SharedEntry?  _playingShared;
  VideoPlayerController? _playerController;
  bool _playerReady   = false;
  bool _showControls  = true;

  /* ──────────────────────── Init / dispose ────────────────────────────────── */

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initOwnVideos();
    _initSharedSessions();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _playerController?.dispose();
    super.dispose();
  }

  /* ──────────────────────── My Videos loading ─────────────────────────────── */

  Future<void> _initOwnVideos() async {
    final currentUser   = await AuthService.instance.api.me();
    final stitchResult  = await AuthService.instance.api.finalizeUser(userId: currentUser['uid']);

    final serverSosIds = (stitchResult['finalized'] as List<dynamic>? ?? [])
        .where((v) => v['ok'] == true && v['finalStoragePath'] != null)
        .map((v) {
          final parts = (v['finalStoragePath'] as String).split('/');
          return parts.length >= 2 ? parts[1] : null;
        })
        .whereType<String>()
        .toSet();

    final docs = await getApplicationDocumentsDirectory();
    _thumbCacheDir = Directory(p.join(docs.path, 'sos_video_thumbs'));
    if (!await _thumbCacheDir!.exists()) {
      await _thumbCacheDir!.create(recursive: true);
    }

    final diskVideos = await VideoStorageUtils.instance.loadFinalVideos();

    final entries = diskVideos.map((f) {
      final isServer = serverSosIds.any((id) => f.path.contains(id));
      return _VideoEntry(file: f, isLocal: true, isServer: isServer);
    }).toList();

    entries.sort((a, b) =>
        b.file.lastModifiedSync().compareTo(a.file.lastModifiedSync()));

    if (!mounted) return;
    setState(() { _entries = entries; _loadingOwn = false; });

    for (final e in _entries) { _loadThumbnail(e); }
  }

  /* ──────────────────────── Shared Sessions loading ───────────────────────── */

  Future<void> _initSharedSessions() async {
    try {
      final currentUser = await AuthService.instance.api.me();
      final uid = currentUser['uid'] as String;

      // 1. Read included_sessions from the user's meta doc
      final metaSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('meta')
          .doc('included_sessions')
          .get();

      if (!metaSnap.exists || metaSnap.data() == null) {
        if (mounted) setState(() => _loadingShared = false);
        return;
      }

      // Keys are session IDs, values are `true`
      final sessionIds = metaSnap.data()!.keys.toList();
      if (sessionIds.isEmpty) {
        if (mounted) setState(() => _loadingShared = false);
        return;
      }

      // 2. Fetch each sos_session doc (batch in groups of 10 for Firestore whereIn limit)
      final List<_SharedEntry> results = [];
      for (var i = 0; i < sessionIds.length; i += 10) {
        final chunk = sessionIds.sublist(i,
            (i + 10 < sessionIds.length) ? i + 10 : sessionIds.length);
        final snap = await FirebaseFirestore.instance
            .collection('sos_sessions')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();

        for (final doc in snap.docs) {
          final d = doc.data();
          final ts = d['createdAt'];
          results.add(_SharedEntry(
            sessionId:        doc.id,
            hostUid:          (d['hostUid'] as String?) ?? '',
            message:          d['message'] as String?,
            listTitle:        d['listTitle'] as String?,
            finalStoragePath: d['finalStoragePath'] as String?,
            createdAt: ts is Timestamp ? ts.toDate() : null,
          ));
        }
      }

      // Sort newest first
      results.sort((a, b) {
        if (a.createdAt == null && b.createdAt == null) return 0;
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });

      if (!mounted) return;
      setState(() { _shared = results; _loadingShared = false; });

      // 3. Resolve sender usernames + stream URLs lazily
      for (final entry in _shared) {
        _resolveSenderName(entry);
        _resolveStreamUrl(entry);
      }
    } catch (e) {
      debugPrint('[SharedSessions] load error: $e');
      if (mounted) setState(() => _loadingShared = false);
    }
  }

  Future<void> _resolveSenderName(_SharedEntry entry) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(entry.hostUid)
          .get();
      final username = snap.data()?['username'] as String?;
      if (username != null && mounted) {
        setState(() => entry.senderName = username);
      }
    } catch (_) {}
  }

  Future<void> _resolveStreamUrl(_SharedEntry entry) async {
    if (entry.urlAttempted || entry.finalStoragePath == null) return;
    entry.urlAttempted = true;
    try {
      final ref = FirebaseStorage.instance.ref(entry.finalStoragePath!);
      final url = await ref.getDownloadURL();
      if (mounted) setState(() => entry.streamUrl = url);
    } catch (e) {
      debugPrint('[SharedSessions] URL resolve error for ${entry.sessionId}: $e');
    }
  }

  /* ──────────────────────── Thumbnails ───────────────────────────────────── */

  Future<void> _loadThumbnail(_VideoEntry entry) async {
    if (entry.thumbnailAttempted) return;
    entry.thumbnailAttempted = true;

    final cacheDir = _thumbCacheDir;
    if (cacheDir == null) return;

    final cacheKey  = entry.file.path.hashCode.toRadixString(16);
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

    if (bytes != null && mounted) {
      setState(() => entry.thumbnail = bytes);
    }
  }

  /* ──────────────────────── Player ───────────────────────────────────────── */

  Future<void> _openOwnPlayer(_VideoEntry entry) async {
    await _playerController?.dispose();
    setState(() {
      _playingOwn    = entry;
      _playingShared = null;
      _playerReady   = false;
      _showControls  = true;
    });

    final ctrl = VideoPlayerController.file(entry.file);
    _playerController = ctrl;
    await ctrl.initialize();
    if (!mounted) return;

    ctrl.addListener(() { if (mounted) setState(() {}); });
    setState(() => _playerReady = true);
    await ctrl.play();
  }

  Future<void> _openSharedPlayer(_SharedEntry entry) async {
    final url = entry.streamUrl;
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Video not ready yet — try again shortly'),
          backgroundColor: Color(0xFF2A2020),
        ),
      );
      return;
    }

    await _playerController?.dispose();
    setState(() {
      _playingShared = entry;
      _playingOwn    = null;
      _playerReady   = false;
      _showControls  = true;
    });

    final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
    _playerController = ctrl;
    await ctrl.initialize();
    if (!mounted) return;

    ctrl.addListener(() { if (mounted) setState(() {}); });
    setState(() => _playerReady = true);
    await ctrl.play();
  }

  Future<void> _closePlayer() async {
    final ctrl = _playerController;
    _playerController = null;

    if (mounted) {
      setState(() {
        _playingOwn    = null;
        _playingShared = null;
        _playerReady   = false;
      });
    }

    try {
      await ctrl?.pause();
      ctrl?.dispose();
    } catch (_) {}
  }

  void _toggleControls()   => setState(() => _showControls = !_showControls);
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
    } catch (_) { return ''; }
  }

  String _formatDateFromDt(DateTime? dt) {
    if (dt == null) return '';
    return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)}  '
        '${_pad(dt.hour)}:${_pad(dt.minute)}';
  }

  String _formatSize(File f) {
    try {
      final bytes = f.lengthSync();
      if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } catch (_) { return ''; }
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
      backgroundColor: const Color.fromARGB(255, 54, 53, 53),
      appBar: isPlaying
          ? null
          : AppBar(
              backgroundColor: const Color.fromARGB(255, 40, 40, 40),
              foregroundColor: Colors.white,
              title: const Text(
                'Videos',
                style: TextStyle(
                    fontFamily: 'Montserrat', fontWeight: FontWeight.w600),
              ),
              bottom: TabBar(
                controller: _tabController,
                indicatorColor: Colors.white,
                indicatorWeight: 2,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white38,
                labelStyle: const TextStyle(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    letterSpacing: 0.3),
                unselectedLabelStyle: const TextStyle(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w400,
                    fontSize: 13),
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
            children: [
              _buildOwnTab(),
              _buildSharedTab(),
            ],
          ),
          if (isPlaying) _buildPlayerOverlay(context),
        ],
      ),
    );
  }

  /* ──────────────────────── My Videos tab ────────────────────────────────── */

  Widget _buildOwnTab() {
    if (_loadingOwn) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_entries.isEmpty) {
      return const Center(
        child: Text('No videos yet',
            style: TextStyle(color: Color(0xFF959393), fontSize: 16)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _entries.length,
      separatorBuilder: (_, __) =>
          const Divider(color: Color(0xFF3A3A3A), height: 1, indent: 80),
      itemBuilder: (_, i) => _buildOwnRow(_entries[i]),
    );
  }

  Widget _buildOwnRow(_VideoEntry entry) {
    final name = entry.file.path.split('/').last;

    return Material(
      color: _localBg,
      child: InkWell(
        onTap: () => _openOwnPlayer(entry),
        splashColor: Colors.white10,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              // Thumbnail
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 72, height: 54,
                  child: entry.thumbnail != null
                      ? Image.memory(entry.thumbnail!, fit: BoxFit.cover)
                      : Container(
                          color: const Color(0xFF978B8B).withOpacity(0.25),
                          child: const Icon(Icons.videocam,
                              color: Colors.white38, size: 28),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              // Title + meta
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text(
                      '${_formatDate(entry.file)}  ·  ${_formatSize(entry.file)}',
                      style: const TextStyle(
                          color: Color(0xFF959393), fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Badges
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildBadge(
                    icon: Icons.phone_android,
                    label: 'Local',
                    bg: _localBadgeBg,
                    textColor: _localBadgeText,
                  ),
                  if (entry.isServer) ...[
                    const SizedBox(width: 6),
                    _buildBadge(
                      icon: Icons.cloud_done_outlined,
                      label: 'Server',
                      bg: _syncedBadgeBg,
                      textColor: _syncedBadgeText,
                    ),
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
      return const Center(child: CircularProgressIndicator());
    }
    if (_shared.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.group_outlined, color: Color(0xFF595959), size: 48),
            SizedBox(height: 12),
            Text('No shared sessions yet',
                style: TextStyle(color: Color(0xFF959393), fontSize: 16)),
            SizedBox(height: 6),
            Text('Videos sent to you will appear here',
                style: TextStyle(color: Color(0xFF595959), fontSize: 13)),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _shared.length,
      separatorBuilder: (_, __) =>
          const Divider(color: Color(0xFF2A3040), height: 1, indent: 80),
      itemBuilder: (_, i) => _buildSharedRow(_shared[i]),
    );
  }

  Widget _buildSharedRow(_SharedEntry entry) {
    final isReady   = entry.streamUrl != null;
    final sender    = entry.senderName.isNotEmpty ? entry.senderName : entry.hostUid;
    final dateStr   = _formatDateFromDt(entry.createdAt);
    final subtitle  = entry.message ?? entry.listTitle ?? '';

    return Material(
      color: _sharedBg,
      child: InkWell(
        onTap: () => _openSharedPlayer(entry),
        splashColor: Colors.white10,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              // Avatar / placeholder thumbnail
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 72, height: 54,
                  color: const Color(0xFF1A3050).withOpacity(0.6),
                  child: isReady
                      ? const Icon(Icons.play_circle_outline,
                          color: Colors.white54, size: 30)
                      : const Center(
                          child: SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: Colors.white24,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              // Title + meta
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.person_outline,
                            color: Color(0xFF6B9EC8), size: 13),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            sender,
                            style: const TextStyle(
                              color: Colors.white,
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
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                            color: Color(0xFF8AAFC8),
                            fontSize: 12,
                            fontStyle: FontStyle.italic),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      dateStr,
                      style: const TextStyle(
                          color: Color(0xFF595D70), fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Badge
              _buildBadge(
                icon: isReady ? Icons.cloud_done_outlined : Icons.cloud_outlined,
                label: isReady ? 'Ready' : 'Loading',
                bg: isReady ? _sharedBadgeBg : const Color(0xFF3A3A3A),
                textColor: isReady ? _sharedBadgeText : Colors.white38,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /* ──────────────────────── Player overlay ────────────────────────────────── */

  Widget _buildPlayerOverlay(BuildContext context) {
    final ctrl     = _playerController;
    final position = ctrl?.value.position ?? Duration.zero;
    final total    = ctrl?.value.duration  ?? Duration.zero;
    final progress = total.inMilliseconds > 0
        ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final isPlaying = ctrl?.value.isPlaying ?? false;

    // Title line shown in controls
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
        color: Colors.black.withOpacity(0.90),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 60),

              // ── Video frame ────────────────────────────────────────────
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => GestureDetector(
                    onTap: _toggleControls,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: constraints.maxHeight - 16),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.7),
                                blurRadius: 40,
                                spreadRadius: 6,
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: AspectRatio(
                            aspectRatio: (_playerReady && ctrl != null)
                                ? ctrl.value.aspectRatio
                                : 16 / 9,
                            child: _playerReady && ctrl != null
                                ? VideoPlayer(ctrl)
                                : const Center(
                                    child: CircularProgressIndicator(
                                        color: Colors.white54)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // ── Controls ───────────────────────────────────────────────
              AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 220),
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        Text(displayName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontFamily: 'Montserrat',
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center),

                        const SizedBox(height: 14),

                        if (_playerReady && ctrl != null) ...[
                          SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6),
                              overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 14),
                              activeTrackColor: Colors.white,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: Colors.white,
                              overlayColor: Colors.white24,
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
                                Text(_formatDuration(position),
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 11)),
                                Text(_formatDuration(total),
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 11)),
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
                                width: 62, height: 62,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white.withOpacity(0.14),
                                  border: Border.all(
                                      color: Colors.white38, width: 1.5),
                                ),
                                child: Icon(
                                  isPlaying ? Icons.pause : Icons.play_arrow,
                                  color: Colors.white,
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
        width: 44, height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.10),
          border: Border.all(color: Colors.white24, width: 1),
        ),
        child: Icon(icon, color: Colors.white70, size: size),
      ),
    );
  }

  Widget _buildBadge({
    required IconData icon,
    required String label,
    required Color bg,
    required Color textColor,
  }) {
    return Container(
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
          Text(label,
              style: TextStyle(
                  color: textColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3)),
        ],
      ),
    );
  }
}