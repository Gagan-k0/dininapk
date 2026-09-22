import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
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
  /// [printed] lines were already handed to the kitchen on an offline KOT, so
  /// they read as KOT'd here too until the server has them.
  Map<String, dynamic> toCartLineMap({bool printed = false}) => {
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
    'kot_status': printed ? 1 : 0,
    'kotprint_status': printed ? 1 : 0,
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

  /// Lines already printed on an offline KOT. They ride their own
  /// [printedKey] and are uploaded BEFORE [pendingOps] replays their status,
  /// so items added afterwards (kept in [lines], under a fresh [key]) can
  /// never be swept in by the server's blanket status update.
  final List<DraftLine> printedLines;
  final String? printedKey;

  /// Server lines that were on an offline ticket, id → quantity shown. The
  /// status replay marks only these sent (plus [printedLines], which upload
  /// already marked), so a line another device added meanwhile still reaches
  /// the kitchen. Null = the tablet cannot name every printed row (a row from
  /// an older build, a lost answer, an unmatched line): the replay stays
  /// blanket, as it was.
  final Map<String, int>? printedServerLines;

  /// [creatingLine] was on an offline ticket: once found on the server, its
  /// id joins [printedServerLines] (createcart cannot mark it sent).
  final bool creatingPrinted;

  /// `setcartstatus` values for a print that already happened on paper,
  /// replayed in [opOrder] once the server has [printedLines]. 'KOT' is never
  /// queued: only that status builds the kitchen-display notification, so
  /// replaying it would re-fire the kitchen for food already cooked.
  final List<String> pendingOps;

  /// The only statuses a print may queue, in the order they must be applied.
  static const List<String> opOrder = ['KOT_PRINT', 'PRINTED'];

  /// Why the last send was refused; [conflict] means waiting on the waiter.
  final String? lastError;
  final bool conflict;

  /// Provisional number printed on this table's offline bill (`OFF-…`), kept
  /// so a reprint shows the same one. The real number arrives at settle sync.
  final String? billNumber;

  /// Held because another device holds the table's claim ([lastError] says who).
  final bool claimed;

  /// When the first item was added; kept across edits and sends.
  final DateTime createdAt;

  TableDraft({
    required this.restaurantId,
    required this.tableId,
    required this.key,
    this.baselineCartId,
    this.creatingLine,
    this.lines = const [],
    this.printedLines = const [],
    this.printedKey,
    this.printedServerLines = const {},
    this.creatingPrinted = false,
    this.pendingOps = const [],
    this.lastError,
    this.conflict = false,
    this.claimed = false,
    this.billNumber,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory TableDraft.start(String rid, String tid, String? cartId) =>
      TableDraft(
        restaurantId: rid,
        tableId: tid,
        key: DeviceIdService.randomHex(),
        baselineCartId: cartId == null || cartId.isEmpty ? null : cartId,
      );

  /// Items on this tablet the server has not received yet.
  bool get hasItems =>
      lines.isNotEmpty || creatingLine != null || printedLines.isNotEmpty;

  /// Nothing left to send AND nothing left to replay — the row can go.
  bool get isEmpty => !hasItems && pendingOps.isEmpty;

  /// Not printed yet, the locked [creatingLine] first.
  List<DraftLine> get unprintedLines => [?creatingLine, ...lines];

  /// Everything still shown as "not sent", oldest batch first.
  List<DraftLine> get allLines => [...printedLines, ...unprintedLines];
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
    List<DraftLine>? printedLines,
    String? printedKey,
    Map<String, int>? printedServerLines,
    bool blanketReplay = false,
    bool? creatingPrinted,
    List<String>? pendingOps,
    bool clearOps = false,
    String? lastError,
    bool clearError = false,
    bool? conflict,
    bool? claimed,
    String? billNumber,
  }) => TableDraft(
    restaurantId: restaurantId,
    tableId: tableId,
    key: key ?? this.key,
    baselineCartId: clearBaseline
        ? null
        : (baselineCartId ?? this.baselineCartId),
    creatingLine: clearCreating ? null : (creatingLine ?? this.creatingLine),
    lines: lines ?? this.lines,
    printedLines: printedLines ?? this.printedLines,
    printedKey: printedKey ?? this.printedKey,
    printedServerLines: blanketReplay
        ? null
        : (printedServerLines ?? this.printedServerLines),
    creatingPrinted: clearCreating ? false : (creatingPrinted ?? this.creatingPrinted),
    pendingOps: clearOps ? const [] : (pendingOps ?? this.pendingOps),
    lastError: clearError ? null : (lastError ?? this.lastError),
    conflict: conflict ?? this.conflict,
    claimed: claimed ?? this.claimed,
    billNumber: billNumber ?? this.billNumber,
    createdAt: createdAt,
  );

  /// Freezes what an offline print just put on paper: those lines read as
  /// printed and keep the key they were collected under, [status] is queued
  /// for replay, and anything added next waits under a NEW key so a later
  /// blanket status update cannot mark it printed too. [serverLines] are the
  /// server lines the same ticket showed (id → quantity). A [creatingLine]
  /// was on the ticket too.
  TableDraft sealPrinted(String status, [Map<String, int> serverLines = const {}]) => copyWith(
    key: DeviceIdService.randomHex(),
    printedKey: printedLines.isEmpty ? key : printedKey,
    printedLines: [...printedLines, ...lines],
    // With no replay still waiting, a blanket fallback has done its job: this
    // ticket starts naming its lines again.
    printedServerLines: (pendingOps.isEmpty
            ? copyWith(printedServerLines: const {})
            : this)
        .withServerLines(serverLines)
        .printedServerLines,
    creatingPrinted: creatingPrinted || creatingLine != null,
    lines: const [],
    pendingOps: pendingOps.contains(status) ? pendingOps : [...pendingOps, status],
  );

  /// Also marks [lines] as on a ticket; the latest quantity shown wins. A
  /// no-op on a blanket row.
  TableDraft withServerLines(Map<String, int> lines) {
    final had = printedServerLines;
    if (had == null || lines.isEmpty) return this;
    return copyWith(printedServerLines: {...had, ...lines});
  }

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
    'printedLines': printedLines.map((l) => l.toJson()).toList(),
    'printedKey': printedKey,
    'printedServerLines': printedServerLines,
    'creatingPrinted': creatingPrinted,
    'pendingOps': pendingOps,
    'lastError': lastError,
    'conflict': conflict,
    'claimed': claimed,
    'billNumber': billNumber,
    'createdAt': createdAt.toIso8601String(),
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
    printedLines: (j['printedLines'] as List? ?? const [])
        .whereType<Map>()
        .map((l) => DraftLine.fromJson(Map<String, dynamic>.from(l)))
        .toList(),
    printedKey: j['printedKey']?.toString(),
    // Null for rows queued before this field: the replay then stays blanket,
    // as it was when they were printed.
    // Absent on rows saved by an older build. Only one with a print still to
    // replay needs the blanket (null); any other starts tracking now.
    printedServerLines: j.containsKey('printedServerLines')
        ? (j['printedServerLines'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), int.tryParse(v.toString()) ?? 1),
          )
        : ((j['pendingOps'] as List? ?? const []).isEmpty ? const {} : null),
    creatingPrinted: j['creatingPrinted'] == true,
    pendingOps: (j['pendingOps'] as List? ?? const [])
        .map((o) => o.toString())
        .where(opOrder.contains)
        .toList(),
    lastError: j['lastError']?.toString(),
    conflict: j['conflict'] == true,
    billNumber: j['billNumber']?.toString(),
    // Drafts held before this field existed carry only the old claim text.
    claimed: j['claimed'] == true ||
        j['lastError'] == 'Another tablet is serving this table.',
    // Rows saved before this field existed read as "now" until next saved.
    createdAt: DateTime.tryParse(j['createdAt']?.toString() ?? ''),
  );
}

