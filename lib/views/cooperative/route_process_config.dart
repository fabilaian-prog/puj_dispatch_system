// =============================================================================
// ROUTE PROCESS CONFIG
//
// One entry per route: route_id -> how that route is dispatched.
//
// STATIC (this file): process type, owner coop, group definitions, which
//   terminals are involved, destination coordinates.
// DYNAMIC (Firestore, edited in the app):
//   rotation_lists/{ownerCoop}_{suffix}
//       groups.{group_n}.order / mode      (existing)
//       active_group                       (scheduled processes with 2 groups)
//       schedule.{group_n} = [{depart:'HH:mm', arrive:'HH:mm'}]
//   terminals_queue/{terminal}_{suffix}
//       dispatch_timer_minutes             (FCFS + timer routes)
//       boarding_started_at                (set when a unit takes Spot 1)
//
// To move a route to a different process, change its entry below. Nothing else
// in the app checks a route name any more.
// =============================================================================

/// How a route dispatches.
enum RouteProcessType {
  /// Guinsang-an / Lindero. Group A = Dalipe Direct. Group B = waits in the
  /// Dalipe standby pool, is called by the Robinsons dispatcher, then goes to
  /// Robinsons. Rotation: bottom unit -> top.
  twoGroupRobinsons,

  /// Dao. Boards at Robinsons only. A scheduled unit drives Dalipe -> Robinsons
  /// and boards at its scheduled arrival time. 2 groups, only one runs.
  /// Next-day rule: first jeep goes to the bottom (button).
  scheduledRobinsonsBoarding,

  /// Anini-y. Boards at Dalipe, departs on a schedule. 1 group.
  /// Next-day rule: first jeep goes to the bottom (button).
  scheduledDalipeSingleGroup,

  /// Sibalom, Belison, Patnongon, Bugasong, San Remigio, Valderrama.
  /// First come first serve. The dispatcher sets a boarding timer. The app
  /// only reminds the dispatcher when the unit is full or the timer ends;
  /// the dispatcher always dispatches by hand.
  fcfsFullOrTimer,

  /// Plain first come first serve with no timer. No route uses this right now;
  /// it is kept so a route can be switched back by editing its entry.
  fcfs,
}

/// Rotation action a route's coop can press.
enum RotationRule {
  none,

  /// Bottom unit goes to the top (two-group process).
  bottomToTop,

  /// First unit of the day goes to the bottom, only when the coop presses
  /// the button (never automatic).
  firstToBottomNextDay,
}

class RouteProcessConfig {
  final String routeId;
  final RouteProcessType type;

  /// The coop that owns the rotation. Empty for routes without rotation.
  final String ownerCoopId;

  /// All coops allowed to run this route (informational / validation).
  final List<String> coopIds;

  /// Group keys used in rotation_lists. Empty = no rotation.
  final List<String> groupKeys;

  final RotationRule rotationRule;

  /// Terminal where the dispatcher for this route boards passengers.
  final List<String> boardingTerminals;

  /// Default for FCFS+timer routes. Overridden per queue doc by the dispatcher.
  final int defaultDispatchTimerMinutes;

  /// Destination coordinates (used by the dispatcher map).
  final double destLat;
  final double destLng;

  const RouteProcessConfig({
    required this.routeId,
    required this.type,
    required this.destLat,
    required this.destLng,
    this.ownerCoopId = '',
    this.coopIds = const [],
    this.groupKeys = const [],
    this.rotationRule = RotationRule.none,
    this.boardingTerminals = const [],
    this.defaultDispatchTimerMinutes = 0,
  });

  String get suffix => routeId.replaceFirst('ROUTE_', '');

  // ── capability flags: UI and dispatcher logic key off these ──────────────

  /// Coop sees a Rotation tab for this route.
  bool get hasRotation => groupKeys.isNotEmpty && ownerCoopId.isNotEmpty;

  /// Guinsang-an style: Dalipe standby pool + Robinsons "call" + approach leg.
  bool get isTwoGroupRobinsons => type == RouteProcessType.twoGroupRobinsons;
  bool get dalipeStaging => isTwoGroupRobinsons;
  bool get robinsonsCallRequired => isTwoGroupRobinsons;
  bool get hasApproachLeg => isTwoGroupRobinsons;

  /// Rotation writes group/origin/hub/route_type onto vehicles_live.
  bool get syncsVehicleFields => isTwoGroupRobinsons;

  bool get isScheduled =>
      type == RouteProcessType.scheduledRobinsonsBoarding ||
      type == RouteProcessType.scheduledDalipeSingleGroup;

