import 'package:flutter/material.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  String _connectionType = 'LAN'; // LAN, Bluetooth, USB
  String _paperSize = '80mm'; // 80mm, 58mm
  bool _isSaving = false;
  bool _isTesting = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _connectionType = prefs.getString('printer_type') ?? 'LAN';
      _paperSize = prefs.getString('printer_paper') ?? '80mm';
      _ipController.text = prefs.getString('printer_ip') ?? '192.168.1.100';
      _portController.text = prefs.getString('printer_port') ?? '9100';
      _headerController.text =
          prefs.getString('printer_header') ?? 'THE FAT FOX';
    });
  }

  Future<void> _persistSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('printer_type', _connectionType);
    await prefs.setString('printer_paper', _paperSize);
    await prefs.setString('printer_ip', _ipController.text.trim());
    await prefs.setString('printer_port', _portController.text.trim());
    await prefs.setString('printer_header', _headerController.text.trim());
  }

  void _showSnackBar(String message, {required Color backgroundColor}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: backgroundColor),
    );
  }

  Future<void> _saveSettings() async {
    setState(() => _isSaving = true);
    await _persistSettings();

    setState(() => _isSaving = false);
    _showSnackBar(
      'Printer settings saved successfully!',
      backgroundColor: Colors.green,
    );
  }

  Future<void> _testPrint() async {
    setState(() => _isTesting = true);
    try {
      await _persistSettings();
      if (_connectionType != 'LAN') {
        _showSnackBar(
          'LAN only in v1 — set Connection Type to LAN',
          backgroundColor: Colors.red,
        );
        return;
      }

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
                    onSelected: (_) => setState(() => _connectionType = type),
                  ),
                );
              }).toList(),
            ),
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
                    onSelected: (_) => setState(() => _paperSize = size),
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
                decoration: InputDecoration(
                  hintText: 'e.g. 192.168.1.100',
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
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: '9100',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Silent print via TCP port 9100 (no system dialog)',
                style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
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
              decoration: InputDecoration(
                hintText: 'THE FAT FOX',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 30),

            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: (_isSaving || _isTesting) ? null : _saveSettings,
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
                onPressed: (_isSaving || _isTesting) ? null : _testPrint,
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
