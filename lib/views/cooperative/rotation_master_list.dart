import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import '../../utils/app_colors.dart';
import 'route_process_config.dart';

// =============================================================================
// ROTATION MASTER LIST (process-driven)
//
// Firestore: rotation_lists/{ownerCoopId}_{routeSuffix}
//   cooperative_id, route_id, process_type, updated_at
//   groups.group_n = { mode, order: [vehicleIds] }
//   active_group                      (only routes where one group runs at a time)
//   schedule.group_n = [{depart, arrive}]   (scheduled routes)
//
// What each route may do is decided by RouteProcesses (route_process_config.dart):
//   twoGroupRobinsons          -> 2 groups, Direct / via Robinsons, Rotate bottom -> top
//   scheduledRobinsonsBoarding -> 2 groups, one runs, schedule, next-day first -> bottom
//   scheduledDalipeSingleGroup -> 1 group, schedule, next-day first -> bottom
//   fcfs / fcfsFullOrTimer     -> no rotation (all writes are rejected)
//
// Every change is also written to `rotation_logs`.
// =============================================================================

const String kModeDirect = 'DALIPE_DIRECT';
const String kModeRobinsons = 'DALIPE_ROBINSONS';
const String kModeScheduled = 'SCHEDULED';
const List<String> kGroupKeys = ['group_1', 'group_2'];

// Values mirrored onto vehicles_live/{vehicleId} (two-group routes ONLY).
const String kOriginTerminal = 'TERM_DALIPE';
const String kHubDalipe = 'TERM_DALIPE';
const String kHubRobinsons = 'TERM_ROBINSONS';
const String kRouteTypeDirect = 'DIRECT_DALIPE';
const String kRouteTypeRobinsons = 'VIA_ROBINSONS';
const List<String> kVehicleSyncFields = [
  'group_assignment',
  'origin_terminal',
  'active_hub',
  'route_type',
];

String groupLabel(String key) {
  final n = RegExp(r'(\d+)$').firstMatch(key)?.group(1);
  return n == null ? key : 'Group $n';
}

const Map<String, String> _routeNames = {
  'ROUTE_GUINSANGAN': 'Guinsang-an',
  'ROUTE_LINDERO': 'Lindero',
  'ROUTE_DAO': 'Dao',
  'ROUTE_ANINIY': 'Anini-y',
  'ROUTE_SAN_REMIGIO': 'San Remigio',
};

String routeDisplayName(String routeId) {
  final known = _routeNames[routeId.toUpperCase()];
  if (known != null) return known;
  return routeId
      .replaceFirst('ROUTE_', '')
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
      .join(' ');
}

// -----------------------------------------------------------------------------
// MODELS
// -----------------------------------------------------------------------------
class ScheduleSlot {
  /// 'HH:mm'. For Aniniy this is the departure from Dalipe. For Dao it is the
  /// departure from Dalipe toward Robinsons.
  final String depart;

  /// 'HH:mm'. Dao only: when the unit is scheduled to arrive and board at
  /// Robinsons.
  final String arrive;
  const ScheduleSlot({required this.depart, this.arrive = ''});

  Map<String, dynamic> toMap() => {
        'depart': depart,
        if (arrive.isNotEmpty) 'arrive': arrive,
      };

  factory ScheduleSlot.fromMap(Map m) => ScheduleSlot(
        depart: (m['depart'] ?? '').toString(),
        arrive: (m['arrive'] ?? '').toString(),
      );

  static int? parseMinutes(String s) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s.trim());
    if (m == null) return null;
    return int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
  }

  int? get departMinutes => parseMinutes(depart);
  int? get arriveMinutes => parseMinutes(arrive);

  /// The moment passengers board: arrival time when there is one (Dao at
  /// Robinsons), otherwise the departure time (Aniniy at Dalipe).
  int? get boardMinutes => arriveMinutes ?? departMinutes;
}

class RotationGroup {
  final String key;
  final String mode;
  final List<String> order;
  const RotationGroup(this.key, this.mode, this.order);

  String get label => groupLabel(key);
  bool get isDirect => mode == kModeDirect;
}

class RotationConfig {
  final RouteProcessConfig? process;
  final Map<String, RotationGroup> groups;

  /// Which group runs (only meaningful when process.hasActiveGroupChoice).
  final String activeGroup;
  final Map<String, List<ScheduleSlot>> schedule;

  const RotationConfig(
    this.groups, {
    this.process,
    this.activeGroup = 'group_1',
    this.schedule = const {},
  });

  static List<String> keysFor(RouteProcessConfig? p) =>
      (p != null && p.groupKeys.isNotEmpty) ? p.groupKeys : kGroupKeys;

  static String _defaultMode(RouteProcessConfig? p, String key) {
    if (p == null || p.isTwoGroupRobinsons) {
      return key == 'group_1' ? kModeDirect : kModeRobinsons;
    }
    return kModeScheduled;
  }

  factory RotationConfig.empty({RouteProcessConfig? process}) =>
      RotationConfig.fromData(null, process: process);