/// A bill settled on this tablet with no signal. It is money already taken,
/// so the row is never deleted to acknowledge a sync — it is marked [synced]
/// and keeps the order the server gave it.
///
/// [key] is the `Idempotency-Key` for `POST /restaurant/cart/offline-settle`:
/// a repeat of it answers with the bill it already made, never a second one.
/// [capturedAt] is what puts the revenue on the day the guest actually paid.
class OfflineSettlement {
  final String restaurantId;
  final String tableId;
  final String key;
  final String paymentType;

  /// The table as the waiter knows it — a row that needs attention has to be
  /// able to name the table, not just carry its id.
  final String tableNumber;

  /// What the guest was charged on the paper the tablet printed.
  final double printedTotal;
  final DateTime capturedAt;

  /// The provisional number on that paper (`OFF-…`), for the waiter to match
  /// it against the real order once it syncs.
  final String? billNumber;

  /// The cart the settlement was sent against, remembered once resolved so a
  /// lost answer is retried against the same order.
  final String? cartId;

  final bool synced;
  final String? orderId;
  final String? orderNo;

  /// The server re-prices at settle; set when its total differed from
  /// [printedTotal].
  final double? serverTotal;

  /// The server refused this settlement for good (409). Never retried.
  final bool conflict;

  /// The waiter said this bill was dealt with elsewhere (reconciled at the
  /// till). It stops asking to be sent, but the row itself stays: it is money
  /// history, and only a person can say what happened to it.
  final bool acknowledged;

