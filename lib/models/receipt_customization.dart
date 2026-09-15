/// Mirrors `fatfox-admin-panel`'s `ReceiptCustomization` interface
/// (`src/app/_services/receipt-customization.service.ts`) field-for-field —
/// same JSON keys — so this round-trips through the SAME backend object
/// (`printer_settings.receipt_settings` via `restaurant/settings/view` GET and
/// `restaurant/settings/update-printer-settings` PUT) with zero API changes.
///
/// Fields the admin exe/website expose that raw ESC/POS text printing cannot
/// render (`fontFamily`, `paddingLeft`/`paddingRight`, `contentOffsetX`,
/// `baseFontSize`) are still parsed and re-serialized here so editing on the
/// waiter app never wipes out values the exe/website rely on — they are just
/// never read by [ThermalPrinterService].
class ReceiptCustomization {
  // Header
  final bool showRestaurantName;
  final String restaurantNameAlignment; // left | center | right
  final bool showRestaurantAddress;
  final bool showRestaurantPhone;
  final bool showRestaurantGstin;
  final String customHeaderLine1;
  final String customHeaderLine2;

  // KOT
  final bool kotShowTableNumber;
  final bool kotShowDepartmentName;
  final bool kotShowOrderNo;
  final bool kotShowCustomerName;
  final bool kotShowCustomerPhone;
  final bool kotShowDate;
  final bool kotShowItemDescription;
  final bool kotShowAddons;
  final bool kotShowVariant;
  final bool kotShowSerialNumber;
  final String kotFontSize; // small | medium | large
  final String kotCustomMessage;
  final bool kotEnableReleaseTable;
  final bool pickupKotPrintAutoSettle;

  // Bill
  final bool billShowDate;
  final bool billShowTableOrOrderNo;
  final bool billShowPaymentMode;
  final bool billShowCustomerName;
  final bool billShowCustomerPhone;
  final bool billShowItemDescription;
  final bool billShowAddons;
  final bool billShowVariant;
  final bool billShowSerialNumber;
  final bool billShowSubtotal;
  final bool billShowDiscount;
  final bool billShowContainerCharge;
  final bool billShowAreaCharge;
  final bool billShowTaxBreakdown;
  final bool billShowRoundOff;
  final bool billShowGrandTotal;
  final bool billShowUpiQr; // not rendered yet — needs QR + payment plumbing
  final bool billShowCustomerCopy;
  final String billFontSize; // small | medium | large

  // Footer
  final String footerThankYouMessage;
  final String footerSubMessage;
  final String customFooterLine1;
  final String customFooterLine2;
  final String footerAlignment; // left | center | right

  // General (some unused by ESC/POS text printing — see class doc)
  final String dateFormat;
  final String timeFormat; // 12h | 24h
  final String currencySymbol;
  final String fontFamily; // not rendered — round-tripped only
  final String fontWeight; // normal | bold
  final int paddingLeft; // not rendered — round-tripped only
  final int paddingRight; // not rendered — round-tripped only
  final int contentOffsetX; // not rendered — round-tripped only
  final int baseFontSize; // not rendered — round-tripped only
  final String itemTableFontSize; // small | medium | large | xlarge