  factory RotationConfig.fromData(Map<String, dynamic>? data,
      {RouteProcessConfig? process}) {
    final keys = keysFor(process);
    final raw = data?['groups'];
    final out = <String, RotationGroup>{};
    for (final key in keys) {
      final g = raw is Map ? raw[key] : null;
      final defMode = _defaultMode(process, key);
      if (g is Map) {
        final order = (g['order'] is List)
            ? (g['order'] as List).map((e) => e.toString()).toList()
            : <String>[];
        final mode = (g['mode'] ?? defMode).toString();
        out[key] = RotationGroup(key, mode, order);
      } else {
        out[key] = RotationGroup(key, defMode, <String>[]);
      }
    }

    var active = (data?['active_group'] ?? keys.first).toString();
    if (!keys.contains(active)) active = keys.first;

    final sched = <String, List<ScheduleSlot>>{};
    final rawSched = data?['schedule'];
    for (final key in keys) {
      final l = rawSched is Map ? rawSched[key] : null;
      sched[key] = (l is List)
          ? l.whereType<Map>().map(ScheduleSlot.fromMap).toList()
          : <ScheduleSlot>[];
    }

    return RotationConfig(out,
        process: process, activeGroup: active, schedule: sched);
  }

  /// Group that is currently running. Scheduled 2-group routes: the one the
  /// coop picked. Everything else: the first group.
  String get runningGroupKey => (process?.hasActiveGroupChoice ?? false)
      ? activeGroup
      : groups.keys.first;

  bool isRunning(String groupKey) => groupKey == runningGroupKey;

  String? groupKeyOf(String vehicleId) {
    for (final g in groups.values) {
      if (g.order.contains(vehicleId)) return g.key;
    }
    return null;
  }

  /// 1-based master-list number inside the vehicle's own group.
  int? numberOf(String vehicleId) {
    final k = groupKeyOf(vehicleId);
    if (k == null) return null;
    return groups[k]!.order.indexOf(vehicleId) + 1;
  }

  /// Two-group Robinsons routes only.
  String? directGroupKey() {
    for (final g in groups.values) {
      if (g.isDirect) return g.key;
    }
    return null;
  }

  /// Slot i of the group's schedule belongs to the unit at position i.
  ScheduleSlot? slotOf(String vehicleId) {
    final k = groupKeyOf(vehicleId);
    if (k == null || (process?.hasActiveGroupChoice ?? false) && k != activeGroup) {
      return null;
    }
    final idx = groups[k]!.order.indexOf(vehicleId);
    final slots = schedule[k] ?? const <ScheduleSlot>[];
    return idx >= 0 && idx < slots.length ? slots[idx] : null;
  }

  /// True when a unit with a LOWER master number (same group) is waiting
  /// behind [vehicleId] in [line]. Used to flag "skipped" turns.
  bool isAheadOfItsTurn(String vehicleId, List<String> line) {
    final myKey = groupKeyOf(vehicleId);
    final myNo = numberOf(vehicleId);
    if (myKey == null || myNo == null) return false;
    final idx = line.indexOf(vehicleId);
    if (idx < 0) return false;
    for (final other in line.skip(idx + 1)) {
      if (groupKeyOf(other) == myKey && (numberOf(other) ?? 9999) < myNo) {
        return true;
      }
    }
    return false;
  }
}

// -----------------------------------------------------------------------------
// REPOSITORY
// -----------------------------------------------------------------------------
class _Work {
  final RouteProcessConfig p;
  final Map<String, List<String>> orders;
  final Map<String, String> modes;
  String activeGroup;
  final Map<String, List<ScheduleSlot>> schedule;
  _Work(this.p, this.orders, this.modes, this.activeGroup, this.schedule);

  List<String> list(String groupKey) {
    final l = orders[groupKey];
    if (l == null) {
      throw StateError('${p.routeId} has no $groupKey.');
    }
    return l;
  }

  void requireRule(RotationRule rule) {
    if (p.rotationRule != rule) {
      throw StateError(
          '${routeDisplayName(p.routeId)} does not use this rotation action.');
    }
  }
}

class RotationRepo {
  static const String collection = 'rotation_lists';

  static String _clean(String s) =>
      s.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// What a vehicle's own document should say for a given group + mode
  /// (two-group Robinsons routes only).
  static Map<String, dynamic> vehicleFields(String groupKey, String mode) {
    final viaRobinsons = mode == kModeRobinsons;
    return {
      'group_assignment': groupLabel(groupKey),
      'origin_terminal': kOriginTerminal,
      'active_hub': viaRobinsons ? kHubRobinsons : kHubDalipe,
      'route_type': viaRobinsons ? kRouteTypeRobinsons : kRouteTypeDirect,
    };
  }

  static Map<String, Map<String, dynamic>> _placement(
          List<String> keys,
          Map<String, List<String>> orders,
          Map<String, String> modes) =>
      {
        for (final k in keys)
          for (final id in orders[k]!) id: vehicleFields(k, modes[k]!),
      };

  static String docId(String coopId, String routeId) =>
      '${_clean(coopId)}_${_clean(routeId.replaceFirst('ROUTE_', ''))}';

