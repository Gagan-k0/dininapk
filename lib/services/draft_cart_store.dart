import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_id_service.dart';

/// One item the waiter added that the server has not received yet.
class DraftLine {
  final String lineId;
  final String? menuId; // null for an extra add-on
  final String name;
  final String? variantId;
  final String? variantName;
  final List<Map<String, dynamic>> addons;
  final int quantity;
  final double unitPrice; // display only — the server re-prices every line
  final String description;
  final bool isExtra;

  const DraftLine({
    required this.lineId,
    required this.menuId,
    required this.name,
    this.variantId,
    this.variantName,
    this.addons = const [],
    required this.quantity,
    required this.unitPrice,
    this.description = '',
    this.isExtra = false,
  });

  DraftLine withQuantity(int q) => DraftLine(
    lineId: lineId,
    menuId: menuId,
    name: name,
    variantId: variantId,
    variantName: variantName,
    addons: addons,
    quantity: q,
    unitPrice: unitPrice,
    description: description,
    isExtra: isExtra,
  );

  static String? _id(Object? v) {
    final s = v?.toString() ?? '';
    return s.isEmpty || s == '0' ? null : s;
  }

  static String _addonKey(List<Map<String, dynamic>> addons) {
    final ids =
        addons
            .map((a) {
              final v = a['value'];
              return (a['addonvalue_id'] ?? (v is Map ? v['_id'] : null) ?? '')
                  .toString();
            })
            .where((s) => s.isNotEmpty)
            .toList()
          ..sort();
    return ids.join('|');
  }

  /// Mirrors the server's `findMatchingCartLine`, so two taps on the same
  /// item merge here exactly as they would merge on the server.
  bool sameItemAs(DraftLine o) {
    if (isExtra || o.isExtra) {
      return isExtra &&
          o.isExtra &&
          name == o.name &&
          unitPrice == o.unitPrice &&
          description.trim() == o.description.trim();
    }
    return _id(menuId) == _id(o.menuId) &&
        _id(variantId) == _id(o.variantId) &&
        _addonKey(addons) == _addonKey(o.addons) &&
        description.trim() == o.description.trim();
  }

  /// A line in the shape `POST /restaurant/cart/offline-sync` expects.
  Map<String, dynamic> toSyncJson() => {
    'menu_id': menuId,
    'menu_name': name,
    'variant_id': variantId,
    'addons': addons,
    'quantity': quantity,
    'individual_price': unitPrice,
    'description': description,
    'is_extra_addon': isExtra,
  };

  /// Painted in the cart list next to server lines (same keys the screen reads).
  Map<String, dynamic> toCartLineMap() => {
    '_id': '${TableDraft.lineIdPrefix}$lineId',
    'menu_id': menuId,
    'menu_name': name,
    if (!isExtra && menuId != null)
      'menuData': [
        {'_id': menuId, 'name': name},
      ],
    'variant_name': variantName,
    'addons': addons,
    'quantity': quantity,
    'individual_price': unitPrice,
    'price': unitPrice * quantity,
    'description': description,
    'kot_status': 0,
    'kotprint_status': 0,
    'is_draft': true,
  };

  Map<String, dynamic> toJson() => {
    'lineId': lineId,
    'menuId': menuId,
    'name': name,
    'variantId': variantId,
    'variantName': variantName,
    'addons': addons,
    'quantity': quantity,
    'unitPrice': unitPrice,
    'description': description,
    'isExtra': isExtra,
  };

  factory DraftLine.fromJson(Map<String, dynamic> j) => DraftLine(
    lineId: j['lineId'].toString(),
    menuId: j['menuId']?.toString(),
    name: j['name']?.toString() ?? 'Item',
    variantId: j['variantId']?.toString(),
    variantName: j['variantName']?.toString(),
    addons: (j['addons'] as List? ?? const [])
        .whereType<Map>()
        .map((a) => Map<String, dynamic>.from(a))
        .toList(),
    quantity: (j['quantity'] as num?)?.toInt() ?? 1,
    unitPrice: (j['unitPrice'] as num?)?.toDouble() ?? 0,
    description: j['description']?.toString() ?? '',
    isExtra: j['isExtra'] == true,
  );
}