  const ReceiptCustomization({
    this.showRestaurantName = true,
    this.restaurantNameAlignment = 'center',
    this.showRestaurantAddress = true,
    this.showRestaurantPhone = true,
    this.showRestaurantGstin = true,
    this.customHeaderLine1 = '',
    this.customHeaderLine2 = '',
    this.kotShowTableNumber = true,
    this.kotShowDepartmentName = true,
    this.kotShowOrderNo = true,
    this.kotShowCustomerName = false,
    this.kotShowCustomerPhone = false,
    this.kotShowDate = true,
    this.kotShowItemDescription = true,
    this.kotShowAddons = true,
    this.kotShowVariant = true,
    this.kotShowSerialNumber = true,
    this.kotFontSize = 'medium',
    this.kotCustomMessage = '',
    this.kotEnableReleaseTable = false,
    this.pickupKotPrintAutoSettle = false,
    this.billShowDate = true,
    this.billShowTableOrOrderNo = true,
    this.billShowPaymentMode = true,
    this.billShowCustomerName = true,
    this.billShowCustomerPhone = true,
    this.billShowItemDescription = true,
    this.billShowAddons = true,
    this.billShowVariant = true,
    this.billShowSerialNumber = true,
    this.billShowSubtotal = true,
    this.billShowDiscount = true,
    this.billShowContainerCharge = true,
    this.billShowAreaCharge = true,
    this.billShowTaxBreakdown = true,
    this.billShowRoundOff = true,
    this.billShowGrandTotal = true,
    this.billShowUpiQr = true,
    this.billShowCustomerCopy = true,
    this.billFontSize = 'medium',
    this.footerThankYouMessage = 'THANKS FOR VISITING US',
    this.footerSubMessage = 'Visit Again!',
    this.customFooterLine1 = '',
    this.customFooterLine2 = '',
    this.footerAlignment = 'center',
    this.dateFormat = 'dd-MM-yyyy',
    this.timeFormat = '12h',
    this.currencySymbol = 'Rs.',
    this.fontFamily = 'monospace',
    this.fontWeight = 'normal',
    this.paddingLeft = 0,
    this.paddingRight = 0,
    this.contentOffsetX = 0,
    this.baseFontSize = 12,
    this.itemTableFontSize = 'medium',
  });

  static const ReceiptCustomization defaults = ReceiptCustomization();

