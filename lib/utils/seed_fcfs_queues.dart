import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

Future<void> seedFcfsTerminalsQueue() async {
  final firestore = FirebaseFirestore.instance;
  final batch = firestore.batch();

  final List<Map<String, String>> fcfsRoutes = [
    {
      'docId': 'TERM_DALIPE_1_BELISON',
      'routeId': 'ROUTE_BELISON',
      'routeName': 'Belison',
    },
    {
      'docId': 'TERM_DALIPE_1_BUGASONG',
      'routeId': 'ROUTE_BUGASONG',
      'routeName': 'Bugasong',
    },
    {
      'docId': 'TERM_DALIPE_1_SAN_REMIGIO',
      'routeId': 'ROUTE_SAN_REMIGIO',
      'routeName': 'San Remigio',
    },
    {
      'docId': 'TERM_DALIPE_1_PATNONGON',
      'routeId': 'ROUTE_PATNONGON',
      'routeName': 'Patnongon',
    },
  ];

  for (final item in fcfsRoutes) {
    final docRef = firestore.collection('terminals_queue').doc(item['docId']);

    batch.set(
      docRef,
      {
        'terminal_id': 'TERM_DALIPE_1',
        'terminal_name': 'Dalipe Terminal 1',
        'route_id': item['routeId'],
        'active_loading_vehicle': 'None',
        'queued_vehicles': <String>[],
        'standby_staged_vehicles': <String>[],
        'created_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  await batch.commit();
  debugPrint('[SEEDER] FCFS terminal queues initialized successfully.');
}