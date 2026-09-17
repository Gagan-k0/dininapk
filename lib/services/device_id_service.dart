import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Stable per-device id sent as `x-device-id`.
///
/// The api-server's table claim (`helpers/tableClaim.js`) allows ONE device per
/// table; with no header every tablet signed in as the same staff account looks
/// like one device (`staff:<id>`), so two waiters silently share a claim.
///
/// Random, generated on this device, never derived from user or hardware
/// identifiers — it only scopes the claim.
class DeviceIdService {
  static const String storageKey = 'waiter_device_id';

  /// Cached so the header costs one prefs read per app run.
  static String? _cached;

  /// 128 random bits as hex — also used for idempotency keys.
  static String randomHex() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<String> get() async {
    final cached = _cached;
    if (cached != null && cached.isNotEmpty) return cached;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(storageKey) ?? '';
    if (id.isEmpty) {
      id = randomHex();
      await prefs.setString(storageKey, id);
    }
    _cached = id;
    return id;
  }

  /// Test seam — drops the in-memory copy so the next [get] re-reads prefs.
  static void resetCache() => _cached = null;
}
