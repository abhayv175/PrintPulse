import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_config.dart';
import '../main.dart';
import '../services/google_auth_service.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/animated_background.dart';
import '../widgets/onboarding_dialog.dart';
import 'dashboard_screen.dart';

class AuthScreen extends StatefulWidget {
  final http.Client? testHttpClient;

  const AuthScreen({super.key, this.testHttpClient});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 1. Authenticate via GoogleAuthService and obtain Google ID token
      final String idToken = await GoogleAuthService.authenticateAndGetIdToken();

      // 2. Verify Google ID token against FastAPI backend
      final client = widget.testHttpClient ?? http.Client();
      final bool ownsClient = widget.testHttpClient == null;
      http.Response response;
      try {
        response = await client.post(
          ApiConfig.authGoogleUri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'id_token': idToken,
          }),
        ).timeout(const Duration(seconds: 7));
      } finally {
        if (ownsClient) client.close();
      }

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final vendorId = data['vendor_id']?.toString().trim() ?? '';

        if (vendorId.isEmpty) {
          throw Exception('Vendor ID not returned from server');
        }

        final rawShopUrl = data['shop_url']?.toString().trim() ?? '';
        final shopUrl = rawShopUrl.isNotEmpty
            ? rawShopUrl
            : ApiConfig.customerShopUrl(vendorId);

        // Cache vendor credentials & profile in SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('vendor_id', vendorId);
        await prefs.setString('shop_url', shopUrl);
        if (data['email'] != null) {
          await prefs.setString('email', data['email'].toString());
        }
        if (data['name'] != null) {
          await prefs.setString('name', data['name'].toString());
        } else if (data['vendor_name'] != null) {
          await prefs.setString('name', data['vendor_name'].toString());
        }
        if (data['shop_name'] != null) {
          await prefs.setString('shop_name', data['shop_name'].toString());
        }
        if (data['upi_id'] != null && data['upi_id'].toString().isNotEmpty) {
          await prefs.setString('upi_id', data['upi_id'].toString());
        }
        if (data['session_token'] != null) {
          await prefs.setString('session_token', data['session_token'].toString());
        }
        if (data['picture'] != null) {
          await prefs.setString('picture', data['picture'].toString());
        }
        if (data['bw_price'] != null) {
          await prefs.setDouble('bw_price', (data['bw_price'] as num).toDouble());
        }
        if (data['color_price'] != null) {
          await prefs.setDouble('color_price', (data['color_price'] as num).toDouble());
        }

        final bool isFirstTime = prefs.getBool('has_seen_initial_qr') != true;
        await prefs.setBool('has_seen_initial_qr', true);

        final bool isAlreadyOnboarded = (data['onboarded'] == true) ||
            (data['onboarding_completed'] == true) ||
            (prefs.getBool('onboarding_completed') == true);

        if (!mounted) return;

        if (!isAlreadyOnboarded) {
          setState(() {
            _isLoading = false;
          });
          await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => OnboardingDialog(
              vendorId: vendorId,
              initialShopName: data['shop_name']?.toString() ?? '',
              initialVendorName: data['name']?.toString() ?? data['vendor_name']?.toString() ?? '',
              initialUpiId: data['upi_id']?.toString() ?? '',
              initialBwPrice: (data['bw_price'] as num?)?.toDouble() ?? 2.0,
              initialColorPrice: (data['color_price'] as num?)?.toDouble() ?? 10.0,
              testHttpClient: widget.testHttpClient,
            ),
          );
          await prefs.setBool('onboarding_completed', true);
        }

        if (!mounted) return;

        // Dismiss any active SnackBars before route transition
        ScaffoldMessenger.of(context).clearSnackBars();

        // Request notification permission when logging in so real-time order alerts appear
        try {
          await NotificationService.requestPermission();
          NotificationService.subscribeToVendorTopic(vendorId);
        } catch (e) {
          debugPrint('Notification permission request error on login: $e');
        }

        if (!mounted) return;

        // Update top-level auth state declaratively
        activeVendorIdNotifier.value = vendorId;
        activeShopUrlNotifier.value = shopUrl;

        // Cleanly reset root navigator to DashboardScreen with zero orphaned route dependents
        Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => DashboardScreen(
              key: ValueKey('dashboard_$vendorId'),
              vendorId: vendorId,
              shopUrl: shopUrl,
              showQrOnLoad: isFirstTime,
            ),
          ),
          (route) => false,
        );
      } else {
        String errorDetail = 'Authentication failed (${response.statusCode})';
        try {
          final errData = jsonDecode(response.body);
          if (errData is Map && errData['detail'] != null) {
            errorDetail = errData['detail'].toString();
          }
        } catch (_) {}
        setState(() {
          _errorMessage = errorDetail;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorDetail),
            backgroundColor: AppColors.dangerRed,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } on GoogleSignInException catch (e) {
      if (!mounted) return;
      if (e.code == GoogleSignInExceptionCode.canceled) {
        // User closed or dismissed the Google account picker dialog
        debugPrint('Google sign-in canceled by user.');
        setState(() {
          _errorMessage = null;
        });
      } else {
        final desc = e.description ?? e.code.name;
        setState(() {
          _errorMessage = 'Google sign-in error: $desc';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Google Sign-In failed: $desc'),
            backgroundColor: AppColors.dangerRed,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Connection error: ${e.toString()}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to connect to backend: ${e.toString()}'),
          backgroundColor: AppColors.dangerRed,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = PrintPulsePalette.of(context);
    final primaryTextColor = theme.colorScheme.onSurface;

    return Scaffold(
      body: AnimatedBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double minViewportHeight =
                  (constraints.maxHeight - 48.0).clamp(0.0, double.infinity);

              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28.0,
                  vertical: 24.0,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minViewportHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const SizedBox(height: 16),

                        // Center Brand Identity & Pure Pill Action Button
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 380),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Brand Logo Badge (84x84)
                              Container(
                                width: 84,
                                height: 84,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      AppColors.primaryPurple,
                                      AppColors.activePurple,
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(28),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.primaryPurple
                                          .withValues(alpha: 0.35),
                                      blurRadius: 30,
                                      spreadRadius: 2,
                                      offset: const Offset(0, 10),
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.print_rounded,
                                  color: Colors.white,
                                  size: 44,
                                ),
                              )
                                  .animate()
                                  .fadeIn(
                                    delay: 100.ms,
                                    duration: 400.ms,
                                    curve: Curves.easeOutCubic,
                                  )
                                  .scale(
                                    begin: const Offset(0.85, 0.85),
                                    end: const Offset(1.0, 1.0),
                                    delay: 100.ms,
                                    duration: 400.ms,
                                    curve: Curves.easeOutBack,
                                  ),

                              const SizedBox(height: 26),

                              // "PrintPulse" Brand & Subtitle Chip
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'PrintPulse',
                                    style: TextStyle(
                                      fontSize: 34,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.9,
                                      color: primaryTextColor,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: palette.chipBg,
                                      borderRadius: BorderRadius.circular(9999),
                                      border: Border.all(
                                        color: palette.chipBorder,
                                      ),
                                    ),
                                    child: Text(
                                      'Printing made easier',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: palette.chipText,
                                        letterSpacing: 0.2,
                                      ),
                                    ),
                                  ),
                                ],
                              )
                                  .animate()
                                  .fadeIn(
                                    delay: 250.ms,
                                    duration: 350.ms,
                                    curve: Curves.easeOutCubic,
                                  )
                                  .moveY(
                                    begin: 20,
                                    end: 0,
                                    delay: 250.ms,
                                    duration: 350.ms,
                                    curve: Curves.easeOutCubic,
                                  ),

                              const SizedBox(height: 44),

                              // Compact Error Banner if Sign-In Fails
                              if (_errorMessage != null) ...[
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.dangerRed
                                        .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: AppColors.dangerRed
                                          .withValues(alpha: 0.35),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.error_outline_rounded,
                                        color: AppColors.dangerRed,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          _errorMessage!,
                                          style: const TextStyle(
                                            color: AppColors.dangerRed,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 18),
                              ],

                              // Pill-Shaped "Sign in with Google" Action Button
                              SizedBox(
                                width: double.infinity,
                                height: 56,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(9999),
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppColors.primaryPurple
                                            .withValues(alpha: 0.35),
                                        blurRadius: 22,
                                        offset: const Offset(0, 8),
                                      ),
                                    ],
                                  ),
                                  child: ElevatedButton(
                                    onPressed:
                                        _isLoading ? null : _handleGoogleSignIn,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.primaryPurple,
                                      foregroundColor: Colors.white,
                                      disabledBackgroundColor: AppColors
                                          .primaryPurple
                                          .withValues(alpha: 0.6),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 18,
                                      ),
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(9999),
                                      ),
                                    ),
                                    child: _isLoading
                                        ? const SizedBox(
                                            height: 22,
                                            width: 22,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.5,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                Colors.white,
                                              ),
                                            ),
                                          )
                                        : const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              SizedBox(
                                                width: 20,
                                                height: 20,
                                                child: CustomPaint(
                                                  painter:
                                                      _GoogleLogoPainter(),
                                                ),
                                              ),
                                              SizedBox(width: 12),
                                              Flexible(
                                                child: FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  child: Text(
                                                    'Sign in with Google',
                                                    maxLines: 1,
                                                    style: TextStyle(
                                                      fontSize: 16,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: Colors.white,
                                                      letterSpacing: 0.2,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                  ),
                                ),
                              )
                                  .animate()
                                  .fadeIn(
                                    delay: 400.ms,
                                    duration: 350.ms,
                                    curve: Curves.easeOutCubic,
                                  )
                                  .moveY(
                                    begin: 24,
                                    end: 0,
                                    delay: 400.ms,
                                    duration: 400.ms,
                                    curve: Curves.easeOutBack,
                                  )
                                  .scale(
                                    begin: const Offset(0.92, 0.92),
                                    end: const Offset(1.0, 1.0),
                                    delay: 400.ms,
                                    duration: 400.ms,
                                    curve: Curves.easeOutBack,
                                  ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Crisp single-color geometric Google 'G' glyph in white.
class _GoogleLogoPainter extends CustomPainter {
  const _GoogleLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = size.width * 0.45;
    final strokeWidth = size.width * 0.21;
    final arcRadius = outerRadius - strokeWidth / 2;

    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: outerRadius)),
    );

    final arcPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: arcRadius),
      0.0,
      1.74 * math.pi,
      false,
      arcPaint,
    );

    final barPaint = Paint()..color = Colors.white;
    canvas.drawRect(
      Rect.fromLTWH(
        center.dx,
        center.dy - strokeWidth * 0.44,
        outerRadius + 1,
        strokeWidth * 0.90,
      ),
      barPaint,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GoogleLogoPainter oldDelegate) => false;
}
