import 'dart:async';
import 'package:flutter/foundation.dart';
import '../services/auth_service.dart';

/// Represents a recipient in an SOS list.
/// Backend should return at least one route: app_user_id (push) and/or phone_e164 (sms).
class SosRecipient {
  final String? appUserId;   // if they have an account / can receive push
  final String? phoneE164;   // +15551234567 for SMS fallback
  final String? displayName;

  const SosRecipient({this.appUserId, this.phoneE164, this.displayName});

  factory SosRecipient.fromJson(Map<String, dynamic> json) {
    return SosRecipient(
      appUserId: json['appUserId']?.toString(),
      phoneE164: json['phoneE164']?.toString(),
      displayName: json['displayName']?.toString(),
    );
    }
}

/// Payload you want recipients to receive.
class SosPayload {
  final String sosId;
  final String message;
  final String? deepLink; // opens app to “join SOS”
  final DateTime createdAt;

  const SosPayload({
    required this.sosId,
    required this.message,
    required this.createdAt,
    this.deepLink,
  });

  factory SosPayload.fromJson(Map<String, dynamic> json) {
    return SosPayload(
      sosId: json['sosId'].toString(),
      message: json['message'].toString(),
      deepLink: json['deepLink']?.toString(),
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

class SosUtils {
  /// Main “one-liner” you call from CameraPage before starting recording/RTC.
  ///
  /// - Fetches active list recipients from backend
  /// - Creates an SOS event on backend
  /// - Backend handles fan-out (push to app users + sms fallback to non-users)
  ///
  /// Returns SosPayload for UI logging/toasts if needed.
  static Future<SosPayload?> sendSosForActiveList({
    required String activeListId,
    required String activeListTitle,
    required String fromDisplayName, // e.g. current user display name
    String? customMessage,
    Map<String, dynamic>? extraContext, // location, etc.
  }) async {
    try {
      final api = AuthService.instance.api;

      // 1) Ask backend for list recipients (do NOT do local contacts->SMS routing here)
      // Expected: { recipients: [ {appUserId?, phoneE164?, displayName?}, ... ] }
      final recipientsRes = await api.getActiveListRecipients(listId: activeListId);
      final raw = (recipientsRes['recipients'] as List?) ?? const [];
      final recipients = raw
          .whereType<Map<String, dynamic>>()
          .map(SosRecipient.fromJson)
          .toList();

      if (recipients.isEmpty) {
        return null; // nothing to send
      }

      // 2) Create SOS on backend. Backend should:
      //   - persist SOS event
      //   - send push to app users
      //   - send SMS to recipients without app installs / push tokens
      final msg = customMessage ??
          "$fromDisplayName is requesting assistance. Tap to join the SOS.";

      final createRes = await api.createSos(
        listId: activeListId,
        listTitle: activeListTitle,
        message: msg,
        recipients: recipients.map((r) => {
          'appUserId': r.appUserId,
          'phoneE164': r.phoneE164,
          'displayName': r.displayName,
        }).toList(),
        extraContext: extraContext ?? const {},
      );

      // Expected: { sosId, message, deepLink, createdAt }
      return SosPayload.fromJson(createRes);
    } catch (e, st) {
      debugPrint("SOS send failed: $e");
      debugPrint("$st");
      return null; // non-fatal for recording flow
    }
  }
}