  factory ReceiptCustomization.fromJson(Map<String, dynamic> json) {
    const d = ReceiptCustomization.defaults;
    bool b(String key, bool fallback) => json[key] is bool ? json[key] as bool : fallback;
    String s(String key, String fallback) =>
        json[key] is String && (json[key] as String).isNotEmpty ? json[key] as String : fallback;
    int i(String key, int fallback) => json[key] is int
        ? json[key] as int
        : (json[key] is double ? (json[key] as double).round() : fallback);

    return ReceiptCustomization(
      showRestaurantName: b('showRestaurantName', d.showRestaurantName),
      restaurantNameAlignment: s('restaurantNameAlignment', d.restaurantNameAlignment),
      showRestaurantAddress: b('showRestaurantAddress', d.showRestaurantAddress),
      showRestaurantPhone: b('showRestaurantPhone', d.showRestaurantPhone),
      showRestaurantGstin: b('showRestaurantGstin', d.showRestaurantGstin),
      customHeaderLine1: s('customHeaderLine1', d.customHeaderLine1),
      customHeaderLine2: s('customHeaderLine2', d.customHeaderLine2),
      kotShowTableNumber: b('kotShowTableNumber', d.kotShowTableNumber),
      kotShowDepartmentName: b('kotShowDepartmentName', d.kotShowDepartmentName),
      kotShowOrderNo: b('kotShowOrderNo', d.kotShowOrderNo),
      kotShowCustomerName: b('kotShowCustomerName', d.kotShowCustomerName),
      kotShowCustomerPhone: b('kotShowCustomerPhone', d.kotShowCustomerPhone),
      kotShowDate: b('kotShowDate', d.kotShowDate),
      kotShowItemDescription: b('kotShowItemDescription', d.kotShowItemDescription),
      kotShowAddons: b('kotShowAddons', d.kotShowAddons),
      kotShowVariant: b('kotShowVariant', d.kotShowVariant),
      kotShowSerialNumber: b('kotShowSerialNumber', d.kotShowSerialNumber),
      kotFontSize: s('kotFontSize', d.kotFontSize),
      kotCustomMessage: s('kotCustomMessage', d.kotCustomMessage),
      kotEnableReleaseTable: b('kotEnableReleaseTable', d.kotEnableReleaseTable),
      pickupKotPrintAutoSettle: b('pickupKotPrintAutoSettle', d.pickupKotPrintAutoSettle),
      billShowDate: b('billShowDate', d.billShowDate),
      billShowTableOrOrderNo: b('billShowTableOrOrderNo', d.billShowTableOrOrderNo),
      billShowPaymentMode: b('billShowPaymentMode', d.billShowPaymentMode),
      billShowCustomerName: b('billShowCustomerName', d.billShowCustomerName),
      billShowCustomerPhone: b('billShowCustomerPhone', d.billShowCustomerPhone),
      billShowItemDescription: b('billShowItemDescription', d.billShowItemDescription),
      billShowAddons: b('billShowAddons', d.billShowAddons),
      billShowVariant: b('billShowVariant', d.billShowVariant),
      billShowSerialNumber: b('billShowSerialNumber', d.billShowSerialNumber),
      billShowSubtotal: b('billShowSubtotal', d.billShowSubtotal),
      billShowDiscount: b('billShowDiscount', d.billShowDiscount),
      billShowContainerCharge: b('billShowContainerCharge', d.billShowContainerCharge),
      billShowAreaCharge: b('billShowAreaCharge', d.billShowAreaCharge),
      billShowTaxBreakdown: b('billShowTaxBreakdown', d.billShowTaxBreakdown),
      billShowRoundOff: b('billShowRoundOff', d.billShowRoundOff),
      billShowGrandTotal: b('billShowGrandTotal', d.billShowGrandTotal),
      billShowUpiQr: b('billShowUpiQr', d.billShowUpiQr),
      billShowCustomerCopy: b('billShowCustomerCopy', d.billShowCustomerCopy),
      billFontSize: s('billFontSize', d.billFontSize),
      footerThankYouMessage: s('footerThankYouMessage', d.footerThankYouMessage),
      footerSubMessage: s('footerSubMessage', d.footerSubMessage),
      customFooterLine1: s('customFooterLine1', d.customFooterLine1),
      customFooterLine2: s('customFooterLine2', d.customFooterLine2),
      footerAlignment: s('footerAlignment', d.footerAlignment),
      dateFormat: s('dateFormat', d.dateFormat),
      timeFormat: s('timeFormat', d.timeFormat),
      currencySymbol: s('currencySymbol', d.currencySymbol),
      fontFamily: s('fontFamily', d.fontFamily),
      fontWeight: s('fontWeight', d.fontWeight),
      paddingLeft: i('paddingLeft', d.paddingLeft),
      paddingRight: i('paddingRight', d.paddingRight),
      contentOffsetX: i('contentOffsetX', d.contentOffsetX),
      baseFontSize: i('baseFontSize', d.baseFontSize),
      itemTableFontSize: s('itemTableFontSize', d.itemTableFontSize),
    );
  }

