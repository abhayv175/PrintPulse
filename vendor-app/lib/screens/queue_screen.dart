import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import '../config/api_config.dart';
import '../models/print_job.dart';
import '../theme/app_theme.dart';

typedef PrintLayoutExecutor = Future<bool> Function({
  required Uint8List pdfBytes,
  required String name,
  required PdfPageFormat format,
  required bool dynamicLayout,
});

/// Normalizes any download URL replacing localhost, 127.0.0.1, or stale IPs
/// with the active configured host (e.g. 192.168.1.41:8000).
String normalizeDownloadUrl(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return '';

  if (trimmed.startsWith('/')) {
    return '${ApiConfig.restBaseUrl}$trimmed';
  }

  var normalized = trimmed;
  normalized = normalized.replaceAll('localhost:8000', ApiConfig.baseHost);
  normalized = normalized.replaceAll('127.0.0.1:8000', ApiConfig.baseHost);
  normalized = normalized.replaceAll('localhost', ApiConfig.baseHost);
  normalized = normalized.replaceAll('127.0.0.1', ApiConfig.baseHost);
  normalized = ApiConfig.normalizeLegacyHost(normalized);
  return normalized;
}

/// Hardened "Print Now" handler that:
/// 1. Immediately presents visible loading diagnostic feedback.
/// 2. Normalizes download URL to the active IP (192.168.1.41:8000).
/// 3. Downloads the compiled A4 application/pdf stream directly from FastAPI.
/// 4. Feeds raw PDF bytes directly to Printing.layoutPdf without client-side image decoding.
/// 5. Catches all network/HTTP and platform errors and displays a clear red SnackBar.
Future<bool> handlePrintOrder(
  BuildContext context,
  PrintJob order, {
  http.Client? httpClient,
  PrintLayoutExecutor? printExecutor,
}) async {
  if (!order.isPaid) return false;

  // 1. Visible Diagnostic Feedback: Immediate loading SnackBar
  ScaffoldMessenger.of(context).clearSnackBars();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: const [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Preparing document for Android Print Spooler...',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      backgroundColor: AppColors.primaryPurple,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      duration: const Duration(seconds: 15),
    ),
  );

  final client = httpClient ?? http.Client();
  final bool ownsClient = httpClient == null;

  try {
    // 1b. Transition order status to "printing" in backend & live tracking
    try {
      final statusUri = ApiConfig.updateOrderStatusUri(order.orderId);
      await client.post(
        statusUri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'status': 'printing'}),
      ).timeout(const Duration(seconds: 4));
    } catch (e) {
      debugPrint('Failed to broadcast printing status to backend: $e');
    }

    // 2. Normalize download URL
    String rawDownloadUrl = '';
    if (order.downloadUrl.isNotEmpty) {
      rawDownloadUrl = order.downloadUrl;
    } else if (order.documents.isNotEmpty &&
        order.documents.first.downloadUrl.isNotEmpty) {
      rawDownloadUrl = order.documents.first.downloadUrl;
    } else {
      rawDownloadUrl = ApiConfig.downloadDocumentUri(order.orderId).toString();
    }

    final String normalizedUrl = normalizeDownloadUrl(rawDownloadUrl);
    final Uri targetUri = Uri.parse(normalizedUrl);

    final response =
        await client.get(targetUri).timeout(const Duration(seconds: 25));

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.body}');
    }

    final Uint8List pdfBytes = response.bodyBytes;
    if (pdfBytes.isEmpty) {
      throw Exception('Downloaded document from $targetUri is empty (0 bytes).');
    }

    final String jobName = '${order.orderId}.pdf';
    final bool isLandscape = order.isLandscape;
    final PdfPageFormat pageFormat =
        isLandscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;

    // 3. Open native Android PrintManager preview passing raw compiled PDF bytes
    final bool printed;
    if (printExecutor != null) {
      printed = await printExecutor(
        pdfBytes: pdfBytes,
        name: jobName,
        format: pageFormat,
        dynamicLayout: false,
      );
    } else {
      printed = await Printing.layoutPdf(
        name: jobName,
        format: pageFormat,
        dynamicLayout: false,
        onLayout: (PdfPageFormat format) async => pdfBytes,
      );
    }

    // 4. If printing completed successfully, transition status to "completed"
    if (printed) {
      try {
        final statusUri = ApiConfig.updateOrderStatusUri(order.orderId);
        await client.post(
          statusUri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'status': 'completed'}),
        ).timeout(const Duration(seconds: 4));
      } catch (e) {
        debugPrint('Failed to broadcast completed status to backend: $e');
      }
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
    }

    return printed;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Print Error: $e',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.dangerRed,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 6),
        ),
      );
    }
    return false;
  } finally {
    if (ownsClient) {
      client.close();
    }
  }
}