/// Unsent items for one table on this tablet.
///
/// [key] is the `Idempotency-Key`. It is minted once and kept through every
/// edit: if a send's response was lost, re-sending under the same key is either
/// a harmless duplicate (same content) or a 409 conflict (edited) — never a
/// second copy of the items. Only an explicit "send again" mints a new key.
class TableDraft {
  static const String lineIdPrefix = 'draft:';

  final String restaurantId;
  final String tableId;
  final String key;

  /// The server cart these items belong to (null = the table had no cart).
  /// If the live cart differs at send time the table has turned over, and the
  /// items must never be added to somebody else's bill automatically.
  final String? baselineCartId;

  /// The item sent through `createcart` to open a cart whose answer has not
  /// come back. Held apart from [lines] and locked, so a lost response is
  /// matched against the live cart instead of adding that item twice.
  final DraftLine? creatingLine;

  final List<DraftLine> lines;

  /// Why the last send was refused; [conflict] means waiting on the waiter.
  final String? lastError;
  final bool conflict;

  const TableDraft({
    required this.restaurantId,
    required this.tableId,
    required this.key,
    this.baselineCartId,
    this.creatingLine,
    this.lines = const [],
    this.lastError,
    this.conflict = false,
  });

  factory TableDraft.start(String rid, String tid, String? cartId) =>
      TableDraft(
        restaurantId: rid,
        tableId: tid,
        key: DeviceIdService.randomHex(),
        baselineCartId: cartId == null || cartId.isEmpty ? null : cartId,
      );

  bool get isEmpty => lines.isEmpty && creatingLine == null;

  /// Everything still shown as "not sent", the locked [creatingLine] first.
  List<DraftLine> get allLines => [?creatingLine, ...lines];
  int get itemCount => allLines.fold(0, (s, l) => s + l.quantity);
  double get subtotal =>
      allLines.fold(0.0, (s, l) => s + l.unitPrice * l.quantity);

  TableDraft copyWith({
    String? key,
    String? baselineCartId,
    bool clearBaseline = false,
    DraftLine? creatingLine,
    bool clearCreating = false,
    List<DraftLine>? lines,
    String? lastError,
    bool clearError = false,
    bool? conflict,
  }) => TableDraft(
    restaurantId: restaurantId,
    tableId: tableId,
    key: key ?? this.key,
    baselineCartId: clearBaseline
        ? null
        : (baselineCartId ?? this.baselineCartId),
    creatingLine: clearCreating ? null : (creatingLine ?? this.creatingLine),
    lines: lines ?? this.lines,
    lastError: clearError ? null : (lastError ?? this.lastError),
    conflict: conflict ?? this.conflict,
  );

  /// Adds [line], merging into an identical line like the server would.
  TableDraft add(DraftLine line) {
    final i = lines.indexWhere((l) => l.sameItemAs(line));
    final next = [...lines];
    if (i >= 0) {
      next[i] = next[i].withQuantity(next[i].quantity + line.quantity);
    } else {
      next.add(line);
    }
    return copyWith(lines: next);
  }

  /// Sets a line's quantity; 0 or less removes it.
  TableDraft setQuantity(String lineId, int qty) => copyWith(
    lines: [
      for (final l in lines)
        if (l.lineId != lineId)
          l
        else if (qty > 0)
          l.withQuantity(qty),
    ],
  );

  Map<String, dynamic> toJson() => {
    'restaurantId': restaurantId,
    'tableId': tableId,
    'key': key,
    'baselineCartId': baselineCartId,
    'creatingLine': creatingLine?.toJson(),
    'lines': lines.map((l) => l.toJson()).toList(),
    'lastError': lastError,
    'conflict': conflict,
  };

  factory TableDraft.fromJson(Map<String, dynamic> j) => TableDraft(
    restaurantId: j['restaurantId'].toString(),
    tableId: j['tableId'].toString(),
    key: j['key'].toString(),
    baselineCartId: j['baselineCartId']?.toString(),
    creatingLine: j['creatingLine'] is Map
        ? DraftLine.fromJson(Map<String, dynamic>.from(j['creatingLine'] as Map))
        : null,
    lines: (j['lines'] as List? ?? const [])
        .whereType<Map>()
        .map((l) => DraftLine.fromJson(Map<String, dynamic>.from(l)))
        .toList(),
    lastError: j['lastError']?.toString(),
    conflict: j['conflict'] == true,
  );
}

