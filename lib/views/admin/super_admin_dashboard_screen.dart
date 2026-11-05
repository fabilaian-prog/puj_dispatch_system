import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../auth/login_screen.dart';
import '../../utils/app_colors.dart';
import '../../utils/staff_auth.dart';
import '../cooperative/coop_ui.dart';
import '../cooperative/route_process_config.dart';
import 'fare_settings_tab.dart';

// ── Navigation model ─────────────────────────────────────────────────────────
enum _AdminSection { overview, cooperatives, reports, fares }

extension _AdminSectionInfo on _AdminSection {
  String get label {
    switch (this) {
      case _AdminSection.overview:
        return 'Overview';
      case _AdminSection.cooperatives:
        return 'Cooperatives';
      case _AdminSection.reports:
        return 'Reports';
      case _AdminSection.fares:
        return 'Fares';
    }
  }

  String get title {
    switch (this) {
      case _AdminSection.overview:
        return 'Network Overview';
      case _AdminSection.cooperatives:
        return 'Transport Cooperatives';
      case _AdminSection.reports:
        return 'Provincial Reports & Audits';
      case _AdminSection.fares:
        return 'Fare Settings';
    }
  }

  String get subtitle {
    switch (this) {
      case _AdminSection.overview:
        return 'Live fleet activity, terminal queues, and network health across Antique';
      case _AdminSection.cooperatives:
        return 'Provision cooperatives, manage CPC franchises, and assign route corridors';
      case _AdminSection.reports:
        return 'Monitor passenger incident reports and terminal queue overrides';
      case _AdminSection.fares:
        return 'Set the base fare, per-km rate, and discounted rates shown to commuters';
    }
  }

  IconData get icon {
    switch (this) {
      case _AdminSection.overview:
        return Icons.space_dashboard_outlined;
      case _AdminSection.cooperatives:
        return Icons.corporate_fare_outlined;
      case _AdminSection.reports:
        return Icons.fact_check_outlined;
      case _AdminSection.fares:
        return Icons.payments_outlined;
    }
  }

  IconData get selectedIcon {
    switch (this) {
      case _AdminSection.overview:
        return Icons.space_dashboard_rounded;
      case _AdminSection.cooperatives:
        return Icons.corporate_fare_rounded;
      case _AdminSection.reports:
        return Icons.fact_check_rounded;
      case _AdminSection.fares:
        return Icons.payments_rounded;
    }
  }
}

class SuperAdminDashboardScreen extends StatefulWidget {
  const SuperAdminDashboardScreen({super.key});

  @override
  State<SuperAdminDashboardScreen> createState() =>
      _SuperAdminDashboardScreenState();
}

