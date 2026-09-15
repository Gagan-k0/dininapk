import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/receipt_customization.dart';
import 'api_service.dart';
import 'auth_service.dart';

/// Loads/saves the SAME `printer_settings.receipt_settings` object the admin
/// exe/website edit (via `restaurant/settings/view` GET and
/// `restaurant/settings/update-printer-settings` PUT), cached locally per
/// restaurant so printing never depends on a live network call.
///
/// [ThermalPrinterService] only ever reads [loadCached] — never fetches over
/// the network on the print path — so once a device has synced once, KOT/bill
/// printing (and locally-saved edits) keep working with no connectivity.
class ReceiptCustomizationService {
  static const String _cachePrefix = 'receipt_customization_';
  static const String _syncedAtPrefix = 'receipt_customization_synced_at_';

  final AuthService _auth;
  final ApiService _api;

  ReceiptCustomizationService({AuthService? auth, ApiService? api})
      : _auth = auth ?? AuthService(),
        _api = api ?? ApiService();

  Future<String> _cacheKey() async =>
      '$_cachePrefix${await _auth.getRestaurantId() ?? 'unknown'}';

  Future<String> _syncedAtKey() async =>
      '$_syncedAtPrefix${await _auth.getRestaurantId() ?? 'unknown'}';

  /// Reads the last-cached settings — never touches the network. Falls back
  /// to admin-matching defaults if this device has never synced.
  Future<ReceiptCustomization> loadCached() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(await _cacheKey());
    if (raw == null || raw.isEmpty) return ReceiptCustomization.defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return ReceiptCustomization.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // Corrupt cache — fall back to defaults rather than block printing.
    }
    return ReceiptCustomization.defaults;
  }

  Future<DateTime?> lastSyncedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final iso = prefs.getString(await _syncedAtKey());
    if (iso == null || iso.isEmpty) return null;
    return DateTime.tryParse(iso);
  }

  /// Persists [settings] to the local cache immediately (so an offline edit is
  /// never lost even if the server push below fails or is skipped).
  Future<void> saveLocal(ReceiptCustomization settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(await _cacheKey(), jsonEncode(settings.toJson()));
  }

  /// GET `restaurant/settings/view`, cache the merged `receipt_settings`, and
  /// return it. Throws [ApiException] on failure — callers on a Settings
  /// screen should catch it and keep showing the last cached copy.
  Future<ReceiptCustomization> fetchAndCache() async {
    final restaurant = await _api.getRestaurantSettingsView();
    final printerSettings = restaurant['printer_settings'];
    final receiptSettings = printerSettings is Map
        ? printerSettings['receipt_settings']
        : null;
    final merged = receiptSettings is Map
        ? ReceiptCustomization.fromJson(Map<String, dynamic>.from(receiptSettings))
        : ReceiptCustomization.defaults;
    await saveLocal(merged);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(await _syncedAtKey(), DateTime.now().toIso8601String());
    return merged;
  }

  /// Saves [settings] locally first (so it survives being offline), then
  /// tries to push it to the server. Returns true only if the server push
  /// also succeeded; false means it is cached locally and will need a retry
  /// once back online. Re-throws a genuine refusal (e.g. this staff account
  /// lacks the `private` permission on `restaurant/settings/*`) rather than
  /// swallowing it as if it were a connectivity problem — a caller should
  /// tell the waiter to ask an admin for access, not "try again when online".
  Future<bool> saveAndPush(ReceiptCustomization settings) async {
    await saveLocal(settings);
    try {
      await _api.updatePrinterSettings(receiptSettings: settings.toJson());
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(await _syncedAtKey(), DateTime.now().toIso8601String());
      return true;
    } on ApiException catch (e) {
      if (e.isNetwork) return false;
      rethrow;
    } catch (_) {
      return false;
    }
  }
}
