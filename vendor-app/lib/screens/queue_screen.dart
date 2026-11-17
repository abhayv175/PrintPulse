import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import '../config/api_config.dart';
import '../models/print_job.dart';
import '../services/order_history_service.dart';
import '../theme/app_theme.dart';

typedef PrintLayoutExecutor = Future<bool> Function({
  required Uint8List pdfBytes,
  required String name,
  required PdfPageFormat format,
  required bool dynamicLayout,
});

/// Normalizes any download URL replacing localhost, 127.0.0.1, or stale IPs
/// with the active configured host (e.g. jh0yc.aiccloud.online).
String normalizeDownloadUrl(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return '';

  if (trimmed.startsWith('/')) {
    return '${ApiConfig.restBaseUrl}$trimmed';
  }

  var normalized = trimmed;
  normalized = normalized.replaceAll('http://localhost:8000', ApiConfig.restBaseUrl);
  normalized = normalized.replaceAll('http://127.0.0.1:8000', ApiConfig.restBaseUrl);
  normalized = normalized.replaceAll('http://10.0.2.2:8000', ApiConfig.restBaseUrl);
  normalized = normalized.replaceAll('localhost:8000', ApiConfig.baseHost);
  normalized = normalized.replaceAll('127.0.0.1:8000', ApiConfig.baseHost);
  normalized = normalized.replaceAll('10.0.2.2:8000', ApiConfig.baseHost);
  normalized = normalized.replaceAll('localhost', ApiConfig.baseHost);
  normalized = normalized.replaceAll('127.0.0.1', ApiConfig.baseHost);
  normalized = normalized.replaceAll('10.0.2.2', ApiConfig.baseHost);
  normalized = ApiConfig.normalizeLegacyHost(normalized);
  return normalized;
}

/// Resolves the vendor device's local "PrintPulse_Orders" storage directory.
/// In automated test environments (or if platform channel fails), falls back to system temporary directory.
Future<Directory> getOrdersDirectory() async {
  final bool isTestMode = WidgetsBinding.instance.runtimeType.toString().contains('Test') ||
      Platform.environment.containsKey('FLUTTER_TEST');

  if (isTestMode) {
    final tempDir = Directory.systemTemp;
    final ordersDir = Directory('${tempDir.path}/PrintPulse_Orders');
    if (!ordersDir.existsSync()) {
      ordersDir.createSync(recursive: true);
    }
    return ordersDir;
  }

  try {
    final appDir = await getApplicationDocumentsDirectory()
        .timeout(const Duration(seconds: 2));
    final ordersDir = Directory('${appDir.path}/PrintPulse_Orders');
    if (!ordersDir.existsSync()) {
      ordersDir.createSync(recursive: true);
    }
    return ordersDir;
  } catch (e) {
    final tempDir = Directory.systemTemp;
    final ordersDir = Directory('${tempDir.path}/PrintPulse_Orders');
    if (!ordersDir.existsSync()) {
      ordersDir.createSync(recursive: true);
    }
    return ordersDir;
  }
}

/// Hardened "Payment Done & Print" handler for Cash at Counter orders that:
/// 1. Immediately sends confirmation to FastAPI backend via POST /api/orders/{order_id}/confirm-cash.
/// 2. Marks the order as paid locally, triggering notification & status updates.
/// 3. Immediately triggers handlePrintOrder to launch the native Android Print Spooler in one tap.
Future<bool> handleConfirmCashAndPrint(
  BuildContext context,
  PrintJob order, {
  http.Client? httpClient,
  PrintLayoutExecutor? printExecutor,
  void Function(PrintJob paidJob)? onOrderPaid,
}) async {
  final client = httpClient ?? http.Client();
  final bool ownsClient = httpClient == null;

  PrintJob paidJob = order.copyWith(
    status: 'paid',
    paymentStatus: 'PAID',
    paymentMethod: 'cash',
    paidAt: DateTime.now().toIso8601String(),
  );

  try {
    try {
      final confirmUri = ApiConfig.confirmCashUri(order.orderId);
      final response = await client.post(
        confirmUri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'confirmed_by': 'vendor'}),
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final dynamic data = jsonDecode(response.body);
        if (data is Map && data['order'] is Map) {
          paidJob = PrintJob.fromJson(Map<String, dynamic>.from(data['order'] as Map));
        } else if (data is Map && data['order_id'] != null) {
          paidJob = PrintJob.fromJson(Map<String, dynamic>.from(data));
        }
      }
    } catch (e) {
      debugPrint('Warning: Failed to confirm cash order on backend: $e');
    }

    if (onOrderPaid != null) {
      onOrderPaid(paidJob);
    }

    if (!context.mounted) return false;

    return await handlePrintOrder(
      context,
      paidJob,
      httpClient: client,
      printExecutor: printExecutor,
    );
  } finally {
    if (ownsClient) {
      client.close();
    }
  }
}

