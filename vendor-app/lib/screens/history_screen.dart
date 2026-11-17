import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import '../config/api_config.dart';
import '../models/print_job.dart';
import '../services/order_history_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_container.dart';
import 'queue_screen.dart';

/// Dedicated HistoryScreen displaying completed print jobs with UPI payer name,
/// settlement timestamp, search filtering, and local PDF re-print/preview capabilities.
class HistoryScreen extends StatefulWidget {
  final String vendorId;
  final http.Client? testHttpClient;
  final PrintLayoutExecutor? testPrintExecutor;
  final VoidCallback? onRefreshRequested;
  final VoidCallback? onHistoryCleared;

  const HistoryScreen({
    super.key,
    required this.vendorId,
    this.testHttpClient,
    this.testPrintExecutor,
    this.onRefreshRequested,
    this.onHistoryCleared,
  });

  @override
  State<HistoryScreen> createState() => HistoryScreenState();
}

class HistoryScreenState extends State<HistoryScreen> {
  List<PrintJob> _orders = [];
  bool _isLoading = false;
  bool _isDeletingHistory = false;
  String? _errorMessage;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Set<String> _cachedFileOrderIds = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (mounted && _searchQuery != _searchController.text) {
        setState(() {
          _searchQuery = _searchController.text;
        });
      }
    });
    OrderHistoryService.updatesNotifier.addListener(_onHistoryUpdated);
    _loadLocalHistory();
    fetchHistory();
  }

  void _onHistoryUpdated() {
    if (mounted) {
      _loadLocalHistory();
    }
  }

  @override
  void dispose() {
    OrderHistoryService.updatesNotifier.removeListener(_onHistoryUpdated);
    _searchController.dispose();
    super.dispose();
  }

  /// Loads locally-persisted order history from local device storage (SharedPreferences,
  /// local JSON file, and scanning PrintPulse_Orders directory) for instant zero-database viewing.
  Future<void> _loadLocalHistory() async {
    try {
      final localOrders = await OrderHistoryService.loadLocalOrders(widget.vendorId);
      final hiddenIds = await OrderHistoryService.getHiddenOrderIds();
      final visibleOrders = localOrders
          .where((j) => !hiddenIds.contains(j.orderId))
          .toList();
      final existingCachedIds =
          await OrderHistoryService.getCachedFileOrderIds(visibleOrders);

      if (mounted) {
        setState(() {
          _orders = visibleOrders;
          _cachedFileOrderIds = existingCachedIds;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('HistoryScreen: Error loading local history: $e');
    }
  }

  /// Records an order locally in local storage as soon as it completes printing on this vendor device.
  Future<void> recordCompletedJobLocally(PrintJob job) async {
    await OrderHistoryService.recordOrder(widget.vendorId, job);
    await _loadLocalHistory();
  }

  /// Refreshes completed order history: loads local device storage first,
  /// then optionally syncs with backend and saves any remote orders to local storage.
  Future<void> fetchHistory() async {
    if (!mounted) return;
    setState(() {
      _errorMessage = null;
    });

    // 1. First ensure all device-local orders are loaded immediately
    await _loadLocalHistory();

    final client = widget.testHttpClient ?? http.Client();
    final bool ownsClient = widget.testHttpClient == null;

    try {
      final uri = ApiConfig.vendorHistoryUri(widget.vendorId);
      final response = await client.get(uri).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final List<dynamic> rawOrders = decoded is Map && decoded['orders'] is List
            ? decoded['orders'] as List<dynamic>
            : (decoded is List ? decoded : []);

        final hiddenIds = await OrderHistoryService.getHiddenOrderIds();

        final List<PrintJob> loaded = rawOrders
            .map((item) =>
                PrintJob.fromJson(Map<String, dynamic>.from(item as Map)))
            .where((item) => !hiddenIds.contains(item.orderId))
            .toList();

        // Merge with existing locally-cached orders
        final Map<String, PrintJob> mergedMap = {};
        for (final j in _orders) {
          if (!hiddenIds.contains(j.orderId)) {
            mergedMap[j.orderId] = j;
          }
        }
        for (final j in loaded) {
          if (!hiddenIds.contains(j.orderId)) {
            mergedMap[j.orderId] = j;
          }
        }
        final List<PrintJob> combined = mergedMap.values.toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

        final cachedIds = await OrderHistoryService.getCachedFileOrderIds(combined);

        if (mounted) {
          setState(() {
            _orders = combined;
            _cachedFileOrderIds = cachedIds;
            _isLoading = false;
            _errorMessage = null;
          });
        }

        // Persist merged order batch to local storage
        await OrderHistoryService.saveAllOrders(widget.vendorId, combined);
      } else {
        // Ephemeral pass-through: 404 or non-200 is expected when completed jobs are purged from server RAM.
        // We gracefully display local device history without raising an error banner.
        debugPrint(
            'HistoryScreen: Server returned HTTP ${response.statusCode} (expected for ephemeral zero-database jobs).');
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = null;
          });
        }
      }
    } catch (e) {
      // Gracefully fall back to local device storage without showing error banner if offline
      debugPrint('HistoryScreen: Remote fetch skipped: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = null;
        });
      }
    } finally {
      if (ownsClient) {
        client.close();
      }
    }
  }

  /// Presents a confirmation dialog before deleting all completed and rejected order history.
  Future<void> _confirmDeleteAllHistory() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.delete_forever_rounded, color: AppColors.dangerRed, size: 24),
            SizedBox(width: 10),
            Text(
              'Delete All History',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        content: const Text(
          'Delete all order history? This action cannot be undone.',
          style: TextStyle(fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.dangerRed,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text(
              'Delete',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _executeDeleteAllHistory();
    }
  }

  /// Clears all completed and rejected order history locally without network calls.
  /// Persists order IDs to hidden_history_ids in SharedPreferences so they remain hidden across restarts.
  Future<void> _executeDeleteAllHistory() async {
    if (_isDeletingHistory) return;
    setState(() {
      _isDeletingHistory = true;
    });

    try {
      // 1. Collect all order IDs currently shown in Order History and locally cached
      final Set<String> idsToHide = _orders
          .map((j) => j.orderId.trim())
          .where((id) => id.isNotEmpty)
          .toSet();

      try {
        final localOrders =
            await OrderHistoryService.loadLocalOrders(widget.vendorId);
        for (final job in localOrders) {
          if (job.orderId.trim().isNotEmpty) {
            idsToHide.add(job.orderId.trim());
          }
        }
      } catch (_) {}

      // 2. Persist to hidden_history_ids in SharedPreferences
      await OrderHistoryService.addHiddenOrderIds(idsToHide);

      // 3. Clear local storage files and prefs for this vendor
      await OrderHistoryService.clearLocalHistory(widget.vendorId);

      // 4. Clear displayed history list in state immediately
      // This resets TOTAL SETTLED to ₹0.00 and COMPLETED PRINTS to 0
      if (mounted) {
        setState(() {
          _orders.clear();
          _cachedFileOrderIds.clear();
          _isDeletingHistory = false;
        });

        // Notify dashboard to reset session earnings and completed jobs count
        widget.onHistoryCleared?.call();

        // 5. Show green "History cleared" snackbar
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'History cleared',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor: AppColors.successGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      debugPrint('HistoryScreen: Error clearing history locally: $e');
      if (mounted) {
        setState(() {
          _isDeletingHistory = false;
        });
      }
    }
  }

  List<PrintJob> get _filteredOrders {
    if (_searchQuery.trim().isEmpty) return _orders;
    final q = _searchQuery.trim().toLowerCase();
    return _orders.where((job) {
      return job.payerName.toLowerCase().contains(q) ||
          job.orderId.toLowerCase().contains(q) ||
          job.status.toLowerCase().contains(q);
    }).toList();
  }

  double get _totalRevenueSettled {
    return _orders.fold(0.0, (sum, job) => sum + job.totalAmount);
  }

  @override
  Widget build(BuildContext context) {
    final palette = PrintPulsePalette.of(context);

    return RefreshIndicator(
      onRefresh: fetchHistory,
      color: AppColors.primaryPurple,
      backgroundColor: palette.cardSurface,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          // Header & Summary Stats
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Order History',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                                color: palette.primaryTextColor,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Settled prints & customer payment records',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: palette.secondaryTextColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _isDeletingHistory ? null : _confirmDeleteAllHistory,
                        icon: _isDeletingHistory
                            ? const SizedBox(
                                width: 13,
                                height: 13,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      AppColors.dangerRed),
                                ),
                              )
                            : const Icon(Icons.delete_outline_rounded, size: 15),
                        label: const Text(
                          'Delete All History',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.dangerRed,
                          backgroundColor:
                              AppColors.dangerRed.withValues(alpha: 0.08),
                          side: BorderSide(
                            color: AppColors.dangerRed.withValues(alpha: 0.35),
                            width: 1.0,
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(9999),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Summary Revenue & Job Metric Cards
                  Row(
                    children: [
                      Expanded(
                        child: GlassContainer(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                          borderRadius: 20,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'TOTAL SETTLED',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.8,
                                  color: palette.secondaryTextColor,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '₹${_totalRevenueSettled.toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.5,
                                  color: palette.primaryTextColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GlassContainer(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                          borderRadius: 20,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'COMPLETED PRINTS',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.8,
                                  color: palette.secondaryTextColor,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${_orders.length}',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.5,
                                  color: palette.primaryTextColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Search Bar
                  GlassContainer(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                    borderRadius: 16,
                    child: TextField(
                      key: const Key('history_search_field'),
                      controller: _searchController,
                      onChanged: (val) {
                        setState(() {
                          _searchQuery = val;
                        });
                      },
                      style: TextStyle(
                        fontSize: 14,
                        color: palette.primaryTextColor,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Search by UPI name or Order ID...',
                        hintStyle: TextStyle(
                          fontSize: 13.5,
                          color: palette.secondaryTextColor.withValues(alpha: 0.8),
                        ),
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          size: 20,
                          color: palette.secondaryTextColor,
                        ),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                key: const Key('history_clear_search'),
                                icon: const Icon(Icons.clear_rounded, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {
                                    _searchQuery = '';
                                  });
                                },
                              )
                            : null,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Main Content State Handling
          if (_isLoading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppColors.primaryPurple),
                ),
              ),
            )
          else if (_errorMessage != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_rounded,
                          size: 44, color: AppColors.dangerRed),
                      const SizedBox(height: 12),
                      Text(
                        'Failed to load order history',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: palette.primaryTextColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.secondaryTextColor,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: fetchHistory,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Try Again'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryPurple,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (_filteredOrders.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: palette.subtlePillBg,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _searchQuery.isNotEmpty
                              ? Icons.search_off_rounded
                              : Icons.receipt_long_outlined,
                          size: 34,
                          color: palette.secondaryTextColor,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _searchQuery.isNotEmpty
                            ? 'No orders match "$_searchQuery"'
                            : 'No completed orders yet',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: palette.primaryTextColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _searchQuery.isNotEmpty
                            ? 'Check spelling or clear search filters'
                            : 'Completed print jobs and UPI settlement records will appear here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: palette.secondaryTextColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final job = _filteredOrders[index];
                    final bool isCached = _cachedFileOrderIds.contains(job.orderId);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _buildHistoryCard(context, job, isCached),
                    );
                  },
                  childCount: _filteredOrders.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHistoryCard(BuildContext context, PrintJob job, bool isCached) {
    final palette = PrintPulsePalette.of(context);

    return GlassContainer(
      borderRadius: 20,
      padding: const EdgeInsets.all(16),
      onTap: () => _showOrderDetailsModal(context, job),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: Payer Name & Amount
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.primaryPurple.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppColors.primaryPurple.withValues(alpha: 0.25),
                  ),
                ),
                child: const Icon(
                  Icons.account_balance_wallet_rounded,
                  size: 20,
                  color: AppColors.primaryPurple,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.payerName,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: palette.primaryTextColor,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                          Icons.access_time_rounded,
                          size: 12,
                          color: palette.secondaryTextColor,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          job.formattedPaidAt,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                            color: palette.secondaryTextColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '₹${job.totalAmount.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: palette.primaryTextColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2.5),
                    decoration: BoxDecoration(
                      color: AppColors.successGreen.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(9999),
                      border: Border.all(
                        color: AppColors.successGreen.withValues(alpha: 0.35),
                      ),
                    ),
                    child: const Text(
                      'COMPLETED',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.successGreen,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Divider
          Divider(
            height: 1,
            color: palette.cardBorder.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 10),

          // Row 2: Order Specs and Storage Badge
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Order ID & Page count badge
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: palette.subtlePillBg,
                      borderRadius: BorderRadius.circular(9999),
                    ),
                    child: Text(
                      job.orderId,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                        color: palette.secondaryTextColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${job.totalPhysicalPages} ${job.totalPhysicalPages == 1 ? 'page' : 'pages'} • ${job.hasColor ? 'Color' : 'B&W'}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: palette.secondaryTextColor,
                    ),
                  ),
                ],
              ),

              // Storage / Privacy Badge
              if (job.autoDeleteAfterPrint)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D9488).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(9999),
                    border: Border.all(
                      color: const Color(0xFF0D9488).withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(
                        Icons.shield_outlined,
                        size: 11,
                        color: Color(0xFF0D9488),
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Auto-Deleted',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0D9488),
                        ),
                      ),
                    ],
                  ),
                )
              else if (isCached)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.successGreen.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(9999),
                    border: Border.all(
                      color: AppColors.successGreen.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(
                        Icons.check_circle_outline_rounded,
                        size: 11,
                        color: AppColors.successGreen,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Saved Locally',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.successGreen,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: palette.subtlePillBg,
                    borderRadius: BorderRadius.circular(9999),
                  ),
                  child: Text(
                    'Not Cached',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: palette.secondaryTextColor,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // Row 3: Compact Reprint Button
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _reprintOrder(context, job),
                  borderRadius: BorderRadius.circular(9999),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.primaryPurple.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(9999),
                      border: Border.all(
                        color: AppColors.primaryPurple.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          Icons.print_rounded,
                          size: 13,
                          color: AppColors.primaryPurple,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Reprint',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primaryPurple,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Opens the Order Details modal displaying customer UPI details, specs,
  /// and the Open Document re-print action or privacy purged banner.
  void _showOrderDetailsModal(BuildContext context, PrintJob job) async {
    final palette = PrintPulsePalette.of(context);
    final ordersDir = await getOrdersDirectory();
    final localFile = File('${ordersDir.path}/${job.orderId}.pdf');
    final bool fileExists = localFile.existsSync();
    final bool canOpenDocument = fileExists && !job.autoDeleteAfterPrint;

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalCtx) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
              decoration: BoxDecoration(
                color: palette.cardSurface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border.all(color: palette.cardBorder, width: 1),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag Handle
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: palette.secondaryTextColor.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(9999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Header with Close
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Order Details',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                          color: palette.primaryTextColor,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(modalCtx).pop(),
                        icon: Icon(
                          Icons.close_rounded,
                          color: palette.secondaryTextColor,
                          size: 22,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Details Grid Card
                  GlassContainer(
                    borderRadius: 20,
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        _buildDetailRow(
                          context,
                          label: 'Customer (UPI Name)',
                          value: job.payerName,
                          icon: Icons.person_rounded,
                        ),
                        _buildDivider(palette),
                        _buildDetailRow(
                          context,
                          label: 'Payment Time',
                          value: job.formattedPaidAt,
                          icon: Icons.schedule_rounded,
                        ),
                        _buildDivider(palette),
                        _buildDetailRow(
                          context,
                          label: 'Order ID',
                          value: '#${job.orderId}',
                          icon: Icons.tag_rounded,
                          isMonospace: true,
                        ),
                        _buildDivider(palette),
                        _buildDetailRow(
                          context,
                          label: 'Status',
                          value: 'Completed',
                          icon: Icons.check_circle_rounded,
                          statusBadgeColor: AppColors.successGreen,
                        ),
                        _buildDivider(palette),
                        _buildDetailRow(
                          context,
                          label: 'Print Specs',
                          value:
                              '${job.totalPhysicalPages} pages • ${job.hasColor ? 'Color' : 'B&W'} • ${job.totalCopies} copies',
                          icon: Icons.print_rounded,
                        ),
                        _buildDivider(palette),
                        _buildDetailRow(
                          context,
                          label: 'Total Paid',
                          value: '₹${job.totalAmount.toStringAsFixed(2)}',
                          icon: Icons.currency_rupee_rounded,
                          isHighlight: true,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Action Button: Open Document or Privacy Banner
                  if (canOpenDocument)
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          Navigator.of(modalCtx).pop();
                          _openOrderDocument(context, job, localFile);
                        },
                        icon: const Icon(Icons.visibility_rounded, size: 20),
                        label: const Text(
                          'Open Document',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryPurple,
                          foregroundColor: Colors.white,
                          elevation: 2,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    )
                  else if (job.autoDeleteAfterPrint)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D9488).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFF0D9488).withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        children: const [
                          Icon(
                            Icons.shield_outlined,
                            size: 20,
                            color: Color(0xFF0D9488),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Document deleted after print (Customer Privacy)',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF0D9488),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: palette.subtlePillBg,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: palette.cardBorder,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 18,
                            color: palette.secondaryTextColor,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Document not cached locally.',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: palette.secondaryTextColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openOrderDocument(
      BuildContext context, PrintJob job, File localFile) async {
    try {
      if (!localFile.existsSync()) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Document file not found in PrintPulse_Orders folder.'),
            backgroundColor: AppColors.dangerRed,
          ),
        );
        return;
      }

      final Uint8List pdfBytes = localFile.readAsBytesSync();
      final PdfPageFormat format =
          job.isLandscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;

      if (widget.testPrintExecutor != null) {
        await widget.testPrintExecutor!(
          pdfBytes: pdfBytes,
          name: '${job.orderId}.pdf',
          format: format,
          dynamicLayout: false,
        );
      } else {
        await Printing.layoutPdf(
          name: '${job.orderId}.pdf',
          format: format,
          dynamicLayout: false,
          onLayout: (_) async => pdfBytes,
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to open document: $e'),
            backgroundColor: AppColors.dangerRed,
          ),
        );
      }
    }
  }

  Future<void> _reprintOrder(BuildContext context, PrintJob job) async {
    try {
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
                  'Preparing document for reprint...',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.primaryPurple,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 10),
        ),
      );

      final ordersDir = await getOrdersDirectory();
      final localFile = File('${ordersDir.path}/${job.orderId}.pdf');
      Uint8List? pdfBytes;

      if (localFile.existsSync() && localFile.lengthSync() > 0) {
        pdfBytes = localFile.readAsBytesSync();
      } else {
        // Re-fetch document from backend download endpoint
        String rawDownloadUrl = job.downloadUrl;
        if (rawDownloadUrl.isEmpty && job.documents.isNotEmpty) {
          rawDownloadUrl = job.documents.first.downloadUrl;
        }
        if (rawDownloadUrl.isEmpty) {
          rawDownloadUrl = ApiConfig.downloadDocumentUri(job.orderId).toString();
        }

        final normalizedUrl = normalizeDownloadUrl(rawDownloadUrl);
        final client = widget.testHttpClient ?? http.Client();
        final bool ownsClient = widget.testHttpClient == null;
        try {
          final res = await client
              .get(Uri.parse(normalizedUrl))
              .timeout(const Duration(seconds: 90));
          if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
            try {
              localFile.writeAsBytesSync(res.bodyBytes, flush: true);
              pdfBytes = localFile.readAsBytesSync();
            } catch (_) {
              pdfBytes = res.bodyBytes;
            }
          }
        } finally {
          if (ownsClient) client.close();
        }
      }

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();

      if (pdfBytes == null || pdfBytes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error_outline_rounded,
                    color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    job.autoDeleteAfterPrint || job.isPrivate
                        ? 'Document was auto-deleted after print per privacy setting.'
                        : 'Document is no longer available on device or server.',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor: AppColors.dangerRed,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 4),
          ),
        );
        return;
      }

      final PdfPageFormat format =
          job.isLandscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;

      final bool printed;
      if (widget.testPrintExecutor != null) {
        printed = await widget.testPrintExecutor!(
          pdfBytes: pdfBytes,
          name: '${job.orderId}.pdf',
          format: format,
          dynamicLayout: false,
        );
      } else {
        printed = await Printing.layoutPdf(
          name: '${job.orderId}.pdf',
          format: format,
          dynamicLayout: false,
          onLayout: (_) async =>
              localFile.existsSync() ? localFile.readAsBytesSync() : pdfBytes!,
        );
      }

      if (printed && (job.autoDeleteAfterPrint || job.isPrivate)) {
        try {
          if (localFile.existsSync()) {
            localFile.deleteSync();
            debugPrint(
                'Auto-deleted reprinted private document: ${localFile.path}');
          }
        } catch (e) {
          debugPrint('Error deleting local PDF after reprint: $e');
        }
      }

      if (context.mounted && printed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded,
                    color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Order ${job.orderId} sent to printer for reprint.',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor: AppColors.successGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to reprint document: $e'),
            backgroundColor: AppColors.dangerRed,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    }
  }

  Widget _buildDetailRow(
    BuildContext context, {
    required String label,
    required String value,
    required IconData icon,
    bool isMonospace = false,
    bool isHighlight = false,
    Color? statusBadgeColor,
  }) {
    final palette = PrintPulsePalette.of(context);

    return Row(
      children: [
        Icon(icon, size: 16, color: palette.secondaryTextColor),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: palette.secondaryTextColor,
          ),
        ),
        const Spacer(),
        if (statusBadgeColor != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
            decoration: BoxDecoration(
              color: statusBadgeColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9999),
              border: Border.all(
                color: statusBadgeColor.withValues(alpha: 0.4),
              ),
            ),
            child: Text(
              value,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: statusBadgeColor,
              ),
            ),
          )
        else
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontFamily: isMonospace ? 'monospace' : null,
              fontWeight: isHighlight ? FontWeight.w800 : FontWeight.w700,
              color: isHighlight
                  ? AppColors.primaryPurple
                  : palette.primaryTextColor,
            ),
          ),
      ],
    );
  }

  Widget _buildDivider(PrintPulsePalette palette) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Divider(
        height: 1,
        color: palette.cardBorder.withValues(alpha: 0.35),
      ),
    );
  }
}
