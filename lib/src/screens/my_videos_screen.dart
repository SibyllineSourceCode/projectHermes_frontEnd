import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../utils/video_storage_utils.dart';
import '../services/auth_service.dart';

// ── Colours ──────────────────────────────────────────────────────────────────

// Synced rows: slightly blue-tinted dark (uploaded to server)
const _syncedBadgeBg   = Color(0xFF1E6B9E);
const _syncedBadgeText = Color(0xFFADD8F7);

// Local-only rows: warm dark (lives only on device)
const _localBg    = Color(0xFF2A2020);
const _localBadgeBg   = Color(0xFF7A3B1E);
const _localBadgeText = Color(0xFFF7C9AD);

// ─────────────────────────────────────────────────────────────────────────────

/// A video entry carrying its file, sync status, and lazily-loaded thumbnail.
class _VideoEntry {
  final File file;
  final bool isLocal;   // always true since it came from disk
  final bool isServer;  // true = confirmed on server post-stitching
  Uint8List? thumbnail;
  bool thumbnailAttempted = false;

  _VideoEntry({required this.file, required this.isLocal, required this.isServer});
}

// ─────────────────────────────────────────────────────────────────────────────

class MyVideosScreen extends StatefulWidget {
  /// Videos that were already uploaded to the server (passed from CameraPage).
  final List<File> videos;
  const MyVideosScreen({super.key, required this.videos});

  @override
  State<MyVideosScreen> createState() => _MyVideosScreenState();
}

class _MyVideosScreenState extends State<MyVideosScreen> {
  List<_VideoEntry> _entries = [];
  bool _loading = true;

  // Thumbnail cache directory
  Directory? _thumbCacheDir;

  // Player state
  _VideoEntry? _playing;
  VideoPlayerController? _playerController;
  bool _playerReady = false;
  bool _showControls = true;

