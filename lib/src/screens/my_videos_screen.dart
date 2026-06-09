import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
// import 'package:cloud_firestore/cloud_firestore.dart';
// import 'package:firebase_storage/firebase_storage.dart';
import '../utils/video_storage_utils.dart';
import '../services/auth_service.dart';

// ── Beacon Brand Palette ─────────────────────────────────────────────────────
//
//  Original brand
//    #000000  Black
//    #060300  Near-black
//    #170B00  Deep brown
//    #FE7E00  Beacon orange
//    #686868  Mid gray
//
//  Extended palette (warm tones derived from brand)
//
//  Ember (warm neutral surfaces — from #170B00 lightened with warmth)
//    Ember50   #FAF6F0   card / page backgrounds
//    Ember100  #EDE4D8   surface tint
//    Ember200  #D4C5B0   dividers
//    Ember400  #A8917A   muted mid-tone
//    Ember600  #6B5544   dark warm surface
//    Ember800  #3A2518   near-dark background
//    Ember900  #1E1008   near-black warm
//
//  Flame (muted amber accents — desaturated from #FE7E00)
//    Flame50   #FFF5E6   very pale orange tint
//    Flame100  #FFE0B0   ghost orange (badge bg)
//    Flame200  #FFC875   soft amber (borders, dividers)
//    Flame400  #F59B30   secondary accent
//    Flame600  #C06A00   strong accent
//    Flame800  #7A4000   dark accent
//    Flame900  #4A2200   deepest accent
//
//  Smoke (warm charcoal — #686868 with warm undertone)
//    Smoke50   #F5F2EE   lightest warm gray
//    Smoke100  #D8D0C8   light warm gray
//    Smoke200  #B0A89E   mid warm gray
//    Smoke400  #7A7068   secondary text
//    Smoke600  #484038   dark warm gray
//    Smoke800  #282018   primary text on light bg
//    Smoke900  #140E08   deepest warm charcoal
//
// ─────────────────────────────────────────────────────────────────────────────

// ── Global / shared ──────────────────────────────────────────────────────────
const _bgPage = Color(0xFF0E0C0A); // near-black warm — scaffold
const _bgAppBar = Color(0xFF140E08); // Smoke900 — appbar
const _textPrimary = Color(0xFFF5F2EE); // Smoke50
const _playerThumb = Color(0xFFFE7E00); // Brand orange — hero accent

// ── MY VIDEOS — Charcoal / wood ──────────────────────────────────────────────
//  Feel: cool-warm dark gray, like charred wood grain. Personal, local, grounded.
const _ownBgRow = Color(0xFF1E1C18); // dark warm charcoal
const _ownBgThumb = Color(0xFF2E2A24); // slightly lighter charcoal
const _ownDivider = Color(0xFF2A2820); // subtle warm-gray line
const _ownTextPrimary = Color(0xFFE8E4DC); // warm off-white
const _ownTextSecondary = Color(0xFFB0A89E); // Smoke200
const _ownTextMuted = Color(0xFF7A7068); // Smoke400
const _ownIconAccent = Color(0xFFA8917A); // Ember400 — warm gray-brown
const _ownSplash = Color(0x0FFFFFFF); // white @6%
// "Local" badge
const _ownLocalBadgeBg = Color(0xFF3A3228); // dark charcoal
const _ownLocalBadgeText = Color(0xFFD8D0C8); // Smoke100
// "Server" badge — a touch of amber so it reads as "synced" without going full orange
const _ownServerBadgeBg = Color(0xFF4A3010); // dark amber-brown
const _ownServerBadgeText = Color(0xFFFFC875); // Flame200

