import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'config/api_config.dart';
import 'screens/auth_screen.dart';
import 'screens/dashboard_screen.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

/// Migrates any stale or empty cached host settings in [prefs] to [ApiConfig.restBaseUrl].
Future<String> loadNormalizedShopUrl(SharedPreferences prefs) async {
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

  final prefs = await SharedPreferences.getInstance();
  final savedVendorId = prefs.getString('vendor_id');
  final savedShopUrl = await loadNormalizedShopUrl(prefs);

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
      listenable: globalThemeController,
      builder: (context, _) {
        return MaterialApp(
          title: 'PrintPulse Kiosk',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: globalThemeController.themeMode,
          themeAnimationDuration: AppTheme.themeTransitionDuration,
          themeAnimationCurve: AppTheme.themeTransitionCurve,
          home: (initialVendorId != null && initialVendorId!.isNotEmpty)
              ? DashboardScreen(
                  vendorId: initialVendorId!,
                  shopUrl: initialShopUrl,
                )
              : const AuthScreen(),
        );
      },
    );
  }
}
