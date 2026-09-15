# FatFox Waiter App (Flutter)

Staff dine-in POS for Android/iOS tablets and phones. Same backend as admin panel: `/api/v1/restaurant/*`.

**Remote:** `git@github.com:Gagan-k0/dininapk.git`  
**Package:** `com.fatfox.dinein.dineinapk`  
**Branch notes:** live KOT uses `setcartstatus` (not offline `createorder`).

## Run on USB tablet

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export PATH="$JAVA_HOME/bin:$HOME/Library/Android/sdk/platform-tools:$PATH"

cd fatfox-waiter-app
flutter pub get
adb devices
flutter run -d <deviceId>
```

Tablet must resolve `backend.fatfox.testfox.in` in Chrome before login works (DNS/Wi‑Fi).

## Silent LAN print

1. Open **Printer Settings** in the app.
2. Connection type **LAN**, set printer IP, port `9100`, paper 58/80mm.
3. **Test Print** — must succeed with no system dialog.
4. **KOT PRINT** — `setcartstatus(KOT)` → `viewmenu?status=kot` → TCP print → `setcartstatus(KOT_PRINT)` only if print OK.
5. **PRINT BILL** — open the table, build the receipt from its complete cart snapshot, print over LAN, then mark the cart `PRINTED`.
6. **RELEASE** — from the opened table only, enabled for `PRINTED`/`PAID`; payment sheet (Cash/Card/UPI) → `setcarttobill`. Release never calls `deletecart`.

## API response rule

FatFox frequently returns HTTP 200 for both success and refusal. All authenticated
requests go through `ApiClient` and use `status.code` as the verdict:

- `200` or `0` — success
- `401` or `2024` — expired session
- any other `4xx`/`5xx` envelope code — refusal; show `status.message` unchanged

Do not branch on HTTP status alone. A failed refresh keeps the last-known floor on
screen and marks it stale; it must not look like an empty restaurant.

## Billing and receipt state

- The bill total comes from cart `total_price` (not the absent `grand_total` key).
- Receipt lines come from the complete, cancellation-filtered cart snapshot.
- KOT lines are locked after they have been sent to the kitchen.
- Paper size, printer address, and receipt options are device-local preferences.
- The legacy `/pos` route/screen has been removed; open a floor table to enter
  `/food-categories`.

## Feature status (Order-taking MVP)

| Feature | Status |
|---------|--------|
| Login (restaurant / staff + demo UI bypass) | Done |
| Table floor + areas | Done |
| Menu + variants/addons (open table → `/food-categories`) | Done |
| Live KOT (`setcartstatus`) + LAN print | Done |
| Settle + payment method + discount chips | Done |
| Shift table (long-press / swap icon) | Done |
| Unify POS (drawer no longer opens legacy `/pos`) | Done |
| QR PENDING Accept / Reject | Done |
| Offline drafts + settle outbox | Next (OT-3) |
| Split bill UI | Deferred |
| Live-order detail / reservation CRUD | Deferred |

## Demo login

`admin@example.com` / `mypassword` → local UI only (no API). Real restaurant credentials required for KOT/settle/tables.