// ── SHARED SESSIONS — Soft ember / firelight ─────────────────────────────────
//  Feel: warm brown glow, amber accents, like embers in low light. Incoming, alive.
const _sharedBgRow = Color(0xFF201408); // deep warm brown
const _sharedBgThumb = Color(0xFF2E1A08); // Ember800-ish
const _sharedDivider = Color(0xFF3A2010); // Ember800 warm
const _sharedTextPrimary = Color(0xFFFAF0E0); // warm cream
const _sharedTextSecondary = Color(0xFFD4A870); // muted gold
const _sharedTextMuted = Color(0xFF8A6040); // dim amber-brown
const _sharedIconAccent = Color(0xFFF59B30); // Flame400
const _sharedSplash = Color(0x1AFE7E00); // brand orange @10%
// "Ready" badge
const _sharedReadyBadgeBg = Color(0xFF4A2200); // Flame900
const _sharedReadyBadgeText = Color(0xFFFFC875); // Flame200
// "Loading" badge
const _sharedLoadingBadgeBg = Color(0xFF2A1C10);
const _sharedLoadingBadgeText = Color(0xFF8A6040);
// Download button
const _dlBg = Color(0xFF2A1C10);
const _dlBorder = Color(0xFFF59B30); // Flame400
const _dlText = Color(0xFFFFC875); // Flame200

// ── Geolocation banner (player overlay — shared context) ─────────────────────
const _geoBannerBg = Color(0xFF2A1C10);
const _geoBannerBorder = Color(0xFFC06A00); // Flame600
const _geoText = Color(0xFFFFC875); // Flame200
const _geoCopyIcon = Color(0xFFF59B30); // Flame400

// ── Snackbars ────────────────────────────────────────────────────────────────
const _snackSuccessBg = Color(0xFF2A1C10);
const _snackSuccessIcon = Color(0xFFFFC875);
const _snackErrorBg = Color(0xFF3A1A08);
const _snackErrorIcon = Color(0xFFFFE0B0);

// ─────────────────────────────────────────────────────────────────────────────

/// A local video entry carrying its file, sync status, and lazily-loaded thumbnail.
class _VideoEntry {
  final File file;
  final bool isLocal;
  final bool isServer;
  Uint8List? thumbnail;
  bool thumbnailAttempted = false;

  _VideoEntry({
    required this.file,
    required this.isLocal,
    required this.isServer,
  });
}

/// A shared session entry from another user's SOS broadcast.
class _SharedEntry {
  final String sessionId;
  final String hostUid;
  String senderName = '';
  final String? message;
  final String? listTitle;
  final DateTime? createdAt;
  final String? finalStoragePath;
  final String? geolocation;
  String? streamUrl;
  bool urlAttempted = false;
  Uint8List? thumbnail;
  bool thumbnailAttempted = false;
  bool isDownloading = false;

