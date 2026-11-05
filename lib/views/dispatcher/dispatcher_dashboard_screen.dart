import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/login_screen.dart';
import '../../utils/staff_auth.dart';
import '../../utils/app_colors.dart';
import '../../utils/app_typography.dart';
import '../cooperative/rotation_master_list.dart';
import '../cooperative/route_process_config.dart';
import '../cooperative/route_process_widgets.dart';
import '../cooperative/queue_seeder.dart';
import '../cooperative/driver_suspension.dart';

enum DateFilterPreset { allTime, amShift, pmShift, custom }

class DispatcherDashboardScreen extends StatefulWidget {
  final String userId;
  final Map<String, dynamic> userData;

  const DispatcherDashboardScreen({
    super.key,
    required this.userId,
    required this.userData,
  });

  @override
  State<DispatcherDashboardScreen> createState() =>
      _DispatcherDashboardScreenState();
}

class _DispatcherDashboardScreenState extends State<DispatcherDashboardScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  static const LatLng _sanPedroCoordinate = LatLng(10.8003, 121.9484);
  List<LatLng> _roadPolylinePoints = const [];
  bool _isLoadingRoad = false;

  // Filter States for Dispatch History
  DateTime? _historyStartDate;
  DateTime? _historyEndDate;
  String _historyPlateQuery = '';
  TimeOfDay? _historyStartTime;
  TimeOfDay? _historyEndTime;
  DateFilterPreset _selectedPreset = DateFilterPreset.allTime;
  DateTime _focusedDate = DateTime.now();

  // Filter States for Queue Changes
  DateTime? _auditStartDate;
  DateTime? _auditEndDate;
  String _auditSearchQuery = '';

  // ── Per-route process (route_process_config.dart) ───────────────────────
  // Everything route-specific keys off this, never off a route name.
  RouteProcessConfig? get _process => RouteProcesses.of(_assignedRouteId);

  /// Rotation exists for this route (two-group, Dao, Aniniy).
  bool get _usesRotation => _process?.hasRotation ?? false;

  /// Dalipe standby pool + Robinsons call (two-group routes only).
  bool get _usesDalipeStaging => _process?.dalipeStaging ?? false;
  bool get _requiresRobinsonsCall => _process?.robinsonsCallRequired ?? false;
  bool get _autoDispatchOnFullOrTimer =>
      _process?.autoDispatchOnFullOrTimer ?? false;

  // Master rotation list (read-only for the dispatcher). Read through the
  // route's OWNER coop, not the dispatcher's own cooperative_id, so shared
  // routes resolve correctly.
  RotationConfig _rotation = RotationConfig.empty();
  StreamSubscription<RotationConfig>? _rotationSub;

  String get _rotationCoopId => _process?.ownerCoopId ?? '';

  Timer? _autoDispatchTimer;
  bool _autoDispatchBusy = false;
  String _lastDispatchAlertKey = '';

  Widget _rotationBadge(String vehicleId, {List<String> line = const []}) {
    if (!_usesRotation) return const SizedBox.shrink();
    final n = _rotation.numberOf(vehicleId);
    final k = _rotation.groupKeyOf(vehicleId);
    if (n == null || k == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: RotationNumberBadge(
        number: n,
        groupLabelText: groupLabel(k),
        skipped: _rotation.isAheadOfItsTurn(vehicleId, line),
      ),
    );
  }

  String get _assignedTerminalId =>
      (widget.userData['assigned_terminal'] ?? 'TERM_DALIPE_1').toString();

  String get _assignedRouteId =>
      (widget.userData['assigned_route'] ?? kLegacyDefaultRouteId).toString();

  bool get _isDalipeTerminal =>
      _assignedTerminalId.toUpperCase().contains('DALIPE');

  bool get _isRobinsonsTerminal =>
      _assignedTerminalId.toUpperCase().contains('ROBINSON');

  String get _currentQueueDocId {
    final routeSuffix = _assignedRouteId.replaceFirst('ROUTE_', '');
    return '${_assignedTerminalId}_$routeSuffix';
  }

  String get _dalipeQueueDocId {
    final routeSuffix = _assignedRouteId.replaceFirst('ROUTE_', '');
    return 'TERM_DALIPE_1_$routeSuffix';
  }

  String _formatRouteName(String rawRoute) {
    return rawRoute.replaceAll('ROUTE_', '').replaceAll('_', ' ');
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _applyDatePreset(DateFilterPreset.allTime, notify: false);
    _fetchRoadGeometry();
    _rotation = RotationConfig.empty(process: _process);
    // Make sure this dispatcher's own queue document exists.
    // Creates every missing terminals_queue doc, then this dispatcher's own.
QueueSeeder.seedAll().then((created) async {
  debugPrint('Queue docs created: $created');
  await QueueSeeder.ensure(_assignedTerminalId, _assignedRouteId);
}).catchError((e) {
  debugPrint('Seeding failed: $e');
});
    if (_usesRotation && _rotationCoopId.isNotEmpty) {
      _rotationSub = RotationRepo.watch(_rotationCoopId, _assignedRouteId)
          .listen((cfg) {
            if (mounted) setState(() => _rotation = cfg);
          }, onError: (e) => debugPrint('Rotation stream error: $e'));
    }
    if (_autoDispatchOnFullOrTimer) {
      _autoDispatchTimer = Timer.periodic(
          const Duration(seconds: 10), (_) => _autoDispatchTick());
    }
  }

  @override
  void didUpdateWidget(covariant DispatcherDashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_tabController.length != 3) {
      _tabController.dispose();
      _tabController = TabController(length: 3, vsync: this);
    }
  }

  @override
  void dispose() {
    _rotationSub?.cancel();
    _autoDispatchTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  // ===========================================================================
  // RESPONSIVE HELPERS
  // ===========================================================================

  /// Keeps the phone's system font scale inside a safe range so text stays
  /// readable without causing pixel overflow on narrow screens.
  Widget _ts(BuildContext context, Widget child) {
    final mq = MediaQuery.of(context);
    final bool narrow = mq.size.width < 360;
    return MediaQuery(
      data: mq.copyWith(
        textScaler: mq.textScaler.clamp(
          minScaleFactor: 0.9,
          maxScaleFactor: narrow ? 1.1 : 1.25,
        ),
      ),
      child: child,
    );
  }

  /// Dialog height cap that always fits inside the current phone screen.
  double _dialogMaxHeight(BuildContext context, double cap) {
    final h = MediaQuery.of(context).size.height;
    return (h * 0.9).clamp(240.0, cap).toDouble();
  }

  /// True on small phones (< 380 logical px wide).
  bool _isNarrow(BuildContext context) =>
      MediaQuery.of(context).size.width < 380;

  List<String> _parseStringList(dynamic raw) {
    if (raw is List) {
      return raw
          .map((e) => e?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return [];
  }

  String _monthName(int month) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return months[(month - 1).clamp(0, 11)];
  }

  String _formatDateHeader(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(dt.year, dt.month, dt.day);

    if (target == today) {
      return 'Today • ${_monthName(dt.month)} ${dt.day}, ${dt.year}';
    }
    final yesterday = today.subtract(const Duration(days: 1));
    if (target == yesterday) {
      return 'Yesterday • ${_monthName(dt.month)} ${dt.day}, ${dt.year}';
    }
    return '${_monthName(dt.month)} ${dt.day}, ${dt.year}';
  }

  // ===========================================================================
  // DATE FILTER PRESET & STEPPING HELPERS
  // ===========================================================================
  void _applyDatePreset(DateFilterPreset preset, {bool notify = true}) {
    final now = DateTime.now();

    void update() {
      _selectedPreset = preset;
      switch (preset) {
        case DateFilterPreset.allTime:
          _historyStartDate = null;
          _historyEndDate = null;
          _historyStartTime = null;
          _historyEndTime = null;
          break;
        case DateFilterPreset.amShift:
          _focusedDate = now;
          _historyStartDate = DateTime(now.year, now.month, now.day);
          _historyEndDate = DateTime(now.year, now.month, now.day);
          _historyStartTime = const TimeOfDay(hour: 5, minute: 0);
          _historyEndTime = const TimeOfDay(hour: 13, minute: 0);
          break;
        case DateFilterPreset.pmShift:
          _focusedDate = now;
          _historyStartDate = DateTime(now.year, now.month, now.day);
          _historyEndDate = DateTime(now.year, now.month, now.day);
          _historyStartTime = const TimeOfDay(hour: 13, minute: 0);
          _historyEndTime = const TimeOfDay(hour: 21, minute: 0);
          break;
        case DateFilterPreset.custom:
          break;
      }
    }

    if (notify && mounted) {
      AppTypography.selectionFeedback();
      setState(update);
    } else {
      update();
    }
  }

  void _stepDate(int daysDelta) {
    AppTypography.lightFeedback();
    final nextDate = _focusedDate.add(Duration(days: daysDelta));
    setState(() {
      _selectedPreset = DateFilterPreset.custom;
      _focusedDate = nextDate;
      _historyStartDate = DateTime(nextDate.year, nextDate.month, nextDate.day);
      _historyEndDate = DateTime(nextDate.year, nextDate.month, nextDate.day);
      _historyStartTime = null;
      _historyEndTime = null;
    });
  }

  // ===========================================================================
  // TERMINAL & ROUTE COORDINATES
  // ===========================================================================
  LatLng _getTerminalCoordinates() {
    if (_isRobinsonsTerminal) {
      return const LatLng(10.736535, 121.951601);
    }
    return const LatLng(10.756903, 121.935679);
  }

  LatLng _getDestinationCoordinates() {
    final p = _process;
    if (p != null) return LatLng(p.destLat, p.destLng);
    return const LatLng(10.641947, 121.977399);
  }

  Future<void> _fetchRoadGeometry() async {
    setState(() => _isLoadingRoad = true);

    final start = _getTerminalCoordinates();
    final end = _getDestinationCoordinates();
    final viaSanPedro = _isDalipeTerminal;

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
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List coordinates = data['routes'][0]['geometry']['coordinates'];

        if (mounted) {
          setState(() {
            _roadPolylinePoints = coordinates
                .map((coord) => LatLng(coord[1] as double, coord[0] as double))
                .toList();
            _isLoadingRoad = false;
          });
        }
        return;
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _roadPolylinePoints = viaSanPedro
            ? [start, _sanPedroCoordinate, end]
            : [start, end];
        _isLoadingRoad = false;
      });
    }
  }

  Color _resolveVehicleDotColor(String? colorStr) {
    if (colorStr == null || colorStr.trim().isEmpty) {
      return const Color(0xFF10B981);
    }
    final c = colorStr.toLowerCase();
    if (c.contains('red') || c.contains('crimson'))
      return const Color(0xFFEF4444);
    if (c.contains('blue') || c.contains('navy'))
      return const Color(0xFF2563EB);
    if (c.contains('green')) return const Color(0xFF10B981);
    if (c.contains('yellow') || c.contains('gold'))
      return const Color(0xFFF59E0B);
    if (c.contains('orange')) return const Color(0xFFF97316);
    if (c.contains('purple') || c.contains('violet'))
      return const Color(0xFF8B5CF6);
    if (c.contains('pink')) return const Color(0xFFEC4899);
    if (c.contains('silver') || c.contains('gray') || c.contains('grey'))
      return const Color(0xFF64748B);
    if (c.contains('white')) return const Color(0xFF0F172A);
    return const Color(0xFF10B981);
  }

  // ===========================================================================
  // PASSENGER BOARDING COUNTER (+ / -)
  // ===========================================================================
  Future<void> _adjustPassengerCount(
    String vehicleId,
    int current,
    int max,
    int delta,
  ) async {
    final next = (current + delta).clamp(0, max);
    if (next == current) return;

    AppTypography.lightFeedback();

    try {
      await FirebaseFirestore.instance
          .collection('vehicles_live')
          .doc(vehicleId)
          .update({
            'passenger_count': next,
            'updated_at': FieldValue.serverTimestamp(),
          });
    } catch (e) {
      _showSnackbar('Failed to update passenger count: $e', isError: true);
    }
  }

  // ===========================================================================
  // DISPATCH VEHICLE
  // ===========================================================================
  Future<void> _executeDispatch({
    required String activeVehicleId,
    required int passengerCount,
    required List<String> currentQueue,
    required List<String> currentStandby,
    required String terminalName,
    bool auto = false,
    String autoReason = '',
  }) async {
    if (activeVehicleId == 'None' || activeVehicleId.isEmpty) {
      if (!auto) {
        _showSnackbar('No vehicle currently loading at Spot 1.', isError: true);
      }
      return;
    }

    if (!auto) AppTypography.selectionFeedback();

    final confirm = auto
        ? true
        : await showDialog<bool>(
      context: context,
      builder: (ctx) => _ts(
        ctx,
        AlertDialog(
          scrollable: true,
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            'Dispatch $activeVehicleId?',
            style: AppTypography.outdoorHeading(fontSize: 17),
          ),
          content: Text(
            'Vehicle will depart Spot 1 with $passengerCount onboard passengers and broadcast live to commuters.',
            style: AppTypography.outdoorBody(fontSize: 13.5),
          ),
          actionsPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text(
                'Cancel',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF059669),
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'Confirm Dispatch',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;

    try {
      final batch = FirebaseFirestore.instance.batch();

      String nextLoading = 'None';
      List<String> newQueue = List.from(currentQueue);
      List<String> newStandby = List.from(currentStandby);

      if (newQueue.isNotEmpty) {
        nextLoading = newQueue.removeAt(0);
      }

      final queueRef = FirebaseFirestore.instance
          .collection('terminals_queue')
          .doc(_currentQueueDocId);
      batch.set(queueRef, {
        'terminal_id': _assignedTerminalId,
        'terminal_name': terminalName,
        'route_id': _assignedRouteId,
        'active_loading_vehicle': nextLoading,
        'queued_vehicles': newQueue,
        'standby_staged_vehicles': newStandby,
        'last_dispatched_time': FieldValue.serverTimestamp(),
        // Boarding timer restarts for whoever moves up to Spot 1.
        if (_autoDispatchOnFullOrTimer)
          'boarding_started_at': nextLoading != 'None'
              ? FieldValue.serverTimestamp()
              : FieldValue.delete(),
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      final vehicleRef = FirebaseFirestore.instance
          .collection('vehicles_live')
          .doc(activeVehicleId);
      batch.set(vehicleRef, {
        'current_status': 'EN_ROUTE',
        'is_dispatched': true,
        'visible_to_commuters': true,
        'passenger_count': passengerCount,
        'route_id': _assignedRouteId,
        'transit_tag': null,
        'dispatched_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      final logRef = FirebaseFirestore.instance
          .collection('dispatch_logs')
          .doc();
      batch.set(logRef, {
        'log_id': logRef.id,
        'vehicle_id': activeVehicleId,
        'terminal_id': _assignedTerminalId,
        'terminal_name': terminalName,
        'route_id': _assignedRouteId,
        'dispatcher_id': widget.userId,
        'dispatcher_name': widget.userData['full_name'] ?? 'Dispatcher',
        'passenger_count': passengerCount,
        'dispatched_at': FieldValue.serverTimestamp(),
        if (auto) 'auto_dispatched': true,
        if (auto) 'auto_reason': autoReason,
      });

      await batch.commit();
      _showSnackbar(auto
          ? 'Unit $activeVehicleId auto-dispatched (${autoReason == 'FULL' ? 'full' : 'timer ended'}).'
          : 'Unit $activeVehicleId dispatched successfully.');
    } catch (e) {
      debugPrint('Dispatch execution failed: $e');
      _showSnackbar('Dispatch failed: $e', isError: true);
    }
  }

  // ===========================================================================
  // FIRST-COME-FIRST-SERVE WITH TIMER (Sibalom, Belison, Patnongon, Bugasong,
  // San Remigio, Valderrama): MANUAL dispatch only.
  // This tick starts the Spot 1 clock and reminds the dispatcher once when the
  // unit is full or the timer ends. It never dispatches anything by itself.
  // ===========================================================================
  Future<void> _autoDispatchTick() async {
    if (_autoDispatchBusy || !mounted || !_autoDispatchOnFullOrTimer) return;
    _autoDispatchBusy = true;
    try {
      final qRef = FirebaseFirestore.instance
          .collection('terminals_queue')
          .doc(_currentQueueDocId);
      final qData = (await qRef.get()).data();
      if (qData == null) return;
      final active = (qData['active_loading_vehicle'] ?? 'None').toString();
      if (active.isEmpty || active == 'None') return;

      final started = (qData['boarding_started_at'] as Timestamp?)?.toDate();
      if (started == null) {
        // Unit was seated before the timer existed: start its clock now.
        await qRef.set({
          'boarding_started_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        return;
      }

      final v = (await FirebaseFirestore.instance
              .collection('vehicles_live')
              .doc(active)
              .get())
          .data();
      if (v == null) return;
      final pax = (v['passenger_count'] as num?)?.toInt() ?? 0;
      final cap = (v['max_capacity'] as num?)?.toInt() ?? 0;
      final minutes = (qData['dispatch_timer_minutes'] as num?)?.toInt() ??
          (_process?.defaultDispatchTimerMinutes ?? 0);

      final full = cap > 0 && pax >= cap;
      final expired = minutes > 0 &&
          DateTime.now().difference(started) >= Duration(minutes: minutes);
      if (!full && !expired) return;

      // Remind once per unit and state (full / timer ended). The dispatcher
      // dispatches with the DISPATCH JEEPNEY button.
      final key =
          '$active|${started.millisecondsSinceEpoch}|${expired ? 'T' : ''}${full ? 'F' : ''}';
      if (key == _lastDispatchAlertKey) return;
      _lastDispatchAlertKey = key;
      AppTypography.lightFeedback();
      _showSnackbar(expired
          ? 'Boarding timer ended for unit $active. Dispatch it now.'
          : 'Unit $active is full. Dispatch it when ready.');
    } catch (e) {
      debugPrint('Auto-dispatch tick failed: $e');
    } finally {
      _autoDispatchBusy = false;
    }
  }

  Future<void> _setDispatchTimer(int minutes) async {
    try {
      final batch = FirebaseFirestore.instance.batch();
      batch.set(
        FirebaseFirestore.instance
            .collection('terminals_queue')
            .doc(_currentQueueDocId),
        {
          'dispatch_timer_minutes': minutes,
          'updated_at': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      final auditRef =
          FirebaseFirestore.instance.collection('queue_audit_logs').doc();
      batch.set(auditRef, {
        'log_id': auditRef.id,
        'event_type': 'DISPATCH_TIMER_CHANGED',
        'queue_id': _currentQueueDocId,
        'route_id': _assignedRouteId,
        'terminal_id': _assignedTerminalId,
        'dispatcher_id': widget.userId,
        'dispatcher_name': widget.userData['full_name'] ?? 'Dispatcher',
        'new_minutes': minutes,
        'timestamp': FieldValue.serverTimestamp(),
      });
      await batch.commit();
      _showSnackbar('Boarding timer set to $minutes minutes.');
    } catch (e) {
      _showSnackbar('Could not change timer: $e', isError: true);
    }
  }

  // Cards shown above Spot 1 for routes that are not the two-group process.
  List<Widget> _buildProcessCards(
    Map<String, dynamic> qData,
    String activeLoading,
    List<String> queuedList,
  ) {
    final p = _process;
    final cards = <Widget>[];
    if (p == null || p.isFcfs && !p.autoDispatchOnFullOrTimer) {
      cards.add(_processInfoCard(
          'First come, first serve. Units are queued in the order you scan them.'));
    }
    if (p != null && p.isScheduled) {
      cards.add(ScheduleBoardCard(
        process: p,
        rotation: _rotation,
        presentUnits: {
          if (activeLoading != 'None' && activeLoading.isNotEmpty) activeLoading,
          ...queuedList,
        },
      ));
    }
    if (p != null && p.autoDispatchOnFullOrTimer) {
      cards.add(DispatchTimerCard(
        queueData: qData,
        defaultMinutes: p.defaultDispatchTimerMinutes,
        activeVehicleId: activeLoading,
        onChangeTimer: _setDispatchTimer,
      ));
    }
    return [
      for (final c in cards) ...[c, const SizedBox(height: 12)],
    ];
  }

  Widget _processInfoCard(String text) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12.5, height: 1.35, color: AppColors.darkSlate)),
      );

  String _queueChipLabel(String activeGroup) {
    final p = _process;
    if (p == null || p.isFcfs) return 'FIRST COME • FIRST SERVE';
    if (p.isScheduled) return 'SCHEDULED';
    return _isRobinsonsTerminal
        ? 'ROBINSONS ACTIVE'
        : '$activeGroup • DALIPE DIRECT';
  }

  // ===========================================================================
  // NOTICES & MEMOS INBOX MODAL (PAST BROADCASTS & INDIVIDUAL NOTICES)
  // ===========================================================================
  void _showNoticesInboxModal(BuildContext context, String coopId) {
    AppTypography.lightFeedback();

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => SafeArea(
        child: Dialog(
          backgroundColor: Colors.white,
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 600),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.mark_email_read_outlined,
                            color: AppColors.primaryNavy,
                            size: 22,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Cooperative Notices & Memos',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppColors.darkSlate,
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 20,
                          color: AppColors.textMuted,
                        ),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: AppColors.borderSubtle),
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('notices')
                        .orderBy('created_at', descending: true)
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(
                          child: CircularProgressIndicator(
                            color: AppColors.commuterTeal,
                          ),
                        );
                      }

                      final userId = widget.userId.trim().toLowerCase();
                      final docs =
                          snapshot.data?.docs.where((doc) {
                            final n = doc.data() as Map<String, dynamic>;
                            final nCoop = (n['cooperative_id'] ?? '')
                                .toString()
                                .trim();
                            if (nCoop.isNotEmpty &&
                                coopId.isNotEmpty &&
                                nCoop != coopId)
                              return false;

                            final targetMode =
                                (n['target_mode'] ?? 'BROADCAST_ALL')
                                    .toString();
                            if (targetMode == 'BROADCAST_ALL' ||
                                targetMode == 'BROADCAST_DISPATCHERS') {
                              return true;
                            }
                            if (targetMode == 'INDIVIDUAL') {
                              return (n['target_user_id'] ?? '')
                                      .toString()
                                      .trim()
                                      .toLowerCase() ==
                                  userId;
                            }
                            return false;
                          }).toList() ??
                          [];

                      if (docs.isEmpty) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32.0),
                            child: Text(
                              'No broadcast notices or memos recorded yet.',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                        );
                      }

                      return ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: docs.length,
                        itemBuilder: (context, index) {
                          final n = docs[index].data() as Map<String, dynamic>;
                          final isUrgent =
                              (n['priority'] ?? '').toString().toUpperCase() ==
                              'URGENT';
                          final isDirect = n['target_mode'] == 'INDIVIDUAL';
                          final title = (n['title'] ?? 'Notice').toString();
                          final message = (n['message'] ?? '').toString();
                          final author =
                              (n['author_name'] ?? 'Operations Office')
                                  .toString();
                          final Timestamp? ts = n['created_at'] as Timestamp?;
                          final dateStr = ts != null
                              ? ts.toDate().toLocal().toString().substring(
                                  0,
                                  16,
                                )
                              : 'Recent';

                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: isUrgent
                                  ? const Color(0xFFFEF2F2)
                                  : const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isUrgent
                                    ? const Color(0xFFFECACA)
                                    : AppColors.borderSubtle,
                                width: 1.2,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isUrgent
                                            ? const Color(0xFFFEE2E2)
                                            : const Color(0xFFEFF6FF),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        isDirect ? 'DIRECT MEMO' : 'BROADCAST',
                                        style: TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w900,
                                          color: isUrgent
                                              ? const Color(0xFF991B1B)
                                              : const Color(0xFF1D4ED8),
                                        ),
                                      ),
                                    ),
                                    Text(
                                      dateStr,
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  title,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: isUrgent
                                        ? const Color(0xFF7F1D1D)
                                        : AppColors.darkSlate,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  message,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    height: 1.35,
                                    color: AppColors.darkSlate,
                                  ),
                                ),
                                const Divider(
                                  height: 16,
                                  color: AppColors.borderSubtle,
                                ),
                                Text(
                                  'Issued by: $author',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                const Divider(height: 1, color: AppColors.borderSubtle),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: SizedBox(
                    width: double.infinity,
                    height: 40,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppColors.borderSubtle),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text(
                        'Close Inbox',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: AppColors.darkSlate,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // REORDER QUEUE / STANDBY MODAL
  // ===========================================================================
  void _showReorderListModal({
    required String targetDocId,
    required String targetFieldName,
    required String listTitle,
    required List<String> currentList,
  }) {
    AppTypography.lightFeedback();
    List<String> tempList = List.from(currentList);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (modalCtx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return _ts(
              context,
              SafeArea(
                maintainBottomViewPadding: true,
                child: Dialog(
                  backgroundColor: Colors.white,
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  insetPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 24,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 420,
                      maxHeight: _dialogMaxHeight(context, 520),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(7),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryNavy.withOpacity(
                                    0.08,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(
                                  Icons.swap_vert_rounded,
                                  color: AppColors.primaryNavy,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Reorder $listTitle',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTypography.outdoorHeading(
                                        fontSize: 15.5,
                                      ),
                                    ),
                                    Text(
                                      'Move slots up or down • Changes are audited',
                                      style: AppTypography.outdoorBody(
                                        fontSize: 12,
                                        fontWeight: FontWeight.normal,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.close_rounded,
                                  size: 20,
                                  color: AppColors.textMuted,
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () => Navigator.pop(modalCtx),
                              ),
                            ],
                          ),
                          const Divider(
                            height: 20,
                            color: AppColors.borderSubtle,
                          ),

                          if (tempList.isEmpty)
                            Expanded(
                              child: Center(
                                child: Text(
                                  'No vehicles currently in this line.',
                                  textAlign: TextAlign.center,
                                  style: AppTypography.outdoorBody(
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            )
                          else
                            Expanded(
                              child: ListView.builder(
                                itemCount: tempList.length,
                                itemBuilder: (context, index) {
                                  final unit = tempList[index];
                                  return FutureBuilder<DocumentSnapshot>(
                                    future: FirebaseFirestore.instance
                                        .collection('vehicles_live')
                                        .doc(unit)
                                        .get(),
                                    builder: (context, snapshot) {
                                      final vData =
                                          snapshot.data?.data()
                                              as Map<String, dynamic>?;
                                      final plate =
                                          (vData?['plate_number'] ?? unit)
                                              .toString();
                                      final jeepName =
                                          (vData?['vehicle_name'] ?? plate)
                                              .toString();

                                      return Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppColors.backgroundSlate,
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          border: Border.all(
                                            color: AppColors.borderSubtle,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            CircleAvatar(
                                              radius: 11,
                                              backgroundColor:
                                                  AppColors.primaryNavy,
                                              child: Text(
                                                '${index + 1}',
                                                style: const TextStyle(
                                                  fontSize: 11.5,
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    jeepName,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style:
                                                        AppTypography.outdoorHeading(
                                                          fontSize: 13.5,
                                                        ),
                                                  ),
                                                  _rotationBadge(
                                                    unit,
                                                    line: tempList,
                                                  ),
                                                  Text(
                                                    plate,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style:
                                                        AppTypography.outdoorBody(
                                                          fontSize: 11.5,
                                                          fontWeight:
                                                              FontWeight.normal,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.arrow_upward_rounded,
                                                size: 18,
                                              ),
                                              padding: const EdgeInsets.all(6),
                                              constraints:
                                                  const BoxConstraints(),
                                              onPressed: index > 0
                                                  ? () {
                                                      AppTypography.selectionFeedback();
                                                      setModalState(() {
                                                        final item = tempList
                                                            .removeAt(index);
                                                        tempList.insert(
                                                          index - 1,
                                                          item,
                                                        );
                                                      });
                                                    }
                                                  : null,
                                            ),
                                            const SizedBox(width: 4),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.arrow_downward_rounded,
                                                size: 18,
                                              ),
                                              padding: const EdgeInsets.all(6),
                                              constraints:
                                                  const BoxConstraints(),
                                              onPressed:
                                                  index < tempList.length - 1
                                                  ? () {
                                                      AppTypography.selectionFeedback();
                                                      setModalState(() {
                                                        final item = tempList
                                                            .removeAt(index);
                                                        tempList.insert(
                                                          index + 1,
                                                          item,
                                                        );
                                                      });
                                                    }
                                                  : null,
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                          const SizedBox(height: 12),

                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primaryNavy,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed:
                                tempList.isEmpty ||
                                    _listsEqual(currentList, tempList)
                                ? null
                                : () async {
                                    Navigator.pop(modalCtx);
                                    await _promptAuditReasonAndSave(
                                      targetDocId: targetDocId,
                                      targetFieldName: targetFieldName,
                                      previousOrder: currentList,
                                      newOrder: tempList,
                                    );
                                  },
                            child: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                'Save Order & Log Reason',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  bool _listsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _promptAuditReasonAndSave({
    required String targetDocId,
    required String targetFieldName,
    required List<String> previousOrder,
    required List<String> newOrder,
  }) async {
    final reasonController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ts(
        ctx,
        AlertDialog(
          scrollable: true,
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Row(
            children: [
              Icon(Icons.security_rounded, color: Color(0xFFF59E0B), size: 18),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Audit Transparency Log',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.darkSlate,
                  ),
                ),
              ),
            ],
          ),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Please enter the operational reason for reordering this queue line-up:',
                  style: AppTypography.outdoorBody(fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: reasonController,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'e.g. Mechanical inspection, tire puncture, driver shift...',
                    hintStyle: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textMuted,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.all(10),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Operational reason is required'
                      : null,
                ),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text(
                'Cancel',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryNavy,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text(
                'Record & Apply',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    try {
      final Set<String> movedVehicles = {};
      for (int i = 0; i < newOrder.length; i++) {
        if (i >= previousOrder.length || newOrder[i] != previousOrder[i]) {
          movedVehicles.add(newOrder[i]);
        }
      }
      for (int i = 0; i < previousOrder.length; i++) {
        final oldIndex = i;
        final newIndex = newOrder.indexOf(previousOrder[i]);
        if (oldIndex != newIndex) {
          movedVehicles.add(previousOrder[i]);
        }
      }

      final unitsToInspect = movedVehicles.isNotEmpty
          ? movedVehicles
          : newOrder.toSet();

      final Set<String> affectedCoopIds = {};
      final Set<String> affectedCoopNames = {};

      for (final vId in unitsToInspect) {
        final vDoc = await FirebaseFirestore.instance
            .collection('vehicles_live')
            .doc(vId)
            .get();
        if (vDoc.exists && vDoc.data() != null) {
          final cId = (vDoc.data()!['cooperative_id'] ?? '').toString().trim();
          final cName = (vDoc.data()!['cooperative_name'] ?? '')
              .toString()
              .trim();
          if (cId.isNotEmpty) affectedCoopIds.add(cId);
          if (cName.isNotEmpty) affectedCoopNames.add(cName);
        }
      }

      final batch = FirebaseFirestore.instance.batch();

      final queueRef = FirebaseFirestore.instance
          .collection('terminals_queue')
          .doc(targetDocId);
      batch.update(queueRef, {
        targetFieldName: newOrder,
        'updated_at': FieldValue.serverTimestamp(),
      });

      final auditRef = FirebaseFirestore.instance
          .collection('queue_audit_logs')
          .doc();
      batch.set(auditRef, {
        'log_id': auditRef.id,
        'queue_id': targetDocId,
        'route_id': _assignedRouteId,
        'terminal_id': _assignedTerminalId,
        'dispatcher_id': widget.userId,
        'dispatcher_name': widget.userData['full_name'] ?? 'Dispatcher',
        'previous_order': previousOrder,
        'new_order': newOrder,
        'affected_vehicles': unitsToInspect.toList(),
        'affected_cooperative_ids': affectedCoopIds.toList(),
        'affected_cooperative_names': affectedCoopNames.toList(),
        'reason': reasonController.text.trim(),
        'timestamp': FieldValue.serverTimestamp(),
      });

      await batch.commit();
      _showSnackbar('Queue reordered and transparency log generated.');
    } catch (e) {
      _showSnackbar('Failed to apply reordering: $e', isError: true);
    }
  }

  // ===========================================================================
  // FULL-SCREEN EXPANDED MAP DIALOG
  // ===========================================================================
  void _openFullMapDialog({required String initialFocusVehicleId}) {
    AppTypography.lightFeedback();
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (fullMapCtx) {
        bool showAllRouteJeeps = false;
        bool showRoutePoly = true;

        final start = _getTerminalCoordinates();
        final end = _getDestinationCoordinates();
        final defaultCenter = LatLng(
          (start.latitude + end.latitude) / 2,
          (start.longitude + end.longitude) / 2,
        );

        return StatefulBuilder(
          builder: (context, setMapState) {
            return _ts(
              context,
              Dialog.fullscreen(
                child: Scaffold(
                  backgroundColor: AppColors.backgroundSlate,
                  appBar: AppBar(
                    backgroundColor: AppColors.primaryNavy,
                    elevation: 1,
                    leading: IconButton(
                      icon: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                      ),
                      onPressed: () => Navigator.pop(fullMapCtx),
                    ),
                    title: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_formatRouteName(_assignedRouteId)} Live Map',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          showAllRouteJeeps
                              ? 'Displaying active & en-route units on this route'
                              : 'Focused unit: $initialFocusVehicleId',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  body: Stack(
                    children: [
                      StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('vehicles_live')
                            .where('route_id', isEqualTo: _assignedRouteId)
                            .snapshots(),
                        builder: (context, snapshot) {
                          final allDocs = snapshot.data?.docs ?? [];

                          final validDocs = allDocs.where((d) {
                            final data = d.data() as Map<String, dynamic>;
                            final status = (data['current_status'] ?? '')
                                .toString()
                                .toUpperCase();
                            final isVisible =
                                data['visible_to_commuters'] == true;
                            final isDispatched = data['is_dispatched'] == true;

                            return status == 'EN_ROUTE' &&
                                (isVisible || isDispatched);
                          }).toList();

                          final markers = <Marker>[];

                          for (var doc in validDocs) {
                            if (!showAllRouteJeeps &&
                                doc.id != initialFocusVehicleId) {
                              continue;
                            }

                            final data = doc.data() as Map<String, dynamic>;
                            final vehicleId = doc.id;
                            final plate = (data['plate_number'] ?? vehicleId)
                                .toString();
                            final jeepName = (data['vehicle_name'] ?? plate)
                                .toString();
                            final speed =
                                (data['speed_kmh'] as num?)?.toInt() ?? 0;
                            final Color dotColor = _resolveVehicleDotColor(
                              data['vehicle_color']?.toString(),
                            );
                            final transitTag = (data['transit_tag'] ?? '')
                                .toString();
                            final isArrivingToRob = transitTag
                                .toLowerCase()
                                .contains('robinson');

                            final loc =
                                data['location'] as Map<String, dynamic>?;
                            double? lat;
                            double? lng;

                            if (loc != null &&
                                loc['latitude'] != null &&
                                loc['longitude'] != null) {
                              lat = (loc['latitude'] as num).toDouble();
                              lng = (loc['longitude'] as num).toDouble();
                            } else if (data['latitude'] != null &&
                                data['longitude'] != null) {
                              lat = (data['latitude'] as num).toDouble();
                              lng = (data['longitude'] as num).toDouble();
                            }

                            if (lat != null && lng != null) {
                              markers.add(
                                Marker(
                                  point: LatLng(lat, lng),
                                  width: 190,
                                  height: 52,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isArrivingToRob
                                              ? const Color(0xFF2563EB)
                                              : AppColors.primaryNavy
                                                    .withOpacity(0.92),
                                          borderRadius: BorderRadius.circular(
                                            5,
                                          ),
                                          border: Border.all(
                                            color: isArrivingToRob
                                                ? Colors.amberAccent
                                                : Colors.white70,
                                            width: 1.0,
                                          ),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Colors.black26,
                                              blurRadius: 3,
                                            ),
                                          ],
                                        ),
                                        child: Text(
                                          isArrivingToRob
                                              ? '$jeepName • Arriving to Rob'
                                              : '$jeepName • $speed km/h',
                                          maxLines: 1,
                                          softWrap: false,
                                          overflow: TextOverflow.ellipsis,
                                          textScaler: TextScaler.noScaling,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Container(
                                            width: 22,
                                            height: 22,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: dotColor.withOpacity(0.28),
                                            ),
                                          ),
                                          Container(
                                            width: 14,
                                            height: 14,
                                            decoration: BoxDecoration(
                                              color: dotColor,
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: Colors.white,
                                                width: 2,
                                              ),
                                              boxShadow: const [
                                                BoxShadow(
                                                  color: Colors.black38,
                                                  blurRadius: 3,
                                                  offset: Offset(0, 1),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }
                          }

                          return FlutterMap(
                            options: MapOptions(
                              initialCenter: defaultCenter,
                              initialZoom: 12.5,
                            ),
                            children: [
                              TileLayer(
                                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                userAgentPackageName:
                                    'com.example.puj_dispatch_system',
                              ),
                              PolylineLayer(
                                polylines: [
                                  if (showRoutePoly &&
                                      _roadPolylinePoints.isNotEmpty)
                                    Polyline(
                                      points: _roadPolylinePoints,
                                      color: AppColors.primaryNavy.withOpacity(
                                        0.85,
                                      ),
                                      strokeWidth: 4.0,
                                      borderColor: AppColors.commuterTeal,
                                      borderStrokeWidth: 1.5,
                                    ),
                                ],
                              ),
                              MarkerLayer(markers: markers),
                            ],
                          );
                        },
                      ),

                      Positioned(
                        top: 12,
                        left: 12,
                        right: 12,
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            ElevatedButton.icon(
                              icon: Icon(
                                showAllRouteJeeps
                                    ? Icons.filter_alt_rounded
                                    : Icons.directions_bus_rounded,
                                size: 14,
                              ),
                              label: Text(
                                showAllRouteJeeps
                                    ? 'Focus Unit'
                                    : 'All Route Units',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: showAllRouteJeeps
                                    ? const Color(0xFF2563EB)
                                    : Colors.white,
                                foregroundColor: showAllRouteJeeps
                                    ? Colors.white
                                    : AppColors.darkSlate,
                                elevation: 3,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  side: BorderSide(
                                    color: showAllRouteJeeps
                                        ? const Color(0xFF1D4ED8)
                                        : AppColors.borderSubtle,
                                  ),
                                ),
                              ),
                              onPressed: () {
                                AppTypography.lightFeedback();
                                setMapState(
                                  () => showAllRouteJeeps = !showAllRouteJeeps,
                                );
                              },
                            ),
                            ElevatedButton.icon(
                              icon: Icon(
                                showRoutePoly
                                    ? Icons.alt_route_rounded
                                    : Icons.visibility_off_outlined,
                                size: 14,
                              ),
                              label: Text(
                                showRoutePoly ? 'Hide Route' : 'Show Route',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: showRoutePoly
                                    ? AppColors.primaryNavy
                                    : Colors.white,
                                foregroundColor: showRoutePoly
                                    ? Colors.white
                                    : AppColors.darkSlate,
                                elevation: 3,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  side: BorderSide(
                                    color: showRoutePoly
                                        ? AppColors.commuterTeal
                                        : AppColors.borderSubtle,
                                  ),
                                ),
                              ),
                              onPressed: () {
                                AppTypography.lightFeedback();
                                setMapState(
                                  () => showRoutePoly = !showRoutePoly,
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ===========================================================================
  // UNIT MANAGEMENT CENTERED MODAL
  // ===========================================================================
  void _showUnitActionsModal({
    required String vehicleId,
    required String targetDocId,
    required String targetFieldName,
    required bool isStandby,
    required int position,
  }) {
    AppTypography.lightFeedback();
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (modalCtx) => _ts(
        modalCtx,
        Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 420,
              maxHeight: _dialogMaxHeight(modalCtx, 720),
            ),
            child: StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('vehicles_live')
                  .doc(vehicleId)
                  .snapshots(),
              builder: (context, snapshot) {
                final vData = snapshot.data?.data() as Map<String, dynamic>?;
                final plate = (vData?['plate_number'] ?? vehicleId).toString();
                final jeepName = (vData?['vehicle_name'] ?? plate).toString();
                final driverName = (vData?['driver_name'] ?? 'Assigned Driver')
                    .toString();
                final speed = (vData?['speed_kmh'] as num?)?.toInt() ?? 0;
                final passCount =
                    (vData?['passenger_count'] as num?)?.toInt() ?? 0;
                final maxCap = (vData?['max_capacity'] as num?)?.toInt() ?? 20;
                final Color dotColor = _resolveVehicleDotColor(
                  vData?['vehicle_color']?.toString(),
                );
                final transitTag = (vData?['transit_tag'] ?? '').toString();

                final loc = vData?['location'] as Map<String, dynamic>?;
                double? lat;
                double? lng;

                if (loc != null &&
                    loc['latitude'] != null &&
                    loc['longitude'] != null) {
                  lat = (loc['latitude'] as num).toDouble();
                  lng = (loc['longitude'] as num).toDouble();
                } else if (vData?['latitude'] != null &&
                    vData?['longitude'] != null) {
                  lat = (vData!['latitude'] as num).toDouble();
                  lng = (vData['longitude'] as num).toDouble();
                }

                final unitCoord = (lat != null && lng != null)
                    ? LatLng(lat, lng)
                    : _getTerminalCoordinates();

                return SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    jeepName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTypography.outdoorHeading(
                                      fontSize: 17,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      _buildLicenseBadge(plate, fontSize: 12.5),
                                      const SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          isStandby
                                              ? 'Standby • Slot #$position'
                                              : 'On-Deck • Slot #$position',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppTypography.outdoorBody(
                                            fontSize: 12,
                                            fontWeight: FontWeight.normal,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.close_rounded,
                                size: 20,
                                color: AppColors.textMuted,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => Navigator.pop(modalCtx),
                            ),
                          ],
                        ),
                        const Divider(
                          height: 18,
                          color: AppColors.borderSubtle,
                        ),

                        if (transitTag.isNotEmpty) ...[
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: const Color(0xFF2563EB),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.directions_transit_filled_rounded,
                                  size: 14,
                                  color: Color(0xFF2563EB),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'STATUS: $transitTag',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF1E40AF),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        Container(
                          height: (MediaQuery.of(context).size.height * 0.2)
                              .clamp(120.0, 200.0)
                              .toDouble(),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.borderSubtle),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            children: [
                              FlutterMap(
                                options: MapOptions(
                                  initialCenter: unitCoord,
                                  initialZoom: 13.5,
                                ),
                                children: [
                                  TileLayer(
                                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                    userAgentPackageName:
                                        'com.example.puj_dispatch_system',
                                  ),
                                  MarkerLayer(
                                    markers: [
                                      Marker(
                                        point: unitCoord,
                                        width: 32,
                                        height: 32,
                                        child: Stack(
                                          alignment: Alignment.center,
                                          children: [
                                            Container(
                                              width: 28,
                                              height: 28,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: dotColor.withOpacity(
                                                  0.3,
                                                ),
                                              ),
                                            ),
                                            Container(
                                              width: 14,
                                              height: 14,
                                              decoration: BoxDecoration(
                                                color: dotColor,
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: Colors.white,
                                                  width: 2,
                                                ),
                                                boxShadow: const [
                                                  BoxShadow(
                                                    color: Colors.black38,
                                                    blurRadius: 3,
                                                    offset: Offset(0, 1),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              Positioned(
                                bottom: 6,
                                right: 6,
                                child: ElevatedButton.icon(
                                  icon: const Icon(
                                    Icons.open_in_full_rounded,
                                    size: 12,
                                  ),
                                  label: const Text(
                                    'View Full Map',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.primaryNavy,
                                    foregroundColor: Colors.white,
                                    elevation: 2,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 9,
                                      vertical: 5,
                                    ),
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: () {
                                    Navigator.pop(modalCtx);
                                    _openFullMapDialog(
                                      initialFocusVehicleId: vehicleId,
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),

                        // Passenger Seating Adjuster Bar in Modal
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0FDF4),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFF86EFAC)),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.airline_seat_recline_normal_rounded,
                                size: 16,
                                color: Color(0xFF059669),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Seats: $passCount / $maxCap',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: passCount >= maxCap
                                        ? AppColors.errorCrimson
                                        : const Color(0xFF065F46),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              SizedBox(
                                height: 28,
                                width: 34,
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    side: const BorderSide(
                                      color: Color(0xFF059669),
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                  ),
                                  onPressed: passCount > 0
                                      ? () => _adjustPassengerCount(
                                          vehicleId,
                                          passCount,
                                          maxCap,
                                          -1,
                                        )
                                      : null,
                                  child: const Icon(
                                    Icons.remove_rounded,
                                    size: 16,
                                    color: Color(0xFF059669),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              SizedBox(
                                height: 28,
                                width: 34,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    backgroundColor: const Color(0xFF059669),
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                  ),
                                  onPressed: passCount < maxCap
                                      ? () => _adjustPassengerCount(
                                          vehicleId,
                                          passCount,
                                          maxCap,
                                          1,
                                        )
                                      : null,
                                  child: const Icon(
                                    Icons.add_rounded,
                                    size: 16,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),

                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.backgroundSlate,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  'Driver: $driverName',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.outdoorBody(
                                    fontSize: 12.5,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Speed: $speed km/h',
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF059669),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),

                        ElevatedButton.icon(
                          icon: const Icon(
                            Icons.notifications_active_rounded,
                            size: 17,
                          ),
                          label: const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'ALERT / CALL DRIVER PHONE',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF059669),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            elevation: 0,
                          ),
                          onPressed: () async {
                            Navigator.pop(modalCtx);
                            await _triggerDriverPhoneAlarm(vehicleId);
                          },
                        ),
                        const SizedBox(height: 8),

                        OutlinedButton.icon(
                          icon: const Icon(
                            Icons.person_remove_rounded,
                            size: 16,
                            color: AppColors.errorCrimson,
                          ),
                          label: const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'Remove Unit from Line-Up',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: AppColors.errorCrimson,
                              ),
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                              color: AppColors.errorCrimson,
                              width: 1.1,
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onPressed: () async {
                            Navigator.pop(modalCtx);
                            await _confirmAndRemoveUnit(
                              vehicleId: vehicleId,
                              targetDocId: targetDocId,
                              targetFieldName: targetFieldName,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _triggerDriverPhoneAlarm(String vehicleId) async {
    try {
      await FirebaseFirestore.instance
          .collection('vehicles_live')
          .doc(vehicleId)
          .set({
            'called_by_robinsons': true,
            'driver_alert': {
              'type': 'CALL_TO_ROBINSONS',
              'title': 'DISPATCH ALERT: PROCEED TO ROBINSONS',
              'message': 'Robinsons Terminal is calling you! Drive from Dalipe to Robinsons now.',
              'caller_name': widget.userData['full_name'] ?? 'Dispatcher',
              'is_active': true,
              'timestamp': FieldValue.serverTimestamp(),
            },
          }, SetOptions(merge: true));

      _showSnackbar(
        'Phone alarm triggered on driver\'s device for $vehicleId!',
      );
    } catch (e) {
      _showSnackbar('Failed to trigger alarm: $e', isError: true);
    }
  }

  Future<void> _confirmAndRemoveUnit({
    required String vehicleId,
    required String targetDocId,
    required String targetFieldName,
  }) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ts(
        ctx,
        AlertDialog(
          scrollable: true,
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            'Remove $vehicleId?',
            style: AppTypography.outdoorHeading(fontSize: 17),
          ),
          content: Text(
            'This unit will be taken off this queue list and will need to scan in again to rejoin.',
            style: AppTypography.outdoorBody(fontSize: 13.5),
          ),
          actionsPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.errorCrimson,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'Remove Unit',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;

    try {
      final queueRef = FirebaseFirestore.instance
          .collection('terminals_queue')
          .doc(targetDocId);
      await queueRef.update({
        targetFieldName: FieldValue.arrayRemove([vehicleId]),
        'updated_at': FieldValue.serverTimestamp(),
      });

      _showSnackbar('Unit $vehicleId removed from line-up.');
    } catch (e) {
      _showSnackbar('Removal failed: $e', isError: true);
    }
  }

  // ===========================================================================
  // DRIVER CHECK-IN QR CODE SCANNER MODAL
  // ===========================================================================
  void _openQrScannerModal() {
    AppTypography.lightFeedback();
    bool hasProcessed = false;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (sheetCtx) => _ts(
        sheetCtx,
        Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 420,
              maxHeight: MediaQuery.of(context).size.height * 0.75,
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'Scan Driver Check-In Pass',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.outdoorHeading(fontSize: 16),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 20,
                          color: AppColors.textMuted,
                        ),
                        onPressed: () => Navigator.pop(sheetCtx),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: AppColors.borderSubtle),
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(18),
                    ),
                    child: MobileScanner(
                      onDetect: (capture) async {
                        if (hasProcessed) return;
                        final List<Barcode> barcodes = capture.barcodes;
                        if (barcodes.isEmpty) return;

                        final raw = barcodes.first.rawValue;
                        if (raw == null) return;

                        hasProcessed = true;
                        Navigator.pop(sheetCtx);

                        await _processScannedCheckIn(raw);
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    'Point camera at the driver\'s Terminal Check-In QR Code',
                    textAlign: TextAlign.center,
                    style: AppTypography.outdoorBody(
                      fontSize: 13,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _processScannedCheckIn(String rawPayload) async {
    try {
      final Map<String, dynamic> data = jsonDecode(rawPayload);

      if (data['type'] != 'TERMINAL_CHECK_IN') {
        _showSnackbar(
          'Invalid QR code: Not a valid driver entry pass.',
          isError: true,
        );
        return;
      }

      final vehicleId = data['vehicle_id']?.toString().trim();
      final driverId = data['driver_id']?.toString().trim();
      final driverName = data['driver_name']?.toString().trim() ?? 'Driver';
      final scannedToken = data['token']?.toString().trim();

      if (vehicleId == null ||
          vehicleId.isEmpty ||
          driverId == null ||
          scannedToken == null) {
        _showSnackbar('Pass error: Incomplete QR credentials.', isError: true);
        return;
      }

      final queueRef = FirebaseFirestore.instance
          .collection('terminals_queue')
          .doc(_currentQueueDocId);
      final dalipeQueueRef = FirebaseFirestore.instance
          .collection('terminals_queue')
          .doc(_dalipeQueueDocId);
      final vehicleRef = FirebaseFirestore.instance
          .collection('vehicles_live')
          .doc(vehicleId);
      final driverRef = FirebaseFirestore.instance
          .collection('users')
          .doc(driverId);

      // ─────────────────────────────────────────────────────────────
      // ROBINSONS OVERRIDE GATEKEEPER (BEFORE TRANSACTION)
      // ─────────────────────────────────────────────────────────────
      bool isOverride = false;
      String overrideReason = '';

      // Suspended drivers cannot queue. Checked here first so the dispatcher
      // is not asked to authorize an override for a driver who will be
      // rejected anyway; checked again inside the transaction below.
      final preDriverSnap = await driverRef.get();
      final preSusp = DriverSuspension.fromUser(preDriverSnap.data());
      if (preSusp.active) {
        _showSnackbar(
          'Entry blocked: $driverName is suspended. ${preSusp.message}',
          isError: true,
        );
        return;
      }

      if (_isRobinsonsTerminal && _requiresRobinsonsCall) {
        final preSnap = await vehicleRef.get();
        final preVData = preSnap.data() as Map<String, dynamic>?;
        final wasCalled = preVData?['called_by_robinsons'] == true;

        if (!wasCalled) {
          final authorized = await _promptRobinsonsOverrideConfirmation(
            vehicleId: vehicleId,
            driverName: driverName,
            violationMessage:
                'Unit arrived at Robinsons without being officially called from Dalipe terminal.',
          );

          if (authorized != true) {
            _showSnackbar(
              'Entry rejected: Unit was not called from Dalipe.',
              isError: true,
            );
            return;
          }

          isOverride = true;
          overrideReason = 'Dispatcher authorized uncalled arrival at Robinsons.';
        }
      }

      String feedbackMessage = '';

      // RUN EVERYTHING ATOMICALLY INSIDE ONE TRANSACTION
      await FirebaseFirestore.instance.runTransaction((transaction) async {
        // 1. Read & Validate Driver Document Inside Transaction
        final driverSnap = await transaction.get(driverRef);
        if (!driverSnap.exists) {
          throw 'Driver record ($driverId) not found in system.';
        }
        final uData = driverSnap.data() as Map<String, dynamic>;
        final activeToken = uData['qr_token']?.toString().trim();
        final Timestamp? expiresTs = uData['qr_expires_at'] as Timestamp?;

        if (activeToken == null || activeToken != scannedToken) {
          throw 'Pass expired or already scanned. Please generate a new pass.';
        }
        if (expiresTs != null && DateTime.now().isAfter(expiresTs.toDate())) {
          throw 'Pass has expired (validity exceeded 30 minutes).';
        }

        // Check: a suspended driver may not enter any queue.
        final susp = DriverSuspension.fromUser(uData);
        if (susp.active) {
          throw '$driverName is suspended. ${susp.message}';
        }

        // Check: Daily pre-trip (B.L.O.W.B.A.G.E.T.S.) must be completed TODAY.
        final now = DateTime.now();
        final todayKey =
            '${now.year.toString().padLeft(4, '0')}-'
            '${now.month.toString().padLeft(2, '0')}-'
            '${now.day.toString().padLeft(2, '0')}';
        if ((uData['pretrip_date'] ?? '').toString() != todayKey) {
          throw 'Pre-trip check not completed today. $driverName must finish the B.L.O.W.B.A.G.E.T.S. checklist before entering the queue.';
        }

        // 2. Read & Validate Vehicle Document Inside Transaction
        final vehicleSnap = await transaction.get(vehicleRef);
        if (!vehicleSnap.exists) {
          throw 'Unauthorized: Unit "$vehicleId" not found in active fleet.';
        }
        final vData = vehicleSnap.data() as Map<String, dynamic>;

        if (vData['driver_id'] != driverId &&
            uData['assigned_vehicle'] != vehicleId) {
          throw 'Driver $driverName is not registered to vehicle $vehicleId!';
        }

        final registeredRoute = (vData['route_id'] ?? '').toString().trim();
        if (registeredRoute != _assignedRouteId) {
          throw 'Route Mismatch! Unit belongs to ${_formatRouteName(registeredRoute)}, not ${_formatRouteName(_assignedRouteId)}.';
        }

        // 3. Read & Validate Queue Document
        final qSnap = await transaction.get(queueRef);
        final qDocData = qSnap.exists
            ? (qSnap.data() as Map<String, dynamic>)
            : <String, dynamic>{};
        final activeUnit = qDocData['active_loading_vehicle']?.toString();
        final List<String> queued = _parseStringList(
          qDocData['queued_vehicles'],
        );
        final List<String> standby = _parseStringList(
          qDocData['standby_staged_vehicles'],
        );

        if (activeUnit == vehicleId ||
            queued.contains(vehicleId) ||
            standby.contains(vehicleId)) {
          throw 'Unit $vehicleId is already in the terminal queue.';
        }

        // 3b. Master rotation list: is this unit in the group that goes to Robinsons?
        bool stagedForRobinsons = false;
        if (_isDalipeTerminal &&
            _usesDalipeStaging &&
            _rotationCoopId.isNotEmpty) {
          final rotSnap = await transaction.get(
            RotationRepo.ref(_rotationCoopId, _assignedRouteId),
          );
          final rotCfg =
              RotationConfig.fromData(rotSnap.data(), process: _process);
          final unitGroup = rotCfg.groupKeyOf(vehicleId);
          final directGroup = rotCfg.directGroupKey();
          stagedForRobinsons =
              unitGroup != null &&
              directGroup != null &&
              unitGroup != directGroup;
        }

        // 4. Invalidate Driver Token Immediately
        transaction.update(driverRef, {
          'qr_token': null,
          'qr_expires_at': null,
        });

        // 5. Place Vehicle into Bay or Line-up
        if (_isRobinsonsTerminal) {
          final int occupiedSlots =
              (activeUnit != null &&
                      activeUnit != 'None' &&
                      activeUnit.isNotEmpty
                  ? 1
                  : 0) +
              queued.length;
          if (occupiedSlots >= 4) {
            throw 'Robinsons Bay is full (4/4 slots occupied). Unit must wait.';
          }

          if (activeUnit == null ||
              activeUnit == 'None' ||
              activeUnit.isEmpty) {
            transaction.set(queueRef, {
              'active_loading_vehicle': vehicleId,
              if (_autoDispatchOnFullOrTimer)
                'boarding_started_at': FieldValue.serverTimestamp(),
              'updated_at': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            feedbackMessage = 'Unit $vehicleId assigned to Spot 1 Loading Bay!';
          } else {
            transaction.set(queueRef, {
              'queued_vehicles': FieldValue.arrayUnion([vehicleId]),
              'updated_at': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            feedbackMessage =
                'Unit $vehicleId placed in On-Deck Slot #${occupiedSlots + 1}!';
          }

          // Only two-group routes have a Dalipe standby pool to clear.
          if (_requiresRobinsonsCall) {
            transaction.update(dalipeQueueRef, {
              'standby_staged_vehicles': FieldValue.arrayRemove([vehicleId]),
            });
          }

          // LOG OVERRIDE TO QUEUE_AUDIT_LOGS IF UNCALLED
          if (isOverride) {
            final auditRef = FirebaseFirestore.instance
                .collection('queue_audit_logs')
                .doc();
            transaction.set(auditRef, {
              'log_id': auditRef.id,
              'event_type': 'UNCALLED_ROBINSONS_ENTRY_OVERRIDE',
              'queue_id': _currentQueueDocId,
              'route_id': _assignedRouteId,
              'terminal_id': _assignedTerminalId,
              'dispatcher_id': widget.userId,
              'dispatcher_name': widget.userData['full_name'] ?? 'Dispatcher',
              'affected_vehicle': vehicleId,
              'affected_driver': driverName,
              'cooperative_id': vData['cooperative_id'] ?? 'N/A',
              'cooperative_name': vData['cooperative_name'] ?? 'N/A',
              'reason': overrideReason,
              'timestamp': FieldValue.serverTimestamp(),
            });
          }
        } else {
          // Dalipe Terminal
          if (stagedForRobinsons) {
            transaction.set(queueRef, {
              'standby_staged_vehicles': FieldValue.arrayUnion([vehicleId]),
              'updated_at': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            feedbackMessage =
                'Unit $vehicleId placed in Dalipe Standby Pool (Robinsons group)!';
          } else if (activeUnit == null ||
              activeUnit == 'None' ||
              activeUnit.isEmpty) {
            transaction.set(queueRef, {
              'active_loading_vehicle': vehicleId,
              if (_autoDispatchOnFullOrTimer)
                'boarding_started_at': FieldValue.serverTimestamp(),
              'updated_at': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            feedbackMessage = 'Unit $vehicleId assigned to Spot 1 Loading Bay!';
          } else {
            transaction.set(queueRef, {
              'queued_vehicles': FieldValue.arrayUnion([vehicleId]),
              'updated_at': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            feedbackMessage = 'Unit $vehicleId placed in On-Deck Queue!';
          }
        }

        transaction.update(vehicleRef, {
          'current_status': 'STANDBY',
          'speed_kmh': 0,
          'is_dispatched': false,
          'visible_to_commuters': false,
          'staged_at_dalipe': stagedForRobinsons,
          'called_by_robinsons': false,
          'last_pretrip_date': todayKey,
          'updated_at': FieldValue.serverTimestamp(),
        });
      });

      _showSnackbar('$feedbackMessage • Pre-trip verified');
    } catch (e) {
      _showSnackbar('Check-in error: $e', isError: true);
    }
  }

  Future<bool?> _promptRobinsonsOverrideConfirmation({
    required String vehicleId,
    required String driverName,
    required String violationMessage,
  }) async {
    AppTypography.selectionFeedback();
    final reasonController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ts(
        ctx,
        AlertDialog(
          scrollable: true,
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Color(0xFFD97706),
                size: 24,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Unscheduled Arrival',
                  style: AppTypography.outdoorHeading(fontSize: 17),
                ),
              ),
            ],
          ),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFDE68A)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Unit: $vehicleId • $driverName',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Color(0xFF92400E),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        violationMessage,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF78350F),
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Admitting this vehicle requires supervisor authorization and will be permanently logged in the cooperative audit trail.',
                  style: AppTypography.outdoorBody(fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: reasonController,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    labelText: 'Override Reason *',
                    hintText: 'e.g., High passenger surge, urgent dispatch...',
                    hintStyle: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textMuted,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.all(10),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Reason is required for audit'
                      : null,
                ),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text(
                'Reject Entry',
                style: TextStyle(
                  color: AppColors.errorCrimson,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryNavy,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text(
                'Authorize & Record',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _commitRobinsonsEntry({
    required DocumentReference queueRef,
    required DocumentReference dalipeQueueRef,
    required DocumentReference vehicleRef,
    required DocumentReference driverRef,
    required String vehicleId,
    required String driverName,
    required bool isOverride,
    required String overrideReason,
    required Map<String, dynamic> vData,
  }) async {
    String feedback = '';

    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snap = await transaction.get(queueRef);
      final qDocData = snap.exists
          ? (snap.data() as Map<String, dynamic>)
          : <String, dynamic>{};
      final activeUnit = qDocData['active_loading_vehicle']?.toString();
      final List queued = _parseStringList(qDocData['queued_vehicles']);

      if (activeUnit == vehicleId || queued.contains(vehicleId)) {
        throw '$vehicleId is already in the Robinsons terminal line-up.';
      }

      final int occupiedSlots =
          (activeUnit != null && activeUnit != 'None' && activeUnit.isNotEmpty
              ? 1
              : 0) +
          queued.length;
      if (occupiedSlots >= 4) {
        throw 'Robinsons Bay is Full (4/4 slots occupied). Unit must hold.';
      }

      if (activeUnit == null || activeUnit == 'None' || activeUnit.isEmpty) {
        transaction.set(queueRef, {
          'active_loading_vehicle': vehicleId,
          'updated_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        feedback =
            'Unit $vehicleId assigned to Spot 1 Loading Bay at Robinsons.';
      } else {
        transaction.set(queueRef, {
          'queued_vehicles': FieldValue.arrayUnion([vehicleId]),
          'updated_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        feedback =
            'Unit $vehicleId placed in On-Deck Slot #${occupiedSlots + 1} at Robinsons.';
      }

      transaction.update(dalipeQueueRef, {
        'standby_staged_vehicles': FieldValue.arrayRemove([vehicleId]),
      });

      transaction.update(vehicleRef, {
        'current_status': 'STANDBY',
        'speed_kmh': 0,
        'is_dispatched': false,
        'visible_to_commuters': false,
        'route_id': _assignedRouteId,
        'transit_tag': null,
        'staged_at_dalipe': false,
        'called_by_robinsons': false,
        'updated_at': FieldValue.serverTimestamp(),
      });

      transaction.update(driverRef, {'qr_token': null, 'qr_expires_at': null});

      if (isOverride) {
        final auditRef = FirebaseFirestore.instance
            .collection('queue_audit_logs')
            .doc();
        transaction.set(auditRef, {
          'log_id': auditRef.id,
          'event_type': 'UNCALLED_ROBINSONS_ENTRY_OVERRIDE',
          'queue_id': _currentQueueDocId,
          'route_id': _assignedRouteId,
          'terminal_id': _assignedTerminalId,
          'dispatcher_id': widget.userId,
          'dispatcher_name': widget.userData['full_name'] ?? 'Dispatcher',
          'affected_vehicle': vehicleId,
          'affected_driver': driverName,
          'cooperative_id': vData['cooperative_id'] ?? 'N/A',
          'cooperative_name': vData['cooperative_name'] ?? 'N/A',
          'reason': overrideReason,
          'timestamp': FieldValue.serverTimestamp(),
        });
      }
    });

    _showSnackbar(feedback);
  }

  Future<void> _commitStandardEntry({
    required DocumentReference queueRef,
    required DocumentReference dalipeQueueRef,
    required DocumentReference vehicleRef,
    required DocumentReference driverRef,
    required String vehicleId,
    required String driverName,
    required String vehicleGroup,
  }) async {
    String feedbackMessage = '';

    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snap = await transaction.get(queueRef);
      final qDocData = snap.exists
          ? (snap.data() as Map<String, dynamic>)
          : <String, dynamic>{};
      final defaultGroup = _isRobinsonsTerminal ? 'Group 2' : 'Group 1';
      final activeGroup = (qDocData['active_group'] ?? defaultGroup)
          .toString()
          .trim();

      if (_isRobinsonsTerminal) {
        final activeUnit = qDocData['active_loading_vehicle']?.toString();
        final List queued = _parseStringList(qDocData['queued_vehicles']);

        if (activeUnit == vehicleId || queued.contains(vehicleId)) {
          throw '$vehicleId is already checked into Robinsons line-up.';
        }

        final int occupiedSlots =
            (activeUnit != null && activeUnit != 'None' && activeUnit.isNotEmpty
                ? 1
                : 0) +
            queued.length;
        if (occupiedSlots >= 4) {
          throw 'Robinsons Bay is Full (4/4 slots occupied). Unit must wait.';
        }

        if (activeUnit == null || activeUnit == 'None' || activeUnit.isEmpty) {
          transaction.set(queueRef, {
            'active_loading_vehicle': vehicleId,
            'updated_at': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          feedbackMessage =
              'Unit $vehicleId ($driverName) arrived at Robinsons & assigned Spot 1 Bay!';
        } else {
          transaction.set(queueRef, {
            'queued_vehicles': FieldValue.arrayUnion([vehicleId]),
            'updated_at': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          feedbackMessage =
              'Unit $vehicleId ($driverName) arrived at Robinsons & placed in Slot #${occupiedSlots + 1}!';
        }

        transaction.update(dalipeQueueRef, {
          'standby_staged_vehicles': FieldValue.arrayRemove([vehicleId]),
        });

        transaction.update(vehicleRef, {
          'staged_at_dalipe': false,
          'called_by_robinsons': false,
        });
      } else {
        final activeUnit = qDocData['active_loading_vehicle']?.toString();
        final List queued = _parseStringList(qDocData['queued_vehicles']);
        final List standby = _parseStringList(
          qDocData['standby_staged_vehicles'],
        );

        if (activeUnit == vehicleId ||
            queued.contains(vehicleId) ||
            standby.contains(vehicleId)) {
          throw '$vehicleId is already checked into Dalipe terminal.';
        }

        if (vehicleGroup == activeGroup) {
          if (activeUnit == null ||
              activeUnit == 'None' ||
              activeUnit.isEmpty) {
            transaction.set(queueRef, {
              'active_loading_vehicle': vehicleId,
              'updated_at': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            feedbackMessage =
                'Unit $vehicleId ($driverName - $vehicleGroup) assigned to Spot 1 (Direct Route)!';
          } else {
            transaction.set(queueRef, {
              'queued_vehicles': FieldValue.arrayUnion([vehicleId]),
              'updated_at': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            feedbackMessage =
                'Unit $vehicleId ($driverName - $vehicleGroup) queued in On-Deck line!';
          }
        } else {
          transaction.set(queueRef, {
            'standby_staged_vehicles': FieldValue.arrayUnion([vehicleId]),
            'updated_at': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

          transaction.update(vehicleRef, {
            'staged_at_dalipe': true,
            'called_by_robinsons': false,
          });

          feedbackMessage =
              'Unit $vehicleId ($driverName - $vehicleGroup) placed in Dalipe Standby Pool (Holding for Robinsons)!';
        }
      }

      transaction.update(vehicleRef, {
        'current_status': 'STANDBY',
        'speed_kmh': 0,
        'is_dispatched': false,
        'visible_to_commuters': false,
        'route_id': _assignedRouteId,
        'transit_tag': null,
        'updated_at': FieldValue.serverTimestamp(),
      });

      transaction.update(driverRef, {'qr_token': null, 'qr_expires_at': null});
    });

    _showSnackbar(feedbackMessage);
  }

  // ===========================================================================
  // SNACKBAR HELPER
  // ===========================================================================
  void _showSnackbar(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        backgroundColor: isError
            ? AppColors.errorCrimson
            : const Color(0xFF059669),
      ),
    );
  }

  // ===========================================================================
  // TAB 1: BAY & QUEUE VIEW
  // ===========================================================================
  Widget _buildQueueAndBayTab() {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('terminals_queue')
          .doc(_currentQueueDocId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'No active terminal queue record for this assigned route.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final qData = snapshot.data!.data() as Map<String, dynamic>;
        final activeLoading = (qData['active_loading_vehicle'] ?? 'None')
            .toString();
        final List<String> queuedList = _parseStringList(
          qData['queued_vehicles'],
        );
        final List<String> standbyList = _parseStringList(
          qData['standby_staged_vehicles'],
        );
        final terminalName = (qData['terminal_name'] ?? _assignedTerminalId)
            .toString();
        final activeGroup =
            (qData['active_group'] ??
                    (_isRobinsonsTerminal ? 'Group 2' : 'Group 1'))
                .toString();
        final standbyGroup = activeGroup == 'Group 1' ? 'Group 2' : 'Group 1';

        return ListView(
          padding: const EdgeInsets.only(
            left: 14,
            right: 14,
            top: 14,
            bottom: 84,
          ),
          children: [
            // COOPERATIVE ANNOUNCEMENT BANNER FOR DISPATCHERS
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('notices')
                  .orderBy('created_at', descending: true)
                  .limit(10)
                  .snapshots(),
              builder: (context, noticeSnap) {
                if (!noticeSnap.hasData) return const SizedBox.shrink();

                final dispCoopId = (widget.userData['cooperative_id'] ?? '')
                    .toString()
                    .trim()
                    .toLowerCase();
                final dispUserId = widget.userId.trim().toLowerCase();

                final myNotices = noticeSnap.data!.docs.where((doc) {
                  final n = doc.data() as Map<String, dynamic>;
                  final noticeCoopId = (n['cooperative_id'] ?? '')
                      .toString()
                      .trim()
                      .toLowerCase();

                  if (dispCoopId.isNotEmpty &&
                      noticeCoopId.isNotEmpty &&
                      dispCoopId != noticeCoopId) {
                    return false;
                  }

                  final targetMode = (n['target_mode'] ?? 'BROADCAST_ALL')
                      .toString();
                  if (targetMode == 'BROADCAST_ALL' ||
                      targetMode == 'BROADCAST_DISPATCHERS')
                    return true;
                  if (targetMode == 'INDIVIDUAL') {
                    final targetId = (n['target_user_id'] ?? '')
                        .toString()
                        .trim()
                        .toLowerCase();
                    return targetId == dispUserId;
                  }
                  return false;
                }).toList();

                if (myNotices.isEmpty) return const SizedBox.shrink();

                final latest = myNotices.first.data() as Map<String, dynamic>;
                final isUrgent =
                    (latest['priority'] ?? '').toString().toUpperCase() ==
                    'URGENT';
                final isDirect = latest['target_mode'] == 'INDIVIDUAL';
                final title = (latest['title'] ?? 'Notice').toString();
                final message = (latest['message'] ?? '').toString();
                final author = (latest['author_name'] ?? 'Operations Office')
                    .toString();

                return Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isUrgent
                        ? const Color(0xFFFEF2F2)
                        : const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isUrgent
                          ? const Color(0xFFFECACA)
                          : const Color(0xFFBFDBFE),
                      width: 1.5,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isUrgent
                                ? Icons.warning_rounded
                                : Icons.campaign_rounded,
                            size: 20,
                            color: isUrgent
                                ? const Color(0xFFDC2626)
                                : const Color(0xFF2563EB),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              isDirect
                                  ? 'DIRECT MEMO: $title'
                                  : 'COOP ANNOUNCEMENT: $title',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w900,
                                color: isUrgent
                                    ? const Color(0xFF991B1B)
                                    : const Color(0xFF1E40AF),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        message,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: isUrgent
                              ? const Color(0xFF7F1D1D)
                              : const Color(0xFF1E3A8A),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Issued by: $author',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),

            ..._buildProcessCards(qData, activeLoading, queuedList),
            _buildSpot1LoadingCard(
              activeVehicleId: activeLoading,
              queuedList: queuedList,
              standbyList: standbyList,
              terminalName: terminalName,
            ),
            const SizedBox(height: 14),

            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: const Color(0xFF2563EB).withOpacity(0.24),
                  width: 1.1,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x05000000),
                    blurRadius: 4,
                    offset: Offset(0, 1.5),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2.5,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEFF6FF),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _queueChipLabel(activeGroup),
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF1D4ED8),
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                            Text(
                              _isRobinsonsTerminal
                                  ? 'ON-DECK (${queuedList.length} / 3 SLOTS)'
                                  : 'ON-DECK LINE (${queuedList.length})',
                              style: AppTypography.outdoorHeading(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      TextButton.icon(
                        icon: const Icon(Icons.swap_vert_rounded, size: 14),
                        label: const Text(
                          'Reorder',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF1D4ED8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () => _showReorderListModal(
                          targetDocId: _currentQueueDocId,
                          targetFieldName: 'queued_vehicles',
                          listTitle: 'On-Deck Line',
                          currentList: queuedList,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 18, color: AppColors.borderSubtle),

                  if (queuedList.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10.0),
                      child: Center(
                        child: Text(
                          'No vehicles queued behind Spot 1.',
                          textAlign: TextAlign.center,
                          style: AppTypography.outdoorBody(fontSize: 13),
                        ),
                      ),
                    )
                  else
                    ...queuedList.asMap().entries.map(
                      (entry) => _buildDirectQueueUnitTile(
                        entry.value,
                        entry.key + 1,
                        line: queuedList,
                      ),
                    ),
                ],
              ),
            ),

            if (_isDalipeTerminal && _usesDalipeStaging) ...[
              const SizedBox(height: 14),
              _buildStandbyContainer(
                targetDocId: _currentQueueDocId,
                title: '$standbyGroup • HOLDING FOR ROBINSONS',
                badgeText: 'STANDBY POOL (${standbyList.length})',
                units: standbyList,
                canManage: false,
              ),
            ],

            if (_isRobinsonsTerminal && _requiresRobinsonsCall) ...[
              const SizedBox(height: 14),
              StreamBuilder<DocumentSnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('terminals_queue')
                    .doc(_dalipeQueueDocId)
                    .snapshots(),
                builder: (context, dalipeSnap) {
                  final dalipeData =
                      dalipeSnap.data?.data() as Map<String, dynamic>?;
                  final remoteStandby = _parseStringList(
                    dalipeData?['standby_staged_vehicles'],
                  );

                  return _buildStandbyContainer(
                    targetDocId: _dalipeQueueDocId,
                    badgeText: 'STANDBY FEED (${remoteStandby.length})',
                    units: remoteStandby,
                    canManage: true,
                  );
                },
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildSpot1LoadingCard({
    required String activeVehicleId,
    required List<String> queuedList,
    required List<String> standbyList,
    required String terminalName,
  }) {
    final hasVehicle = activeVehicleId != 'None' && activeVehicleId.isNotEmpty;

    if (!hasVehicle) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.borderSubtle),
          boxShadow: const [
            BoxShadow(
              color: Color(0x05000000),
              blurRadius: 4,
              offset: Offset(0, 1.5),
            ),
          ],
        ),
        child: Column(
          children: [
            const Icon(
              Icons.directions_bus_outlined,
              size: 38,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: 8),
            Text(
              'Spot 1 Bay is Currently Empty',
              textAlign: TextAlign.center,
              style: AppTypography.outdoorHeading(fontSize: 15),
            ),
            const SizedBox(height: 3),
            Text(
              'Scan an arriving driver\'s QR pass to assign the loading bay.',
              textAlign: TextAlign.center,
              style: AppTypography.outdoorBody(
                fontSize: 12.5,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
      );
    }

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('vehicles_live')
          .doc(activeVehicleId)
          .snapshots(),
      builder: (context, snapshot) {
        final vData = snapshot.data?.data() as Map<String, dynamic>?;
        final plate = (vData?['plate_number'] ?? activeVehicleId).toString();
        final jeepName = (vData?['vehicle_name'] ?? plate).toString();
        final driverName = (vData?['driver_name'] ?? 'Assigned Driver')
            .toString();
        final maxCapacity = (vData?['max_capacity'] as num?)?.toInt() ?? 20;
        final passengerCount =
            (vData?['passenger_count'] as num?)?.toInt() ?? 0;
        final isFull = passengerCount >= maxCapacity;

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF059669), width: 1.4),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0A059669),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2.5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFECFDF5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _rotation.numberOf(activeVehicleId) != null
                            ? 'SPOT 1 • BOARDING NOW • TURN #${_rotation.numberOf(activeVehicleId)}'
                            : 'SPOT 1 • BOARDING NOW',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF059669),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$passengerCount / $maxCapacity Seats',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: isFull
                          ? AppColors.errorCrimson
                          : const Color(0xFF059669),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              Row(
                children: [
                  _buildLicenseBadge(plate),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          jeepName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.outdoorHeading(fontSize: 14),
                        ),
                        Text(
                          'Driver: $driverName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.outdoorBody(
                            fontSize: 12.5,
                            fontWeight: FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.info_outline_rounded,
                      color: AppColors.primaryNavy,
                      size: 20,
                    ),
                    tooltip: 'Vehicle Location & Info',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => _showUnitActionsModal(
                      vehicleId: activeVehicleId,
                      targetDocId: _currentQueueDocId,
                      targetFieldName: 'active_loading_vehicle',
                      isStandby: false,
                      position: 1,
                    ),
                  ),
                ],
              ),
              const Divider(height: 20, color: AppColors.borderSubtle),

              Text(
                'RECORD PASSENGER BOARDING',
                style: AppTypography.outdoorBody(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.remove_rounded, size: 16),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'Passenger',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        side: const BorderSide(color: AppColors.borderSubtle),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: passengerCount > 0
                          ? () => _adjustPassengerCount(
                              activeVehicleId,
                              passengerCount,
                              maxCapacity,
                              -1,
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.add_rounded, size: 16),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'Passenger',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF059669),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: passengerCount < maxCapacity
                          ? () => _adjustPassengerCount(
                              activeVehicleId,
                              passengerCount,
                              maxCapacity,
                              1,
                            )
                          : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.send_rounded, size: 15),
                  label: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'DISPATCH JEEPNEY',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryNavy,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => _executeDispatch(
                    activeVehicleId: activeVehicleId,
                    passengerCount: passengerCount,
                    currentQueue: queuedList,
                    currentStandby: standbyList,
                    terminalName: terminalName,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStandbyContainer({
    required String targetDocId,
    String? title,
    required String badgeText,
    required List<String> units,
    required bool canManage,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFFF59E0B).withOpacity(0.4),
          width: 1.1,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x05000000),
            blurRadius: 4,
            offset: Offset(0, 1.5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (title != null && title.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF92400E),
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    Text(
                      badgeText,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF92400E),
                      ),
                    ),
                  ],
                ),
              ),
              if (canManage) ...[
                const SizedBox(width: 6),
                TextButton.icon(
                  icon: const Icon(Icons.swap_vert_rounded, size: 14),
                  label: const Text(
                    'Reorder',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF92400E),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _showReorderListModal(
                    targetDocId: targetDocId,
                    targetFieldName: 'standby_staged_vehicles',
                    listTitle: 'Standby Pool',
                    currentList: units,
                  ),
                ),
              ],
            ],
          ),
          const Divider(height: 18, color: Color(0xFFFDE68A)),

          if (units.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10.0),
              child: Center(
                child: Text(
                  'No vehicles currently staged in this standby pool.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Color(0xFFB45309)),
                ),
              ),
            )
          else
            ...units.asMap().entries.map(
              (entry) => _buildRobinsonsStandbyTile(
                entry.value,
                entry.key + 1,
                isManageable: canManage,
                targetDocId: targetDocId,
              ),
            ),
        ],
      ),
    );
  }

  // ===========================================================================
  // ON-DECK QUEUE UNIT TILE
  // ===========================================================================
  Widget _buildDirectQueueUnitTile(
    String vehicleId,
    int position, {
    List<String> line = const [],
  }) {
    final isFrontOfQueue = position == 1;

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('vehicles_live')
          .doc(vehicleId)
          .snapshots(),
      builder: (context, snapshot) {
        final vData = snapshot.data?.data() as Map<String, dynamic>?;
        final plate = (vData?['plate_number'] ?? vehicleId).toString();
        final jeepName = (vData?['vehicle_name'] ?? plate).toString();
        final passCount = (vData?['passenger_count'] as num?)?.toInt() ?? 0;
        final maxCap = (vData?['max_capacity'] as num?)?.toInt() ?? 20;

        return Container(
          margin: const EdgeInsets.only(bottom: 7),
          decoration: BoxDecoration(
            color: isFrontOfQueue
                ? const Color(0xFFF0FDF4)
                : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isFrontOfQueue
                  ? const Color(0xFF86EFAC)
                  : const Color(0xFFE2E8F0),
              width: isFrontOfQueue ? 1.2 : 1.0,
            ),
          ),
          child: Column(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => _showUnitActionsModal(
                  vehicleId: vehicleId,
                  targetDocId: _currentQueueDocId,
                  targetFieldName: 'queued_vehicles',
                  isStandby: false,
                  position: position,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 11,
                        backgroundColor: isFrontOfQueue
                            ? const Color(0xFF059669)
                            : const Color(0xFF2563EB),
                        child: Text(
                          '$position',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              jeepName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.outdoorHeading(fontSize: 13.5),
                            ),
                            _rotationBadge(vehicleId, line: line),
                            if (isFrontOfQueue)
                              const Text(
                                'Front of Queue • Next to load into bay',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF059669),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildLicenseBadge(plate, fontSize: 12.5),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.more_horiz_rounded,
                        size: 18,
                        color: AppColors.textMuted,
                      ),
                    ],
                  ),
                ),
              ),

              if (isFrontOfQueue) ...[
                const Divider(height: 1, color: Color(0xFFBBF7D0)),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.airline_seat_recline_normal_rounded,
                        size: 15,
                        color: Color(0xFF059669),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          'Seats: $passCount / $maxCap',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: passCount >= maxCap
                                ? AppColors.errorCrimson
                                : const Color(0xFF065F46),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        height: 28,
                        width: 34,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.zero,
                            side: const BorderSide(
                              color: Color(0xFF059669),
                              width: 1.1,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                            backgroundColor: Colors.white,
                          ),
                          onPressed: passCount > 0
                              ? () => _adjustPassengerCount(
                                  vehicleId,
                                  passCount,
                                  maxCap,
                                  -1,
                                )
                              : null,
                          child: const Icon(
                            Icons.remove_rounded,
                            size: 16,
                            color: Color(0xFF059669),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        height: 28,
                        width: 34,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            padding: EdgeInsets.zero,
                            backgroundColor: const Color(0xFF059669),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          onPressed: passCount < maxCap
                              ? () => _adjustPassengerCount(
                                  vehicleId,
                                  passCount,
                                  maxCap,
                                  1,
                                )
                              : null,
                          child: const Icon(
                            Icons.add_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildRobinsonsStandbyTile(
    String vehicleId,
    int position, {
    required bool isManageable,
    required String targetDocId,
  }) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('vehicles_live')
          .doc(vehicleId)
          .snapshots(),
      builder: (context, snapshot) {
        final vData = snapshot.data?.data() as Map<String, dynamic>?;
        final plate = (vData?['plate_number'] ?? vehicleId).toString();
        final jeepName = (vData?['vehicle_name'] ?? plate).toString();

        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: isManageable
              ? () => _showUnitActionsModal(
                  vehicleId: vehicleId,
                  targetDocId: targetDocId,
                  targetFieldName: 'standby_staged_vehicles',
                  isStandby: true,
                  position: position,
                )
              : null,
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFCD34D)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Hold #$position',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF92400E),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        jeepName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.outdoorHeading(fontSize: 13.5),
                      ),
                      _rotationBadge(vehicleId),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _buildLicenseBadge(plate, fontSize: 12.5),
                const SizedBox(width: 6),
                if (isManageable)
                  const Icon(
                    Icons.more_horiz_rounded,
                    size: 18,
                    color: Color(0xFFD97706),
                  )
                else
                  const Text(
                    'Staged',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFFD97706),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================
  // TAB 2: DISPATCH HISTORY TAB
  // ===========================================================================
  Widget _buildDispatchHistoryTab() {
    return Column(
      children: [
        _buildDispatchFilterBar(),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('dispatch_logs')
                .where('terminal_id', isEqualTo: _assignedTerminalId)
                .where('route_id', isEqualTo: _assignedRouteId)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                      'Query error: ${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.errorCrimson,
                        fontSize: 13,
                      ),
                    ),
                  ),
                );
              }

              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primaryNavy,
                  ),
                );
              }

              final rawDocs = List<QueryDocumentSnapshot>.from(
                snapshot.data?.docs ?? [],
              );

              final filteredDocs = rawDocs.where((doc) {
                final data = doc.data() as Map<String, dynamic>;
                final vehicleId = (data['vehicle_id'] ?? '')
                    .toString()
                    .toUpperCase();
                final Timestamp? ts = data['dispatched_at'] as Timestamp?;
                final query = (_historyPlateQuery ?? '').trim().toUpperCase();

                if (query.isNotEmpty && !vehicleId.contains(query)) {
                  return false;
                }

                if (ts != null) {
                  final dt = ts.toDate().toLocal();

                  if (_historyStartDate != null) {
                    final start = DateTime(
                      _historyStartDate!.year,
                      _historyStartDate!.month,
                      _historyStartDate!.day,
                    );
                    if (dt.isBefore(start)) return false;
                  }

                  if (_historyEndDate != null) {
                    final end = DateTime(
                      _historyEndDate!.year,
                      _historyEndDate!.month,
                      _historyEndDate!.day,
                      23,
                      59,
                      59,
                    );
                    if (dt.isAfter(end)) return false;
                  }

                  if (_historyStartTime != null) {
                    final minutesOfDay = dt.hour * 60 + dt.minute;
                    final startMinutes =
                        _historyStartTime!.hour * 60 +
                        _historyStartTime!.minute;
                    if (minutesOfDay < startMinutes) return false;
                  }

                  if (_historyEndTime != null) {
                    final minutesOfDay = dt.hour * 60 + dt.minute;
                    final endMinutes =
                        _historyEndTime!.hour * 60 + _historyEndTime!.minute;
                    if (minutesOfDay > endMinutes) return false;
                  }
                }
                return true;
              }).toList();

              filteredDocs.sort((a, b) {
                final dataA = a.data() as Map<String, dynamic>;
                final dataB = b.data() as Map<String, dynamic>;
                final Timestamp? timeA = dataA['dispatched_at'] as Timestamp?;
                final Timestamp? timeB = dataB['dispatched_at'] as Timestamp?;
                if (timeA == null && timeB == null) return 0;
                if (timeA == null) return 1;
                if (timeB == null) return -1;
                return timeB.compareTo(timeA);
              });

              if (filteredDocs.isEmpty) {
                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.filter_list_off_rounded,
                          size: 40,
                          color: AppColors.textMuted.withOpacity(0.5),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'No matching dispatch logs found.',
                          textAlign: TextAlign.center,
                          style: AppTypography.outdoorHeading(fontSize: 14),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Try clearing or broadening your filter criteria.',
                          textAlign: TextAlign.center,
                          style: AppTypography.outdoorBody(
                            fontSize: 12.5,
                            fontWeight: FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              final Map<String, List<Map<String, dynamic>>> groupedLogs = {};
              final Map<String, DateTime> groupDateMap = {};

              for (var doc in filteredDocs) {
                final data = doc.data() as Map<String, dynamic>;
                final ts = data['dispatched_at'] as Timestamp?;
                final dt = ts != null ? ts.toDate().toLocal() : DateTime.now();
                final dateKey =
                    '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

                groupedLogs.putIfAbsent(dateKey, () => []).add(data);
                groupDateMap.putIfAbsent(dateKey, () => dt);
              }

              return ListView.builder(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                itemCount: groupedLogs.keys.length,
                itemBuilder: (context, groupIndex) {
                  final dateKey = groupedLogs.keys.elementAt(groupIndex);
                  final groupDate = groupDateMap[dateKey]!;
                  final logsForDay = groupedLogs[dateKey]!;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(
                          top: 8,
                          bottom: 6,
                          left: 2,
                        ),
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                _formatDateHeader(groupDate),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.darkSlate,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEFF6FF),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '${logsForDay.length} Units',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1D4ED8),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      ...logsForDay.map((log) {
                        final vehicleId = log['vehicle_id'] ?? 'Unknown';
                        final passengers = log['passenger_count'] ?? 0;
                        final dispatcherName =
                            log['dispatcher_name'] ?? 'Dispatcher';
                        final Timestamp? ts =
                            log['dispatched_at'] as Timestamp?;
                        final timeStr = ts != null
                            ? '${ts.toDate().hour.toString().padLeft(2, '0')}:${ts.toDate().minute.toString().padLeft(2, '0')}'
                            : '--:--';

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.borderSubtle),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x05000000),
                                blurRadius: 4,
                                offset: Offset(0, 1.5),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFECFDF5),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(
                                  Icons.check_circle_outline_rounded,
                                  color: Color(0xFF059669),
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: FutureBuilder<DocumentSnapshot>(
                                            future: FirebaseFirestore.instance
                                                .collection('vehicles_live')
                                                .doc(vehicleId)
                                                .get(),
                                            builder: (context, vSnap) {
                                              String displayTitle = vehicleId;
                                              if (vSnap.hasData &&
                                                  vSnap.data!.exists) {
                                                final vData =
                                                    vSnap.data!.data()
                                                        as Map<
                                                          String,
                                                          dynamic
                                                        >?;
                                                final plate =
                                                    vData?['plate_number']
                                                        ?.toString();
                                                if (plate != null &&
                                                    plate.trim().isNotEmpty) {
                                                  displayTitle = plate;
                                                }
                                              }
                                              return Text(
                                                displayTitle
                                                    .replaceAll('_', ' ')
                                                    .toUpperCase(),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style:
                                                    AppTypography.outdoorHeading(
                                                      fontSize: 14,
                                                    ),
                                              );
                                            },
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 5,
                                            vertical: 1.5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFEFF6FF),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: const Text(
                                            'DISPATCHED',
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w800,
                                              color: Color(0xFF1D4ED8),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'By $dispatcherName • $passengers passengers',
                                      style: AppTypography.outdoorBody(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.normal,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                timeStr,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                  color: AppColors.primaryNavy,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // DISPATCH FILTER BAR
  // ===========================================================================
  Widget _buildDispatchFilterBar() {
    final now = DateTime.now();
    final isToday =
        _focusedDate.year == now.year &&
        _focusedDate.month == now.month &&
        _focusedDate.day == now.day;

    final bool hasActiveFilters =
        _historyStartDate != null ||
        _historyEndDate != null ||
        (_historyPlateQuery ?? '').isNotEmpty ||
        _historyStartTime != null ||
        _historyEndTime != null ||
        _selectedPreset != DateFilterPreset.allTime;

    final bool narrow = _isNarrow(context);

    final Widget searchField = SizedBox(
      height: 40,
      child: TextField(
        onChanged: (val) => setState(() => _historyPlateQuery = val.trim()),
        style: const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: AppColors.darkSlate,
        ),
        decoration: InputDecoration(
          hintText: 'Search plate number / ID...',
          hintStyle: const TextStyle(fontSize: 13, color: AppColors.textMuted),
          prefixIcon: const Icon(
            Icons.search_rounded,
            size: 18,
            color: AppColors.primaryNavy,
          ),
          contentPadding: EdgeInsets.zero,
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFCBD5E1), width: 1.2),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFCBD5E1), width: 1.2),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(
              color: AppColors.primaryNavy,
              width: 1.5,
            ),
          ),
        ),
      ),
    );

    // Date Stepper Control (< Date >)
    final Widget dateStepper = Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFCBD5E1), width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(
              Icons.chevron_left_rounded,
              size: 18,
              color: AppColors.primaryNavy,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28),
            tooltip: 'Previous Day',
            onPressed: () => _stepDate(-1),
          ),
          InkWell(
            onTap: () async {
              AppTypography.lightFeedback();
              final picked = await showDatePicker(
                context: context,
                initialDate: _focusedDate,
                firstDate: DateTime(2025),
                lastDate: DateTime(2030),
              );
              if (picked != null) {
                setState(() {
                  _focusedDate = picked;
                  _selectedPreset = DateFilterPreset.custom;
                  _historyStartDate = DateTime(
                    picked.year,
                    picked.month,
                    picked.day,
                  );
                  _historyEndDate = DateTime(
                    picked.year,
                    picked.month,
                    picked.day,
                  );
                });
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                isToday
                    ? 'Today'
                    : '${_monthName(_focusedDate.month)} ${_focusedDate.day}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  color: isToday
                      ? const Color(0xFF059669)
                      : AppColors.darkSlate,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: AppColors.primaryNavy,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28),
            tooltip: 'Next Day',
            onPressed: isToday ? null : () => _stepDate(1),
          ),
        ],
      ),
    );

    final Widget resetButton = SizedBox(
      height: 40,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          side: const BorderSide(color: Color(0xFFFECACA)),
          backgroundColor: const Color(0xFFFEF2F2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        onPressed: () {
          AppTypography.lightFeedback();
          _applyDatePreset(DateFilterPreset.allTime);
          setState(() => _historyPlateQuery = '');
        },
        child: const Text(
          'Reset',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.bold,
            color: AppColors.errorCrimson,
          ),
        ),
      ),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (narrow) ...[
            // Small phones: search on its own line, stepper + reset below it
            searchField,
            const SizedBox(height: 8),
            Row(
              children: [
                dateStepper,
                if (hasActiveFilters) ...[
                  const SizedBox(width: 6),
                  resetButton,
                ],
              ],
            ),
          ] else
            Row(
              children: [
                Expanded(child: searchField),
                const SizedBox(width: 8),
                dateStepper,
                if (hasActiveFilters) ...[
                  const SizedBox(width: 6),
                  resetButton,
                ],
              ],
            ),
          const SizedBox(height: 8),

          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildSimplePresetChip('All Time', DateFilterPreset.allTime),
                const SizedBox(width: 6),
                _buildSimplePresetChip('AM Shift', DateFilterPreset.amShift),
                const SizedBox(width: 6),
                _buildSimplePresetChip('PM Shift', DateFilterPreset.pmShift),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: Icon(
                    Icons.date_range_rounded,
                    size: 14,
                    color: _selectedPreset == DateFilterPreset.custom
                        ? AppColors.primaryNavy
                        : AppColors.textMuted,
                  ),
                  label: Text(
                    _selectedPreset == DateFilterPreset.custom &&
                            _historyStartDate != null
                        ? '${_historyStartDate!.month}/${_historyStartDate!.day} - ${_historyEndDate != null ? "${_historyEndDate!.month}/${_historyEndDate!.day}" : ""}'
                        : 'Custom Range',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: _selectedPreset == DateFilterPreset.custom
                          ? FontWeight.bold
                          : FontWeight.w600,
                      color: _selectedPreset == DateFilterPreset.custom
                          ? AppColors.primaryNavy
                          : AppColors.darkSlate,
                    ),
                  ),
                  backgroundColor: _selectedPreset == DateFilterPreset.custom
                      ? const Color(0xFFEFF6FF)
                      : AppColors.backgroundSlate,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: _selectedPreset == DateFilterPreset.custom
                          ? const Color(0xFFBFDBFE)
                          : AppColors.borderSubtle,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  onPressed: () async {
                    AppTypography.lightFeedback();
                    final picked = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(2025),
                      lastDate: DateTime(2030),
                      initialDateRange:
                          _historyStartDate != null && _historyEndDate != null
                          ? DateTimeRange(
                              start: _historyStartDate!,
                              end: _historyEndDate!,
                            )
                          : null,
                    );
                    if (picked != null) {
                      setState(() {
                        _selectedPreset = DateFilterPreset.custom;
                        _historyStartDate = picked.start;
                        _historyEndDate = picked.end;
                        _historyStartTime = null;
                        _historyEndTime = null;
                      });
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSimplePresetChip(String label, DateFilterPreset preset) {
    final isSelected = _selectedPreset == preset;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _applyDatePreset(preset),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.primaryNavy
                : AppColors.backgroundSlate,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? AppColors.primaryNavy
                  : AppColors.borderSubtle,
              width: 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isSelected) ...[
                const Icon(Icons.check_rounded, size: 14, color: Colors.white),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                  color: isSelected ? Colors.white : AppColors.darkSlate,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // TAB 3: AUDIT TRAIL TAB
  // ===========================================================================
  Widget _buildAuditTrailTab() {
    return Column(
      children: [
        _buildAuditFilterBar(),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('queue_audit_logs')
                .where('route_id', isEqualTo: _assignedRouteId)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                      'Query error: ${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.errorCrimson,
                        fontSize: 13,
                      ),
                    ),
                  ),
                );
              }

              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primaryNavy,
                  ),
                );
              }

              final rawDocs = List<QueryDocumentSnapshot>.from(
                snapshot.data?.docs ?? [],
              );

              final filteredDocs = rawDocs.where((doc) {
                final data = doc.data() as Map<String, dynamic>;
                final reason = (data['reason'] ?? '').toString().toLowerCase();
                final dispatcher = (data['dispatcher_name'] ?? '')
                    .toString()
                    .toLowerCase();
                final prev = _parseStringList(data['previous_order'])
                    .join(' ')
                    .toLowerCase();
                final next = _parseStringList(data['new_order'])
                    .join(' ')
                    .toLowerCase();
                final Timestamp? ts = data['timestamp'] as Timestamp?;
                final q = (_auditSearchQuery ?? '').trim().toLowerCase();

                if (q.isNotEmpty) {
                  if (!reason.contains(q) &&
                      !dispatcher.contains(q) &&
                      !prev.contains(q) &&
                      !next.contains(q)) {
                    return false;
                  }
                }

                if (ts != null) {
                  final dt = ts.toDate().toLocal();

                  if (_auditStartDate != null) {
                    final start = DateTime(
                      _auditStartDate!.year,
                      _auditStartDate!.month,
                      _auditStartDate!.day,
                    );
                    if (dt.isBefore(start)) return false;
                  }

                  if (_auditEndDate != null) {
                    final end = DateTime(
                      _auditEndDate!.year,
                      _auditEndDate!.month,
                      _auditEndDate!.day,
                      23,
                      59,
                      59,
                    );
                    if (dt.isAfter(end)) return false;
                  }
                }
                return true;
              }).toList();

              filteredDocs.sort((a, b) {
                final dataA = a.data() as Map<String, dynamic>;
                final dataB = b.data() as Map<String, dynamic>;
                final Timestamp? timeA = dataA['timestamp'] as Timestamp?;
                final Timestamp? timeB = dataB['timestamp'] as Timestamp?;
                if (timeA == null && timeB == null) return 0;
                if (timeA == null) return 1;
                if (timeB == null) return -1;
                return timeB.compareTo(timeA);
              });

              if (filteredDocs.isEmpty) {
                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          size: 40,
                          color: AppColors.textMuted.withOpacity(0.5),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'No matching queue change records.',
                          textAlign: TextAlign.center,
                          style: AppTypography.outdoorHeading(fontSize: 14),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Zero audit anomalies detected for the selected period.',
                          textAlign: TextAlign.center,
                          style: AppTypography.outdoorBody(
                            fontSize: 12.5,
                            fontWeight: FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              final Map<String, List<Map<String, dynamic>>> groupedAudits = {};
              final Map<String, DateTime> auditDateMap = {};

              for (var doc in filteredDocs) {
                final data = doc.data() as Map<String, dynamic>;
                final ts = data['timestamp'] as Timestamp?;
                final dt = ts != null ? ts.toDate().toLocal() : DateTime.now();
                final dateKey =
                    '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

                groupedAudits.putIfAbsent(dateKey, () => []).add(data);
                auditDateMap.putIfAbsent(dateKey, () => dt);
              }

              return ListView.builder(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                itemCount: groupedAudits.keys.length,
                itemBuilder: (context, groupIndex) {
                  final dateKey = groupedAudits.keys.elementAt(groupIndex);
                  final groupDate = auditDateMap[dateKey]!;
                  final auditsForDay = groupedAudits[dateKey]!;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(
                          top: 8,
                          bottom: 6,
                          left: 2,
                        ),
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                _formatDateHeader(groupDate),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.darkSlate,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEF3C7),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '${auditsForDay.length} Events',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF92400E),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      ...auditsForDay.map((audit) {
                        final dispatcher =
                            audit['dispatcher_name'] ?? 'Dispatcher';
                        final reason = audit['reason'] ?? 'No reason logged.';
                        final prev = _parseStringList(audit['previous_order'])
                            .join(', ');
                        final next = _parseStringList(audit['new_order'])
                            .join(', ');
                        final Timestamp? ts = audit['timestamp'] as Timestamp?;
                        final timeStr = ts != null
                            ? '${ts.toDate().hour.toString().padLeft(2, '0')}:${ts.toDate().minute.toString().padLeft(2, '0')}'
                            : '--:--';
                        final eventType =
                            audit['event_type'] ?? 'QUEUE OVERRIDE';

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFFDE68A)),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x05000000),
                                blurRadius: 4,
                                offset: Offset(0, 1.5),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Flexible(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFEF3C7),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        eventType.toString().replaceAll(
                                          '_',
                                          ' ',
                                        ),
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF92400E),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    timeStr,
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      color: AppColors.textMuted,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Reason: "$reason"',
                                style: AppTypography.outdoorHeading(
                                  fontSize: 13,
                                ),
                              ),
                              if (prev.isNotEmpty || next.isNotEmpty) ...[
                                const Divider(
                                  height: 14,
                                  color: AppColors.borderSubtle,
                                ),
                                if (prev.isNotEmpty)
                                  Text(
                                    'Previous: $prev',
                                    style: AppTypography.outdoorBody(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.normal,
                                    ),
                                  ),
                                if (next.isNotEmpty)
                                  Text(
                                    'New Order: $next',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF1D4ED8),
                                    ),
                                  ),
                              ],
                              const SizedBox(height: 3),
                              Text(
                                'Authorized by: $dispatcher',
                                style: AppTypography.outdoorBody(
                                  fontSize: 11,
                                  fontWeight: FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAuditFilterBar() {
    final bool hasActiveFilters =
        _auditStartDate != null ||
        _auditEndDate != null ||
        (_auditSearchQuery ?? '').isNotEmpty;

    final bool narrow = _isNarrow(context);

    final Widget searchField = SizedBox(
      height: 40,
      child: TextField(
        onChanged: (val) => setState(() => _auditSearchQuery = val.trim()),
        style: const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: AppColors.darkSlate,
        ),
        decoration: InputDecoration(
          hintText: 'Search by reason, dispatcher, or plate...',
          hintStyle: const TextStyle(fontSize: 13, color: AppColors.textMuted),
          prefixIcon: const Icon(
            Icons.search_rounded,
            size: 18,
            color: AppColors.primaryNavy,
          ),
          contentPadding: EdgeInsets.zero,
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFCBD5E1), width: 1.2),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFCBD5E1), width: 1.2),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(
              color: AppColors.primaryNavy,
              width: 1.5,
            ),
          ),
        ),
      ),
    );

    final Widget dateChip = ActionChip(
      avatar: const Icon(
        Icons.calendar_month_rounded,
        size: 13,
        color: AppColors.primaryNavy,
      ),
      label: Text(
        _auditStartDate == null
            ? 'Date Range'
            : '${_auditStartDate!.month}/${_auditStartDate!.day} - ${_auditEndDate != null ? "${_auditEndDate!.month}/${_auditEndDate!.day}" : "Today"}',
        style: TextStyle(
          fontSize: 12,
          fontWeight: _auditStartDate != null
              ? FontWeight.bold
              : FontWeight.w500,
          color: _auditStartDate != null
              ? AppColors.primaryNavy
              : AppColors.darkSlate,
        ),
      ),
      backgroundColor: _auditStartDate != null
          ? const Color(0xFFEFF6FF)
          : AppColors.backgroundSlate,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      onPressed: () async {
        AppTypography.lightFeedback();
        final picked = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2025),
          lastDate: DateTime(2030),
          initialDateRange: _auditStartDate != null && _auditEndDate != null
              ? DateTimeRange(start: _auditStartDate!, end: _auditEndDate!)
              : null,
        );
        if (picked != null) {
          setState(() {
            _auditStartDate = picked.start;
            _auditEndDate = picked.end;
          });
        }
      },
    );

    final Widget clearButton = IconButton(
      visualDensity: VisualDensity.compact,
      icon: const Icon(
        Icons.filter_alt_off_rounded,
        color: AppColors.errorCrimson,
        size: 18,
      ),
      tooltip: 'Clear Filters',
      onPressed: () {
        AppTypography.lightFeedback();
        setState(() {
          _auditStartDate = null;
          _auditEndDate = null;
          _auditSearchQuery = '';
        });
      },
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: narrow
          // Small phones: search on its own line, date chip + clear below it
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                searchField,
                const SizedBox(height: 8),
                Row(
                  children: [
                    dateChip,
                    if (hasActiveFilters) ...[
                      const SizedBox(width: 4),
                      clearButton,
                    ],
                  ],
                ),
              ],
            )
          : Row(
              children: [
                Expanded(child: searchField),
                const SizedBox(width: 8),
                dateChip,
                if (hasActiveFilters) ...[
                  const SizedBox(width: 4),
                  clearButton,
                ],
              ],
            ),
    );
  }

  Widget _buildLicenseBadge(String plate, {double fontSize = 13}) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 130),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
        decoration: BoxDecoration(
          color: AppTypography.slate100,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFFCBD5E1), width: 1.0),
        ),
        child: Text(
          plate.replaceAll('_', ' ').toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.plateStyle(fontSize: fontSize),
        ),
      ),
    );
  }

  // ===========================================================================
  // MAIN SCAFFOLD & BUILD METHOD
  // ===========================================================================
  @override
  Widget build(BuildContext context) {
    if (_tabController.length != 3) {
      _tabController.dispose();
      _tabController = TabController(length: 3, vsync: this);
    }

    final fullName = (widget.userData['full_name'] ?? 'Terminal Dispatcher')
        .toString();
    final initialChar = fullName.trim().isNotEmpty
        ? fullName.trim()[0].toUpperCase()
        : 'D';
    final coopId = (widget.userData['cooperative_id'] ?? '').toString();

    return _ts(
      context,
      Scaffold(
        backgroundColor: AppColors.backgroundSlate,
        appBar: AppBar(
          elevation: 0,
          backgroundColor: AppColors.primaryNavy,
          automaticallyImplyLeading: false,
          titleSpacing: 14,
          title: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.12),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFF38BDF8),
                    width: 1.4,
                  ),
                ),
                child: Center(
                  child: Text(
                    initialChar,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            fullName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF38BDF8).withOpacity(0.18),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: const Color(0xFF38BDF8).withOpacity(0.5),
                              width: 0.8,
                            ),
                          ),
                          child: const Text(
                            'DISPATCHER',
                            style: TextStyle(
                              color: Color(0xFF38BDF8),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 1.5),
                    Text(
                      '${_assignedTerminalId.replaceAll('_', ' ')} • ${_formatRouteName(_assignedRouteId)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.72),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            // Notifications / Inbox Bell Icon
            IconButton(
              icon: const Icon(
                Icons.notifications_none_rounded,
                color: Colors.white,
                size: 20,
              ),
              tooltip: 'View Notices & Memos',
              onPressed: () => _showNoticesInboxModal(context, coopId),
            ),

            PopupMenuButton<String>(
              icon: const Icon(
                Icons.more_vert_rounded,
                color: Colors.white,
                size: 20,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              onSelected: (val) async {
                if (val == 'LOGOUT') {
                  AppTypography.lightFeedback();
                  await StaffAuth.signOut();
                  if (!mounted) return;
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const LoginScreen(),
                    ),
                    (route) => false, // Clears the entire navigation stack
                  );
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'LOGOUT',
                  height: 38,
                  child: Row(
                    children: [
                      Icon(
                        Icons.logout_rounded,
                        size: 16,
                        color: AppColors.errorCrimson,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Log Out',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.errorCrimson,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(42),
            child: Container(
              decoration: const BoxDecoration(
                color: AppColors.primaryNavy,
                border: Border(bottom: BorderSide(color: Colors.white12)),
              ),
              child: TabBar(
                controller: _tabController,
                indicatorColor: Colors.white,
                indicatorWeight: 3.0,
                labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white60,
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
                onTap: (_) => AppTypography.lightFeedback(),
                tabs: const [
                  Tab(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('Bay & Queue'),
                    ),
                  ),
                  Tab(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('History'),
                    ),
                  ),
                  Tab(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('Queue Changes'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        body: SafeArea(
          maintainBottomViewPadding: true,
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildQueueAndBayTab(),
              _buildDispatchHistoryTab(),
              _buildAuditTrailTab(),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: AppColors.primaryNavy,
          foregroundColor: Colors.white,
          elevation: 3,
          icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
          label: const Text(
            'Scan QR',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          onPressed: _openQrScannerModal,
        ),
      ),
    );
  }
}