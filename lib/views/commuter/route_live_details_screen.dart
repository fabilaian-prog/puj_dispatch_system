import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

import 'complaint_screen.dart';
import '../../utils/app_colors.dart';
import '../../utils/app_typography.dart';
import '../../utils/fare_config.dart';
import '../cooperative/route_process_config.dart';

class RouteLiveDetailsScreen extends StatefulWidget {
  final String terminalName;
  final String terminalId;
  final String destination;
  final String subCategory;
  final String dispatchRule;
  final String regularFare;
  final String discountedFare;

  const RouteLiveDetailsScreen({
    super.key,
    required this.terminalName,
    required this.terminalId,
    required this.destination,
    required this.subCategory,
    required this.dispatchRule,
    this.regularFare = '₱20.00',
    this.discountedFare = '₱16.00',
  });

  @override
  State<RouteLiveDetailsScreen> createState() => _RouteLiveDetailsScreenState();
}

class _RouteLiveDetailsScreenState extends State<RouteLiveDetailsScreen>
    with SingleTickerProviderStateMixin {
  static const LatLng _sanPedroCoordinate = LatLng(10.8003, 121.9484);
  static const double _zoomVisibilityThreshold = 13.0;

  final MapController _mapController = MapController();
  final ValueNotifier<bool> _showMarkerTags = ValueNotifier<bool>(true);
  final Distance _distance = const Distance();

  LatLng _startCoordinate = const LatLng(10.755222, 121.934684);
  LatLng _endCoordinate = const LatLng(10.641947, 121.977399);
  List<LatLng> _roadPolylinePoints = const [];
  bool _isLoadingRoad = true;
  bool _showPolyline = true;

  // ── Connectivity ──
  bool _isOffline = false;
  bool _roadFetchFailed = false; // true when the straight-line fallback is shown
  bool _checkingConnection = false;
  int _failedChecks = 0;
  Timer? _connectivityTimer;

  // ── Pinned stop (for ETA) ──
  LatLng? _pinnedStop;
  double? _pinnedAlongMeters; // road distance from route start to the pin
  bool _pinMode = false;

  // Current map zoom, used to scale how forgiving pin taps are.
  double _currentZoom = 12.0;

  // ── Live telemetry (speed smoothing + signal freshness) ──
  static const int _speedWindow = 5;
  final Map<String, List<double>> _speedHistory = {};
  final Map<String, String> _lastSampleKey = {};

  // Driver names rarely change, so cache them to avoid a users read
  // on every live vehicle update.
  final Map<String, String> _driverNameCache = {};

  // ── Guinsang-an approach leg: Dalipe holding group -> Robinsons ──
  // Group 2 units wait at Dalipe without boarding, get called by the
  // Robinsons dispatcher, acknowledge, and drive to Robinsons (the start of
  // the Guinsang-an route). The driver app tags them while they travel.
  // Dalipe 2 (the Atrium area), where the holding group waits.
  static const LatLng _dalipeHubCoordinate = LatLng(10.755222, 121.934684);
  static const LatLng _robinsonsHubCoordinate = LatLng(10.736535, 121.951601);
  static const String _approachTag = 'arriving to robinsons';

  List<LatLng> _approachPolylinePoints = const [];
  bool _showApproach = true;

  List<double> _approachCumulativeMeters = const [0];
  List<LatLng>? _approachCumulativeFor;

  // True for routes with the Dalipe holding group -> Robinsons approach leg
  // (Guinsang-an and Lindero), decided by the route's process type.
  bool get _isGuinsangan =>
      RouteProcesses.of(RouteProcesses.routeIdForDestination(widget.destination))
          ?.hasApproachLeg ??
      false;

  @override
  void initState() {
    super.initState();
    _startCoordinate = _getTerminalCoordinates();
    _endCoordinate = _getDestinationCoordinates();
    _roadPolylinePoints = [_startCoordinate, _endCoordinate];
    _fetchRoadGeometry();
    _fetchApproachGeometry();
    _checkConnectivity();
    _connectivityTimer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => _checkConnectivity(),
    );
    _fareSub = FareConfig.stream().listen((c) {
      if (mounted) setState(() => _fareConfig = c);
    });
    _frameTicker = createTicker(_onFrame)..start();
  }

  @override
  void dispose() {
    _fareSub?.cancel();
    _connectivityTimer?.cancel();
    _frameTicker.dispose();
    _animationFrame.dispose();
    _showMarkerTags.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RouteLiveDetailsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.destination != widget.destination ||
        oldWidget.terminalId != widget.terminalId) {
      _startCoordinate = _getTerminalCoordinates();
      _endCoordinate = _getDestinationCoordinates();
      // Route changed, so the old pin no longer applies.
      _pinnedStop = null;
      _pinnedAlongMeters = null;
      _pinMode = false;
      _fetchRoadGeometry();
      _fetchApproachGeometry();
    }
  }

  LatLng _getTerminalCoordinates() {
    final name = widget.terminalName.toLowerCase();
    final id = widget.terminalId.toUpperCase();

    if (id == 'TERM_ROBINSONS' || name.contains('robinson')) {
      return const LatLng(10.736535, 121.951601);
    }
    if (id == 'TERM_DALIPE_2' || name.contains('dalipe 2') || name.contains('dalipe-2')) {
      return const LatLng(10.755222, 121.934684);
    }
    if (id == 'TERM_DALIPE_1' || id == 'TERM_DALIPE' || name.contains('dalipe')) {
      return const LatLng(10.756903, 121.935679);
    }
    return const LatLng(10.736535, 121.935753);
  }

  LatLng _getDestinationCoordinates() {
    final dest = widget.destination;
    if (dest.contains('Lindero')) return const LatLng(10.5795, 122.0212);
    if (dest.contains('Guinsang-an')) return const LatLng(10.641947, 121.977399);
    if (dest.contains('Sibalom')) return const LatLng(10.7915, 122.0135);
    if (dest.contains('Belison')) return const LatLng(10.8405, 121.9605);
    if (dest.contains('Patnongon')) return const LatLng(10.9145, 121.9960);
    if (dest.contains('Bugasong')) return const LatLng(11.0425, 122.0620);
    if (dest.contains('Anini-y')) return const LatLng(10.4320, 121.9240);
    if (dest.contains('DAO') || dest.contains('Tobias Fornier')) {
      return const LatLng(10.5180, 121.9350);
    }
    if (dest.contains('San Remigio')) return const LatLng(10.8810, 122.0880);
    if (dest.contains('Valderrama')) return const LatLng(11.0018, 122.1294);

    return const LatLng(10.641947, 121.977399);
  }

  bool _shouldRouteViaSanPedro() {
    final termName = widget.terminalName.toLowerCase();
    final termId = widget.terminalId.toUpperCase();
    final dest = widget.destination.toLowerCase();

    final isDalipe = termId.contains('DALIPE') || termName.contains('dalipe');
    if (!isDalipe) return false;

    // Dalipe 2 routes go straight to the destination (no San Pedro leg).
    final isDalipe2 = termId == 'TERM_DALIPE_2' ||
        termName.contains('dalipe 2') ||
        termName.contains('dalipe-2');
    if (isDalipe2) return false;

    final isExcluded = dest.contains('sibalom') || dest.contains('san remigio');
    return !isExcluded;
  }

  Future<void> _fetchRoadGeometry() async {
    setState(() => _isLoadingRoad = true);

    final start = _startCoordinate;
    final end = _endCoordinate;
    final viaSanPedro = _shouldRouteViaSanPedro();

    final String coordinatesString = viaSanPedro
        ? '${start.longitude},${start.latitude};'
          '${_sanPedroCoordinate.longitude},${_sanPedroCoordinate.latitude};'
          '${end.longitude},${end.latitude}'
        : '${start.longitude},${start.latitude};'
          '${end.longitude},${end.latitude}';

    final url = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/'
      '$coordinatesString?overview=full&geometries=geojson',
    );

    try {
      final response =
          await http.get(url).timeout(const Duration(seconds: 12));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List coordinates = data['routes'][0]['geometry']['coordinates'];

        if (mounted) {
          setState(() {
            _roadPolylinePoints = coordinates
                .map((coord) => LatLng(
                      (coord[1] as num).toDouble(),
                      (coord[0] as num).toDouble(),
                    ))
                .toList();
            _isLoadingRoad = false;
            _roadFetchFailed = false;
            if (_pinnedStop != null) {
              _resnapPin();
            }
          });
        }
        return;
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _roadPolylinePoints = viaSanPedro
            ? [_startCoordinate, _sanPedroCoordinate, _endCoordinate]
            : [_startCoordinate, _endCoordinate];
        _isLoadingRoad = false;
        _roadFetchFailed = true;
        if (_pinnedStop != null) {
          _resnapPin();
        }
      });
      _checkConnectivity();
    }
  }

  // ─────────────────────────── Connectivity

  /// Real internet check (a DNS lookup), not just "is Wi-Fi/data on".
  /// Also retries the road geometry once we're back online.
  Future<void> _checkConnectivity() async {
    if (_checkingConnection) return;
    _checkingConnection = true;

    // Plain HTTP request (works on Android, iOS, web and desktop). Any
    // response, even an error status, means the internet is reachable.
    bool online;
    try {
      await http
          .get(Uri.parse(
              'https://router.project-osrm.org/route/v1/driving/121.93,10.75;121.95,10.74?overview=false'))
          .timeout(const Duration(seconds: 5));
      online = true;
      _failedChecks = 0;
    } catch (_) {
      online = false;
      _failedChecks++;
    }
    _checkingConnection = false;
    if (!mounted) return;

    // Only show the banner after 2 failed checks in a row, so one slow
    // request doesn't cause a false "offline".
    final offline = !online && _failedChecks >= 2;
    if (online || offline) {
      if (offline != _isOffline) setState(() => _isOffline = offline);
    }
    if (online && _roadFetchFailed && !_isLoadingRoad) {
      _fetchRoadGeometry();
    }
  }

  // ─────────────────────────── Pin + ETA helpers

  // ─────────────────────────── Pin + route projection helpers

  /// Projects [p] onto the closest point of the route line (not just the
  /// nearest vertex), so pins land exactly where you tap at any zoom level.
  _RouteProjection? _projectOntoRoute(LatLng p, {bool approach = false}) {
    final pts = approach ? _approachPolylinePoints : _roadPolylinePoints;
    if (pts.length < 2) return null;
    final cum = approach ? _approachCumulative : _routeCumulative;

    // Local flat projection with p at the origin (fine at city scale).
    final cosLat = math.cos(p.latitude * math.pi / 180);
    double bestD2 = double.infinity;
    int bestSeg = 0;
    double bestT = 0;

    for (int i = 0; i < pts.length - 1; i++) {
      final ax = (pts[i].longitude - p.longitude) * cosLat;
      final ay = pts[i].latitude - p.latitude;
      final bx = (pts[i + 1].longitude - p.longitude) * cosLat;
      final by = pts[i + 1].latitude - p.latitude;
      final dx = bx - ax;
      final dy = by - ay;
      final len2 = dx * dx + dy * dy;

      double t = len2 == 0 ? 0 : -(ax * dx + ay * dy) / len2;
      t = t.clamp(0.0, 1.0).toDouble();

      final px = ax + dx * t;
      final py = ay + dy * t;
      final d2 = px * px + py * py;

      if (d2 < bestD2) {
        bestD2 = d2;
        bestSeg = i;
        bestT = t;
      }
    }

    final a = pts[bestSeg];
    final b = pts[bestSeg + 1];
    final point = LatLng(
      a.latitude + (b.latitude - a.latitude) * bestT,
      a.longitude + (b.longitude - a.longitude) * bestT,
    );
    final along = cum[bestSeg] + (cum[bestSeg + 1] - cum[bestSeg]) * bestT;

    return _RouteProjection(point, along, _distance(p, point));
  }

  /// Re-projects the existing pin after the route polyline was replaced.
  /// Call inside setState.
  void _resnapPin() {
    if (_pinnedStop == null) return;
    final proj = _projectOntoRoute(_pinnedStop!);
    if (proj == null) return;
    _pinnedStop = proj.point;
    _pinnedAlongMeters = proj.alongMeters;
  }

  /// How far from the line a tap may land: about 48 screen pixels at the
  /// current zoom (so zooming in makes pinning stricter and more precise).
  double _snapToleranceMeters(double latitude) {
    final metersPerPixel = 156543.03392 *
        math.cos(latitude * math.pi / 180) /
        math.pow(2, _currentZoom);
    return math.max(25.0, metersPerPixel * 48);
  }

  void _handleMapTap(LatLng tapped) {
    // Allow taps while placing a pin OR when a pin already exists (to move it).
    if (!(_pinMode || _pinnedStop != null) || _roadPolylinePoints.length < 2) {
      return;
    }

    final proj = _projectOntoRoute(tapped);
    if (proj == null) return;

    if (proj.offRouteMeters > _snapToleranceMeters(tapped.latitude)) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tap closer to the route line to pin a stop.')),
      );
      return;
    }

    final isMove = _pinnedStop != null;
    AppTypography.selectionFeedback();
    setState(() {
      _pinnedStop = proj.point; // exact closest point on the road line
      _pinnedAlongMeters = proj.alongMeters;
      _pinMode = false;
    });

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(isMove
            ? 'Pin moved.'
            : 'Stop pinned. Tap the route again to move it.'),
      ),
    );
  }

  void _clearPin() {
    setState(() {
      _pinnedStop = null;
      _pinnedAlongMeters = null;
      _pinMode = false;
    });
  }

  /// Distance in meters from the vehicle to the pin.
  /// Returns null if there's no pin, -1 if the vehicle already passed it.
  ///
  /// The vehicle is snapped onto the route and the remaining road distance to
  /// the pin is measured from there. If the vehicle is well off the route (for
  /// example still on its way to the terminal), the gap between the vehicle
  /// and the route is added, so it is never reported as "right at the pin"
  /// just because its nearest route point happens to be the start.
  double? _distanceToPinMeters(LatLng vehicle) {
    if (_pinnedAlongMeters == null) return null;
    final proj = _projectOntoRoute(vehicle);
    if (proj == null) return null;

    final ahead = _pinnedAlongMeters! - proj.alongMeters;
    if (ahead < -20) return -1; // 20 m tolerance for GPS noise

    // Ignore normal GPS drift; count the gap only when clearly off the route.
    final offRoute = proj.offRouteMeters > 60 ? proj.offRouteMeters : 0.0;
    return (ahead < 0 ? 0.0 : ahead) + offRoute;
  }

  final Map<String, String> _offRouteKey = {};
  final Map<String, bool> _offRouteVal = {};

  /// True when a vehicle is clearly away from the route line (> 60 m).
  /// Cached per vehicle so the per-frame marker rebuild doesn't re-project.
  bool _isOffRoute(String vehicleId, LatLng p) {
    final key =
        '${p.latitude},${p.longitude},${identityHashCode(_roadPolylinePoints)}';
    if (_offRouteKey[vehicleId] == key) return _offRouteVal[vehicleId] ?? false;
    final proj = _projectOntoRoute(p);
    final off = proj != null && proj.offRouteMeters > 60;
    _offRouteKey[vehicleId] = key;
    _offRouteVal[vehicleId] = off;
    return off;
  }

  String _formatDistance(double meters) =>
      meters >= 1000 ? '${(meters / 1000).toStringAsFixed(1)} km' : '${meters.round()} m';

  // ─────────────────────────── Live telemetry helpers

  /// Stores one speed reading per distinct vehicle update.
  void _recordSpeed(String vehicleId, num speed, String sampleKey) {
    if (_lastSampleKey[vehicleId] == sampleKey) return;
    _lastSampleKey[vehicleId] = sampleKey;
    final history = _speedHistory.putIfAbsent(vehicleId, () => <double>[]);
    history.add(speed.toDouble());
    if (history.length > _speedWindow) history.removeAt(0);
  }

  /// Smoothed speed (moving average of recent moving readings) and its
  /// relative spread, used for the ETA range.
  _SpeedEstimate _estimateSpeed(String vehicleId, num latest) {
    if (latest < 3) return const _SpeedEstimate(0, 0);

    final moving = (_speedHistory[vehicleId] ?? <double>[])
        .where((v) => v >= 3)
        .toList();
    if (moving.isEmpty) moving.add(latest.toDouble());

    final mean = moving.reduce((a, b) => a + b) / moving.length;
    final variance =
        moving.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
            moving.length;
    final spread = (math.sqrt(variance) / mean).clamp(0.10, 0.35).toDouble();

    return _SpeedEstimate(mean, spread);
  }

  String _fmtMinutes(int m) {
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    final r = m % 60;
    return r == 0 ? '${h}h' : '${h}h ${r}m';
  }

  /// ETA as a range based on the smoothed speed, e.g. "4–6 min".
  String _formatEtaRange(double meters, _SpeedEstimate est) {
    if (est.kmh < 3) return 'Vehicle is stopped';

    final fastKmh = est.kmh * (1 + est.spread);
    final slowKmh = est.kmh * (1 - est.spread);
    final minLow = (meters / 1000) / fastKmh * 60;
    final minHigh = (meters / 1000) / slowKmh * 60;

    if (minHigh < 1) return 'Arriving now';

    final low = math.max(1, minLow.round());
    final high = minHigh.round();
    if (low >= high) return '~${_fmtMinutes(high)}';
    if (high < 60) return '$low–$high min';
    return '${_fmtMinutes(low)} – ${_fmtMinutes(high)}';
  }

  // ─────────────────────────── Guinsang-an approach leg (Dalipe -> Robinsons)

  List<double> get _approachCumulative {
    if (!identical(_approachCumulativeFor, _approachPolylinePoints)) {
      final cum = <double>[0];
      for (int i = 1; i < _approachPolylinePoints.length; i++) {
        cum.add(cum.last +
            _distance(_approachPolylinePoints[i - 1], _approachPolylinePoints[i]));
      }
      _approachCumulativeMeters = cum;
      _approachCumulativeFor = _approachPolylinePoints;
    }
    return _approachCumulativeMeters;
  }

  Future<void> _fetchApproachGeometry() async {
    if (!_isGuinsangan) {
      _approachPolylinePoints = const [];
      return;
    }

    // Straight-line fallback until the road geometry arrives.
    _approachPolylinePoints = [_dalipeHubCoordinate, _robinsonsHubCoordinate];

    final a = _dalipeHubCoordinate;
    final b = _robinsonsHubCoordinate;
    final url = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/'
      '${a.longitude},${a.latitude};${b.longitude},${b.latitude}'
      '?overview=full&geometries=geojson',
    );

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List coordinates = data['routes'][0]['geometry']['coordinates'];
        if (mounted) {
          setState(() {
            _approachPolylinePoints = coordinates
                .map((coord) => LatLng(
                      (coord[1] as num).toDouble(),
                      (coord[0] as num).toDouble(),
                    ))
                .toList();
          });
        }
      }
    } catch (_) {}
  }

  /// True for a Guinsang-an unit that acknowledged the Robinsons call and is
  /// driving Dalipe -> Robinsons (not yet scanned in at Robinsons).
  bool _isApproachingData(Map<String, dynamic> data) {
    final status = (data['current_status'] ?? '').toString().toUpperCase();
    if (status != 'EN_ROUTE') return false;

    final tag = (data['transit_tag'] ?? '').toString().toLowerCase();
    final calledAndNotDispatched =
        data['called_by_robinsons'] == true && data['is_dispatched'] != true;
    return tag == _approachTag || calledAndNotDispatched;
  }

  bool _isApproaching(QueryDocumentSnapshot d) =>
      _isGuinsangan && _isApproachingData(d.data() as Map<String, dynamic>);

  /// Remaining road meters from the vehicle to Robinsons along the approach leg.
  double? _distanceToRobinsonsMeters(Map<String, dynamic> data) {
    final loc = data['location'];
    if (loc is! Map || loc['latitude'] == null || loc['longitude'] == null) {
      return null;
    }
    final proj = _projectOntoRoute(
      LatLng(
        (loc['latitude'] as num).toDouble(),
        (loc['longitude'] as num).toDouble(),
      ),
      approach: true,
    );
    if (proj == null) return null;

    final remaining = _approachCumulative.last - proj.alongMeters;
    return remaining < 0 ? 0 : remaining;
  }

  String _approachEtaText(String vehicleId, Map<String, dynamic> data) {
    final meters = _distanceToRobinsonsMeters(data);
    if (meters == null) return 'Locating vehicle…';
    if (meters < 60) return 'Arriving now';
    final speed = (data['speed_kmh'] as num?) ?? 0;
    return _formatEtaRange(meters, _estimateSpeed(vehicleId, speed));
  }

  void _recordVehicleSpeed(String vehicleId, Map<String, dynamic> data) {
    final speed = (data['speed_kmh'] as num?) ?? 0;
    final loc = data['location'];
    final locKey = loc is Map ? '${loc['latitude']},${loc['longitude']}' : '';
    _recordSpeed(vehicleId, speed, '$locKey|$speed');
  }

  // ─────────────────────────── Fare estimate (LTFRB PUJ General Fare Guide)
  //
  // New fare rates effective September 28, 2026 (add-on method):
  //   Regular:                  P14.00 first 4 km, +P2.00 per succeeding km.
  //   Student / Elderly / PWD:  P11.20 first 4 km, +P1.60 per succeeding km.
  // Fares are rounded UP to the next whole peso. Partial km count as a full km.
  // The base add-on rates follow the printed 1-50 km matrix and continue past 50 km.

  // The numbers above are only the defaults. The live values come from
  // Firestore (settings/fare_rates), editable by the super admin.
  FareConfig _fareConfig = FareConfig.defaults;
  StreamSubscription<FareConfig>? _fareSub;

  List<double> _cumulativeMeters = const [0];
  List<LatLng>? _cumulativeFor;

  /// Running road distance (meters) at each polyline point. Rebuilt
  /// automatically whenever the route polyline is replaced.
  List<double> get _routeCumulative {
    if (!identical(_cumulativeFor, _roadPolylinePoints)) {
      final cum = <double>[0];
      for (int i = 1; i < _roadPolylinePoints.length; i++) {
        cum.add(cum.last +
            _distance(_roadPolylinePoints[i - 1], _roadPolylinePoints[i]));
      }
      _cumulativeMeters = cum;
      _cumulativeFor = _roadPolylinePoints;
    }
    return _cumulativeMeters;
  }

  /// Guinsang-an units start from Robinsons but are dispatched from Dalipe 2,
  /// so the Dalipe 2 -> Robinsons leg is added to every fare distance.
  /// Zero for any route that already starts at Dalipe 2.
  double get _fareOffsetMeters {
    if (!_isGuinsangan) return 0;
    if (_distance(_startCoordinate, _dalipeHubCoordinate) <= 150) return 0;
    final cum = _approachCumulative;
    return cum.isEmpty ? 0 : cum.last;
  }

  bool get _fareIncludesDalipeLeg => _fareOffsetMeters > 0;

  int _billableKm(double meters) {
    final km = (meters / 1000).ceil();
    return km < 1 ? 1 : km;
  }

  /// Rounds up to the next whole peso (no centavos). The tiny epsilon stops
  /// floating-point noise (e.g. 19.000000000000004) from bumping a fare up.
  double _roundUpToPeso(double v) => (v - 1e-9).ceilToDouble();

  double _regularFareForMeters(double meters) =>
      _fareConfig.regularForKm(_billableKm(meters));

  double _discountedFareForMeters(double meters) =>
      _fareConfig.discountedForKm(_billableKm(meters));

  String _formatPeso(double amount) => '₱${amount.round()}.00';

  // ─────────────────────────── Firestore / data helpers

  String _getQueueDocId() {
    final routeSuffix = RouteProcesses.routeIdForDestination(widget.destination)
        .replaceFirst('ROUTE_', '');
    return '${widget.terminalId}_$routeSuffix';
  }

  String _mapDestinationToRouteId(String dest) =>
      RouteProcesses.routeIdForDestination(dest);

  Color _resolveVehicleDotColor(String? colorStr) {
    if (colorStr == null || colorStr.trim().isEmpty) {
      return const Color(0xFF10B981);
    }
    final c = colorStr.toLowerCase();
    if (c.contains('red') || c.contains('crimson')) return const Color(0xFFEF4444);
    if (c.contains('blue') || c.contains('navy')) return const Color(0xFF2563EB);
    if (c.contains('green')) return const Color(0xFF10B981);
    if (c.contains('yellow') || c.contains('gold')) return const Color(0xFFF59E0B);
    if (c.contains('orange')) return const Color(0xFFF97316);
    if (c.contains('purple') || c.contains('violet')) return const Color(0xFF8B5CF6);
    if (c.contains('pink')) return const Color(0xFFEC4899);
    if (c.contains('silver') || c.contains('gray') || c.contains('grey')) return const Color(0xFF64748B);
    if (c.contains('white')) return const Color(0xFF0F172A);
    return const Color(0xFF10B981);
  }

  Future<Map<String, dynamic>?> _fetchVehicleData(
    String vehicleId, [
    Map<String, dynamic>? baseData,
  ]) async {
    try {
      Map<String, dynamic>? vData = baseData != null
          ? Map<String, dynamic>.from(baseData)
          : null;

      if (vData == null) {
        final doc = await FirebaseFirestore.instance
            .collection('vehicles_live')
            .doc(vehicleId)
            .get();
        if (doc.exists && doc.data() != null) {
          vData = Map<String, dynamic>.from(doc.data()!);
        }
      }

      if (vData == null) return null;

      final driverName = await _resolveDriverName(vData['driver_id']);
      if (driverName != null) {
        vData['driver_name'] = driverName;
      }

      return vData;
    } catch (_) {}
    return null;
  }

  Future<String?> _resolveDriverName(dynamic driverId) async {
    final id = driverId?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    if (_driverNameCache.containsKey(id)) return _driverNameCache[id];

    try {
      final userDoc =
          await FirebaseFirestore.instance.collection('users').doc(id).get();
      final name = (userDoc.data()?['full_name'] ?? id).toString();
      _driverNameCache[id] = name;
      return name;
    } catch (_) {
      // Passengers are not signed in, so the users collection is private.
      // Fall back to the driver_name already stored on the vehicle.
      return null;
    }
  }

  // Screen-size scale factor. Uses the shortest side so phones in landscape
  // keep readable (not oversized) text, while tablets grow up to 1.25x.
  double get _s {
    final shortest = MediaQuery.sizeOf(context).shortestSide;
    return (shortest / 390.0).clamp(0.92, 1.25);
  }

  // High-contrast, Monospace Philippine Plate Badge Styler
  Widget _buildLicensePlateBadge(String plateNumber, {double fontSize = 13.5}) {
    final s = _s;
    final cleanPlate = plateNumber.replaceAll('_', ' ').toUpperCase();

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 3 * s),
      decoration: BoxDecoration(
        color: AppTypography.slate100,
        borderRadius: BorderRadius.circular(5 * s),
        border: Border.all(color: const Color(0xFFCBD5E1), width: 1.0),
      ),
      child: Text(
        cleanPlate,
        style: AppTypography.plateStyle(fontSize: fontSize * s),
      ),
    );
  }

  Widget _buildCapacityBadge(int current, int max) {
    final s = _s;
    final isFull = current >= max && max > 0;
    final isAlmostFull = max > 0 && current >= (max * 0.8);
    final color = isFull
        ? AppColors.errorCrimson
        : isAlmostFull
            ? const Color(0xFFD97706)
            : const Color(0xFF047857);
    final bgColor = isFull
        ? const Color(0xFFFEF2F2)
        : isAlmostFull
            ? const Color(0xFFFFFBEB)
            : const Color(0xFFECFDF5);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 3 * s),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6 * s),
        border: Border.all(color: color.withOpacity(0.35), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.airline_seat_recline_normal_rounded, size: 15 * s, color: color),
          SizedBox(width: 3 * s),
          Text(
            '$current/$max',
            style: TextStyle(fontSize: 12.5 * s, fontWeight: FontWeight.w800, color: color),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveBadge() {
    final s = _s;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6 * s, vertical: 2 * s),
      decoration: BoxDecoration(
        color: const Color(0xFFECFDF5),
        borderRadius: BorderRadius.circular(6 * s),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6 * s,
            height: 6 * s,
            decoration: const BoxDecoration(color: Color(0xFF059669), shape: BoxShape.circle),
          ),
          SizedBox(width: 4 * s),
          Text(
            'LIVE',
            style: TextStyle(
              fontSize: 10 * s,
              fontWeight: FontWeight.w900,
              color: const Color(0xFF059669),
            ),
          ),
        ],
      ),
    );
  }

  // "ETA to Pin" + "Distance to Pin" rows for the vehicle modal.
  Widget _buildPinEtaRows(
    Map<String, dynamic> data,
    String vehicleId,
    num speed,
    double s,
  ) {
    if (_pinnedStop == null) return const SizedBox.shrink();

    final loc = data['location'] as Map<String, dynamic>?;
    if (loc == null || loc['latitude'] == null || loc['longitude'] == null) {
      return const SizedBox.shrink();
    }

    final vehiclePos = LatLng(
      (loc['latitude'] as num).toDouble(),
      (loc['longitude'] as num).toDouble(),
    );
    final meters = _distanceToPinMeters(vehiclePos);
    if (meters == null) return const SizedBox.shrink();

    final passed = meters < 0;
    final offRoute = _isOffRoute(vehicleId, vehiclePos);

    return Padding(
      padding: EdgeInsets.only(top: 7 * s),
      child: Column(
        children: [
          if (offRoute) ...[
            _buildDetailRow(
              Icons.link_off_rounded,
              'Status',
              'Not on route yet',
              valueColor: const Color(0xFFD97706),
            ),
            SizedBox(height: 7 * s),
          ],
          _buildDetailRow(
            Icons.push_pin_rounded,
            'ETA to Pin',
            passed
                ? 'Already passed your stop'
                : _formatEtaRange(meters, _estimateSpeed(vehicleId, speed)),
            valueColor: passed ? AppColors.errorCrimson : const Color(0xFF1D4ED8),
          ),
          if (!passed) ...[
            SizedBox(height: 7 * s),
            _buildDetailRow(
              Icons.straighten_rounded,
              'Distance to Pin',
              _formatDistance(meters),
            ),
          ],
        ],
      ),
    );
  }

  void _showVehicleDetailsModal({
    required BuildContext context,
    required String vehicleId,
    required bool showSpeed,
    Map<String, dynamic>? initialData,
  }) {
    AppTypography.selectionFeedback();
    final s = _s;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => SafeArea(
        child: Dialog(
          backgroundColor: Colors.white,
          elevation: 6,
          insetPadding: EdgeInsets.symmetric(horizontal: 20 * s, vertical: 24 * s),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18 * s)),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 440 * s),
            child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('vehicles_live')
                  .doc(vehicleId)
                  .snapshots(),
              builder: (context, snapshot) {
                // Prefer fresh stream data; fall back to what the tap passed in.
                final data = snapshot.data?.data() ?? initialData;

                if (data == null) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Padding(
                      padding: EdgeInsets.all(36.0 * s),
                      child: const Center(
                        child: CircularProgressIndicator(color: AppColors.commuterTeal),
                      ),
                    );
                  }
                  return Padding(
                    padding: EdgeInsets.all(20 * s),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildLicensePlateBadge(vehicleId, fontSize: 16),
                        SizedBox(height: 12 * s),
                        Text(
                          'Live telemetry synchronizing with hardware modem.',
                          textAlign: TextAlign.center,
                          style: AppTypography.outdoorBody(fontSize: 14 * s),
                        ),
                      ],
                    ),
                  );
                }

                final plate = data['plate_number'] ?? data['jeepney_id'] ?? vehicleId;
                final jeepName = data['vehicle_name'] ?? plate;
                final vehicleColor = data['vehicle_color'] ?? 'Standard';
                final maxCapacity = data['max_capacity'] ?? 20;
                final passengerCount = data['passenger_count'] ?? 0;
                final status = (data['current_status'] ?? 'STANDBY').toString().replaceAll('_', ' ');
                final speed = (data['speed_kmh'] as num?) ?? 0;
                final isEnRoute = status == 'EN ROUTE';

                final driverId = data['driver_id']?.toString().trim() ?? '';
                final cachedDriver = _driverNameCache[driverId];

                // Record one speed reading per distinct vehicle update.
                final loc = data['location'];
                final locKey = loc is Map ? '${loc['latitude']},${loc['longitude']}' : '';
                _recordSpeed(vehicleId, speed, '$locKey|$speed');

                return SingleChildScrollView(
                  padding: EdgeInsets.all(18 * s),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: EdgeInsets.all(8 * s),
                            decoration: BoxDecoration(
                              color: isEnRoute ? const Color(0xFFECFDF5) : const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(10 * s),
                            ),
                            child: Icon(
                              Icons.directions_bus_rounded,
                              color: isEnRoute ? const Color(0xFF059669) : const Color(0xFF2563EB),
                              size: 24 * s,
                            ),
                          ),
                          SizedBox(width: 10 * s),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        jeepName.toString(),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppTypography.outdoorHeading(fontSize: 18 * s),
                                      ),
                                    ),
                                    if (isEnRoute) ...[
                                      SizedBox(width: 6 * s),
                                      _buildLiveBadge(),
                                    ],
                                  ],
                                ),
                                Text(
                                  'Route: ${widget.destination}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.outdoorBody(fontSize: 12.5 * s, fontWeight: FontWeight.normal),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(width: 6 * s),
                          _buildLicensePlateBadge(plate.toString(), fontSize: 14),
                        ],
                      ),
                      Divider(height: 20 * s, color: AppColors.borderSubtle),

                      // Driver name: served from cache once resolved.
                      if (cachedDriver != null)
                        _buildDetailRow(Icons.person_rounded, 'Driver', cachedDriver)
                      else
                        FutureBuilder<String?>(
                          future: _resolveDriverName(driverId),
                          builder: (context, driverSnap) {
                            final name = driverSnap.data ??
                                data['driver_name'] ??
                                (driverId.isNotEmpty ? driverId : 'Assigned Driver');
                            return _buildDetailRow(Icons.person_rounded, 'Driver', name.toString());
                          },
                        ),
                      SizedBox(height: 7 * s),
                      _buildDetailRow(Icons.palette_outlined, 'Body Color', vehicleColor.toString()),
                      SizedBox(height: 7 * s),
                      _buildDetailRow(
                        Icons.airline_seat_recline_normal_rounded,
                        'Passenger Load',
                        '$passengerCount / $maxCapacity Seats',
                        valueColor: passengerCount >= maxCapacity ? AppColors.errorCrimson : const Color(0xFF047857),
                      ),
                      if (showSpeed) ...[
                        SizedBox(height: 7 * s),
                        _buildDetailRow(Icons.speed_rounded, 'Hardware Speed', '$speed km/h',
                            valueColor: const Color(0xFF047857)),
                      ],

                      if (_isGuinsangan && _isApproachingData(data))
                          _buildApproachEtaRows(data, vehicleId, s)
                        else
                          _buildPinEtaRows(data, vehicleId, speed, s),

                      SizedBox(height: 16 * s),

                      SizedBox(
                        height: 46 * s,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryNavy,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10 * s)),
                            elevation: 0,
                          ),
                          onPressed: () {
                            AppTypography.lightFeedback();
                            Navigator.pop(dialogCtx);
                          },
                          child: Text('Close Details',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15 * s)),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value, {Color? valueColor}) {
    final s = _s;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 10 * s),
      decoration: BoxDecoration(
        color: AppColors.backgroundSlate,
        borderRadius: BorderRadius.circular(10 * s),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18 * s, color: AppColors.primaryNavy),
          SizedBox(width: 8 * s),
          Text(label, style: AppTypography.outdoorBody(fontSize: 13.5 * s, fontWeight: FontWeight.normal)),
          SizedBox(width: 10 * s),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14 * s,
                fontWeight: FontWeight.bold,
                color: valueColor ?? AppTypography.slate900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTerminalStatusBanner(bool hasActiveQueue) {
    final s = _s;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 10 * s),
      decoration: BoxDecoration(
        color: hasActiveQueue ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(12 * s),
        border: Border.all(
          color: hasActiveQueue ? const Color(0xFF86EFAC) : const Color(0xFFFECACA),
          width: 1.0,
        ),
      ),
      child: Row(
        children: [
          Icon(
            hasActiveQueue ? Icons.check_circle_rounded : Icons.info_outline_rounded,
            color: hasActiveQueue ? const Color(0xFF059669) : AppColors.errorCrimson,
            size: 20 * s,
          ),
          SizedBox(width: 8 * s),
          Expanded(
            child: Text(
              hasActiveQueue
                  ? 'TERMINAL BAY ACTIVE • Dispatcher Live'
                  : 'STANDBY • Waiting for Next Line-Up',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: hasActiveQueue ? const Color(0xFF065F46) : const Color(0xFF991B1B),
                fontWeight: FontWeight.w800,
                fontSize: 13 * s,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpot1LoadingCard(Map<String, dynamic>? queueData) {
    final s = _s;
    final activeVehicle = queueData?['active_loading_vehicle'] ?? 'None';
    final hasActive = activeVehicle != 'None' && activeVehicle != 'null' && activeVehicle != null;

    return Container(
      padding: EdgeInsets.all(12 * s),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14 * s),
        border: Border.all(color: const Color(0xFF059669).withOpacity(0.35), width: 1.1),
        boxShadow: const [BoxShadow(color: Color(0x08000000), blurRadius: 4, offset: Offset(0, 1.5))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.directions_bus_filled_rounded, color: const Color(0xFF059669), size: 20 * s),
              SizedBox(width: 7 * s),
              Expanded(
                child: Text(
                  'Loading Bay (Spot 1)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.outdoorHeading(fontSize: 15 * s),
                ),
              ),
              SizedBox(width: 6 * s),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 3 * s),
                decoration: BoxDecoration(
                  color: hasActive ? const Color(0xFFECFDF5) : Colors.grey.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6 * s),
                ),
                child: Text(
                  hasActive ? 'BOARDING' : 'BAY EMPTY',
                  style: TextStyle(
                    fontSize: 11.5 * s,
                    fontWeight: FontWeight.w900,
                    color: hasActive ? const Color(0xFF059669) : AppTypography.slate600,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 9 * s),

          if (!hasActive)
            Text('No vehicle currently loading at the bay.', style: AppTypography.outdoorBody(fontSize: 13.5 * s))
          else
            FutureBuilder<Map<String, dynamic>?>(
              future: _fetchVehicleData(activeVehicle.toString()),
              builder: (context, snapshot) {
                final vData = snapshot.data;
                final plate = vData?['plate_number'] ?? activeVehicle.toString();
                final jeepName = vData?['vehicle_name'] ?? plate;
                final driverName = vData?['driver_name'] ?? 'Driver Assigned';
                final maxSeats = (vData?['max_capacity'] as num?)?.toInt() ?? 20;
                final passengerCount = (vData?['passenger_count'] as num?)?.toInt() ?? 0;

                return InkWell(
                  onTap: () => _showVehicleDetailsModal(
                    context: context,
                    vehicleId: activeVehicle.toString(),
                    showSpeed: false,
                    initialData: vData,
                  ),
                  borderRadius: BorderRadius.circular(10 * s),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 10 * s),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundSlate,
                      borderRadius: BorderRadius.circular(10 * s),
                    ),
                    child: Row(
                      children: [
                        _buildLicensePlateBadge(plate.toString(), fontSize: 13),
                        SizedBox(width: 8 * s),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                jeepName.toString(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.outdoorHeading(fontSize: 14 * s),
                              ),
                              Text(
                                'Driver: $driverName',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.outdoorBody(fontSize: 12.5 * s, fontWeight: FontWeight.normal),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 6 * s),
                        _buildCapacityBadge(passengerCount, maxSeats),
                        Icon(Icons.chevron_right_rounded, size: 20 * s, color: AppColors.textMuted),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildEnRouteSection(List<QueryDocumentSnapshot> enRouteDocs) {
    final s = _s;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8 * s,
              height: 8 * s,
              decoration: const BoxDecoration(color: Color(0xFF059669), shape: BoxShape.circle),
            ),
            SizedBox(width: 7 * s),
            Expanded(
              child: Text(
                'EN-ROUTE ON ROAD (${enRouteDocs.length})',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5 * s,
                  fontWeight: FontWeight.w800,
                  color: AppTypography.slate900,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            SizedBox(width: 6 * s),
            Text('Live Telemetry', style: AppTypography.outdoorBody(fontSize: 12 * s, fontWeight: FontWeight.normal)),
          ],
        ),
        SizedBox(height: 8 * s),

        if (enRouteDocs.isEmpty)
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(12 * s),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10 * s),
              border: Border.all(color: AppColors.borderSubtle),
            ),
            child: Text(
              'No jeepneys currently traveling on the highway.',
              style: AppTypography.outdoorBody(fontSize: 13.5 * s),
            ),
          )
        else
          ...enRouteDocs.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final plate = data['plate_number'] ?? doc.id;
            final jeepName = data['vehicle_name'] ?? plate;
            final speed = (data['speed_kmh'] as num?)?.toInt() ?? 0;
            final currentSeats = (data['passenger_count'] as num?)?.toInt() ?? 0;
            final maxSeats = (data['max_capacity'] as num?)?.toInt() ?? 20;

            return Container(
              margin: EdgeInsets.only(bottom: 8 * s),
              child: InkWell(
                onTap: () {
                  _showVehicleDetailsModal(
                    context: context,
                    vehicleId: doc.id,
                    showSpeed: true,
                    initialData: data,
                  );
                },
                borderRadius: BorderRadius.circular(10 * s),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 9 * s),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10 * s),
                    border: Border.all(color: const Color(0xFF86EFAC)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.navigation_rounded, size: 18 * s, color: const Color(0xFF059669)),
                      SizedBox(width: 6 * s),
                      _buildLicensePlateBadge(plate.toString(), fontSize: 13),
                      SizedBox(width: 8 * s),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              jeepName.toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.outdoorHeading(fontSize: 14 * s),
                            ),
                            Text(
                              '$speed km/h',
                              style: AppTypography.outdoorBody(fontSize: 12.5 * s, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 6 * s),
                      _buildCapacityBadge(currentSeats, maxSeats),
                      Icon(Icons.chevron_right_rounded, size: 20 * s, color: AppColors.textMuted),
                    ],
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildQueueSection(Map<String, dynamic>? queueData) {
    final s = _s;
    final queuedList = (queueData?['queued_vehicles'] as List<dynamic>?) ?? [];
    final stagedList = (queueData?['standby_staged_vehicles'] as List<dynamic>?) ?? [];

    if (queuedList.isEmpty && stagedList.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'TERMINAL LINE-UP (ON-DECK & STANDBY)',
          style: AppTypography.outdoorBody(fontSize: 13 * s, fontWeight: FontWeight.w800),
        ),
        SizedBox(height: 8 * s),
        ...queuedList.map((item) => _buildQueueTile(item.toString(), 'On-Deck', const Color(0xFF2563EB))),
        ...stagedList.map((item) => _buildQueueTile(item.toString(), _isGuinsangan ? 'Holding for Robinsons (not boarding)' : 'Standby', const Color(0xFFD97706))),
      ],
    );
  }

  Widget _buildQueueTile(String vehicleId, String label, Color color) {
    final s = _s;
    return Container(
      margin: EdgeInsets.only(bottom: 8 * s),
      child: FutureBuilder<Map<String, dynamic>?>(
        future: _fetchVehicleData(vehicleId),
        builder: (context, snapshot) {
          final vData = snapshot.data;
          final plate = vData?['plate_number'] ?? vehicleId;
          final jeepName = vData?['vehicle_name'] ?? plate;
          final maxSeats = (vData?['max_capacity'] as num?)?.toInt() ?? 20;
          final passengerCount = (vData?['passenger_count'] as num?)?.toInt() ?? 0;

          return InkWell(
            onTap: () => _showVehicleDetailsModal(
              context: context,
              vehicleId: vehicleId,
              showSpeed: false,
              initialData: vData,
            ),
            borderRadius: BorderRadius.circular(10 * s),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 9 * s),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10 * s),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Row(
                children: [
                  Container(
                    width: 9 * s,
                    height: 9 * s,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  SizedBox(width: 8 * s),
                  _buildLicensePlateBadge(plate.toString(), fontSize: 13),
                  SizedBox(width: 8 * s),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          jeepName.toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.outdoorHeading(fontSize: 14 * s),
                        ),
                        Text(
                          (vData != null && _isGuinsangan && _isApproachingData(vData))
                              ? 'Heading to Robinsons'
                              : label,
                          style: TextStyle(fontSize: 12.5 * s, fontWeight: FontWeight.bold, color: color),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 6 * s),
                  _buildCapacityBadge(passengerCount, maxSeats),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFareCard() {
    final s = _s;

    // The pinned stop decides the fare: road distance from the start
    // terminal to the pin, measured along the route polyline.
    final hasPin = _pinnedAlongMeters != null;
    final includesDalipe = _fareIncludesDalipeLeg;
    // Guinsang-an: add the Dalipe 2 -> Robinsons distance to the fare distance.
    final meters = (_pinnedAlongMeters ?? 0.0) + (hasPin ? _fareOffsetMeters : 0.0);

    final regular = hasPin
        ? _formatPeso(_regularFareForMeters(meters))
        : widget.regularFare;
    final discounted = hasPin
        ? _formatPeso(_discountedFareForMeters(meters))
        : widget.discountedFare;

    return Container(
      padding: EdgeInsets.all(14 * s),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14 * s),
        border: Border.all(
          color: hasPin ? const Color(0xFFFCA5A5) : AppColors.borderSubtle,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                hasPin ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                size: 16 * s,
                color: hasPin ? const Color(0xFFDC2626) : AppTypography.slate600,
              ),
              SizedBox(width: 6 * s),
              Expanded(
                child: Text(
                  hasPin ? 'FARE TO YOUR STOP' : 'ROUTE FARE',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.outdoorBody(fontSize: 12.5 * s, fontWeight: FontWeight.w800),
                ),
              ),
              if (hasPin)
                Text(
                  '${_formatDistance(meters)} from ${includesDalipe ? 'Dalipe 2' : 'start'}',
                  style: AppTypography.outdoorBody(fontSize: 12 * s, fontWeight: FontWeight.w600),
                ),
            ],
          ),
          SizedBox(height: 10 * s),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('REGULAR FARE', style: AppTypography.outdoorBody(fontSize: 11.5 * s, fontWeight: FontWeight.w700)),
                    SizedBox(height: 2 * s),
                    Text(regular, style: TextStyle(fontSize: 19 * s, fontWeight: FontWeight.w800, color: AppTypography.slate900)),
                  ],
                ),
              ),
              Container(width: 1, height: 36 * s, color: AppColors.borderSubtle),
              SizedBox(width: 14 * s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'STUDENT / PWD / SENIOR',
                      maxLines: 2,
                      style: AppTypography.outdoorBody(fontSize: 11.5 * s, fontWeight: FontWeight.w700),
                    ),
                    SizedBox(height: 2 * s),
                    Text(discounted, style: TextStyle(fontSize: 19 * s, fontWeight: FontWeight.w800, color: const Color(0xFF0F766E))),
                  ],
                ),
              ),
            ],
          ),
          if (!hasPin) ...[
            SizedBox(height: 8 * s),
            Text(
              'Tap the pin button on the map, then tap the route to see the fare to your stop.',
              style: AppTypography.outdoorBody(fontSize: 11.5 * s, fontWeight: FontWeight.normal),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDispatchNote() {
    final s = _s;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 10 * s),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(10 * s),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: 1 * s),
            child: Icon(Icons.info_outline_rounded, size: 18 * s, color: const Color(0xFF1D4ED8)),
          ),
          SizedBox(width: 8 * s),
          Expanded(
            child: Text(
              widget.dispatchRule,
              style: TextStyle(fontSize: 13 * s, color: const Color(0xFF1E40AF), height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  bool _isEnRoute(QueryDocumentSnapshot d) {
    final data = d.data() as Map<String, dynamic>;
    final status = (data['current_status'] ?? '').toString().toUpperCase();
    final isDispatched = data['is_dispatched'] == true;
    final isVisible = data['visible_to_commuters'] != false;
    if (_isGuinsangan && _isApproachingData(data)) return false;
    return status == 'EN_ROUTE' && (isDispatched || isVisible);
  }

  // Sheet section: units heading Dalipe -> Robinsons with a live ETA each.
  Widget _buildApproachSection(List<QueryDocumentSnapshot> approachDocs) {
    final s = _s;
    const amber = Color(0xFFD97706);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8 * s,
              height: 8 * s,
              decoration: const BoxDecoration(color: amber, shape: BoxShape.circle),
            ),
            SizedBox(width: 7 * s),
            Expanded(
              child: Text(
                'ARRIVING TO ROBINSONS (${approachDocs.length})',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5 * s,
                  fontWeight: FontWeight.w800,
                  color: AppTypography.slate900,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: 3 * s),
        Text(
          'Driving from Dalipe to Robinsons. Not boarding passengers.',
          style: AppTypography.outdoorBody(fontSize: 11.5 * s, fontWeight: FontWeight.normal),
        ),
        SizedBox(height: 8 * s),
        ...approachDocs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          _recordVehicleSpeed(doc.id, data);
          final plate = data['plate_number'] ?? doc.id;
          final jeepName = data['vehicle_name'] ?? plate;
          final eta = _approachEtaText(doc.id, data);

          return Container(
            margin: EdgeInsets.only(bottom: 8 * s),
            child: InkWell(
              onTap: () => _showVehicleDetailsModal(
                context: context,
                vehicleId: doc.id,
                showSpeed: true,
                initialData: data,
              ),
              borderRadius: BorderRadius.circular(10 * s),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 9 * s),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10 * s),
                  border: Border.all(color: const Color(0xFFFCD34D)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.near_me_rounded, size: 18 * s, color: amber),
                    SizedBox(width: 6 * s),
                    _buildLicensePlateBadge(plate.toString(), fontSize: 13),
                    SizedBox(width: 8 * s),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            jeepName.toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.outdoorHeading(fontSize: 14 * s),
                          ),
                          Text(
                            'ETA to Robinsons: $eta',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5 * s,
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF1D4ED8),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, size: 20 * s, color: AppColors.textMuted),
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  // Modal rows for a unit that is heading Dalipe -> Robinsons.
  Widget _buildApproachEtaRows(Map<String, dynamic> data, String vehicleId, double s) {
    final meters = _distanceToRobinsonsMeters(data);

    return Padding(
      padding: EdgeInsets.only(top: 7 * s),
      child: Column(
        children: [
          _buildDetailRow(
            Icons.near_me_rounded,
            'Status',
            'Heading to Robinsons',
            valueColor: const Color(0xFFD97706),
          ),
          SizedBox(height: 7 * s),
          _buildDetailRow(
            Icons.schedule_rounded,
            'ETA to Robinsons',
            _approachEtaText(vehicleId, data),
            valueColor: const Color(0xFF1D4ED8),
          ),
          if (meters != null) ...[
            SizedBox(height: 7 * s),
            _buildDetailRow(
              Icons.straighten_rounded,
              'Distance to Robinsons',
              _formatDistance(meters),
            ),
          ],
          SizedBox(height: 6 * s),
          Text(
            'Not boarding passengers. Joins the Robinsons line-up after the dispatcher scan.',
            textAlign: TextAlign.center,
            style: AppTypography.outdoorBody(fontSize: 11 * s, fontWeight: FontWeight.normal),
          ),
        ],
      ),
    );
  }

  // Small hub badge used for Dalipe / Robinsons on the Guinsang-an map.
  Widget _buildHubMarker(String label, IconData icon, Color color, double s, bool showTag) {
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 40 * s,
          height: 40 * s,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color.withOpacity(0.18)),
        ),
        Container(
          width: 28 * s,
          height: 28 * s,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: const [
              BoxShadow(color: Color(0x40000000), blurRadius: 5, offset: Offset(0, 2)),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 15 * s),
        ),
        if (showTag)
          Positioned(
            bottom: 0,
            child: _buildMarkerLabel(label, color, s),
          ),
      ],
    );
  }

  // ─────────────────────────── Smooth + predicted vehicle movement
  //
  // Hardware pings can be several seconds apart. Between pings the marker is
  // moved forward along the road using the vehicle's last reported speed
  // (dead reckoning), then eased toward the corrected position when the next
  // real fix arrives, so it never freezes or jumps.

  final Map<String, _VehicleGlide> _glides = {};
  final ValueNotifier<int> _animationFrame = ValueNotifier<int>(0);
  late final Ticker _frameTicker;

  void _onFrame(Duration _) {
    // Only repaint the markers while something is still moving.
    for (final g in _glides.values) {
      if (g.isAnimating) {
        _animationFrame.value++;
        return;
      }
    }
  }

  /// Point at [distanceMeters] along a polyline (cum = running distances).
  LatLng _pointAtAlong(List<LatLng> pts, List<double> cum, double distanceMeters) {
    if (pts.isEmpty) return const LatLng(0, 0);
    if (pts.length < 2 || distanceMeters <= 0) return pts.first;
    if (distanceMeters >= cum.last) return pts.last;

    int lo = 0;
    int hi = cum.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] <= distanceMeters) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final segLen = cum[lo + 1] - cum[lo];
    final t = segLen == 0 ? 0.0 : (distanceMeters - cum[lo]) / segLen;
    return LatLng(
      pts[lo].latitude + (pts[lo + 1].latitude - pts[lo].latitude) * t,
      pts[lo].longitude + (pts[lo + 1].longitude - pts[lo].longitude) * t,
    );
  }

  /// Where the vehicle probably is right now, based on its last fix.
  LatLng _predictedTarget(_VehicleGlide g, DateTime now, bool approach) {
    final along = g.alongAtFix;
    if (along == null || g.speedKmh < 3) return g.fix;

    final elapsed = math.min(
      now.difference(g.fixAt).inMilliseconds / 1000.0,
      g.maxPredictSeconds,
    );
    final travelMeters = g.speedKmh / 3.6 * elapsed;

    final pts = approach ? _approachPolylinePoints : _roadPolylinePoints;
    final cum = approach ? _approachCumulative : _routeCumulative;
    return _pointAtAlong(pts, cum, math.min(along + travelMeters, cum.last));
  }

  /// Position to draw for vehicle [id]: predicted ahead of its last fix and
  /// smoothly corrected whenever a new fix arrives.
  LatLng _smoothPosition(String id, LatLng fix, num speedKmh, {bool approach = false}) {
    final now = DateTime.now();
    final speed = speedKmh.toDouble();
    final g = _glides.putIfAbsent(id, () => _VehicleGlide(fix, speed, now));

    if (g.isNewFix(fix, speed)) {
      g.registerFix(fix, speed, now);
      final proj = _projectOntoRoute(fix, approach: approach);
      // Only predict along the road if the vehicle is actually on it.
      g.alongAtFix =
          (proj != null && proj.offRouteMeters <= 60) ? proj.alongMeters : null;
    }

    return g.follow(_predictedTarget(g, now, approach), now);
  }

  // ─────────────────────────── Map markers

  // Small white label used under/over markers.
  Widget _buildMarkerLabel(String text, Color color, double s) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6 * s, vertical: 1.5 * s),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8 * s),
        border: Border.all(color: color.withOpacity(0.5), width: 1),
        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 3)],
      ),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          fontSize: 9.5 * s,
          fontWeight: FontWeight.w900,
          color: color,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  // Start terminal: navy bus badge with a soft halo and label.
  Widget _buildStartMarker(double s, bool showTag) {
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 46 * s,
          height: 46 * s,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primaryNavy.withOpacity(0.18),
          ),
        ),
        Container(
          width: 32 * s,
          height: 32 * s,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.primaryNavy.withOpacity(0.85), AppColors.primaryNavy],
            ),
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: const [
              BoxShadow(color: Color(0x40000000), blurRadius: 5, offset: Offset(0, 2)),
            ],
          ),
          child: Icon(Icons.directions_bus_rounded, color: Colors.white, size: 17 * s),
        ),
        if (showTag)
          Positioned(
            bottom: 0,
            child: _buildMarkerLabel('START', AppColors.primaryNavy, s),
          ),
      ],
    );
  }

  // End of route: green flag badge with halo and label.
  Widget _buildEndMarker(double s, bool showTag) {
    const green = Color(0xFF059669);
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 46 * s,
          height: 46 * s,
          decoration: BoxDecoration(shape: BoxShape.circle, color: green.withOpacity(0.18)),
        ),
        Container(
          width: 32 * s,
          height: 32 * s,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF10B981), Color(0xFF047857)],
            ),
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: const [
              BoxShadow(color: Color(0x40000000), blurRadius: 5, offset: Offset(0, 2)),
            ],
          ),
          child: Icon(Icons.flag_rounded, color: Colors.white, size: 17 * s),
        ),
        if (showTag)
          Positioned(
            bottom: 0,
            child: _buildMarkerLabel('END', green, s),
          ),
      ],
    );
  }

  // User's pinned stop: teardrop pin with a ground shadow and "YOUR STOP" label.
  Widget _buildStopPin(double s, bool showTag) {
    return Stack(
      alignment: Alignment.bottomCenter,
      clipBehavior: Clip.none,
      children: [
        // ground shadow under the pin tip
        Positioned(
          bottom: 0,
          child: Container(
            width: 16 * s,
            height: 6 * s,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8 * s),
              color: Colors.black.withOpacity(0.22),
            ),
          ),
        ),
        CustomPaint(
          size: Size(36 * s, 48 * s),
          painter: _TeardropPinPainter(),
        ),
        if (showTag)
          Positioned(
            top: 0,
            child: _buildMarkerLabel('YOUR STOP', const Color(0xFFDC2626), s),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final queueDocId = _getQueueDocId();
    final routeId = _mapDestinationToRouteId(widget.destination);

    final mapCenter = LatLng(
      (_startCoordinate.latitude + _endCoordinate.latitude) / 2,
      (_startCoordinate.longitude + _endCoordinate.longitude) / 2,
    );

    return Scaffold(
      backgroundColor: AppColors.backgroundSlate,
      body: Stack(
        children: [
          // Full-bleed live map (with floating header + map buttons)
          Positioned.fill(child: _buildMapArea(routeId, mapCenter, s)),

          // Draggable bottom sheet
          _buildDraggableSheet(queueDocId, routeId, s),
        ],
      ),
    );
  }

  // ─────────────────────────── Map area (map + floating header + buttons)

  Widget _buildMapArea(String routeId, LatLng mapCenter, double s) {
    final pad = MediaQuery.paddingOf(context);

    return Stack(
      children: [
        // 1. LIVE OPENSTREETMAP
        StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('vehicles_live')
              .where('route_id', isEqualTo: routeId)
              .snapshots(),
          builder: (context, vehiclesSnapshot) {
            final allDocs = vehiclesSnapshot.data?.docs ?? [];
            final enRouteDocs = allDocs.where(_isEnRoute).toList();
            final approachDocs = allDocs.where(_isApproaching).toList();

            return Positioned.fill(
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: mapCenter,
                  initialZoom: 12.0,
                  onTap: (_, point) => _handleMapTap(point),
                  onPositionChanged: (pos, _) {
                    final zoom = pos.zoom;
                    _currentZoom = zoom;
                    final shouldShow = zoom >= _zoomVisibilityThreshold;
                    if (_showMarkerTags.value != shouldShow) {
                      _showMarkerTags.value = shouldShow;
                    }
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.puj_dispatch_system',
                  ),
                  PolylineLayer(
                    polylines: [
                      if (_isGuinsangan &&
                          _showApproach &&
                          _approachPolylinePoints.length >= 2)
                        Polyline(
                          points: _approachPolylinePoints,
                          color: const Color(0xFFF59E0B).withOpacity(0.9),
                          strokeWidth: 4,
                          borderColor: Colors.white,
                          borderStrokeWidth: 1,
                        ),
                      if (_showPolyline && !_isLoadingRoad && _roadPolylinePoints.isNotEmpty)
                        Polyline(
                          points: _roadPolylinePoints,
                          color: const Color(0xFF2563EB),
                          strokeWidth: 5,
                          borderColor: Colors.white,
                          borderStrokeWidth: 2,
                        ),
                    ],
                  ),
                  ValueListenableBuilder<int>(
                    valueListenable: _animationFrame,
                    builder: (context, frame, child) => ValueListenableBuilder<bool>(
                    valueListenable: _showMarkerTags,
                    builder: (context, showTags, _) {
                      final markers = <Marker>[];

                      // Start & End Terminal Pins
                      markers.add(
                        Marker(
                          point: _startCoordinate,
                          width: 90 * s,
                          height: 76 * s,
                          child: Opacity(
                            opacity: (_pinnedStop != null &&
                                    _distance(_pinnedStop!, _startCoordinate) < 120)
                                ? 0.55
                                : 1.0,
                            child: _buildStartMarker(s, showTags),
                          ),
                        ),
                      );

                      markers.add(
                        Marker(
                          point: _endCoordinate,
                          width: 90 * s,
                          height: 76 * s,
                          child: _buildEndMarker(s, showTags),
                        ),
                      );

                      // Guinsang-an hubs: Dalipe holding area and Robinsons
                      if (_isGuinsangan) {
                        if (_distance(_startCoordinate, _dalipeHubCoordinate) > 150) {
                          markers.add(
                            Marker(
                              point: _dalipeHubCoordinate,
                              width: 90 * s,
                              height: 76 * s,
                              child: _buildHubMarker('DALIPE 2', Icons.hourglass_top_rounded,
                                  const Color(0xFFD97706), s, showTags),
                            ),
                          );
                        }
                        if (_distance(_startCoordinate, _robinsonsHubCoordinate) > 150) {
                          markers.add(
                            Marker(
                              point: _robinsonsHubCoordinate,
                              width: 90 * s,
                              height: 76 * s,
                              child: _buildHubMarker('ROBINSONS', Icons.storefront_rounded,
                                  AppColors.primaryNavy, s, showTags),
                            ),
                          );
                        }
                      }

                      // User-pinned stop (tip of the pin sits on the snapped road point)
                      if (_pinnedStop != null) {
                        markers.add(
                          Marker(
                            point: _pinnedStop!,
                            width: 80 * s,
                            height: 64 * s,
                            alignment: Alignment.topCenter,
                            child: _buildStopPin(s, showTags),
                          ),
                        );
                      }

                      // Moving Vehicles
                      for (var doc in enRouteDocs) {
                        final data = doc.data() as Map<String, dynamic>;
                        final loc = data['location'] as Map<String, dynamic>?;

                        if (loc != null && loc['latitude'] != null && loc['longitude'] != null) {
                          final lat = (loc['latitude'] as num).toDouble();
                          final lng = (loc['longitude'] as num).toDouble();
                          final plate = (data['plate_number'] ?? doc.id).toString();
                          final speed = (data['speed_kmh'] as num?)?.toInt() ?? 0;
                          final dotColor = _resolveVehicleDotColor(data['vehicle_color']?.toString());
                          final offRoute = _isOffRoute(doc.id, LatLng(lat, lng));

                          markers.add(
                            Marker(
                              point: _smoothPosition(doc.id, LatLng(lat, lng), speed),
                              width: 160 * s,
                              height: 62 * s,
                              child: GestureDetector(
                                onTap: () {
                                  AppTypography.lightFeedback();
                                  _showVehicleDetailsModal(
                                    context: context,
                                    vehicleId: doc.id,
                                    showSpeed: true,
                                    initialData: data,
                                  );
                                },
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (showTags) ...[
                                      Container(
                                        padding: EdgeInsets.symmetric(horizontal: 7 * s, vertical: 2.5 * s),
                                        decoration: BoxDecoration(
                                          color: (offRoute ? const Color(0xFFD97706) : AppColors.primaryNavy).withOpacity(0.94),
                                          borderRadius: BorderRadius.circular(6 * s),
                                          border: Border.all(color: Colors.white70, width: 0.8),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (offRoute) ...[
                                              Icon(Icons.link_off_rounded, color: Colors.white, size: 12 * s),
                                              SizedBox(width: 3 * s),
                                            ],
                                            Text(
                                              '$plate • $speed km/h',
                                              maxLines: 1,
                                              style: TextStyle(color: Colors.white, fontSize: 11.5 * s, fontWeight: FontWeight.bold),
                                            ),
                                          ],
                                        ),
                                      ),
                                      SizedBox(height: 3 * s),
                                    ],
                                    Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        Container(
                                          width: 28 * s,
                                          height: 28 * s,
                                          decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor.withOpacity(0.28)),
                                        ),
                                        Container(
                                          width: 18 * s,
                                          height: 18 * s,
                                          decoration: BoxDecoration(
                                            color: dotColor.withOpacity(speed < 3 ? 0.55 : 1.0),
                                            shape: BoxShape.circle,
                                            border: Border.all(color: Colors.white, width: 2.2),
                                            boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 2)],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }
                      }

                      // Units driving Dalipe -> Robinsons after acknowledging the call
                      for (var doc in approachDocs) {
                        final data = doc.data() as Map<String, dynamic>;
                        final loc = data['location'] as Map<String, dynamic>?;
                        if (loc == null || loc['latitude'] == null || loc['longitude'] == null) {
                          continue;
                        }
                        _recordVehicleSpeed(doc.id, data);
                        final plate = (data['plate_number'] ?? doc.id).toString();
                        final eta = _approachEtaText(doc.id, data);

                        markers.add(
                          Marker(
                            point: _smoothPosition(
                              doc.id,
                              LatLng(
                                (loc['latitude'] as num).toDouble(),
                                (loc['longitude'] as num).toDouble(),
                              ),
                              (data['speed_kmh'] as num?) ?? 0,
                              approach: true,
                            ),
                            width: 200 * s,
                            height: 62 * s,
                            child: GestureDetector(
                              onTap: () {
                                AppTypography.lightFeedback();
                                _showVehicleDetailsModal(
                                  context: context,
                                  vehicleId: doc.id,
                                  showSpeed: true,
                                  initialData: data,
                                );
                              },
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (showTags) ...[
                                    Container(
                                      padding: EdgeInsets.symmetric(horizontal: 7 * s, vertical: 2.5 * s),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFD97706).withOpacity(0.95),
                                        borderRadius: BorderRadius.circular(6 * s),
                                        border: Border.all(color: Colors.white70, width: 0.8),
                                      ),
                                      child: Text(
                                        '$plate → Robinsons • $eta',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(color: Colors.white, fontSize: 11.5 * s, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    SizedBox(height: 3 * s),
                                  ],
                                  Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Container(
                                        width: 28 * s,
                                        height: 28 * s,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: const Color(0xFFF59E0B).withOpacity(0.3),
                                        ),
                                      ),
                                      Container(
                                        width: 18 * s,
                                        height: 18 * s,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFD97706),
                                          shape: BoxShape.circle,
                                          border: Border.all(color: Colors.white, width: 2.2),
                                          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 2)],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }

                      return MarkerLayer(markers: markers);
                    },
                  ),
                  ),
                ],
              ),
            );
          },
        ),

        // 1b. ROUTE LOADING OVERLAY (until the road polyline is ready)
        if (_isLoadingRoad)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: Colors.white.withOpacity(0.55),
                alignment: const Alignment(0, -0.3),
                child: _buildRouteLoadingCard(s),
              ),
            ),
          ),

        // 2. FLOATING TOP HEADER & NAVIGATION BAR
        Positioned(
          top: pad.top + 8 * s,
          left: 12 * s + pad.left,
          right: 12 * s,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 4 * s, vertical: 4 * s),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.96),
              borderRadius: BorderRadius.circular(26 * s),
              border: Border.all(color: AppColors.borderSubtle),
              boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 2))],
            ),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_back_rounded, size: 24 * s, color: AppTypography.slate900),
                  onPressed: () {
                    AppTypography.lightFeedback();
                    Navigator.pop(context);
                  },
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.destination,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.outdoorHeading(fontSize: 16.5 * s),
                      ),
                      Text(
                        widget.terminalName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.outdoorBody(fontSize: 12.5 * s, fontWeight: FontWeight.normal),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 6 * s),
                InkWell(
                  onTap: () {
                    AppTypography.selectionFeedback();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => PassengerComplaintScreen(
                          terminalName: widget.terminalName,
                          terminalId: widget.terminalId,
                          destination: widget.destination,
                          routeId: routeId,
                        ),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(18 * s),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 11 * s, vertical: 8 * s),
                    decoration: BoxDecoration(
                      color: AppColors.errorCrimson,
                      borderRadius: BorderRadius.circular(18 * s),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.report_problem_rounded, color: Colors.white, size: 16 * s),
                        SizedBox(width: 4 * s),
                        Text(
                          'REPORT',
                          style: TextStyle(color: Colors.white, fontSize: 12.5 * s, fontWeight: FontWeight.w900),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: 6 * s),
              ],
            ),
          ),
        ),

        // 2b. NO-INTERNET BANNER
        Positioned(
          top: pad.top + 8 * s + 62 * s,
          left: 12 * s + pad.left,
          right: 70 * s,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SizeTransition(
                sizeFactor: anim,
                axisAlignment: -1,
                child: child,
              ),
            ),
            child: _isOffline
                ? _buildOfflineBanner(s)
                : const SizedBox.shrink(key: ValueKey('online')),
          ),
        ),

        // 3. MAP BUTTONS: RE-CENTER, POLYLINE TOGGLE, PIN STOP
        Positioned(
          top: pad.top + 8 * s + 62 * s,
          right: 14 * s,
          child: Column(
            children: [
              SizedBox(
                width: 44 * s,
                height: 44 * s,
                child: FloatingActionButton(
                  heroTag: 'recenter_map',
                  tooltip: 'Re-center map',
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.primaryNavy,
                  elevation: 3,
                  onPressed: () {
                    AppTypography.lightFeedback();
                    _mapController.move(mapCenter, 12.0);
                  },
                  child: Icon(Icons.my_location_rounded, size: 22 * s),
                ),
              ),
              SizedBox(height: 8 * s),
              SizedBox(
                width: 44 * s,
                height: 44 * s,
                child: FloatingActionButton(
                  heroTag: 'toggle_poly',
                  tooltip: _showPolyline ? 'Hide route' : 'Show route',
                  backgroundColor: _showPolyline ? AppColors.primaryNavy : Colors.white,
                  foregroundColor: _showPolyline ? Colors.white : AppTypography.slate800,
                  elevation: 3,
                  onPressed: () {
                    AppTypography.lightFeedback();
                    setState(() {
                      _showPolyline = !_showPolyline;
                      _showApproach = _showPolyline;
                    });
                  },
                  child: Icon(Icons.alt_route_rounded, size: 22 * s),
                ),
              ),
              SizedBox(height: 8 * s),
              SizedBox(
                width: 44 * s,
                height: 44 * s,
                child: FloatingActionButton(
                  heroTag: 'pin_stop',
                  tooltip: _pinnedStop != null ? 'Remove pin' : 'Pin your stop',
                  backgroundColor: (_pinMode || _pinnedStop != null)
                      ? const Color(0xFFEF4444)
                      : Colors.white,
                  foregroundColor: (_pinMode || _pinnedStop != null)
                      ? Colors.white
                      : AppTypography.slate800,
                  elevation: 3,
                  onPressed: () {
                    AppTypography.lightFeedback();
                    if (_pinnedStop != null) {
                      _clearPin(); // tap again to remove the pin
                    } else {
                      setState(() => _pinMode = !_pinMode);
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      if (_pinMode) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Tap the route to pin your stop.')),
                        );
                      }
                    }
                  },
                  child: Icon(
                    _pinnedStop != null
                        ? Icons.location_off_rounded
                        : Icons.push_pin_outlined,
                    size: 22 * s,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─────────────────────────── Loading + offline widgets

  Widget _buildRouteLoadingCard(double s) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 18 * s, vertical: 14 * s),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18 * s),
        border: Border.all(color: AppColors.borderSubtle),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 14, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 22 * s,
            height: 22 * s,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: AppColors.primaryNavy,
            ),
          ),
          SizedBox(width: 12 * s),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Loading route…',
                style: AppTypography.outdoorHeading(fontSize: 14.5 * s),
              ),
              Text(
                'Drawing the road path',
                style: AppTypography.outdoorBody(
                  fontSize: 12 * s,
                  fontWeight: FontWeight.normal,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineBanner(double s) {
    return Container(
      key: const ValueKey('offline'),
      padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 9 * s),
      decoration: BoxDecoration(
        color: const Color(0xFF334155),
        borderRadius: BorderRadius.circular(14 * s),
        boxShadow: const [
          BoxShadow(color: Color(0x26000000), blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_off_rounded, color: const Color(0xFFFBBF24), size: 20 * s),
          SizedBox(width: 10 * s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'No internet connection',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13 * s,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  'Live positions and the map may be outdated.',
                  style: TextStyle(color: Colors.white, fontSize: 11.5 * s),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────── Draggable bottom sheet

  Widget _buildDraggableSheet(String queueDocId, String routeId, double s) {
    final pad = MediaQuery.paddingOf(context);

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('terminals_queue').doc(queueDocId).snapshots(),
      builder: (context, queueSnapshot) {
        final queueData = queueSnapshot.hasData && queueSnapshot.data!.exists
            ? queueSnapshot.data!.data() as Map<String, dynamic>
            : null;

        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('vehicles_live')
              .where('route_id', isEqualTo: routeId)
              .snapshots(),
          builder: (context, vehiclesSnapshot) {
            final allDocs = vehiclesSnapshot.data?.docs ?? [];
            final enRouteDocs = allDocs.where(_isEnRoute).toList();
            final approachDocs = allDocs.where(_isApproaching).toList();

            return DraggableScrollableSheet(
              initialChildSize: 0.38,
              minChildSize: 0.16,
              maxChildSize: 0.88,
              snap: true,
              snapSizes: const [0.16, 0.38, 0.88],
              builder: (sheetContext, scrollController) {
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(24 * s)),
                    boxShadow: const [
                      BoxShadow(color: Color(0x18000000), blurRadius: 14, offset: Offset(0, -3)),
                    ],
                  ),
                  child: ListView(
                    controller: scrollController,
                    padding: EdgeInsets.fromLTRB(
                      16 * s + pad.left,
                      10 * s,
                      16 * s + pad.right,
                      16 * s + pad.bottom,
                    ),
                    children: [
                      Center(
                        child: Container(
                          width: 40 * s,
                          height: 5 * s,
                          decoration: BoxDecoration(
                            color: const Color(0xFFCBD5E1),
                            borderRadius: BorderRadius.circular(3 * s),
                          ),
                        ),
                      ),
                      SizedBox(height: 12 * s),

                      _buildTerminalStatusBanner(queueData != null),
                      SizedBox(height: 12 * s),
                      _buildSpot1LoadingCard(queueData),
                      SizedBox(height: 14 * s),
                      _buildEnRouteSection(enRouteDocs),
                      if (_isGuinsangan && approachDocs.isNotEmpty) ...[
                        SizedBox(height: 14 * s),
                        _buildApproachSection(approachDocs),
                      ],
                      SizedBox(height: 14 * s),
                      _buildQueueSection(queueData),
                      SizedBox(height: 14 * s),
                      _buildFareCard(),
                      if (widget.dispatchRule.isNotEmpty) ...[
                        SizedBox(height: 12 * s),
                        _buildDispatchNote(),
                      ],
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────── Custom painter for the stop pin

class _TeardropPinPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final r = w / 2;
    final cx = w / 2;
    final cy = r; // center of the round head

    // Teardrop: circle head tapering to a point at the bottom.
    final path = Path()
      ..moveTo(cx, h)
      ..cubicTo(cx - r * 0.2, h - r * 0.9, 0, cy + r * 0.9, 0, cy)
      ..arcToPoint(Offset(w, cy), radius: Radius.circular(r), clockwise: true)
      ..cubicTo(w, cy + r * 0.9, cx + r * 0.2, h - r * 0.9, cx, h)
      ..close();

    // drop shadow
    canvas.drawShadow(path, Colors.black, 4, true);

    // body gradient
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFF87171), Color(0xFFDC2626)],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawPath(path, paint);

    // white outline
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );

    // inner white dot
    canvas.drawCircle(Offset(cx, cy), r * 0.42, Paint()..color = Colors.white);
    canvas.drawCircle(Offset(cx, cy), r * 0.2, Paint()..color = const Color(0xFFDC2626));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─────────────────────────── Small helper types

class _RouteProjection {
  final LatLng point; // closest point on the route line
  final double alongMeters; // road distance from the route start to [point]
  final double offRouteMeters; // how far the original point was from the line

  const _RouteProjection(this.point, this.alongMeters, this.offRouteMeters);
}

class _SpeedEstimate {
  final double kmh; // smoothed speed (0 when stopped)
  final double spread; // relative variation, used for the ETA range

  const _SpeedEstimate(this.kmh, this.spread);
}

/// Tracks one vehicle's last GPS fix and the position currently drawn for it.
class _VehicleGlide {
  LatLng fix;
  DateTime fixAt;
  double speedKmh;
  double? alongAtFix; // road distance of the fix along the route, if on-road

  LatLng drawn;
  DateTime _lastDrawAt;

  double _intervalSec = 8.0; // smoothed time between hardware fixes

  _VehicleGlide(LatLng p, double speed, DateTime now)
      : fix = p,
        fixAt = now,
        speedKmh = speed,
        drawn = p,
        _lastDrawAt = now;

  /// Never predict further ahead than ~1.5 update intervals (max 14 s), so a
  /// vehicle that stops sending data doesn't drive off into the distance.
  double get maxPredictSeconds => (_intervalSec * 1.5).clamp(4.0, 14.0).toDouble();

  bool isNewFix(LatLng p, double speed) =>
      p.latitude != fix.latitude ||
      p.longitude != fix.longitude ||
      (speed >= 3) != (speedKmh >= 3);

  void registerFix(LatLng p, double speed, DateTime now) {
    final gapSec = now.difference(fixAt).inMilliseconds / 1000.0;
    // Blend the measured gap into the interval estimate.
    _intervalSec = _intervalSec * 0.5 + gapSec.clamp(1.0, 20.0).toDouble() * 0.5;
    fix = p;
    fixAt = now;
    speedKmh = speed;
  }

  /// Still worth repainting every frame?
  bool get isAnimating =>
      DateTime.now().difference(fixAt).inMilliseconds / 1000.0 <
      maxPredictSeconds + 2.5;

  /// Eases the drawn position toward [target] (frame-rate independent), which
  /// hides the correction when a real fix disagrees with the prediction.
  LatLng follow(LatLng target, DateTime now) {
    final dt = now.difference(_lastDrawAt).inMilliseconds / 1000.0;
    if (dt <= 0) return drawn;
    _lastDrawAt = now;

    final alpha = 1 - math.exp(-dt / 0.7);
    drawn = LatLng(
      drawn.latitude + (target.latitude - drawn.latitude) * alpha,
      drawn.longitude + (target.longitude - drawn.longitude) * alpha,
    );
    return drawn;
  }
}