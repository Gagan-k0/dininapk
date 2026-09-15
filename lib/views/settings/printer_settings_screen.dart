import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/printer_discovery_service.dart';
import '../../services/thermal_printer_service.dart';

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

  String _connectionType = 'LAN'; // LAN, Bluetooth, USB
  String _paperSize = '80mm'; // 80mm, 58mm
  String _btMac = '';
  String _btName = '';
  bool _kotEnableReleaseTable = false;
  bool _isSaving = false;
  bool _isTesting = false;
  bool _isScanning = false;
  int _scanChecked = 0;
  int _scanTotal = 0;
  List<DiscoveredPrinter> _discovered = [];

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

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _connectionType = prefs.getString('printer_type') ?? 'LAN';
      _paperSize = prefs.getString('printer_paper') ?? '80mm';
      _ipController.text = prefs.getString('printer_ip') ?? '';
      _portController.text = prefs.getString('printer_port') ?? '9100';
      _headerController.text =
          prefs.getString('printer_header') ?? 'THE FAT FOX';
      _btMac = prefs.getString('printer_bt_mac') ?? '';
      _btName = prefs.getString('printer_bt_name') ?? '';
      _kotEnableReleaseTable =
          prefs.getBool('kot_enable_release_table') ?? false;
    });
  }

  Future<void> _persistSettings() async {
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
    if (!mounted) return;
    setState(() => _isSaving = false);
    _showSnackBar(
      'Printer settings saved successfully!',
      backgroundColor: Colors.green,
    );
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
      } else {
        _connectionType = 'Bluetooth';
        _btMac = printer.macAddress ?? '';
        _btName = printer.displayName;
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

  @override
  Widget build(BuildContext context) {
    final busy = _isSaving || _isTesting || _isScanning;

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
                        : (_) => setState(() => _paperSize = size),
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