/// Hardened Zero-Fee UPI "Verify & Print" handler that:
/// 1. Submits verification approval (or rejection) to POST /api/jobs/{order_id}/verify-payment.
/// 2. Updates order status to PAID and spools the print job immediately on approval.
Future<bool> handleVerifyPaymentAndPrint(
  BuildContext context,
  PrintJob order, {
  bool approved = true,
  http.Client? httpClient,
  PrintLayoutExecutor? printExecutor,
  void Function(PrintJob updatedJob)? onOrderUpdated,
}) async {
  final client = httpClient ?? http.Client();
  final bool ownsClient = httpClient == null;

  PrintJob updatedJob = order.copyWith(
    status: approved ? 'paid' : 'rejected',
    paymentStatus: approved ? 'PAID' : 'REJECTED',
    paidAt: approved ? (order.paidAt ?? DateTime.now().toIso8601String()) : null,
  );

  try {
    try {
      final verifyUri = ApiConfig.verifyJobPaymentUri(order.orderId);
      final response = await client.post(
        verifyUri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'approved': approved, 'verified_by': 'vendor_app'}),
      ).timeout(const Duration(seconds: 7));

      if (response.statusCode == 200) {
        final dynamic data = jsonDecode(response.body);
        if (data is Map && data['order'] is Map) {
          updatedJob = PrintJob.fromJson(Map<String, dynamic>.from(data['order'] as Map));
        } else if (data is Map && data['order_id'] != null) {
          updatedJob = PrintJob.fromJson(Map<String, dynamic>.from(data));
        }
      }
    } catch (e) {
      debugPrint('Warning: Failed to verify job payment on backend: $e');
    }

    if (onOrderUpdated != null) {
      onOrderUpdated(updatedJob);
    }

    if (!approved || !context.mounted) return false;

    // Decoupled Print Spooling: Payment is ALREADY approved and marked PAID.
    // If print dialog fails or is cancelled, the order remains PAID.
    return await handlePrintOrder(
      context,
      updatedJob,
      httpClient: client,
      printExecutor: printExecutor,
    );
  } finally {
    if (ownsClient) {
      client.close();
    }
  }
}