  static DocumentReference<Map<String, dynamic>> ref(
          String coopId, String routeId) =>
      FirebaseFirestore.instance
          .collection(collection)
          .doc(docId(coopId, routeId));

  static Stream<RotationConfig> watch(String coopId, String routeId) {
    final p = RouteProcesses.of(routeId);
    return ref(coopId, routeId)
        .snapshots()
        .map((s) => RotationConfig.fromData(s.data(), process: p));
  }

  static Map<String, List<Map<String, dynamic>>> _scheduleMaps(
          Map<String, List<ScheduleSlot>> s) =>
      {
        for (final e in s.entries) e.key: [for (final x in e.value) x.toMap()],
      };

  /// Runs [mutate] on a working copy inside a transaction and logs the change.
  static Future<void> _mutate({
    required String coopId,
    required String routeId,
    required String actorName,
    required String action,
    required void Function(_Work w) mutate,
    Map<String, dynamic> logExtra = const {},
    bool syncActiveGroup = false,
    bool forceSyncVehicles = false,
  }) async {
    final p = RouteProcesses.of(routeId);
    if (p == null || !p.hasRotation) {
      throw StateError('$routeId does not use a rotation list.');
    }
    if (p.ownerCoopId != coopId) {
      throw StateError(
          'Only ${p.ownerCoopId} manages the rotation for ${routeDisplayName(routeId)}.');
    }
    final keys = p.groupKeys;
    final r = ref(coopId, routeId);

    await FirebaseFirestore.instance.runTransaction((tx) async {
      final snap = await tx.get(r);
      final cfg = RotationConfig.fromData(snap.data(), process: p);
      final w = _Work(
        p,
        {for (final g in cfg.groups.values) g.key: List<String>.from(g.order)},
        {for (final g in cfg.groups.values) g.key: g.mode},
        cfg.activeGroup,
        {
          for (final k in keys)
            k: List<ScheduleSlot>.from(cfg.schedule[k] ?? const []),
        },
      );
      final before = {
        for (final k in keys) k: List<String>.from(w.orders[k]!)
      };
      final modesBefore = Map<String, String>.from(w.modes);
      final activeBefore = w.activeGroup;
      final scheduleBefore = _scheduleMaps(w.schedule);

      mutate(w);

      // ---- vehicle docs to update (two-group routes only) ----------------
      // All reads must happen before the first write in a transaction.
      final vehicleWrites = <String, Map<String, dynamic>>{};
      if (p.syncsVehicleFields) {
        final placeBefore = _placement(keys, before, modesBefore);
        final placeAfter = _placement(keys, w.orders, w.modes);
        for (final e in placeAfter.entries) {
          if (forceSyncVehicles || !mapEquals(placeBefore[e.key], e.value)) {
            vehicleWrites[e.key] = e.value;
          }
        }
        for (final id in placeBefore.keys) {
          if (!placeAfter.containsKey(id)) {
            vehicleWrites[id] = {
              for (final f in kVehicleSyncFields) f: FieldValue.delete(),
            };
          }
        }
      }
      final vehicleRefs = {
        for (final id in vehicleWrites.keys)
          id: FirebaseFirestore.instance.collection('vehicles_live').doc(id),
      };
      final existing = <String, bool>{};
      for (final e in vehicleRefs.entries) {
        existing[e.key] = (await tx.get(e.value)).exists;
      }

      tx.set(
          r,
          {
            'cooperative_id': coopId,
            'route_id': routeId,
            'process_type': p.type.name,
            'updated_at': FieldValue.serverTimestamp(),
            'groups': {
              for (final k in keys)
                k: {'mode': w.modes[k], 'order': w.orders[k]},
            },
            if (p.hasActiveGroupChoice) 'active_group': w.activeGroup,
            if (p.isScheduled) 'schedule': _scheduleMaps(w.schedule),
          },
          SetOptions(merge: true));

      if (syncActiveGroup && p.isTwoGroupRobinsons) {
        final directKey = w.modes.entries
            .firstWhere((e) => e.value == kModeDirect,
                orElse: () => const MapEntry('group_1', kModeDirect))
            .key;
        // Keeps the dispatcher's 'active_group' logic in sync.
        tx.set(
            FirebaseFirestore.instance
                .collection('terminals_queue')
                .doc('TERM_DALIPE_1_${p.suffix}'),
            {
              'active_group': groupLabel(directKey),
              'updated_at': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true));
      }

      for (final e in vehicleWrites.entries) {
        if (existing[e.key] != true) continue; // never create phantom vehicles
        tx.update(vehicleRefs[e.key]!, e.value);
      }

      final logRef =
          FirebaseFirestore.instance.collection('rotation_logs').doc();
      tx.set(logRef, {
        'log_id': logRef.id,
        'cooperative_id': coopId,
        'route_id': routeId,
        'process_type': p.type.name,
        'action': action,
        'actor_name': actorName,
        'previous_orders': before,
        'new_orders': w.orders,
        'modes': w.modes,
        if (p.hasActiveGroupChoice) 'previous_active_group': activeBefore,
        if (p.hasActiveGroupChoice) 'active_group': w.activeGroup,
        if (p.isScheduled) 'previous_schedule': scheduleBefore,
        if (p.isScheduled) 'new_schedule': _scheduleMaps(w.schedule),
        'timestamp': FieldValue.serverTimestamp(),
        ...logExtra,
      });
    });
  }