  Map<String, dynamic> toJson() => {
        'showRestaurantName': showRestaurantName,
        'restaurantNameAlignment': restaurantNameAlignment,
        'showRestaurantAddress': showRestaurantAddress,
        'showRestaurantPhone': showRestaurantPhone,
        'showRestaurantGstin': showRestaurantGstin,
        'customHeaderLine1': customHeaderLine1,
        'customHeaderLine2': customHeaderLine2,
        'kotShowTableNumber': kotShowTableNumber,
        'kotShowDepartmentName': kotShowDepartmentName,
        'kotShowOrderNo': kotShowOrderNo,
        'kotShowCustomerName': kotShowCustomerName,
        'kotShowCustomerPhone': kotShowCustomerPhone,
        'kotShowDate': kotShowDate,
        'kotShowItemDescription': kotShowItemDescription,
        'kotShowAddons': kotShowAddons,
        'kotShowVariant': kotShowVariant,
        'kotShowSerialNumber': kotShowSerialNumber,
        'kotFontSize': kotFontSize,
        'kotCustomMessage': kotCustomMessage,
        'kotEnableReleaseTable': kotEnableReleaseTable,
        'pickupKotPrintAutoSettle': pickupKotPrintAutoSettle,
        'billShowDate': billShowDate,
        'billShowTableOrOrderNo': billShowTableOrOrderNo,
        'billShowPaymentMode': billShowPaymentMode,
        'billShowCustomerName': billShowCustomerName,
        'billShowCustomerPhone': billShowCustomerPhone,
        'billShowItemDescription': billShowItemDescription,
        'billShowAddons': billShowAddons,
        'billShowVariant': billShowVariant,
        'billShowSerialNumber': billShowSerialNumber,
        'billShowSubtotal': billShowSubtotal,
        'billShowDiscount': billShowDiscount,
        'billShowContainerCharge': billShowContainerCharge,
        'billShowAreaCharge': billShowAreaCharge,
        'billShowTaxBreakdown': billShowTaxBreakdown,
        'billShowRoundOff': billShowRoundOff,
        'billShowGrandTotal': billShowGrandTotal,
        'billShowUpiQr': billShowUpiQr,
        'billShowCustomerCopy': billShowCustomerCopy,
        'billFontSize': billFontSize,
        'footerThankYouMessage': footerThankYouMessage,
        'footerSubMessage': footerSubMessage,
        'customFooterLine1': customFooterLine1,
        'customFooterLine2': customFooterLine2,
        'footerAlignment': footerAlignment,
        'dateFormat': dateFormat,
        'timeFormat': timeFormat,
        'currencySymbol': currencySymbol,
        'fontFamily': fontFamily,
        'fontWeight': fontWeight,
        'paddingLeft': paddingLeft,
        'paddingRight': paddingRight,
        'contentOffsetX': contentOffsetX,
        'baseFontSize': baseFontSize,
        'itemTableFontSize': itemTableFontSize,
      };

