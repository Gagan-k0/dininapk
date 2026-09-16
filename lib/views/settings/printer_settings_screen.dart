import 'dart:convert';

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

/// Editable connection fields for one assigned printer (Bill or KOT).
class _PrinterSlot {
  String type = 'LAN'; // LAN, Bluetooth, USB
  final ip = TextEditingController();
  final port = TextEditingController(text: '9100');
  String btMac = '';
  String btName = '';
  String usbId = '';
  String usbName = '';

  bool get isConfigured {
    if (type == 'Bluetooth') return btMac.isNotEmpty;
    if (type == 'USB') return usbId.isNotEmpty;
    return ip.text.trim().isNotEmpty;
  }

  void dispose() {
    ip.dispose();
    port.dispose();
  }
}

class PrinterSettingsScreen extends StatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen> {
  final _headerController = TextEditingController(text: 'THE FAT FOX');
  final _discovery = PrinterDiscoveryService();
  final _receiptService = ReceiptCustomizationService();

  final _slots = {
    PrinterRole.bill: _PrinterSlot(),
    PrinterRole.kot: _PrinterSlot(),
  };
  PrinterRole _editing = PrinterRole.bill;
  bool _kotSameAsBill = true;

  _PrinterSlot get _slot => _slots[_editing]!;

  /// Editing the KOT slot while it just follows the Bill printer — there are
  /// no connection fields of its own to show or scan for.
  bool get _kotFollowsBill => _editing == PrinterRole.kot && _kotSameAsBill;

  String _paperSize = '80mm'; // 80mm, 58mm

  /// True once Paper Size has a real saved value, or the user has picked one
  /// in this session. Small handheld Bluetooth thermal printers are almost
  /// always 58mm while LAN kitchen printers are usually 80mm, so a genuinely
  /// fresh setup defaults smartly by connection type — but that default must
  /// never clobber a choice the user actually made (saved before, or picked
  /// this session), or switching Connection Type would silently wipe it.
  bool _paperSizeExplicit = false;
  bool _kotEnableReleaseTable = false;
  bool _isSaving = false;
  bool _isTesting = false;
  bool _isScanning = false;
  bool _isSyncing = false;
  int _scanChecked = 0;
  int _scanTotal = 0;
  List<DiscoveredPrinter> _discovered = [];

  ReceiptCustomization _receipt = ReceiptCustomization.defaults;

