import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import 'api_client.dart';
import 'auth_service.dart';
import 'connectivity_service.dart';
import 'subscription_rules.dart';

/// The signed-in restaurant's subscription: banner state and whether the app
/// must show the lock screen. The server is the only enforcer — this is UX.
///
/// Online, [isLocked] follows the server's verdict. Offline, it follows the
/// last signed licence stored on the tablet ([evaluateOffline]).
class SubscriptionService with ChangeNotifier {
  SubscriptionService._();
  static final SubscriptionService instance = SubscriptionService._();

  static const String storageKey = 'waiter_subscription_licence';
  static const Duration refreshEvery = Duration(minutes: 30);

  SubscriptionInfo? _current;
  bool _offlineAllowed = true;
  bool _running = false;
  Timer? _timer;

  SubscriptionInfo? get current => _current;

  bool get isLocked {
    if (!_running) return false;
    final refuses = _current?.refuses ?? false;
    if (ConnectivityService.instance.isOnline) return refuses;
    return refuses || !_offlineAllowed;
  }

  /// Signed in (not demo): check now, then every [refreshEvery] and whenever
  /// the tablet goes on/offline.
  Future<void> start({Map<String, dynamic>? loginSubscription}) async {
    if (!_running) {
      _running = true;
      ConnectivityService.instance.addListener(_onConnectivity);
      _timer = Timer.periodic(refreshEvery, (_) => refresh());
    }
    final rid = await AuthService().getRestaurantId() ?? '';
    final stored = await _load();
    if (stored != null && stored['restaurantId'] != rid) {
      // Licence belongs to another restaurant: start clean for this one.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    }
    if (loginSubscription != null) {
      await apply(loginSubscription);
    } else {
      await refresh();
    }
  }

  /// Signed out: nothing to enforce on the login screen. The licence is kept
  /// for this restaurant (cleared when a different restaurant signs in).
  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_running) ConnectivityService.instance.removeListener(_onConnectivity);
    _running = false;
    _current = null;
    _offlineAllowed = true;
    notifyListeners();
  }

  /// Asks the server. A network failure re-checks the offline licence instead.
  Future<void> refresh() async {
    if (!_running) return;
    try {
      final env = await ApiClient().get(
        ApiConfig.subscriptionStatus,
        background: true,
      );
      final data = env.map;
      if (data != null) await apply(data);
    } on ApiException catch (e) {
      // A subscription refusal already reached [apply] via ApiClient.
      if (!e.isSubscriptionLocked) await _recomputeOffline();
    } catch (_) {
      await _recomputeOffline();
    }
  }

  /// A subscription object from status, login or a refusal envelope.
  Future<void> apply(Map<String, dynamic> data) async {
    if (!_running) return;
    final info = SubscriptionInfo.fromJson(data);
    if (info.state.isEmpty) return;
    _current = info;
    final rid = await AuthService().getRestaurantId() ?? '';
    final stored = await _load();
    final sameRestaurant = stored != null && stored['restaurantId'] == rid;
    final prevSeen = sameRestaurant ? DateTime.tryParse('${stored['lastServerTime']}') : null;
    final seen = info.serverTime;
    final lastSeen = prevSeen == null || (seen != null && seen.isAfter(prevSeen)) ? seen : prevSeen;
    final licence = info.licence.isNotEmpty
        ? info.licence
        : (sameRestaurant ? stored['licence']?.toString() : null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      storageKey,
      jsonEncode({
        'restaurantId': rid,
        'licence': licence,
        'lastServerTime': lastSeen?.toIso8601String(),
      }),
    );
    await _recomputeOffline(notify: false);
    notifyListeners();
  }

  void _onConnectivity() {
    unawaited(_recomputeOffline());
  }

  Future<void> _recomputeOffline({bool notify = true}) async {
    final rid = await AuthService().getRestaurantId() ?? '';
    final stored = await _load();
    final own = stored != null && stored['restaurantId'] == rid;
    _offlineAllowed = await evaluateOffline(
      licenceToken: own ? stored['licence']?.toString() : null,
      restaurantId: rid,
      now: DateTime.now(),
      lastServerTime: own ? DateTime.tryParse('${stored['lastServerTime']}') : null,
      publicKeyBase64: ApiConfig.subscriptionPublicKey,
    );
    if (notify) notifyListeners();
  }

  static Future<Map<String, dynamic>?> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw);
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null;
    }
  }
}