  ReceiptCustomization copyWith({
    bool? showRestaurantName,
    String? restaurantNameAlignment,
    bool? showRestaurantAddress,
    bool? showRestaurantPhone,
    bool? showRestaurantGstin,
    String? customHeaderLine1,
    String? customHeaderLine2,
    bool? kotShowTableNumber,
    bool? kotShowDepartmentName,
    bool? kotShowOrderNo,
    bool? kotShowCustomerName,
    bool? kotShowCustomerPhone,
    bool? kotShowDate,
    bool? kotShowItemDescription,
    bool? kotShowAddons,
    bool? kotShowVariant,
    bool? kotShowSerialNumber,
    String? kotFontSize,
    String? kotCustomMessage,
    bool? kotEnableReleaseTable,
    bool? pickupKotPrintAutoSettle,
    bool? billShowDate,
    bool? billShowTableOrOrderNo,
    bool? billShowPaymentMode,
    bool? billShowCustomerName,
    bool? billShowCustomerPhone,
    bool? billShowItemDescription,
    bool? billShowAddons,
    bool? billShowVariant,
    bool? billShowSerialNumber,
    bool? billShowSubtotal,
    bool? billShowDiscount,
    bool? billShowContainerCharge,
    bool? billShowAreaCharge,
    bool? billShowTaxBreakdown,
    bool? billShowRoundOff,
    bool? billShowGrandTotal,
    bool? billShowUpiQr,
    bool? billShowCustomerCopy,
    String? billFontSize,
    String? footerThankYouMessage,
    String? footerSubMessage,
    String? customFooterLine1,
    String? customFooterLine2,
    String? footerAlignment,
    String? dateFormat,
    String? timeFormat,
    String? currencySymbol,
    String? fontWeight,
    String? itemTableFontSize,
  }) {
    return ReceiptCustomization(
      showRestaurantName: showRestaurantName ?? this.showRestaurantName,
      restaurantNameAlignment: restaurantNameAlignment ?? this.restaurantNameAlignment,
      showRestaurantAddress: showRestaurantAddress ?? this.showRestaurantAddress,
      showRestaurantPhone: showRestaurantPhone ?? this.showRestaurantPhone,
      showRestaurantGstin: showRestaurantGstin ?? this.showRestaurantGstin,
      customHeaderLine1: customHeaderLine1 ?? this.customHeaderLine1,
      customHeaderLine2: customHeaderLine2 ?? this.customHeaderLine2,
      kotShowTableNumber: kotShowTableNumber ?? this.kotShowTableNumber,
      kotShowDepartmentName: kotShowDepartmentName ?? this.kotShowDepartmentName,
      kotShowOrderNo: kotShowOrderNo ?? this.kotShowOrderNo,
      kotShowCustomerName: kotShowCustomerName ?? this.kotShowCustomerName,
      kotShowCustomerPhone: kotShowCustomerPhone ?? this.kotShowCustomerPhone,
      kotShowDate: kotShowDate ?? this.kotShowDate,
      kotShowItemDescription: kotShowItemDescription ?? this.kotShowItemDescription,
      kotShowAddons: kotShowAddons ?? this.kotShowAddons,
      kotShowVariant: kotShowVariant ?? this.kotShowVariant,
      kotShowSerialNumber: kotShowSerialNumber ?? this.kotShowSerialNumber,
      kotFontSize: kotFontSize ?? this.kotFontSize,
      kotCustomMessage: kotCustomMessage ?? this.kotCustomMessage,
      kotEnableReleaseTable: kotEnableReleaseTable ?? this.kotEnableReleaseTable,
      pickupKotPrintAutoSettle: pickupKotPrintAutoSettle ?? this.pickupKotPrintAutoSettle,
      billShowDate: billShowDate ?? this.billShowDate,
      billShowTableOrOrderNo: billShowTableOrOrderNo ?? this.billShowTableOrOrderNo,
      billShowPaymentMode: billShowPaymentMode ?? this.billShowPaymentMode,
      billShowCustomerName: billShowCustomerName ?? this.billShowCustomerName,
      billShowCustomerPhone: billShowCustomerPhone ?? this.billShowCustomerPhone,
      billShowItemDescription: billShowItemDescription ?? this.billShowItemDescription,
      billShowAddons: billShowAddons ?? this.billShowAddons,
      billShowVariant: billShowVariant ?? this.billShowVariant,
      billShowSerialNumber: billShowSerialNumber ?? this.billShowSerialNumber,
      billShowSubtotal: billShowSubtotal ?? this.billShowSubtotal,
      billShowDiscount: billShowDiscount ?? this.billShowDiscount,
      billShowContainerCharge: billShowContainerCharge ?? this.billShowContainerCharge,
      billShowAreaCharge: billShowAreaCharge ?? this.billShowAreaCharge,
      billShowTaxBreakdown: billShowTaxBreakdown ?? this.billShowTaxBreakdown,
      billShowRoundOff: billShowRoundOff ?? this.billShowRoundOff,
      billShowGrandTotal: billShowGrandTotal ?? this.billShowGrandTotal,
      billShowUpiQr: billShowUpiQr ?? this.billShowUpiQr,
      billShowCustomerCopy: billShowCustomerCopy ?? this.billShowCustomerCopy,
      billFontSize: billFontSize ?? this.billFontSize,
      footerThankYouMessage: footerThankYouMessage ?? this.footerThankYouMessage,
      footerSubMessage: footerSubMessage ?? this.footerSubMessage,
      customFooterLine1: customFooterLine1 ?? this.customFooterLine1,
      customFooterLine2: customFooterLine2 ?? this.customFooterLine2,
      footerAlignment: footerAlignment ?? this.footerAlignment,
      dateFormat: dateFormat ?? this.dateFormat,
      timeFormat: timeFormat ?? this.timeFormat,
      currencySymbol: currencySymbol ?? this.currencySymbol,
      fontFamily: fontFamily,
      fontWeight: fontWeight ?? this.fontWeight,
      paddingLeft: paddingLeft,
      paddingRight: paddingRight,
      contentOffsetX: contentOffsetX,
      baseFontSize: baseFontSize,
      itemTableFontSize: itemTableFontSize ?? this.itemTableFontSize,
    );
  }
}