/// SharedPreferences persistence, restaurant-scoped. Unsent drafts survive
/// logout (they are sales); cart snapshots do not (they can hold guest names).
class DraftCartStore {
  static const String _draftPrefix = 'waiter_draft_';
  static const String _snapPrefix = 'waiter_cart_snap_';

  static String _draftKey(String rid, String tid) => '$_draftPrefix${rid}_$tid';

  /// Tables on this tablet with unsent items — drives the Sync chip badge.
  static final ValueNotifier<int> pendingTables = ValueNotifier(0);

  /// Every stored draft for [rid] (other restaurants' rows are never read).
  Future<List<TableDraft>> all(String rid) async {
    if (rid.isEmpty) return const [];
    final prefs = await SharedPreferences.getInstance();
    final out = <TableDraft>[];
    for (final k in prefs.getKeys().where((k) => k.startsWith('$_draftPrefix${rid}_'))) {
      final d = await load(rid, k.substring('$_draftPrefix${rid}_'.length));
      if (d != null) out.add(d);
    }
    return out;
  }

  /// Recounts [pendingTables] for [rid].
  Future<void> refreshPending(String rid) async {
    pendingTables.value = (await all(rid)).length;
  }
  static String _snapKey(String rid, String tid) => '$_snapPrefix${rid}_$tid';

  Future<TableDraft?> load(String rid, String tid) async {
    if (rid.isEmpty || tid.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_draftKey(rid, tid));
    if (raw == null) return null;
    try {
      final d = TableDraft.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      // Never trust a row filed under another restaurant or table.
      return d.restaurantId == rid && d.tableId == tid ? d : null;
    } catch (_) {
      return null;
    }
  }

  /// Saves, or deletes when there is nothing left to send.
  Future<void> save(TableDraft d) async {
    final prefs = await SharedPreferences.getInstance();
    final k = _draftKey(d.restaurantId, d.tableId);
    if (d.isEmpty) {
      await prefs.remove(k);
    } else {
      await prefs.setString(k, jsonEncode(d.toJson()));
    }
    await refreshPending(d.restaurantId);
  }

  Future<void> delete(String rid, String tid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_draftKey(rid, tid));
    await refreshPending(rid);
  }

  /// Last server view of a table, so it can still be opened offline.
  Future<void> saveSnapshot(
    String rid,
    String tid, {
    Map<String, dynamic>? table,
    required List<Map<String, dynamic>> cart,
  }) async {
    if (rid.isEmpty || tid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _snapKey(rid, tid),
      jsonEncode({'table': table, 'cart': cart}),
    );
  }

  Future<({Map<String, dynamic>? table, List<Map<String, dynamic>> cart})?>
  loadSnapshot(String rid, String tid) async {
    if (rid.isEmpty || tid.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_snapKey(rid, tid));
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final t = j['table'];
      return (
        table: t is Map ? Map<String, dynamic>.from(t) : null,
        cart: (j['cart'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Last floor (areas + tables) so the app can start with no connection.
  /// Shares the snapshot prefix, so logout clears it too.
  Future<void> saveFloor(
    String rid, {
    required List<Map<String, dynamic>> areas,
    required List<Map<String, dynamic>> tables,
  }) async {
    if (rid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '${_snapPrefix}floor_$rid',
      jsonEncode({
        'areas': areas,
        'tables': tables,
        'at': DateTime.now().toIso8601String(),
      }),
    );
  }

  Future<
    ({
      List<Map<String, dynamic>> areas,
      List<Map<String, dynamic>> tables,
      DateTime? at,
    })?
  >
  loadFloor(String rid) async {
    if (rid.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('${_snapPrefix}floor_$rid');
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      List<Map<String, dynamic>> maps(Object? v) => (v as List? ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      return (
        areas: maps(j['areas']),
        tables: maps(j['tables']),
        at: DateTime.tryParse(j['at']?.toString() ?? ''),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearSnapshots() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys().where((k) => k.startsWith(_snapPrefix))) {
      await prefs.remove(k);
    }
  }
}
