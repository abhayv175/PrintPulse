class ApiConfig {
  static const String hostIp = '192.168.1.41';
  static const String baseHost = '$hostIp:8000';
  static const String restBaseUrl = 'http://$baseHost';
  static const String webSocketUrl = 'ws://$baseHost';

  static final RegExp _localIpv4Pattern = RegExp(r'192\.168\.\d+\.\d+');

  /// Returns true when [value] contains a 192.168.x.x IP other than [hostIp].
  static bool hasOutdatedLocalHost(String value) {
    return _localIpv4Pattern
        .allMatches(value)
        .any((match) => match.group(0) != hostIp);
  }

  /// Replaces outdated 192.168.x.x host IP references with [hostIp].
  static String normalizeLegacyHost(String value) {
    if (value.isEmpty || !hasOutdatedLocalHost(value)) return value;
    return value.replaceAll(_localIpv4Pattern, hostIp);
  }

  // Auth Endpoint
  static Uri get authGoogleUri => Uri.parse('$restBaseUrl/api/vendor/auth/google');

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

  // Payment Verification Endpoint (Manual Approval Fallback)
  static Uri verifyPaymentUri(String orderId) =>
      Uri.parse('$restBaseUrl/api/orders/$orderId/verify-payment');

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