  /// Only one group runs at a time and the coop picks which one.
  bool get hasActiveGroupChoice =>
      type == RouteProcessType.scheduledRobinsonsBoarding;

  bool get isFcfs =>
      type == RouteProcessType.fcfs || type == RouteProcessType.fcfsFullOrTimer;

  bool get autoDispatchOnFullOrTimer =>
      type == RouteProcessType.fcfsFullOrTimer;

  String get processLabel {
    switch (type) {
      case RouteProcessType.twoGroupRobinsons:
        return 'Two groups: Dalipe Direct / via Robinsons';
      case RouteProcessType.scheduledRobinsonsBoarding:
        return 'Scheduled: boards at Robinsons';
      case RouteProcessType.scheduledDalipeSingleGroup:
        return 'Scheduled: boards at Dalipe';
      case RouteProcessType.fcfsFullOrTimer:
        return 'First come first serve (boarding timer, manual dispatch)';
      case RouteProcessType.fcfs:
        return 'First come first serve';
    }
  }
}

// Coop ids ------------------------------------------------------------------
const String kCoopGuinsangan = 'COOP_SJ_GUINSANGAN'; // seen in users docs
const String kCoopFejoda = 'COOP_FEJODA';
const String kCoopHdDao = 'COOP_HD_DAO';
const String kCoopWvtc = 'COOP_WVTC';

// Terminals -----------------------------------------------------------------
const String kTermDalipe1 = 'TERM_DALIPE_1';
const String kTermDalipe2 = 'TERM_DALIPE_2';
const String kTermRobinsons = 'TERM_ROBINSONS';

/// Starting boarding timer for first-come-first-serve routes. The dispatcher
/// can change it per queue. PLACEHOLDER: confirm with the coop.
const int kDefaultFcfsTimerMinutes = 15;

/// Last-resort route for a dispatcher doc that has no `assigned_route`.
/// Kept only so legacy accounts do not crash; it is NOT used for any check.
const String kLegacyDefaultRouteId = 'ROUTE_GUINSANGAN';

class RouteProcesses {
  RouteProcesses._();

  static const Map<String, RouteProcessConfig> all = {
    'ROUTE_GUINSANGAN': RouteProcessConfig(
      routeId: 'ROUTE_GUINSANGAN',
      type: RouteProcessType.twoGroupRobinsons,
      ownerCoopId: kCoopGuinsangan,
      coopIds: [kCoopGuinsangan],
      groupKeys: ['group_1', 'group_2'],
      rotationRule: RotationRule.bottomToTop,
      boardingTerminals: [kTermDalipe1, kTermDalipe2, kTermRobinsons],
      destLat: 10.641947,
      destLng: 121.977399,
    ),
    'ROUTE_LINDERO': RouteProcessConfig(
      routeId: 'ROUTE_LINDERO',
      type: RouteProcessType.twoGroupRobinsons,
      ownerCoopId: kCoopGuinsangan,
      coopIds: [kCoopGuinsangan],
      groupKeys: ['group_1', 'group_2'],
      rotationRule: RotationRule.bottomToTop,
      boardingTerminals: [kTermDalipe1, kTermDalipe2, kTermRobinsons],
      destLat: 10.5795,
      destLng: 122.0212,
    ),
    'ROUTE_DAO': RouteProcessConfig(
      routeId: 'ROUTE_DAO',
      type: RouteProcessType.scheduledRobinsonsBoarding,
      ownerCoopId: kCoopHdDao,
      coopIds: [kCoopHdDao],
      groupKeys: ['group_1', 'group_2'],
      rotationRule: RotationRule.firstToBottomNextDay,
      boardingTerminals: [kTermRobinsons], // NOT Dalipe
      destLat: 10.5180,
      destLng: 121.9350,
    ),
    'ROUTE_ANINIY': RouteProcessConfig(
      routeId: 'ROUTE_ANINIY',
      type: RouteProcessType.scheduledDalipeSingleGroup,
      ownerCoopId: kCoopFejoda,
      coopIds: [kCoopFejoda],
      groupKeys: ['group_1'],
      rotationRule: RotationRule.firstToBottomNextDay,
      boardingTerminals: [kTermDalipe2],
      destLat: 10.4320,
      destLng: 121.9240,
    ),
    'ROUTE_SIBALOM': RouteProcessConfig(
      routeId: 'ROUTE_SIBALOM',
      type: RouteProcessType.fcfsFullOrTimer,
      coopIds: [kCoopFejoda, kCoopWvtc],
      boardingTerminals: [kTermDalipe1],
      defaultDispatchTimerMinutes: 15, // PLACEHOLDER: confirm with the coop
      destLat: 10.7915,
      destLng: 122.0135,
    ),
    'ROUTE_BELISON': RouteProcessConfig(
      routeId: 'ROUTE_BELISON',
      type: RouteProcessType.fcfsFullOrTimer,
      defaultDispatchTimerMinutes: kDefaultFcfsTimerMinutes,
      coopIds: [kCoopFejoda, kCoopWvtc],
      boardingTerminals: [kTermDalipe1],
      destLat: 10.8405,
      destLng: 121.9605,
    ),
    'ROUTE_PATNONGON': RouteProcessConfig(
      routeId: 'ROUTE_PATNONGON',
      type: RouteProcessType.fcfsFullOrTimer,
      defaultDispatchTimerMinutes: kDefaultFcfsTimerMinutes,
      coopIds: [kCoopFejoda, kCoopWvtc],
      boardingTerminals: [kTermDalipe1],
      destLat: 10.9145,
      destLng: 121.9960,
    ),
    'ROUTE_BUGASONG': RouteProcessConfig(
      routeId: 'ROUTE_BUGASONG',
      type: RouteProcessType.fcfsFullOrTimer,
      defaultDispatchTimerMinutes: kDefaultFcfsTimerMinutes,
      coopIds: [kCoopFejoda, kCoopWvtc],
      boardingTerminals: [kTermDalipe1],
      destLat: 11.0425,
      destLng: 122.0620,
    ),
    'ROUTE_SAN_REMIGIO': RouteProcessConfig(
      routeId: 'ROUTE_SAN_REMIGIO',
      type: RouteProcessType.fcfsFullOrTimer,
      defaultDispatchTimerMinutes: kDefaultFcfsTimerMinutes,
      coopIds: [kCoopFejoda],
      boardingTerminals: [kTermDalipe2],
      destLat: 10.8810,
      destLng: 122.0880,
    ),
    'ROUTE_VALDERRAMA': RouteProcessConfig(
      routeId: 'ROUTE_VALDERRAMA',
      type: RouteProcessType.fcfsFullOrTimer,
      defaultDispatchTimerMinutes: kDefaultFcfsTimerMinutes,
      coopIds: [kCoopFejoda], // PLACEHOLDER: confirm which coop(s) run it
      boardingTerminals: [kTermDalipe2],
      destLat: 11.0018,
      destLng: 122.1294,
    ),
  };

