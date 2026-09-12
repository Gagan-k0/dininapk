# 📱 Fatfox Dine-In Mobile Application (`Dineinapk`)

> **Comprehensive Audit & Handoff Guide for AI Agents & Developers**  
> **Last Updated**: September 11, 2026  
> **Repository**: [https://github.com/Gagan-k0/dininapk.git](https://github.com/Gagan-k0/dininapk.git)  
> **Backend Base URL**: `https://backend.fatfox.testfox.in/api/v1`  
> **Web Admin Panel Reference**: `https://fatfox-admin-panel.vercel.app/` (`fatfox-admin-panel`)

---

## 🎯 Executive Summary

The `Dineinapk` project is a native Flutter Android application designed for restaurant waiters, POS operators, and staff to handle **Dine-In Table Management**, **Food Ordering**, **Backend Cart Synchronization**, and **KOT Thermal Printing** directly on mobile devices and Sunmi POS terminals.

This document presents a **feature-by-feature comparative audit** between the Angular Web Admin Panel (`fatfox-admin-panel`) and this mobile Flutter app (`Dineinapk`), detailing what is **100% Completed**, what **Bugs Were Fixed**, and what is **Pending for Future Agent Iterations**.

---

## 🔍 Feature-by-Feature Audit: Website (`fatfox-admin-panel`) vs. Mobile App (`Dineinapk`)

| Feature Module | Web Panel (`fatfox-admin-panel`) | Mobile App (`Dineinapk`) | Implementation Status | Notes / Gaps |
|---|---|---|---|---|
| **Authentication & Auth Token** | Login form, saves token to `localStorage` | Login screen, saves token via `SharedPreferences` | `[x] COMPLETED` | Live auth with bearer token header |
| **Table Dashboard Overview** | `/#/dineIn-table-list` — 40 tables across 5 areas | `DineInTableScreen` — 40 live tables across 5 areas | `[x] COMPLETED` | Live backend sync (`/restaurant/table/all?searchNumber=`) |
| **Dashboard Metrics Cards** | Total Tables (40), Available (28), Occupied (7), KOT (5), Pre-Booking, Live Orders | Dynamic metric cards header | `[x] COMPLETED` | Live dynamic counts from API |
| **Area Filtering Tabs** | AC Dining, Family Section, Non-AC Dining, Outdoor, VIP Lounge | Horizontal scrollable chip bar for areas | `[x] COMPLETED` | Fetched dynamically from `/table/area/all-avaliable?searchName=` |
| **Table Card Status & Details** | Status colors (Blank/Occupied/KOT), Timer, Total Amount, Capacity, Customer | Custom responsive table cards matching Web UI | `[x] COMPLETED` | Real-time status badges and pricing |
| **Food Categories & Menu Grid** | `/#/dineIn-food-categories?tableId=...&areaId=...` | `FoodCategoriesScreen` (`/pos`) | `[x] COMPLETED` | Dynamic category tabs & 235+ menu items |
| **Food Item Search & Filters** | Instant text search + Veg/Non-Veg filter chips | Integrated Search Bar + Veg/Non-Veg filter | `[x] COMPLETED` | Instant client-side & API search filtering |
| **Live Backend Cart Sync** | Add to cart, update qty (+/-), remove item via REST API | Live synchronization via `PosProvider` | `[x] COMPLETED` | Calls `/cart/add-to-cart`, `/cart/update-quantity`, `/cart/remove-item` |
| **KOT Order Submission** | "Print KOT" / "Create Order" button | KOT PRINT via setcartstatus | `[x] COMPLETED` | Live path: KOT → print → KOT_PRINT |
| **Thermal Printer Integration** | Web browser `window.print()` / ESC-POS service | `ThermalPrinterService` (Bluetooth / Sunmi / ESC-POS) | `[x] COMPLETED` | Native ESC/POS printing over Bluetooth & USB |
| **Variants & Addons Selection** | Modal popup when tapping items with variants/addons | Bottom sheet on item tap | `[x] COMPLETED` | Wired 2026-09-12 |
| **Payment Settlement & Billing** | Settlement modal: Cash, Card, UPI, Room Charge, Split Pay | Settle sheet Cash/Card/UPI→ONLINE + discount | `[x] COMPLETED` | Room Charge / split still deferred |
| **Split Bill Functionality** | `dinein-split-bill` modal (split by seat/equal) | Not yet exposed in UI | `[ ] PENDING` | Backend API `/cart/split-bill` needs Flutter UI screen |
| **Table Shift / Merge Table** | Move cart items from Table A to Table B | Shift via long-press / swap icon | `[/] PARTIAL` | Shift done; merge deferred |
| **Discounts & Coupon Codes** | Apply percentage/flat discount to cart | Available-discount chips on settle sheet | `[x] COMPLETED` | Uses setcartdiscount |
| **Pre-Booking / Reservations** | `dinein-prebooking` list & booking modal | Pre-booking tab with live list count | `[/] PARTIAL` | Pre-booking list displayed, new booking creation pending |
| **Live Orders Full View** | Dedicated `live-orders` page with order management | Live Orders tab inside `DineInTableScreen` | `[/] PARTIAL` | Displays live order list, detail view modal pending |
| **Table QR Code Generation** | `generate-dinein-qrcode` (prints table QR code) | Not present | `[ ] LOW PRIORITY` | Desktop/Web feature only |

---

## 🐛 Bug Fixes & Gotchas History (Crucial for Future Agents)

### 1. 🚨 Backend Query Parameter Regex Matching Bug (`table.controller.js` & `table_area.controller.js`)
* **Symptom**: Mobile app table list and area list returned 0 results (`[]`), whereas the website showed 40 tables and 5 areas.
* **Root Cause**: The backend controllers construct Regex searches like `new RegExp(req.query.searchNumber, 'i')`. When query parameters `searchNumber` or `searchName` were missing from the URL, Express/Node evaluated `req.query.searchNumber` as the string `"undefined"`. MongoDB then searched for tables named `"undefined"`, returning 0 records.
* **Fix**: Always append explicit query parameter string keys in API endpoint URLs:
  * Table All: `/restaurant/table/all?searchNumber=`
  * Table Areas: `/restaurant/table/area/all-avaliable?searchName=`
* **Files Touched**: `lib/config/api_config.dart`, `lib/services/api_service.dart`.

### 2. 🚨 Missing `PosProvider` Import in `dinein_table_screen.dart`
* **Symptom**: Release APK build failed (`assembleRelease` exit code 1) with `Error: 'PosProvider' isn't a type`.
* **Fix**: Added `import '../../providers/pos_provider.dart';` at line 5 of `lib/views/tables/dinein_table_screen.dart`.

---

## 🛠️ Architecture & Code Map (`Dineinapk`)

```
Dineinapk/lib/
├── config/
│   └── api_config.dart          # Centralized API URLs, base headers, & REST endpoints
├── models/
│   ├── cart_model.dart          # Models for Cart, CartItem, Addons, Variants, Taxes
│   ├── menu_model.dart          # Models for Categories and Menu Items
│   └── table_model.dart         # Models for Tables, Table Areas, and Reservations
├── providers/
│   ├── auth_provider.dart       # State for JWT Login, Restaurant Profile, Auth Token
│   ├── table_provider.dart      # State for Table Grid, Area Tabs, Metrics, Live Orders
│   └── pos_provider.dart        # State for Active Cart, Menu Items, Categories, KOT Submit
├── services/
│   ├── api_service.dart         # HTTP Client (GET/POST/PUT/DELETE) with Bearer token
│   ├── auth_service.dart        # Persistent SharedPreferences auth storage
│   └── thermal_printer_service.dart # Bluetooth & ESC/POS Thermal Printer driver
└── views/
    ├── auth/
    │   └── login_screen.dart    # Login UI
    ├── pos/
    │   ├── food_categories_screen.dart # Dynamic Food Categories & Menu POS UI (Web Parity)
    │   └── pos_ordering_screen.dart    # Fullscreen POS layout
    ├── settings/
    │   └── printer_settings_screen.dart # ESC/POS Printer configuration & testing
    └── tables/
        └── dinein_table_screen.dart    # Table Dashboard & Live Metrics UI (Web Parity)
```

---

## 📋 Comprehensive Pending Roadmap for Next AI Agent / Developer

### ✅ Priority 1: Item Variant & Addons Modal — DONE
### ✅ Priority 2: Payment Settlement Modal — DONE (Cash/Card/UPI)
### ✅ Priority 3: Table Shift — DONE (merge still pending)

### ~~🟢 Priority 1 OLD~~
* Done — see food_categories_screen variant sheet.

### ~~🟢 Priority 2 OLD~~
* Done — settle payment sheet.

### ~~🟢 Priority 3 OLD~~
* Shift done; merge deferred.

### 🟡 Priority 4: Split Bill Dialog (`dinein_split_bill`)
* **Goal**: Implement split bill interface allowing waiters to split a table's bill equally or by item selection.
* **API Endpoint**: `/restaurant/cart/split-bill`.

### 🟡 Priority 5: Live Order Actions & Pre-booking Detail Drawer
* **Goal**: On the "Live Orders" tab inside `dinein_table_screen.dart`, clicking a live order opens full order summary with action buttons: `Print Bill`, `Cancel Order`, `Change Table`, `View KOT History`.

---

## 🚀 How to Run & Build

### Development Mode
```bash
cd Dineinapk
flutter pub get
flutter run
```

### Release APK Build
```bash
cd Dineinapk
flutter build apk --release
```
Output location: `Dineinapk/build/app/outputs/flutter-apk/app-release.apk`

---

> **Note for Agents**: Always verify changes by running `flutter analyze` and `flutter build apk` before completing your turn. Do NOT delete or overwrite existing backend API helpers in `api_service.dart`.
