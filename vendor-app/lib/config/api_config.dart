import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'google_auth_config.dart';

class ApiConfig {
  /// Default compiled live cloud backend host, overridable via --dart-define=HOST_IP
  static const String defaultHostIp =
      String.fromEnvironment('HOST_IP', defaultValue: 'jh0yc.aiccloud.online');

  static String _activeHostIp = defaultHostIp;

  /// Active IP address or domain pointing to the backend serving machine.
  static String get hostIp => _activeHostIp;

  /// Updates the active host address at runtime.
  static set hostIp(String ip) {
    final clean = ip.trim();
    if (clean.isNotEmpty) {
      _activeHostIp = clean;
    }
  }

  static String get baseHost {
    final clean = _activeHostIp
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'/.*$'), '');
    if (clean.contains(':')) return clean;
    if (clean.contains('.')) {
      final isIp = RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(clean);
      if (isIp) {
        return '$clean:8000';
      }
      return clean;
    }
    return '$clean:8000';
  }

  static bool get isSecure {
    if (_activeHostIp.startsWith('https://')) return true;
    final hostOnly = baseHost.split(':').first;
    return !RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(hostOnly) &&
        hostOnly != 'localhost' &&
        hostOnly != '127.0.0.1';
  }

  static String get restBaseUrl =>
      isSecure ? 'https://$baseHost' : 'http://$baseHost';
  static String get webSocketUrl =>
      isSecure ? 'wss://$baseHost' : 'ws://$baseHost';

  static final RegExp _localHostPattern =
      RegExp(r'(192\.168\.\d+\.\d+|localhost|127\.0\.0\.1|10\.0\.2\.2)');
  static final RegExp _legacyUrlPrefixPattern =
      RegExp(r'https?://(192\.168\.\d+\.\d+|localhost|127\.0\.0\.1|10\.0\.2\.2)(:\d+)?');
  static final RegExp _legacyHostWithPortPattern =
      RegExp(r'(192\.168\.\d+\.\d+|localhost|127\.0\.0\.1|10\.0\.2\.2)(:\d+)?');

  /// Returns true when [value] contains a local/stale IP or localhost reference other than [hostIp].
  static bool hasOutdatedLocalHost(String value) {
    if (value.isEmpty) return false;
    if (value.contains('192.168.') ||
        value.contains('localhost') ||
        value.contains('127.0.0.1') ||
        value.contains('10.0.2.2')) {
      return true;
    }
    return _localHostPattern
        .allMatches(value)
        .any((match) => match.group(0) != hostIp);
  }

  /// Replaces outdated local/stale host references with the active cloud host.
  static String normalizeLegacyHost(String value) {
    if (value.isEmpty || !hasOutdatedLocalHost(value)) return value;
    var result = value.replaceAll(_legacyUrlPrefixPattern, restBaseUrl);
    result = result.replaceAll(_legacyHostWithPortPattern, baseHost);
    return result;
  }

  /// Performs an autonomous LAN UDP broadcast discovery on port 8002
  /// to locate the active PrintPulse server without manual IP entry.
  static Future<String?> discoverServerIp({
    int timeoutMs = 1500,
    int port = 8002,
  }) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      final completer = Completer<String?>();
      final payload = utf8.encode('PRINT_PULSE_DISCOVER');

      socket.send(payload, InternetAddress('255.255.255.255'), port);

      final sub = socket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket?.receive();
          if (datagram != null) {
            try {
              final raw = utf8.decode(datagram.data);
              final map = jsonDecode(raw);
              if (map is Map && map['service'] == 'printpulse' && map['ip'] != null) {
                final discoveredIp = map['ip'].toString().trim();
                if (discoveredIp.isNotEmpty && !completer.isCompleted) {
                  hostIp = discoveredIp;
                  completer.complete(discoveredIp);
                }
              }
            } catch (_) {}
          }
        }
      });

      Timer(Duration(milliseconds: timeoutMs), () {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      });

      final result = await completer.future;
      await sub.cancel();
      return result;
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }

  static const String _cliGoogleWebClientId =
      String.fromEnvironment('GOOGLE_WEB_CLIENT_ID', defaultValue: '');

  /// Google Web Client ID used as serverClientId for Google Sign-In v7+
  static String get googleWebClientId {
    if (_cliGoogleWebClientId.isNotEmpty) {
      return _cliGoogleWebClientId;
    }
    return GoogleAuthConfig.clientId;
  }

  // Auth Endpoint
  static Uri get authGoogleUri => Uri.parse('$restBaseUrl/api/auth/google');
  static Uri get vendorAuthGoogleUri =>
      Uri.parse('$restBaseUrl/api/vendor/auth/google');

  // Cancel Order Endpoint
  static Uri cancelOrderUri(String orderId) =>
      Uri.parse('$restBaseUrl/api/documents/orders/$orderId/cancel');

  // Pre-processed Print-Ready PDF & Download Endpoints
  static Uri printReadyDocumentUri(String orderId) =>
      Uri.parse('$restBaseUrl/api/documents/$orderId/print-ready');

  static Uri downloadDocumentUri(String orderId) =>
      Uri.parse('$restBaseUrl/api/documents/$orderId/download');

  // Vendor Active Orders List
  static Uri vendorOrdersUri(String vendorId) =>
      Uri.parse('$restBaseUrl/api/orders/vendor/$vendorId');

  // Vendor Completed Orders History
  static Uri vendorHistoryUri(String vendorId) =>
      Uri.parse('$restBaseUrl/api/vendor/$vendorId/history');

  static Uri deleteVendorHistoryUri(String vendorId) =>
      Uri.parse('$restBaseUrl/api/vendor/$vendorId/history');

  static Uri orderHistoryUri({String? vendorId, String? status = 'completed'}) {
    final query = <String, String>{};
    if (status != null && status.isNotEmpty) query['status'] = status;
    if (vendorId != null && vendorId.isNotEmpty) query['vendor_id'] = vendorId;
    final queryString = query.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final suffix = queryString.isNotEmpty ? '?$queryString' : '';
    return Uri.parse('$restBaseUrl/api/orders$suffix');
  }

  // Payment Verification Endpoint (Manual Approval Fallback)
  static Uri verifyPaymentUri(String orderId) =>
      Uri.parse('$restBaseUrl/api/orders/$orderId/verify-payment');

  static Uri rejectOrderPaymentUri(String orderId) =>
      Uri.parse('$restBaseUrl/api/orders/$orderId/reject');

  // Zero-Fee UPI & Job Payment Endpoints
  static Uri jobPaymentInfoUri(String jobId) =>
      Uri.parse('$restBaseUrl/api/jobs/$jobId/payment-info');

  static Uri claimPaidJobUri(String jobId) =>
      Uri.parse('$restBaseUrl/api/jobs/$jobId/claim-paid');

  static Uri verifyJobPaymentUri(String jobId) =>
      Uri.parse('$restBaseUrl/api/jobs/$jobId/verify-payment');

  static Uri patchVendorUpiUri(String vendorId) =>
      Uri.parse('$restBaseUrl/api/vendors/$vendorId/upi');

  static Uri onboardVendorUri(String vendorId) =>
      Uri.parse('$restBaseUrl/api/vendors/$vendorId/onboard');

  // Cash Payment Endpoints
  static Uri selectCashUri(String orderId) =>
      Uri.parse('$restBaseUrl/api/orders/$orderId/select-cash');

  static Uri confirmCashUri(String orderId) =>
      Uri.parse('$restBaseUrl/api/orders/$orderId/confirm-cash');

  // Order Status Lifecycle Update Endpoint
  static Uri updateOrderStatusUri(String orderId) =>
      Uri.parse('$restBaseUrl/api/orders/$orderId/status');

  // Vendor Profile & UPI VPA Endpoints
  static Uri vendorProfileUri(String vendorId) =>
      Uri.parse('$restBaseUrl/api/vendor/$vendorId/profile');

  static Uri updateVendorUpiUri(String vendorId) =>
      Uri.parse('$restBaseUrl/api/vendor/$vendorId/upi');

  // Vendor Pricing & Stats Endpoints
  static Uri vendorPricingUri(String vendorId) =>
      Uri.parse('$restBaseUrl/api/vendor/$vendorId/pricing');

  static Uri vendorStatsUri(String vendorId) =>
      Uri.parse('$restBaseUrl/api/vendor/$vendorId/stats');

  // WebSocket URL for Vendor
  static String vendorWebSocketUrl(String vendorId) =>
      '$webSocketUrl/ws/vendor/$vendorId';

  // Customer Shop Web Portal URL
  static String customerShopUrl(String vendorId) =>
      '$restBaseUrl/shop/$vendorId';
}
