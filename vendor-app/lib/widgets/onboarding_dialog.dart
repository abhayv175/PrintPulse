import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';

/// Modal dialog presented to vendors right after Google Sign-In when onboarding details
/// (shop name, per-page print pricing, and verified UPI ID) are not yet configured.
class OnboardingDialog extends StatefulWidget {
  final String vendorId;
  final String? initialShopName;
  final String? initialVendorName;
  final String? initialUpiId;
  final double? initialBwPrice;
  final double? initialColorPrice;
  final http.Client? testHttpClient;

  const OnboardingDialog({
    super.key,
    required this.vendorId,
    this.initialShopName,
    this.initialVendorName,
    this.initialUpiId,
    this.initialBwPrice,
    this.initialColorPrice,
    this.testHttpClient,
  });

  @override
  State<OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<OnboardingDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _shopNameController;
  late final TextEditingController _bwPriceController;
  late final TextEditingController _colorPriceController;
  late final TextEditingController _upiIdController;

  bool _isSubmitting = false;
  String? _errorMessage;

  static final RegExp _upiRegex =
      RegExp(r'^[a-zA-Z0-9._-]{2,256}@[a-zA-Z0-9.-]{2,64}$');

  @override
  void initState() {
    super.initState();
    final defaultShop = (widget.initialShopName != null && widget.initialShopName!.isNotEmpty)
        ? widget.initialShopName!
        : (widget.initialVendorName != null && widget.initialVendorName!.isNotEmpty)
            ? "${widget.initialVendorName}'s Print Shop"
            : '';
    _shopNameController = TextEditingController(text: defaultShop);
    _bwPriceController = TextEditingController(
      text: (widget.initialBwPrice != null && widget.initialBwPrice! > 0)
          ? widget.initialBwPrice!.toStringAsFixed(2)
          : '2.00',
    );
    _colorPriceController = TextEditingController(
      text: (widget.initialColorPrice != null && widget.initialColorPrice! > 0)
          ? widget.initialColorPrice!.toStringAsFixed(2)
          : '10.00',
    );
    _upiIdController = TextEditingController(
      text: widget.initialUpiId?.isNotEmpty == true ? widget.initialUpiId : '',
    );
  }

