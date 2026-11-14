import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class GlassContainer extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final bool isPill;
  final bool hasBackdropFilter;
  final Color? customSurfaceColor;
  final Color? customBorderColor;
  final List<BoxShadow>? customShadows;
  final VoidCallback? onTap;

  const GlassContainer({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.padding,
    this.margin,
    this.borderRadius = 22.0,
    this.isPill = false,
    this.hasBackdropFilter = false,
    this.customSurfaceColor,
    this.customBorderColor,
    this.customShadows,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = PrintPulsePalette.of(context);
    final radius = isPill ? BorderRadius.circular(9999) : BorderRadius.circular(borderRadius);

    // High performance translucent surface colors lerped smoothly via AnimatedTheme.
    final surfaceColor = customSurfaceColor ?? palette.cardSurface;
    final borderColor = customBorderColor ?? palette.cardBorder;

    final defaultShadows = [
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
    ];

    Widget content = Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        color: hasBackdropFilter ? null : surfaceColor,
        borderRadius: radius,
        border: Border.all(color: borderColor, width: 1.0),
        boxShadow: customShadows ?? defaultShadows,
      ),
      child: hasBackdropFilter
          ? ClipRRect(
              borderRadius: radius,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 25.0, sigmaY: 25.0),
                child: Container(
                  padding: padding,
                  decoration: BoxDecoration(
                    color: surfaceColor,
                    borderRadius: radius,
                  ),
                  child: child,
                ),
              ),
            )
          : Padding(
              padding: padding ?? EdgeInsets.zero,
              child: child,
            ),
    );

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          splashColor: AppColors.primaryPurple.withValues(alpha: 0.12),
          highlightColor: AppColors.primaryPurple.withValues(alpha: 0.06),
          child: content,
        ),
      );
    }

    return content;
  }
}
