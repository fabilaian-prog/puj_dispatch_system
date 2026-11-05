import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTypography {
  static const Color slate900 = Color(0xFF0F172A);
  static const Color slate800 = Color(0xFF1E293B);
  static const Color slate700 = Color(0xFF334155);
  static const Color slate600 = Color(0xFF475569);
  static const Color slate100 = Color(0xFFF1F5F9);

  static TextStyle plateStyle({double fontSize = 12.0}) {
    return TextStyle(
      fontFamily: 'monospace',
      fontWeight: FontWeight.w900,
      fontSize: fontSize,
      letterSpacing: 1.1,
      color: slate900,
    );
  }

  static TextStyle outdoorHeading({double fontSize = 14.0}) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w800,
      color: slate900,
      letterSpacing: -0.2,
    );
  }

  static TextStyle outdoorBody({double fontSize = 11.0, FontWeight fontWeight = FontWeight.w600}) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: slate700,
      height: 1.25,
    );
  }

  static void lightFeedback() {
    HapticFeedback.lightImpact();
  }

  static void selectionFeedback() {
    HapticFeedback.selectionClick();
  }
}