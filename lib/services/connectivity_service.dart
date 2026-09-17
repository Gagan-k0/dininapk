import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SyncState { online, offlineManual, offlineNoSignal }

/// Whether this tablet should talk to the server.
///
/// Two independent reasons to be offline:
/// * **manual** — the waiter turned Sync off. Persisted; no request leaves the
///   device until they turn it back on.
/// * **no signal** — a real request failed at the transport level. Derived from
///   request outcomes, never from the OS network flag (it says "connected" on a
///   captive or dead Wi-Fi). While in this state a cheap [probe] runs every
///   [probeEvery]; the first response of any kind means the server is back.
class ConnectivityService with ChangeNotifier {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  static const String storageKey = 'waiter_sync_off';
  static const Duration probeEvery = Duration(seconds: 20);

  /// Set once at startup (main.dart) — a background request whose outcome
  /// flows back through [reportReachable] / [reportNetworkFailure].
  Future<void> Function()? probe;

  bool _manualOff = false;
  bool _noSignal = false;
  Timer? _probeTimer;

  SyncState get state => _manualOff
      ? SyncState.offlineManual
      : _noSignal
      ? SyncState.offlineNoSignal
      : SyncState.online;

  bool get isOnline => state == SyncState.online;

  /// The waiter's switch. Requests are refused locally only in this state.
  bool get syncOff => _manualOff;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _manualOff = prefs.getBool(storageKey) ?? false;
    notifyListeners();
  }

  Future<void> setSyncOn(bool on) async {
    if (_manualOff == !on) return;
    _manualOff = !on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(storageKey, _manualOff);
    if (_manualOff) {
      _stopProbe();
    } else if (_noSignal) {
      _startProbe();
      unawaited(_runProbe()); // turning Sync on should answer "is it back?" now
    }
    notifyListeners();
  }

  /// The server answered (any verdict, even a refusal).
  void reportReachable() {
    if (!_noSignal) return;
    _noSignal = false;
    _stopProbe();
    notifyListeners();
  }

  /// A request never got a verdict (DNS, socket, timeout).
  void reportNetworkFailure() {
    if (_noSignal) return;
    _noSignal = true;
    if (!_manualOff) _startProbe();
    notifyListeners();
  }

  void _startProbe() {
    _probeTimer ??= Timer.periodic(probeEvery, (_) => _runProbe());
  }

  void _stopProbe() {
    _probeTimer?.cancel();
    _probeTimer = null;
  }

  bool _probing = false;
  Future<void> _runProbe() async {
    final p = probe;
    if (p == null || _probing || _manualOff) return;
    _probing = true;
    try {
      await p();
    } catch (_) {
      // Outcome already reported by the request layer.
    } finally {
      _probing = false;
    }
  }

  /// Signed out: nothing to probe for. Back to online (the switch is kept).
  void clearSignal() {
    if (!_noSignal) return;
    _noSignal = false;
    _stopProbe();
    notifyListeners();
  }
}
