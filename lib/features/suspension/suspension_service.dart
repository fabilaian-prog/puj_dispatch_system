import 'package:cloud_firestore/cloud_firestore.dart';

// =============================================================================
// DRIVER SUSPENSION — service / repository
//
// Stored on users/{driverId}:
//   is_suspended         bool
//   suspended_until      Timestamp?  (null = until the coop lifts it)
//   suspension_reason    String
//   suspended_by         String      (coop officer name)
//   suspended_by_coop    String      (coop id)
//   suspended_at         Timestamp
//   suspension_complaint_id String?  (complaint that triggered it)
//
// Every suspend / lift is also written to driver_suspensions (audit trail).
// A timed suspension expires by itself: fromUser() compares suspended_until
// with the clock, so no scheduled job is needed.
// =============================================================================

class DriverSuspension {
  final bool active;
  final String reason;
  final DateTime? until;

  const DriverSuspension({required this.active, this.reason = '', this.until});

  static const none = DriverSuspension(active: false);

  /// Pass a users/{id} map. Safe with null.
  static DriverSuspension fromUser(Map<String, dynamic>? u) {
    if (u == null || u['is_suspended'] != true) return none;
    final raw = u['suspended_until'];
    final until = raw is Timestamp ? raw.toDate() : null;
    if (until != null && DateTime.now().isAfter(until)) return none;
    return DriverSuspension(
      active: true,
      reason: (u['suspension_reason'] ?? '').toString().trim(),
      until: until,
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String get untilLabel {
    final u = until;
    if (u == null) return 'until the cooperative lifts it';
    final l = u.toLocal();
    final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
    final m = l.minute.toString().padLeft(2, '0');
    final ap = l.hour >= 12 ? 'PM' : 'AM';
    return 'until ${_months[l.month - 1]} ${l.day}, $h:$m $ap';
  }

  /// Text shown to the driver / dispatcher.
  String get message =>
      'Suspended $untilLabel.${reason.isEmpty ? '' : ' Reason: $reason'}';
}

class SuspendResult {
  final int removedFromQueues;
  final List<String> stillAtSpot1; // terminals where the unit is Spot 1
  final bool queueCleanupFailed;
  const SuspendResult(
      this.removedFromQueues, this.stillAtSpot1, this.queueCleanupFailed);
}

class DriverSuspensionRepo {
  DriverSuspensionRepo._();

  static final _db = FirebaseFirestore.instance;

  static Future<SuspendResult> suspend({
    required String driverId,
    required String driverName,
    required String reason,
    required String officerName,
    required String coopId,
    required String coopName,
    DateTime? until,
    String? complaintId,
    String? plate,
  }) async {
    final userRef = _db.collection('users').doc(driverId);
    final userSnap = await userRef.get();
    final vehicleId =
        (userSnap.data()?['assigned_vehicle'] ?? '').toString().trim();

    final batch = _db.batch();

    batch.update(userRef, {
      'is_suspended': true,
      'suspended_until': until == null ? null : Timestamp.fromDate(until),
      'suspension_reason': reason,
      'suspended_by': officerName,
      'suspended_by_coop': coopId,
      'suspended_at': FieldValue.serverTimestamp(),
      'suspension_complaint_id': complaintId,
      // Kills any QR pass the driver already generated.
      'qr_token': null,
      'qr_expires_at': null,
    });

    final logRef = _db.collection('driver_suspensions').doc();
    batch.set(logRef, {
      'log_id': logRef.id,
      'event_type': 'SUSPENDED',
      'driver_id': driverId,
      'driver_name': driverName,
      'vehicle_id': vehicleId,
      'plate_number': plate,
      'complaint_id': complaintId,
      'reason': reason,
      'suspended_until': until == null ? null : Timestamp.fromDate(until),
      'cooperative_id': coopId,
      'cooperative_name': coopName,
      'officer_name': officerName,
      'timestamp': FieldValue.serverTimestamp(),
    });

    if (complaintId != null && complaintId.isNotEmpty) {
      final note = 'Driver $driverName suspended ${DriverSuspension(active: true, until: until).untilLabel}. Reason: $reason';
      batch.update(_db.collection('complaints').doc(complaintId), {
        'cooperative_comments': FieldValue.arrayUnion([
          {
            'author_name': officerName,
            'coop_name': coopName,
            'message': note,
            'created_at': Timestamp.now(),
          }
        ]),
        'latest_coop_comment': note,
        'updated_at': FieldValue.serverTimestamp(),
      });
    }

    await batch.commit();

    // Pull the unit out of any line-up it is already waiting in.
    // Best effort: the suspension above is already in force either way.
    int removed = 0;
    final spot1 = <String>[];
    bool failed = false;
    if (vehicleId.isNotEmpty &&
        vehicleId != 'UNASSIGNED' &&
        vehicleId != 'None') {
      try {
        final q = _db.collection('terminals_queue');
        for (final field in const ['queued_vehicles', 'standby_staged_vehicles']) {
          final snap = await q.where(field, arrayContains: vehicleId).get();
          for (final d in snap.docs) {
            await d.reference.update({
              field: FieldValue.arrayRemove([vehicleId]),
              'updated_at': FieldValue.serverTimestamp(),
            });
            removed++;
          }
        }
        final active =
            await q.where('active_loading_vehicle', isEqualTo: vehicleId).get();
        for (final d in active.docs) {
          spot1.add((d.data()['terminal_name'] ?? d.id).toString());
        }
      } catch (_) {
        failed = true;
      }
    }
    return SuspendResult(removed, spot1, failed);
  }

  static Future<void> lift({
    required String driverId,
    required String driverName,
    required String officerName,
    required String coopId,
    required String coopName,
  }) async {
    final batch = _db.batch();
    batch.update(_db.collection('users').doc(driverId), {
      'is_suspended': false,
      'suspended_until': FieldValue.delete(),
      'suspension_reason': FieldValue.delete(),
      'suspended_by': FieldValue.delete(),
      'suspended_by_coop': FieldValue.delete(),
      'suspended_at': FieldValue.delete(),
      'suspension_complaint_id': FieldValue.delete(),
    });
    final logRef = _db.collection('driver_suspensions').doc();
    batch.set(logRef, {
      'log_id': logRef.id,
      'event_type': 'LIFTED',
      'driver_id': driverId,
      'driver_name': driverName,
      'cooperative_id': coopId,
      'cooperative_name': coopName,
      'officer_name': officerName,
      'timestamp': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }
}