  static Future<void> assign(String coopId, String routeId, String actor,
          String vehicleId, String groupKey) =>
      _mutate(
        coopId: coopId,
        routeId: routeId,
        actorName: actor,
        action: 'ASSIGN',
        logExtra: {'vehicle_id': vehicleId, 'target_group': groupKey},
        mutate: (w) {
          w.list(groupKey); // validates the key
          for (final l in w.orders.values) {
            l.remove(vehicleId);
          }
          w.orders[groupKey]!.add(vehicleId); // joins at the bottom
        },
      );

  static Future<void> remove(
          String coopId, String routeId, String actor, String vehicleId) =>
      _mutate(
        coopId: coopId,
        routeId: routeId,
        actorName: actor,
        action: 'REMOVE',
        logExtra: {'vehicle_id': vehicleId},
        mutate: (w) {
          for (final l in w.orders.values) {
            l.remove(vehicleId);
          }
        },
      );

  /// Two-group routes: whoever is at the bottom goes to the top.
  static Future<void> rotateBottomToTop(
          String coopId, String routeId, String actor, String groupKey) =>
      _mutate(
        coopId: coopId,
        routeId: routeId,
        actorName: actor,
        action: 'ROTATE',
        logExtra: {'target_group': groupKey},
        mutate: (w) {
          w.requireRule(RotationRule.bottomToTop);
          final l = w.list(groupKey);
          if (l.length > 1) l.insert(0, l.removeLast());
        },
      );

  /// Scheduled routes: the first jeep goes to the bottom. Only ever runs when
  /// the coop presses the button (no automatic midnight rollover).
  static Future<void> firstToBottomNextDay(
          String coopId, String routeId, String actor, String groupKey) =>
      _mutate(
        coopId: coopId,
        routeId: routeId,
        actorName: actor,
        action: 'NEXT_DAY_FIRST_TO_BOTTOM',
        logExtra: {'target_group': groupKey},
        mutate: (w) {
          w.requireRule(RotationRule.firstToBottomNextDay);
          final l = w.list(groupKey);
          if (l.length > 1) l.add(l.removeAt(0));
        },
      );

  static Future<void> reorder(String coopId, String routeId, String actor,
          String groupKey, int oldIndex, int newIndex) =>
      _mutate(
        coopId: coopId,
        routeId: routeId,
        actorName: actor,
        action: 'REORDER',
        logExtra: {
          'target_group': groupKey,
          'from_index': oldIndex,
          'to_index': newIndex,
        },
        mutate: (w) {
          final l = w.list(groupKey);
          if (oldIndex < 0 || oldIndex >= l.length) return;
          final item = l.removeAt(oldIndex);
          l.insert(newIndex.clamp(0, l.length), item);
        },
      );

  /// Re-writes group_assignment / origin_terminal / active_hub / route_type on
  /// every vehicle in a two-group rotation (run once for existing units).
  static Future<void> syncVehicleFields(
          String coopId, String routeId, String actor) =>
      _mutate(
        coopId: coopId,
        routeId: routeId,
        actorName: actor,
        action: 'SYNC_VEHICLES',
        forceSyncVehicles: true,
        mutate: (w) {},
      );

  /// Two-group routes: makes [groupKey] the Dalipe Direct group.
  static Future<void> setDirectGroup(
          String coopId, String routeId, String actor, String groupKey) =>
      _mutate(
        coopId: coopId,
        routeId: routeId,
        actorName: actor,
        action: 'SET_MODE',
        syncActiveGroup: true,
        logExtra: {'target_group': groupKey},
        mutate: (w) {
          if (!w.p.isTwoGroupRobinsons) {
            throw StateError('This route has no Direct / Robinsons groups.');
          }
          w.list(groupKey);
          for (final k in w.p.groupKeys) {
            w.modes[k] = k == groupKey ? kModeDirect : kModeRobinsons;
          }
        },
      );

  /// Dao: the coop chooses which of the two groups runs.
  static Future<void> setActiveGroup(
          String coopId, String routeId, String actor, String groupKey) =>
      _mutate(
        coopId: coopId,
        routeId: routeId,
        actorName: actor,
        action: 'SET_ACTIVE_GROUP',
        logExtra: {'target_group': groupKey},
        mutate: (w) {
          if (!w.p.hasActiveGroupChoice) {
            throw StateError('Only one group exists on this route.');
          }
          w.list(groupKey);
          w.activeGroup = groupKey;
        },
      );

  /// Scheduled routes: replaces the schedule of one group.
  static Future<void> setSchedule(String coopId, String routeId, String actor,
          String groupKey, List<ScheduleSlot> slots) =>
      _mutate(
        coopId: coopId,
        routeId: routeId,
        actorName: actor,
        action: 'SET_SCHEDULE',
        logExtra: {'target_group': groupKey},
        mutate: (w) {
          if (!w.p.isScheduled) {
            throw StateError('This route has no schedule.');
          }
          w.list(groupKey);
          final sorted = [...slots]..sort((a, b) =>
              (a.departMinutes ?? 0).compareTo(b.departMinutes ?? 0));
          w.schedule[groupKey] = sorted;
        },
      );
}