  _SharedEntry({
    required this.sessionId,
    required this.hostUid,
    this.message,
    this.listTitle,
    this.createdAt,
    this.finalStoragePath,
    this.streamUrl,
    this.senderName = '',
    this.geolocation,
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
  late final TabController _tabController;

  List<_VideoEntry> _entries = [];
  bool _loadingOwn = true;
  Directory? _thumbCacheDir;

  List<_SharedEntry> _shared = [];
  bool _loadingShared = true;

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
  }

  @override
  void dispose() {
    _tabController.dispose();
    _playerController?.dispose();
    super.dispose();
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
    final serverSosIds =
        ((sessionsResult['sosIds'] as List<dynamic>?) ?? [])
            .whereType<String>()
            .toSet();

    final diskVideos = await VideoStorageUtils.instance.loadFinalVideos();
    final entries =
        diskVideos.map((f) {
          final isServer = serverSosIds.any((id) => f.path.contains(id));
          return _VideoEntry(file: f, isLocal: true, isServer: isServer);
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
      debugPrint('[SharedSessions] raw response: $response');

      final rawList = response['sessions'];
      if (rawList == null) {
        debugPrint('[SharedSessions] ⚠️ sessions key was null in response');
        if (mounted) setState(() => _loadingShared = false);
        return;
      }

      final List sessions = rawList as List;
      debugPrint('[SharedSessions] got ${sessions.length} sessions');

      final results =
          sessions.map((d) {
            if (d['error'] == true) {
              debugPrint(
                '[SharedSessions] ⚠️ skipping errored session: ${d['sessionId']}',
              );
              return _SharedEntry(
                sessionId: d['sessionId'] ?? 'unknown',
                hostUid: '',
                message: 'Error — something went wrong with this video',
              );
            }

            return _SharedEntry(
              sessionId: d['sessionId'] ?? '',
              hostUid: d['hostUid'] ?? '',
              message: d['message'],
              listTitle: d['listTitle'],
              finalStoragePath: d['finalStoragePath'],
              streamUrl: d['streamUrl'],
              senderName: d['senderName'] ?? '',
              geolocation: d['geolocation'] as String?,
              createdAt:
                  d['createdAt'] != null
                      ? DateTime.tryParse(d['createdAt'])
                      : null,
            );
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
      debugPrint('[SharedSessions] ❌ load error: $e');
      debugPrint('[SharedSessions] stack: $stack');
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: _snackSuccessBg,
          duration: Duration(seconds: 2),
          content: Row(
            children: [
              Icon(
                Icons.check_circle_outline,
                color: _snackSuccessIcon,
                size: 16,
              ),
              SizedBox(width: 8),
              Text(
                'Saved to your videos',
                style: TextStyle(color: _textPrimary, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      debugPrint('[Download] ❌ error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: _snackErrorBg,
          duration: Duration(seconds: 3),
          content: Row(
            children: [
              Icon(Icons.error_outline, color: _snackErrorIcon, size: 16),
              SizedBox(width: 8),
              Text(
                'Download failed — please try again',
                style: TextStyle(color: _textPrimary, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => entry.isDownloading = false);
    }
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

    if (bytes != null && mounted) {
      setState(() => entry.thumbnail = bytes);
    }
  }

  Future<void> _loadSharedThumbnail(_SharedEntry entry) async {
    if (entry.thumbnailAttempted || entry.streamUrl == null) return;
    entry.thumbnailAttempted = true;

    final cacheDir = _thumbCacheDir;
    if (cacheDir == null) return;

    final cacheKey = entry.sessionId.hashCode.toRadixString(16);
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

    if (bytes != null && mounted) {
      setState(() => entry.thumbnail = bytes);
    }
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
        const SnackBar(
          content: Text(
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
      if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
                  unselectedLabelColor: Color(0xFF7A7068),
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

  /* ──────────────────────── My Videos tab — charcoal/wood ────────────────── */

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
                  if (entry.isServer) ...[
                    const SizedBox(height: 6),
                    _buildBadge(
                      icon: Icons.cloud_done_outlined,
                      label: 'Server',
                      bg: _ownServerBadgeBg,
                      textColor: _ownServerBadgeText,
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

  /* ──────────────────────── Shared Sessions tab — soft ember ─────────────── */

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
    final isReady = entry.streamUrl != null;
    final sender =
        entry.senderName.isNotEmpty ? entry.senderName : entry.hostUid;
    final dateStr = _formatDateFromDt(entry.createdAt);
    final subtitle = entry.message ?? entry.listTitle ?? '';

    return Material(
      color: _sharedBgRow,
      child: InkWell(
        onTap: () => _openSharedPlayer(entry),
        splashColor: _sharedSplash,
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
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
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
                      dateStr,
                      style: const TextStyle(
                        color: _sharedTextMuted,
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
                    icon:
                        isReady
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_outlined,
                    label: isReady ? 'Ready' : 'Loading',
                    bg: isReady ? _sharedReadyBadgeBg : _sharedLoadingBadgeBg,
                    textColor:
                        isReady
                            ? _sharedReadyBadgeText
                            : _sharedLoadingBadgeText,
                  ),
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
        color: const Color(0xED0A0602), // near-black warm @93%
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
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          backgroundColor: _snackSuccessBg,
                          duration: Duration(seconds: 2),
                          content: Row(
                            children: [
                              Icon(
                                Icons.check_circle_outline,
                                color: _snackSuccessIcon,
                                size: 16,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Coordinates copied to clipboard',
                                style: TextStyle(
                                  color: _textPrimary,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
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
  }
}