  /* ---------------- Init / dispose ---------------- */

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _playerController?.dispose();
    super.dispose();
  }

  /* ---------------- Data loading ---------------- */

  Future<void> _init() async {
    final currentUser = await AuthService.instance.api.me();
    final stitchResult = await AuthService.instance.api.finalizeUser(userId: currentUser['uid']);

    // Extract sosIds that were successfully finalized on the server
    // Each result has finalStoragePath = "sos/{sosId}/final.mp4"
    final serverSosIds = (stitchResult['finalized'] as List<dynamic>? ?? [])
        .where((v) => v['ok'] == true && v['finalStoragePath'] != null)
        .map((v) {
          // Extract sosId from "sos/{sosId}/final.mp4"
          final parts = (v['finalStoragePath'] as String).split('/');
          return parts.length >= 2 ? parts[1] : null;
        })
        .whereType<String>()
        .toSet();

    // Prepare thumb cache dir
    final docs = await getApplicationDocumentsDirectory();
    _thumbCacheDir = Directory(p.join(docs.path, 'sos_video_thumbs'));
    if (!await _thumbCacheDir!.exists()) {
      await _thumbCacheDir!.create(recursive: true);
    }

    // Load all videos from disk
    final diskVideos = await VideoStorageUtils.instance.loadFinalVideos();

    // Synced = exists locally AND confirmed on server (matched by sosId in path)
    final entries = diskVideos.map((f) {
      final isServer = serverSosIds.any((id) => f.path.contains(id));
      debugPrint('[VideoSync]=$serverSosIds');
      debugPrint('[VideoSync]=${f.path}');
      debugPrint('[VideoSync]=$isServer');
      return _VideoEntry(file: f, isLocal: true, isServer: isServer);
    }).toList();

    entries.sort((a, b) =>
        b.file.lastModifiedSync().compareTo(a.file.lastModifiedSync()));

    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });

    for (final e in _entries) {
      _loadThumbnail(e);
    }
  }
  /* ---------------- Thumbnails ---------------- */

  Future<void> _loadThumbnail(_VideoEntry entry) async {
    if (entry.thumbnailAttempted) return;
    entry.thumbnailAttempted = true;

    final cacheDir = _thumbCacheDir;
    if (cacheDir == null) return;

    // Use a hash of the file path as the cache filename
    final cacheKey = entry.file.path.hashCode.toRadixString(16);
    final cacheFile = File(p.join(cacheDir.path, '$cacheKey.jpg'));

    Uint8List? bytes;

    if (await cacheFile.exists()) {
      // Serve from disk cache
      bytes = await cacheFile.readAsBytes();
    } else {
      // Generate and cache
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
      } catch (_) {
        // Generation failed — thumbnail stays null, icon fallback shown
      }
    }

    if (bytes != null && mounted) {
      setState(() => entry.thumbnail = bytes);
    }
  }

  /* ---------------- Player ---------------- */

  Future<void> _openPlayer(_VideoEntry entry) async {
    await _playerController?.dispose();
    setState(() {
      _playing = entry;
      _playerReady = false;
      _showControls = true;
    });

    final ctrl = VideoPlayerController.file(entry.file);
    _playerController = ctrl;
    await ctrl.initialize();
    if (!mounted) return;

    ctrl.addListener(() { if (mounted && _playerController != null) setState(() {}); });
    setState(() => _playerReady = true);
    await ctrl.play();
  }

  Future<void> _closePlayer() async {
    final ctrl = _playerController;
    _playerController = null;

    // Update UI immediately before disposal
    if (mounted) setState(() { _playing = null; _playerReady = false; });

    // Dispose after UI has already moved on
    try {
      await ctrl?.pause();
      ctrl?.dispose();  // no await — fire and forget to avoid hangs
    } catch (_) {}
  }

  void _toggleControls() => setState(() => _showControls = !_showControls);

  void _togglePlayPause() {
    final ctrl = _playerController;
    if (ctrl == null) return;
    ctrl.value.isPlaying ? ctrl.pause() : ctrl.play();
    setState(() {});
  }

  /* ---------------- Formatting ---------------- */

  String _formatDate(File f) {
    try {
      final dt = f.lastModifiedSync();
      return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)}  '
          '${_pad(dt.hour)}:${_pad(dt.minute)}';
    } catch (_) { return ''; }
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

  /* ---------------- Build ---------------- */

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 54, 53, 53),
      appBar: _playing == null
          ? AppBar(
              backgroundColor: const Color.fromARGB(255, 40, 40, 40),
              foregroundColor: Colors.white,
              title: const Text('My Videos',
                  style: TextStyle(
                      fontFamily: 'Montserrat', fontWeight: FontWeight.w600)),
            )
          : null,
      body: Stack(
        children: [
          // ── Video list ────────────────────────────────────────────────
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _entries.isEmpty
                  ? const Center(
                      child: Text('No videos yet',
                          style: TextStyle(
                              color: Color(0xFF959393), fontSize: 16)))
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _entries.length,
                      separatorBuilder: (_, __) => const Divider(
                          color: Color(0xFF3A3A3A), height: 1, indent: 80),
                      itemBuilder: (_, i) => _buildRow(_entries[i]),
                    ),

          // ── Player overlay ────────────────────────────────────────────
          if (_playing != null) _buildPlayerOverlay(context),
        ],
      ),
    );
  }

  /* ---------------- List row ---------------- */

  Widget _buildRow(_VideoEntry entry) {
    final name = entry.file.path.split('/').last;
    final bg   =  _localBg;
    final badgeBg   = _localBadgeBg;


    return Material(
      color: bg,
      child: InkWell(
        onTap: () => _openPlayer(entry),
        splashColor: Colors.white10,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              // ── Thumbnail ──────────────────────────────────────────
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 72,
                  height: 54,
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

              // ── Title + meta ───────────────────────────────────────
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

              // ── Sync badge ─────────────────────────────────────────
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeBg.withOpacity(0.35),
                  border: Border.all(color: badgeBg, width: 1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: // ── Sync badges ─────────────────────────────────────────────
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  /* ---------------- Player overlay ---------------- */

  Widget _buildPlayerOverlay(BuildContext context) {
    final ctrl     = _playerController;
    final name     = _playing!.file.path.split('/').last;
    final position = ctrl?.value.position ?? Duration.zero;
    final total    = ctrl?.value.duration  ?? Duration.zero;
    final progress = total.inMilliseconds > 0
        ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final isPlaying = ctrl?.value.isPlaying ?? false;

    const double topTapHeight    = 60;
    const double bottomTapHeight = 60;
    const double videoMarginV    = 16;

    return GestureDetector(
      onTap: _closePlayer,
      child: Container(
        color: Colors.black.withOpacity(0.90),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: topTapHeight),

              // ── Video frame ──────────────────────────────────────────
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return GestureDetector(
                      onTap: _toggleControls,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                              maxHeight: constraints.maxHeight - videoMarginV),
                          child: Container(
                            margin:
                                const EdgeInsets.symmetric(horizontal: 16),
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
                    );
                  },
                ),
              ),

              const SizedBox(height: 12),

              // ── Controls ─────────────────────────────────────────────
              AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 220),
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        Text(name,
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
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4),
                            child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
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
                                width: 62,
                                height: 62,
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

              const SizedBox(height: bottomTapHeight),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconButton(IconData icon, VoidCallback onTap, {double size = 24}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
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