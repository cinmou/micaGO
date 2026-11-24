import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:provider/provider.dart';

import '../theme_controller.dart';

bool isGlassTheme(BuildContext context) =>
    context.watch<ThemeController>().useLiquidGlass;

/// Whether the current rendering backend supports shader-backed liquid glass
/// (Impeller). Skia (Linux desktop / widget tests) falls back cleanly.
bool get canUseShaderGlass => ui.ImageFilter.isShaderFilterSupported;

Future<void>? _liquidGlassInitFuture;

/// Idempotently warms liquid glass shaders when supported by the backend.
Future<void> ensureLiquidGlassInitialized() {
  if (!canUseShaderGlass) return Future<void>.value();
  return _liquidGlassInitFuture ??= LiquidGlassWidgets.initialize().catchError((
    Object _,
  ) {
    _liquidGlassInitFuture = null;
  });
}

bool _isNeutralInkWash(ColorScheme scheme) =>
    (scheme.brightness == Brightness.light &&
        scheme.primary == const Color(0xFF111111)) ||
    (scheme.brightness == Brightness.dark &&
        scheme.primary == const Color(0xFFFFFFFF));

Color liquidGlassHeaderColor(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final dark = scheme.brightness == Brightness.dark;
  final neutral = _isNeutralInkWash(scheme);
  return Color.alphaBlend(
    scheme.primary.withValues(
      alpha: dark ? (neutral ? 0.03 : 0.12) : (neutral ? 0.02 : 0.08),
    ),
    dark ? const Color(0xFF0D1016) : const Color(0xFFF6F8FC),
  );
}

Color liquidGlassPageColor(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final dark = scheme.brightness == Brightness.dark;
  final neutral = _isNeutralInkWash(scheme);
  return Color.alphaBlend(
    scheme.primary.withValues(
      alpha: dark ? (neutral ? 0.015 : 0.07) : (neutral ? 0.01 : 0.045),
    ),
    dark ? const Color(0xFF080A0F) : const Color(0xFFFAFBFD),
  );
}

BoxDecoration liquidGlassPageDecoration(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final dark = scheme.brightness == Brightness.dark;
  final neutral = _isNeutralInkWash(scheme);
  final base = dark ? const Color(0xFF080A0F) : const Color(0xFFFAFBFD);
  final start = Color.alphaBlend(
    scheme.primary.withValues(
      alpha: dark ? (neutral ? 0.035 : 0.13) : (neutral ? 0.02 : 0.09),
    ),
    base,
  );
  final middle = liquidGlassPageColor(context);
  final end = Color.alphaBlend(
    scheme.primary.withValues(
      alpha: dark ? (neutral ? 0.01 : 0.045) : (neutral ? 0.008 : 0.025),
    ),
    base,
  );
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [start, middle, end],
      stops: const [0.0, 0.52, 1.0],
    ),
  );
}

Color liquidGlassSurfaceColor(BuildContext context, {double alpha = 0.58}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return (dark ? const Color(0xFF1C1C1E) : Colors.white).withValues(
    alpha: alpha,
  );
}

LiquidGlassSettings micaGlassSettings(Color color, {double blur = 9}) =>
    LiquidGlassSettings(
      glassColor: color,
      backerColor: color.withValues(alpha: 0.42),
      blur: blur,
      thickness: 28,
      refractiveIndex: 1.18,
      chromaticAberration: 0.012,
      saturation: 1.35,
      lightIntensity: 0.58,
      standardOpacityMultiplier: 1.0,
    );

/// Lightweight translucent glass container that uses [GlassContainer] on
/// shader-capable backends and falls back to a clean frosted surface with a
/// subtle 1px highlight stroke on Skia / test runtimes.
class MicaGlassSurface extends StatelessWidget {
  final Widget child;
  final Color? color;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final bool useOwnLayer;
  final GlassQuality quality;
  final bool isOval;

  const MicaGlassSurface({
    super.key,
    required this.child,
    this.color,
    this.borderRadius = 28,
    this.padding,
    this.blur = 10,
    this.useOwnLayer = true,
    this.quality = GlassQuality.standard,
    this.isOval = false,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final effectiveColor =
        color ?? liquidGlassSurfaceColor(context, alpha: dark ? 0.62 : 0.72);
    if (canUseShaderGlass) {
      return GlassContainer(
        useOwnLayer: useOwnLayer,
        quality: quality,
        settings: micaGlassSettings(effectiveColor, blur: blur),
        shape: isOval
            ? const LiquidOval()
            : LiquidRoundedSuperellipse(borderRadius: borderRadius),
        padding: padding,
        child: child,
      );
    }
    final borderColor = dark
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.white.withValues(alpha: 0.80);
    final radius = BorderRadius.circular(isOval ? 999 : borderRadius);
    final content = padding == null
        ? child
        : Padding(padding: padding!, child: child);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: effectiveColor,
        borderRadius: radius,
        border: Border.all(color: borderColor, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.24 : 0.08),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: content,
    );
  }
}

class MicaGlassCircleButton extends StatelessWidget {
  final Widget icon;
  final VoidCallback? onPressed;
  final Color? color;
  final Color? iconColor;
  final String? tooltip;
  final double size;
  final bool useOwnLayer;

  const MicaGlassCircleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.color,
    this.iconColor,
    this.tooltip,
    this.size = 52,
    this.useOwnLayer = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effectiveColor =
        color ?? scheme.surfaceContainerHighest.withValues(alpha: 0.56);
    return SizedBox(
      width: size,
      height: size,
      child: MicaGlassSurface(
        isOval: true,
        useOwnLayer: useOwnLayer,
        color: effectiveColor,
        blur: 9,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          color: iconColor ?? scheme.onSurface,
          icon: icon,
        ),
      ),
    );
  }
}