  /// Why the last attempt did not land, for the waiter.
  final String? lastError;

  /// Failed attempts so far — the retry waits [retryAfter] between them.
  final int attempts;
  final DateTime? lastTriedAt;

  /// The sitting this bill was taken for: the items and print statuses that
  /// still have to reach the order before it can be billed. The settlement
  /// OWNS them — they leave the table's live draft at settle time, so the next
  /// sitting starts empty and can never be billed onto this one.
  final TableDraft? draft;

  const OfflineSettlement({
    required this.restaurantId,
    required this.tableId,
    required this.key,
    required this.paymentType,
    this.tableNumber = '',
    required this.printedTotal,
    required this.capturedAt,
    this.billNumber,
    this.cartId,
    this.synced = false,
    this.orderId,
    this.orderNo,
    this.serverTotal,
    this.conflict = false,
    this.acknowledged = false,
    this.lastError,
    this.attempts = 0,
    this.lastTriedAt,
    this.draft,
  });

  /// Still owed to the server, and still worth trying.
  bool get pending => !synced && !conflict;

  /// Money the server has not taken yet — a refused row counts, or the waiter
  /// would never learn that a bill they printed is not on any order.
  bool get unsettled => !synced;

  /// The printed paper and the server's own pricing disagree — the waiter has
  /// to be told, the ledger is the server's.
  bool get mismatched =>
      serverTotal != null && (serverTotal! - printedTotal).abs() >= 0.01;

  /// What the waiter is shown for a bill that cannot be sent.
  String get stuckReason =>
      lastError ?? 'The server would not take this bill.';

  /// How the waiter finds this bill: the table, and the number on the paper.
  String get label => [
    if (tableNumber.isNotEmpty) 'Table $tableNumber',
    if (billNumber != null && billNumber!.isNotEmpty) 'bill $billNumber',
  ].join(' · ');

  /// Backoff between attempts: 1, 2, 4 … minutes, capped at 15.
  static Duration retryAfter(int attempts) {
    if (attempts <= 0) return Duration.zero;
    final minutes = attempts >= 4 ? 15 : (1 << (attempts - 1));
    return Duration(minutes: minutes);
  }

  /// Due for another attempt (a fresh row always is).
  bool get dueNow {
    if (!pending) return false;
    final at = lastTriedAt;
    if (at == null || attempts == 0) return true;
    return DateTime.now().difference(at) >= retryAfter(attempts);
  }

  OfflineSettlement copyWith({
    String? cartId,
    bool? synced,
    String? orderId,
    String? orderNo,
    double? serverTotal,
    bool? conflict,
    bool? acknowledged,
    String? lastError,
    bool clearError = false,
    int? attempts,
    DateTime? lastTriedAt,
    TableDraft? draft,
    bool clearDraft = false,
  }) => OfflineSettlement(
    restaurantId: restaurantId,
    tableId: tableId,
    key: key,
    paymentType: paymentType,
    tableNumber: tableNumber,
    printedTotal: printedTotal,
    capturedAt: capturedAt,
    billNumber: billNumber,
    cartId: cartId ?? this.cartId,
    synced: synced ?? this.synced,
    orderId: orderId ?? this.orderId,
    orderNo: orderNo ?? this.orderNo,
    serverTotal: serverTotal ?? this.serverTotal,
    conflict: conflict ?? this.conflict,
    acknowledged: acknowledged ?? this.acknowledged,
    lastError: clearError ? null : (lastError ?? this.lastError),
    attempts: attempts ?? this.attempts,
    lastTriedAt: lastTriedAt ?? this.lastTriedAt,
    draft: clearDraft ? null : (draft ?? this.draft),
  );

