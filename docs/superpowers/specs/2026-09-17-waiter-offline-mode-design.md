# Waiter app — offline/online mode + API-call reduction

Status: approved design, 2026-09-17. Branch `feat/waiter-offline-mode` (worktree
`wt-waiter-offline-mode`), based on `origin/master` @ 1b3976e.

## Goal

1. The POS feels instant: tapping items never waits for the server.
2. Dine-in keeps working with no connectivity, to the same limits the admin panel
   allows (add items, adjust qty on unsynced lines, release).
3. A visible Sync switch with a pending count, so nothing is lost silently.

## Decided scope (user, 2026-09-17)

* **Offline-capable:** add item, qty change on *own unsynced* lines, release table.
* **Online-only:** KOT, bill print, settle, discount, split, customer, QR approval.
  Rationale: the api-server offline contract covers draft lines + settle only; a
  fully offline KOT/bill design was reviewed and rejected in this workspace.
* **Online cart:** local-first, flushed in ONE request on KOT/Bill.
* **Conflicts:** surfaced to the waiter (Retry / Move / Discard), never auto-resolved.

## Server contract (already on api-server `main`, verified 2026-09-17)

* `POST /restaurant/cart/offline-sync` — `dineinOfflineSync.controller.js`.
  Body `{ table_id, lines[], captured_at, device_id? }`, header `Idempotency-Key`.
  * Receipt keyed `(restaurant_id, idempotency_key)` in `offline_apply_receipt`.
  * Same key + same content → `200 sync_result:'duplicate'` (safe retry).
  * Same key + **different** content → `409 conflict` — terminal, never auto-retry.
  * Lines merge through the server's own `findMatchingCartLine`; prices are
    re-resolved server-side (client prices are never trusted).
  * Refusals: `422 no_cart | empty_draft | item_bad_quantity | menu_not_found |
    extra_addon_bad_price | cart_locked_by_paid_split`,
    and `table_claimed_by_another_device` (claim gate).
* `POST /restaurant/cart/offline-settle` — not used in this scope (settle stays online).
* **Table claim** (`helpers/tableClaim.js`): one device per table, TTL 4h, renewed by
  the holder. Device id from `x-device-id` / `x-till-id` header, else `staff:<id>`.
  **`createcart` claims too** (`cart.controller.js:321`), so this applies online today.
* **No `/health` endpoint on `main`** — the admin panel's probe design cannot be copied.

## Architecture

### Connectivity (`lib/services/connectivity_service.dart`, new)

* State: `online | offlineManual | offlineNoSignal`. Manual is persisted.
* Transitions **from real request outcomes**: any `ApiException.isNetwork` marks
  no-signal; a success marks online. No OS network flag (lies on captive Wi-Fi).
* While no-signal, one cheap probe (`GET /restaurant/tax/settax`, already used by the
  POS) every 20s, `background: true` so a 401 can't log the waiter out.
* Exposed through a `ChangeNotifier` consumed by the app bar switch.

### Device identity (`lib/services/device_id_service.dart`, new)

* Random 128-bit id, generated once, stored in SharedPreferences (`waiter_device_id`).
* Sent as `x-device-id` on every request (`ApiConfig.headers`). Not derived from any
  user or hardware identifier.

### Local store (`lib/services/offline_store.dart`, new)

* **No new packages** — `sqflite`/`hive` are not in the local pub cache and would need
  network + a new dependency. JSON in SharedPreferences, one key per table:
  * `waiter_draft_<rid>_<tableId>` — `{ localId, lines[], capturedAt, idempotencyKey }`
  * `waiter_outbox_<rid>` — index of table ids with unsent drafts + last error.
* Keys are restaurant-scoped; a mismatched `rid` is never read.
* Logout clears drafts **except** unsent ones, which survive and are counted
  (losing them loses sales).

### Menu cache (`lib/services/menu_cache_service.dart`, exists)

* Add `cachedAt` age check. `loadTableAndMenu` skips the 6 catalog calls when the cache
  is younger than 6h or the app is offline → table open drops from 7 requests to 1
  (cart only), and 0 offline.
* "Menu updated Xh ago" + **Sync menu** button forces a refresh.

### Cart engine (`lib/providers/pos_provider.dart`)

* Taps write to the draft, not the network. The painted cart = server snapshot +
  draft lines, marked "NOT SENT". Draft lines count as un-KOT'd, so Bill and Release
  stay blocked until KOT sends them.
* **Exception (verified 2026-09-17):** `offline-sync` answers `422 no_cart` on a table
  with no cart. Online, the first tap on an empty table goes straight to `createcart`.
  A draft started with no cart opens one at flush via `createcart` for its first
  line. That line is persisted as a locked `creatingLine` first: if the answer is
  lost it is matched against the live cart; if the table has no cart any more it is
  parked as a conflict (it may be on a bill that closed) and never re-created
  automatically. A refused `createcart` puts the line back as an editable line.
* Taps are refused while a send is in flight; a send is pinned to its own table; a
  cart that could not be re-read after a send blocks KOT, bill and release until it
  is fetched again.
* `flushDraft()` re-reads the live cart and compares it with the draft's baseline cart
  id; any difference is a conflict (never auto-applied). Then one `offline-sync` with
  the stored `Idempotency-Key`. Called by KOT (Phase 4 adds Sync and reconnect).
* **Key rule (corrected from admin's implementation):** the key is minted once and
  kept through every edit. A lost response then re-sends as a duplicate (same
  content) or a 409 conflict (edited) — never a second copy. A new key is minted only
  by an explicit "Send again" on a conflict (Phase 4). The earlier "re-key on edit"
  rule would have double-billed after a lost response.
* **Server pricing gap:** `offline-sync` on api-server main only sums line prices
  (tax, area charge and round-off go stale). The tablet re-saves one line's quantity
  afterwards to trigger full pricing; api-server PR #294 fixes the endpoint, after
  which that extra request is removed.

## Phases

| Phase | Content | Risk |
|---|---|---|
| 1 | Device id header, classify `table_claimed_by_another_device`, menu cache TTL + skip | low, no behaviour change offline |
| 2 | Connectivity service + Sync switch + offline gating of online-only actions | low |
| 3 | Draft store + local-first taps + `flushDraft` on KOT/Bill | high — money path |
| 4 | Outbox, pending badge, conflict UI (Retry / Move / Discard), reconnect flush | medium |
| 5 | Hardening: tests, security review, on-device verification | — |

Each phase: `flutter analyze` + `flutter test` clean, an independent skeptic pass on the
diff, then commit. No push without the user's approval.

## Security

* Drafts hold menu ids, quantities and notes — no card or personal data.
* Prices in a draft are display-only; the server re-prices every line.
* Device id is random, not personal, and only scopes the table claim.
* Sync traffic uses `background: true`, so a background 401 never logs a waiter out
  mid-shift; it surfaces as "sign in again to sync".
* Drafts are cleared on logout except unsent ones, which are retained for the same
  restaurant only.

## Known risks

* Draft items are invisible to other devices and the admin panel until KOT.
* A tablet that never regains signal holds those sales until someone syncs it.
* The table claim can refuse a waiter whose colleague's tablet touched the table first;
  Phase 4's conflict UI is the only mitigation.
