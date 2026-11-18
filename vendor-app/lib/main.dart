import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'config/api_config.dart';
import 'screens/auth_screen.dart';
import 'screens/dashboard_screen.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

/// Global notifiers holding the currently authenticated vendor session.
/// Enables declarative, clean root-level auth transitions with zero orphaned dependents.
final ValueNotifier<String?> activeVendorIdNotifier = ValueNotifier<String?>(null);
final ValueNotifier<String> activeShopUrlNotifier = ValueNotifier<String>('');

/// Global root navigator key to ensure clean modal/route dismissal.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Migrates any stale or empty cached host settings in [prefs] to [ApiConfig.restBaseUrl].
Future<String> loadNormalizedShopUrl(SharedPreferences prefs) async {
  final savedHostIp = prefs.getString('host_ip')?.trim() ?? '';
  if (savedHostIp.isNotEmpty && !ApiConfig.hasOutdatedLocalHost(savedHostIp)) {
    ApiConfig.hostIp = savedHostIp;
  }

  const hostKeys = [
    'host_url',
    'api_host',
    'backend_host',
    'base_host',
    'host_ip',
    'server_host',
  ];
  for (final key in hostKeys) {
    final cachedHost = prefs.getString(key);
    if (cachedHost != null &&
        (cachedHost.trim().isEmpty || ApiConfig.hasOutdatedLocalHost(cachedHost))) {
      await prefs.setString(key, ApiConfig.restBaseUrl);
    }
  }

  final currentHostUrl = prefs.getString('host_url') ?? '';
  if (currentHostUrl.trim().isEmpty || ApiConfig.hasOutdatedLocalHost(currentHostUrl)) {
    await prefs.setString('host_url', ApiConfig.restBaseUrl);
  }

  final vendorId = prefs.getString('vendor_id')?.trim() ?? '';
  final rawShopUrl = prefs.getString('shop_url')?.trim() ?? '';
  if (rawShopUrl.isEmpty) {
    if (vendorId.isNotEmpty) {
      final fallbackShopUrl = ApiConfig.customerShopUrl(vendorId);
      await prefs.setString('shop_url', fallbackShopUrl);
      return fallbackShopUrl;
    }
    return '';
  }

  final normalizedShopUrl = ApiConfig.normalizeLegacyHost(rawShopUrl);
  if (normalizedShopUrl != rawShopUrl) {
    await prefs.setString('shop_url', normalizedShopUrl);
  }
  return normalizedShopUrl;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hide the bottom system gesture/navigation bar while keeping the top status bar visible
  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: [SystemUiOverlay.top],
  );

  // Automatically re-hide the bottom system gesture bar after 2 seconds if temporarily revealed by user swipe
  SystemChrome.setSystemUIChangeCallback((systemOverlaysAreVisible) async {
    if (systemOverlaysAreVisible) {
      await Future.delayed(const Duration(seconds: 2));
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: [SystemUiOverlay.top],
      );
    }
  });

  final prefs = await SharedPreferences.getInstance();
  final savedVendorId = prefs.getString('vendor_id');
  final savedShopUrl = await loadNormalizedShopUrl(prefs);

  activeVendorIdNotifier.value = savedVendorId;
  activeShopUrlNotifier.value = savedShopUrl;

  runApp(PrintPulseVendorApp(
    initialVendorId: savedVendorId,
    initialShopUrl: savedShopUrl,
  ));
}

class PrintPulseVendorApp extends StatelessWidget {
  final String? initialVendorId;
  final String initialShopUrl;

  const PrintPulseVendorApp({
    super.key,
    this.initialVendorId,
    this.initialShopUrl = '',
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([globalThemeController, activeVendorIdNotifier]),
      builder: (context, _) {
        final currentVendorId = activeVendorIdNotifier.value ?? initialVendorId;
        final currentShopUrl = activeShopUrlNotifier.value.isNotEmpty
            ? activeShopUrlNotifier.value
            : initialShopUrl;
        final bool isAuthenticated =
            currentVendorId != null && currentVendorId.isNotEmpty;

        return MaterialApp(
          navigatorKey: rootNavigatorKey,
          title: 'PrintPulse Kiosk',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: globalThemeController.themeMode,
          themeAnimationDuration: AppTheme.themeTransitionDuration,
          themeAnimationCurve: AppTheme.themeTransitionCurve,
          home: isAuthenticated
              ? DashboardScreen(
                  key: ValueKey('dashboard_$currentVendorId'),
                  vendorId: currentVendorId,
                  shopUrl: currentShopUrl,
                )
              : const AuthScreen(key: ValueKey('auth_screen')),
        );
      },
    );
  }
}