  @override
  void dispose() {
    _shopNameController.dispose();
    _bwPriceController.dispose();
    _colorPriceController.dispose();
    _upiIdController.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final String shopName = _shopNameController.text.trim();
    final double bwPrice = double.tryParse(_bwPriceController.text.trim()) ?? 2.0;
    final double colorPrice =
        double.tryParse(_colorPriceController.text.trim()) ?? 10.0;
    final String upiId = _upiIdController.text.trim();

    final client = widget.testHttpClient ?? http.Client();
    final bool ownsClient = widget.testHttpClient == null;

    try {
      final uri = ApiConfig.onboardVendorUri(widget.vendorId);
      final response = await client
          .patch(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'shop_name': shopName,
              'bw_price': bwPrice,
              'color_price': colorPrice,
              'upi_id': upiId,
              'vendor_name': shopName,
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        // Persist onboarding details in local SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('shop_name', shopName);
        await prefs.setString('name', shopName);
        await prefs.setString('vendor_name', shopName);
        await prefs.setDouble('bw_price', bwPrice);
        await prefs.setDouble('color_price', colorPrice);
        await prefs.setString('upi_id', upiId);
        await prefs.setBool('onboarding_completed', true);
        await prefs.setBool('onboarded', true);

        if (!mounted) return;
        Navigator.of(context).pop(true);
      } else {
        String detail = 'Server returned HTTP ${response.statusCode}';
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map && decoded['detail'] != null) {
            detail = decoded['detail'].toString();
          }
        } catch (_) {}
        if (mounted) {
          setState(() {
            _errorMessage = detail;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Network error: ${e.toString()}';
        });
      }
    } finally {
      if (ownsClient) client.close();
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = PrintPulsePalette.of(context);
    final primaryTextColor = isDark ? Colors.white : AppColors.lightTextPrimary;
    final secondaryTextColor =
        isDark ? Colors.white70 : AppColors.lightTextSecondary;

    return PopScope(
      canPop: false, // Blocking onboarding wizard
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            decoration: BoxDecoration(
              color: palette.cardSurface,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: palette.cardBorder,
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: isDark
                      ? Colors.black.withValues(alpha: 0.6)
                      : AppColors.primaryPurple.withValues(alpha: 0.14),
                  blurRadius: 36,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header with Icon
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.primaryPurple.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.storefront_rounded,
                            color: AppColors.primaryPurple,
                            size: 26,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Shop Setup',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.4,
                                  color: primaryTextColor,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Configure rates & instant UPI payout',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: secondaryTextColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),

                    // Error Banner if submission fails
                    if (_errorMessage != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.dangerRed.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.dangerRed.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              size: 18,
                              color: AppColors.dangerRed,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(
                                  color: AppColors.dangerRed,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Shop Name Input
                    Text(
                      'SHOP NAME',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: secondaryTextColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _shopNameController,
                      style: TextStyle(color: primaryTextColor, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: "e.g. Abhay's Xerox & Print",
                        hintStyle: TextStyle(
                            color: secondaryTextColor.withValues(alpha: 0.6)),
                        prefixIcon: const Icon(Icons.store_outlined, size: 20),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      validator: (val) {
                        if (val == null || val.trim().length < 2) {
                          return 'Please enter your shop or business name';
                        }
                        return null;
                      },
                    ),

                    const SizedBox(height: 16),

                    // Per-Page Printing Rates
                    Text(
                      'PRINT PRICING (PER PAGE)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: secondaryTextColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        // B&W Rate
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TextFormField(
                                controller: _bwPriceController,
                                keyboardType: const TextInputType.numberWithOptions(
                                    decimal: true),
                                style: TextStyle(
                                    color: primaryTextColor,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600),
                                decoration: InputDecoration(
                                  labelText: 'B&W Rate',
                                  prefixText: '₹ ',
                                  prefixStyle: TextStyle(
                                    color: primaryTextColor,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 12),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                validator: (val) {
                                  final num? v = double.tryParse(val ?? '');
                                  if (v == null || v <= 0) {
                                    return 'Invalid rate';
                                  }
                                  return null;
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Color Rate
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TextFormField(
                                controller: _colorPriceController,
                                keyboardType: const TextInputType.numberWithOptions(
                                    decimal: true),
                                style: TextStyle(
                                    color: primaryTextColor,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600),
                                decoration: InputDecoration(
                                  labelText: 'Color Rate',
                                  prefixText: '₹ ',
                                  prefixStyle: TextStyle(
                                    color: primaryTextColor,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 12),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                validator: (val) {
                                  final num? v = double.tryParse(val ?? '');
                                  if (v == null || v <= 0) {
                                    return 'Invalid rate';
                                  }
                                  return null;
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // UPI ID Input
                    Text(
                      'UPI ID (ZERO-FEE SETTLEMENT)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: secondaryTextColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _upiIdController,
                      keyboardType: TextInputType.emailAddress,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                      decoration: InputDecoration(
                        hintText: 'e.g. shopkeeper@okicici',
                        hintStyle: TextStyle(
                            color: secondaryTextColor.withValues(alpha: 0.6)),
                        prefixIcon: const Icon(
                            Icons.account_balance_wallet_outlined,
                            size: 20),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'UPI ID is required for direct settlements';
                        }
                        if (!_upiRegex.hasMatch(val.trim())) {
                          return 'Enter valid UPI format (name@bankhandle)';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Customer payments arrive directly in your bank account.',
                      style: TextStyle(
                        fontSize: 11,
                        color: secondaryTextColor.withValues(alpha: 0.7),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Submit Button
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _isSubmitting ? null : _handleSubmit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryPurple,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: _isSubmitting
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  valueColor:
                                      AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              )
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.check_circle_outline_rounded,
                                      size: 19),
                                  SizedBox(width: 8),
                                  Text(
                                    'Save & Launch Kiosk',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
