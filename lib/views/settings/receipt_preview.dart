import 'package:flutter/material.dart';

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

  String _row(String left, String right) {
    final gap = (charsPerLine - left.length - right.length).clamp(0, charsPerLine);
    return '$left${' ' * gap}$right';
  }

  @override
  Widget build(BuildContext context) {
    final mono = const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4);
    final bold = mono.copyWith(fontWeight: FontWeight.bold);
    final lines = <Widget>[];

    void line(String text, {TextStyle? style, String align = 'center'}) {
      lines.add(Align(
        alignment: _align(align),
        child: Text(text, style: style ?? mono, textAlign: TextAlign.center),
      ));
    }

    if (c.showRestaurantName && !isKot) {
      line('HOTEL SUNSHINE', style: bold.copyWith(fontSize: 14), align: c.restaurantNameAlignment);
    }
    if (isKot) {
      line('KOT', style: bold.copyWith(fontSize: 14));
      if (c.kotShowDepartmentName) line('DEPARTMENT : North Indian');
      if (c.kotShowTableNumber) line('Table #: 5', style: bold, align: 'left');
      if (c.kotShowDate) line('Date: 15-09-2026 1:15 PM', align: 'left');
      lines.add(const Divider());
      line(_row('Item Name', 'Qty'), style: bold, align: 'left');
      lines.add(const Divider());
      var name = 'Paneer Butter Masala';
      if (c.kotShowVariant) name += ' (Full)';
      if (c.kotShowSerialNumber) name = '1. $name';
      line(_row(name, 'x2'), align: 'left');
      if (c.kotShowAddons) line('   + Extra Gravy', align: 'left');
      if (c.kotCustomMessage.isNotEmpty) {
        lines.add(const Divider());
        line(c.kotCustomMessage);
      }
    } else {
      if (c.showRestaurantAddress) line('123 MG Road, Pune');
      if (c.showRestaurantPhone) line('Ph: 9876543210');
      if (c.showRestaurantGstin) line('GSTIN: 27AABCU9603R1ZP');
      lines.add(const Divider());
      if (c.billShowDate) line('Date: 15-09-2026 1:15 PM', align: 'left');
      if (c.billShowTableOrOrderNo) line('Table No : 5', style: bold, align: 'left');
      if (c.billShowCustomerName) line('Name : Rahul Sharma', align: 'left');
      lines.add(const Divider());
      line(_row('Item', 'Amount'), style: bold, align: 'left');
      lines.add(const Divider());
      var name = 'Paneer Butter Masala';
      if (c.billShowVariant) name += ' (Full)';
      if (c.billShowSerialNumber) name = '1. $name';
      line(_row(name, 'Rs. 340.00'), align: 'left');
      if (c.billShowAddons) line('   + Extra Gravy', align: 'left');
      lines.add(const Divider());
      if (c.billShowSubtotal) line(_row('Subtotal', 'Rs. 680.00'), style: bold, align: 'left');
      if (c.billShowDiscount) line(_row('Discount (10% Off)', '-Rs. 68.00'), align: 'left');
      if (c.billShowAreaCharge) line(_row('AC / Area Charge', 'Rs. 50.00'), align: 'left');
      if (c.billShowTaxBreakdown) {
        line(_row('CGST', 'Rs. 17.10'), align: 'left');
        line(_row('SGST', 'Rs. 17.10'), align: 'left');
      }
      lines.add(const Divider());
      if (c.billShowGrandTotal) {
        line(_row('GRAND TOTAL', 'Rs. 716.20'), style: bold.copyWith(fontSize: 14), align: 'left');
        lines.add(const Divider());
      }
      if (c.billShowCustomerCopy) line('--- CUSTOMER COPY ---', style: bold);
      line(c.footerThankYouMessage, style: bold, align: c.footerAlignment);
      if (c.footerSubMessage.isNotEmpty) line(c.footerSubMessage, align: c.footerAlignment);
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 6)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: lines),
    );
  }
}
