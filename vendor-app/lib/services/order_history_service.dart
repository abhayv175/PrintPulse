import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/print_job.dart';
import '../screens/queue_screen.dart';

/// Service managing zero-database, device-local order history persistence.
/// All completed and paid order metadata is cached locally in SharedPreferences
/// and mirrored in app documents, with automatic discovery of local PDFs in PrintPulse_Orders.
class OrderHistoryService {
  /// Reactive notifier triggered whenever a new order is completed or recorded locally.
  static final ValueNotifier<int> updatesNotifier = ValueNotifier<int>(0);

  /// Saves or updates a completed/paid print job in local device storage.
  static Future<void> recordOrder(String vendorId, PrintJob job) async {
    try {
      final cleanVendorId =
          vendorId.trim().isNotEmpty ? vendorId.trim() : (job.vendorId.trim().isNotEmpty ? job.vendorId.trim() : 'default_vendor');
      final prefs = await SharedPreferences.getInstance();
      final key = 'cached_order_history_$cleanVendorId';

      final existingJson = prefs.getString(key);
      List<dynamic> list = [];
      if (existingJson != null && existingJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(existingJson);
          if (decoded is List) list = decoded;
        } catch (_) {}
      }

      final existingIdx = list.indexWhere(
        (item) => (item is Map) && item['order_id'] == job.orderId,
      );

      final jobMap = job.toJson();
      if (existingIdx >= 0) {
        list[existingIdx] = jobMap;
      } else {
        list.insert(0, jobMap);
      }

      final encoded = jsonEncode(list);
      await prefs.setString(key, encoded);

      // Redundant backup to local JSON file in PrintPulse_Orders directory
      try {
        final ordersDir = await getOrdersDirectory();
        final historyFile =
            File('${ordersDir.path}/order_history_$cleanVendorId.json');
        await historyFile.writeAsString(encoded, flush: true);
      } catch (e) {
        debugPrint('Warning: Could not mirror history to local file: $e');
      }

      // Notify any listening widgets (e.g. HistoryScreen) to update state
      updatesNotifier.value++;
      debugPrint(
          'OrderHistoryService: Successfully recorded order ${job.orderId} in local storage.');
    } catch (e) {
      debugPrint('OrderHistoryService: Error saving order locally: $e');
    }
  }

  /// Persists a batch of print jobs to local storage (SharedPreferences and mirrored file).
  static Future<void> saveAllOrders(String vendorId, List<PrintJob> jobs) async {
    try {
      final cleanVendorId =
          vendorId.trim().isNotEmpty ? vendorId.trim() : 'default_vendor';
      final prefs = await SharedPreferences.getInstance();
      final key = 'cached_order_history_$cleanVendorId';

      final encoded = jsonEncode(jobs.map((j) => j.toJson()).toList());
      await prefs.setString(key, encoded);

      try {
        final ordersDir = await getOrdersDirectory();
        final historyFile =
            File('${ordersDir.path}/order_history_$cleanVendorId.json');
        await historyFile.writeAsString(encoded, flush: true);
      } catch (e) {
        debugPrint('Warning: Could not mirror history batch to local file: $e');
      }
    } catch (e) {
      debugPrint('OrderHistoryService: Error saving orders batch: $e');
    }
  }

  /// Loads locally-persisted order history for a vendor, merging SharedPreferences,
  /// local JSON file, and scanning PrintPulse_Orders directory for offline PDF files.
  static Future<List<PrintJob>> loadLocalOrders(String vendorId) async {
    final cleanVendorId =
        vendorId.trim().isNotEmpty ? vendorId.trim() : 'default_vendor';
    final Map<String, PrintJob> orderMap = {};

    // 1. Load from SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      final localRaw = prefs.getString('cached_order_history_$cleanVendorId');
      if (localRaw != null && localRaw.isNotEmpty) {
        final decoded = jsonDecode(localRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final job = PrintJob.fromJson(Map<String, dynamic>.from(item));
              orderMap[job.orderId] = job;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('OrderHistoryService: Error reading from prefs: $e');
    }

    // 2. Fallback read from mirrored local JSON file
    try {
      final ordersDir = await getOrdersDirectory();
      final historyFile =
          File('${ordersDir.path}/order_history_$cleanVendorId.json');
      if (historyFile.existsSync()) {
        final content = historyFile.readAsStringSync();
        if (content.isNotEmpty) {
          final decoded = jsonDecode(content);
          if (decoded is List) {
            for (final item in decoded) {
              if (item is Map) {
                final job = PrintJob.fromJson(Map<String, dynamic>.from(item));
                orderMap.putIfAbsent(job.orderId, () => job);
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('OrderHistoryService: Error reading from mirrored file: $e');
    }

    // 3. Scan local PrintPulse_Orders directory for any existing PDF files
    try {
      final ordersDir = await getOrdersDirectory();
      if (ordersDir.existsSync()) {
        final files = ordersDir.listSync().whereType<File>();
        for (final file in files) {
          final filename = file.uri.pathSegments.last;
          if (filename.toLowerCase().endsWith('.pdf') &&
              !filename.startsWith('.')) {
            final orderId = filename.substring(0, filename.length - 4);
            if (!orderMap.containsKey(orderId)) {
              DateTime modTime;
              try {
                modTime = file.lastModifiedSync();
              } catch (_) {
                modTime = DateTime.now();
              }
              orderMap[orderId] = PrintJob(
                orderId: orderId,
                vendorId: cleanVendorId,
                timestamp: modTime.toIso8601String(),
                totalAmount: 0.0,
                totalPages: 1,
                status: 'completed',
                paymentStatus: 'COMPLETED',
                payerName: 'Customer',
                paymentMethod: 'upi',
                autoDeleteAfterPrint: false,
                documents: [],
              );
            }
          }
        }
      }
    } catch (e) {
      debugPrint('OrderHistoryService: Error scanning orders directory: $e');
    }

    final hiddenIds = await getHiddenOrderIds();
    final list = orderMap.values
        .where((job) => !hiddenIds.contains(job.orderId))
        .toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  /// Returns the set of order IDs that currently have a physical PDF cached on disk.
  static Future<Set<String>> getCachedFileOrderIds(List<PrintJob> jobs) async {
    final Set<String> existingCachedIds = {};
    try {
      final ordersDir = await getOrdersDirectory();
      for (final job in jobs) {
        final f = File('${ordersDir.path}/${job.orderId}.pdf');
        if (f.existsSync() && !job.autoDeleteAfterPrint) {
          existingCachedIds.add(job.orderId);
        }
      }
    } catch (_) {}
    return existingCachedIds;
  }

  /// SharedPreferences key storing order IDs cleared by the vendor
  static const String hiddenHistoryKey = 'hidden_history_ids';

  /// Returns the set of order IDs that have been cleared/hidden locally by the vendor.
  static Future<Set<String>> getHiddenOrderIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(hiddenHistoryKey) ?? [];
      return list.map((id) => id.trim()).where((id) => id.isNotEmpty).toSet();
    } catch (e) {
      debugPrint('OrderHistoryService: Error reading hidden IDs: $e');
      return {};
    }
  }

  /// Appends order IDs to the locally persisted hidden history list in SharedPreferences.
  static Future<void> addHiddenOrderIds(Iterable<String> orderIds) async {
    final validIds = orderIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    if (validIds.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = (prefs.getStringList(hiddenHistoryKey) ?? []).toSet();
      existing.addAll(validIds);
      await prefs.setStringList(hiddenHistoryKey, existing.toList());
      updatesNotifier.value++;
      debugPrint(
          'OrderHistoryService: Persisted ${existing.length} hidden history order IDs.');
    } catch (e) {
      debugPrint('OrderHistoryService: Error saving hidden IDs: $e');
    }
  }

  /// Resets the hidden IDs list in SharedPreferences.
  static Future<void> clearHiddenOrderIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(hiddenHistoryKey);
    } catch (_) {}
  }

  /// Clears locally-persisted order history for a vendor from SharedPreferences,
  /// mirrored JSON file, and any cached print PDF documents in PrintPulse_Orders.
  static Future<void> clearLocalHistory(String vendorId) async {
    try {
      final cleanVendorId =
          vendorId.trim().isNotEmpty ? vendorId.trim() : 'default_vendor';
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('cached_order_history_$cleanVendorId');

      try {
        final ordersDir = await getOrdersDirectory();
        final historyFile =
            File('${ordersDir.path}/order_history_$cleanVendorId.json');
        if (historyFile.existsSync()) {
          historyFile.deleteSync();
        }
        if (ordersDir.existsSync()) {
          final files = ordersDir.listSync().whereType<File>();
          for (final file in files) {
            final filename = file.uri.pathSegments.last;
            if (filename.toLowerCase().endsWith('.pdf') &&
                !filename.startsWith('.')) {
              try {
                file.deleteSync();
              } catch (_) {}
            }
          }
        }
      } catch (e) {
        debugPrint('Warning: Could not remove mirrored history files: $e');
      }

      updatesNotifier.value++;
      debugPrint('OrderHistoryService: Cleared all local history for $cleanVendorId');
    } catch (e) {
      debugPrint('OrderHistoryService: Error clearing history: $e');
    }
  }
}
