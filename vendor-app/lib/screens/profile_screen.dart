import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_container.dart';

/// PrintPricingCard provides numeric inputs to customize shop per-page B&W and Color rates,
/// synced live with the backend and customer web portal.
class PrintPricingCard extends StatefulWidget {
  final String vendorId;
  final http.Client? httpClient;
  final void Function(double bwRate, double colorRate)? onPricingUpdated;

  const PrintPricingCard({
    super.key,
    required this.vendorId,
    this.httpClient,
    this.onPricingUpdated,
  });

  @override
  State<PrintPricingCard> createState() => _PrintPricingCardState();
}

class _PrintPricingCardState extends State<PrintPricingCard> {
  final TextEditingController _bwController = TextEditingController(text: '2.00');
  final TextEditingController _colorController = TextEditingController(text: '10.00');
  bool _isSaving = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadPricing();
  }

  @override
  void dispose() {
    _bwController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  Future<void> _loadPricing() async {
    setState(() => _isLoading = true);

    // 1. Read cached rates from SharedPreferences first
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedBw = prefs.getDouble('bw_price');
      final cachedColor = prefs.getDouble('color_price');
      if (cachedBw != null && cachedBw > 0 && mounted) {
        _bwController.text = cachedBw.toStringAsFixed(2);
      }
      if (cachedColor != null && cachedColor > 0 && mounted) {
        _colorController.text = cachedColor.toStringAsFixed(2);
      }
    } catch (_) {}

    // 2. Fetch active rates from backend
    final client = widget.httpClient ?? http.Client();
    final bool ownsClient = widget.httpClient == null;
    try {
      final res = await client
          .get(ApiConfig.vendorPricingUri(widget.vendorId))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final bw = (data['bw_price'] as num?)?.toDouble();
        final color = (data['color_price'] as num?)?.toDouble();
        if (bw != null && bw > 0) {
          _bwController.text = bw.toStringAsFixed(2);
        }
        if (color != null && color > 0) {
          _colorController.text = color.toStringAsFixed(2);
        }
        final prefs = await SharedPreferences.getInstance();
        if (bw != null) await prefs.setDouble('bw_price', bw);
        if (color != null) await prefs.setDouble('color_price', color);
      }
    } catch (e) {
      debugPrint('Failed to fetch pricing from backend: $e');
    } finally {
      if (ownsClient) client.close();
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _savePricing() async {
    final double? bw = double.tryParse(_bwController.text.trim());
    final double? color = double.tryParse(_colorController.text.trim());

    if (bw == null || bw <= 0 || color == null || color <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please enter valid positive print rates.'),
          backgroundColor: AppColors.dangerRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);
    final client = widget.httpClient ?? http.Client();
    final bool ownsClient = widget.httpClient == null;

    try {
      final res = await client
          .post(
            ApiConfig.vendorPricingUri(widget.vendorId),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'bw_price': bw, 'color_price': color}),
          )
          .timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble('bw_price', bw);
        await prefs.setDouble('color_price', color);

        if (!mounted) return;
        widget.onPricingUpdated?.call(bw, color);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text('Print rates updated: ₹${bw.toStringAsFixed(2)} B&W • ₹${color.toStringAsFixed(2)} Color'),
              ],
            ),
            backgroundColor: AppColors.successGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update rates (${res.statusCode})'),
            backgroundColor: AppColors.dangerRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving rates: $e'),
            backgroundColor: AppColors.dangerRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (ownsClient) client.close();
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryTextColor = isDark ? Colors.white : AppColors.lightTextPrimary;
    final secondaryTextColor = isDark ? Colors.white70 : const Color(0xFF6B7280);

    return GlassContainer(
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
                  const Icon(Icons.payments_rounded, size: 20, color: AppColors.primaryPurple),
                  const SizedBox(width: 10),
                  Text(
                    'Print Pricing (INR)',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: primaryTextColor,
                    ),
                  ),
                ],
              ),
              if (_isLoading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primaryPurple),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Customize per-page print rates synced live to customer portal.',
            style: TextStyle(fontSize: 12, color: secondaryTextColor),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'B&W Rate (₹ / page)',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: secondaryTextColor),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _bwController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                      ],
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: primaryTextColor,
                        fontFamily: 'monospace',
                      ),
                      decoration: InputDecoration(
                        prefixText: '₹ ',
                        prefixStyle: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.primaryPurple),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        filled: true,
                        fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF9FAFB),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: isDark ? Colors.white.withValues(alpha: 0.12) : const Color(0xFFE5E7EB),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: isDark ? Colors.white.withValues(alpha: 0.12) : const Color(0xFFE5E7EB),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: AppColors.primaryPurple, width: 1.8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Color Rate (₹ / page)',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: secondaryTextColor),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _colorController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                      ],
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: primaryTextColor,
                        fontFamily: 'monospace',
                      ),
                      decoration: InputDecoration(
                        prefixText: '₹ ',
                        prefixStyle: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.primaryPurple),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        filled: true,
                        fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF9FAFB),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: isDark ? Colors.white.withValues(alpha: 0.12) : const Color(0xFFE5E7EB),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: isDark ? Colors.white.withValues(alpha: 0.12) : const Color(0xFFE5E7EB),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: AppColors.primaryPurple, width: 1.8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isSaving ? null : _savePricing,
              icon: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.check_rounded, size: 18),
              label: Text(_isSaving ? 'Updating...' : 'Save Rates'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryPurple,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
