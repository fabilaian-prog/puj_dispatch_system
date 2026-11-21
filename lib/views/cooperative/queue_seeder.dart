import 'package:cloud_firestore/cloud_firestore.dart';
import 'route_process_config.dart';

/// Creates terminals_queue/{terminal}_{routeSuffix} documents when missing.
/// Never overwrites an existing document.
class QueueSeeder {
  QueueSeeder._();

  static String terminalName(String terminalId) {
    final t = terminalId.toUpperCase();
    if (t.contains('ROBINSON')) return 'Robinsons Terminal';
    if (t.contains('DALIPE_2')) return 'Dalipe Terminal 2';
    if (t.contains('DALIPE')) return 'Dalipe Terminal 1';
    return terminalId;
  }

  /// Creates the one queue doc a dispatcher needs. Returns true if created.
  static Future<bool> ensure(String terminalId, String routeId) async {
    final suffix = routeId.replaceFirst('ROUTE_', '');
    final ref = FirebaseFirestore.instance
        .collection('terminals_queue')
        .doc('${terminalId}_$suffix');

    if ((await ref.get()).exists) return false;

    final p = RouteProcesses.of(routeId);
    await ref.set({
      'terminal_id': terminalId,
      'terminal_name': terminalName(terminalId),
      'route_id': routeId,
      'active_loading_vehicle': 'None',
      'queued_vehicles': <String>[],
      'standby_staged_vehicles': <String>[],
      if (p != null && p.autoDispatchOnFullOrTimer)
        'dispatch_timer_minutes': p.defaultDispatchTimerMinutes,
      'created_at': FieldValue.serverTimestamp(),
      'updated_at': FieldValue.serverTimestamp(),
    });
    return true;
  }

  /// Edit this list to match where each route really boards.
  static const List<List<String>> defaultQueues = [
    [kTermDalipe1, 'ROUTE_GUINSANGAN'],
    [kTermRobinsons, 'ROUTE_GUINSANGAN'],
    [kTermDalipe1, 'ROUTE_LINDERO'],
    [kTermRobinsons, 'ROUTE_LINDERO'],
    [kTermRobinsons, 'ROUTE_DAO'], // Robinsons only, never Dalipe
    [kTermDalipe2, 'ROUTE_ANINIY'],
    [kTermDalipe1, 'ROUTE_SIBALOM'],
    [kTermDalipe1, 'ROUTE_BELISON'],
    [kTermDalipe1, 'ROUTE_PATNONGON'],
    [kTermDalipe1, 'ROUTE_BUGASONG'],
    [kTermDalipe1, 'ROUTE_SAN_REMIGIO'],
    [kTermDalipe2, 'ROUTE_VALDERRAMA'],
  ];

  /// One-off: creates every missing queue doc above. Returns the ids created.
  /// Call from a temporary button or a debug screen, then remove it.
  static Future<List<String>> seedAll() async {
    final created = <String>[];
    for (final q in defaultQueues) {
      if (await ensure(q[0], q[1])) {
        created.add('${q[0]}_${q[1].replaceFirst('ROUTE_', '')}');
      }
    }
    return created;
  }
}