// =============================================================================
// SMALL BADGE (used by the dispatcher screen and by the tab below)
// =============================================================================
class RotationNumberBadge extends StatelessWidget {
  final int number;
  final String groupLabelText;
  final bool skipped;
  const RotationNumberBadge({
    super.key,
    required this.number,
    required this.groupLabelText,
    this.skipped = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = skipped ? const Color(0xFFFEF3C7) : const Color(0xFFEDE9FE);
    final fg = skipped ? const Color(0xFF92400E) : const Color(0xFF5B21B6);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        skipped
            ? 'TURN #$number • lower # waiting'
            : '$groupLabelText • TURN #$number',
        style: TextStyle(
            fontSize: 10.5, fontWeight: FontWeight.w800, color: fg),
      ),
    );
  }
}

// =============================================================================
// COOP "ROTATION" TAB HOST: route picker + one tab per selected route
// =============================================================================
class RotationTabHost extends StatefulWidget {
  final String coopId;
  final String coopName;
  final String actorName;

  /// Routes this coop owns a rotation for (already filtered by the dashboard).
  final List<RouteProcessConfig> routes;
  final bool Function(Map<String, dynamic> vehicleData) matchesCooperative;

  const RotationTabHost({
    super.key,
    required this.coopId,
    required this.coopName,
    required this.actorName,
    required this.routes,
    required this.matchesCooperative,
  });

  @override
  State<RotationTabHost> createState() => _RotationTabHostState();
}

class _RotationTabHostState extends State<RotationTabHost> {
  String? _selected;

  String? _resolve() {
    if (widget.routes.isEmpty) return null;
    if (_selected != null && widget.routes.any((r) => r.routeId == _selected)) {
      return _selected;
    }
    return widget.routes.first.routeId;
  }