class _SuperAdminDashboardScreenState extends State<SuperAdminDashboardScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Persistent controllers & streams so typing in search bars never rebuilds streams
  final TextEditingController _coopSearchCtrl = TextEditingController();
  final TextEditingController _reportSearchCtrl = TextEditingController();

  String _coopSearchQuery = '';
  String _coopFilter = 'ALL'; // ALL, WITH_FLEET, NO_CPC

  int _reportsSegment = 0; // 0 = Complaints, 1 = Queue Audits
  String _complaintStatusFilter = 'ALL';
  String _reportSearchQuery = '';

  // Streams are plain `late` fields (not final) so "Retry" can recreate them.
  late Stream<QuerySnapshot> _coopsStream = _makeCoopsStream();
  late Stream<QuerySnapshot> _vehiclesStream = _makeVehiclesStream();
  late Stream<QuerySnapshot> _queuesStream = _makeQueuesStream();
  late Stream<QuerySnapshot> _complaintsStream = _makeComplaintsStream();
  late Stream<QuerySnapshot> _auditsStream = _makeAuditsStream();

  // The Overview tab gets its OWN stream instances. A Firestore stream does
  // not replay its last value to a second listener, so sharing one stream
  // between Overview and the Cooperatives / Reports tabs left whichever tab
  // subscribed second stuck on its loading spinner.
  late Stream<QuerySnapshot> _ovCoopsStream = _makeCoopsStream();
  late Stream<QuerySnapshot> _ovVehiclesStream = _makeVehiclesStream();
  late Stream<QuerySnapshot> _ovQueuesStream = _makeQueuesStream();
  late Stream<QuerySnapshot> _ovComplaintsStream = _makeComplaintsStream();

  Stream<QuerySnapshot> _makeCoopsStream() => FirebaseFirestore.instance
      .collection('users')
      .where('role', isEqualTo: 'COOPERATIVE')
      .snapshots();

  // vehicles_live updates constantly: refresh the UI at most every 3 seconds.
  Stream<QuerySnapshot> _makeVehiclesStream() => _throttle<QuerySnapshot>(
        FirebaseFirestore.instance.collection('vehicles_live').snapshots(),
        const Duration(seconds: 3),
      );

  Stream<QuerySnapshot> _makeQueuesStream() =>
      FirebaseFirestore.instance.collection('terminals_queue').snapshots();

  // Newest 100 only, sorted by the server instead of downloading everything.
  Stream<QuerySnapshot> _makeComplaintsStream() => FirebaseFirestore.instance
      .collection('complaints')
      .orderBy('created_at', descending: true)
      .limit(100)
      .snapshots();

  Stream<QuerySnapshot> _makeAuditsStream() => FirebaseFirestore.instance
      .collection('queue_audit_logs')
      .orderBy('timestamp', descending: true)
      .limit(100)
      .snapshots();

  void _retryStreams() {
    if (!mounted) return;
    setState(() {
      _coopsStream = _makeCoopsStream();
      _vehiclesStream = _makeVehiclesStream();
      _queuesStream = _makeQueuesStream();
      _complaintsStream = _makeComplaintsStream();
      _auditsStream = _makeAuditsStream();
      _ovCoopsStream = _makeCoopsStream();
      _ovVehiclesStream = _makeVehiclesStream();
      _ovQueuesStream = _makeQueuesStream();
      _ovComplaintsStream = _makeComplaintsStream();
    });
  }

  /// Emits the first event immediately, then at most one (the latest) event
  /// per [every]. Broadcast so tabs can re-subscribe after being disposed.
  static Stream<T> _throttle<T>(Stream<T> source, Duration every) {
    StreamSubscription<T>? sub;
    Timer? timer;
    T? pending;
    var hasPending = false;
    late final StreamController<T> c;
    c = StreamController<T>.broadcast(
      onListen: () {
        var first = true;
        sub = source.listen(
          (e) {
            if (first) {
              first = false;
              c.add(e);
              return;
            }
            pending = e;
            hasPending = true;
            timer ??= Timer(every, () {
              timer = null;
              if (hasPending && !c.isClosed) {
                hasPending = false;
                c.add(pending as T);
              }
            });
          },
          onError: c.addError,
          onDone: () => c.close(),
        );
      },
      onCancel: () {
        timer?.cancel();
        timer = null;
        hasPending = false;
        final old = sub;
        sub = null;
        old?.cancel();
      },
    );
    return c.stream;
  }

  static const List<_AdminSection> _sections = _AdminSection.values;

  _AdminSection get _current =>
      _sections[_tabController.index.clamp(0, _sections.length - 1)];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _sections.length, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _coopSearchCtrl.dispose();
    _reportSearchCtrl.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _goTo(_AdminSection section) {
    final i = _sections.indexOf(section);
    if (i >= 0) {
      _tabController.animateTo(i, duration: Duration.zero);
    }
  }

  Future<void> _logout() async {
    await StaffAuth.signOut();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  String _todayLabel() {
    const wd = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday'
    ];
    const mo = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    final n = DateTime.now();
    return '${wd[n.weekday - 1]}, ${mo[n.month - 1]} ${n.day}';
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} hr ago';
    return '${d.inDays} d ago';
  }

  String _formatRouteDisplayName(String rawRouteId) {
    String clean =
        rawRouteId.replaceAll('ROUTE_', '').replaceAll('_', ' ').trim();
    if (clean.toUpperCase() == 'GUINSANGAN') return 'San Jose - Guinsang-an';
    if (clean.toUpperCase() == 'ANINIY') return 'San Jose - Anini-y';
    if (clean.toUpperCase() == 'DAO') return 'San Jose - Dao';
    final words = clean.toLowerCase().split(' ').map((w) {
      if (w.isEmpty) return '';
      return '${w[0].toUpperCase()}${w.substring(1)}';
    }).join(' ');
    return words.toLowerCase().startsWith('san jose')
        ? words
        : 'San Jose - $words';
  }

  // ───────────────────────────────────────────────────────────────────────────
  // ONE-TIME ACCOUNT MIGRATION
  // ───────────────────────────────────────────────────────────────────────────
  Future<void> _migrateAccounts() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Migrate staff accounts',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
        ),
        content: const Text(
          'This creates a Firebase login for every staff account that does not '
          'have one yet (username@jeepes.ph, with their current PIN as the '
          'password), then removes the stored plain-text PIN.\n\n'
          'Every PIN must be at least 6 digits. Continue?',
          style: TextStyle(fontSize: 13.5, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryNavy,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Migrate'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Migrating accounts... please wait.'),
        duration: Duration(seconds: 4),
      ),
    );

    final myUid = FirebaseAuth.instance.currentUser?.uid;
    final snap = await FirebaseFirestore.instance.collection('users').get();
    int created = 0;
    int skipped = 0;
    final failures = <String>[];

    for (final doc in snap.docs) {
      final data = doc.data();
      final role = (data['role'] ?? '').toString().trim().toUpperCase();
      final alreadyDone = (data['auth_uid'] ?? '').toString().isNotEmpty;

      if (role == 'SUPER_ADMIN' || doc.id == myUid || alreadyDone) {
        skipped++;
        continue;
      }

      final username = (data['username'] ?? '').toString().trim();
      final pin = (data['pin_code'] ?? '').toString().trim();

      if (role.isEmpty) {
        failures.add('${doc.id}: no role set');
        continue;
      }
      if (username.isEmpty) {
        failures.add('${doc.id}: no username');
        continue;
      }
      if (pin.length < StaffAuth.minPinLength) {
        failures.add(
            '${doc.id}: pin_code must be 6+ digits (edit it in Firestore first)');
        continue;
      }

      try {
        final uid = await StaffAuth.createAccount(username, pin);
        await StaffAuth.writeRole(uid, role, doc.id, username);
        await doc.reference.update({
          'auth_uid': uid,
          'pin_code': FieldValue.delete(),
        });
        created++;
      } catch (e) {
        failures.add('${doc.id}: $e');
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Migration finished',
            style: TextStyle(fontWeight: FontWeight.w800)),
        content: SingleChildScrollView(
          child: Text(
            'Created: $created\nSkipped (already done / admin): $skipped\n'
            'Failed: ${failures.length}'
            '${failures.isEmpty ? '' : '\n\n${failures.join('\n')}'}',
            style: const TextStyle(fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // FLEET MATCHING HELPER
  // ───────────────────────────────────────────────────────────────────────────
  Map<String, List<QueryDocumentSnapshot>> _groupFleetByCoop(
    List<QueryDocumentSnapshot> coops,
    List<QueryDocumentSnapshot> vehicles,
    List<String> unlinkedOut,
  ) {
    final coopKeys = <String, List<String>>{};
    for (final c in coops) {
      final cd = c.data() as Map<String, dynamic>;
      final cid =
          (cd['cooperative_id'] ?? c.id).toString().trim().toLowerCase();
      final cname = (cd['cooperative_name'] ?? cd['coop_name'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      coopKeys[c.id] = [cid, cname];
    }

    final map = <String, List<QueryDocumentSnapshot>>{
      for (final c in coops) c.id: <QueryDocumentSnapshot>[],
    };

    for (final v in vehicles) {
      final vd = v.data() as Map<String, dynamic>;
      final vId = (vd['cooperative_id'] ?? '').toString().trim().toLowerCase();
      final vName =
          (vd['cooperative_name'] ?? '').toString().trim().toLowerCase();
      String? ownerDocId;
      for (final e in coopKeys.entries) {
        final idMatch = vId.isNotEmpty && vId == e.value[0];
        final nameMatch =
            vName.isNotEmpty && e.value[1].isNotEmpty && vName == e.value[1];
        if (idMatch || nameMatch) {
          ownerDocId = e.key;
          break;
        }
      }
      if (ownerDocId == null) {
        unlinkedOut.add((vd['plate_number'] ?? v.id).toString());
      } else {
        map[ownerDocId]!.add(v);
      }
    }
    return map;
  }

  // ===========================================================================
  // TAB 1: NETWORK OVERVIEW
  // ===========================================================================
  Widget _buildOverviewTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: _ovCoopsStream,
      builder: (context, coopSnap) => StreamBuilder<QuerySnapshot>(
        stream: _ovVehiclesStream,
        builder: (context, vehSnap) => StreamBuilder<QuerySnapshot>(
          stream: _ovQueuesStream,
          builder: (context, qSnap) => StreamBuilder<QuerySnapshot>(
            stream: _ovComplaintsStream,
            builder: (context, compSnap) {
              if (coopSnap.hasError) {
        return _StreamErrorView(error: coopSnap.error, onRetry: _retryStreams);
      }
      if (!coopSnap.hasData) {
        return _SlowLoadNotice(onRetry: _retryStreams);
      }
              return _overviewBody(
                coopSnap.data?.docs ?? const <QueryDocumentSnapshot>[],
                vehSnap.data?.docs ?? const <QueryDocumentSnapshot>[],
                qSnap.data?.docs ?? const <QueryDocumentSnapshot>[],
                compSnap.data?.docs ?? const <QueryDocumentSnapshot>[],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _overviewBody(
    List<QueryDocumentSnapshot> coops,
    List<QueryDocumentSnapshot> vehicles,
    List<QueryDocumentSnapshot> queues,
    List<QueryDocumentSnapshot> complaints,
  ) {
    Map<String, dynamic> m(QueryDocumentSnapshot d) =>
        d.data() as Map<String, dynamic>;

    int enRoute = 0, standby = 0, seats = 0, cap = 0;
    for (final d in vehicles) {
      final v = m(d);
      final live =
          (v['current_status'] ?? 'STANDBY').toString().toUpperCase() ==
              'EN_ROUTE';
      if (live) {
        enRoute++;
        seats += (v['passenger_count'] as num?)?.toInt() ?? 0;
        cap += (v['max_capacity'] as num?)?.toInt() ?? 20;
      } else {
        standby++;
      }
    }

    final unlinkedPlates = <String>[];
    final fleetByCoop = _groupFleetByCoop(coops, vehicles, unlinkedPlates);

    int coopsWithoutCpc = 0;
    for (final c in coops) {
      final cd = m(c);
      final cpc =
          (cd['franchise_case_number'] ?? cd['cpc_case_number'] ?? '')
              .toString()
              .trim();
      if (cpc.isEmpty) coopsWithoutCpc++;
    }

    int unresolvedComplaints = 0;
    for (final c in complaints) {
      final status = (m(c)['status'] ?? '').toString().toUpperCase();
      if (!status.contains('RESOLVED')) unresolvedComplaints++;
    }

    int totalQueuedUnits = 0;
    int activeBoardingBays = 0;
    for (final q in queues) {
      final qm = m(q);
      final active = (qm['active_loading_vehicle'] ?? 'None').toString().trim();
      if (active.isNotEmpty && active != 'None' && active != 'null') {
        activeBoardingBays++;
      }
      totalQueuedUnits +=
          ((qm['queued_vehicles'] as List<dynamic>?)?.length ?? 0) +
              ((qm['standby_staged_vehicles'] as List<dynamic>?)?.length ?? 0);
    }

    final fill = cap > 0 ? seats / cap : 0.0;

    final header = Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_greeting()}, Super Admin',
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
              color: AppColors.darkSlate,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${_todayLabel()}  •  Antique Provincial PUJ Network',
            style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
          ),
        ],
      ),
    );

    // Network Fleet Status Board
    final fleetBoard = CoopPanel(
      title: 'Provincial fleet right now',
      subtitle: 'All tracked jeepneys across enrolled cooperatives',
      trailing: TextButton(
        onPressed: () => _goTo(_AdminSection.cooperatives),
        child: const Text(
          'View cooperatives',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      child: vehicles.isEmpty
          ? const CoopEmptyState(
              icon: Icons.directions_bus_outlined,
              title: 'No vehicles in network yet',
              message:
                  'Units enrolled by transport cooperatives will appear here automatically.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '$enRoute',
                      style: const TextStyle(
                        fontSize: 44,
                        height: 1,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -1.5,
                        color: AppColors.darkSlate,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(
                        'of ${vehicles.length} unit${vehicles.length == 1 ? '' : 's'} on the road',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                CoopSplitBar(
                  height: 14,
                  segments: [
                    CoopSegment(enRoute, CoopTone.success.fg),
                    CoopSegment(standby, const Color(0xFF93C5FD)),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 18,
                  runSpacing: 6,
                  children: [
                    CoopLegendDot(CoopTone.success.fg, 'On the road  $enRoute'),
                    CoopLegendDot(
                        const Color(0xFF93C5FD), 'Standby  $standby'),
                    if (unlinkedPlates.isNotEmpty)
                      CoopLegendDot(CoopTone.warning.fg,
                          'Unlinked  ${unlinkedPlates.length}'),
                  ],
                ),
                if (enRoute > 0) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Provincial seat occupancy (active trips)',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                      Text(
                        '$seats / $cap seats (${(fill * 100).round()}%)',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          color: AppColors.darkSlate,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: fill.clamp(0.0, 1.0),
                      minHeight: 7,
                      backgroundColor: const Color(0xFFE2E8F0),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          AppColors.commuterTeal),
                    ),
                  ),
                ],
              ],
            ),
    );

    // Terminal hubs panel
    final terminalsPanel = CoopPanel(
      title: 'Terminal hubs & line-ups',
      subtitle: 'Live boarding bays and waiting queues across terminals',
      child: _buildTerminalSummaryRows(queues),
    );

    // Needs Attention items
    final attention = <Widget>[];
    if (unlinkedPlates.isNotEmpty) {
      attention.add(_attentionRow(
        CoopTone.warning,
        Icons.link_off_rounded,
        '${unlinkedPlates.length} unit${unlinkedPlates.length == 1 ? ' is' : 's are'} not linked to a cooperative',
        'Plates: ${unlinkedPlates.take(5).join(', ')}${unlinkedPlates.length > 5 ? '…' : ''}',
        'Review coops',
        () => _goTo(_AdminSection.cooperatives),
      ));
    }
    if (coopsWithoutCpc > 0) {
      attention.add(_attentionRow(
        CoopTone.info,
        Icons.verified_user_outlined,
        '$coopsWithoutCpc cooperative${coopsWithoutCpc == 1 ? ' has' : 's have'} no CPC franchise on file',
        'Set their CPC case number so they can enroll fleet units.',
        'Manage',
        () {
          setState(() => _coopFilter = 'NO_CPC');
          _goTo(_AdminSection.cooperatives);
        },
      ));
    }
    if (unresolvedComplaints > 0) {
      attention.add(_attentionRow(
        CoopTone.danger,
        Icons.report_problem_outlined,
        '$unresolvedComplaints unresolved passenger report${unresolvedComplaints == 1 ? '' : 's'}',
        'Pending verification or cooperative disciplinary action.',
        'Open reports',
        () {
          setState(() => _reportsSegment = 0);
          _goTo(_AdminSection.reports);
        },
      ));
    }

    final attentionPanel = CoopPanel(
      title: 'Network oversight alerts',
      child: attention.isEmpty
          ? Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: CoopTone.success.bg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.check_rounded,
                      size: 20, color: CoopTone.success.fg),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'All cooperatives, fleet links, and reports are in good standing.',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.darkSlate,
                    ),
                  ),
                ),
              ],
            )
          : Column(
              children: [
                for (int i = 0; i < attention.length; i++) ...[
                  if (i > 0) const SizedBox(height: 10),
                  attention[i],
                ],
              ],
            ),
    );

    // Cooperative standings summary
    final coopStandingsPanel = CoopPanel(
      title: 'Cooperative fleet distribution',
      subtitle: 'Enrolled units per cooperative',
      trailing: TextButton(
        onPressed: () => _goTo(_AdminSection.cooperatives),
        child: const Text('Manage all',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      child: coops.isEmpty
          ? CoopEmptyState(
              icon: Icons.corporate_fare_rounded,
              title: 'No cooperatives provisioned',
              message: 'Add your first transport cooperative to begin.',
              actionLabel: 'Add cooperative',
              onAction: () => _showCreateCoopDialog(context),
            )
          : Column(
              children: [
                for (int i = 0; i < coops.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 20, color: AppColors.borderSubtle),
                  _buildCoopDistributionRow(
                    coops[i],
                    fleetByCoop[coops[i].id] ?? const <QueryDocumentSnapshot>[],
                    vehicles.length,
                  ),
                ],
              ],
            ),
    );

    final quickActionsPanel = CoopPanel(
      title: 'System administration',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _quickAction(
            Icons.add_business_rounded,
            'Provision cooperative',
            () => _showCreateCoopDialog(context),
          ),
          _quickAction(
            Icons.sync_alt_rounded,
            'Migrate legacy PIN accounts',
            _migrateAccounts,
          ),
          _quickAction(
            Icons.fact_check_outlined,
            'Review incident reports',
            () {
              setState(() => _reportsSegment = 0);
              _goTo(_AdminSection.reports);
            },
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final wide = w >= 900;
        final pad = wide ? 28.0 : 16.0;

        final cols = w >= 1000 ? 4 : 2;
        final inner = (w.clamp(0, 1240) as num).toDouble() - pad * 2;
        final tileW = (inner - 10 * (cols - 1)) / cols;

        Widget tile(Widget t) => SizedBox(width: tileW, child: t);

        final tiles = Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            tile(CoopStatTile(
              label: 'Cooperatives',
              value: '${coops.length}',
              icon: Icons.business_rounded,
              tone: CoopTone.info,
              caption: coopsWithoutCpc > 0
                  ? '$coopsWithoutCpc missing CPC'
                  : 'All accredited',
              onTap: () => _goTo(_AdminSection.cooperatives),
            )),
            tile(CoopStatTile(
              label: 'Total fleet',
              value: '${vehicles.length}',
              icon: Icons.directions_bus_rounded,
              tone: CoopTone.success,
              caption: '$enRoute on the road',
              onTap: () => _goTo(_AdminSection.cooperatives),
            )),
            tile(CoopStatTile(
              label: 'Units in terminals',
              value: '${totalQueuedUnits + activeBoardingBays}',
              icon: Icons.storefront_rounded,
              tone: CoopTone.neutral,
              caption: '$activeBoardingBays boarding at Spot 1',
            )),
            tile(CoopStatTile(
              label: 'Open reports',
              value: '$unresolvedComplaints',
              icon: Icons.report_problem_rounded,
              tone:
                  unresolvedComplaints > 0 ? CoopTone.danger : CoopTone.success,
              caption: unresolvedComplaints > 0
                  ? '${complaints.length} total filed'
                  : 'All resolved',
              onTap: () {
                setState(() => _reportsSegment = 0);
                _goTo(_AdminSection.reports);
              },
            )),
          ],
        );

        final Widget content;
        if (wide) {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              const SizedBox(height: 16),
              tiles,
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      children: [
                        fleetBoard,
                        const SizedBox(height: 16),
                        terminalsPanel,
                        const SizedBox(height: 16),
                        coopStandingsPanel,
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: Column(
                      children: [
                        attentionPanel,
                        const SizedBox(height: 16),
                        quickActionsPanel,
                      ],
                    ),
                  ),
                ],
              ),
            ],
          );
        } else {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              const SizedBox(height: 14),
              attentionPanel,
              const SizedBox(height: 14),
              tiles,
              const SizedBox(height: 14),
              fleetBoard,
              const SizedBox(height: 14),
              terminalsPanel,
              const SizedBox(height: 14),
              coopStandingsPanel,
              const SizedBox(height: 14),
              quickActionsPanel,
            ],
          );
        }

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1240),
            child: ListView(
              padding: EdgeInsets.fromLTRB(pad, 18, pad, 32),
              children: [content],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTerminalSummaryRows(List<QueryDocumentSnapshot> docs) {
    final terminals = <Map<String, dynamic>>[
      {
        'name': 'Dalipe 1 (Northbound)',
        'subtitle': 'Sibalom • Belison • Patnongon • Bugasong',
        'id': 'TERM_DALIPE_1',
        'tone': CoopTone.info,
      },
      {
        'name': 'Dalipe 2 (Southbound & Interior)',
        'subtitle': 'Guinsang-an • Lindero • Anini-y • San Remigio',
        'id': 'TERM_DALIPE_2',
        'tone': CoopTone.success,
      },
      {
        'name': 'Robinsons Terminal',
        'subtitle': 'Guinsang-an • Lindero • Dao • Anini-y',
        'id': 'TERM_ROBINSONS',
        'tone': CoopTone.neutral,
      },
    ];

    return Column(
      children: [
        for (int i = 0; i < terminals.length; i++) ...[
          if (i > 0) const Divider(height: 22, color: AppColors.borderSubtle),
          Builder(builder: (context) {
            final t = terminals[i];
            final id = t['id'] as String;
            final tone = t['tone'] as CoopTone;
            int queued = 0;
            int standby = 0;
            int boarding = 0;
            int routes = 0;

            for (final d in docs) {
              if (!d.id.startsWith('${id}_')) continue;
              routes++;
              final m = d.data() as Map<String, dynamic>;
              final active =
                  (m['active_loading_vehicle'] ?? 'None').toString().trim();
              if (active.isNotEmpty && active != 'None' && active != 'null') {
                boarding++;
              }
              queued += (m['queued_vehicles'] as List<dynamic>?)?.length ?? 0;
              standby +=
                  (m['standby_staged_vehicles'] as List<dynamic>?)?.length ?? 0;
            }

            final totalHere = boarding + queued + standby;

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: tone.bg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.storefront_rounded,
                      size: 20, color: tone.fg),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t['name'] as String,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: AppColors.darkSlate,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${t['subtitle']}  •  $routes route queue${routes == 1 ? '' : 's'}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          CoopPill(
                            '$boarding boarding',
                            tone: boarding > 0
                                ? CoopTone.success
                                : CoopTone.neutral,
                            icon: Icons.airline_seat_recline_normal_rounded,
                          ),
                          CoopPill(
                            '$queued on-deck',
                            tone:
                                queued > 0 ? CoopTone.info : CoopTone.neutral,
                          ),
                          if (standby > 0)
                            CoopPill(
                              '$standby standby',
                              tone: CoopTone.warning,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$totalHere unit${totalHere == 1 ? '' : 's'}',
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w900,
                    color: AppColors.darkSlate,
                  ),
                ),
              ],
            );
          }),
        ],
      ],
    );
  }

  Widget _buildCoopDistributionRow(
    QueryDocumentSnapshot coopDoc,
    List<QueryDocumentSnapshot> coopUnits,
    int totalNetworkFleet,
  ) {
    final data = coopDoc.data() as Map<String, dynamic>;
    final name =
        (data['cooperative_name'] ?? data['coop_name'] ?? 'Unnamed Coop')
            .toString();
    final cpc =
        (data['franchise_case_number'] ?? data['cpc_case_number'] ?? '')
            .toString()
            .trim();
    int live = 0;
    for (final u in coopUnits) {
      final um = u.data() as Map<String, dynamic>;
      if ((um['current_status'] ?? '').toString().toUpperCase() == 'EN_ROUTE') {
        live++;
      }
    }
    final standby = coopUnits.length - live;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _showCoopDetailsModal(coopDoc, coopUnits),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppColors.darkSlate,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${coopUnits.length} unit${coopUnits.length == 1 ? '' : 's'} ($live live)',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color:
                        live > 0 ? CoopTone.success.fg : AppColors.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              cpc.isNotEmpty ? 'CPC: $cpc' : 'No CPC franchise number set',
              style: TextStyle(
                fontSize: 11.5,
                color: cpc.isNotEmpty
                    ? AppColors.textMuted
                    : CoopTone.warning.fg,
              ),
            ),
            const SizedBox(height: 8),
            CoopSplitBar(
              height: 6,
              segments: [
                CoopSegment(live, CoopTone.success.fg),
                CoopSegment(standby, const Color(0xFF93C5FD)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _attentionRow(
    CoopTone tone,
    IconData icon,
    String title,
    String body,
    String actionLabel,
    VoidCallback onTap,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.line),
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: tone.fg),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.darkSlate,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              foregroundColor: tone.fg,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 36),
            ),
            child: Text(
              actionLabel,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickAction(IconData icon, String label, VoidCallback onTap) {
    return Material(
      color: AppColors.backgroundSlate,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: AppColors.primaryNavy),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.darkSlate,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // TAB 2: COOPERATIVES MANAGEMENT
  // ===========================================================================
  Widget _buildCooperativesTab() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isDesktop = constraints.maxWidth >= 850;
        final double pad = isDesktop ? 28 : 16;

        return StreamBuilder<QuerySnapshot>(
          stream: _coopsStream,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
        return _StreamErrorView(error: snapshot.error, onRetry: _retryStreams);
      }
      if (!snapshot.hasData) {
        return _SlowLoadNotice(onRetry: _retryStreams);
      }

            final List<QueryDocumentSnapshot> docs = [
              ...(snapshot.data?.docs ?? const <QueryDocumentSnapshot>[]),
            ];
            docs.sort((a, b) {
              final ta = (a.data() as Map<String, dynamic>)['created_at'];
              final tb = (b.data() as Map<String, dynamic>)['created_at'];
              final da = ta is Timestamp ? ta.millisecondsSinceEpoch : 0;
              final db = tb is Timestamp ? tb.millisecondsSinceEpoch : 0;
              return db.compareTo(da);
            });

            return StreamBuilder<QuerySnapshot>(
              stream: _vehiclesStream,
              builder: (context, vehSnap) {
                final List<QueryDocumentSnapshot> vehicles =
                    vehSnap.data?.docs ?? const <QueryDocumentSnapshot>[];
                final unlinked = <String>[];
                final fleetByCoop = _groupFleetByCoop(docs, vehicles, unlinked);

                int withFleetCount = 0;
                int missingCpcCount = 0;
                for (final d in docs) {
                  final data = d.data() as Map<String, dynamic>;
                  if ((fleetByCoop[d.id]?.length ?? 0) > 0) withFleetCount++;
                  final cpc = (data['franchise_case_number'] ??
                          data['cpc_case_number'] ??
                          '')
                      .toString()
                      .trim();
                  if (cpc.isEmpty) missingCpcCount++;
                }

                final q = _coopSearchQuery.trim().toLowerCase();
                final List<QueryDocumentSnapshot> filtered = docs.where((d) {
                  final data = d.data() as Map<String, dynamic>;
                  final name =
                      (data['cooperative_name'] ?? data['coop_name'] ?? '')
                          .toString()
                          .toLowerCase();
                  final uname =
                      (data['username'] ?? '').toString().toLowerCase();
                  final cid = (data['cooperative_id'] ?? d.id)
                      .toString()
                      .toLowerCase();
                  final cpc = (data['franchise_case_number'] ??
                          data['cpc_case_number'] ??
                          '')
                      .toString()
                      .toLowerCase();

                  if (q.isNotEmpty &&
                      !name.contains(q) &&
                      !uname.contains(q) &&
                      !cid.contains(q) &&
                      !cpc.contains(q)) {
                    return false;
                  }
                  if (_coopFilter == 'WITH_FLEET' &&
                      (fleetByCoop[d.id]?.isEmpty ?? true)) {
                    return false;
                  }
                  if (_coopFilter == 'NO_CPC' && cpc.trim().isNotEmpty) {
                    return false;
                  }
                  return true;
                }).toList();

                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1240),
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(pad, 16, pad, 96),
                      children: [
                        if (vehSnap.hasData && unlinked.isNotEmpty) ...[
                          Container(
                            margin: const EdgeInsets.only(bottom: 14),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: CoopTone.warning.bg,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: CoopTone.warning.line),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.link_off_rounded,
                                    color: CoopTone.warning.fg, size: 20),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    '${unlinked.length} vehicle${unlinked.length == 1 ? ' is' : 's are'} in vehicles_live but not matched to any cooperative: ${unlinked.join(', ')}',
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.darkSlate,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        CoopSearchField(
                          controller: _coopSearchCtrl,
                          hint:
                              'Search cooperative name, @username, ID, or CPC number',
                          onChanged: (v) =>
                              setState(() => _coopSearchQuery = v),
                        ),
                        const SizedBox(height: 12),
                        CoopChoiceChips(
                          value: _coopFilter,
                          onChanged: (v) => setState(() => _coopFilter = v),
                          choices: [
                            CoopChoice('ALL', 'All cooperatives',
                                count: docs.length),
                            CoopChoice('WITH_FLEET', 'Active fleet',
                                count: withFleetCount),
                            CoopChoice('NO_CPC', 'Missing CPC',
                                count: missingCpcCount),
                          ],
                        ),
                        const SizedBox(height: 14),
                        if (docs.isEmpty)
                          CoopEmptyState(
                            icon: Icons.corporate_fare_rounded,
                            title: 'No cooperatives provisioned yet',
                            message:
                                'Tap "Add cooperative" to register the first transport cooperative.',
                            actionLabel: 'Add cooperative',
                            onAction: () => _showCreateCoopDialog(context),
                          )
                        else if (filtered.isEmpty)
                          CoopEmptyState(
                            icon: Icons.search_off_rounded,
                            title: 'No cooperatives match',
                            message: 'Try clearing your search or filter.',
                            actionLabel: 'Reset filters',
                            onAction: () => setState(() {
                              _coopSearchCtrl.clear();
                              _coopSearchQuery = '';
                              _coopFilter = 'ALL';
                            }),
                          )
                        else if (isDesktop)
                          GridView.builder(
                            physics: const NeverScrollableScrollPhysics(),
                            shrinkWrap: true,
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 580,
                              mainAxisExtent: 195,
                              crossAxisSpacing: 14,
                              mainAxisSpacing: 14,
                            ),
                            itemCount: filtered.length,
                            itemBuilder: (context, i) {
                              final doc = filtered[i];
                              return _buildCoopCard(
                                doc,
                                fleetByCoop[doc.id] ??
                                    const <QueryDocumentSnapshot>[],
                              );
                            },
                          )
                        else
                          ...filtered.map(
                            (doc) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _buildCoopCard(
                                doc,
                                fleetByCoop[doc.id] ??
                                    const <QueryDocumentSnapshot>[],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildCoopCard(
    QueryDocumentSnapshot doc,
    List<QueryDocumentSnapshot> units,
  ) {
    final data = doc.data() as Map<String, dynamic>;
    final coopName =
        (data['cooperative_name'] ?? data['coop_name'] ?? 'Unnamed Coop')
            .toString();
    final coopId = (data['cooperative_id'] ?? doc.id).toString();
    final username = (data['username'] ?? '').toString();
    final email = (data['email'] ?? '').toString();
    final cpc =
        (data['franchise_case_number'] ?? data['cpc_case_number'] ?? '')
            .toString()
            .trim();
    final rawRoutes = data['authorized_routes'];
    final routes = (rawRoutes is List)
        ? rawRoutes.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    int live = 0;
    for (final u in units) {
      final um = u.data() as Map<String, dynamic>;
      if ((um['current_status'] ?? '').toString().toUpperCase() == 'EN_ROUTE') {
        live++;
      }
    }

    final loginLabel = username.isNotEmpty
        ? '@$username'
        : (email.isNotEmpty ? email : 'No login set');

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderSubtle),
        boxShadow: const [
          BoxShadow(
              color: Color(0x0A0F172A), blurRadius: 10, offset: Offset(0, 3)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _showCoopDetailsModal(doc, units),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: AppColors.primaryNavy.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.business_rounded,
                        color: AppColors.primaryNavy,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            coopName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              color: AppColors.darkSlate,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$loginLabel  •  ID: $coopId',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    CoopPill(
                      '${units.length} unit${units.length == 1 ? '' : 's'}',
                      tone: units.isNotEmpty ? CoopTone.info : CoopTone.neutral,
                      icon: Icons.directions_bus_rounded,
                    ),
                  ],
                ),
                const Divider(height: 18, color: AppColors.borderSubtle),
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          CoopPill(
                            cpc.isNotEmpty ? 'CPC: $cpc' : 'No CPC set',
                            tone: cpc.isNotEmpty
                                ? CoopTone.success
                                : CoopTone.warning,
                            icon: cpc.isNotEmpty
                                ? Icons.verified_user_rounded
                                : Icons.gpp_maybe_rounded,
                          ),
                          if (live > 0)
                            CoopPill(
                              '$live on road',
                              tone: CoopTone.success,
                            ),
                          CoopPill(
                            routes.isEmpty
                                ? 'No routes set'
                                : '${routes.length} route${routes.length == 1 ? '' : 's'}',
                            tone: CoopTone.neutral,
                            icon: Icons.alt_route_rounded,
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.textMuted,
                      size: 20,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // COOPERATIVE DETAILS & EDIT MODAL (CPC, AUTHORIZED ROUTES, PIN RESET)
  // ───────────────────────────────────────────────────────────────────────────
  void _showCoopDetailsModal(
    QueryDocumentSnapshot coopDoc,
    List<QueryDocumentSnapshot> units,
  ) {
    final data = coopDoc.data() as Map<String, dynamic>;
    final coopName =
        (data['cooperative_name'] ?? data['coop_name'] ?? 'Unnamed Coop')
            .toString();
    final coopId = (data['cooperative_id'] ?? coopDoc.id).toString();
    final username = (data['username'] ?? '').toString();
    final cpcCtrl = TextEditingController(
      text: (data['franchise_case_number'] ?? data['cpc_case_number'] ?? '')
          .toString(),
    );

    final rawRoutes = data['authorized_routes'];
    final selectedRoutes = <String>{
      if (rawRoutes is List)
        for (final r in rawRoutes) r.toString().trim(),
    };

    bool isSaving = false;

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setModalState) {
          return SafeArea(
            child: Dialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 520, maxHeight: 700),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                              color: AppColors.primaryNavy.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.business_rounded,
                              color: AppColors.primaryNavy,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  coopName,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.darkSlate,
                                  ),
                                ),
                                Text(
                                  '@$username  •  ID: $coopId  •  ${units.length} units',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close_rounded,
                                color: AppColors.textMuted),
                            onPressed: () => Navigator.pop(dialogCtx),
                          ),
                        ],
                      ),
                      const Divider(height: 22, color: AppColors.borderSubtle),
                      const Text(
                        'Consolidated Franchise (CPC / Prangkisa No.)',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: AppColors.darkSlate,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: cpcCtrl,
                        textCapitalization: TextCapitalization.characters,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700),
                        decoration: InputDecoration(
                          hintText: 'e.g. CPC-2024-VI-0892',
                          isDense: true,
                          filled: true,
                          fillColor: AppColors.backgroundSlate,
                          prefixIcon: const Icon(Icons.verified_user_outlined,
                              size: 18, color: AppColors.primaryNavy),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide:
                                const BorderSide(color: AppColors.borderSubtle),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide:
                                const BorderSide(color: AppColors.borderSubtle),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Authorized Route Corridors',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: AppColors.darkSlate,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Select the routes this cooperative is accredited to operate and dispatch:',
                        style:
                            TextStyle(fontSize: 12, color: AppColors.textMuted),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: RouteProcesses.all.keys.map((rId) {
                          final isSel = selectedRoutes.contains(rId);
                          return FilterChip(
                            label: Text(_formatRouteDisplayName(rId)),
                            selected: isSel,
                            selectedColor: AppColors.commuterTealLight,
                            checkmarkColor: AppColors.primaryNavy,
                            labelStyle: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: isSel
                                  ? AppColors.primaryNavy
                                  : AppColors.darkSlate,
                            ),
                            onSelected: (v) {
                              setModalState(() {
                                if (v) {
                                  selectedRoutes.add(rId);
                                } else {
                                  selectedRoutes.remove(rId);
                                }
                              });
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.lock_reset_rounded,
                                  size: 17),
                              label: const Text(
                                'Reset PIN',
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.primaryNavy,
                                side: const BorderSide(
                                    color: AppColors.borderSubtle),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                              onPressed: () {
                                Navigator.pop(dialogCtx);
                                _showResetCoopPinModal(coopDoc.id, coopName);
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primaryNavy,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                              onPressed: isSaving
                                  ? null
                                  : () async {
                                      setModalState(() => isSaving = true);
                                      try {
                                        final cpcVal = cpcCtrl.text
                                            .trim()
                                            .toUpperCase();
                                        await coopDoc.reference.update({
                                          'franchise_case_number': cpcVal,
                                          'authorized_routes':
                                              selectedRoutes.toList(),
                                          'updated_at':
                                              FieldValue.serverTimestamp(),
                                        });
                                        if (!mounted) return;
                                        Navigator.pop(dialogCtx);
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text(
                                                'Updated "$coopName" settings.'),
                                            backgroundColor:
                                                const Color(0xFF059669),
                                          ),
                                        );
                                      } catch (e) {
                                        setModalState(() => isSaving = false);
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text('Failed: $e'),
                                            backgroundColor:
                                                AppColors.errorCrimson,
                                          ),
                                        );
                                      }
                                    },
                              child: isSaving
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          color: Colors.white, strokeWidth: 2),
                                    )
                                  : const Text(
                                      'Save Changes',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w800),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _showResetCoopPinModal(String coopDocId, String coopName) {
    final pinCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool obscure = true;
    bool saving = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Reset PIN for $coopName',
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: pinCtrl,
              keyboardType: TextInputType.number,
              obscureText: obscure,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(8),
              ],
              decoration: InputDecoration(
                labelText: 'New 6-8 digit PIN',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                suffixIcon: IconButton(
                  icon: Icon(obscure
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                  onPressed: () => setS(() => obscure = !obscure),
                ),
              ),
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.length < 6 || t.length > 8) {
                  return 'PIN must be 6 to 8 digits';
                }
                return null;
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryNavy,
                foregroundColor: Colors.white,
              ),
              onPressed: saving
                  ? null
                  : () async {
                      if (!formKey.currentState!.validate()) return;
                      setS(() => saving = true);
                      try {
                        await StaffAuth.resetPin(
                          userDocId: coopDocId,
                          newPin: pinCtrl.text.trim(),
                        );
                        if (!mounted) return;
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content:
                                Text('PIN for "$coopName" reset successfully.'),
                            backgroundColor: const Color(0xFF059669),
                          ),
                        );
                      } catch (e) {
                        setS(() => saving = false);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Reset failed: $e'),
                            backgroundColor: AppColors.errorCrimson,
                          ),
                        );
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    )
                  : const Text('Update PIN'),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // TAB 3: REPORTS & QUEUE AUDITS
  // ===========================================================================
  Widget _buildReportsTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: CoopSegmented(
                labels: const ['Passenger complaints', 'Queue overrides'],
                icons: const [
                  Icons.report_problem_rounded,
                  Icons.swap_vert_circle_rounded,
                ],
                index: _reportsSegment,
                onChanged: (i) => setState(() => _reportsSegment = i),
              ),
            ),
          ),
        ),
        Expanded(
          child: _reportsSegment == 0
              ? _buildProvincialComplaintsList()
              : _buildProvincialAuditsList(),
        ),
      ],
    );
  }

  Widget _buildProvincialComplaintsList() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isDesktop = constraints.maxWidth >= 850;
        final double pad = isDesktop ? 28 : 16;

        return StreamBuilder<QuerySnapshot>(
          stream: _complaintsStream,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
        return _StreamErrorView(error: snapshot.error, onRetry: _retryStreams);
      }
      if (!snapshot.hasData) {
        return _SlowLoadNotice(onRetry: _retryStreams);
      }

            final List<QueryDocumentSnapshot> allDocs = [
              ...(snapshot.data?.docs ?? const <QueryDocumentSnapshot>[]),
            ];
            allDocs.sort((a, b) {
              final ta = (a.data() as Map<String, dynamic>)['created_at'];
              final tb = (b.data() as Map<String, dynamic>)['created_at'];
              final da = ta is Timestamp ? ta.millisecondsSinceEpoch : 0;
              final db = tb is Timestamp ? tb.millisecondsSinceEpoch : 0;
              return db.compareTo(da);
            });

            int pendingCount = 0;
            int reviewCount = 0;
            int resolvedCount = 0;
            for (final d in allDocs) {
              final s = (d.data() as Map<String, dynamic>)['status']
                      ?.toString()
                      .toUpperCase() ??
                  '';
              if (s.contains('RESOLVED')) {
                resolvedCount++;
              } else if (s.contains('REVIEW') || s.contains('INVESTIGAT')) {
                reviewCount++;
              } else {
                pendingCount++;
              }
            }

            final q = _reportSearchQuery.trim().toLowerCase();
            final List<QueryDocumentSnapshot> filtered = allDocs.where((d) {
              final m = d.data() as Map<String, dynamic>;
              final s = (m['status'] ?? '').toString().toUpperCase();
              if (_complaintStatusFilter == 'PENDING' &&
                  !s.contains('PENDING')) {
                return false;
              }
              if (_complaintStatusFilter == 'UNDER_REVIEW' &&
                  !(s.contains('REVIEW') || s.contains('INVESTIGAT'))) {
                return false;
              }
              if (_complaintStatusFilter == 'RESOLVED' &&
                  !s.contains('RESOLVED')) {
                return false;
              }

              if (q.isNotEmpty) {
                final plate =
                    (m['plate_number'] ?? '').toString().toLowerCase();
                final cat = (m['category'] ?? '').toString().toLowerCase();
                final desc = (m['description'] ?? '').toString().toLowerCase();
                if (!plate.contains(q) &&
                    !cat.contains(q) &&
                    !desc.contains(q)) {
                  return false;
                }
              }
              return true;
            }).toList();

            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1240),
                child: ListView(
                  padding: EdgeInsets.fromLTRB(pad, 16, pad, 40),
                  children: [
                    CoopSearchField(
                      controller: _reportSearchCtrl,
                      hint: 'Search plate number, category, or description',
                      onChanged: (v) => setState(() => _reportSearchQuery = v),
                    ),
                    const SizedBox(height: 12),
                    CoopChoiceChips(
                      value: _complaintStatusFilter,
                      onChanged: (v) =>
                          setState(() => _complaintStatusFilter = v),
                      choices: [
                        CoopChoice('ALL', 'All reports', count: allDocs.length),
                        CoopChoice('PENDING', 'Pending', count: pendingCount),
                        CoopChoice('UNDER_REVIEW', 'Under review',
                            count: reviewCount),
                        CoopChoice('RESOLVED', 'Resolved',
                            count: resolvedCount),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (filtered.isEmpty)
                      const CoopEmptyState(
                        icon: Icons.fact_check_outlined,
                        title: 'No matching passenger reports',
                        message: 'Try adjusting your search or status filter.',
                      )
                    else
                      ...filtered.map((doc) {
                        final m = doc.data() as Map<String, dynamic>;
                        final cat =
                            (m['category'] ?? 'Incident').toString();
                        final plate =
                            (m['plate_number'] ?? 'N/A').toString();
                        final desc = (m['description'] ?? '').toString();
                        final status = (m['status'] ?? 'PENDING_VERIFICATION')
                            .toString()
                            .toUpperCase();
                        final latestNote =
                            (m['latest_coop_comment'] ?? '').toString();
                        final ts =
                            (m['created_at'] as Timestamp?)?.toDate();

                        final CoopTone tone = status.contains('RESOLVED')
                            ? CoopTone.success
                            : (status.contains('REVIEW')
                                ? CoopTone.info
                                : CoopTone.warning);
                        final String statusLabel = status.contains('RESOLVED')
                            ? 'Resolved'
                            : (status.contains('REVIEW')
                                ? 'Under review'
                                : 'Pending');

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: AppColors.borderSubtle),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  CoopPlate(plate),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      cat,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.darkSlate,
                                      ),
                                    ),
                                  ),
                                  CoopPill(statusLabel, tone: tone),
                                ],
                              ),
                              if (desc.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  desc,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppColors.darkSlate,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                              if (latestNote.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: CoopTone.info.bg,
                                    borderRadius: BorderRadius.circular(8),
                                    border:
                                        Border.all(color: CoopTone.info.line),
                                  ),
                                  child: Text(
                                    'Coop Action: $latestNote',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: CoopTone.info.fg,
                                    ),
                                  ),
                                ),
                              ],
                              if (ts != null) ...[
                                const SizedBox(height: 6),
                                Text(
                                  'Filed ${_ago(ts)}',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildProvincialAuditsList() {
    return StreamBuilder<QuerySnapshot>(
      stream: _auditsStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
        return _StreamErrorView(error: snapshot.error, onRetry: _retryStreams);
      }
      if (!snapshot.hasData) {
        return _SlowLoadNotice(onRetry: _retryStreams);
      }

        final List<QueryDocumentSnapshot> docs = [
          ...(snapshot.data?.docs ?? const <QueryDocumentSnapshot>[]),
        ];
        docs.sort((a, b) {
          final ta = (a.data() as Map<String, dynamic>)['timestamp'];
          final tb = (b.data() as Map<String, dynamic>)['timestamp'];
          final da = ta is Timestamp ? ta.millisecondsSinceEpoch : 0;
          final db = tb is Timestamp ? tb.millisecondsSinceEpoch : 0;
          return db.compareTo(da);
        });

        if (docs.isEmpty) {
          return const CoopEmptyState(
            icon: Icons.verified_user_outlined,
            title: 'No queue overrides recorded',
            message:
                'Terminal dispatcher queue reorderings across all routes will appear here.',
          );
        }

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 40),
              itemCount: docs.length,
              itemBuilder: (context, index) {
                final data = docs[index].data() as Map<String, dynamic>;
                final reason =
                    (data['reason'] ?? 'Operational adjustment').toString();
                final dispatcher =
                    (data['dispatcher_name'] ?? 'Dispatcher').toString();
                final route = _formatRouteDisplayName(
                    (data['route_id'] ?? '').toString());
                final coops =
                    (data['affected_cooperative_names'] as List<dynamic>?)
                            ?.map((e) => e.toString())
                            .toList() ??
                        const <String>[];
                final isCross = coops.length > 1;
                final ts = (data['timestamp'] as Timestamp?)?.toDate();

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isCross
                          ? CoopTone.warning.line
                          : AppColors.borderSubtle,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          CoopPill(
                            isCross
                                ? 'Cross-cooperative override'
                                : 'Queue override',
                            tone: isCross ? CoopTone.warning : CoopTone.info,
                            icon: Icons.swap_vert_rounded,
                          ),
                          if (ts != null)
                            Text(
                              _ago(ts),
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppColors.textMuted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Reason: "$reason"',
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: AppColors.darkSlate,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$route  •  Authorized by $dispatcher${coops.isNotEmpty ? '  •  ${coops.join(' & ')}' : ''}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================
  // PROVISION COOPERATIVE DIALOG
  // ===========================================================================
  void _showCreateCoopDialog(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController();
    final usernameController = TextEditingController();
    final cpcController = TextEditingController();
    final emailController = TextEditingController();
    final pinController = TextEditingController();

    final selectedRoutes = <String>{'ROUTE_GUINSANGAN'};
    bool isSubmitting = false;

    InputDecoration deco(String label, IconData icon, {String? hint}) =>
        InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          prefixIcon: Icon(icon, size: 18, color: AppColors.primaryNavy),
          filled: true,
          fillColor: AppColors.backgroundSlate,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.borderSubtle),
          ),
        );

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return Dialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(22),
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: AppColors.commuterTealLight,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.add_business_rounded,
                              color: AppColors.primaryNavy,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Provision Cooperative',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.darkSlate,
                                  ),
                                ),
                                Text(
                                  'Create an accredited cooperative office account',
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color: AppColors.textMuted),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close_rounded,
                                color: AppColors.textMuted),
                            onPressed: isSubmitting
                                ? null
                                : () => Navigator.pop(dialogCtx),
                          ),
                        ],
                      ),
                      const Divider(height: 22, color: AppColors.borderSubtle),
                      TextFormField(
                        controller: nameController,
                        style: const TextStyle(fontSize: 14),
                        decoration: deco(
                          'Cooperative Name *',
                          Icons.corporate_fare_rounded,
                          hint: 'e.g. FEJODA Transport Cooperative',
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Enter cooperative name'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: cpcController,
                        textCapitalization: TextCapitalization.characters,
                        style: const TextStyle(fontSize: 14),
                        decoration: deco(
                          'Franchise CPC / Case No. (optional)',
                          Icons.verified_user_outlined,
                          hint: 'e.g. CPC-2024-VI-0892',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: usernameController,
                        autocorrect: false,
                        style: const TextStyle(fontSize: 14),
                        decoration: deco(
                          'Login Username *',
                          Icons.account_circle_outlined,
                          hint: 'letters, numbers, dots or underscores',
                        ),
                        validator: (v) {
                          final t = (v ?? '').trim();
                          if (!RegExp(r'^[a-zA-Z0-9._]{3,}$').hasMatch(t)) {
                            return 'At least 3 letters/numbers (no spaces or @)';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: emailController,
                        keyboardType: TextInputType.emailAddress,
                        style: const TextStyle(fontSize: 14),
                        decoration: deco(
                          'Contact Email (optional)',
                          Icons.email_outlined,
                        ),
                        validator: (v) {
                          final t = (v ?? '').trim();
                          return (t.isNotEmpty && !t.contains('@'))
                              ? 'Enter a valid email'
                              : null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: pinController,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        maxLength: 8,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        style: const TextStyle(fontSize: 14, letterSpacing: 2),
                        decoration: deco(
                          'Login PIN (6-8 digits) *',
                          Icons.lock_outline_rounded,
                        ).copyWith(counterText: ''),
                        validator: (v) =>
                            RegExp(r'^\d{6,8}$').hasMatch((v ?? '').trim())
                                ? null
                                : 'PIN must be 6 to 8 digits',
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Authorized Route Corridors',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: AppColors.darkSlate,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: RouteProcesses.all.keys.map((rId) {
                          final isSel = selectedRoutes.contains(rId);
                          return FilterChip(
                            label: Text(_formatRouteDisplayName(rId)),
                            selected: isSel,
                            selectedColor: AppColors.commuterTealLight,
                            checkmarkColor: AppColors.primaryNavy,
                            labelStyle: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: isSel
                                  ? AppColors.primaryNavy
                                  : AppColors.darkSlate,
                            ),
                            onSelected: (v) {
                              setDialogState(() {
                                if (v) {
                                  selectedRoutes.add(rId);
                                } else if (selectedRoutes.length > 1) {
                                  selectedRoutes.remove(rId);
                                }
                              });
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: isSubmitting
                                  ? null
                                  : () => Navigator.pop(dialogCtx),
                              style: OutlinedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primaryNavy,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                              onPressed: isSubmitting
                                  ? null
                                  : () async {
                                      if (!formKey.currentState!.validate()) {
                                        return;
                                      }
                                      setDialogState(() => isSubmitting = true);

                                      try {
                                        final name = nameController.text.trim();
                                        final username = usernameController.text
                                            .trim()
                                            .toLowerCase();
                                        final email = emailController.text
                                            .trim()
                                            .toLowerCase();
                                        final cpc = cpcController.text
                                            .trim()
                                            .toUpperCase();
                                        final pin = pinController.text.trim();
                                        final users = FirebaseFirestore.instance
                                            .collection('users');

                                        final dupUser = await users
                                            .where('username',
                                                isEqualTo: username)
                                            .limit(1)
                                            .get();
                                        if (dupUser.docs.isNotEmpty) {
                                          throw 'That username is already taken.';
                                        }
                                        if (email.isNotEmpty) {
                                          final dupMail = await users
                                              .where('email', isEqualTo: email)
                                              .limit(1)
                                              .get();
                                          if (dupMail.docs.isNotEmpty) {
                                            throw 'That email is already in use.';
                                          }
                                        }

                                        final existing = await users
                                            .where('role',
                                                isEqualTo: 'COOPERATIVE')
                                            .get();
                                        int maxId = 0;
                                        for (final d in existing.docs) {
                                          if (d.id.startsWith('USER_COOP_')) {
                                            final n = int.tryParse(d.id
                                                .replaceFirst(
                                                    'USER_COOP_', ''));
                                            if (n != null && n > maxId) {
                                              maxId = n;
                                            }
                                          }
                                        }
                                        final newDocId =
                                            'USER_COOP_${(maxId + 1).toString().padLeft(3, '0')}';

                                        final newAuthUid =
                                            await StaffAuth.createAccount(
                                                username, pin);

                                        await users.doc(newDocId).set({
                                          'full_name': name,
                                          'username': username,
                                          if (email.isNotEmpty) 'email': email,
                                          if (cpc.isNotEmpty)
                                            'franchise_case_number': cpc,
                                          'authorized_routes':
                                              selectedRoutes.toList(),
                                          'auth_uid': newAuthUid,
                                          'role': 'COOPERATIVE',
                                          'cooperative_id': newDocId,
                                          'cooperative_name': name,
                                          'created_at':
                                              FieldValue.serverTimestamp(),
                                        });
                                        await StaffAuth.writeRole(newAuthUid,
                                            'COOPERATIVE', newDocId, username);

                                        if (dialogCtx.mounted) {
                                          Navigator.pop(dialogCtx);
                                        }
                                        messenger.showSnackBar(
                                          SnackBar(
                                            content: Text(
                                                '"$name" created. They can log in as "$username" with their PIN.'),
                                            backgroundColor:
                                                const Color(0xFF059669),
                                          ),
                                        );
                                      } catch (err) {
                                        if (dialogCtx.mounted) {
                                          setDialogState(
                                              () => isSubmitting = false);
                                        }
                                        messenger.showSnackBar(
                                          SnackBar(
                                            content: Text('Failed: $err'),
                                            backgroundColor:
                                                AppColors.errorCrimson,
                                          ),
                                        );
                                      }
                                    },
                              child: isSubmitting
                                  ? const SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                          color: Colors.white, strokeWidth: 2),
                                    )
                                  : const Text(
                                      'Provision & Save Account',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w800),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // SHELL HEADERS & NAVIGATION
  // ===========================================================================
  PreferredSizeWidget _mobileAppBar(_AdminSection s) {
    return AppBar(
      elevation: 0,
      backgroundColor: AppColors.primaryNavy,
      automaticallyImplyLeading: false,
      toolbarHeight: 62,
      titleSpacing: 16,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white24),
            ),
            child: const Icon(
              Icons.admin_panel_settings_rounded,
              color: Colors.white,
              size: 21,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Super Admin Central',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  s.title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withOpacity(0.78),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Migrate accounts to Firebase login',
          icon: const Icon(Icons.sync_alt_rounded,
              color: Colors.white, size: 21),
          onPressed: _migrateAccounts,
        ),
        IconButton(
          tooltip: 'Log out',
          icon:
              const Icon(Icons.logout_rounded, color: Colors.white, size: 21),
          onPressed: _logout,
        ),
        const SizedBox(width: 6),
      ],
    );
  }

  Widget _desktopHeader(_AdminSection s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 18, 28, 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.title,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                    color: AppColors.darkSlate,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  s.subtitle,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: _migrateAccounts,
            icon: const Icon(Icons.sync_alt_rounded, size: 18),
            label: const Text(
              'Migrate accounts',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primaryNavy,
              side: const BorderSide(color: AppColors.borderSubtle),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: () => _showCreateCoopDialog(context),
            icon: const Icon(Icons.add_business_rounded, size: 18),
            label: const Text(
              'Add cooperative',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.commuterTeal,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final wide = width >= 900;
    final idx = _tabController.index.clamp(0, _sections.length - 1);
    final current = _sections[idx];

    final body = TabBarView(
      controller: _tabController,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _buildOverviewTab(),
        _buildCooperativesTab(),
        _buildReportsTab(),
        const FareSettingsTab(),
      ],
    );

    if (wide) {
      final extended = width >= 1150;
      return Scaffold(
        backgroundColor: AppColors.backgroundSlate,
        body: Row(
          children: [
            CoopSideRail(
              title: 'Super Admin Central',
              subtitle: 'Provincial network',
              extended: extended,
              selected: idx,
              onSelect: (i) =>
                  _tabController.animateTo(i, duration: Duration.zero),
              items: [
                for (final s in _sections)
                  CoopNavItem(s.label, s.icon, s.selectedIcon),
              ],
              footer: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _logout,
                child: Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: extended ? 12 : 0, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: extended
                        ? MainAxisAlignment.start
                        : MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.logout_rounded,
                          color: Colors.white, size: 19),
                      if (extended) ...[
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Log out',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  _desktopHeader(current),
                  Expanded(child: body),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.backgroundSlate,
      appBar: _mobileAppBar(current),
      floatingActionButton: current == _AdminSection.cooperatives
          ? FloatingActionButton.extended(
              backgroundColor: AppColors.commuterTeal,
              foregroundColor: Colors.white,
              elevation: 3,
              icon: const Icon(Icons.add_business_rounded, size: 20),
              label: const Text(
                'Add cooperative',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
              ),
              onPressed: () => _showCreateCoopDialog(context),
            )
          : null,
      body: body,
      bottomNavigationBar: NavigationBar(
        height: 68,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        indicatorColor: AppColors.commuterTealLight,
        selectedIndex: idx,
        onDestinationSelected: (i) =>
            _tabController.animateTo(i, duration: Duration.zero),
        destinations: [
          for (final s in _sections)
            NavigationDestination(
              icon: Icon(s.icon, color: AppColors.textMuted),
              selectedIcon: Icon(s.selectedIcon, color: AppColors.primaryNavy),
              label: s.label,
            ),
        ],
      ),
    );
  }
}

// ── Loading / error helpers ──────────────────────────────────────────────────
/// Spinner that turns into a message + Retry button if data takes too long,
/// so the screen can never sit on an endless spinner with no explanation.
class _SlowLoadNotice extends StatefulWidget {
  final VoidCallback onRetry;
  const _SlowLoadNotice({required this.onRetry});

  @override
  State<_SlowLoadNotice> createState() => _SlowLoadNoticeState();
}

class _SlowLoadNoticeState extends State<_SlowLoadNotice> {
  Timer? _timer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: AppColors.commuterTeal),
          if (_slow) ...[
            const SizedBox(height: 16),
            const Text(
              'Still connecting to the database…',
              style: TextStyle(fontSize: 13.5, color: AppColors.textMuted),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: widget.onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }
}

class _StreamErrorView extends StatelessWidget {
  final Object? error;
  final VoidCallback onRetry;
  const _StreamErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    debugPrint('Dashboard stream error: $error');
    final denied = error.toString().contains('permission-denied');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded,
                size: 40, color: AppColors.textMuted),
            const SizedBox(height: 12),
            Text(
              denied
                  ? 'Access denied by Firestore rules'
                  : 'Could not load data',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              denied
                  ? 'The signed-in account is not allowed to read this data. '
                      'Check the Firestore security rules and that this admin '
                      'has a Firebase login (see Migrate accounts).'
                  : '$error',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}