  Map<String, dynamic> toJson() => {
    'restaurantId': restaurantId,
    'tableId': tableId,
    'key': key,
    'paymentType': paymentType,
    'tableNumber': tableNumber,
    'printedTotal': printedTotal,
    'capturedAt': capturedAt.toIso8601String(),
    'billNumber': billNumber,
    'cartId': cartId,
    'synced': synced,
    'orderId': orderId,
    'orderNo': orderNo,
    'serverTotal': serverTotal,
    'conflict': conflict,
    'acknowledged': acknowledged,
    'lastError': lastError,
    'attempts': attempts,
    'lastTriedAt': lastTriedAt?.toIso8601String(),
    'draft': draft?.toJson(),
  };

  factory OfflineSettlement.fromJson(Map<String, dynamic> j) =>
      OfflineSettlement(
        restaurantId: j['restaurantId'].toString(),
        tableId: j['tableId'].toString(),
        key: j['key'].toString(),
        paymentType: j['paymentType']?.toString() ?? 'CASH',
        tableNumber: j['tableNumber']?.toString() ?? '',
        printedTotal: (j['printedTotal'] as num?)?.toDouble() ?? 0,
        capturedAt:
            DateTime.tryParse(j['capturedAt']?.toString() ?? '') ??
            DateTime.now(),
        billNumber: j['billNumber']?.toString(),
        cartId: j['cartId']?.toString(),
        synced: j['synced'] == true,
        orderId: j['orderId']?.toString(),
        orderNo: j['orderNo']?.toString(),
        serverTotal: (j['serverTotal'] as num?)?.toDouble(),
        conflict: j['conflict'] == true,
        acknowledged: j['acknowledged'] == true,
        lastError: j['lastError']?.toString(),
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        lastTriedAt: DateTime.tryParse(j['lastTriedAt']?.toString() ?? ''),
        draft: j['draft'] is Map
            ? TableDraft.fromJson(Map<String, dynamic>.from(j['draft'] as Map))
            : null,
      );
}

/// Provisional bill numbers for paper handed out with no signal, the way the
/// admin exe mints them for offline pickup
/// (fatfox-admin-panel/src/app/pickup-offline/pickup-offline-id.ts): remember
/// the last number the server issued and continue from it locally, prefixed
/// `OFF-` so nobody mistakes one for the real number — that one arrives when
/// the settlement syncs. The sequence is stored per restaurant.
class OfflineBillNumbers {
  static const String _lastPrefix = 'waiter_last_bill_no_';
  static const String _seqPrefix = 'waiter_offline_bill_seq_';

  static bool isProvisional(String? no) => no != null && no.startsWith('OFF-');

