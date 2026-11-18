import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config/api_config.dart';
import '../main.dart';
import '../models/print_job.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/animated_background.dart';
import '../widgets/glass_container.dart';
import '../widgets/onboarding_dialog.dart';
import '../services/google_auth_service.dart';
import '../services/notification_service.dart';
import '../services/order_history_service.dart';
import 'auth_screen.dart';
import 'history_screen.dart';
import 'profile_screen.dart';
import 'queue_screen.dart';

class DashboardScreen extends StatefulWidget {
  final String vendorId;
  final String shopUrl;
  final bool showQrOnLoad;
  final Stream<dynamic>? testWebSocketStream;
  final http.Client? testHttpClient;
  final PrintLayoutExecutor? testPrintExecutor;

  const DashboardScreen({
    super.key,
    required this.vendorId,
    required this.shopUrl,
    this.showQrOnLoad = false,
    this.testWebSocketStream,
    this.testHttpClient,
    this.testPrintExecutor,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final GlobalKey _qrCaptureKey = GlobalKey();
  final GlobalKey<HistoryScreenState> _historyScreenKey =
      GlobalKey<HistoryScreenState>();
  int _currentTabIndex = 0;
  late final PageController _pageController;
  late final ValueNotifier<double> _pageValueNotifier;
  double _currentPageValue = 0.0;

  final List<PrintJob> _orders = [];
  final Set<String> _cancellingOrders = {};
  final Set<String> _verifyingOrders = {};
  final Set<String> _printingOrders = {};
  final Set<String> _settledOrderIds = {};
  final Set<String> _completedOrderIds = {};
  final Set<String> _unprintedPaidOrderIds = {};
  final Set<String> _knownJobIds = {};

  int _completedJobsCount = 0;
  double _totalEarnings = 0.0;
  int _bwPagesPrinted = 0;
  int _colorPagesPrinted = 0;
  String _vendorUpiId = 'shop@okaxis';
  String _shopName = 'PrintPulse Shop';
  String _vendorEmail = '';
  String _vendorPhone = '';
  bool _shopIsOpen = true;
  bool _autoSpool = true;
  final String _defaultPrinter = 'System Default / Wi-Fi Spooler - Ready';
  final String _paperSize = 'A4 Standard (210 × 297 mm)';

  WebSocketChannel? _channel;
  StreamSubscription? _channelSub;
  StreamSubscription? _testStreamSub;
  Timer? _reconnectTimer;
  Timer? _pollingTimer;
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    _currentPageValue = _currentTabIndex.toDouble();
    _pageValueNotifier = ValueNotifier<double>(_currentPageValue);
    _pageController = PageController(initialPage: _currentTabIndex);
    _pageController.addListener(_handlePageScroll);
    _loadProfileSettings();
    _loadVendorUpi();
    _loadInitialOrders();
    _loadVendorStats();

    // Initialize notification service and request Android 13+ permission on startup
    NotificationService.initialize();

    // Redundant fallback polling to detect new orders even if socket drops
    _pollingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && !_isDisposed) {
        _loadInitialOrders(isPolling: true);
      }
    });

    if (widget.testWebSocketStream != null) {
      _testStreamSub =
          widget.testWebSocketStream!.listen(_handleWebSocketMessage);
    } else {
      _connectWebSocket();
    }

    // Display Onboarding Dialog if vendor has not configured pricing/UPI yet, or show QR Modal
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        final prefs = await SharedPreferences.getInstance();
        final bool explicitlyIncomplete =
            prefs.containsKey('onboarding_completed') &&
            prefs.getBool('onboarding_completed') == false;
        final upi = prefs.getString('upi_id') ?? '';
        if (explicitlyIncomplete && upi.isEmpty && mounted) {
          final onboarded = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => OnboardingDialog(
              vendorId: widget.vendorId,
              initialShopName: prefs.getString('shop_name') ?? '',
              initialVendorName: prefs.getString('name') ?? '',
              initialUpiId: prefs.getString('upi_id') ?? '',
              initialBwPrice: prefs.getDouble('bw_price') ?? 2.0,
              initialColorPrice: prefs.getDouble('color_price') ?? 10.0,
            ),
          );
          if (onboarded == true) {
            await prefs.setBool('onboarding_completed', true);
            _loadVendorUpi();
          }
        }
      } catch (_) {}

      if (!mounted) return;
      if (widget.showQrOnLoad) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('has_seen_initial_qr', true);
        if (mounted) {
          _showQrModal();
        }
        return;
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        final hasSeen = prefs.getBool('has_seen_initial_qr');
        if (hasSeen == false) {
          await prefs.setBool('has_seen_initial_qr', true);
          if (mounted) {
            _showQrModal();
          }
        }
      } catch (_) {}
    });
  }

  Future<void> _loadProfileSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        final cachedShop = prefs.getString('shop_name');
        if (cachedShop != null && cachedShop.trim().isNotEmpty) {
          _shopName = cachedShop.trim();
        } else {
          final prefix = widget.vendorId.split('@').first;
          final clean = prefix.replaceAll(RegExp(r'[^a-zA-Z0-9]'), ' ').trim();
          _shopName = clean.isNotEmpty ? '$clean Kiosk' : 'PrintPulse Kiosk';
        }

        final cachedEmail = prefs.getString('email');
        if (cachedEmail != null && cachedEmail.trim().isNotEmpty) {
          _vendorEmail = cachedEmail.trim();
        } else if (widget.vendorId.contains('@')) {
          _vendorEmail = widget.vendorId;
        } else {
          _vendorEmail = '${widget.vendorId}@printpulse.app';
        }

        final cachedPhone = prefs.getString('phone');
        if (cachedPhone != null && cachedPhone.trim().isNotEmpty) {
          _vendorPhone = cachedPhone.trim();
        }

        _shopIsOpen = prefs.getBool('shop_is_open') ?? true;
        _autoSpool = prefs.getBool('printer_auto_spool') ?? true;
      });
    } catch (_) {}
  }

  Future<void> _toggleShopStatus(bool value) async {
    setState(() => _shopIsOpen = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('shop_is_open', value);
    } catch (_) {}
  }

  Future<void> _toggleAutoSpool(bool value) async {
    setState(() => _autoSpool = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('printer_auto_spool', value);
    } catch (_) {}
  }

  Future<void> _loadVendorUpi() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('upi_id');
      if (cached != null && cached.isNotEmpty && mounted) {
        setState(() => _vendorUpiId = cached);
      }
    } catch (_) {}
  }

  Future<void> _loadVendorStats() async {
    try {
      final client = widget.testHttpClient ?? http.Client();
      final bool ownsClient = widget.testHttpClient == null;
      try {
        final res = await client
            .get(ApiConfig.vendorStatsUri(widget.vendorId))
            .timeout(const Duration(seconds: 4));
        if (res.statusCode == 200 && mounted) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final hiddenIds = await OrderHistoryService.getHiddenOrderIds();
          if (hiddenIds.isNotEmpty && _totalEarnings == 0.0 && _completedJobsCount == 0) {
            return;
          }
          setState(() {
            _bwPagesPrinted = (data['bw_pages_printed'] as num?)?.toInt() ?? _bwPagesPrinted;
            _colorPagesPrinted = (data['color_pages_printed'] as num?)?.toInt() ?? _colorPagesPrinted;
            final rev = (data['session_revenue'] as num?)?.toDouble();
            if (rev != null && rev > 0) {
              _totalEarnings = rev;
            }
            final completed = (data['completed_orders'] as num?)?.toInt();
            if (completed != null && completed > 0) {
              _completedJobsCount = completed;
            }
          });
        }
      } finally {
        if (ownsClient) client.close();
      }
    } catch (e) {
      debugPrint('Failed to load vendor stats: $e');
    }
  }

  Future<void> _loadInitialOrders({bool isPolling = false}) async {
    final client = widget.testHttpClient ?? http.Client();
    final bool ownsClient = widget.testHttpClient == null;
    try {
      final uri = ApiConfig.vendorOrdersUri(widget.vendorId);
      final res = await client.get(uri).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final dynamic decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['orders'] is List) {
          final List<PrintJob> loaded = (decoded['orders'] as List)
              .map((o) => PrintJob.fromJson(Map<String, dynamic>.from(o)))
              .toList();
          if (mounted && loaded.isNotEmpty) {
            setState(() {
              for (final job in loaded) {
                // Cease active queue tracking and status polling once an order is completed
                if (_completedOrderIds.contains(job.orderId) ||
                    job.status.toLowerCase() == 'completed') {
                  _orders.removeWhere((o) => o.orderId == job.orderId);
                  OrderHistoryService.recordOrder(
                    widget.vendorId,
                    job.copyWith(status: 'completed', paymentStatus: 'COMPLETED'),
                  );
                  continue;
                }

                final bool isBrandNew = !_knownJobIds.contains(job.orderId);
                _knownJobIds.add(job.orderId);

                final idx =
                    _orders.indexWhere((o) => o.orderId == job.orderId);
                if (idx >= 0) {
                  _orders[idx] = job;
                } else {
                  _orders.add(job);
                }
                if (job.isPaid) {
                  _settledOrderIds.add(job.orderId);
                }

                // If detected during periodic background polling and not seen before, alert vendor
                if (isPolling &&
                    isBrandNew &&
                    (job.isPaid || job.isCash || job.isPaymentClaimed)) {
                  if (job.isPaymentClaimed) {
                    NotificationService.alertNewJob(
                      title: 'Payment Claimed',
                      body:
                          'UPI Claimed: ₹${job.totalAmount.toStringAsFixed(2)} • Please verify payment',
                      payload: job.orderId,
                    );
                  } else {
                    NotificationService.alertNewJob(
                      title: 'New Print Job',
                      body:
                          'Order #${job.orderId} • ${job.totalPages} pages • ₹${job.totalAmount.toStringAsFixed(2)}',
                      payload: job.orderId,
                    );
                  }
                }
              }
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to load initial orders: $e');
    } finally {
      if (ownsClient) client.close();
    }
  }

  Future<void> _updateVendorUpi(String newUpi) async {
    final trimmed = newUpi.trim();
    if (trimmed.isEmpty || !trimmed.contains('@')) return;
    final client = widget.testHttpClient ?? http.Client();
    final bool ownsClient = widget.testHttpClient == null;
    try {
      final res = await client.post(
        ApiConfig.updateVendorUpiUri(widget.vendorId),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'upi_id': trimmed}),
      );
      if (res.statusCode == 200) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('upi_id', trimmed);
        if (mounted) {
          setState(() => _vendorUpiId = trimmed);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('UPI VPA updated to $trimmed'),
              backgroundColor: AppColors.successGreen,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invalid UPI ID (${res.statusCode})'),
            backgroundColor: AppColors.dangerRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update UPI VPA: $e'),
            backgroundColor: AppColors.dangerRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (ownsClient) client.close();
    }
  }

  Future<void> _showEditUpiDialog() async {
    final controller = TextEditingController(text: _vendorUpiId);
    final result = await _showAnimatedModal<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (ctx) {
        final bool isDark = Theme.of(ctx).brightness == Brightness.dark;
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1735) : Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.12)
                      : const Color(0xFFE5E7EB),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Configure UPI VPA',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : AppColors.lightTextPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Customers scan or pay directly to this UPI ID.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white70 : const Color(0xFF6B7280),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      hintText: 'shop@okaxis',
                      prefixIcon: const Icon(Icons.account_balance_wallet_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            backgroundColor: isDark
                                ? Colors.white.withValues(alpha: 0.08)
                                : const Color(0xFFF3F4F6),
                          ),
                          child: Text(
                            'Cancel',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF374151),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () =>
                              Navigator.of(ctx).pop(controller.text.trim()),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            elevation: 0,
                            backgroundColor: AppColors.primaryPurple,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'Save',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    controller.dispose();
    if (result != null && result.isNotEmpty) {
      await _updateVendorUpi(result);
    }
  }

  void _handlePageScroll() {
    if (!_pageController.hasClients ||
        !_pageController.position.hasContentDimensions) {
      return;
    }
    final double? page = _pageController.page;
    if (page == null) return;
    _currentPageValue = page;
    if (_pageValueNotifier.value != page) {
      _pageValueNotifier.value = page;
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _pollingTimer?.cancel();
    _pageController.removeListener(_handlePageScroll);
    _pageController.dispose();
    _pageValueNotifier.dispose();
    _reconnectTimer?.cancel();
    _channelSub?.cancel();
    _testStreamSub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  void _connectWebSocket() {
    if (_isDisposed) return;

    setState(() {
      _isConnecting = true;
      _isConnected = false;
    });

    _reconnectTimer?.cancel();
    _channelSub?.cancel();

    try {
      final wsUri = Uri.parse(ApiConfig.vendorWebSocketUrl(widget.vendorId));
      _channel = WebSocketChannel.connect(wsUri);

      _channelSub = _channel!.stream.listen(
        (data) {
          if (!_isConnected && mounted) {
            setState(() {
              _isConnected = true;
              _isConnecting = false;
            });
          }
          _handleWebSocketMessage(data);
        },
        onDone: () {
          if (!_isDisposed && mounted) {
            setState(() {
              _isConnected = false;
              _isConnecting = false;
            });
            _scheduleReconnect();
          }
        },
        onError: (error) {
          if (!_isDisposed && mounted) {
            setState(() {
              _isConnected = false;
              _isConnecting = false;
            });
            _scheduleReconnect();
          }
        },
      );

      _channel!.ready.then((_) {
        if (!_isDisposed && mounted) {
          setState(() {
            _isConnected = true;
            _isConnecting = false;
          });
          _loadInitialOrders();
        }
      }).catchError((_) {
        if (!_isDisposed && mounted) {
          setState(() {
            _isConnected = false;
            _isConnecting = false;
          });
          _scheduleReconnect();
        }
      });
    } catch (e) {
      if (!_isDisposed && mounted) {
        setState(() {
          _isConnected = false;
          _isConnecting = false;
        });
        _scheduleReconnect();
      }
    }
  }

  void _scheduleReconnect() {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 4), () {
      if (!_isDisposed && mounted && !_isConnected) {
        _connectWebSocket();
      }
    });
  }

  void _playPaymentPing() {
    NotificationService.playForegroundChime();
  }

  void _applyPaidSettlement(PrintJob incomingPaidJob) {
    final int existingIdx =
        _orders.indexWhere((o) => o.orderId == incomingPaidJob.orderId);
    final PrintJob settledJob = existingIdx >= 0
        ? _orders[existingIdx].copyWith(
            status: 'paid',
            paidAt: incomingPaidJob.paidAt,
            totalAmount: incomingPaidJob.totalAmount > 0
                ? incomingPaidJob.totalAmount
                : _orders[existingIdx].totalAmount,
            totalPages: incomingPaidJob.totalPages > 0
                ? incomingPaidJob.totalPages
                : _orders[existingIdx].totalPages,
            documents: incomingPaidJob.documents.isNotEmpty
                ? incomingPaidJob.documents
                : _orders[existingIdx].documents,
          )
        : incomingPaidJob.copyWith(status: 'paid');

    final bool firstSettlement = _settledOrderIds.add(settledJob.orderId);
    _knownJobIds.add(settledJob.orderId);
    OrderHistoryService.recordOrder(widget.vendorId, settledJob);

    setState(() {
      _orders.removeWhere((o) => o.orderId == settledJob.orderId);
      _orders.insert(0, settledJob);
      if (firstSettlement) {
        _totalEarnings += settledJob.totalAmount;
        _completedJobsCount += 1;
        if (settledJob.isColor) {
          _colorPagesPrinted += settledJob.totalPages;
        } else {
          _bwPagesPrinted += settledJob.totalPages;
        }
      }
    });

    _loadVendorStats();

    if (firstSettlement && mounted) {
      _playPaymentPing();
      NotificationService.alertNewJob(
        title: 'New Print Job',
        body:
            'Paid: Order #${settledJob.orderId} • ${settledJob.totalPages} pages • ₹${settledJob.totalAmount.toStringAsFixed(2)}',
        payload: settledJob.orderId,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.verified_rounded, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Payment Received: ${settledJob.orderId} • PAID ₹${settledJob.totalAmount.toStringAsFixed(2)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.successGreen,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  void _handleWebSocketMessage(dynamic raw) {
    try {
      final dynamic decoded = raw is String ? jsonDecode(raw) : raw;
      final Map<String, dynamic> data = Map<String, dynamic>.from(decoded);
      final event = data['event']?.toString() ?? data['type']?.toString() ?? '';

      // 1. Order Cancelled
      if (event == 'ORDER_CANCELLED' || event == 'order_cancelled') {
        final cancelledId = data['order_id']?.toString();
        if (cancelledId != null) {
          setState(() {
            _orders.removeWhere((o) => o.orderId == cancelledId);
          });
        }
        return;
      }

      // 2. Extract order payload if present
      final Map<String, dynamic> orderMap = data['order'] is Map
          ? Map<String, dynamic>.from(data['order'] as Map)
          : Map<String, dynamic>.from(data);
      orderMap.putIfAbsent('vendor_id', () => widget.vendorId);

      final String status =
          (orderMap['status']?.toString() ?? '').toLowerCase().trim();
      final String paymentMethod = (orderMap['payment_method']?.toString() ??
              orderMap['paymentMethod']?.toString() ??
              'upi')
          .toLowerCase()
          .trim();

      final String pStatus = (orderMap['payment_status']?.toString() ??
              data['payment_status']?.toString() ??
              '')
          .toUpperCase()
          .trim();

      // Zero-Fee UPI Payment Claimed (Customer clicked "I Have Made the Payment")
      if (event == 'payment-claimed' ||
          data['event'] == 'payment-claimed' ||
          pStatus == 'PAYMENT_CLAIMED' ||
          status == 'upi_claimed' ||
          status == 'paid_queued') {
        orderMap['payment_status'] = 'PAYMENT_CLAIMED';
        final claimedJob = PrintJob.fromJson(orderMap);
        _knownJobIds.add(claimedJob.orderId);
        setState(() {
          _orders.removeWhere((o) => o.orderId == claimedJob.orderId);
          _orders.insert(0, claimedJob);
        });

        _playPaymentPing();

        final utrText = claimedJob.utrNumber != null &&
                claimedJob.utrNumber!.isNotEmpty
            ? ' • UTR #${claimedJob.utrNumber}'
            : '';

        NotificationService.alertNewJob(
          title: 'Payment Claimed',
          body:
              'UPI Claimed: ₹${claimedJob.totalAmount.toStringAsFixed(2)}$utrText. Please verify payment.',
          payload: claimedJob.orderId,
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.account_balance_wallet_rounded,
                      color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'UPI Claimed: ₹${claimedJob.totalAmount.toStringAsFixed(2)}$utrText. Please verify payment.',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              backgroundColor: const Color(0xFFF59E0B),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      // Rejection verification event - purge immediately from active live queue
      if ((event == 'payment-verified' && (data['approved'] == false || data['status'] == 'rejected')) ||
          event == 'order_rejected' ||
          data['event'] == 'order_rejected' ||
          status == 'rejected' ||
          pStatus == 'REJECTED') {
        final rejId = data['order_id']?.toString() ?? data['job_id']?.toString() ?? orderMap['order_id']?.toString();
        if (rejId != null) {
          setState(() {
            _orders.removeWhere((o) => o.orderId == rejId);
            _unprintedPaidOrderIds.remove(rejId);
            _printingOrders.remove(rejId);
          });
        }
        return;
      }

      // STRICT GATE: Discard draft uploads awaiting payment with NO chime & NO queue insertion
      if ((status == 'awaiting_payment' || status == 'pending_payment') &&
          pStatus != 'PAYMENT_CLAIMED' &&
          pStatus != 'CASH_AT_COUNTER') {
        return;
      }

      // 3. Paid Order Settlement (UPI confirmed or Cash confirmed)
      if (event == 'order_paid' ||
          event == 'ORDER_PAID' ||
          status == 'paid' ||
          (data['type'] == 'status_update' && data['status'] == 'paid') ||
          (data['event'] == 'status_update' && data['status'] == 'paid')) {
        orderMap['status'] = 'paid';
        final paidJob = PrintJob.fromJson(orderMap);
        _applyPaidSettlement(paidJob);
        return;
      }

      // 4. Cash Order Selected ("Pay Cash at Counter")
      if (status == 'pending_cash' ||
          status == 'cash_at_counter' ||
          pStatus == 'CASH_AT_COUNTER' ||
          event == 'cash_selected' ||
          data['event'] == 'cash_selected' ||
          (paymentMethod == 'cash' &&
              (event == 'new-job' ||
                  event == 'new_order' ||
                  event == 'NEW_PRINT_JOB'))) {
        final cashJob = PrintJob.fromJson(orderMap);
        final bool isNew = _knownJobIds.add(cashJob.orderId);
        setState(() {
          _orders.removeWhere((o) => o.orderId == cashJob.orderId);
          _orders.insert(0, cashJob);
        });

        _playPaymentPing();

        final tokenSuffix =
            cashJob.tokenCode != null && cashJob.tokenCode!.isNotEmpty
                ? ' • Token #${cashJob.tokenCode}'
                : '';

        if (isNew) {
          NotificationService.alertNewJob(
            title: 'New Print Job',
            body:
                'Cash Order: ${cashJob.orderId}$tokenSuffix • Pay at Counter ₹${cashJob.totalAmount.toStringAsFixed(2)}',
            payload: cashJob.orderId,
          );
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.point_of_sale_rounded,
                      color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Cash Order: ${cashJob.orderId}$tokenSuffix • Pay at Counter ₹${cashJob.totalAmount.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              backgroundColor: AppColors.warningOrange,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      // 5. General new-job / new_order or NEW_PRINT_JOB fallback
      if (event == 'new-job' ||
          event == 'new_order' ||
          event == 'NEW_PRINT_JOB') {
        final job = PrintJob.fromJson(orderMap);
        if (job.isPaid) {
          _applyPaidSettlement(job);
          return;
        }
        if (job.isCash || job.isPendingCash) {
          final bool isNew = _knownJobIds.add(job.orderId);
          setState(() {
            _orders.removeWhere((o) => o.orderId == job.orderId);
            _orders.insert(0, job);
          });
          _playPaymentPing();
          if (isNew) {
            NotificationService.alertNewJob(
              title: 'New Print Job',
              body:
                  'Order #${job.orderId} • ${job.totalPages} pages • ₹${job.totalAmount.toStringAsFixed(2)}',
              payload: job.orderId,
            );
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('Error parsing WebSocket message: $e');
    }
  }

  Future<void> _verifyOrderPayment(PrintJob job) async {
    final orderId = job.orderId;
    setState(() {
      _verifyingOrders.add(orderId);
    });

    try {
      final response = await http.post(
        ApiConfig.verifyPaymentUri(orderId),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'verified_by': 'manual'}),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        _applyPaidSettlement(job.copyWith(status: 'paid'));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to confirm payment (${response.statusCode})'),
            backgroundColor: AppColors.dangerRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error verifying payment: $e'),
            backgroundColor: AppColors.dangerRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _verifyingOrders.remove(orderId);
        });
      }
    }
  }

  Future<void> _cancelOrder(PrintJob job) async {
    final orderId = job.orderId;
    setState(() {
      _cancellingOrders.add(orderId);
    });

    try {
      final response = await http.post(ApiConfig.cancelOrderUri(orderId));
      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _orders.removeWhere((o) => o.orderId == orderId);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Order $orderId cancelled and files removed.'),
            backgroundColor: AppColors.dangerRed,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to cancel order $orderId (${response.statusCode})'),
            backgroundColor: AppColors.dangerRed,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error cancelling order: ${e.toString()}'),
          backgroundColor: AppColors.dangerRed,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _cancellingOrders.remove(orderId);
        });
      }
    }
  }

  Future<void> _handlePrintOrder(PrintJob job) async {
    if (_printingOrders.contains(job.orderId)) return;

    if (!job.isPaid) {
      if (job.isUpi) {
        await _verifyOrderPayment(job);
        final idx = _orders.indexWhere((o) => o.orderId == job.orderId);
        if (idx >= 0 && _orders[idx].isPaid) {
          job = _orders[idx];
        } else {
          return;
        }
      } else {
        return;
      }
    }

    if (!mounted) return;

    setState(() {
      _printingOrders.add(job.orderId);
    });

    try {
      final bool printed = await handlePrintOrder(
        context,
        job,
        httpClient: widget.testHttpClient,
        printExecutor: widget.testPrintExecutor,
      );

      if (!mounted) return;

      if (printed) {
        _completedOrderIds.add(job.orderId);
        _unprintedPaidOrderIds.remove(job.orderId);
        final bool needsCount = _settledOrderIds.add(job.orderId);
        setState(() {
          _orders.removeWhere((o) => o.orderId == job.orderId);
          if (needsCount) {
            _completedJobsCount++;
          }
        });

        // Update History screen in real time with local device persistence
        final completedJob = job.copyWith(
          status: 'completed',
          paymentStatus: 'COMPLETED',
          paidAt: job.paidAt ?? DateTime.now().toIso8601String(),
        );
        unawaited(OrderHistoryService.recordOrder(widget.vendorId, completedJob));
        if (!mounted) return;
        _historyScreenKey.currentState?.recordCompletedJobLocally(completedJob);

        final bool autoDeleted = job.autoDeleteAfterPrint || job.isPrivate;
        if (!mounted) return;

      ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  autoDeleted ? Icons.shield_rounded : Icons.check_circle_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    autoDeleted
                        ? 'Printing ${job.orderId} • Customer requested instant deletion: document deleted from device.'
                        : 'Printing ${job.orderId} (${job.totalPages} pages) • Sent to printer',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor:
                autoDeleted ? const Color(0xFF0D9488) : AppColors.primaryPurple,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        setState(() {
          _unprintedPaidOrderIds.add(job.orderId);
          final notPrintedJob = job.copyWith(
            status: 'paid_not_printed',
            paymentStatus: 'PAID',
          );
          final idx = _orders.indexWhere((o) => o.orderId == job.orderId);
          if (idx >= 0) {
            _orders[idx] = notPrintedJob;
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _printingOrders.remove(job.orderId);
        });
      }
    }
  }

  Future<void> _handleConfirmCashAndPrint(PrintJob job) async {
    final orderId = job.orderId;
    if (_printingOrders.contains(orderId)) return;

    setState(() {
      _printingOrders.add(orderId);
    });

    try {
      final client = widget.testHttpClient ?? http.Client();
      final bool ownsClient = widget.testHttpClient == null;
      PrintJob paidJob = job.copyWith(
        status: 'paid',
        paymentMethod: 'cash',
        paidAt: DateTime.now().toIso8601String(),
      );

      try {
        final response = await client.post(
          ApiConfig.confirmCashUri(orderId),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'confirmed_by': 'vendor'}),
        ).timeout(const Duration(seconds: 4));

        if (response.statusCode == 200) {
          final dynamic data = jsonDecode(response.body);
          if (data is Map && data['order'] is Map) {
            paidJob = PrintJob.fromJson(
                Map<String, dynamic>.from(data['order'] as Map));
          } else if (data is Map && data['order_id'] != null) {
            paidJob = PrintJob.fromJson(Map<String, dynamic>.from(data));
          }
        }
      } catch (e) {
        debugPrint('Warning: Cash confirmation network error: $e');
      } finally {
        if (ownsClient) client.close();
      }

      if (!mounted) return;

      // Update session total earnings and order state locally
      _applyPaidSettlement(paidJob);

      // Immediately launch Android Print Spooler preview in one tap
      final bool printed = await handlePrintOrder(
        context,
        paidJob,
        httpClient: widget.testHttpClient,
        printExecutor: widget.testPrintExecutor,
      );

      if (!mounted) return;

      if (printed) {
        _completedOrderIds.add(paidJob.orderId);
        _unprintedPaidOrderIds.remove(paidJob.orderId);
        final bool needsCount = _settledOrderIds.add(paidJob.orderId);
        setState(() {
          _orders.removeWhere((o) => o.orderId == paidJob.orderId);
          if (needsCount) {
            _completedJobsCount++;
          }
        });

        final completedJob = paidJob.copyWith(
          status: 'completed',
          paymentStatus: 'COMPLETED',
          paidAt: paidJob.paidAt ?? DateTime.now().toIso8601String(),
        );
        unawaited(OrderHistoryService.recordOrder(widget.vendorId, completedJob));
        if (!mounted) return;
        _historyScreenKey.currentState?.recordCompletedJobLocally(completedJob);

        final bool autoDeleted = paidJob.autoDeleteAfterPrint || paidJob.isPrivate;
        if (!mounted) return;

      ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  autoDeleted
                      ? Icons.shield_rounded
                      : Icons.check_circle_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    autoDeleted
                        ? 'Printing ${paidJob.orderId} • Customer requested instant deletion: document deleted from device.'
                        : 'Printing ${paidJob.orderId} (${paidJob.totalPages} pages) • Sent to printer',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor:
                autoDeleted ? const Color(0xFF0D9488) : AppColors.primaryPurple,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        setState(() {
          _unprintedPaidOrderIds.add(paidJob.orderId);
          final notPrintedJob = paidJob.copyWith(
            status: 'paid_not_printed',
            paymentStatus: 'PAID',
          );
          final idx = _orders.indexWhere((o) => o.orderId == paidJob.orderId);
          if (idx >= 0) {
            _orders[idx] = notPrintedJob;
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _printingOrders.remove(orderId);
        });
      }
    }
  }

  Future<void> _handleVerifyPaymentAndPrint(PrintJob job) async {
    final orderId = job.orderId;
    if (_printingOrders.contains(orderId)) return;

    setState(() {
      _printingOrders.add(orderId);
    });

    try {
      final client = widget.testHttpClient ?? http.Client();
      final bool ownsClient = widget.testHttpClient == null;
      PrintJob paidJob = job.copyWith(
        status: 'paid',
        paymentStatus: 'PAID',
        paidAt: DateTime.now().toIso8601String(),
      );

      // STEP 1: Verify payment on backend FIRST before print spooling
      try {
        final response = await client.post(
          ApiConfig.verifyJobPaymentUri(orderId),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'approved': true, 'verified_by': 'vendor_dashboard'}),
        ).timeout(const Duration(seconds: 7));

        if (response.statusCode == 200) {
          final dynamic data = jsonDecode(response.body);
          if (data is Map && data['order'] is Map) {
            paidJob = PrintJob.fromJson(
                Map<String, dynamic>.from(data['order'] as Map));
          } else if (data is Map && data['order_id'] != null) {
            paidJob = PrintJob.fromJson(Map<String, dynamic>.from(data));
          }
        } else {
          // If server rejects verification, show error and halt before spooling
          if (mounted) {
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                    'Payment verification failed (${response.statusCode}): ${response.body}'),
                backgroundColor: AppColors.dangerRed,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            );
          }
          return;
        }
      } catch (e) {
        debugPrint('Warning: Payment verification network error: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Network error verifying payment: $e'),
              backgroundColor: AppColors.dangerRed,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
        return;
      } finally {
        if (ownsClient) client.close();
      }

      if (!mounted) return;

      // Ensure paidJob is explicitly marked PAID
      paidJob = paidJob.copyWith(
        status: 'paid',
        paymentStatus: 'PAID',
      );

      // STEP 2: Update session total earnings and order state locally to PAID
      _applyPaidSettlement(paidJob);

      // STEP 3: Decoupled Print Spooling: launch Android Print Spooler preview.
      // If print dialog fails or is cancelled, payment status is NEVER reverted to rejected.
      final bool printed = await handlePrintOrder(
        context,
        paidJob,
        httpClient: widget.testHttpClient,
        printExecutor: widget.testPrintExecutor,
      );

      if (!mounted) return;

      if (printed) {
        _completedOrderIds.add(paidJob.orderId);
        _unprintedPaidOrderIds.remove(paidJob.orderId);
        final bool needsCount = _settledOrderIds.add(paidJob.orderId);
        setState(() {
          _orders.removeWhere((o) => o.orderId == paidJob.orderId);
          if (needsCount) {
            _completedJobsCount++;
          }
        });

        final completedJob = paidJob.copyWith(
          status: 'completed',
          paymentStatus: 'COMPLETED',
          paidAt: paidJob.paidAt ?? DateTime.now().toIso8601String(),
        );
        unawaited(OrderHistoryService.recordOrder(widget.vendorId, completedJob));
        if (!mounted) return;
        _historyScreenKey.currentState?.recordCompletedJobLocally(completedJob);

        final bool autoDeleted = paidJob.autoDeleteAfterPrint || paidJob.isPrivate;
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  autoDeleted
                      ? Icons.shield_rounded
                      : Icons.check_circle_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    autoDeleted
                        ? 'Payment Verified & Printed ${paidJob.orderId} • Sensitive file deleted.'
                        : 'Payment Verified & Spooled ${paidJob.orderId}.',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor: AppColors.successGreen,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        // Print cancelled or backed out: payment remains PAID!
        // Order is retained in queue with "PAID • Not Printed" badge, "Retry Print", and "Mark Completed".
        setState(() {
          _unprintedPaidOrderIds.add(paidJob.orderId);
          final notPrintedJob = paidJob.copyWith(
            status: 'paid_not_printed',
            paymentStatus: 'PAID',
          );
          final idx = _orders.indexWhere((o) => o.orderId == paidJob.orderId);
          if (idx >= 0) {
            _orders[idx] = notPrintedJob;
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _printingOrders.remove(job.orderId);
        });
      }
    }
  }

  Future<void> _markOrderCompleted(PrintJob job) async {
    final orderId = job.orderId;
    if (_printingOrders.contains(orderId)) return;

    setState(() {
      _printingOrders.add(orderId);
    });

    try {
      final client = widget.testHttpClient ?? http.Client();
      final bool ownsClient = widget.testHttpClient == null;
      try {
        final statusUri = ApiConfig.updateOrderStatusUri(orderId);
        await client.post(
          statusUri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'status': 'completed'}),
        ).timeout(const Duration(seconds: 4));
      } catch (e) {
        debugPrint('Failed to broadcast completed status to backend: $e');
      } finally {
        if (ownsClient) client.close();
      }

      final completedJob = job.copyWith(
        status: 'completed',
        paymentStatus: 'COMPLETED',
        paidAt: job.paidAt ?? DateTime.now().toIso8601String(),
      );

      _completedOrderIds.add(orderId);
      _unprintedPaidOrderIds.remove(orderId);
      final bool needsCount = _settledOrderIds.add(orderId);
      setState(() {
        _orders.removeWhere((o) => o.orderId == orderId);
        if (needsCount) {
          _completedJobsCount++;
        }
      });

      unawaited(OrderHistoryService.recordOrder(widget.vendorId, completedJob));
      if (!mounted) return;
      _historyScreenKey.currentState?.recordCompletedJobLocally(completedJob);

      if (job.autoDeleteAfterPrint || job.isPrivate) {
        try {
          final ordersDir = await getOrdersDirectory();
          final localFile = File('${ordersDir.path}/$orderId.pdf');
          if (localFile.existsSync()) {
            localFile.deleteSync();
          }
        } catch (_) {}
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded,
                  color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Order $orderId marked as completed.',
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
    } finally {
      if (mounted) {
        setState(() {
          _printingOrders.remove(orderId);
        });
      }
    }
  }

  Future<void> _handleRejectPayment(PrintJob job) async {
    final orderId = job.orderId;
    final client = widget.testHttpClient ?? http.Client();
    final bool ownsClient = widget.testHttpClient == null;
    try {
      final response = await client.post(
        ApiConfig.verifyJobPaymentUri(orderId),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'approved': false, 'verified_by': 'vendor_dashboard'}),
      ).timeout(const Duration(seconds: 7));

      if (response.statusCode == 200) {
        setState(() {
          _orders.removeWhere((o) => o.orderId == orderId);
          _unprintedPaidOrderIds.remove(orderId);
          _printingOrders.remove(orderId);
        });

        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Payment claim rejected for ${job.orderId}'),
              backgroundColor: AppColors.dangerRed,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to reject order (${response.statusCode}): ${response.body}'),
              backgroundColor: AppColors.dangerRed,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error rejecting payment: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Network error rejecting order: $e'),
            backgroundColor: AppColors.dangerRed,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } finally {
      if (ownsClient) client.close();
    }
  }

  /// Presents modals with a smooth scale + fade entrance instead of an abrupt pop-in.
  Future<T?> _showAnimatedModal<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    Color? barrierColor,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: barrierColor ?? Colors.black.withValues(alpha: 0.55),
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (dialogCtx, anim1, anim2) => builder(dialogCtx),
      transitionBuilder: (dialogCtx, anim, secondaryAnim, child) {
        final double scaleValue = anim.status == AnimationStatus.reverse
            ? Curves.easeInCubic.transform(anim.value)
            : Curves.easeOutBack.transform(anim.value);
        return Transform.scale(
          scale: scaleValue,
          child: Opacity(
            opacity: anim.value.clamp(0.0, 1.0),
            child: child,
          ),
        );
      },
    );
  }

  Future<bool> _saveQrToStorage(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      final boundary = _qrCaptureKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        throw Exception('QR preview is not ready yet.');
      }

      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final ByteData? byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();

      if (byteData == null) {
        throw Exception('Failed to encode QR image.');
      }
      final Uint8List pngBytes = byteData.buffer.asUint8List();

      bool hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        hasAccess = await Gal.requestAccess();
      }
      if (!hasAccess) {
        throw Exception('Storage permission denied.');
      }

      await Gal.putImageBytes(
        pngBytes,
        name: 'PrintPulse_QR_${DateTime.now().millisecondsSinceEpoch}',
      );

      await HapticFeedback.mediumImpact();
      if (!mounted) return true;

      messenger.showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Counter QR saved to Gallery',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF7C3AED),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
      return true;
    } catch (e) {
      if (!mounted) return false;
      messenger.showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Failed to save QR: ${e.toString().replaceFirst('Exception: ', '')}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.dangerRed,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
      return false;
    }
  }

  String get _resolvedShopUrl => widget.shopUrl.isNotEmpty
      ? ApiConfig.normalizeLegacyHost(widget.shopUrl)
      : ApiConfig.customerShopUrl(widget.vendorId);

  void _showQrModal() {
    final qrData = _resolvedShopUrl;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      elevation: 0,
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 380),
        reverseDuration: Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final palette = PrintPulsePalette.of(sheetContext);
        final primaryTextColor = theme.colorScheme.onSurface;

        bool isSaving = false;
        bool isSaved = false;

        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: palette.sheetBg,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(32),
                ),
                border: Border.all(
                  color: palette.sheetBorder,
                  width: 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: palette.sheetShadow,
                    blurRadius: 28,
                    offset: const Offset(0, -6),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Centered Drag Handle Pill
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: palette.sheetHandle,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Centered Header Title + Top-Right Circular Close Button
                      Row(
                        children: [
                          const SizedBox(width: 36),
                          Expanded(
                            child: Text(
                              'Counter QR Code',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.4,
                                color: primaryTextColor,
                              ),
                            ),
                          ),
                          Material(
                            color: palette.sheetCloseBg,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => Navigator.of(sheetContext).pop(),
                              child: SizedBox(
                                width: 36,
                                height: 36,
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 20,
                                  color: primaryTextColor,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // Capturable White Counter QR Card
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: palette.sheetQrGlow,
                              blurRadius: 28,
                              spreadRadius: 1,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: RepaintBoundary(
                          key: _qrCaptureKey,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 22,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: const Color(0xFF7C3AED)
                                    .withValues(alpha: 0.10),
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                QrImageView(
                                  data: qrData,
                                  version: QrVersions.auto,
                                  size: 210,
                                  backgroundColor: Colors.white,
                                  padding: const EdgeInsets.all(4),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  widget.vendorId,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'monospace',
                                    letterSpacing: 1.2,
                                    color: Color(0xFF4C1D95),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Scan to open web portal and submit instant print jobs.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    height: 1.4,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF6B7280),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 26),

                      // Bottom Action Pill Buttons
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton.icon(
                          onPressed: isSaving
                              ? null
                              : () async {
                                  setSheetState(() => isSaving = true);
                                  final ok =
                                      await _saveQrToStorage(sheetContext);
                                  if (!sheetContext.mounted) return;
                                  setSheetState(() {
                                    isSaving = false;
                                    if (ok) isSaved = true;
                                  });
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF7C3AED),
                            foregroundColor: Colors.white,
                            disabledBackgroundColor:
                                const Color(0xFF7C3AED).withValues(alpha: 0.65),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(9999),
                            ),
                          ),
                          icon: isSaving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                                  ),
                                )
                              : Icon(
                                  isSaved
                                      ? Icons.check_rounded
                                      : Icons.download_rounded,
                                  size: 20,
                                ),
                          label: Text(
                            isSaved ? 'Saved to Gallery' : 'Save to Gallery',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: TextButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          style: TextButton.styleFrom(
                            backgroundColor: palette.sheetSecondaryBtnBg,
                            foregroundColor: palette.sheetSecondaryBtnFg,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(9999),
                            ),
                          ),
                          child: const Text(
                            'Done',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDisconnectConfirmDialog(BuildContext ctx) {
    final bool isDark = Theme.of(ctx).brightness == Brightness.dark;
    final Color surfaceColor =
        isDark ? const Color(0xFF1E1735) : Colors.white;
    final Color borderColor =
        isDark ? Colors.white.withValues(alpha: 0.12) : const Color(0xFFE5E7EB);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: borderColor, width: 1.0),
            boxShadow: isDark
                ? const []
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Warning Icon Badge
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.redAccent.withValues(alpha: 0.12),
                ),
                child: const Icon(
                  Icons.logout_rounded,
                  size: 24,
                  color: Colors.redAccent,
                ),
              ),
              const SizedBox(height: 16),
              // Title
              Text(
                'Disconnect Kiosk?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : AppColors.lightTextPrimary,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 8),
              // Description
              Text(
                'Are you sure you want to sign out? Live queue monitoring and walk-in print reception will pause.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.45,
                  color: isDark ? Colors.white70 : const Color(0xFF6B7280),
                ),
              ),
              const SizedBox(height: 24),
              // Full-width balanced action row
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        backgroundColor: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : const Color(0xFFF3F4F6),
                      ),
                      child: Text(
                        'Cancel',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color:
                              isDark ? Colors.white : const Color(0xFF374151),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        elevation: 0,
                        backgroundColor: const Color(0xFFEF4444),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        'Disconnect',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleSignOut() async {
    final confirmed = await _showAnimatedModal<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: _buildDisconnectConfirmDialog,
    );

    if (confirmed == true) {
      if (!mounted) return;

      // 1. Dismiss any active SnackBars so no floating dependent widgets remain
      if (!mounted) return;

      ScaffoldMessenger.of(context).clearSnackBars();

      // 2. Perform background sign-out & credential clearing
      await GoogleAuthService.signOut();
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      if (!mounted) return;

      // 3. Ensure the dialog's reverse transition (320ms) has fully finished
      // so all dialog Elements and InheritedTheme dependents are cleanly unmounted
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;

      // 4. Update top-level declarative auth state
      activeVendorIdNotifier.value = null;
      activeShopUrlNotifier.value = '';

      // 5. Cleanly reset root navigator to AuthScreen with zero orphaned dependents
      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => const AuthScreen(key: ValueKey('auth_screen')),
        ),
        (route) => false,
      );
    }
  }

  Future<void> _launchDeveloperUrl(BuildContext context) async {
    final Uri url = Uri.parse('https://abhayv175.netlify.app');
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bool launched = await launchUrl(
        url,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && context.mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Could not open developer portfolio.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Error opening link: $e')),
        );
      }
    }
  }

  ({PrintPulsePalette palette, Color primary, Color secondary})
      _resolveThemeColors(BuildContext context) {
    final theme = Theme.of(context);
    final palette = PrintPulsePalette.of(context);
    return (
      palette: palette,
      primary: theme.colorScheme.onSurface,
      secondary: theme.textTheme.bodyMedium?.color ?? AppColors.lightTextSecondary,
    );
  }

  // -------------------------------------------------------------------------
  // TAB 1: HOME SECTION
  // -------------------------------------------------------------------------
  Widget _buildHomeTab(BuildContext context) {
    final colors = _resolveThemeColors(context);
    final primaryTextColor = colors.primary;
    final secondaryTextColor = colors.secondary;

    return SafeArea(
      top: true,
      bottom: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(top: 12, left: 20, right: 20, bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Greeting & Status Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Good day, Vendor 👋',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: primaryTextColor,
                          letterSpacing: -0.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // Live Status Pill
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: (_isConnected
                            ? AppColors.successGreen
                            : AppColors.warningOrange)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(9999),
                    border: Border.all(
                      color: (_isConnected
                              ? AppColors.successGreen
                              : AppColors.warningOrange)
                          .withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: _isConnected ? AppColors.successGreen : AppColors.warningOrange,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _isConnected ? 'Online' : (_isConnecting ? 'Connecting' : 'Offline'),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _isConnected ? AppColors.successGreen : AppColors.warningOrange,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1, end: 0),

            const SizedBox(height: 20),

            // Featured Counter QR Trigger Card
            GlassContainer(
              borderRadius: 24,
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.primaryPurple, AppColors.activePurple],
                      ),
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primaryPurple.withValues(alpha: 0.3),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.qr_code_scanner_rounded,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Counter QR Code',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: primaryTextColor,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Display on counter for customer scans',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: secondaryTextColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: _showQrModal,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryPurple,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9999),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.fullscreen_rounded, size: 18),
                        SizedBox(width: 6),
                        Text(
                          'View QR',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(duration: 400.ms, delay: 100.ms).slideY(begin: 0.1, end: 0),

            const SizedBox(height: 20),

            // Connected Printer Details Card
            GlassContainer(
              borderRadius: 24,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            const Icon(
                              Icons.local_printshop_rounded,
                              color: AppColors.primaryPurple,
                              size: 22,
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                'Connected Printer',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: primaryTextColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Status Badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.successGreen.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(9999),
                          border: Border.all(
                            color: AppColors.successGreen.withValues(alpha: 0.35),
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle_rounded, color: AppColors.successGreen, size: 14),
                            SizedBox(width: 5),
                            Text(
                              'Ready',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.successGreen,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Divider(
                    height: 1,
                    thickness: 1,
                    color: Color(0x1A7C3AED),
                  ),
                  const SizedBox(height: 14),
                  // Printer Meta Grid
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildPrinterMeta(
                        icon: Icons.wifi_tethering_rounded,
                        label: 'Spooler Protocol',
                        value: 'Android Spooler',
                        secondaryTextColor: secondaryTextColor,
                        primaryTextColor: primaryTextColor,
                      ),
                      const SizedBox(width: 8),
                      _buildPrinterMeta(
                        icon: Icons.newspaper_rounded,
                        label: 'Paper Format',
                        value: 'A4 Normal',
                        secondaryTextColor: secondaryTextColor,
                        primaryTextColor: primaryTextColor,
                      ),
                      const SizedBox(width: 8),
                      _buildPrinterMeta(
                        icon: Icons.high_quality_rounded,
                        label: 'Resolution',
                        value: '600 × 600',
                        secondaryTextColor: secondaryTextColor,
                        primaryTextColor: primaryTextColor,
                      ),
                    ],
                  ),
                ],
              ),
            ).animate().fadeIn(duration: 400.ms, delay: 200.ms).slideY(begin: 0.1, end: 0),

          const SizedBox(height: 20),

          // Quick Stats Bar
          Row(
            children: [
              Expanded(
                child: GlassContainer(
                  borderRadius: 20,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.check_circle_outline_rounded,
                              size: 18, color: AppColors.primaryPurple),
                          const SizedBox(width: 8),
                          Text(
                            'Printed Today',
                            style: TextStyle(fontSize: 12.5, color: secondaryTextColor),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '$_completedJobsCount jobs',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: primaryTextColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: GlassContainer(
                  borderRadius: 20,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.currency_rupee_rounded,
                              size: 18, color: AppColors.primaryPurple),
                          const SizedBox(width: 8),
                          Text(
                            'Session Total',
                            style: TextStyle(fontSize: 12.5, color: secondaryTextColor),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '₹${_totalEarnings.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primaryPurple,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ).animate().fadeIn(duration: 400.ms, delay: 300.ms).slideY(begin: 0.1, end: 0),
        ],
      ),
    ),
  );
}

  Widget _buildPrinterMeta({
    required IconData icon,
    required String label,
    required String value,
    required Color secondaryTextColor,
    required Color primaryTextColor,
  }) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: AppColors.primaryPurple),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: secondaryTextColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: primaryTextColor,
            ),
          ),
        ],
      ),
    );
  }

  /// Filtered active live queue list (excluding rejected, completed, and cancelled orders)
  List<PrintJob> get _activeQueueOrders => _orders.where((o) =>
      o.paymentStatus != 'REJECTED' &&
      o.status.toLowerCase() != 'rejected' &&
      o.status.toLowerCase() != 'completed' &&
      o.status.toLowerCase() != 'cancelled' &&
      !_completedOrderIds.contains(o.orderId)
  ).toList();

  int get _activeQueueCount => _activeQueueOrders.length;

  // -------------------------------------------------------------------------
  // TAB 2: QUEUE SECTION (LIVE PRINT ORDERS)
  // -------------------------------------------------------------------------
  Widget _buildQueueTab(BuildContext context) {
    final colors = _resolveThemeColors(context);
    final palette = colors.palette;
    final primaryTextColor = colors.primary;
    final secondaryTextColor = colors.secondary;

    // Active Live Queue: filter out rejected, completed, and cancelled jobs
    final activeQueueOrders = _activeQueueOrders;

    return SafeArea(
      child: Column(
        children: [
          // Header Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Text(
                      'Live Queue',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: primaryTextColor,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.primaryPurple,
                        borderRadius: BorderRadius.circular(9999),
                      ),
                      child: Text(
                        '${activeQueueOrders.length}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                // QR Button
                TextButton.icon(
                  onPressed: _showQrModal,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primaryPurple,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  ),
                  icon: const Icon(Icons.qr_code_rounded, size: 18),
                  label: const Text(
                    'Show QR',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),

          // Orders List or Empty Glass State
          Expanded(
            child: activeQueueOrders.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32.0),
                      child: GlassContainer(
                        borderRadius: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 76,
                              height: 76,
                              decoration: BoxDecoration(
                                color: AppColors.primaryPurple.withValues(alpha: 0.1),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.hourglass_empty_rounded,
                                color: AppColors.primaryPurple,
                                size: 36,
                              ),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              'Queue is Empty',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: primaryTextColor,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Waiting for walk-in scans...\nNew customer print jobs will appear instantly.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                color: secondaryTextColor,
                                height: 1.45,
                              ),
                            ),
                            const SizedBox(height: 24),
                            ElevatedButton.icon(
                              onPressed: _showQrModal,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primaryPurple,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(9999),
                                ),
                              ),
                              icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                              label: const Text(
                                'Display Counter QR',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ).animate().fadeIn(duration: 350.ms)
                : ListView.separated(
                    padding: const EdgeInsets.only(top: 4, left: 20, right: 20, bottom: 100),
                    itemCount: activeQueueOrders.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 14),
                    itemBuilder: (context, index) {
                      final job = activeQueueOrders[index];
                      final isCancelling = _cancellingOrders.contains(job.orderId);
                      final bool isPaid = job.isPaid;
                      final bool isNotPrinted =
                          job.isNotPrinted || _unprintedPaidOrderIds.contains(job.orderId);
                      final bool isPreparing =
                          _printingOrders.contains(job.orderId);

                      // Resolve primary action styling and callbacks
                      final List<Color> primaryGradientColors;
                      final Color primaryShadowColor;
                      final IconData primaryIconData;
                      final String primaryLabel;
                      final VoidCallback? onPrimaryAction;

                      if (job.isPaymentClaimed) {
                        primaryGradientColors = const [
                          Color(0xFF10B981),
                          Color(0xFF059669),
                        ];
                        primaryShadowColor = const Color(0xFF10B981);
                        primaryIconData = Icons.verified_rounded;
                        primaryLabel = isPreparing
                            ? 'PREPARING...'
                            : 'VERIFY & PRINT';
                        onPrimaryAction = isPreparing
                            ? null
                            : () => _handleVerifyPaymentAndPrint(job);
                      } else if (isPaid ||
                          (!job.isCash && !job.isCashAtCounter)) {
                        primaryGradientColors = const [
                          AppColors.primaryPurple,
                          AppColors.activePurple,
                        ];
                        primaryShadowColor = AppColors.primaryPurple;
                        primaryIconData = Icons.print_rounded;
                        primaryLabel = isPreparing
                            ? 'PREPARING...'
                            : (isNotPrinted ? 'Retry Print' : 'PRINT');
                        onPrimaryAction = isPreparing
                            ? null
                            : () => _handlePrintOrder(job);
                      } else {
                        primaryGradientColors = const [
                          Color(0xFFF59E0B),
                          Color(0xFFD97706),
                        ];
                        primaryShadowColor = const Color(0xFFF59E0B);
                        primaryIconData = Icons.verified_rounded;
                        primaryLabel = isPreparing
                            ? 'PREPARING...'
                            : 'Verify & Print';
                        onPrimaryAction = isPreparing
                            ? null
                            : () => _handleConfirmCashAndPrint(job);
                      }

                      return GlassContainer(
                        borderRadius: 22,
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Card Header: Order ID & Payment Status Badge
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: AppColors.primaryPurple
                                              .withValues(alpha: 0.1),
                                          borderRadius: BorderRadius.circular(9999),
                                          border: Border.all(
                                            color: AppColors.primaryPurple
                                                .withValues(alpha: 0.25),
                                          ),
                                        ),
                                        child: Text(
                                          job.orderId,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.primaryPurple,
                                          ),
                                        ),
                                      ),
                                      if (job.timestamp.isNotEmpty)
                                        Text(
                                          job.timestamp,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: secondaryTextColor,
                                          ),
                                        ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: job.isLandscape
                                              ? const Color(0xFF6366F1)
                                                  .withValues(alpha: 0.14)
                                              : palette.subtlePillBg,
                                          borderRadius:
                                              BorderRadius.circular(9999),
                                          border: Border.all(
                                            color: job.isLandscape
                                                ? const Color(0xFF6366F1)
                                                    .withValues(alpha: 0.35)
                                                : Colors.transparent,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              job.isLandscape
                                                  ? Icons.landscape_rounded
                                                  : Icons.portrait_rounded,
                                              size: 11,
                                              color: job.isLandscape
                                                  ? const Color(0xFF6366F1)
                                                  : secondaryTextColor,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              job.isLandscape
                                                  ? 'Landscape'
                                                  : 'Portrait',
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w700,
                                                color: job.isLandscape
                                                    ? const Color(0xFF6366F1)
                                                    : secondaryTextColor,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (job.autoDeleteAfterPrint || job.isPrivate)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF10B981)
                                                .withValues(alpha: 0.14),
                                            borderRadius:
                                                BorderRadius.circular(9999),
                                            border: Border.all(
                                              color: const Color(0xFF10B981)
                                                  .withValues(alpha: 0.35),
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: const [
                                              Icon(
                                                Icons.shield_outlined,
                                                size: 11,
                                                color: Color(0xFF10B981),
                                              ),
                                              SizedBox(width: 4),
                                              Text(
                                                'Auto-Delete After Print',
                                                style: TextStyle(
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.w700,
                                                  color: Color(0xFF10B981),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (isNotPrinted)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF59E0B)
                                          .withValues(alpha: 0.16),
                                      borderRadius: BorderRadius.circular(9999),
                                      border: Border.all(
                                        color: const Color(0xFFF59E0B)
                                            .withValues(alpha: 0.5),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: const [
                                        Icon(
                                          Icons.warning_amber_rounded,
                                          size: 14,
                                          color: Color(0xFFD97706),
                                        ),
                                        SizedBox(width: 5),
                                        Text(
                                          'PAID • Ready to Print',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w800,
                                            color: Color(0xFFD97706),
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                else if (isPaid)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: AppColors.successGreen
                                          .withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(9999),
                                      border: Border.all(
                                        color: AppColors.successGreen
                                            .withValues(alpha: 0.4),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.verified_rounded,
                                          size: 14,
                                          color: AppColors.successGreen,
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          'PAID • ₹${job.totalAmount.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w800,
                                            color: AppColors.successGreen,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                else if (job.isPaymentClaimed)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF59E0B)
                                          .withValues(alpha: 0.16),
                                      borderRadius: BorderRadius.circular(9999),
                                      border: Border.all(
                                        color: const Color(0xFFF59E0B)
                                            .withValues(alpha: 0.5),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.account_balance_wallet_rounded,
                                          size: 14,
                                          color: Color(0xFFD97706),
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          job.utrNumber != null &&
                                                  job.utrNumber!.isNotEmpty
                                              ? 'PAYMENT CLAIMED • ₹${job.totalAmount.toStringAsFixed(2)} (#${job.utrNumber})'
                                              : 'PAYMENT CLAIMED • ₹${job.totalAmount.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w800,
                                            color: Color(0xFFD97706),
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                else if (job.isCashAtCounter ||
                                    job.isCash ||
                                    job.isPendingCash)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: AppColors.warningOrange
                                          .withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(9999),
                                      border: Border.all(
                                        color: AppColors.warningOrange
                                            .withValues(alpha: 0.4),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.point_of_sale_rounded,
                                          size: 14,
                                          color: AppColors.warningOrange,
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          job.tokenCode != null &&
                                                  job.tokenCode!.isNotEmpty
                                              ? 'Cash at Counter • ₹${job.totalAmount.toStringAsFixed(2)} (#${job.tokenCode})'
                                              : 'Cash at Counter • ₹${job.totalAmount.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w800,
                                            color: AppColors.warningOrange,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                else
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: AppColors.warningOrange
                                          .withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(9999),
                                      border: Border.all(
                                        color: AppColors.warningOrange
                                            .withValues(alpha: 0.4),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.lock_clock_rounded,
                                          size: 13,
                                          color: AppColors.warningOrange,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          'Awaiting Payment • ₹${job.totalAmount.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.warningOrange,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            const Divider(
                              height: 20,
                              thickness: 1,
                              color: Color(0x1A7C3AED),
                            ),
                            const SizedBox(height: 12),

                            // Document Items (with clean summary fallback for API-only orders)
                            if (job.documents.isNotEmpty)
                              Column(
                                children: job.documents.map((doc) {
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 8.0),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.description_outlined,
                                          size: 18,
                                          color: AppColors.primaryPurple,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            doc.originalFilename,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w500,
                                              color: primaryTextColor,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        // Pages Pill
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: palette.subtlePillBg,
                                            borderRadius:
                                                BorderRadius.circular(9999),
                                          ),
                                          child: Text(
                                            '${doc.pages}p × ${doc.copies}',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: secondaryTextColor,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        // Color/B&W Pill
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: doc.isColor
                                                ? Colors.amber
                                                    .withValues(alpha: 0.18)
                                                : palette.subtlePillBg,
                                            borderRadius:
                                                BorderRadius.circular(9999),
                                          ),
                                          child: Text(
                                            doc.isColor ? 'Color' : 'B&W',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: doc.isColor
                                                  ? Colors.amber.shade700
                                                  : secondaryTextColor,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        // Orientation Pill
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: doc.isLandscape
                                                ? const Color(0xFF6366F1)
                                                    .withValues(alpha: 0.14)
                                                : palette.subtlePillBg,
                                            borderRadius:
                                                BorderRadius.circular(9999),
                                          ),
                                          child: Text(
                                            doc.isLandscape
                                                ? 'Landscape'
                                                : 'Portrait',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: doc.isLandscape
                                                  ? const Color(0xFF6366F1)
                                                  : secondaryTextColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                              )
                            else
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8.0),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.description_outlined,
                                      size: 18,
                                      color: AppColors.primaryPurple,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Walk-in Print Document',
                                        style: TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w500,
                                          color: primaryTextColor,
                                        ),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: palette.subtlePillBg,
                                        borderRadius:
                                            BorderRadius.circular(9999),
                                      ),
                                      child: Text(
                                        job.hasColor ? 'Color' : 'B&W',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: job.hasColor
                                              ? Colors.amber.shade700
                                              : secondaryTextColor,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: job.isLandscape
                                            ? const Color(0xFF6366F1)
                                                .withValues(alpha: 0.14)
                                            : palette.subtlePillBg,
                                        borderRadius:
                                            BorderRadius.circular(9999),
                                      ),
                                      child: Text(
                                        job.isLandscape
                                            ? 'Landscape'
                                            : 'Portrait',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: job.isLandscape
                                              ? const Color(0xFF6366F1)
                                              : secondaryTextColor,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 8),

                            // Summary Meta
                            Text(
                              '${job.totalPhysicalPages} Total Pages • ${job.totalCopies} Total Copies',
                              style: TextStyle(
                                fontSize: 12,
                                color: secondaryTextColor,
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Action Buttons: Balanced 50/50 Row with matching 44px height and pill borders
                            Row(
                              children: [
                                // Secondary Action: "Mark Completed" (when paid) or "Cancel" / "Reject"
                                Expanded(
                                  child: SizedBox(
                                    height: 44,
                                    child: OutlinedButton.icon(
                                      onPressed: isCancelling
                                          ? null
                                          : () {
                                              if (isPaid) {
                                                _markOrderCompleted(job);
                                              } else if (job.isPaymentClaimed) {
                                                _handleRejectPayment(job);
                                              } else {
                                                _cancelOrder(job);
                                              }
                                            },
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: isPaid
                                            ? AppColors.successGreen
                                            : AppColors.dangerRed,
                                        side: BorderSide(
                                          color: (isPaid
                                                  ? AppColors.successGreen
                                                  : AppColors.dangerRed)
                                              .withValues(alpha: 0.45),
                                          width: 1.2,
                                        ),
                                        backgroundColor: (isPaid
                                                ? AppColors.successGreen
                                                : AppColors.dangerRed)
                                            .withValues(alpha: 0.08),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(9999),
                                        ),
                                      ),
                                      icon: isCancelling
                                          ? SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                        Color>(
                                                  isPaid
                                                      ? AppColors.successGreen
                                                      : AppColors.dangerRed,
                                                ),
                                              ),
                                            )
                                          : Icon(
                                              isPaid
                                                  ? Icons.check_circle_outline_rounded
                                                  : Icons.close_rounded,
                                              size: 16,
                                            ),
                                      label: Text(
                                        isCancelling
                                            ? 'Updating...'
                                            : (isPaid
                                                ? 'Mark Completed'
                                                : (job.isPaymentClaimed
                                                    ? 'REJECT'
                                                    : 'Cancel')),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        softWrap: false,
                                        style: const TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                // Primary Action: "Print" / "Retry Print" / "Verify & Print"
                                Expanded(
                                  child: SizedBox(
                                    height: 44,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius:
                                            BorderRadius.circular(9999),
                                        gradient: LinearGradient(
                                          colors: primaryGradientColors,
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: primaryShadowColor
                                                .withValues(alpha: 0.32),
                                            blurRadius: 12,
                                            offset: const Offset(0, 3),
                                          ),
                                        ],
                                      ),
                                      child: ElevatedButton.icon(
                                        onPressed: onPrimaryAction,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.transparent,
                                          shadowColor: Colors.transparent,
                                          disabledBackgroundColor:
                                              Colors.transparent,
                                          disabledForegroundColor: Colors.white
                                              .withValues(alpha: 0.75),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(9999),
                                          ),
                                        ),
                                        icon: isPreparing
                                            ? const SizedBox(
                                                width: 14,
                                                height: 14,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  valueColor:
                                                      AlwaysStoppedAnimation<
                                                          Color>(Colors.white),
                                                ),
                                              )
                                            : Icon(primaryIconData, size: 16),
                                        label: Text(
                                          primaryLabel,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          softWrap: false,
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // TAB 3: PROFILE & SETTINGS SECTION
  // -------------------------------------------------------------------------
  Widget _buildProfileTab(BuildContext context) {
    final colors = _resolveThemeColors(context);
    final palette = colors.palette;
    final primaryTextColor = colors.primary;
    final secondaryTextColor = colors.secondary;

    return SafeArea(
      top: true,
      bottom: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(top: 16, left: 20, right: 20, bottom: 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Section Title
            Text(
              'Kiosk Profile & Settings',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: primaryTextColor,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 18),

            // Shop / Vendor Details Card
            GlassContainer(
              borderRadius: 24,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [AppColors.primaryPurple, AppColors.secondaryPurple],
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(Icons.storefront_rounded, color: Colors.white, size: 28),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _shopName,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: primaryTextColor,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.vendorId,
                              style: TextStyle(fontSize: 12.5, color: secondaryTextColor),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Text(
                                  _vendorEmail.isNotEmpty ? _vendorEmail : '${widget.vendorId}@printpulse.app',
                                  style: TextStyle(fontSize: 11.5, color: secondaryTextColor),
                                ),
                                if (_vendorPhone.isNotEmpty) ...[
                                  Text(' • ', style: TextStyle(fontSize: 11.5, color: secondaryTextColor)),
                                  Text(
                                    _vendorPhone,
                                    style: TextStyle(fontSize: 11.5, color: secondaryTextColor),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Divider(
                    height: 1,
                    thickness: 1,
                    color: Color(0x1A7C3AED),
                  ),
                  const SizedBox(height: 14),
                  // Shop Status Toggle: Open for Orders vs Closed
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Shop Status',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: primaryTextColor,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _shopIsOpen ? 'Open for walk-in & online orders' : 'Closed for new print orders',
                            style: TextStyle(fontSize: 11.5, color: secondaryTextColor),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: (_shopIsOpen ? AppColors.successGreen : AppColors.warningOrange).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(9999),
                              border: Border.all(
                                color: (_shopIsOpen ? AppColors.successGreen : AppColors.warningOrange).withValues(alpha: 0.3),
                              ),
                            ),
                            child: Text(
                              _shopIsOpen ? 'OPEN' : 'CLOSED',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: _shopIsOpen ? AppColors.successGreen : AppColors.warningOrange,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Switch.adaptive(
                            value: _shopIsOpen,
                            activeThumbColor: AppColors.successGreen,
                            onChanged: _toggleShopStatus,
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Divider(
                    height: 1,
                    thickness: 1,
                    color: Color(0x1A7C3AED),
                  ),
                  const SizedBox(height: 14),
                  // Customer Shop Portal URL with copy button
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Customer Web Portal',
                              style: TextStyle(fontSize: 11.5, color: secondaryTextColor),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _resolvedShopUrl,
                              style: const TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                                color: AppColors.primaryPurple,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy_rounded, size: 18, color: AppColors.primaryPurple),
                        tooltip: 'Copy URL',
                        onPressed: () {
                          Clipboard.setData(ClipboardData(
                            text: _resolvedShopUrl,
                          ));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: const Text('Portal URL copied to clipboard'),
                              backgroundColor: AppColors.primaryPurple,
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1, end: 0),

            const SizedBox(height: 20),

            // UPI ID Settlement Management Card
            GlassContainer(
              borderRadius: 24,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: AppColors.successGreen.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.account_balance_wallet_rounded,
                              size: 20,
                              color: AppColors.successGreen,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'UPI ID Management',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: primaryTextColor,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Direct Bank Settlement (0% Fee)',
                                style: TextStyle(fontSize: 12, color: secondaryTextColor),
                              ),
                            ],
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.successGreen.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(9999),
                          border: Border.all(
                            color: AppColors.successGreen.withValues(alpha: 0.3),
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.verified_rounded, size: 12, color: AppColors.successGreen),
                            SizedBox(width: 4),
                            Text(
                              'Active',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: AppColors.successGreen,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: palette.subtlePillBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: palette.subtlePillBorder,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Linked VPA',
                                style: TextStyle(fontSize: 11.5, color: secondaryTextColor),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _vendorUpiId,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.successGreen,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: _showEditUpiDialog,
                          icon: const Icon(Icons.edit_rounded, size: 14),
                          label: const Text('Edit UPI ID'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryPurple,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(duration: 400.ms, delay: 50.ms).slideY(begin: 0.1, end: 0),

            const SizedBox(height: 20),

            // Printer & Print Preferences Card
            GlassContainer(
              borderRadius: 24,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppColors.primaryPurple.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.print_rounded,
                          size: 20,
                          color: AppColors.primaryPurple,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Printer & Spool Preferences',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: primaryTextColor,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Hardware & Format Output',
                            style: TextStyle(fontSize: 12, color: secondaryTextColor),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Default Printer Status
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Default Printer Status',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: primaryTextColor),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _defaultPrinter,
                              style: TextStyle(fontSize: 12, color: secondaryTextColor),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.successGreen.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(9999),
                          border: Border.all(
                            color: AppColors.successGreen.withValues(alpha: 0.3),
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle_rounded, size: 12, color: AppColors.successGreen),
                            SizedBox(width: 4),
                            Text(
                              'Ready',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: AppColors.successGreen,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1, thickness: 1, color: Color(0x1A7C3AED)),
                  const SizedBox(height: 12),
                  // Default Paper Size
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Default Paper Size',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: primaryTextColor),
                      ),
                      Text(
                        _paperSize,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryPurple,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1, thickness: 1, color: Color(0x1A7C3AED)),
                  const SizedBox(height: 12),
                  // Auto Spool Toggle
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Auto-Spool Verified Jobs',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: primaryTextColor),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Automatically dispatch PDF to Android print spooler upon verification',
                              style: TextStyle(fontSize: 11.5, color: secondaryTextColor),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Switch.adaptive(
                        value: _autoSpool,
                        activeThumbColor: AppColors.primaryPurple,
                        onChanged: _toggleAutoSpool,
                      ),
                    ],
                  ),
                ],
              ),
            ).animate().fadeIn(duration: 400.ms, delay: 100.ms).slideY(begin: 0.1, end: 0),

            const SizedBox(height: 20),

            // Theme Selector Card
            ListenableBuilder(
              listenable: globalThemeController,
              builder: (context, _) {
                final currentMode = globalThemeController.themeMode;

                return GlassContainer(
                  borderRadius: 24,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.palette_outlined, size: 20, color: AppColors.primaryPurple),
                          const SizedBox(width: 10),
                          Text(
                            'Theme & Appearance',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: primaryTextColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      // 3-way Segmented Buttons (Light, Dark, System)
                      Row(
                        children: [
                          Expanded(
                            child: _buildThemeSegmentOption(
                              label: 'Light',
                              icon: Icons.light_mode_rounded,
                              isSelected: currentMode == ThemeMode.light,
                              onTap: () {
                                HapticFeedback.selectionClick();
                                globalThemeController.setThemeMode(ThemeMode.light);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildThemeSegmentOption(
                              label: 'Dark',
                              icon: Icons.dark_mode_rounded,
                              isSelected: currentMode == ThemeMode.dark,
                              onTap: () {
                                HapticFeedback.selectionClick();
                                globalThemeController.setThemeMode(ThemeMode.dark);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildThemeSegmentOption(
                              label: 'System',
                              icon: Icons.brightness_auto_rounded,
                              isSelected: currentMode == ThemeMode.system,
                              onTap: () {
                                HapticFeedback.selectionClick();
                                globalThemeController.setThemeMode(ThemeMode.system);
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ).animate().fadeIn(duration: 400.ms, delay: 150.ms).slideY(begin: 0.1, end: 0),

            const SizedBox(height: 20),

            // Print Pricing (INR) Configuration Card
            PrintPricingCard(
              vendorId: widget.vendorId,
              httpClient: widget.testHttpClient,
            ).animate().fadeIn(duration: 400.ms, delay: 200.ms).slideY(begin: 0.1, end: 0),

            const SizedBox(height: 20),

            // App Info & Support Card
            Container(
              decoration: BoxDecoration(
                color: palette.cardSurface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: palette.devCardBorder,
                  width: 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: palette.cardPurpleShadow,
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                  BoxShadow(
                    color: palette.cardDarkShadow,
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                      splashColor: const Color(0xFF7C3AED).withValues(alpha: 0.12),
                      highlightColor: const Color(0xFF7C3AED).withValues(alpha: 0.06),
                      onTap: () => _launchDeveloperUrl(context),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: const Color(0xFF7C3AED).withValues(alpha: 0.12),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.code_rounded,
                                color: Color(0xFF7C3AED),
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'About the Developer',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: primaryTextColor,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Abhay Verma • Portfolio',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: secondaryTextColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Icon(
                              Icons.arrow_outward_rounded,
                              size: 20,
                              color: Color(0xFF7C3AED),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1, thickness: 1, color: Color(0x1A7C3AED)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.primaryPurple),
                            const SizedBox(width: 8),
                            Text(
                              'Version',
                              style: TextStyle(fontSize: 13, color: secondaryTextColor),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: palette.subtlePillBg,
                            borderRadius: BorderRadius.circular(9999),
                            border: Border.all(color: palette.subtlePillBorder),
                          ),
                          child: const Text(
                            'v1.0.0 (Production Release)',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryPurple,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(duration: 400.ms, delay: 250.ms).slideY(begin: 0.1, end: 0),

            const SizedBox(height: 24),

            // Logout Button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _handleSignOut,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.dangerRed,
                side: BorderSide(color: AppColors.dangerRed.withValues(alpha: 0.4)),
                backgroundColor: AppColors.dangerRed.withValues(alpha: 0.06),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9999)),
              ),
              icon: const Icon(Icons.logout_rounded, size: 20),
              label: const Text(
                'Disconnect Kiosk',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ).animate().fadeIn(duration: 400.ms, delay: 300.ms).slideY(begin: 0.1, end: 0),
        ],
      ),
    ),
  );
}

  Widget _buildThemeSegmentOption({
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final targetContentColor = isSelected ? Colors.white : AppColors.primaryPurple;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.primaryPurple
                : AppColors.primaryPurple.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(9999),
            border: Border.all(
              color: isSelected
                  ? AppColors.primaryPurple
                  : AppColors.primaryPurple.withValues(alpha: 0.2),
            ),
          ),
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: targetContentColor),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            builder: (context, animatedColor, _) {
              final resolvedColor = animatedColor ?? targetContentColor;
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: resolvedColor,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: resolvedColor,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // MAIN SCAFFOLD & FLOATING GLASS BOTTOM NAVIGATION
  // -------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: AnimatedBackground(
        child: SafeArea(
          top: true,
          bottom: false,
          child: PageView(
            controller: _pageController,
            physics: const BouncingScrollPhysics(),
            onPageChanged: (index) {
              if (_currentTabIndex != index) {
                HapticFeedback.selectionClick();
                setState(() {
                  _currentTabIndex = index;
                });
                if (index == 2) {
                  _historyScreenKey.currentState?.fetchHistory();
                }
              }
            },
            children: [
              _KeepAliveTab(
                key: const PageStorageKey<String>('dashboard_home_tab'),
                child: _buildHomeTab(context),
              ),
              _KeepAliveTab(
                key: const PageStorageKey<String>('dashboard_queue_tab'),
                child: _buildQueueTab(context),
              ),
              _KeepAliveTab(
                key: const PageStorageKey<String>('dashboard_history_tab'),
                child: HistoryScreen(
                  key: _historyScreenKey,
                  vendorId: widget.vendorId,
                  testHttpClient: widget.testHttpClient,
                  testPrintExecutor: widget.testPrintExecutor,
                  onHistoryCleared: () {
                    setState(() {
                      _totalEarnings = 0.0;
                      _completedJobsCount = 0;
                      _bwPagesPrinted = 0;
                      _colorPagesPrinted = 0;
                      _settledOrderIds.clear();
                    });
                  },
                ),
              ),
              _KeepAliveTab(
                key: const PageStorageKey<String>('dashboard_profile_tab'),
                child: _buildProfileTab(context),
              ),
            ],
          ),
        ),
      ),
      // Apple Music Liquid Glass Capsule Bottom Bar
      bottomNavigationBar: _buildAppleMusicBottomBar(context),
    );
  }

  void _handleDockDragStart() {
    if (!_pageController.hasClients ||
        !_pageController.position.hasViewportDimension) {
      return;
    }
    // Halt any in-flight tab transition so thumb drag takes immediate control.
    _pageController.jumpTo(_pageController.offset);
  }

  void _handleDockDragUpdate(DragUpdateDetails details, double trackWidth) {
    if (trackWidth <= 0 ||
        !_pageController.hasClients ||
        !_pageController.position.hasViewportDimension) {
      return;
    }
    // 1 tab width (trackWidth / 4.0) corresponds to 1.0 page step for 1:1 pill tracking.
    final double deltaPage =
        (details.primaryDelta ?? 0.0) / (trackWidth / 4.0);
    final double newPage = (_currentPageValue + deltaPage).clamp(0.0, 3.0);
    _pageController.jumpTo(
      newPage * _pageController.position.viewportDimension,
    );
  }

  void _snapDockToPage({double velocity = 0.0, int maxIndex = 3}) {
    if (!_pageController.hasClients) return;
    final int targetPage;
    if (velocity.abs() > 280.0) {
      targetPage = velocity > 0
          ? _currentPageValue.ceil()
          : _currentPageValue.floor();
    } else {
      targetPage = _currentPageValue.round();
    }
    _pageController.animateToPage(
      targetPage.clamp(0, maxIndex),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _buildAppleMusicBottomBar(BuildContext context) {
    final palette = PrintPulsePalette.of(context);
    final List<Map<String, dynamic>> tabs = [
      {'icon': Icons.home_rounded, 'label': 'Home'},
      {'icon': Icons.receipt_long_rounded, 'label': 'Queue'},
      {'icon': Icons.history_rounded, 'label': 'History'},
      {'icon': Icons.person_rounded, 'label': 'Profile'},
    ];

    final Color activeColor = palette.navActiveColor;
    final Color inactiveColor = palette.navInactiveColor;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(left: 28, right: 28, bottom: 12),
        child: Container(
          height: 68,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(34),
            boxShadow: [
              BoxShadow(
                color: palette.navTrackShadow,
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(34),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: palette.navTrackColor,
                  borderRadius: BorderRadius.circular(34),
                  border: Border.all(
                    color: palette.navTrackBorder,
                    width: 1.0,
                  ),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final double trackWidth = constraints.maxWidth;
                    return GestureDetector(
                      dragStartBehavior: DragStartBehavior.down,
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (_) => _handleDockDragStart(),
                      onHorizontalDragUpdate: (details) =>
                          _handleDockDragUpdate(details, trackWidth),
                      onHorizontalDragEnd: (details) => _snapDockToPage(
                        velocity: details.primaryVelocity ?? 0.0,
                        maxIndex: tabs.length - 1,
                      ),
                      onHorizontalDragCancel: () =>
                          _snapDockToPage(maxIndex: tabs.length - 1),
                      child: ValueListenableBuilder<double>(
                        valueListenable: _pageValueNotifier,
                        builder: (context, pageValue, _) {
                          // Map page [0.0..(tabs.length - 1)] to alignment [-1.0..1.0].
                          final double alignmentX = tabs.length > 1
                              ? ((pageValue / (tabs.length - 1)) * 2.0 - 1.0)
                                  .clamp(-1.0, 1.0)
                              : 0.0;

                          return Stack(
                            children: [
                              // Real-time Sliding Liquid Glass Active Bubble
                              Align(
                                alignment: Alignment(alignmentX, 0.0),
                                child: FractionallySizedBox(
                                  widthFactor: 1 / tabs.length,
                                  heightFactor: 1.0,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: palette.navPillColor,
                                      borderRadius: BorderRadius.circular(30),
                                      border: Border.all(
                                        color: palette.navPillBorder,
                                        width: 0.8,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: palette.navPillShadow,
                                          blurRadius: 8,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              // Equal Stacked Tab Items
                              Row(
                                children: List.generate(tabs.length, (index) {
                                  final double proximity =
                                      (1.0 - (pageValue - index).abs())
                                          .clamp(0.0, 1.0);
                                  final Color itemColor = Color.lerp(
                                    inactiveColor,
                                    activeColor,
                                    proximity,
                                  )!;
                                  final int activeQueueCount = _activeQueueCount;

                                  return Expanded(
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        if ((_currentPageValue - index).abs() <
                                            0.01) {
                                          HapticFeedback.selectionClick();
                                          return;
                                        }
                                        _pageController.animateToPage(
                                          index,
                                          duration: const Duration(
                                              milliseconds: 320),
                                          curve: Curves.easeOutCubic,
                                        );
                                      },
                                      child: Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Stack(
                                              clipBehavior: Clip.none,
                                              children: [
                                                Icon(
                                                  tabs[index]['icon']
                                                      as IconData,
                                                  size: 25,
                                                  color: itemColor,
                                                ),
                                                Positioned(
                                                  top: -4,
                                                  right: -8,
                                                  child: Visibility(
                                                    visible: index == 1 &&
                                                        activeQueueCount > 0,
                                                    child: Container(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 5,
                                                          vertical: 1.5),
                                                      decoration: BoxDecoration(
                                                        color: activeColor,
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(
                                                                    9999),
                                                      ),
                                                      child: Text(
                                                        '$activeQueueCount',
                                                        style: const TextStyle(
                                                          fontSize: 9,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              tabs[index]['label'] as String,
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: proximity > 0.5
                                                    ? FontWeight.w600
                                                    : FontWeight.w500,
                                                color: itemColor,
                                                letterSpacing: -0.1,
                                                height: 1.1,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ),
                            ],
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Preserves scroll position and state for each tab inside [PageView].
class _KeepAliveTab extends StatefulWidget {
  final Widget child;

  const _KeepAliveTab({
    super.key,
    required this.child,
  });

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin<_KeepAliveTab> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
