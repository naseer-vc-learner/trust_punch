import 'package:flutter/material.dart';

import '../data/models/models.dart';

const _seed = Color(0xFF1B5E4A);

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: scheme.surfaceTint,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
  );
}

/// One place that maps a verdict to a colour, so "approved green" cannot drift
/// into meaning something else on another screen.
extension StatusPresentation on AttendanceStatus {
  Color color(ColorScheme scheme) => switch (this) {
        AttendanceStatus.approved => const Color(0xFF2E7D32),
        AttendanceStatus.flagged => const Color(0xFFEF6C00),
        AttendanceStatus.rejected => scheme.error,
        AttendanceStatus.pendingSync => scheme.outline,
      };

  IconData get icon => switch (this) {
        AttendanceStatus.approved => Icons.check_circle_outline,
        AttendanceStatus.flagged => Icons.flag_outlined,
        AttendanceStatus.rejected => Icons.cancel_outlined,
        AttendanceStatus.pendingSync => Icons.cloud_upload_outlined,
      };
}
