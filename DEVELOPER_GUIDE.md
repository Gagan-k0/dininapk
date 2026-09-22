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

## Silent thermal print (auto-detect)

Keeps **ESC/POS silent** print (no Android PrintManager / system dialog).

1. Open **Printer Settings**.
2. Choose **LAN** or **Bluetooth** (USB/Sunmi not wired yet).
3. Tap **Scan for printers**:
   - **LAN** — probes the tablet Wi‑Fi `/24` subnet for TCP port `9100` (override port if needed).
   - **Bluetooth** — lists paired classic devices (pair the printer in Android Settings first).
4. Tap a result to select, or type a LAN IP manually. Save. **Test Print** must succeed with no system dialog.
5. Optional: **Allow release without printed bill** (`kot_enable_release_table`) — matches admin `kotEnableReleaseTable`.
6. **KOT PRINT** — `setcartstatus(KOT)` → print → `setcartstatus(KOT_PRINT)` only if print OK.
7. **PRINT BILL** — complete cart snapshot → ESC/POS → mark `PRINTED`.
8. **RELEASE** — from the opened table; `PRINTED`/`PAID` (or KOT path when the toggle is on) → payment → `setcarttobill`. Never `deletecart`.

Prefs keys: `printer_type`, `printer_ip`, `printer_port`, `printer_bt_mac`, `printer_bt_name`, `printer_paper`, `printer_header`, `kot_enable_release_table`.

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

## Release signing

Release APKs must all be signed with **one shared key**. Each machine's debug key is different, so an APK built on another machine cannot install over the app on a tablet: Android refuses the update, and uninstalling first **deletes unsynced offline bills, drafts and printer settings**.

One-time setup (whoever owns releases):

```bash
keytool -genkey -v -keystore ~/fatfox-waiter-release.jks -keyalg RSA \
  -keysize 2048 -validity 10000 -alias fatfox-waiter
```

Create `android/key.properties` (git-ignored, never commit it or the `.jks`):

```properties
storeFile=/absolute/path/to/fatfox-waiter-release.jks
storePassword=...
keyAlias=fatfox-waiter
keyPassword=...
```

Share the `.jks` and passwords with other release builders through a password manager, not chat or git. Without `key.properties` the build still works, but it prints a warning and signs with the local debug key.

**Switching a tablet to the release key** needs one last uninstall. Before uninstalling, open the app online and wait until the Sync chip shows nothing pending. Otherwise unsynced offline bills are lost.

