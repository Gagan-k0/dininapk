import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/receipt_customization.dart';
import '../../services/api_service.dart' show ApiException, friendlyError;
import '../../services/printer_discovery_service.dart';
import '../../services/receipt_customization_service.dart';
import '../../services/thermal_printer_service.dart';
import 'receipt_preview.dart';

class PrinterSettingsScreen extends StatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen> {
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '9100');
  final _headerController = TextEditingController(text: 'THE FAT FOX');
  final _discovery = PrinterDiscoveryService();
  final _receiptService = ReceiptCustomizationService();

  String _connectionType = 'LAN'; // LAN, Bluetooth, USB
  String _paperSize = '80mm'; // 80mm, 58mm

  /// True once Paper Size has a real saved value, or the user has picked one
  /// in this session. Small handheld Bluetooth thermal printers are almost
  /// always 58mm while LAN kitchen printers are usually 80mm, so a genuinely
  /// fresh setup defaults smartly by connection type — but that default must
  /// never clobber a choice the user actually made (saved before, or picked
  /// this session), or switching Connection Type would silently wipe it.
  bool _paperSizeExplicit = false;
  String _btMac = '';
  String _btName = '';
  bool _kotEnableReleaseTable = false;
  bool _isSaving = false;
  bool _isTesting = false;
  bool _isScanning = false;
  bool _isSyncing = false;
  int _scanChecked = 0;
  int _scanTotal = 0;
  List<DiscoveredPrinter> _discovered = [];

  ReceiptCustomization _receipt = ReceiptCustomization.defaults;
  DateTime? _lastSynced;
  bool _previewIsKot = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    _headerController.dispose();
    super.dispose();
  }

  /// Small handheld Bluetooth thermal printers are almost always 58mm; LAN
  /// kitchen printers are usually 80mm. Only a suggestion for a connection
  /// type that has no explicit Paper Size choice yet — see _paperSizeExplicit.
  String _defaultPaperSizeFor(String connectionType) =>
      connectionType == 'Bluetooth' ? '58mm' : '80mm';

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPaper = prefs.getString('printer_paper');
    final receipt = await _receiptService.loadCached();
    final syncedAt = await _receiptService.lastSyncedAt();
    setState(() {
      _connectionType = prefs.getString('printer_type') ?? 'LAN';
      _paperSizeExplicit = savedPaper != null;
      _paperSize = savedPaper ?? _defaultPaperSizeFor(_connectionType);
      _ipController.text = prefs.getString('printer_ip') ?? '';
      _portController.text = prefs.getString('printer_port') ?? '9100';
      _headerController.text =
          prefs.getString('printer_header') ?? 'THE FAT FOX';
      _btMac = prefs.getString('printer_bt_mac') ?? '';
      _btName = prefs.getString('printer_bt_name') ?? '';
      _kotEnableReleaseTable =
          prefs.getBool('kot_enable_release_table') ?? false;
      _receipt = receipt;
      _lastSynced = syncedAt;
    });
  }

  Future<void> _persistSettings() async {
    // A save makes the current Paper Size (default or not) the user's real
    // choice — a later Connection Type switch must not silently override it.
    _paperSizeExplicit = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('printer_type', _connectionType);
    await prefs.setString('printer_paper', _paperSize);
    await prefs.setString('printer_ip', _ipController.text.trim());
    await prefs.setString('printer_port', _portController.text.trim());
    await prefs.setString('printer_header', _headerController.text.trim());
    await prefs.setString('printer_bt_mac', _btMac);
    await prefs.setString('printer_bt_name', _btName);
    await prefs.setBool('kot_enable_release_table', _kotEnableReleaseTable);
  }

  /// Pulls the SAME `receipt_settings` the admin exe/website edit. Only
  /// touches the network here — printing always reads the cached copy
  /// [_loadSettings] already loaded, so a failed sync never blocks printing.
  Future<void> _syncFromServer() async {
    setState(() => _isSyncing = true);
    try {
      final receipt = await _receiptService.fetchAndCache();
      final syncedAt = await _receiptService.lastSyncedAt();
      if (!mounted) return;
      setState(() {
        _receipt = receipt;
        _lastSynced = syncedAt;
      });
      _showSnackBar('Synced receipt settings from server', backgroundColor: Colors.green);
    } catch (e) {
      _showSnackBar(
        'Could not sync (${friendlyError(e)}) — using last saved settings',
        backgroundColor: Colors.orange,
      );
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  void _showSnackBar(String message, {required Color backgroundColor}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: backgroundColor),
    );
  }

  /// Parses the Port field, or shows a red snackbar and returns null if it
  /// isn't a valid TCP port (1-65535) — callers must not scan/print/persist
  /// on null, since `Socket.connect` throws a raw ArgumentError otherwise.
  int? _validatedLanPort() {
    final port = int.tryParse(_portController.text.trim());
    if (!isValidTcpPort(port)) {
      _showSnackBar(
        'Enter a valid port (1-65535)',
        backgroundColor: Colors.red,
      );
      return null;
    }
    return port;
  }

  Future<void> _saveSettings() async {
    setState(() => _isSaving = true);
    await _persistSettings();
    var pushed = false;
    String message = 'Saved on this device — will sync to server when online';
    var color = Colors.orange;
    try {
      pushed = await _receiptService.saveAndPush(_receipt);
      if (pushed) {
        final syncedAt = await _receiptService.lastSyncedAt();
        if (mounted) setState(() => _lastSynced = syncedAt);
        message = 'Printer settings saved successfully!';
        color = Colors.green;
      }
    } on ApiException catch (e) {
      // A real refusal (e.g. this staff account lacks permission to edit
      // shared receipt settings) is not a connectivity problem — say so.
      message = 'Saved on this device only — ${friendlyError(e)}';
      color = Colors.red;
    }
    if (!mounted) return;
    setState(() => _isSaving = false);
    _showSnackBar(message, backgroundColor: color);
  }

  Future<void> _scan() async {
    if (_connectionType == 'USB') {
      _showSnackBar(
        'USB auto-detect is not available yet — use LAN or Bluetooth.',
        backgroundColor: Colors.orange,
      );
      return;
    }

    int? lanPort;
    if (_connectionType == 'LAN') {
      lanPort = _validatedLanPort();
      if (lanPort == null) return;
    }

    setState(() {
      _isScanning = true;
      _discovered = [];
      _scanChecked = 0;
      _scanTotal = _connectionType == 'LAN' ? 254 : 0;
    });

    try {
      final list = _connectionType == 'LAN'
          ? await _discovery.scanLan(
              port: lanPort!,
              onProgress: (checked, total) {
                if (!mounted) return;
                setState(() {
                  _scanChecked = checked;
                  _scanTotal = total;
                });
              },
            )
          : await _discovery.scanBluetooth();

      if (!mounted) return;
      setState(() => _discovered = list);
      _showSnackBar(
        list.isEmpty
            ? (_connectionType == 'LAN'
                  ? 'No printers on port ${_portController.text}. Check Wi‑Fi / IP.'
                  : 'No paired Bluetooth printers. Pair in Android Settings first.')
            : 'Found ${list.length} printer(s). Tap one to select.',
        backgroundColor: list.isEmpty ? Colors.orange : Colors.green,
      );
    } catch (error) {
      _showSnackBar(error.toString(), backgroundColor: Colors.red);
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  void _selectDiscovered(DiscoveredPrinter printer) {
    setState(() {
      if (printer.transport == PrinterTransport.lan) {
        _connectionType = 'LAN';
        _ipController.text = printer.host ?? '';
        _portController.text = '${printer.port}';
        _btMac = '';
        _btName = '';
        if (!_paperSizeExplicit) _paperSize = _defaultPaperSizeFor('LAN');
      } else {
        _connectionType = 'Bluetooth';
        _btMac = printer.macAddress ?? '';
        _btName = printer.displayName;
        if (!_paperSizeExplicit) _paperSize = _defaultPaperSizeFor('Bluetooth');
      }
    });
    _showSnackBar(
      'Selected ${printer.displayName}',
      backgroundColor: Colors.green,
    );
  }

  Future<void> _testPrint() async {
    if (_connectionType == 'USB') {
      _showSnackBar(
        'USB not supported yet — use LAN or Bluetooth',
        backgroundColor: Colors.red,
      );
      return;
    }
    if (_connectionType == 'Bluetooth' && _btMac.isEmpty) {
      _showSnackBar(
        'Select a Bluetooth printer from Scan first',
        backgroundColor: Colors.red,
      );
      return;
    }
    if (_connectionType == 'LAN' && _ipController.text.trim().isEmpty) {
      _showSnackBar(
        'Enter or scan a printer IP first',
        backgroundColor: Colors.red,
      );
      return;
    }
    if (_connectionType == 'LAN' && _validatedLanPort() == null) return;

    setState(() => _isTesting = true);
    try {
      await _persistSettings();
      final service = ThermalPrinterService();
      final bytes = await service.generateTestBytes(
        header: _headerController.text.trim().isEmpty
            ? 'THE FAT FOX'
            : _headerController.text.trim(),
        paperSize: _paperSize == '58mm' ? PaperSize.mm58 : PaperSize.mm80,
      );
      await service.printBytes(bytes);
      _showSnackBar(
        'Test print sent successfully!',
        backgroundColor: Colors.green,
      );
    } catch (error) {
      _showSnackBar(error.toString(), backgroundColor: Colors.red);
    } finally {
      if (mounted) {
        setState(() => _isTesting = false);
      }
    }
  }

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged, {bool busy = false}) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(fontSize: 13)),
      value: value,
      activeThumbColor: const Color(0xFFF97316),
      onChanged: busy ? null : onChanged,
    );
  }

  Widget _chips(String label, List<String> options, String value, ValueChanged<String> onChanged, {bool busy = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 100, child: Text(label, style: const TextStyle(fontSize: 13))),
          Expanded(
            child: Wrap(
              spacing: 6,
              children: options.map((o) {
                final selected = value.toLowerCase() == o.toLowerCase();
                return ChoiceChip(
                  label: Text(o, style: const TextStyle(fontSize: 12)),
                  selected: selected,
                  selectedColor: const Color(0xFFF97316),
                  labelStyle: TextStyle(color: selected ? Colors.white : Colors.black87),
                  onSelected: busy ? null : (_) => onChanged(o),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _textRow(String label, String value, ValueChanged<String> onChanged, {bool busy = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextFormField(
        initialValue: value,
        enabled: !busy,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  Widget _buildReceiptCustomizationSection(bool busy) {
    final charsPerLine = _paperSize == '58mm' ? 32 : 48;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Receipt Customization',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            TextButton.icon(
              onPressed: busy || _isSyncing ? null : _syncFromServer,
              icon: _isSyncing
                  ? const SizedBox(
                      width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync, size: 16),
              label: const Text('Sync from server', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        Text(
          _lastSynced == null
              ? 'Never synced — shared with admin exe/website once you sync or save'
              : 'Last synced: ${_lastSynced!.toLocal()}'.split('.').first,
          style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 8),

        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Header', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          children: [
            _toggle('Show restaurant name', _receipt.showRestaurantName,
                (v) => setState(() => _receipt = _receipt.copyWith(showRestaurantName: v)), busy: busy),
            _chips('Alignment', const ['left', 'center', 'right'], _receipt.restaurantNameAlignment,
                (v) => setState(() => _receipt = _receipt.copyWith(restaurantNameAlignment: v)), busy: busy),
            _toggle('Show address', _receipt.showRestaurantAddress,
                (v) => setState(() => _receipt = _receipt.copyWith(showRestaurantAddress: v)), busy: busy),
            _toggle('Show phone', _receipt.showRestaurantPhone,
                (v) => setState(() => _receipt = _receipt.copyWith(showRestaurantPhone: v)), busy: busy),
            _toggle('Show GSTIN', _receipt.showRestaurantGstin,
                (v) => setState(() => _receipt = _receipt.copyWith(showRestaurantGstin: v)), busy: busy),
            _textRow('Custom header line 1', _receipt.customHeaderLine1,
                (v) => _receipt = _receipt.copyWith(customHeaderLine1: v), busy: busy),
            _textRow('Custom header line 2', _receipt.customHeaderLine2,
                (v) => _receipt = _receipt.copyWith(customHeaderLine2: v), busy: busy),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('KOT', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          children: [
            _toggle('Show department', _receipt.kotShowDepartmentName,
                (v) => setState(() => _receipt = _receipt.copyWith(kotShowDepartmentName: v)), busy: busy),
            _toggle('Show table number', _receipt.kotShowTableNumber,
                (v) => setState(() => _receipt = _receipt.copyWith(kotShowTableNumber: v)), busy: busy),
            _toggle('Show date', _receipt.kotShowDate,
                (v) => setState(() => _receipt = _receipt.copyWith(kotShowDate: v)), busy: busy),
            _toggle('Show variant', _receipt.kotShowVariant,
                (v) => setState(() => _receipt = _receipt.copyWith(kotShowVariant: v)), busy: busy),
            _toggle('Show add-ons', _receipt.kotShowAddons,
                (v) => setState(() => _receipt = _receipt.copyWith(kotShowAddons: v)), busy: busy),
            _toggle('Show serial number', _receipt.kotShowSerialNumber,
                (v) => setState(() => _receipt = _receipt.copyWith(kotShowSerialNumber: v)), busy: busy),
            _toggle('Show item note', _receipt.kotShowItemDescription,
                (v) => setState(() => _receipt = _receipt.copyWith(kotShowItemDescription: v)), busy: busy),
            _textRow('Custom KOT message', _receipt.kotCustomMessage,
                (v) => _receipt = _receipt.copyWith(kotCustomMessage: v), busy: busy),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Bill', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          children: [
            _toggle('Show date', _receipt.billShowDate,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowDate: v)), busy: busy),
            _toggle('Show table number', _receipt.billShowTableOrOrderNo,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowTableOrOrderNo: v)), busy: busy),
            _toggle('Show payment mode', _receipt.billShowPaymentMode,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowPaymentMode: v)), busy: busy),
            _toggle('Show customer name', _receipt.billShowCustomerName,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowCustomerName: v)), busy: busy),
            _toggle('Show customer phone', _receipt.billShowCustomerPhone,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowCustomerPhone: v)), busy: busy),
            _toggle('Show variant', _receipt.billShowVariant,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowVariant: v)), busy: busy),
            _toggle('Show add-ons', _receipt.billShowAddons,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowAddons: v)), busy: busy),
            _toggle('Show serial number', _receipt.billShowSerialNumber,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowSerialNumber: v)), busy: busy),
            _toggle('Show item note', _receipt.billShowItemDescription,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowItemDescription: v)), busy: busy),
            _toggle('Show subtotal', _receipt.billShowSubtotal,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowSubtotal: v)), busy: busy),
            _toggle('Show discount', _receipt.billShowDiscount,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowDiscount: v)), busy: busy),
            _toggle('Show container charge', _receipt.billShowContainerCharge,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowContainerCharge: v)), busy: busy),
            _toggle('Show AC / area charge', _receipt.billShowAreaCharge,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowAreaCharge: v)), busy: busy),
            _toggle('Show tax breakdown', _receipt.billShowTaxBreakdown,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowTaxBreakdown: v)), busy: busy),
            _toggle('Show round off', _receipt.billShowRoundOff,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowRoundOff: v)), busy: busy),
            _toggle('Show grand total', _receipt.billShowGrandTotal,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowGrandTotal: v)), busy: busy),
            _toggle('Print a second customer copy', _receipt.billShowCustomerCopy,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowCustomerCopy: v)), busy: busy),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Footer & General', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          children: [
            _textRow('Thank-you message', _receipt.footerThankYouMessage,
                (v) => _receipt = _receipt.copyWith(footerThankYouMessage: v), busy: busy),
            _textRow('Footer sub-message', _receipt.footerSubMessage,
                (v) => _receipt = _receipt.copyWith(footerSubMessage: v), busy: busy),
            _textRow('Custom footer line 1', _receipt.customFooterLine1,
                (v) => _receipt = _receipt.copyWith(customFooterLine1: v), busy: busy),
            _textRow('Custom footer line 2', _receipt.customFooterLine2,
                (v) => _receipt = _receipt.copyWith(customFooterLine2: v), busy: busy),
            _chips('Alignment', const ['left', 'center', 'right'], _receipt.footerAlignment,
                (v) => setState(() => _receipt = _receipt.copyWith(footerAlignment: v)), busy: busy),
            _chips('Font weight', const ['normal', 'bold'], _receipt.fontWeight,
                (v) => setState(() => _receipt = _receipt.copyWith(fontWeight: v)), busy: busy),
            _textRow('Currency symbol', _receipt.currencySymbol,
                (v) => _receipt = _receipt.copyWith(currencySymbol: v), busy: busy),
            _textRow('Date format (e.g. dd-MM-yyyy)', _receipt.dateFormat,
                (v) => _receipt = _receipt.copyWith(dateFormat: v), busy: busy),
            _chips('Time format', const ['12h', '24h'], _receipt.timeFormat,
                (v) => setState(() => _receipt = _receipt.copyWith(timeFormat: v)), busy: busy),
          ],
        ),
        const SizedBox(height: 12),

        Row(
          children: [
            const Text('Preview:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('KOT', style: TextStyle(fontSize: 12)),
              selected: _previewIsKot,
              selectedColor: const Color(0xFFF97316),
              labelStyle: TextStyle(color: _previewIsKot ? Colors.white : Colors.black87),
              onSelected: (_) => setState(() => _previewIsKot = true),
            ),
            const SizedBox(width: 6),
            ChoiceChip(
              label: const Text('Bill', style: TextStyle(fontSize: 12)),
              selected: !_previewIsKot,
              selectedColor: const Color(0xFFF97316),
              labelStyle: TextStyle(color: !_previewIsKot ? Colors.white : Colors.black87),
              onSelected: (_) => setState(() => _previewIsKot = false),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ReceiptPreview(c: _receipt, isKot: _previewIsKot, charsPerLine: charsPerLine),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy = _isSaving || _isTesting || _isScanning || _isSyncing;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text(
          'Printer Settings',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Connection Type',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Row(
              children: ['LAN', 'Bluetooth', 'USB'].map((type) {
                final isSelected = _connectionType == type;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(type),
                    selected: isSelected,
                    selectedColor: const Color(0xFFF97316),
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.white : Colors.black87,
                    ),
                    onSelected: busy
                        ? null
                        : (_) => setState(() {
                              _connectionType = type;
                              _discovered = [];
                              if (!_paperSizeExplicit) {
                                _paperSize = _defaultPaperSizeFor(type);
                              }
                            }),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            const Text(
              'Silent ESC/POS — auto-detect scans LAN :9100 or paired Bluetooth. '
              'No Android print dialog.',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
            ),
            const SizedBox(height: 16),

            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton.icon(
                onPressed: busy ? null : _scan,
                icon: _isScanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.radar),
                label: Text(
                  _isScanning
                      ? (_scanTotal > 0
                            ? 'Scanning… $_scanChecked/$_scanTotal'
                            : 'Scanning…')
                      : 'Scan for printers',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFF97316),
                  side: const BorderSide(color: Color(0xFFF97316)),
                ),
              ),
            ),

            if (_discovered.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'Discovered',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 6),
              ..._discovered.map((p) {
                final selected = p.transport == PrinterTransport.lan
                    ? p.host == _ipController.text.trim()
                    : p.macAddress == _btMac;
                return Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    leading: Icon(
                      p.transport == PrinterTransport.lan
                          ? Icons.lan
                          : Icons.bluetooth,
                      color: const Color(0xFFF97316),
                    ),
                    title: Text(p.displayName),
                    subtitle: Text(
                      p.transport == PrinterTransport.lan
                          ? 'LAN ESC/POS'
                          : 'Bluetooth · ${p.macAddress}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: selected
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : const Icon(Icons.chevron_right),
                    onTap: busy ? null : () => _selectDiscovered(p),
                  ),
                );
              }),
            ],

            const SizedBox(height: 20),
            const Text(
              'Paper Size',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Row(
              children: ['80mm', '58mm'].map((size) {
                final isSelected = _paperSize == size;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(size),
                    selected: isSelected,
                    selectedColor: const Color(0xFFF97316),
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.white : Colors.black87,
                    ),
                    onSelected: busy
                        ? null
                        : (_) => setState(() {
                              _paperSize = size;
                              _paperSizeExplicit = true;
                            }),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            if (_connectionType == 'LAN') ...[
              const Text(
                'Printer IP Address',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _ipController,
                enabled: !busy,
                decoration: InputDecoration(
                  hintText: 'Scan or type e.g. 192.168.1.100',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Printer Port',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _portController,
                enabled: !busy,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(5),
                ],
                decoration: InputDecoration(
                  hintText: '9100',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],

            if (_connectionType == 'Bluetooth') ...[
              const Text(
                'Selected Bluetooth printer',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Text(
                  _btMac.isEmpty
                      ? 'None — pair in Android Settings, then Scan'
                      : '$_btName\n$_btMac',
                  style: TextStyle(
                    color: _btMac.isEmpty
                        ? const Color(0xFF64748B)
                        : Colors.black87,
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],

            if (_connectionType == 'USB') ...[
              const Text(
                'USB / built-in (Sunmi) printers are not wired yet. Use LAN or Bluetooth for silent ESC/POS.',
                style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
              ),
              const SizedBox(height: 20),
            ],

            const Text(
              'Receipt Header Title',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _headerController,
              enabled: !busy,
              decoration: InputDecoration(
                hintText: 'THE FAT FOX',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 16),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Allow release without printed bill',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
              subtitle: const Text(
                'Matches admin kotEnableReleaseTable — Release after KOT without PRINTED.',
                style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
              value: _kotEnableReleaseTable,
              activeThumbColor: const Color(0xFFF97316),
              onChanged: busy
                  ? null
                  : (v) => setState(() => _kotEnableReleaseTable = v),
            ),
            const SizedBox(height: 24),

            _buildReceiptCustomizationSection(busy),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: busy ? null : _saveSettings,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFF97316),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        'Save Printer Settings',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton(
                onPressed: busy ? null : _testPrint,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFF97316),
                  side: const BorderSide(color: Color(0xFFF97316)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isTesting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text(
                        'Test Print',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
