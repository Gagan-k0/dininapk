# Graph Report - wt-waiter-subscription  (2026-09-17)

## Corpus Check
- 115 files · ~78,883 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 611 nodes · 727 edges · 18 communities (17 shown, 1 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `b3ff3ccb`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 12|Community 12]]
- [[_COMMUNITY_Community 13|Community 13]]
- [[_COMMUNITY_Community 14|Community 14]]
- [[_COMMUNITY_Community 15|Community 15]]
- [[_COMMUNITY_Community 16|Community 16]]
- [[_COMMUNITY_Community 17|Community 17]]

## God Nodes (most connected - your core abstractions)
1. `PosProvider` - 16 edges
2. `state` - 7 edges
3. `_DineInTableScreenState` - 6 edges
4. `build` - 5 edges
5. `_FatfoxDineInAppState` - 4 edges
6. `_FoodCategoriesScreenState` - 4 edges
7. `_relogin` - 4 edges
8. `FatfoxDineInApp` - 3 edges
9. `ApiException` - 3 edges
10. `map` - 3 edges

## Surprising Connections (you probably didn't know these)
- `_FatfoxDineInAppState` --inherits--> `state`  [EXTRACTED]
  lib/main.dart → lib/services/subscription_rules.dart
- `build` --references--> `PosProvider`  [EXTRACTED]
  lib/views/pos/food_categories_screen.dart → lib/providers/pos_provider.dart
- `didChangeDependencies` --references--> `PosProvider`  [EXTRACTED]
  lib/views/pos/food_categories_screen.dart → lib/providers/pos_provider.dart
- `_FoodCategoriesScreenState` --references--> `PosProvider`  [EXTRACTED]
  lib/views/pos/food_categories_screen.dart → lib/providers/pos_provider.dart
- `build` --references--> `PosProvider`  [EXTRACTED]
  lib/views/tables/dinein_table_screen.dart → lib/providers/pos_provider.dart

## Import Cycles
- None detected.

## Communities (18 total, 1 thin omitted)

### Community 0 - "Community 0"
Cohesion: 0.01
Nodes (163): DateTime? get, DineInTable?, DineInTable? get, double get, DraftCartStore, int get, MenuCacheService, ../models/cart_model.dart (+155 more)

### Community 1 - "Community 1"
Cohesion: 0.03
Nodes (61): MenuItem, MenuPageWindow, _addItemAndShowResult, _buildActionButtons, _buildAppBar, _buildCartErrorBar, _buildCartItem, _buildCollapsedCartStrip (+53 more)

### Community 2 - "Community 2"
Cohesion: 0.04
Nodes (50): ../../models/menu_model.dart, ApiService, _authService, cancelCartMenuItem, _client, createCartItem, decideQrOrder, _decodeOrNull (+42 more)

### Community 3 - "Community 3"
Cohesion: 0.04
Nodes (45): addToCart, allAvailableAddons, allVariants, ApiConfig, availableDiscounts, baseUrl, billView, cancelCartMenu (+37 more)

### Community 4 - "Community 4"
Cohesion: 0.05
Nodes (44): dart:async, dart:convert, dart:io, Exception, List, package:cryptography/cryptography.dart, package:dineinapk/models/menu_model.dart, package:dineinapk/providers/pos_provider.dart (+36 more)

### Community 5 - "Community 5"
Cohesion: 0.05
Nodes (39): Client, device_id_service.dart, DeviceIdService, ApiClient, ApiEnvelope, _auth, claimHeldBy, code (+31 more)

### Community 6 - "Community 6"
Cohesion: 0.05
Nodes (36): ../../models/table_model.dart, _acceptQrOrder, _asDouble, _buildAreaChip, _buildDineInTablesDashboard, _buildFullError, _buildFullWidthSubTab, _buildKpiCard (+28 more)

### Community 7 - "Community 7"
Cohesion: 0.06
Nodes (32): bool get, DateTime?, Duration, int?, return, clockRollbackSlack, _date, daysLeft (+24 more)

### Community 8 - "Community 8"
Cohesion: 0.07
Nodes (29): ApiService, AuthService, ChangeNotifier, _apiService, AuthProvider, _authService, checkSession, clearSessionNotice (+21 more)

### Community 9 - "Community 9"
Cohesion: 0.07
Nodes (28): GlobalKey, appNavigatorKey, auth, authProvider, build, checkSession, createState, didChangeAppLifecycleState (+20 more)

### Community 10 - "Community 10"
Cohesion: 0.08
Nodes (24): api_client.dart, auth_service.dart, ../config/api_config.dart, connectivity_service.dart, package:flutter/foundation.dart, apply, _current, instance (+16 more)

### Community 11 - "Community 11"
Cohesion: 0.22
Nodes (9): package:flutter/services.dart, package:intl/intl.dart, ../../services/connectivity_service.dart, build, _checkAgain, _checking, createState, SubscriptionLockedScreen (+1 more)

### Community 12 - "Community 12"
Cohesion: 0.28
Nodes (9): AuthProvider, Route /settings/printer, TableProvider, build, DineInTableScreen, _DineInTableScreenState, initState, _relogin (+1 more)

### Community 13 - "Community 13"
Cohesion: 0.25
Nodes (7): package:flutter/material.dart, _CartBottomSheet, ../services/subscription_service.dart, StatelessWidget, build, _daysUntil, SubscriptionBanner

### Community 14 - "Community 14"
Cohesion: 0.25
Nodes (8): build, didChangeDependencies, PosProvider, Route /food-categories, _openPos, _printBillFromFloor, _settleFromFloor, _showShiftTableDialog

### Community 15 - "Community 15"
Cohesion: 0.32
Nodes (8): _CustomExtraDialog, _CustomExtraDialogState, _ExtraAmountDialog, _ExtraAmountDialogState, FoodCategoriesScreen, _FoodCategoriesScreenState, state, StatefulWidget

### Community 16 - "Community 16"
Cohesion: 0.67
Nodes (3): FatfoxDineInApp, _FatfoxDineInAppState, WidgetsBindingObserver

## Knowledge Gaps
- **451 isolated node(s):** `ApiConfig`, `baseUrl`, `restaurantLogin`, `staffLogin`, `login` (+446 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `PosProvider` connect `Community 14` to `Community 0`, `Community 1`, `Community 6`, `Community 8`, `Community 9`, `Community 12`, `Community 15`?**
  _High betweenness centrality (0.087) - this node is a cross-community bridge._
- **Why does `state` connect `Community 15` to `Community 16`, `Community 11`, `Community 12`, `Community 7`?**
  _High betweenness centrality (0.030) - this node is a cross-community bridge._
- **Why does `map` connect `Community 8` to `Community 0`, `Community 5`?**
  _High betweenness centrality (0.013) - this node is a cross-community bridge._
- **What connects `ApiConfig`, `baseUrl`, `restaurantLogin` to the rest of the system?**
  _451 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.012195121951219513 - nodes in this community are weakly interconnected._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.03225806451612903 - nodes in this community are weakly interconnected._
- **Should `Community 2` be split into smaller, more focused modules?**
  _Cohesion score 0.0392156862745098 - nodes in this community are weakly interconnected._