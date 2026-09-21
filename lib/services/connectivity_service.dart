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
  static const Duration probeFastInterval = Duration(seconds: 10);
  static const Duration probeSecondaryInterval = Duration(seconds: 15);
  static const Duration probeMaxInterval = Duration(seconds: 30);

  /// Set once at startup (main.dart) — a background request whose outcome
  /// flows back through [reportReachable] / [reportNetworkFailure].
  Future<void> Function()? probe;

  /// Called whenever the tablet becomes able to reach the server again
  /// (Sync switched on, or the first answer after no signal).
  void Function()? onBackOnline;

  bool _manualOff = false;
  bool _noSignal = false;
  Timer? _probeTimer;
  int _probeAttempts = 0;

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
      triggerImmediateProbe();
    }
    notifyListeners();
    if (isOnline) onBackOnline?.call();
  }

  /// Trigger an immediate 0s probe attempt and reset backoff schedule to fast 10s phase.
  void triggerImmediateProbe() {
    if (_manualOff) return;
    _probeAttempts = 0;
    _stopProbe();
    _scheduleNextProbe();
    unawaited(_runProbe());
  }

  /// The server answered (any verdict, even a refusal).
  void reportReachable() {
    if (!_noSignal) return;
    _noSignal = false;
    _probeAttempts = 0;
    _stopProbe();
    notifyListeners();
    if (isOnline) onBackOnline?.call();
  }

  /// A request never got a verdict (DNS, socket, timeout).
  void reportNetworkFailure() {
    final wasNoSignal = _noSignal;
    _noSignal = true;
    if (!_manualOff) {
      if (!wasNoSignal) {
        // First network failure: trigger instant probe and start fast 10s schedule
        triggerImmediateProbe();
      } else if (_probeTimer == null) {
        _scheduleNextProbe();
      }
    }
    notifyListeners();
  }

  void _scheduleNextProbe() {
    _probeTimer?.cancel();
    final Duration currentInterval;
    if (_probeAttempts < 6) {
      currentInterval = probeFastInterval; // 10s for first 1 min (6 * 10s)
    } else if (_probeAttempts < 10) {
      currentInterval = probeSecondaryInterval; // 15s for next minute
    } else {
      currentInterval = probeMaxInterval; // 30s cap for prolonged outages
    }

    _probeTimer = Timer(currentInterval, () async {
      await _runProbe();
      if (_noSignal && !_manualOff) {
        _scheduleNextProbe();
      }
    });
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
    _probeAttempts++;
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
    _probeAttempts = 0;
    _stopProbe();
    notifyListeners();
  }
}