  /// Records a number the server issued, if it is higher than the last one.
  static Future<void> remember(String rid, Object? billNo) async {
    if (rid.isEmpty || billNo == null) return;
    final digits = RegExp(r'\d+').firstMatch(billNo.toString())?.group(0);
    final n = int.tryParse(digits ?? '') ?? 0;
    if (n <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    if (n > (prefs.getInt('$_lastPrefix$rid') ?? 0)) {
      await prefs.setInt('$_lastPrefix$rid', n);
    }
  }

  /// The next provisional number, consumed as it is handed out.
  ///
  /// ALWAYS carries the device tag. Two tablets in the same outage have seen
  /// the same last server number, so continuing from it alone would have both
  /// print the same "next" one; the tag is what keeps them apart. The `OFF-`
  /// prefix keeps it clear of any number the server itself can issue.
  static Future<String> next(String rid) async {
    final prefs = await SharedPreferences.getInstance();
    final tag = (await DeviceIdService().get())
        .replaceAll(RegExp('[^a-zA-Z0-9]'), '')
        .padRight(4, '0')
        .substring(0, 4)
        .toUpperCase();
    final last = prefs.getInt('$_lastPrefix$rid') ?? 0;
    if (last > 0) {
      await prefs.setInt('$_lastPrefix$rid', last + 1);
      return 'OFF-$tag-${last + 1}';
    }
    // Nothing seen from the server yet: this device's own sequence.
    final seq = (prefs.getInt('$_seqPrefix$rid') ?? 0) + 1;
    await prefs.setInt('$_seqPrefix$rid', seq);
    return 'OFF-$tag-$seq';
  }
}

/// SharedPreferences persistence, restaurant-scoped. Unsent drafts survive
/// logout (they are sales); cart snapshots do not (they can hold guest names).
class DraftCartStore {
  static const String _draftPrefix = 'waiter_draft_';
  static const String _snapPrefix = 'waiter_cart_snap_';
  static const String _settlePrefix = 'waiter_settle_';

  static String _draftKey(String rid, String tid) => '$_draftPrefix${rid}_$tid';

  /// One row PER SETTLEMENT, not per table: a table settled twice in one
  /// outage holds two bills, and neither may overwrite the other.
  static String _settleKey(String rid, String tid, String key) =>
      '$_settlePrefix${rid}_${tid}_$key';

  /// Bills settled offline that are simply waiting for the next sync — the
  /// Sync chip shows these apart from tables with unsent items.
  static final ValueNotifier<int> pendingSettlements = ValueNotifier(0);

  /// Bills the tablet CANNOT send on its own: refused by the server, or with
  /// no order left to settle against. Money on paper that is on no order —
  /// these need a person, so they are listed, not counted.
  static final ValueNotifier<List<OfflineSettlement>> stuckSettlements =
      ValueNotifier(const []);

  /// Every settlement stored for [rid], oldest capture first.
  ///
  /// These are money already taken, so SharedPreferences is not trusted
  /// alone: a row it lost or can no longer decode comes back from its disk
  /// copy ([OutboxFileStore]) and is written back.
  Future<List<OfflineSettlement>> allSettlements(String rid) async {
    if (rid.isEmpty) return const [];
    final prefs = await SharedPreferences.getInstance();
    final prefix = '$_settlePrefix${rid}_';
    final byKey = <String, OfflineSettlement>{};
    for (final k in prefs.getKeys().where((k) => k.startsWith(prefix))) {
      final s = _decodeSettlement(prefs.getString(k));
      if (s != null && s.restaurantId == rid) byKey[k] = s;
    }
    for (final file in await OutboxFileStore.keys(prefix)) {
      if (byKey.containsKey(file)) continue;
      final json = await OutboxFileStore.atomicRead(file);
      if (json == null) continue;
      try {
        final s = OfflineSettlement.fromJson(json);
        // The row's own key, not the (sanitised) file name.
        final k = _settleKey(s.restaurantId, s.tableId, s.key);
        if (s.restaurantId != rid || byKey.containsKey(k)) continue;
        byKey[k] = s;
        await prefs.setString(k, jsonEncode(json));
      } catch (_) {}
    }
    final out = byKey.values.toList()
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    return out;
  }

  /// This table's settlements, oldest capture first — a table may hold more
  /// than one when several sittings were billed during the same outage.
  Future<List<OfflineSettlement>> settlementsFor(String rid, String tid) async {
    if (tid.isEmpty) return const [];
    return (await allSettlements(rid)).where((s) => s.tableId == tid).toList();
  }

