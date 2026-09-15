import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat; // intl's TextDirection would shadow Flutter's

import '../../models/receipt_customization.dart';

/// Flutter-rendered paper mockup — mirrors admin's `PREVIEW_DATA` sample bill
/// so a waiter can see roughly what a toggle does without a physical test
/// print. This is an approximation (monospace text, not real ESC/POS bytes);
/// [ThermalPrinterService] is the source of truth for what actually prints.
class ReceiptPreview extends StatelessWidget {
  final ReceiptCustomization c;
  final bool isKot;
  final int charsPerLine; // 32 (58mm) or 48 (80mm)

  const ReceiptPreview({
    super.key,
    required this.c,
    required this.isKot,
    required this.charsPerLine,
  });

  Alignment _align(String v) {
    switch (v.toLowerCase()) {
      case 'left':
        return Alignment.centerLeft;
      case 'right':
        return Alignment.centerRight;
      default:
        return Alignment.center;
    }
  }

  String get _size => isKot ? c.kotFontSize : c.billFontSize;

  /// Small prints in the printer's narrow Font B: 42 / 64 characters a line.
  int get _cpl => _size == 'small' ? (charsPerLine == 32 ? 42 : 64) : charsPerLine;

  String _row(String left, String right) {
    final gap = (_cpl - left.length - right.length).clamp(0, _cpl);
    return '$left${' ' * gap}$right';
  }

  /// Same pattern the printer uses, so a typo in the date format shows here.
  String _date() {
    final time = c.timeFormat == '24h' ? 'HH:mm' : 'hh:mm a';
    final sample = DateTime(2026, 9, 15, 13, 15);
    try {
      return DateFormat('${c.dateFormat} $time').format(sample);
    } catch (_) {
      return DateFormat('dd MMM yyyy - h:mm a').format(sample);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mono = TextStyle(fontFamily: 'monospace', fontSize: _size == 'small' ? 10 : 12, height: 1.4);
    final bold = mono.copyWith(fontWeight: FontWeight.bold);
    final itemStyle = c.fontWeight.toLowerCase() == 'bold' ? bold : mono;
    final tallItems = _size == 'large';
    // The printer can't render '₹' and prints "Rs." instead.
    final cur = c.currencySymbol.replaceAll('₹', 'Rs.');
    String money(String amount) => '$cur $amount';
    final lines = <Widget>[];

    /// [tall] mimics ESC/POS double height: same width, stretched vertically.
    void line(String text, {TextStyle? style, String align = 'center', bool tall = false}) {
      final t = Text(text, style: style ?? mono, textAlign: TextAlign.center);
      lines.add(tall
          ? SizedBox(height: 34, child: FittedBox(fit: BoxFit.fill, child: t))
          : Align(alignment: _align(align), child: t));
    }

    if (isKot) {
      line('KOT', style: bold.copyWith(fontSize: 16));
      if (c.kotShowDepartmentName) line('DEPARTMENT : North Indian', style: bold);
      if (c.kotShowTableNumber) line('Table #: 5', style: bold, align: 'left');
      if (c.kotShowDate) line('Date: ${_date()}', align: 'left');
      lines.add(const Divider());
      line(_row('Item Name', 'Qty'), style: bold, align: 'left');
      lines.add(const Divider());
      var name = 'Paneer Butter Masala';
      if (c.kotShowVariant) name += ' (Full)';
      if (c.kotShowSerialNumber) name = '1. $name';
      line(_row(name, 'x2'), style: itemStyle, align: 'left', tall: tallItems);
      if (c.kotShowAddons) line('   + Extra Gravy', align: 'left');
      if (c.kotShowItemDescription) line('   Note: Less spicy', align: 'left');
      if (c.kotCustomMessage.isNotEmpty) {
        lines.add(const Divider());
        line(c.kotCustomMessage);
      }
    } else {
      if (c.showRestaurantName) {
        line('HOTEL SUNSHINE', style: bold.copyWith(fontSize: 14), align: c.restaurantNameAlignment);
      }
      if (c.customHeaderLine1.isNotEmpty) line(c.customHeaderLine1);
      if (c.customHeaderLine2.isNotEmpty) line(c.customHeaderLine2);
      if (c.showRestaurantAddress) line('123 MG Road, Pune');
      if (c.showRestaurantPhone) line('Ph: 9876543210');
      if (c.showRestaurantGstin) line('GSTIN: 27AABCU9603R1ZP');
      lines.add(const Divider());
      if (c.billShowDate) line('Date: ${_date()}', align: 'left');
      if (c.billShowTableOrOrderNo) line('Table No : 5', style: bold, align: 'left');
      if (c.billShowPaymentMode) line('Payment : CASH', align: 'left');
      if (c.billShowCustomerName) line('Name : Rahul Sharma', align: 'left');
      if (c.billShowCustomerPhone) line('Mobile : 9876543210', align: 'left');
      lines.add(const Divider());
      line(_row('Item', 'Amount'), style: bold, align: 'left');
      lines.add(const Divider());
      var name = 'Paneer Butter Masala';
      if (c.billShowVariant) name += ' (Full)';
      if (c.billShowSerialNumber) name = '1. $name';
      line(_row(name, money('340.00')), style: itemStyle, align: 'left', tall: tallItems);
      if (c.billShowAddons) line('   + Extra Gravy', align: 'left');
      if (c.billShowItemDescription) line('   (Less spicy)', align: 'left');
      lines.add(const Divider());
      if (c.billShowSubtotal) line(_row('Subtotal', money('680.00')), style: bold, align: 'left');
      if (c.billShowDiscount) line(_row('Discount (10% Off)', '-${money('68.00')}'), align: 'left');
      if (c.billShowContainerCharge) line(_row('Container Charge', money('20.00')), align: 'left');
      if (c.billShowAreaCharge) line(_row('AC / Area Charge', money('50.00')), align: 'left');
      if (c.billShowTaxBreakdown) {
        line(_row('CGST (2.5%)', money('17.10')), align: 'left');
        line(_row('SGST (2.5%)', money('17.10')), align: 'left');
      }
      if (c.billShowRoundOff) line(_row('Round Off', money('-0.20')), align: 'left');
      lines.add(const Divider());
      if (c.billShowGrandTotal) {
        line(_row('GRAND TOTAL', money('736.00')), style: bold.copyWith(fontSize: 14), align: 'left');
        lines.add(const Divider());
      }
      if (c.billShowCustomerCopy) line('--- CUSTOMER COPY ---', style: bold);
      if (c.footerThankYouMessage.isNotEmpty) {
        line(c.footerThankYouMessage, style: bold, align: c.footerAlignment);
      }
      for (final extra in [c.footerSubMessage, c.customFooterLine1, c.customFooterLine2]) {
        if (extra.isNotEmpty) line(extra, align: c.footerAlignment);
      }
    }

    // Paper exactly one printer line wide, then scaled down to fit the panel —
    // a 48-character row used to wrap, splitting "Item Name" from "Qty".
    // Measured exactly as the Text widgets render: merged with the theme's
    // DefaultTextStyle (its letterSpacing widened every row) and the device font scale.
    final charWidth = (TextPainter(
      text: TextSpan(text: 'M' * 10, style: DefaultTextStyle.of(context).style.merge(mono)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout())
        .width /
        10;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.topCenter,
      child: Container(
      // + padding 24, border 2, and slack so sub-pixel rounding can't wrap a full row.
      width: _cpl * charWidth + 24 + 2 + 4,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 6)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: lines),
      ),
    );
  }
}