  @override
  Widget build(BuildContext context) {
    final selected = _resolve();
    if (selected == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'None of your routes use a rotation list. Dispatching for your '
            'routes is handled by the terminal dispatcher.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textMuted, height: 1.4),
          ),
        ),
      );
    }

    return Column(
      children: [
        if (widget.routes.length > 1)
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Route:',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.darkSlate)),
                for (final r in widget.routes)
                  ChoiceChip(
                    label: Text(routeDisplayName(r.routeId)),
                    selected: r.routeId == selected,
                    selectedColor: AppColors.primaryNavy,
                    labelStyle: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: r.routeId == selected
                          ? Colors.white
                          : AppColors.darkSlate,
                    ),
                    onSelected: (_) => setState(() => _selected = r.routeId),
                  ),
              ],
            ),
          ),
        Expanded(
          child: RotationMasterListTab(
            // A new key gives each route its own streams and state.
            key: ValueKey(selected),
            coopId: widget.coopId,
            coopName: widget.coopName,
            routeId: selected,
            actorName: widget.actorName,
            matchesCooperative: widget.matchesCooperative,
            // Vehicles with no route_id can only be offered when there is
            // exactly one rotation route, otherwise they could be double-assigned.
            allowUnroutedVehicles: widget.routes.length == 1,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// ONE ROUTE'S ROTATION VIEW
// =============================================================================
class RotationMasterListTab extends StatefulWidget {
  final String coopId;
  final String coopName;
  final String routeId;
  final String actorName;
  final bool allowUnroutedVehicles;
  final bool Function(Map<String, dynamic> vehicleData) matchesCooperative;

  const RotationMasterListTab({
    super.key,
    required this.coopId,
    required this.coopName,
    required this.routeId,
    required this.actorName,
    required this.matchesCooperative,
    this.allowUnroutedVehicles = true,
  });

  @override
  State<RotationMasterListTab> createState() => _RotationMasterListTabState();
}

class _RotationMasterListTabState extends State<RotationMasterListTab> {
  late final Stream<RotationConfig> _rotationStream;
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _vehiclesStream;

  RouteProcessConfig? get _p => RouteProcesses.of(widget.routeId);

  @override
  void initState() {
    super.initState();
    _rotationStream = RotationRepo.watch(widget.coopId, widget.routeId);
    _vehiclesStream =
        FirebaseFirestore.instance.collection('vehicles_live').snapshots();
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor:
          error ? AppColors.errorCrimson : const Color(0xFF059669),
    ));
  }

  Future<void> _run(Future<void> Function() job, String ok) async {
    try {
      await job();
      _toast(ok);
    } catch (e) {
      _toast('Rotation update failed: $e', error: true);
    }
  }

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static TimeOfDay? _parse(String s) {
    final m = ScheduleSlot.parseMinutes(s);
    return m == null ? null : TimeOfDay(hour: m ~/ 60, minute: m % 60);
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null || !p.hasRotation || p.ownerCoopId != widget.coopId) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('This route does not use a rotation list for your coop.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted)),
        ),
      );
    }

    return StreamBuilder<RotationConfig>(
      stream: _rotationStream,
      builder: (context, rotSnap) {
        final cfg = rotSnap.data ?? RotationConfig.empty(process: p);
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _vehiclesStream,
          builder: (context, vSnap) {
            if (!vSnap.hasData) {
              return const Center(
                  child: CircularProgressIndicator(
                      color: AppColors.commuterTeal));
            }
            final info = <String, Map<String, dynamic>>{};
            for (final d in vSnap.data!.docs) {
              final data = d.data();
              final route = (data['route_id'] ?? '').toString();
              final routeOk = route == widget.routeId ||
                  (route.isEmpty && widget.allowUnroutedVehicles);
              if (widget.matchesCooperative(data) && routeOk) {
                info[d.id] = data;
              }
            }
            final unassigned = info.keys
                .where((id) => cfg.groupKeyOf(id) == null)
                .toList()
              ..sort();

            return ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 90),
              children: [
                _banner(p),
                const SizedBox(height: 12),
                if (p.hasActiveGroupChoice) ...[
                  _activeGroupCard(p, cfg),
                  const SizedBox(height: 12),
                ],
                for (final k in p.groupKeys) ...[
                  _groupCard(p, cfg, cfg.groups[k]!, info),
                  const SizedBox(height: 12),
                ],
                _unassignedCard(p, unassigned, info),
              ],
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------- banner
  Widget _banner(RouteProcessConfig p) {
    String text;
    switch (p.type) {
      case RouteProcessType.twoGroupRobinsons:
        text = 'Master rotation list for ${routeDisplayName(p.routeId)}. '
            'The number beside each unit is its turn. Dispatchers see these '
            'numbers in their line-up and decide whether a lower number may '
            'skip ahead when units arrive out of turn. Use Rotate to move the '
            'bottom unit to the top, or drag to correct a wrong rotation.';
        break;
      case RouteProcessType.scheduledRobinsonsBoarding:
        text = 'Dao runs on a schedule. Only one group runs at a time; pick it '
            'below. Each scheduled unit leaves Dalipe at its departure time '
            'and boards at Robinsons at its arrival time. The Robinsons '
            'dispatcher for Dao handles dispatching. Slot 1 belongs to the '
            'unit in position 1, slot 2 to position 2, and so on.';
        break;
      case RouteProcessType.scheduledDalipeSingleGroup:
        text = 'Anini-y boards at Dalipe and departs on a schedule. Slot 1 '
            'belongs to the unit in position 1, slot 2 to position 2, and so '
            'on. Press the next-day button to move the first jeep to the '
            'bottom; it never happens automatically.';
        break;
      default:
        text = 'This route does not use a rotation list.';
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Text(text,
          style: const TextStyle(
              fontSize: 12.5, height: 1.35, color: Color(0xFF1E3A8A))),
    );
  }

  // ------------------------------------------------ Dao: which group runs
  Widget _activeGroupCard(RouteProcessConfig p, RotationConfig cfg) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('RUNNING GROUP',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w900,
                  color: AppColors.darkSlate)),
          const SizedBox(height: 4),
          const Text('Only one group can run. The other group stays off the road.',
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final k in p.groupKeys)
                ChoiceChip(
                  label: Text('${groupLabel(k)} runs'),
                  selected: cfg.activeGroup == k,
                  selectedColor: const Color(0xFFBBF7D0),
                  labelStyle: const TextStyle(
                      fontWeight: FontWeight.w800, color: AppColors.darkSlate),
                  onSelected: (_) {
                    if (cfg.activeGroup == k) return;
                    _run(
                      () => RotationRepo.setActiveGroup(
                          widget.coopId, widget.routeId, widget.actorName, k),
                      '${groupLabel(k)} is now the running group.',
                    );
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- group card
  Widget _groupCard(RouteProcessConfig p, RotationConfig cfg, RotationGroup g,
      Map<String, Map<String, dynamic>> info) {
    final isTwo = p.isTwoGroupRobinsons;
    final running = cfg.isRunning(g.key);
    final Color accent;
    final String chip;
    if (isTwo) {
      accent = g.isDirect ? const Color(0xFF059669) : const Color(0xFFD97706);
      chip = g.isDirect ? 'DALIPE DIRECT' : 'DALIPE TO ROBINSONS';
    } else if (p.hasActiveGroupChoice) {
      accent = running ? const Color(0xFF059669) : const Color(0xFF94A3B8);
      chip = running ? 'RUNNING' : 'NOT RUNNING';
    } else {
      accent = const Color(0xFF059669);
      chip = 'SCHEDULED • DALIPE';
    }
    final others = p.groupKeys.where((k) => k != g.key).toList();
    final other = others.isEmpty ? null : others.first;
    final slots = cfg.schedule[g.key] ?? const <ScheduleSlot>[];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withOpacity(0.45), width: 1.3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(g.label,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            color: AppColors.darkSlate)),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2.5),
                      decoration: BoxDecoration(
                        color: accent.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(chip,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              color: accent)),
                    ),
                    Text('${g.order.length} units',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textMuted)),
                  ],
                ),
              ),
              if (isTwo && other != null)
                PopupMenuButton<String>(
                  tooltip: 'Group mode',
                  icon: const Icon(Icons.swap_horiz_rounded,
                      color: AppColors.primaryNavy),
                  onSelected: (v) {
                    final target = v == 'direct' ? g.key : other;
                    _run(
                      () => RotationRepo.setDirectGroup(widget.coopId,
                          widget.routeId, widget.actorName, target),
                      '${groupLabel(target)} is now Dalipe Direct; '
                      '${groupLabel(target == g.key ? other : g.key)} goes to Robinsons.',
                    );
                  },
                  itemBuilder: (_) => [
                    if (!g.isDirect)
                      const PopupMenuItem(
                          value: 'direct',
                          child: Text('Make this group Dalipe Direct')),
                    if (g.isDirect)
                      const PopupMenuItem(
                          value: 'robinsons',
                          child: Text('Make this group go to Robinsons')),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 4),
          _rotationButton(p, cfg, g),
          if (p.isScheduled) ...[
            const Divider(height: 18),
            _scheduleSection(p, g, slots, info),
          ],
          const Divider(height: 18),
          if (g.order.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Center(
                  child: Text('No units in this group yet.',
                      style: TextStyle(color: AppColors.textMuted))),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: g.order.length,
              onReorder: (oldIndex, newIndex) {
                if (newIndex > oldIndex) newIndex -= 1;
                if (newIndex == oldIndex) return;
                _run(
                  () => RotationRepo.reorder(widget.coopId, widget.routeId,
                      widget.actorName, g.key, oldIndex, newIndex),
                  'Rotation order updated.',
                );
              },
              itemBuilder: (context, i) =>
                  _unitRow(p, g, i, other, info, slots),
            ),
        ],
      ),
    );
  }

  Widget _rotationButton(
      RouteProcessConfig p, RotationConfig cfg, RotationGroup g) {
    final style = ElevatedButton.styleFrom(
      backgroundColor: AppColors.primaryNavy,
      foregroundColor: Colors.white,
      elevation: 0,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );
    const labelStyle = TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold);

    if (p.rotationRule == RotationRule.bottomToTop) {
      return Row(children: [
        ElevatedButton.icon(
          style: style,
          icon: const Icon(Icons.autorenew_rounded, size: 16),
          label: const Text('Rotate: bottom to top', style: labelStyle),
          onPressed: g.order.length < 2
              ? null
              : () => _run(
                    () => RotationRepo.rotateBottomToTop(widget.coopId,
                        widget.routeId, widget.actorName, g.key),
                    '${g.label}: last unit moved to the top.',
                  ),
        ),
      ]);
    }

    if (p.rotationRule == RotationRule.firstToBottomNextDay) {
      final enabled = g.order.length >= 2 && cfg.isRunning(g.key);
      return Row(children: [
        Flexible(
          child: ElevatedButton.icon(
            style: style,
            icon: const Icon(Icons.today_rounded, size: 16),
            label: const Text('Next day: first jeep to bottom',
                style: labelStyle),
            onPressed: !enabled
                ? null
                : () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text('Start next day for ${g.label}?'),
                        content: const Text(
                            'The first jeep in this list moves to the bottom. '
                            'This is only done when you confirm it here.'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel')),
                          ElevatedButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Move to bottom')),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    await _run(
                      () => RotationRepo.firstToBottomNextDay(widget.coopId,
                          widget.routeId, widget.actorName, g.key),
                      '${g.label}: first jeep moved to the bottom.',
                    );
                  },
          ),
        ),
      ]);
    }
    return const SizedBox.shrink();
  }

  // --------------------------------------------------------------- schedule
  Widget _scheduleSection(RouteProcessConfig p, RotationGroup g,
      List<ScheduleSlot> slots, Map<String, Map<String, dynamic>> info) {
    final hasArrive = p.hasActiveGroupChoice; // Dao: Dalipe depart + Robinsons arrive
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('SCHEDULE',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w900,
                      color: AppColors.darkSlate)),
            ),
            TextButton.icon(
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Add time'),
              onPressed: () => _editSlot(p, g, slots, null),
            ),
          ],
        ),
        if (slots.isEmpty)
          const Text('No times set yet.',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted))
        else
          for (int i = 0; i < slots.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 10,
                    backgroundColor: const Color(0xFFE2E8F0),
                    child: Text('${i + 1}',
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: AppColors.darkSlate)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      hasArrive
                          ? 'Leaves Dalipe ${slots[i].depart}, boards at Robinsons ${slots[i].arrive.isEmpty ? '—' : slots[i].arrive}'
                          : 'Departs Dalipe ${slots[i].depart}',
                      style: const TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.edit_rounded, size: 18),
                    onPressed: () => _editSlot(p, g, slots, i),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    onPressed: () {
                      final next = [...slots]..removeAt(i);
                      _run(
                        () => RotationRepo.setSchedule(widget.coopId,
                            widget.routeId, widget.actorName, g.key, next),
                        'Time removed.',
                      );
                    },
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Future<void> _editSlot(RouteProcessConfig p, RotationGroup g,
      List<ScheduleSlot> slots, int? index) async {
    final existing = index == null ? null : slots[index];
    final departInit = (existing == null ? null : _parse(existing.depart)) ??
        const TimeOfDay(hour: 10, minute: 0);

    final depart = await showTimePicker(
      context: context,
      initialTime: departInit,
      helpText: p.hasActiveGroupChoice
          ? 'DEPARTS DALIPE'
          : 'DEPARTS DALIPE (ANINI-Y)',
    );
    if (depart == null || !mounted) return;

    String arrive = '';
    if (p.hasActiveGroupChoice) {
      final arriveInit = (existing == null ? null : _parse(existing.arrive)) ??
          TimeOfDay(
              hour: (depart.hour + (depart.minute + 15) ~/ 60) % 24,
              minute: (depart.minute + 15) % 60);
      final a = await showTimePicker(
        context: context,
        initialTime: arriveInit,
        helpText: 'ARRIVES / BOARDS AT ROBINSONS',
      );
      if (a == null || !mounted) return;
      arrive = _fmt(a);
    }

    final slot = ScheduleSlot(depart: _fmt(depart), arrive: arrive);
    final next = [...slots];
    if (index == null) {
      next.add(slot);
    } else {
      next[index] = slot;
    }
    await _run(
      () => RotationRepo.setSchedule(
          widget.coopId, widget.routeId, widget.actorName, g.key, next),
      'Schedule saved.',
    );
  }

  // ---------------------------------------------------------------- unit row
  Widget _unitRow(RouteProcessConfig p, RotationGroup g, int i, String? other,
      Map<String, Map<String, dynamic>> info, List<ScheduleSlot> slots) {
    final id = g.order[i];
    final v = info[id];
    final plate = (v?['plate_number'] ?? id).toString();
    final name = (v?['vehicle_name'] ?? plate).toString();
    final driver = (v?['driver_name'] ?? 'Unassigned Driver').toString();
    final slot = i < slots.length ? slots[i] : null;
    final slotText = !p.isScheduled
        ? ''
        : slot == null
            ? ' • no time slot'
            : p.hasActiveGroupChoice
                ? ' • leaves ${slot.depart}, boards ${slot.arrive.isEmpty ? '—' : slot.arrive}'
                : ' • departs ${slot.depart}';

    return Container(
      key: ValueKey('${g.key}_$id'),
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: i == 0 ? const Color(0xFFF0FDF4) : AppColors.backgroundSlate,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color:
                i == 0 ? const Color(0xFF86EFAC) : AppColors.borderSubtle),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: AppColors.primaryNavy,
            child: Text('${i + 1}',
                style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.darkSlate)),
                Text('$plate • $driver$slotText',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.textMuted)),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, size: 20),
            onSelected: (sel) {
              if (sel == 'top') {
                _run(
                  () => RotationRepo.reorder(widget.coopId, widget.routeId,
                      widget.actorName, g.key, i, 0),
                  '$plate moved to the top.',
                );
              } else if (sel == 'move' && other != null) {
                _run(
                  () => RotationRepo.assign(widget.coopId, widget.routeId,
                      widget.actorName, id, other),
                  '$plate moved to ${groupLabel(other)}.',
                );
              } else if (sel == 'remove') {
                _run(
                  () => RotationRepo.remove(widget.coopId, widget.routeId,
                      widget.actorName, id),
                  '$plate removed from the rotation.',
                );
              }
            },
            itemBuilder: (_) => [
              if (i > 0)
                const PopupMenuItem(value: 'top', child: Text('Move to top')),
              if (other != null)
                PopupMenuItem(
                    value: 'move',
                    child: Text('Move to ${groupLabel(other)}')),
              const PopupMenuItem(
                  value: 'remove', child: Text('Remove from rotation')),
            ],
          ),
          ReorderableDragStartListener(
            index: i,
            child: const Padding(
              padding: EdgeInsets.all(6),
              child:
                  Icon(Icons.drag_handle_rounded, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- unassigned
  Widget _unassignedCard(RouteProcessConfig p, List<String> ids,
      Map<String, Map<String, dynamic>> info) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('UNASSIGNED UNITS (${ids.length})',
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w900,
                  color: AppColors.darkSlate)),
          const SizedBox(height: 4),
          Text(
              p.isTwoGroupRobinsons
                  ? 'Units without a group check in as Dalipe Direct until assigned. '
                      'Assigning adds the unit to the bottom of that group\'s list.'
                  : 'Units without a group have no turn or time slot. '
                      'Assigning adds the unit to the bottom of that group\'s list.',
              style:
                  const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
          const SizedBox(height: 8),
          if (ids.isEmpty)
            const Text('Every unit is assigned.',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted))
          else
            for (final id in ids)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${info[id]?['plate_number'] ?? id} • ${info[id]?['driver_name'] ?? 'Unassigned Driver'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                    for (final k in p.groupKeys) ...[
                      const SizedBox(width: 6),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () => _run(
                          () => RotationRepo.assign(widget.coopId,
                              widget.routeId, widget.actorName, id, k),
                          '${info[id]?['plate_number'] ?? id} added to ${groupLabel(k)}.',
                        ),
                        child: Text(groupLabel(k),
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ],
                ),
              ),
        ],
      ),
    );
  }
}