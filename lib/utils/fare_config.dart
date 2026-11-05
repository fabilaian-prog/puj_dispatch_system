import 'package:cloud_firestore/cloud_firestore.dart';

/// Fare criteria (LTFRB add-on method), editable by the super admin.
/// Stored in Firestore at `settings/fare_rates`.
class FareConfig {
  final double baseFare;
  final double baseFareDiscounted;
  final int baseKm;
  final double perKmFare;
  final double perKmFareDiscounted;

  const FareConfig({
    required this.baseFare,
    required this.baseFareDiscounted,
    required this.baseKm,
    required this.perKmFare,
    required this.perKmFareDiscounted,
  });

  /// Used when nothing has been saved yet (or Firestore is unreachable).
  static const FareConfig defaults = FareConfig(
    baseFare: 14.0,
    baseFareDiscounted: 11.2,
    baseKm: 4,
    perKmFare: 2.0,
    perKmFareDiscounted: 1.6,
  );

  static final DocumentReference<Map<String, dynamic>> docRef =
      FirebaseFirestore.instance.collection('settings').doc('fare_rates');

  static double _d(dynamic v, double fallback) =>
      (v is num && v >= 0) ? v.toDouble() : fallback;

  factory FareConfig.fromMap(Map<String, dynamic>? m) {
    if (m == null) return defaults;
    final km = m['base_km'];
    return FareConfig(
      baseFare: _d(m['base_fare'], defaults.baseFare),
      baseFareDiscounted:
          _d(m['base_fare_discounted'], defaults.baseFareDiscounted),
      baseKm: (km is num && km >= 1) ? km.round() : defaults.baseKm,
      perKmFare: _d(m['per_km_fare'], defaults.perKmFare),
      perKmFareDiscounted:
          _d(m['per_km_fare_discounted'], defaults.perKmFareDiscounted),
    );
  }

  Map<String, dynamic> toMap() => {
        'base_fare': baseFare,
        'base_fare_discounted': baseFareDiscounted,
        'base_km': baseKm,
        'per_km_fare': perKmFare,
        'per_km_fare_discounted': perKmFareDiscounted,
      };

  /// Live stream; falls back to [defaults] if the doc is missing or errors.
  static Stream<FareConfig> stream() => docRef
      .snapshots()
      .map((s) => FareConfig.fromMap(s.data()))
      .handleError((_) {});

  static int billableKm(double meters) {
    final km = (meters / 1000).ceil();
    return km < 1 ? 1 : km;
  }

  /// Rounds up to the next whole peso (epsilon avoids float noise).
  static double roundUpToPeso(double v) => (v - 1e-9).ceilToDouble();

  double regularForKm(int km) {
    final extra = km > baseKm ? km - baseKm : 0;
    return roundUpToPeso(baseFare + extra * perKmFare);
  }

  double discountedForKm(int km) {
    final extra = km > baseKm ? km - baseKm : 0;
    return roundUpToPeso(baseFareDiscounted + extra * perKmFareDiscounted);
  }

  double regularForMeters(double meters) => regularForKm(billableKm(meters));
  double discountedForMeters(double meters) =>
      discountedForKm(billableKm(meters));
}