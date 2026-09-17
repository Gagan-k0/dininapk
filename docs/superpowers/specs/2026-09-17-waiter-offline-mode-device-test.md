# Waiter app offline mode: on-device test script

For: restaurant manager or tester. Takes about 60 minutes.

**You need:** two Android tablets (A and B), one thermal printer set up in the app, the
admin panel open in a browser, and a test restaurant with tables and a menu.

**Words on screen used below:**
- The **Sync chip** is at the top of the screen. It reads `Online`, `No signal` or
  `Sync off`. When items are waiting it adds a count, e.g. `Online · 2 unsent`. On a
  phone-sized screen it is only an icon with a number badge.
- Tapping the chip opens the **Sync sheet**: a `Sync with server` switch, a
  `Send now` button (when items are waiting) and a `Sync menu` button.
- Items not yet sent show a small blue `NOT SENT` tag in the cart.

---

## A. Setup

1. Install the APK on both tablets. Open it. **Expected:** login screen.
2. Log in on both tablets to the same restaurant. **Expected:** the floor (table list) loads.
3. Look at the Sync chip on both. **Expected:** `Online`, no count.
4. Make sure the printer is on and a test print works from Printer settings.

## B. Speed

1. On tablet A, open a table that already has an order. Go back. Open it again.
   **Expected:** the second open is clearly faster.
2. Tap one item 5 times quickly. **Expected:** no spinner; the cart updates at once;
   the line shows `NOT SENT`; quantity is 5; totals update.

## C. KOT on an open order

1. Continue from B. Add two more different items. Press **KOT**.
   **Expected:** a kitchen ticket prints with all the new items in one go.
2. **Expected:** the `NOT SENT` tags disappear; chip shows no count.
3. In the admin panel, open the same table's order. **Expected:** every item appears
   once, with correct quantities.
4. Compare the bill total on the tablet with the admin panel total (tax included).
   **Expected:** the same amount.

## D. Empty table

1. On tablet A, open an empty table. Tap one item.
   **Expected:** a short wait (this first item opens the order); it has no `NOT SENT` tag.
2. Refresh the admin panel. **Expected:** the table now has an order with that item.
3. Add two more items (stay on the table). **Expected:** they show `NOT SENT` and are
   **not** on the admin panel yet.
4. Press **KOT**. **Expected:** ticket prints; the admin panel now shows all items.

## E. Sync off

1. Tap the chip. Turn `Sync with server` off. **Expected:** chip reads `Sync off`;
   sheet says "Off — nothing is sent. KOT, bill and settle need Sync on."
2. Open a table and add 2 items. **Expected:** they appear with `NOT SENT`.
3. Press **KOT**. **Expected:** refused with "Sync is off. Turn Sync on to print KOT or bill."
   Nothing prints.
4. Press **Bill**. **Expected:** the same message. Nothing prints.
5. Go back to the floor. **Expected:** chip reads `Sync off · 1 unsent`.
6. Tap the chip, turn Sync on. **Expected:** the items send by themselves within a few
   seconds (if not, press `Send now`). The count disappears; chip reads `Online`.
7. Check the admin panel. **Expected:** the items are on that table, once.

## F. No signal

1. Open a table and add an item. Turn Wi-Fi off on the tablet.
2. Press **KOT** (or go back to the floor). **Expected:** chip changes to `No signal`
   after that one failed action. The sheet says "On — server unreachable, retrying every 20s."
3. Add 2 more items. **Expected:** they appear at once with `NOT SENT`.
   Press **Bill**. **Expected:** an error message and **no paper** (nothing prints
   without the server).
4. Turn Wi-Fi on. Wait up to about 20 seconds. **Expected:** chip returns to `Online`,
   the items send automatically, and the count goes away.
5. Check the admin panel. **Expected:** each item appears once.

## G. App restart while offline

1. Open a table, add 2 items. Turn Wi-Fi off.
2. In Android Settings, **Force stop** the app. Reopen it (Wi-Fi still off).
   **Expected:** the floor shows the tables from last time, with a note that it could
   not refresh — not an empty screen.
3. Open the same table. **Expected:** the table opens from the tablet; both items are
   still there with `NOT SENT`.
4. Turn Wi-Fi on. **Expected:** within about 20 seconds the items send (or press **KOT**).

## H. Held items (order changed on the admin panel)

1. On tablet A, open a table that has an order, add 2 items. Do **not** press KOT.
   Stay on this screen.
2. On the admin panel, bill and release that table.
3. On tablet A press **KOT**. **Expected:** an orange bar appears:
   "2 unsent items held. This table was billed or cleared while these items were waiting."
   with buttons `Discard` and `Send to current order`.
4. Press `Discard` → dialog "Discard held items?" → Discard.
   **Expected:** the bar and the items go away. Nothing reaches the admin panel.
5. Repeat steps 1–3 on another table. This time press `Send to current order` → dialog
   "Send held items?" → Send. **Expected:** "Held items sent"; the items appear on the
   admin panel once.

## I. Two tablets on one table

1. On tablet A, open a table and add an item (so A is serving it). Press KOT.
2. On tablet B, open the same table and add an item. Press **KOT**.
   **Expected:** the orange held bar says "Another tablet is serving this table." with
   `Discard` / `Send to current order`.
3. Press `Discard` on tablet B. **Expected:** the item goes; the admin panel is unchanged.
4. Note: if tablet B tries the first item on an **empty** table tablet A just opened, an
   error message may appear instead of the bar. Record the exact text.

## J. Lost response (optional)

1. Open a table, add 3 items. Press **KOT** and switch on Airplane mode immediately.
2. Switch Airplane mode off. Wait for `Online`. Press **KOT** again.
3. **Expected:** in the admin panel each of the 3 items appears **once**, never twice.
   If a held bar appears instead, check the admin panel before choosing.

## K. Leaving a table

1. Open a table, add 2 items. Go back to the floor without pressing KOT.
2. **Expected:** the floor appears at once; within a few seconds the chip count returns
   to none and that table's card updates.
3. **Expected:** the admin panel shows the items on that table (not yet printed to the kitchen).

## L. Logout and login

1. Turn Sync off. Add 2 items to a table. Log out.
2. Log back in to the **same** restaurant. Turn Sync on.
   **Expected:** the items are still there and send; the admin panel shows them once.
3. Repeat step 1, then log in to a **different** restaurant.
   **Expected:** no unsent count, the items never appear, and nothing is added to that
   restaurant's admin panel. Log back in to the first restaurant: the items are still waiting.

## M. Printer check

1. On a table with items from two kitchen departments, press **KOT**.
   **Expected:** one ticket per department, as before.
2. Press **Bill**. **Expected:** the bill prints and matches the admin panel total.
3. If separate KOT and Bill printers are set up: **Expected:** tickets go to the KOT
   printer and the bill to the Bill printer.

---

## What to report

For every step that does not match "Expected":

- Section and step number (e.g. "F4")
- Table number and time (to the minute)
- Screenshot of the tablet showing the Sync chip and the cart
- Screenshot of the admin panel order for that table
- Any message shown, copied exactly

## Checklist

| Section | Pass | Fail | Notes |
|---|---|---|---|
| A. Setup | | | |
| B. Speed | | | |
| C. KOT on open order | | | |
| D. Empty table | | | |
| E. Sync off | | | |
| F. No signal | | | |
| G. App restart offline | | | |
| H. Held items | | | |
| I. Two tablets | | | |
| J. Lost response | | | |
| K. Leaving a table | | | |
| L. Logout / login | | | |
| M. Printer check | | | |
