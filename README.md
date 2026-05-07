# 🔴 Project Hermes — Frontend

**A resilient SOS alert and covert video recording system built with Flutter.**

Project Hermes is a mobile application designed to operate under adverse conditions. When a user triggers an SOS, the app silently records video in short chunks, uploads them to cloud storage with automatic retry, notifies designated recipients via push notification, and stitches all footage into a final video — even if the device loses signal or is shut down mid-session.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Tech Stack](#tech-stack)
- [Project Structure](#project-structure)
- [Core Concepts](#core-concepts)
  - [Chunked Recording Pipeline](#chunked-recording-pipeline)
  - [ChunkUploadQueue](#chunkuploadqueue)
  - [CameraBloc](#camerabloc)
  - [SOS Session Lifecycle](#sos-session-lifecycle)
  - [Recipient Notifications](#recipient-notifications)
  - [Shared Sessions](#shared-sessions)
- [Dependencies](#dependencies)
- [Firebase Configuration](#firebase-configuration)
- [Setup & Installation](#setup--installation)
- [Environment Configuration](#environment-configuration)
- [Android Notes](#android-notes)
- [iOS Notes](#ios-notes)
- [Debugging](#debugging)
- [Backend Companion](#backend-companion)
- [Roadmap](#roadmap)

---

## Overview

Project Hermes was built with a core design constraint: **footage must survive**. Signal loss, app backgrounding, device shutdown, and poor connectivity must not result in lost video. This shapes every architectural decision — from how recording is split into chunks, to how uploads are retried, to how server-side stitching is decoupled from the client.

Key capabilities:
- One-tap SOS trigger with covert background recording
- 4-second video chunks recorded, saved to stable local storage, and uploaded independently
- Automatic exponential backoff retry for failed uploads
- Server-side video stitching via ffmpeg (decoupled from the client)
- FCM push notifications to designated recipients upon first stitch completion
- Shared sessions screen for recipients to view recorded footage via signed GCS URLs
- Persistent upload queue that survives app restarts

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Flutter Frontend                    │
│                                                      │
│  ┌──────────┐   ┌────────────┐   ┌───────────────┐  │
│  │CameraPage│──▶│ CameraBloc │──▶│ChunkUploadQueue│  │
│  └──────────┘   └────────────┘   └───────┬───────┘  │
│                                          │           │
│              UUID (sosId) generated      │           │
│              here and used consistently  │           │
└──────────────────────────────────────────┼───────────┘
                                           │ HTTP multipart
                                           ▼
┌─────────────────────────────────────────────────────┐
│               Backend (Node.js / Cloud Run)          │
│                                                      │
│  POST /sos/create ──▶ Firestore session doc          │
│  POST /sos/:id/chunk ──▶ GCS upload + scheduleStitch │
│  GET  /me/my_sessions ──▶ own session list           │
│  GET  /me/shared_sessions ──▶ recipient session list │
│                                                      │
│  scheduleStitch (debounced 4s) ──▶ ffmpeg stitch     │
│  _notifyRecipients() ──▶ FCM push on first stitch    │
└─────────────────────────────────────────────────────┘
                           │
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
       Firestore          GCS           Firebase Auth
  (sessions, users,   (chunk files,   (identity + JWT)
   shared_sessions)    final.mp4)
```

The Flutter-generated UUID is established as the `sosId` **before** the session is created on the backend. This UUID is used as the Firestore document ID, the GCS path prefix, and the reference key throughout the stack — ensuring a single consistent identity for every session.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend framework | Flutter (Dart) |
| State management | `flutter_bloc` (BLoC pattern) |
| Auth | Firebase Auth |
| Database | Cloud Firestore |
| File storage | Google Cloud Storage (via backend) |
| Push notifications | Firebase Cloud Messaging (FCM) |
| Video recording | `camera` plugin |
| Local video processing | `ffmpeg_kit_flutter_new` |
| Contacts | `flutter_contacts` |
| HTTP | `http` |
| Permissions | `permission_handler` |
| Local paths | `path_provider`, `path` |
| Video playback | `video_player` |
| Thumbnails | `video_thumbnail` |
| Location | `geolocator` |
| Media saving | `gal` |
| Fonts | `google_fonts` |
| ID generation | `uuid` |

---

## Project Structure

```
lib/
├── main.dart                    # App entry point, Firebase init, FCM setup
├── firebase_options.dart        # Auto-generated Firebase config (FlutterFire CLI)
│
├── blocs/
│   └── camera/
│       ├── camera_bloc.dart     # Core recording state machine
│       ├── camera_event.dart    # CameraEnable, CameraDisable, CameraReset, etc.
│       └── camera_state.dart    # CameraReady, CameraRecording, CameraError, etc.
│
├── services/
│   ├── chunk_upload_queue.dart  # Singleton upload queue with retry + disk persistence
│   ├── auth_service.dart        # Firebase Auth helpers (sign in, token refresh)
│   └── notification_service.dart# FCM token management and foreground handler
│
├── screens/
│   ├── home_screen.dart         # Main dashboard + SOS trigger button
│   ├── camera_page.dart         # Active recording UI, lifecycle management
│   ├── shared_sessions_screen.dart # Recipient view of shared footage
│   ├── my_sessions_screen.dart  # Own past SOS sessions
│   ├── login_screen.dart        # Auth flow
│   └── contacts_screen.dart     # Recipient management (phone contacts)
│
├── models/
│   ├── sos_session.dart         # Session data model
│   └── shared_session.dart      # Shared session model (recipient view)
│
└── utils/
    ├── api_client.dart          # HTTP wrapper with auth token injection
    └── constants.dart           # Backend base URL and config constants
```

> **Note:** GitHub currently prevents direct tree browsing via robots.txt, so the above reflects the actual structure as built. File names may vary slightly from what appears in the GitHub file explorer.

---

## Core Concepts

### Chunked Recording Pipeline

Rather than attempting live streaming (fragile under poor connectivity), Hermes records video in **4-second chunks**. Each chunk is:

1. Recorded by the `camera` plugin and saved to stable local storage (`path_provider` application documents directory — **not** the cache, which can be cleared by the OS)
2. Enqueued in the `ChunkUploadQueue` singleton immediately
3. Uploaded to the backend via `POST /sos/:sosId/chunk` as a multipart form upload
4. Deleted locally after confirmed upload

Chunks are self-contained, independently retryable units. Even if the app is killed mid-session, the queue is persisted to disk and resumes on next launch.

**Why 4 seconds?** This duration aligns with industry norms (HLS segments are typically 2–6s) and balances two concerns: short enough that a failed upload doesn't lose much footage, long enough to keep upload overhead reasonable.

### ChunkUploadQueue

`ChunkUploadQueue` is a **singleton** with disk-persisted state. Key behaviors:

- Maintains a per-session upload loop — one concurrent upload per session at a time
- Uses **exponential backoff** retry on upload failure (network loss, server errors)
- Persists pending chunk paths to disk so the queue survives app termination
- Emits upload completion events so `CameraBloc` can track session progress
- Calls the backend's `finalizeUser` endpoint fire-and-forget after all chunks upload (the server's debounced watcher handles actual stitching, so this is a belt-and-suspenders signal)

### CameraBloc

`CameraBloc` manages the full recording state machine using the BLoC pattern (`flutter_bloc` + `equatable`). States include:

- `CameraInitial` — not yet initialized
- `CameraReady` — camera initialized, not recording
- `CameraRecording` — actively recording and chunking
- `CameraError` — initialization or recording failure

Important lifecycle detail: when the app resumes from background, `CameraReset` is emitted **before** `CameraEnable`. Emitting only `CameraEnable` after resume causes a black screen bug because the camera controller is in an inconsistent state. `AppLifecycleState.inactive` does **not** stop the camera — only `paused` and `detached` trigger a stop.

### SOS Session Lifecycle

```
User taps SOS
      │
      ▼
Flutter generates UUID  ◀─── This becomes sosId everywhere
      │
      ▼
POST /sos/create  ──▶  Firestore doc created
                        recipientUids resolved and stored
                        fan-out: sosId written to each recipient's shared_sessions
      │
      ▼
CameraBloc starts recording 4s chunks
      │
      ▼  (per chunk)
ChunkUploadQueue: POST /sos/:sosId/chunk
      │
      ▼  (server side, per chunk arrival)
scheduleStitch debounces 4s of quiet
      │
      ▼
_finalizeSession: ffmpeg stitches chunks into final.mp4
  - Incremental: prepends any existing final.mp4
  - stitchInProgress Set prevents concurrent stitching
      │
      ▼  (first stitch only)
_notifyRecipients(): FCM push to all recipientUids
      │
      ▼
User stops SOS
ChunkUploadQueue drains remaining chunks
finalizeUser called fire-and-forget (belt and suspenders)
```

**Recipient UIDs** are resolved from phone numbers at session creation time and stored in the Firestore session document. This avoids repeated phone-to-UID lookups and ensures notifications go to the right people even if phone number mappings change.

### Recipient Notifications

Push notifications are handled via **FCM** (`firebase_messaging`). The backend fires FCM notifications only on the **first** stitch completion — not on every subsequent incremental stitch. This prevents notification spam during a long session.

Foreground in-app notifications are intentionally **deprioritized**: active users see live updates via Firestore real-time listeners. FCM handles the background/terminated device case.

For recipients who are not yet registered in the system, their session IDs are stored under `users_unregistered/{hashedPhone}/meta/included_sessions` and migrated into their account on registration.

### Shared Sessions

Recipients can view sessions shared with them via the **Shared Sessions** screen. The backend `GET /me/shared_sessions` endpoint:

- Reads `sosId` references from the authenticated user's `users/{uid}/shared_sessions` Firestore subcollection
- Batch-queries session documents in chunks of 10 (Firestore `whereIn` limit)
- Resolves host usernames via the `username_index` collection
- Generates **signed GCS URLs** for video playback (time-limited, no public bucket exposure)
- Soft-skips sessions with missing `finalStoragePath`, returning an `error: true` stub

The Flutter screen handles `error: true` stub entries gracefully (shows a placeholder), uses `DateTime.tryParse` for safe timestamp parsing, and guards against a null `sessions` field in the response.

---

## Dependencies

From `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  uuid: ^4.3.3
  firebase_core: ^4.2.0
  firebase_auth: ^6.1.1
  cloud_firestore: ^6.0.3
  google_fonts: ^6.3.2
  cupertino_icons: ^1.0.8
  http: ^1.5.0
  camera: ^0.11.2
  permission_handler: ^12.0.1
  equatable: ^2.0.7
  flutter_bloc: ^9.1.1
  visibility_detector: ^0.4.0+2
  video_player: ^2.10.1
  firebase_messaging: ^16.0.4
  flutter_contacts: ^1.1.9
  path_provider: ^2.1.0
  path: ^1.9.0
  ffmpeg_kit_flutter_new: ^4.1.0
  video_thumbnail: ^0.5.3
  firebase_storage: ^13.1.0
  geolocator: ^13.0.0
  gal: ^2.3.0
```

---

## Firebase Configuration

The Firebase project ID is **`project-hermes-d667b`**. The app is configured for Android, iOS, and Web targets.

Firebase configuration is stored in:
- `android/app/google-services.json` — Android Firebase config (generated by FlutterFire CLI, not committed)
- `lib/firebase_options.dart` — Dart-side multi-platform config (generated by FlutterFire CLI, not committed)
- `firebase.json` — FlutterFire CLI metadata (committed)

To regenerate these files after changing Firebase project settings:

```bash
flutterfire configure --project=project-hermes-d667b
```

---

## Setup & Installation

### Prerequisites

- Flutter SDK `^3.7.2`
- Dart SDK `^3.7.2`
- Android Studio or VS Code with Flutter extension
- Firebase CLI + FlutterFire CLI
- A running instance of the [Project Hermes backend](https://github.com/SibyllineSourceCode/projectHermes_backEnd) *(see Backend Companion)*

### Steps

```bash
# 1. Clone the repo
git clone https://github.com/SibyllineSourceCode/projectHermes_frontEnd.git
cd projectHermes_frontEnd

# 2. Install dependencies
flutter pub get

# 3. Configure Firebase
#    Ensure google-services.json is in android/app/
#    Ensure lib/firebase_options.dart exists
#    If not, run:
flutterfire configure --project=project-hermes-d667b

# 4. Set the backend base URL
#    Edit lib/utils/constants.dart and set the Cloud Run URL

# 5. Run the app
flutter run
```

---

## Environment Configuration

The backend URL and any other environment-specific values are configured in `lib/utils/constants.dart`. Before running, ensure this file points to your deployed backend:

```dart
// lib/utils/constants.dart
const String backendBaseUrl = 'https://your-cloud-run-url.run.app';
```

For local backend development, you can use your machine's LAN IP (e.g., `http://192.168.x.x:3000`) while running on a physical device on the same network.

---

## Android Notes

The following permissions are declared in `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.READ_CONTACTS" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
```

These are also requested at runtime via `permission_handler`.

**Minimum SDK:** The `camera` and `ffmpeg_kit_flutter_new` packages require a minimum SDK level of 21 (Android 5.0).

**Debugging on Android:**

```bash
# Filtered Flutter logs only (cuts through GPU driver noise)
adb logcat -s flutter

# Or with emoji prefix filtering for targeted debug output
adb logcat -s flutter | grep "🔴\|📦\|✅\|❌"
```

Use `debugPrint('🔴 [CameraBloc] $message')` style prefixes in source for easy filtering.

**Hot restart vs hot reload:** When changes affect `initState` or `_init()` methods (e.g., camera initialization), use **hot restart** (`Ctrl+Shift+F5` in VS Code) rather than hot reload. Hot reload does not re-run `initState`.

---

## iOS Notes

The core architecture is platform-agnostic, but iOS requires additional setup before the app can run on a real device:

1. **APNs configuration** — an Apple Push Notification service key must be uploaded to the Firebase console and linked to the FCM project.

2. **`Info.plist` permission strings** — add the following to `ios/Runner/Info.plist`:
   ```xml
   <key>NSCameraUsageDescription</key>
   <string>Hermes uses the camera to record SOS video.</string>
   <key>NSMicrophoneUsageDescription</key>
   <string>Hermes records audio during an SOS session.</string>
   <key>NSContactsUsageDescription</key>
   <string>Hermes uses your contacts to select SOS recipients.</string>
   ```

3. **Background execution** — iOS aggressively suspends background apps. For reliable background upload continuation, consider integrating `workmanager` for background task registration.

4. **Apple Developer account** — required for real device testing and TestFlight distribution. Simulator testing is possible for UI but not for camera recording.

5. **Xcode** — device logging on iOS requires Xcode's Console app or `xcrun simctl spawn booted log stream --predicate 'subsystem == "com.your.bundle.id"'`.

---

## Debugging

**Targeted log filtering (Android):**

```bash
adb logcat -s flutter
```

**Recommended `debugPrint` pattern:**

```dart
debugPrint('🔴 [ChunkUploadQueue] Uploading chunk $chunkIndex for session $sosId');
debugPrint('✅ [ChunkUploadQueue] Chunk $chunkIndex uploaded successfully');
debugPrint('❌ [ChunkUploadQueue] Upload failed, retry in ${delay}ms: $error');
```

Using emoji prefixes and BLoC/class names in log messages makes it easy to grep for specific subsystems without installing additional tooling.

**Diagnosing black screen on resume:**

If the camera shows a black screen after the app resumes from background, verify that `didChangeAppLifecycleState` emits `CameraReset()` before `CameraEnable()` — not just `CameraEnable()` alone.

**Diagnosing upload queue stalls:**

Check whether `ChunkUploadQueue` has a pending entry for the session in its persisted state. If the upload loop died without cleaning up, a hot restart will re-read the persisted queue and resume.

---

## Backend Companion

This repository is the frontend half of Project Hermes. The backend (TypeScript / Node.js / Express, deployed on Firebase Cloud Functions v2 / Cloud Run) handles:

- Session creation and Firestore fan-out
- Chunk ingestion and GCS storage
- Server-side ffmpeg stitching via debounced watcher (`scheduleStitch`)
- FCM notification dispatch
- Signed URL generation for video playback
- Recipient UID resolution and unregistered user handling

**Backend repo:** `https://github.com/SibyllineSourceCode/projectHermes_backEnd` *(private)*

Key backend endpoints:

| Method | Path | Description |
|---|---|---|
| `POST` | `/sos/create` | Create a new SOS session, resolve recipient UIDs, fan-out to Firestore |
| `POST` | `/sos/:sosId/chunk` | Ingest a video chunk, upload to GCS, trigger debounced stitch |
| `POST` | `/sos/finalize` | Manually trigger finalization (belt-and-suspenders) |
| `GET` | `/me/my_sessions` | Retrieve the authenticated user's own session list |
| `GET` | `/me/shared_sessions` | Retrieve sessions shared with the authenticated user |
| `POST` | `/notify/stream-start` | Send FCM push notification (SMS stub included for future A2P integration) |

---

## Roadmap

- [ ] **SMS notifications** — gated on A2P 10DLC carrier compliance. Plivo and Telnyx identified as developer-friendly providers. Backend stub already in place at `POST /notify/stream-start`.
- [ ] **iOS production deployment** — APNs key upload, `Info.plist` entries, codesigning, Apple Developer account setup, TestFlight.
- [ ] **Foreground in-app notifications** — currently deprioritized; active users see updates via Firestore listeners.
- [ ] **Unregistered recipient migration** — session IDs stored under `users_unregistered/{hashedPhone}` at session creation; migration hook fires at registration.
- [ ] **Background recording hardening (iOS)** — `workmanager` integration for reliable background task execution on iOS.
- [ ] **Chunk gap detection** — server-side detection and logging of sequence gaps in uploaded chunks.
- [ ] **Session replay controls** — scrubbing, chapter markers per chunk, download to device.

---

*Project Hermes — because the messenger must always get through.*