/// Hardened "Print Now" handler that:
/// 1. Immediately presents visible loading diagnostic feedback.
/// 2. Normalizes download URL to the active host (jh0yc.aiccloud.online).
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
      duration: const Duration(seconds: 90),
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

    // 2. Download-First Print Architecture:
    // Sanitize job filename so Android's PrintManager / DocumentsUI does not fail on Save as PDF
    final String cleanOrderId = order.orderId
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final String jobName = cleanOrderId.toLowerCase().endsWith('.pdf')
        ? cleanOrderId
        : '$cleanOrderId.pdf';

    final ordersDir = await getOrdersDirectory();
    final localPdfFile = File('${ordersDir.path}/$jobName');
    Uint8List? pdfBytes;

    // Check cached file on disk: ensure valid %PDF signature
    if (localPdfFile.existsSync() && localPdfFile.lengthSync() >= 4) {
      final cachedBytes = localPdfFile.readAsBytesSync();
      if (cachedBytes.length >= 4 &&
          cachedBytes[0] == 0x25 &&
          cachedBytes[1] == 0x50 &&
          cachedBytes[2] == 0x44 &&
          cachedBytes[3] == 0x46) {
        debugPrint('Valid cached PDF found at: ${localPdfFile.path}');
        pdfBytes = cachedBytes;
      } else {
        debugPrint('Corrupt cached PDF at: ${localPdfFile.path}. Deleting.');
        try {
          localPdfFile.deleteSync();
        } catch (_) {}
      }
    }

    if (pdfBytes == null || pdfBytes.isEmpty) {
      String rawDownloadUrl = '';
      if (order.downloadUrl.isNotEmpty) {
        rawDownloadUrl = order.downloadUrl;
      } else if (order.documents.isNotEmpty &&
          order.documents.first.downloadUrl.isNotEmpty) {
        rawDownloadUrl = order.documents.first.downloadUrl;
      } else {
        rawDownloadUrl =
            ApiConfig.downloadDocumentUri(order.orderId).toString();
      }

      final String normalizedUrl = normalizeDownloadUrl(rawDownloadUrl);
      final Uri targetUri = Uri.parse(normalizedUrl);

      // Network & download timeout increased to 90 seconds for large multi-page scans / wake-ups
      final response =
          await client.get(targetUri).timeout(const Duration(seconds: 90));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }

      final Uint8List downloadedBytes = response.bodyBytes;
      if (downloadedBytes.isEmpty) {
        throw Exception(
            'Downloaded document from $targetUri is empty (0 bytes).');
      }

      // Validate PDF signature (%PDF)
      if (downloadedBytes.length < 4 ||
          downloadedBytes[0] != 0x25 ||
          downloadedBytes[1] != 0x50 ||
          downloadedBytes[2] != 0x44 ||
          downloadedBytes[3] != 0x46) {
        final sample = downloadedBytes.length > 60
            ? String.fromCharCodes(downloadedBytes.take(60))
            : String.fromCharCodes(downloadedBytes);
        throw Exception('Server returned invalid PDF format: $sample');
      }

      // Flush completely to local disk storage before print spooling
      localPdfFile.writeAsBytesSync(downloadedBytes, flush: true);
      debugPrint('Order PDF cached at: ${localPdfFile.path}');

      pdfBytes = downloadedBytes;
    }

    if (pdfBytes.isEmpty) {
      throw Exception('PDF payload is empty (0 bytes).');
    }

    final bool isLandscape = order.isLandscape;
    final PdfPageFormat pageFormat =
        isLandscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;

    // 3. Print execution: strictly feed validated in-memory PDF bytes to layoutPdf
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
        onLayout: (PdfPageFormat format) async => pdfBytes!,
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

      // Persist completed order metadata locally for zero-database architecture
      final completedJob = order.copyWith(
        status: 'completed',
        paymentStatus: 'COMPLETED',
        paidAt: order.paidAt ?? DateTime.now().toIso8601String(),
      );
      unawaited(OrderHistoryService.recordOrder(order.vendorId, completedJob));

      // Conditional privacy deletion: if customer turned on auto-delete or marked private,
      // automatically delete the cached PDF file from local storage to protect privacy.
      final bool isPrivateOrder =
          order.autoDeleteAfterPrint || order.isPrivate;
      if (isPrivateOrder) {
        try {
          if (localPdfFile.existsSync()) {
            localPdfFile.deleteSync();
            debugPrint(
                'Customer requested instant deletion: document deleted from device: ${localPdfFile.path}');
          } else {
            final fallbackFile =
                File('${ordersDir.path}/${order.orderId}.pdf');
            if (fallbackFile.existsSync()) {
              fallbackFile.deleteSync();
              debugPrint(
                  'Customer requested instant deletion: document deleted from device: ${fallbackFile.path}');
            }
          }
        } catch (e) {
          debugPrint('Error deleting local PDF on auto-delete request: $e');
        }
      } else {
        debugPrint(
            'Auto-delete off: ${order.orderId}.pdf retained in PrintPulse_Orders.');
      }
    } else {
      // Print dialog cancelled or backed out; revert backend status to paid
      try {
        final statusUri = ApiConfig.updateOrderStatusUri(order.orderId);
        await client.post(
          statusUri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'status': 'paid'}),
        ).timeout(const Duration(seconds: 4));
      } catch (e) {
        debugPrint('Failed to reset status to paid on backend: $e');
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