  /// The receipt layout as last loaded/synced — Save only uploads when it
  /// changed, so picking a printer never needs the admin-only settings API.
  String _receiptBaseline = jsonEncode(ReceiptCustomization.defaults.toJson());
  DateTime? _lastSynced;
  bool _previewIsKot = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    for (final slot in _slots.values) {
      slot.dispose();
    }
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
      for (final role in PrinterRole.values) {
        final p = PrinterTarget.prefixFor(role);
        final slot = _slots[role]!;
        slot.type = prefs.getString('${p}printer_type') ?? 'LAN';
        slot.ip.text = prefs.getString('${p}printer_ip') ?? '';
        slot.port.text = prefs.getString('${p}printer_port') ?? '9100';
        slot.btMac = prefs.getString('${p}printer_bt_mac') ?? '';
        slot.btName = prefs.getString('${p}printer_bt_name') ?? '';
        slot.usbId = prefs.getString('${p}printer_usb_id') ?? '';
        slot.usbName = prefs.getString('${p}printer_usb_name') ?? '';
      }
      _kotSameAsBill = prefs.getBool(ReceiptPrefs.kotSameAsBillKey) ?? true;
      if (!_slots[PrinterRole.kot]!.isConfigured && _slots[PrinterRole.bill]!.isConfigured) {
        _copySlot(_slots[PrinterRole.bill]!, _slots[PrinterRole.kot]!);
      }
      _paperSizeExplicit = savedPaper != null;
      _paperSize = savedPaper ?? _defaultPaperSizeFor(_slots[PrinterRole.bill]!.type);
      _headerController.text =
          prefs.getString('printer_header') ?? 'THE FAT FOX';
      _kotEnableReleaseTable =
          prefs.getBool('kot_enable_release_table') ?? false;
      _receipt = receipt;
      _receiptBaseline = jsonEncode(receipt.toJson());
      _lastSynced = syncedAt;
    });
  }

  void _copySlot(_PrinterSlot src, _PrinterSlot dest) {
    dest.type = src.type;
    dest.ip.text = src.ip.text;
    dest.port.text = src.port.text;
    dest.btMac = src.btMac;
    dest.btName = src.btName;
    dest.usbId = src.usbId;
    dest.usbName = src.usbName;
  }

  Future<void> _persistSettings() async {
    // A save makes the current Paper Size (default or not) the user's real
    // choice — a later Connection Type switch must not silently override it.
    _paperSizeExplicit = true;
    if (_kotSameAsBill) {
      if (_editing == PrinterRole.bill) {
        _copySlot(_slots[PrinterRole.bill]!, _slots[PrinterRole.kot]!);
      } else {
        _copySlot(_slots[PrinterRole.kot]!, _slots[PrinterRole.bill]!);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    for (final role in PrinterRole.values) {
      final p = PrinterTarget.prefixFor(role);
      final slot = _slots[role]!;
      await prefs.setString('${p}printer_type', slot.type);
      await prefs.setString('${p}printer_ip', slot.ip.text.trim());
      await prefs.setString('${p}printer_port', slot.port.text.trim());
      await prefs.setString('${p}printer_bt_mac', slot.btMac);
      await prefs.setString('${p}printer_bt_name', slot.btName);
      await prefs.setString('${p}printer_usb_id', slot.usbId);
      await prefs.setString('${p}printer_usb_name', slot.usbName);
    }
    await prefs.setBool(ReceiptPrefs.kotSameAsBillKey, _kotSameAsBill);
    await prefs.setString('printer_paper', _paperSize);
    await prefs.setString('printer_header', _headerController.text.trim());
    await prefs.setBool('kot_enable_release_table', _kotEnableReleaseTable);

    // Invalidate in-memory cache so all app services instantly pick up changes
    ReceiptPrefs.invalidateCache();
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
        _receiptBaseline = jsonEncode(receipt.toJson());
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

  /// Parses [slot]'s Port field, or shows a red snackbar and returns null if
  /// it isn't a valid TCP port (1-65535) — callers must not scan/print/persist
  /// on null, since `Socket.connect` throws a raw ArgumentError otherwise.
  int? _validatedLanPort(_PrinterSlot slot) {
    final port = int.tryParse(slot.port.text.trim());
    if (!isValidTcpPort(port)) {
      _showSnackBar(
        'Enter a valid port (1-65535)',
        backgroundColor: Colors.red,
      );
      return null;
    }
    return port;
  }

  String _roleLabel(PrinterRole role) => role == PrinterRole.kot ? 'KOT' : 'Bill';

  String _describe(PrinterRole role) {
    if (role == PrinterRole.kot && _kotSameAsBill) return 'Same as bill printer';
    final slot = _slots[role]!;
    switch (slot.type) {
      case 'Bluetooth':
        if (slot.btMac.isEmpty) return 'Not set';
        return slot.btName.isEmpty ? slot.btMac : slot.btName;
      case 'LAN':
        final ip = slot.ip.text.trim();
        return ip.isEmpty ? 'Not set' : '$ip:${slot.port.text.trim()}';
      default:
        if (slot.usbId.isEmpty) return 'Not set';
        return 'USB · ${slot.usbName}';
    }
  }

  Future<void> _saveSettings() async {
    setState(() => _isSaving = true);
    await _persistSettings();
    String message = 'Printer settings saved successfully!';
    var color = Colors.green;
    final layout = jsonEncode(_receipt.toJson());
    if (layout != _receiptBaseline) {
      try {
        if (await _receiptService.saveAndPush(_receipt)) {
          _receiptBaseline = layout;
          final syncedAt = await _receiptService.lastSyncedAt();
          if (mounted) setState(() => _lastSynced = syncedAt);
        } else {
          message = 'Printer saved. Receipt layout saved on this device — will sync when online';
          color = Colors.orange;
        }
      } on ApiException catch (e) {
        // Waiter accounts lack the server's `private` permission for the
        // restaurant-wide layout (403). Everything is already saved locally
        // and prints from there, so this is a note, not a failure.
        final forbidden = e.code == 403 || e.httpStatus == 403;
        message = forbidden
            ? 'Printer saved. Receipt layout applies to this device only — ask an admin to change it for all devices.'
            : 'Printer saved. Receipt layout not synced — ${friendlyError(e)}';
        color = Colors.orange;
      }
    }
    if (!mounted) return;
    setState(() => _isSaving = false);
    _showSnackBar(message, backgroundColor: color);
  }

  Future<void> _scan() async {
    final slot = _slot;
    int? lanPort;
    if (slot.type == 'LAN') {
      lanPort = _validatedLanPort(slot);
      if (lanPort == null) return;
    }

    setState(() {
      _isScanning = true;
      _discovered = [];
      _scanChecked = 0;
      _scanTotal = slot.type == 'LAN' ? 254 : 0;
    });

    try {
      final list = slot.type == 'LAN'
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
          : slot.type == 'USB'
              ? await _discovery.scanUsb()
              : await _discovery.scanBluetooth();

      if (!mounted) return;
      setState(() => _discovered = list);
      _showSnackBar(
        list.isEmpty
            ? switch (slot.type) {
                'LAN' => 'No printers on port ${slot.port.text}. Check Wi‑Fi / IP.',
                'USB' => 'No USB printer found. Plug it in (OTG cable on phones) and Scan again.',
                _ => 'No paired Bluetooth printers. Pair in Android Settings first.',
              }
            : 'Found ${list.length} printer(s). Tap one to select.',
        backgroundColor: list.isEmpty ? Colors.orange : Colors.green,
      );
    } catch (error) {
      _showSnackBar(error.toString(), backgroundColor: Colors.red);
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  Future<void> _selectDiscovered(DiscoveredPrinter printer) async {
    final slot = _slot;
    setState(() {
      if (printer.transport == PrinterTransport.lan) {
        slot.type = 'LAN';
        slot.ip.text = printer.host ?? '';
        slot.port.text = '${printer.port}';
        slot.btMac = '';
        slot.btName = '';
      } else if (printer.transport == PrinterTransport.usb) {
        slot.type = 'USB';
        slot.usbId = printer.usbId ?? '';
        slot.usbName = printer.displayName;
      } else {
        slot.type = 'Bluetooth';
        slot.btMac = printer.macAddress ?? '';
        slot.btName = printer.displayName;
      }
      if (_kotSameAsBill) {
        if (_editing == PrinterRole.bill) {
          _copySlot(_slots[PrinterRole.bill]!, _slots[PrinterRole.kot]!);
        } else {
          _copySlot(_slots[PrinterRole.kot]!, _slots[PrinterRole.bill]!);
        }
      }
      if (_editing == PrinterRole.bill && !_paperSizeExplicit) {
        _paperSize = _defaultPaperSizeFor(slot.type);
      }
    });
    await _persistSettings();
    _showSnackBar(
      'Selected & saved ${printer.displayName} as ${_roleLabel(_editing)} printer',
      backgroundColor: Colors.green,
    );
  }

  Future<void> _testPrint() async {
    final role = _editing;
    final slot = _kotFollowsBill ? _slots[PrinterRole.bill]! : _slot;
    if (slot.type == 'USB' && slot.usbId.isEmpty) {
      _showSnackBar(
        'Select a USB printer from Scan first',
        backgroundColor: Colors.red,
      );
      return;
    }
    if (slot.type == 'Bluetooth' && slot.btMac.isEmpty) {
      _showSnackBar(
        'Select a Bluetooth printer from Scan first',
        backgroundColor: Colors.red,
      );
      return;
    }
    if (slot.type == 'LAN' && slot.ip.text.trim().isEmpty) {
      _showSnackBar(
        'Enter or scan a printer IP first',
        backgroundColor: Colors.red,
      );
      return;
    }
    if (slot.type == 'LAN' && _validatedLanPort(slot) == null) return;

    setState(() => _isTesting = true);
    try {
      await _persistSettings();
      final service = ThermalPrinterService();
      final bytes = await service.generateTestBytes(
        header: _headerController.text.trim().isEmpty
            ? 'THE FAT FOX'
            : _headerController.text.trim(),
        paperSize: _paperSize == '58mm' ? PaperSize.mm58 : PaperSize.mm80,
        title: '${_roleLabel(role)} PRINTER TEST',
      );
      await service.printBytes(bytes, role: role);
      _showSnackBar(
        '${_roleLabel(role)} test print sent successfully!',
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
                  // No checkmark: it widened the chips so they wrapped in the grid.
                  showCheckmark: false,
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
        // Recreated after a sync so it shows the synced value, not the stale one.
        key: ValueKey('$label|$_receiptBaseline'),
        initialValue: value,
        enabled: !busy,
        // setState so the live preview follows every keystroke.
        onChanged: (v) => setState(() => onChanged(v)),
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

  /// White rounded panel grouping one area of the form. A [Material], not a
  /// decorated Container, so the switch tiles inside keep their ink splashes.
  Widget _card(Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(width: double.infinity, child: child),
          ),
        ),
      );

  /// Titled set of controls laid out as a grid: two columns once there is room.
  Widget _group(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF334155))),
          const Divider(height: 12),
          LayoutBuilder(builder: (context, c) {
            const gap = 16.0;
            final cols = c.maxWidth >= 520 ? 2 : 1;
            final width = (c.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              children: [for (final child in children) SizedBox(width: width, child: child)],
            );
          }),
        ],
      ),
    );
  }

  /// One assigned printer at a glance; tapping it opens its connection fields.
  Widget _roleTile(PrinterRole role, bool busy) {
    final selected = _editing == role;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: busy
          ? null
          : () => setState(() {
                _editing = role;
                _discovered = [];
              }),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFF7ED) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? const Color(0xFFF97316) : const Color(0xFFE2E8F0),
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(role == PrinterRole.kot ? Icons.soup_kitchen : Icons.receipt_long,
                color: const Color(0xFFF97316)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${_roleLabel(role)} printer',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  Text(_describe(role),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Admin "Hardware Printers": pick which printer gets KOTs and which gets
  /// bills, then edit that one's connection below.
  Widget _buildPrinterAssignment(bool busy) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Printers',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const Text(
          'KOTs print only on the KOT printer, bills only on the Bill printer. '
          'Tap one to set it up.',
          style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _roleTile(PrinterRole.bill, busy)),
            const SizedBox(width: 12),
            Expanded(child: _roleTile(PrinterRole.kot, busy)),
          ],
        ),
        if (_editing == PrinterRole.kot)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Print KOT on the bill printer',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            subtitle: const Text(
              'Turn off to send kitchen tickets to a separate printer.',
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
            value: _kotSameAsBill,
            activeThumbColor: const Color(0xFFF97316),
            onChanged: busy
                ? null
                : (v) async {
                      setState(() {
                        _kotSameAsBill = v;
                        _discovered = [];
                      });
                      await _persistSettings();
                    },
          ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildActiveStatusCard(_PrinterSlot slot) {
    final role = _editing;
    final isKotFollowingBill = _kotFollowsBill;
    final activeSlot = isKotFollowingBill ? _slots[PrinterRole.bill]! : slot;
    final isConfigured = activeSlot.isConfigured;
    final targetDesc = _describe(isKotFollowingBill ? PrinterRole.bill : role);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isConfigured ? const Color(0xFFF0FDF4) : const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isConfigured ? const Color(0xFF86EFAC) : const Color(0xFFFCA5A5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isConfigured ? Icons.check_circle : Icons.error_outline,
                color: isConfigured ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
                size: 24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_roleLabel(role)} Printer: ${isConfigured ? "CONNECTED / READY" : "NOT CONFIGURED"}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: isConfigured ? const Color(0xFF15803D) : const Color(0xFFB91C1C),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isKotFollowingBill
                          ? 'KOT follows Bill Printer → $targetDesc'
                          : '${activeSlot.type} · $targetDesc',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF334155)),
                    ),
                  ],
                ),
              ),
              if (isConfigured)
                ElevatedButton.icon(
                  onPressed: _isTesting ? null : _testPrint,
                  icon: _isTesting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.print, size: 16),
                  label: const Text('Test Print', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF97316),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
          if (isKotFollowingBill) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFFEDD5)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: Color(0xFFEA580C)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'KOT is using the Bill printer setup. Turn off "Print KOT on bill printer" above to assign a separate printer for KOTs.',
                      style: TextStyle(fontSize: 11, color: Color(0xFFC2410C)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildConnectionFields(bool busy) {
    final slot = _slot;
    return [
      _buildActiveStatusCard(slot),
      const Text(
        'Connection Type',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
      ),
      const SizedBox(height: 8),
      // Wrap, not Row: three chips don't fit a phone-width card on one line.
      Wrap(
        runSpacing: 8,
        children: ['LAN', 'Bluetooth', 'USB'].map((type) {
          final isSelected = slot.type == type;
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
                        slot.type = type;
                        _discovered = [];
                        if (_editing == PrinterRole.bill && !_paperSizeExplicit) {
                          _paperSize = _defaultPaperSizeFor(type);
                        }
                      }),
            ),
          );
        }).toList(),
      ),
      const SizedBox(height: 12),
      const Text(
        'Silent ESC/POS — auto-detect scans LAN :9100, paired Bluetooth or USB. '
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
                : 'Scan for ${_roleLabel(_editing)} printer',
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
          final selected = (p.transport == PrinterTransport.lan && slot.type == 'LAN' && p.host == slot.ip.text.trim()) ||
              (p.transport == PrinterTransport.bluetooth && slot.type == 'Bluetooth' && p.macAddress == slot.btMac) ||
              (p.transport == PrinterTransport.usb && slot.type == 'USB' && p.usbId == slot.usbId);
          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              leading: Icon(
                switch (p.transport) {
                  PrinterTransport.lan => Icons.lan,
                  PrinterTransport.bluetooth => Icons.bluetooth,
                  PrinterTransport.usb => Icons.usb,
                },
                color: const Color(0xFFF97316),
              ),
              title: Text(p.displayName),
              subtitle: Text(
                switch (p.transport) {
                  PrinterTransport.lan => 'LAN ESC/POS',
                  PrinterTransport.bluetooth => 'Bluetooth · ${p.macAddress}',
                  PrinterTransport.usb => 'USB ESC/POS',
                },
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

      if (slot.type == 'LAN') ...[
        const Text(
          'Printer IP Address',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: slot.ip,
          enabled: !busy,
          onChanged: (_) => setState(() {}),
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
          controller: slot.port,
          enabled: !busy,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(5),
          ],
          onChanged: (_) => setState(() {}),
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

      if (slot.type == 'Bluetooth') ...[
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
            slot.btMac.isEmpty
                ? 'None — pair in Android Settings, then Scan'
                : '${slot.btName}\n${slot.btMac}',
            style: TextStyle(
              color: slot.btMac.isEmpty
                  ? const Color(0xFF64748B)
                  : Colors.black87,
            ),
          ),
        ),
        const SizedBox(height: 20),
      ],

      if (slot.type == 'USB') ...[
        const Text(
          'Selected USB printer',
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
            slot.usbId.isEmpty
                ? 'None — plug the printer in (OTG cable on phones), then Scan'
                : slot.usbName,
            style: TextStyle(
              color: slot.usbId.isEmpty
                  ? const Color(0xFF64748B)
                  : Colors.black87,
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Android asks once for permission to use the printer — tap OK.',
          style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
        ),
        const SizedBox(height: 20),
      ],
    ];
  }

  Widget _buildReceiptCustomizationSection(bool busy) {
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

        _group('Header', [
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
        _group('KOT', [
            _chips('Font size', const ['small', 'medium', 'large'], _receipt.kotFontSize,
                (v) => setState(() => _receipt = _receipt.copyWith(kotFontSize: v)), busy: busy),
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
        _group('Bill', [
            _chips('Font size', const ['small', 'medium', 'large'], _receipt.billFontSize,
                (v) => setState(() => _receipt = _receipt.copyWith(billFontSize: v)), busy: busy),
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
            _toggle('Show "Customer copy" label', _receipt.billShowCustomerCopy,
                (v) => setState(() => _receipt = _receipt.copyWith(billShowCustomerCopy: v)), busy: busy),
          ],
        ),
        _group('Footer & General', [
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
      ],
    );
  }

  Widget _buildPreviewPanel() {
    final charsPerLine = _paperSize == '58mm' ? 32 : 48;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
      // Mirrors the admin printer settings page: side-by-side preview on wide
      // (tablet / landscape) screens, stacked below the form when narrow.
      body: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 840;
        final form = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _buildPrinterAssignment(busy),
            if (_kotFollowsBill)
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFBFDBFE)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, color: Color(0xFF2563EB), size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'KOTs will print on the Bill Printer',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: Color(0xFF1E40AF),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Active target: ${_describe(PrinterRole.bill)}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF1E3A8A),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => setState(() {
                                _kotSameAsBill = false;
                                _discovered = [];
                              }),
                      icon: const Icon(Icons.add),
                      label: const Text('Set up a separate KOT printer'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFF97316),
                        side: const BorderSide(color: Color(0xFFF97316)),
                      ),
                    ),
                  ],
                ),
              )
            else
              ..._buildConnectionFields(busy),
            ])),
            _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
            ])),
            _card(_buildReceiptCustomizationSection(busy)),
            if (!wide) _card(_buildPreviewPanel()),
          ],
        );

        const buttonText = TextStyle(fontWeight: FontWeight.bold, fontSize: 15);
        final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
        // Pinned under the form so Save/Test are reachable without scrolling to the end.
        final actions = Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      onPressed: busy ? null : _testPrint,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFF97316),
                        side: const BorderSide(color: Color(0xFFF97316)),
                        shape: buttonShape,
                      ),
                      child: _isTesting
                          ? const SizedBox(
                              height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text('Test ${_roleLabel(_editing)} Printer',
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: buttonText),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: ElevatedButton(
                      onPressed: busy ? null : _saveSettings,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF97316),
                        foregroundColor: Colors.white,
                        shape: buttonShape,
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Text('Save Printer Settings',
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: buttonText),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

        final content = !wide
            ? SingleChildScrollView(padding: const EdgeInsets.all(16), child: form)
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: form),
                  ),
                  // Sticky: the preview scrolls on its own, so it stays in view
                  // beside whichever setting is being changed.
                  SizedBox(
                    width: 400,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
                      child: _card(_buildPreviewPanel()),
                    ),
                  ),
                ],
              );
        return Column(children: [Expanded(child: content), actions]);
      }),
    );
  }
}
