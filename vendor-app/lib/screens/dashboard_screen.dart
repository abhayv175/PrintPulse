import 'dart:async';
import 'dart:convert';
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
import '../models/print_job.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/animated_background.dart';
import '../widgets/glass_container.dart';
import '../services/sound_service.dart';
import 'auth_screen.dart';
import 'home_screen.dart';
import 'profile_screen.dart';
import 'queue_screen.dart';

class DashboardScreen extends StatefulWidget {
  final String vendorId;
  final String shopUrl;
  final Stream<dynamic>? testWebSocketStream;
  final http.Client? testHttpClient;
  final PrintLayoutExecutor? testPrintExecutor;

  const DashboardScreen({
    super.key,
    required this.vendorId,
    required this.shopUrl,
    this.testWebSocketStream,
    this.testHttpClient,
    this.testPrintExecutor,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final GlobalKey _qrCaptureKey = GlobalKey();
  int _currentTabIndex = 0;
  late final PageController _pageController;
  late final ValueNotifier<double> _pageValueNotifier;
  double _currentPageValue = 0.0;

  final List<PrintJob> _orders = [];
  final Set<String> _cancellingOrders = {};
  final Set<String> _verifyingOrders = {};
  final Set<String> _printingOrders = {};
  final Set<String> _settledOrderIds = {};

  int _completedJobsCount = 0;
  double _totalEarnings = 0.0;
  int _bwPagesPrinted = 0;
  int _colorPagesPrinted = 0;
  String _vendorUpiId = 'shop@okaxis';

  WebSocketChannel? _channel;
  StreamSubscription? _channelSub;
  StreamSubscription? _testStreamSub;
  Timer? _reconnectTimer;
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
    _loadVendorUpi();
    _loadInitialOrders();
    _loadVendorStats();
    if (widget.testWebSocketStream != null) {
      _testStreamSub =
          widget.testWebSocketStream!.listen(_handleWebSocketMessage);
    } else {
      _connectWebSocket();
    }

    // Auto-display Counter QR Modal on initial launch
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _showQrModal();
      }
    });
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

  Future<void> _loadInitialOrders() async {
    try {
      final uri = ApiConfig.vendorOrdersUri(widget.vendorId);
      final client = widget.testHttpClient ?? http.Client();
      final res = await client.get(uri).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final dynamic decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['orders'] is List) {
          final List<PrintJob> loaded = (decoded['orders'] as List)
              .map((o) => PrintJob.fromJson(Map<String, dynamic>.from(o)))
              .toList();
          if (mounted && loaded.isNotEmpty) {
            setState(() {
              for (final job in loaded) {
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
              }
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to load initial orders: $e');
    }
  }

  Future<void> _updateVendorUpi(String newUpi) async {
    final trimmed = newUpi.trim();
    if (trimmed.isEmpty || !trimmed.contains('@')) return;
    try {
      final res = await http.post(
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
    SoundService.playOrderChime();
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
      final event = data['event']?.toString() ?? '';

      if (event == 'NEW_PRINT_JOB') {
        final job = PrintJob.fromJson(data);
        if (job.isPaid) {
          _applyPaidSettlement(job);
          return;
        }
        setState(() {
          _orders.removeWhere((o) => o.orderId == job.orderId);
          _orders.insert(0, job);
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.print_rounded, color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'New Order: ${job.orderId} (Awaiting Payment • ₹${job.totalAmount.toStringAsFixed(2)})',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              backgroundColor: AppColors.primaryPurple,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              duration: const Duration(seconds: 4),
            ),
          );
        }
      } else if (event == 'order_paid' || event == 'ORDER_PAID') {
        final Map<String, dynamic> orderMap = data['order'] is Map
            ? Map<String, dynamic>.from(data['order'] as Map)
            : Map<String, dynamic>.from(data);
        orderMap.putIfAbsent('vendor_id', () => widget.vendorId);
        orderMap['status'] = 'paid';
        final paidJob = PrintJob.fromJson(orderMap);
        _applyPaidSettlement(paidJob);
      } else if (event == 'ORDER_CANCELLED') {
        final cancelledId = data['order_id']?.toString();
        if (cancelledId != null) {
          setState(() {
            _orders.removeWhere((o) => o.orderId == cancelledId);
          });
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
    if (!job.isPaid || _printingOrders.contains(job.orderId)) return;

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
        final bool needsCount = _settledOrderIds.add(job.orderId);
        setState(() {
          _orders.removeWhere((o) => o.orderId == job.orderId);
          if (needsCount) {
            _completedJobsCount++;
          }
        });

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
                    'Printing ${job.orderId} (${job.totalPages} pages) • Sent to printer',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor: AppColors.primaryPurple,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _printingOrders.remove(job.orderId);
        });
      }
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
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AuthScreen()),
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
                      const SizedBox(height: 4),
                      Text(
                        'Terminal ID: ${widget.vendorId}',
                        style: TextStyle(
                          fontSize: 13,
                          color: secondaryTextColor,
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

          const SizedBox(height: 12),

          // Daily B&W vs. Color Page Breakdown
          PageBreakdownRow(
            bwPages: _bwPagesPrinted,
            colorPages: _colorPagesPrinted,
          ),
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

  // -------------------------------------------------------------------------
  // TAB 2: QUEUE SECTION (LIVE PRINT ORDERS)
  // -------------------------------------------------------------------------
  Widget _buildQueueTab(BuildContext context) {
    final colors = _resolveThemeColors(context);
    final palette = colors.palette;
    final primaryTextColor = colors.primary;
    final secondaryTextColor = colors.secondary;

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
                        '${_orders.length}',
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
            child: _orders.isEmpty
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
                    itemCount: _orders.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 14),
                    itemBuilder: (context, index) {
                      final job = _orders[index];
                      final isCancelling = _cancellingOrders.contains(job.orderId);
                      final isVerifying = _verifyingOrders.contains(job.orderId);
                      final bool isPaid = job.isPaid;

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
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (isPaid)
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
                                else
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 9, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: AppColors.warningOrange
                                              .withValues(alpha: 0.14),
                                          borderRadius:
                                              BorderRadius.circular(9999),
                                          border: Border.all(
                                            color: AppColors.warningOrange
                                                .withValues(alpha: 0.4),
                                          ),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.lock_clock_rounded,
                                              size: 13,
                                              color: AppColors.warningOrange,
                                            ),
                                            SizedBox(width: 4),
                                            Text(
                                              'Awaiting Payment',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                                color: AppColors.warningOrange,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '₹${job.totalAmount.toStringAsFixed(2)}',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                          color: AppColors.primaryPurple,
                                        ),
                                      ),
                                    ],
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

                            // Action Buttons: Cancel & Print (Locked while unpaid)
                            Row(
                              children: [
                                // Cancel Pill Button
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: isCancelling
                                        ? null
                                        : () => _cancelOrder(job),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppColors.dangerRed,
                                      side: BorderSide(
                                        color: AppColors.dangerRed
                                            .withValues(alpha: 0.4),
                                      ),
                                      backgroundColor: AppColors.dangerRed
                                          .withValues(alpha: 0.06),
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 12),
                                      shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(9999),
                                      ),
                                    ),
                                    child: isCancelling
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                      AppColors.dangerRed),
                                            ),
                                          )
                                        : const Text(
                                            'CANCEL',
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.3,
                                            ),
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // Print Pill Button (Locked until paid)
                                Expanded(
                                  flex: 2,
                                  child: isPaid
                                      ? Container(
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(9999),
                                            gradient: const LinearGradient(
                                              colors: [
                                                AppColors.primaryPurple,
                                                AppColors.activePurple,
                                              ],
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: AppColors.primaryPurple
                                                    .withValues(alpha: 0.35),
                                                blurRadius: 16,
                                                offset: const Offset(0, 4),
                                              ),
                                            ],
                                          ),
                                          child: ElevatedButton.icon(
                                            onPressed: _printingOrders
                                                    .contains(job.orderId)
                                                ? null
                                                : () => _handlePrintOrder(job),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor:
                                                  Colors.transparent,
                                              shadowColor: Colors.transparent,
                                              disabledBackgroundColor:
                                                  Colors.transparent,
                                              disabledForegroundColor:
                                                  Colors.white
                                                      .withValues(alpha: 0.75),
                                              foregroundColor: Colors.white,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      vertical: 12),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(9999),
                                              ),
                                            ),
                                            icon: _printingOrders
                                                    .contains(job.orderId)
                                                ? const SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      valueColor:
                                                          AlwaysStoppedAnimation<
                                                                  Color>(
                                                              Colors.white),
                                                    ),
                                                  )
                                                : const Icon(
                                                    Icons.print_rounded,
                                                    size: 18),
                                            label: Text(
                                              _printingOrders
                                                      .contains(job.orderId)
                                                  ? 'PREPARING...'
                                                  : 'PRINT',
                                              style: const TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w700,
                                                letterSpacing: 0.3,
                                              ),
                                            ),
                                          ),
                                        )
                                      : ElevatedButton.icon(
                                          onPressed: null,
                                          style: ElevatedButton.styleFrom(
                                            disabledBackgroundColor:
                                                palette.subtlePillBg,
                                            disabledForegroundColor:
                                                secondaryTextColor,
                                            elevation: 0,
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 12),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(9999),
                                              side: BorderSide(
                                                color: palette.subtlePillBorder,
                                              ),
                                            ),
                                          ),
                                          icon: const Icon(Icons.lock_rounded,
                                              size: 16),
                                          label: const Text(
                                            'LOCKED',
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.3,
                                            ),
                                          ),
                                        ),
                                ),
                              ],
                            ),
                            if (!isPaid) ...[
                              const SizedBox(height: 10),
                              SizedBox(
                                width: double.infinity,
                                child: TextButton.icon(
                                  onPressed: isVerifying
                                      ? null
                                      : () => _verifyOrderPayment(job),
                                  style: TextButton.styleFrom(
                                    foregroundColor: AppColors.successGreen,
                                    backgroundColor: AppColors.successGreen
                                        .withValues(alpha: 0.1),
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 10),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(9999),
                                      side: BorderSide(
                                        color: AppColors.successGreen
                                            .withValues(alpha: 0.3),
                                      ),
                                    ),
                                  ),
                                  icon: isVerifying
                                      ? const SizedBox(
                                          width: 15,
                                          height: 15,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                    AppColors.successGreen),
                                          ),
                                        )
                                      : const Icon(Icons.check_circle_outline_rounded,
                                          size: 17),
                                  label: const Text(
                                    'Confirm Manual Payment',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ],
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

            // Vendor Account Card
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
                              widget.vendorId,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: primaryTextColor,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Active Kiosk Terminal',
                              style: TextStyle(fontSize: 12.5, color: secondaryTextColor),
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
          ).animate().fadeIn(duration: 400.ms, delay: 100.ms).slideY(begin: 0.1, end: 0),

          const SizedBox(height: 20),

          // Print Pricing (INR) Configuration Card
          PrintPricingCard(
            vendorId: widget.vendorId,
            httpClient: widget.testHttpClient,
          ).animate().fadeIn(duration: 400.ms, delay: 150.ms).slideY(begin: 0.1, end: 0),

          const SizedBox(height: 20),

          // App Configuration Card
          GlassContainer(
            borderRadius: 24,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.dns_rounded, size: 20, color: AppColors.primaryPurple),
                    const SizedBox(width: 10),
                    Text(
                      'Network & Host Configuration',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: primaryTextColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('API Server Host', style: TextStyle(color: secondaryTextColor, fontSize: 13)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: palette.subtlePillBg,
                          borderRadius: BorderRadius.circular(9999),
                        ),
                        child: const Text(
                          ApiConfig.restBaseUrl,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w600,
                            color: AppColors.primaryPurple,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('WebSocket Endpoint', style: TextStyle(color: secondaryTextColor, fontSize: 13)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        ApiConfig.webSocketUrl,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: secondaryTextColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('UPI VPA (Settlement)', style: TextStyle(color: secondaryTextColor, fontSize: 13)),
                    GestureDetector(
                      onTap: _showEditUpiDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.successGreen.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(9999),
                          border: Border.all(
                            color: AppColors.successGreen.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _vendorUpiId,
                              style: const TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w600,
                                color: AppColors.successGreen,
                              ),
                            ),
                            const SizedBox(width: 5),
                            const Icon(
                              Icons.edit_rounded,
                              size: 13,
                              color: AppColors.successGreen,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ).animate().fadeIn(duration: 400.ms, delay: 200.ms).slideY(begin: 0.1, end: 0),

          const SizedBox(height: 20),

          // About the Developer Card
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
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
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
    // 1 tab width (trackWidth / 3.0) corresponds to 1.0 page step for 1:1 pill tracking.
    final double deltaPage =
        (details.primaryDelta ?? 0.0) / (trackWidth / 3.0);
    final double newPage = (_currentPageValue + deltaPage).clamp(0.0, 2.0);
    _pageController.jumpTo(
      newPage * _pageController.position.viewportDimension,
    );
  }

  void _snapDockToPage({double velocity = 0.0, int maxIndex = 2}) {
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
                          // Map page [0.0..2.0] to alignment [-1.0..1.0].
                          final double alignmentX =
                              (pageValue - 1.0).clamp(-1.0, 1.0);

                          return Stack(
                            children: [
                              // Real-time Sliding Liquid Glass Active Bubble
                              Align(
                                alignment: Alignment(alignmentX, 0.0),
                                child: FractionallySizedBox(
                                  widthFactor: 1 / 3,
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
                              // 3 Equal Stacked Tab Items
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
                                  final int badgeCount =
                                      index == 1 ? _orders.length : 0;

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
                                                if (badgeCount > 0)
                                                  Positioned(
                                                    top: -4,
                                                    right: -8,
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
                                                        '$badgeCount',
                                                        style: const TextStyle(
                                                          fontSize: 9,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: Colors.white,
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
