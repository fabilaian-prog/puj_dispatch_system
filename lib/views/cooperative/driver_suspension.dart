import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../utils/app_colors.dart';

// =============================================================================
// DRIVER SUSPENSION
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

// -----------------------------------------------------------------------------
// Dialog: pick a length and a reason. Returns true if the driver was suspended.
// -----------------------------------------------------------------------------
Future<bool> showSuspendDriverDialog(
  BuildContext context, {
  required String driverId,
  required String driverName,
  required String officerName,
  required String coopId,
  required String coopName,
  String? plate,
  String? complaintId,
  String initialReason = '',
}) async {
  final reasonCtl = TextEditingController(text: initialReason);
  // null days = until lifted
  final options = <String, int?>{
    '1 day': 1,
    '3 days': 3,
    '7 days': 7,
    '30 days': 30,
    'Until lifted': null,
  };
  String picked = '3 days';
  bool saving = false;
  String? error;

  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSt) => AlertDialog(
        backgroundColor: Colors.white,
        title: Text('Suspend $driverName?',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'The driver will not be able to check in at any terminal until '
                'the suspension ends or you lift it. Any QR pass already '
                'generated is cancelled and the unit is removed from waiting '
                'line-ups.',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final k in options.keys)
                    ChoiceChip(
                      label: Text(k, style: const TextStyle(fontSize: 12)),
                      selected: picked == k,
                      onSelected: saving ? null : (_) => setSt(() => picked = k),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonCtl,
                maxLines: 3,
                enabled: !saving,
                decoration: const InputDecoration(
                  labelText: 'Reason (shown to the driver)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.errorCrimson)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.errorCrimson,
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            onPressed: saving
                ? null
                : () async {
                    final reason = reasonCtl.text.trim();
                    if (reason.isEmpty) {
                      setSt(() => error = 'Enter a reason.');
                      return;
                    }
                    setSt(() {
                      saving = true;
                      error = null;
                    });
                    try {
                      final days = options[picked];
                      final res = await DriverSuspensionRepo.suspend(
                        driverId: driverId,
                        driverName: driverName,
                        reason: reason,
                        officerName: officerName,
                        coopId: coopId,
                        coopName: coopName,
                        plate: plate,
                        complaintId: complaintId,
                        until: days == null
                            ? null
                            : DateTime.now().add(Duration(days: days)),
                      );
                      if (ctx.mounted) Navigator.pop(ctx, true);
                      if (context.mounted) {
                        final extra = res.stillAtSpot1.isNotEmpty
                            ? ' The unit is currently at Spot 1 (${res.stillAtSpot1.join(', ')}): ask that dispatcher to release it.'
                            : res.queueCleanupFailed
                                ? ' Could not clear the line-up automatically; tell the dispatcher.'
                                : '';
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('$driverName suspended.$extra'),
                          backgroundColor: const Color(0xFF059669),
                          duration: const Duration(seconds: 5),
                        ));
                      }
                    } catch (e) {
                      setSt(() {
                        saving = false;
                        error = 'Failed: $e';
                      });
                    }
                  },
            child: saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('Suspend driver'),
          ),
        ],
      ),
    ),
  );
  return ok == true;
}

// -----------------------------------------------------------------------------
// Panel dropped into the coop's complaint dialog. Finds the driver of the
// reported plate, shows their suspension state, and offers Suspend / Lift.
// -----------------------------------------------------------------------------
class ComplaintSuspensionPanel extends StatefulWidget {
  final String plate;
  final String complaintId;
  final String complaintCategory;
  final String officerName;
  final String coopId;
  final String coopName;

  /// Pass the dashboard's _matchesCooperative so a coop can only act on its
  /// own drivers.
  final bool Function(Map<String, dynamic>) belongsToCoop;

  const ComplaintSuspensionPanel({
    super.key,
    required this.plate,
    required this.complaintId,
    required this.complaintCategory,
    required this.officerName,
    required this.coopId,
    required this.coopName,
    required this.belongsToCoop,
  });

  @override
  State<ComplaintSuspensionPanel> createState() =>
      _ComplaintSuspensionPanelState();
}

class _ComplaintSuspensionPanelState extends State<ComplaintSuspensionPanel> {
  late Future<({String id, String name})?> _driver = _resolve();

  static String _norm(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();

  Future<({String id, String name})?> _resolve() async {
    final db = FirebaseFirestore.instance;
    final plate = widget.plate.trim();
    if (plate.isEmpty || plate == 'N/A') return null;

    Map<String, dynamic>? v;
    final direct = await db.collection('vehicles_live').doc(plate).get();
    if (direct.exists) {
      v = direct.data();
    } else {
      final all = await db.collection('vehicles_live').get();
      for (final d in all.docs) {
        final p = (d.data()['plate_number'] ?? d.id).toString();
        if (_norm(p) == _norm(plate)) {
          v = d.data();
          break;
        }
      }
    }
    if (v == null || !widget.belongsToCoop(v)) return null;

    final id = (v['driver_id'] ?? '').toString().trim();
    if (id.isEmpty || id == 'UNASSIGNED' || id == 'None') return null;
    final u = await db.collection('users').doc(id).get();
    final name = (u.data()?['full_name'] ?? v['driver_name'] ?? id).toString();
    return (id: id, name: name);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<({String id, String name})?>(
      future: _driver,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        final drv = snap.data;
        if (drv == null) {
          return _box(
            const Color(0xFFF8FAFC),
            AppColors.borderSubtle,
            const Text(
              'No driver of your cooperative is currently assigned to this '
              'plate, so there is no one to suspend from here.',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          );
        }
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('users')
              .doc(drv.id)
              .snapshots(),
          builder: (context, us) {
            final s = DriverSuspension.fromUser(us.data?.data());
            return _box(
              s.active ? const Color(0xFFFEF2F2) : const Color(0xFFF8FAFC),
              s.active ? const Color(0xFFFECACA) : AppColors.borderSubtle,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(s.active ? Icons.block_rounded : Icons.badge_outlined,
                        size: 17,
                        color: s.active
                            ? AppColors.errorCrimson
                            : AppColors.primaryNavy),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('Driver: ${drv.name}',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: AppColors.darkSlate)),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                    s.active
                        ? s.message
                        : 'Currently assigned to ${widget.plate}. Suspending '
                            'blocks this driver from queuing at every terminal.',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 36,
                    child: s.active
                        ? OutlinedButton.icon(
                            icon: const Icon(Icons.lock_open_rounded, size: 16),
                            label: const Text('Lift suspension'),
                            onPressed: () async {
                              await DriverSuspensionRepo.lift(
                                driverId: drv.id,
                                driverName: drv.name,
                                officerName: widget.officerName,
                                coopId: widget.coopId,
                                coopName: widget.coopName,
                              );
                            },
                          )
                        : ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.errorCrimson,
                              foregroundColor: Colors.white,
                              elevation: 0,
                            ),
                            icon: const Icon(Icons.block_rounded, size: 16),
                            label: const Text('Suspend driver'),
                            onPressed: () => showSuspendDriverDialog(
                              context,
                              driverId: drv.id,
                              driverName: drv.name,
                              plate: widget.plate,
                              complaintId: widget.complaintId,
                              officerName: widget.officerName,
                              coopId: widget.coopId,
                              coopName: widget.coopName,
                              initialReason: widget.complaintCategory,
                            ),
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _box(Color bg, Color border, Widget child) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border),
        ),
        child: child,
      );
}