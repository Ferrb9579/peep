import 'package:flutter/material.dart';

abstract final class PeepColors {
  static const primary = Color(0xff087f73);
  static const primarySoft = Color(0xffe5f4ef);
  static const ink = Color(0xff182c34);
  static const muted = Color(0xff65767c);
  static const subtle = Color(0xff829196);
  static const border = Color(0xffe2e8e5);
  static const canvas = Color(0xfff6f8f5);
  static const navy = Color(0xff142d34);
  static const mint = Color(0xffb8ecce);
  static const success = Color(0xff087f73);
  static const warning = Color(0xff9b641c);
  static const danger = Color(0xffba3e43);
}

ThemeData buildPeepTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: PeepColors.primary,
      primary: PeepColors.primary,
      surface: Colors.white,
      error: PeepColors.danger,
    ),
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
  return base.copyWith(
    scaffoldBackgroundColor: PeepColors.canvas,
    dividerColor: PeepColors.border,
    textTheme: base.textTheme
        .apply(bodyColor: PeepColors.ink, displayColor: PeepColors.ink)
        .copyWith(
          headlineLarge: const TextStyle(
            fontSize: 38,
            height: 1.15,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.4,
            color: PeepColors.ink,
          ),
          headlineSmall: const TextStyle(
            fontSize: 28,
            height: 1.2,
            fontWeight: FontWeight.w700,
            letterSpacing: -.8,
            color: PeepColors.ink,
          ),
          titleLarge: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -.3,
            color: PeepColors.ink,
          ),
          bodyMedium: const TextStyle(
            fontSize: 14,
            height: 1.5,
            color: PeepColors.ink,
          ),
          bodySmall: const TextStyle(
            fontSize: 12,
            height: 1.4,
            color: PeepColors.muted,
          ),
        ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: PeepColors.canvas,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: PeepColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: PeepColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: PeepColors.primary, width: 1.5),
      ),
      labelStyle: const TextStyle(color: PeepColors.muted),
      hintStyle: const TextStyle(color: PeepColors.subtle),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 52),
        shape: shape,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
        side: const BorderSide(color: PeepColors.border),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      showDragHandle: true,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: PeepColors.primarySoft,
      height: 76,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? PeepColors.primary
              : PeepColors.muted,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: PeepColors.navy,
      shape: shape,
    ),
  );
}

class PeepBrand extends StatelessWidget {
  const PeepBrand({super.key, this.light = false});
  final bool light;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: light ? PeepColors.mint : PeepColors.primary,
          borderRadius: BorderRadius.circular(13),
        ),
        child: Icon(
          Icons.forum_rounded,
          size: 21,
          color: light ? PeepColors.navy : Colors.white,
        ),
      ),
      const SizedBox(width: 10),
      Text(
        'peep',
        style: TextStyle(
          fontSize: 27,
          fontWeight: FontWeight.w800,
          letterSpacing: -1.2,
          color: light ? Colors.white : PeepColors.ink,
        ),
      ),
    ],
  );
}

class PeepAvatar extends StatelessWidget {
  const PeepAvatar({
    super.key,
    required this.label,
    this.group = false,
    this.radius = 25,
  });
  final String label;
  final bool group;
  final double radius;
  @override
  Widget build(BuildContext context) {
    const palettes = [
      (Color(0xffe2eee6), Color(0xff357157)),
      (Color(0xffeee7dc), Color(0xff8f6741)),
      (Color(0xffe6e9f4), Color(0xff596696)),
      (Color(0xfff3e3e5), Color(0xffa16370)),
    ];
    final hash = label.runes.fold<int>(0, (sum, rune) => sum + rune);
    final (background, foreground) = group
        ? (PeepColors.primarySoft, PeepColors.primary)
        : palettes[hash % palettes.length];
    return CircleAvatar(
      radius: radius,
      backgroundColor: background,
      foregroundColor: foreground,
      child: group
          ? const Icon(Icons.groups_outlined)
          : Text(
              label.isEmpty ? '?' : label.characters.first.toUpperCase(),
              style: TextStyle(
                fontSize: radius * .72,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }
}
