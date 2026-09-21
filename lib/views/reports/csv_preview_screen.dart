import 'package:flutter/material.dart';

/// Read-only table of a saved transactions CSV. [rows] is
/// `CsvExportService.buildRows` — header first — so what is shown is exactly
/// what the file holds.
class CsvPreviewScreen extends StatelessWidget {
  final String fileName;
  final List<List<String>> rows;

  const CsvPreviewScreen({
    super.key,
    required this.fileName,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    final header = rows.first;
    return Scaffold(
      appBar: AppBar(
        title: Text(fileName, style: const TextStyle(fontSize: 14)),
        backgroundColor: const Color(0xFF1A2332),
        foregroundColor: Colors.white,
      ),
      body: Scrollbar(
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: WidgetStatePropertyAll(Colors.grey.shade200),
              columnSpacing: 20,
              dataRowMinHeight: 36,
              dataRowMaxHeight: 48,
              columns: [
                for (final h in header)
                  DataColumn(
                    label: Text(h, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
              ],
              rows: [
                for (final r in rows.skip(1))
                  DataRow(cells: [for (final c in r) DataCell(Text(c))]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
