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
5. **SAVE & PRINT** — payment sheet (Cash/Card/UPI) → `setcarttobill` → receipt print.

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