  static OfflineSettlement? _decodeSettlement(String? raw) {
    if (raw == null) return null;
    try {
      return OfflineSettlement.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  /// Writes a settlement under its own idempotency key. Rows are money: this
  /// only ever adds or updates the row that key names, never another.
  Future<void> saveSettlement(OfflineSettlement s) async {
    final prefs = await SharedPreferences.getInstance();
    final k = _settleKey(s.restaurantId, s.tableId, s.key);
    final jsonMap = s.toJson();
    final jsonStr = jsonEncode(jsonMap);
    await prefs.setString(k, jsonStr);
    await OutboxFileStore.atomicWrite(k, jsonMap);
    await refreshPendingSettlements(s.restaurantId);
  }

  Future<void> refreshPendingSettlements(String rid) async {
    final rows = await allSettlements(rid);
    // Counted once, in one place or the other: a bill that needs a person is
    // not also a bill that is "waiting for the next sync".
    pendingSettlements.value =
        rows.where((s) => s.pending && s.lastError == null).length;
    // Anything the tablet cannot move on its own: refused outright, or held
    // with a reason. A held bill under "sent on the next sync" is a lie.
    stuckSettlements.value = List.unmodifiable(
      rows.where((s) => !s.synced && (s.conflict || s.lastError != null)),
    );
  }

  /// Tables on this tablet with unsent items — drives the Sync chip badge.
  static final ValueNotifier<int> pendingTables = ValueNotifier(0);

  /// Every stored draft for [rid] (other restaurants' rows are never read).
  Future<List<TableDraft>> all(String rid) async {
    if (rid.isEmpty) return const [];
    final prefs = await SharedPreferences.getInstance();
    final out = <TableDraft>[];
    final keys = prefs.getKeys().where((k) => k.startsWith('$_draftPrefix${rid}_')).toList();
    for (final k in keys) {
      final d = await load(rid, k.substring('$_draftPrefix${rid}_'.length));
      if (d != null) out.add(d);
    }
    return out;
  }

  /// Recounts [pendingTables] for [rid]. A row kept only to replay a print's
  /// status holds no items, so it must not show as a table waiting to send.
  Future<void> refreshPending(String rid) async {
    pendingTables.value = (await all(rid)).where((d) => d.hasItems).length;
  }
  static String _snapKey(String rid, String tid) => '$_snapPrefix${rid}_$tid';

  Future<TableDraft?> load(String rid, String tid) async {
    if (rid.isEmpty || tid.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final k = _draftKey(rid, tid);
    final raw = prefs.getString(k);
    if (raw != null) {
      try {
        final d = TableDraft.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        return d.restaurantId == rid && d.tableId == tid ? d : null;
      } catch (_) {
        // Corrupted SharedPreferences string — attempt recovery from disk backup
        final diskJson = await OutboxFileStore.atomicRead(k);
        if (diskJson != null) {
          final d = TableDraft.fromJson(diskJson);
          return d.restaurantId == rid && d.tableId == tid ? d : null;
        }
        return null;
      }
    }
    return null;
  }

  /// Saves, or deletes when there is nothing left to send.
  Future<void> save(TableDraft d) async {
    final prefs = await SharedPreferences.getInstance();
    final k = _draftKey(d.restaurantId, d.tableId);
    if (d.isEmpty) {
      await prefs.remove(k);
      await OutboxFileStore.atomicRemove(k);
    } else {
      final jsonMap = d.toJson();
      await prefs.setString(k, jsonEncode(jsonMap));
      await OutboxFileStore.atomicWrite(k, jsonMap);
    }
    await refreshPending(d.restaurantId);
  }

  Future<void> delete(String rid, String tid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_draftKey(rid, tid));
    // Or a later corrupt read would "recover" these already-settled items.
    await OutboxFileStore.atomicRemove(_draftKey(rid, tid));
    await refreshPending(rid);
  }

  /// Last server view of a table, so it can still be opened offline. Stamped,
  /// because paper may only be printed from a copy that is still young.
  Future<void> saveSnapshot(
    String rid,
    String tid, {
    Map<String, dynamic>? table,
    required List<Map<String, dynamic>> cart,
  }) async {
    if (rid.isEmpty || tid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    // A background sync knows the cart but not the table header; keep the one
    // already stored rather than losing the table number.
    final header = table ?? (await loadSnapshot(rid, tid))?.table;
    await prefs.setString(
      _snapKey(rid, tid),
      jsonEncode({
        'table': header,
        'cart': cart,
        'at': DateTime.now().toIso8601String(),
      }),
    );
  }

  /// This copy is known to be behind the server (items were just uploaded
  /// from it). Durable, so a later offline open cannot print from it — only a
  /// fresh [saveSnapshot] clears the mark.
  Future<void> markSnapshotStale(String rid, String tid) async {
    if (rid.isEmpty || tid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final snap = await loadSnapshot(rid, tid);
    await prefs.setString(
      _snapKey(rid, tid),
      jsonEncode({
        'table': snap?.table,
        'cart': snap?.cart ?? const [],
        'at': snap?.at?.toIso8601String(),
        'stale': true,
      }),
    );
  }

  Future<
    ({
      Map<String, dynamic>? table,
      List<Map<String, dynamic>> cart,
      DateTime? at,
      bool stale,
    })?
  >
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
        at: DateTime.tryParse(j['at']?.toString() ?? ''),
        stale: j['stale'] == true,
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

  /// Logout. Only snapshots go: the outbox's disk copies back up unsent
  /// drafts and offline settlements, which are sales and survive logout.
  static Future<void> clearSnapshots() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys().where((k) => k.startsWith(_snapPrefix))) {
      await prefs.remove(k);
    }
  }
}

/// Atomic disk-file persistence backup for [DraftCartStore].
///
/// Operates with write-ahead atomic file operations (`.tmp` write + sync + rename)
/// to ensure zero loss or corruption of unsent drafts or offline settlements
/// even during sudden OS crashes or battery shutdowns.
///
/// Lives in the app's documents directory: the temp/cache directory it used
/// to use is the one Android clears under storage pressure. Files left there
/// by older builds are moved over once.
class OutboxFileStore {
  static const String _name = 'fatfox_dinein_outbox';

  // One lookup (and one migration) however many callers race at start-up.
  static Future<Directory?>? _dir;
  static Future<Directory?> _getDir() => _dir ??= _openDir();

  /// Tests get their own folder: files outlive a prefs reset and a test run,
  /// and test files run in parallel.
  @visibleForTesting
  static void useDirectoryForTesting(Directory dir) => _dir = Future.value(dir);

  static Future<Directory?> _openDir() async {
    try {
      final legacy = Directory('${Directory.systemTemp.path}/$_name');
      Directory dir;
      try {
        dir = Directory('${(await getApplicationDocumentsDirectory()).path}/$_name');
      } catch (_) {
        dir = legacy; // no platform channel (unit tests)
      }
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      if (dir.path != legacy.path && await legacy.exists()) {
        await for (final f in legacy.list()) {
          if (f is! File || !f.path.endsWith('.json')) continue;
          final to = File('${dir.path}/${f.uri.pathSegments.last}');
          if (await to.exists()) continue;
          // Copy then rename: a crash mid-copy must not leave a torn file
          // that hides the original once the old folder is gone.
          await (await f.copy('${to.path}.tmp')).rename(to.path);
        }
        await legacy.delete(recursive: true);
      }
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// Keys of every stored file whose key starts with [prefix]. Keys written
  /// by [DraftCartStore] are already filename-safe, so a name is its key.
  static Future<List<String>> keys(String prefix) async {
    try {
      final dir = await _getDir();
      if (dir == null) return const [];
      return [
        await for (final f in dir.list())
          if (f is File && f.path.endsWith('.json'))
            f.uri.pathSegments.last.replaceFirst(RegExp(r'\.json$'), ''),
      ].where((k) => k.startsWith(prefix)).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> atomicWrite(String key, Map<String, dynamic> json) async {
    try {
      final dir = await _getDir();
      if (dir == null) return;
      final sanitized = key.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final file = File('${dir.path}/$sanitized.json');
      final tmp = File('${dir.path}/$sanitized.tmp');
      final content = jsonEncode(json);
      await tmp.writeAsString(content, flush: true);
      await tmp.rename(file.path);
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> atomicRead(String key) async {
    try {
      final dir = await _getDir();
      if (dir == null) return null;
      final sanitized = key.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final file = File('${dir.path}/$sanitized.json');
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> atomicRemove(String key) async {
    try {
      final dir = await _getDir();
      if (dir == null) return;
      final sanitized = key.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final file = File('${dir.path}/$sanitized.json');
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  static Future<void> clearAll() async {
    try {
      final dir = await _getDir();
      if (dir != null && await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is File) {
            await entity.delete();
          }
        }
      }
    } catch (_) {}
  }
}
