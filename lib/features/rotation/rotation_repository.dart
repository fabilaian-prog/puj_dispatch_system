import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import '../../core/config/route_process_config.dart';

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
