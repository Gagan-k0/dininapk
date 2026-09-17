import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dineinapk/services/api_client.dart';
import 'package:dineinapk/services/auth_service.dart';
import 'package:dineinapk/services/subscription_rules.dart';

String b64url(List<int> b) => base64Url.encode(b).replaceAll('=', '');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.utc(2026, 9, 17, 10);
  late SimpleKeyPair keys;
  late String publicKey;

  setUpAll(() async {
    keys = await Ed25519().newKeyPair();
    publicKey = base64.encode((await keys.extractPublicKey()).bytes);
  });

  Future<String> licence({
    String rid = 'r1',
    String state = 'active',
    DateTime? offlineUntil,
  }) async {
    final payload = b64url(utf8.encode(jsonEncode({
      'v': 1,
      'rid': rid,
      'state': state,
      'ends_at': '2026-10-01T00:00:00.000Z',
      'grace_ends_at': '2026-10-04T00:00:00.000Z',
      'iat': now.toIso8601String(),
      'offline_until': (offlineUntil ?? now.add(const Duration(days: 3))).toIso8601String(),
    })));
    final sig = await Ed25519().sign(ascii.encode(payload), keyPair: keys);
    return '$payload.${b64url(sig.bytes)}';
  }

  Future<bool> offline(String? token, {String rid = 'r1', DateTime? at, DateTime? lastSeen}) =>
      evaluateOffline(
        licenceToken: token,
        restaurantId: rid,
        now: at ?? now,
        lastServerTime: lastSeen ?? now,
        publicKeyBase64: publicKey,
      );

  group('offline licence rule', () {
    test('a valid licence for this restaurant is usable offline', () async {
      expect(await offline(await licence()), isTrue);
    });

    test('no stored licence is allowed until the first status call', () async {
      expect(await offline(null), isTrue);
      expect(await offline(''), isTrue);
    });

    test('a tampered payload fails the signature', () async {
      final t = await licence(state: 'locked');
      final forged = b64url(utf8.encode(utf8
          .decode(base64Url.decode(base64Url.normalize(t.split('.')[0])))
          .replaceFirst('"locked"', '"active"')));
      expect(await offline('$forged.${t.split('.')[1]}'), isFalse);
      expect(await offline('garbage'), isFalse);
    });

    test('a licence signed by another key is refused', () async {
      final other = await Ed25519().newKeyPair();
      final t = await licence();
      final sig = await Ed25519().sign(ascii.encode(t.split('.')[0]), keyPair: other);
      expect(await offline('${t.split('.')[0]}.${b64url(sig.bytes)}'), isFalse);
    });

    test('a licence from another restaurant is refused', () async {
      expect(await offline(await licence(rid: 'r2')), isFalse);
    });

    test('past offline_until locks', () async {
      final t = await licence(offlineUntil: now.add(const Duration(hours: 1)));
      expect(await offline(t, at: now.add(const Duration(hours: 1))), isFalse);
    });

    test('a clock set back more than 10 minutes locks', () async {
      final t = await licence();
      expect(await offline(t, at: now.subtract(const Duration(minutes: 9))), isTrue);
      expect(await offline(t, at: now.subtract(const Duration(minutes: 11))), isFalse);
    });

    test('a locked or blocked licence never works offline', () async {
      expect(await offline(await licence(state: 'locked')), isFalse);
      expect(await offline(await licence(state: 'blocked')), isFalse);
    });

    test('the shipped public key is a 32-byte key', () {
      expect(base64.decode('xXsgsz5LPgJaQfw7WU1KBRY4j4QVhjKXXDQixmeN56Y=').length, 32);
    });
  });

  group('subscription object', () {
    SubscriptionInfo info(String state, String enforcement) =>
        SubscriptionInfo.fromJson({'state': state, 'enforcement': enforcement});

    test('refuses like the server: blocked always, locked/none only when on', () {
      expect(info('blocked', 'warn').refuses, isTrue);
      expect(info('locked', 'on').refuses, isTrue);
      expect(info('none', 'on').refuses, isTrue);
      expect(info('locked', 'warn').refuses, isFalse);
      expect(info('grace', 'on').refuses, isFalse);
    });

    test('parses dates, days and support', () {
      final s = SubscriptionInfo.fromJson({
        'state': 'grace',
        'ends_at': '2026-09-15T18:29:59.999Z',
        'grace_ends_at': '2026-09-18T18:29:59.999Z',
        'days_left': -2,
        'server_time': '2026-09-17T10:00:00.000Z',
        'support': {'phone': '+91 1', 'whatsapp': '+91 2', 'email': 'a@b.c'},
        'licence': 'x.y',
      });
      expect(s.showsBanner, isTrue);
      expect(s.daysLeft, -2);
      expect(s.serverTime, DateTime.utc(2026, 9, 17, 10));
      expect(s.supportWhatsapp, '+91 2');
      expect(s.licence, 'x.y');
    });
  });

  group('ApiClient', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await AuthService().saveSession(token: 't', restaurantId: 'r1');
      ApiClient.sessionRefreshed();
    });

    for (final code in [subscriptionLockedCode, restaurantBlockedCode]) {
      test('403 $code is a subscription lock, never a session expiry', () async {
        var expired = 0;
        ApiClient.onSessionExpired = (_) => expired++;
        addTearDown(() => ApiClient.onSessionExpired = null);
        final client = ApiClient(
          auth: AuthService(),
          httpClient: MockClient((_) async => http.Response(
                jsonEncode({
                  'status': {'code': code, 'message': 'Subscription expired'},
                  'data': {'state': 'locked', 'enforcement': 'on'},
                }),
                403,
              )),
        );
        await expectLater(
          client.get('/restaurant/table/all'),
          throwsA(isA<ApiException>()
              .having((e) => e.isSubscriptionLocked, 'isSubscriptionLocked', isTrue)
              .having((e) => e.isAuth, 'isAuth', isFalse)
              .having((e) => e.message, 'message', 'Subscription expired')),
        );
        expect(expired, 0);
      });
    }
  });
}
