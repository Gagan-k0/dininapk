import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Pure subscription parsing and the offline licence rule (no I/O), so both
/// can be unit-tested. Server contract: api-server
/// `docs/superpowers/specs/2026-09-17-restaurant-subscription-design.md`.

/// Envelope `status.code` words the server refuses a locked restaurant with.
const String subscriptionLockedCode = 'subscription_locked';
const String restaurantBlockedCode = 'restaurant_blocked';

/// A device clock this far behind the last server time counts as rolled back.
const Duration clockRollbackSlack = Duration(minutes: 10);

DateTime? _date(Object? v) =>
    v == null ? null : DateTime.tryParse(v.toString())?.toUtc();

String _str(Object? v) => v?.toString() ?? '';

/// The subscription object (status, login `data.subscription`, refusal `data`).
class SubscriptionInfo {
  /// active | expiring | grace | locked | blocked | none
  final String state;
  final DateTime? endsAt;
  final DateTime? graceEndsAt;
  final int? daysLeft;
  final DateTime? serverTime;

  /// off | warn | on
  final String enforcement;
  final String supportPhone;
  final String supportWhatsapp;
  final String supportEmail;
  final String licence;

  const SubscriptionInfo({
    required this.state,
    this.endsAt,
    this.graceEndsAt,
    this.daysLeft,
    this.serverTime,
    this.enforcement = '',
    this.supportPhone = '',
    this.supportWhatsapp = '',
    this.supportEmail = '',
    this.licence = '',
  });

  factory SubscriptionInfo.fromJson(Map<String, dynamic> j) {
    final support = j['support'] is Map ? j['support'] as Map : const {};
    final days = j['days_left'];
    return SubscriptionInfo(
      state: _str(j['state']),
      endsAt: _date(j['ends_at']),
      graceEndsAt: _date(j['grace_ends_at']),
      daysLeft: days is num ? days.toInt() : int.tryParse(_str(days)),
      serverTime: _date(j['server_time']),
      enforcement: _str(j['enforcement']),
      supportPhone: _str(support['phone']),
      supportWhatsapp: _str(support['whatsapp']),
      supportEmail: _str(support['email']),
      licence: _str(j['licence']),
    );
  }

  /// Whether the server refuses this restaurant's calls: blocked always;
  /// locked / no record only once enforcement is `on`.
  bool get refuses =>
      state == 'blocked' ||
      (enforcement == 'on' && (state == 'locked' || state == 'none'));

  bool get showsBanner => state == 'expiring' || state == 'grace';
}

/// Signed licence payload `{ v, rid, state, ends_at, grace_ends_at, iat, offline_until }`.
class LicencePayload {
  final String rid;
  final String state;
  final DateTime? offlineUntil;

  const LicencePayload({required this.rid, required this.state, this.offlineUntil});
}

/// Decodes `base64url(payload).base64url(signature)` and checks the Ed25519
/// signature over the ASCII bytes of the first segment. Null when malformed or
/// the signature does not verify.
Future<LicencePayload?> verifyLicence(String token, String publicKeyBase64) async {
  final parts = token.split('.');
  if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
  try {
    final pk = base64.decode(publicKeyBase64);
    final sig = base64Url.decode(base64Url.normalize(parts[1]));
    if (pk.length != 32 || sig.length != 64) return null;
    final ok = await Ed25519().verify(
      ascii.encode(parts[0]),
      signature: Signature(
        sig,
        publicKey: SimplePublicKey(pk, type: KeyPairType.ed25519),
      ),
    );
    if (!ok) return null;
    final json = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))));
    if (json is! Map) return null;
    return LicencePayload(
      rid: _str(json['rid']),
      state: _str(json['state']),
      offlineUntil: _date(json['offline_until']),
    );
  } catch (_) {
    return null;
  }
}

/// Client offline rule: may this tablet be used without reaching the server?
///
/// A verified `blocked` licence for this restaurant always locks. Otherwise the
/// lock applies only when the last seen [enforcement] is `on` (under `warn` the
/// server locks nobody, so neither does the tablet). Under `on`: no stored
/// licence → allowed (first run after the update, until the first status call);
/// else the licence must verify, be for [restaurantId], not be locked,
/// `now < offline_until`, and the clock must not be earlier than
/// [lastServerTime] − 10 min.
Future<bool> evaluateOffline({
  required String? licenceToken,
  required String restaurantId,
  required DateTime now,
  required DateTime? lastServerTime,
  required String publicKeyBase64,
  required String enforcement,
}) async {
  if (licenceToken == null || licenceToken.isEmpty) return true;
  final p = await verifyLicence(licenceToken, publicKeyBase64);
  if (p != null && p.rid == restaurantId && p.state == 'blocked') return false;
  if (enforcement != 'on') return true;
  if (p == null) return false;
  if (restaurantId.isEmpty || p.rid != restaurantId) return false;
  if (p.state == 'locked' || p.state == 'blocked') return false;
  final until = p.offlineUntil;
  if (until == null || !now.toUtc().isBefore(until)) return false;
  if (lastServerTime != null &&
      now.toUtc().isBefore(lastServerTime.subtract(clockRollbackSlack))) {
    return false;
  }
  return true;
}
