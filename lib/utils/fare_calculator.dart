class FareCalculator {
  static const double baseFareRegular = 14.0;
  static const double baseFareDiscounted = 11.2;
  static const double perKmRegular = 2.0;
  static const double perKmDiscounted = 1.6;
  static const int baseKm = 4;

  static double computeRegular(double meters) {
    final km = (meters / 1000).ceil();
    final billableKm = km < 1 ? 1 : km;
    final extra = billableKm > baseKm ? billableKm - baseKm : 0;
    return (baseFareRegular + (extra * perKmRegular) - 1e-9).ceilToDouble();
  }

  static double computeDiscounted(double meters) {
    final km = (meters / 1000).ceil();
    final billableKm = km < 1 ? 1 : km;
    final extra = billableKm > baseKm ? billableKm - baseKm : 0;
    return (baseFareDiscounted + (extra * perKmDiscounted) - 1e-9).ceilToDouble();
  }

  static String format(double val) => '₱${val.round()}.00';
}