  /// Null for an unknown route id.
  static RouteProcessConfig? of(String? routeId) {
    if (routeId == null) return null;
    return all[routeId.trim().toUpperCase()];
  }

  /// Terminals a dispatcher for [routeId] can be assigned to.
  /// Dao boards at Robinsons only (no dispatcher at Dalipe).
  static List<String> terminalsForDispatcher(String routeId) {
    final p = of(routeId);
    if (p != null && p.type == RouteProcessType.scheduledRobinsonsBoarding) {
      return const [kTermRobinsons];
    }
    return const [kTermDalipe1, kTermDalipe2, kTermRobinsons];
  }

  /// Routes from [authorized] that this coop owns a rotation for.
  static List<RouteProcessConfig> rotationRoutesForCoop(
      String coopId, Iterable<String> authorized) {
    final out = <RouteProcessConfig>[];
    for (final r in authorized) {
      final p = of(r);
      if (p != null && p.hasRotation && p.ownerCoopId == coopId) out.add(p);
    }
    return out;
  }

  /// Maps the commuter-facing destination label to a route id.
  /// Shared by route_live_details_screen and terminal_routes_screen.
  static String routeIdForDestination(String dest) {
    if (dest.contains('Guinsang-an')) return 'ROUTE_GUINSANGAN';
    if (dest.contains('Lindero')) return 'ROUTE_LINDERO';
    if (dest.contains('Sibalom')) return 'ROUTE_SIBALOM';
    if (dest.contains('Belison')) return 'ROUTE_BELISON';
    if (dest.contains('Patnongon')) return 'ROUTE_PATNONGON';
    if (dest.contains('Bugasong')) return 'ROUTE_BUGASONG';
    if (dest.contains('Anini-y')) return 'ROUTE_ANINIY';
    if (dest.contains('DAO') || dest.contains('Tobias Fornier')) {
      return 'ROUTE_DAO';
    }
    if (dest.contains('San Remigio')) return 'ROUTE_SAN_REMIGIO';
    if (dest.contains('Valderrama')) return 'ROUTE_VALDERRAMA';
    return dest.toUpperCase().replaceAll(' ', '_');
  }
}