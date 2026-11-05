import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../auth/login_screen.dart';
import '../../utils/staff_auth.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/app_colors.dart';
import '../../utils/app_typography.dart';
import '../cooperative/route_process_config.dart';
import '../cooperative/rotation_master_list.dart';
import '../cooperative/driver_suspension.dart';

class DriverDashboardScreen extends StatefulWidget {
  final String userId;
  final Map<String, dynamic> userData;

  const DriverDashboardScreen({
    super.key,
    required this.userId,
    required this.userData,
  });

  @override
  State<DriverDashboardScreen> createState() => _DriverDashboardScreenState();
}

class _DriverDashboardScreenState extends State<DriverDashboardScreen> {
  static const MethodChannel _screenChannel = MethodChannel(
    'com.example.puj_dispatch_system/screen',
  );

  // Rotation list streams, one per route, so the line-up does not resubscribe
  // every time the queue snapshot rebuilds the screen.
  final Map<String, Stream<RotationConfig>> _rotStreams = {};
  Stream<RotationConfig> _rotationStream(RouteProcessConfig p) =>
      _rotStreams.putIfAbsent(
        p.routeId,
        () => RotationRepo.watch(p.ownerCoopId, p.routeId).asBroadcastStream(),
      );

  bool _isTogglingStatus = false;
  bool _isAlarmModalShowing = false;
  bool _isPlayingSound = false;

  // Daily pre-trip (BLOWBAGETS) state, kept in sync from the user stream in build()
  bool _preTripDoneToday = false;
  String _currentDriverName = 'Driver';

  late final AudioPlayer _audioPlayer;
  StreamSubscription<DocumentSnapshot>? _vehicleAlertSub;

  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    _initAudio();
    _listenToVehicleAlerts();
  }

  Future<void> _initAudio() async {
    try {
      await _audioPlayer.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            isSpeakerphoneOn: true,
            stayAwake: true,
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.alarm,
            audioFocus: AndroidAudioFocus.gainTransientExclusive,
            audioMode: AndroidAudioMode.normal,
          ),
        ),
      );
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      debugPrint('AudioContext successfully configured.');
    } catch (e) {
      debugPrint('AudioContext configuration error: $e');
    }
  }

  // ===========================================================================
  // SCREEN WAKE (LOCKSCREEN & DISPLAY WAKEUP)
  // ===========================================================================
  Future<void> _wakeDeviceScreen() async {
    try {
      await _screenChannel.invokeMethod('wakeScreen');
      debugPrint('Native screen wake executed.');
    } catch (e) {
      debugPrint('Screen wake execution error: $e');
    }
  }

  // ===========================================================================
  // BACKGROUND STREAM LISTENER (MONITORS DISPATCHER ALERTS)
  // ===========================================================================
  void _listenToVehicleAlerts() {
    final vehicleId = (widget.userData['assigned_vehicle'] ?? 'UNASSIGNED')
        .toString();
    if (vehicleId == 'UNASSIGNED' || vehicleId == 'None') return;

    _vehicleAlertSub?.cancel();
    _vehicleAlertSub = FirebaseFirestore.instance
        .collection('vehicles_live')
        .doc(vehicleId)
        .snapshots()
        .listen(
          (snapshot) {
            if (!snapshot.exists) return;
            final vData = snapshot.data();
            if (vData == null) return;

            final alertData = vData['driver_alert'] as Map<String, dynamic>?;
            if (alertData != null && alertData['is_active'] == true) {
              _wakeDeviceScreen();
              _startAlarm();
              if (mounted && !_isAlarmModalShowing) {
                final routeId = (vData['route_id'] ?? 'ROUTE_GUINSANGAN')
                    .toString();
                _showAlarmModal(vehicleId, routeId, alertData);
              }
            } else {
              _stopAlarm();
            }
          },
          onError: (e) {
            debugPrint('Background alert stream error: $e');
          },
        );
  }

  @override
  void dispose() {
    _stopAlarm();
    _vehicleAlertSub?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _startAlarm() async {
    if (!_isPlayingSound) {
      _isPlayingSound = true;
      try {
        debugPrint('--> Triggering alarm audio: sounds/alarm.mp3');
        await _audioPlayer.stop();
        await _audioPlayer.play(
          AssetSource('sounds/alarm.mp3'),
          volume: 1.0,
          mode: PlayerMode.mediaPlayer,
        );
        debugPrint('--> Alarm playback active.');
      } catch (e, stack) {
        _isPlayingSound = false;
        debugPrint('AudioPlayer playback failed: $e');
        debugPrint('Stacktrace: $stack');
      }
    }
  }

  Future<void> _stopAlarm() async {
    if (_isPlayingSound) {
      _isPlayingSound = false;
      try {
        await _audioPlayer.stop();
        debugPrint('--> Alarm stopped.');
      } catch (e) {
        debugPrint('Error stopping audio: $e');
      }
    }
  }

  // ===========================================================================
  // VEHICLE MATCHING HELPERS
  // ===========================================================================
  bool _isVehicleMatch(String? candidate, String vehicleId, String plate) {
    if (candidate == null) return false;
    final cand = candidate.trim().toUpperCase();
    if (cand.isEmpty || cand == 'NONE' || cand == 'NULL' || cand == 'UNASSIGNED') {
      return false;
    }
    final vId = vehicleId.trim().toUpperCase();
    final p = plate.trim().toUpperCase();

    if (cand == vId || cand == p) return true;

    final cleanCand = cand.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final cleanVId = vId.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final cleanPlate = p.replaceAll(RegExp(r'[^A-Z0-9]'), '');

    return cleanCand.isNotEmpty && (cleanCand == cleanVId || cleanCand == cleanPlate);
  }

  int _findVehicleIndexInList(List<dynamic>? list, String vehicleId, String plate) {
    if (list == null || list.isEmpty) return -1;
    for (int i = 0; i < list.length; i++) {
      if (_isVehicleMatch(list[i]?.toString(), vehicleId, plate)) {
        return i;
      }
    }
    return -1;
  }

  // ===========================================================================
  // DAILY PRE-TRIP INSPECTION (B.L.O.W.B.A.G.E.T.S.)
  // Must be completed once per calendar day before the driver can
  // (a) turn on Biyahe / live location, or (b) generate a terminal QR pass.
  // ===========================================================================
  static const List<Map<String, String>> _preTripItems = [
    {
      'key': 'battery',
      'letter': 'B',
      'title': 'Battery',
      'desc': 'Terminals are clean, tightly fastened, and have sufficient charge.',
    },
    {
      'key': 'lights',
      'letter': 'L',
      'title': 'Lights',
      'desc': 'Headlights, brake lights, signal lights, and hazard flashers all illuminate properly.',
    },
    {
      'key': 'oil',
      'letter': 'O',
      'title': 'Oil',
      'desc': 'Engine oil level is between the dipstick markers and not dark/milky.',
    },
    {
      'key': 'water',
      'letter': 'W',
      'title': 'Water',
      'desc': 'Radiator coolant and reservoir levels are topped up (never open when hot).',
    },
    {
      'key': 'brakes',
      'letter': 'B',
      'title': 'Brakes',
      'desc': 'Brake pedal feels firm (not spongy) and the handbrake holds firmly.',
    },
    {
      'key': 'air',
      'letter': 'A',
      'title': 'Air',
      'desc': "Tire pressure is within the manufacturer's recommended PSI on all wheels (including the spare).",
    },
    {
      'key': 'gas',
      'letter': 'G',
      'title': 'Gas',
      'desc': 'Sufficient fuel to complete the trip/route without risking an empty tank.',
    },
    {
      'key': 'engine',
      'letter': 'E',
      'title': 'Engine',
      'desc': 'No visible fluid leaks underneath, belts are intact, and no abnormal knocking sounds upon starting.',
    },
    {
      'key': 'tires',
      'letter': 'T',
      'title': 'Tires',
      'desc': 'Adequate tread depth with no visible punctures, bulges, or uneven wear.',
    },
    {
      'key': 'self',
      'letter': 'S',
      'title': 'Self',
      'desc': 'I am well-rested, sober, mentally alert, and physically fit to operate the vehicle.',
    },
  ];

  /// Local calendar-day key, e.g. 2026-10-07. Must match the dispatcher's format.
  String _todayKey() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}-'
        '${n.day.toString().padLeft(2, '0')}';
  }

  /// Returns true if today's checklist is already done, otherwise opens the
  /// checklist and returns whether the driver completed it.
  Future<bool> _ensurePreTripVerified(String vehicleId) async {
    if (_preTripDoneToday) return true;
    return _showPreTripChecklistModal(vehicleId);
  }

  Future<bool> _showPreTripChecklistModal(String vehicleId) async {
    AppTypography.lightFeedback();
    final checked = <String, bool>{
      for (final i in _preTripItems) i['key']!: false,
    };
    bool isSaving = false;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final doneCount = checked.values.where((v) => v).length;
            final allDone = doneCount == _preTripItems.length;

            return PopScope(
              canPop: !isSaving,
              child: SafeArea(
                child: Dialog(
                  backgroundColor: Colors.white,
                  surfaceTintColor: Colors.transparent,
                  insetPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 20,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryNavy.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.fact_check_rounded,
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
                                      'Daily Pre-Trip Check',
                                      style: TextStyle(
                                        fontSize: 15.5,
                                        fontWeight: FontWeight.w900,
                                        color: AppColors.darkSlate,
                                      ),
                                    ),
                                    Text(
                                      'B.L.O.W.B.A.G.E.T.S. • Required before Biyahe & terminal pass',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(
                                  Icons.close_rounded,
                                  size: 20,
                                  color: AppColors.textMuted,
                                ),
                                onPressed: isSaving
                                    ? null
                                    : () => Navigator.pop(dialogCtx, false),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: doneCount / _preTripItems.length,
                              minHeight: 5,
                              backgroundColor: const Color(0xFFE2E8F0),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                allDone
                                    ? const Color(0xFF059669)
                                    : AppColors.primaryNavy,
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              '$doneCount / ${_preTripItems.length} checked',
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                        ),
                        const Divider(height: 1, color: AppColors.borderSubtle),
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            itemCount: _preTripItems.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 6),
                            itemBuilder: (_, index) {
                              final item = _preTripItems[index];
                              final key = item['key']!;
                              final isOn = checked[key] == true;

                              return Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: isSaving
                                      ? null
                                      : () {
                                          HapticFeedback.selectionClick();
                                          setDialogState(
                                            () => checked[key] = !isOn,
                                          );
                                        },
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 150),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 9,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isOn
                                          ? const Color(0xFFF0FDF4)
                                          : const Color(0xFFF8FAFC),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: isOn
                                            ? const Color(0xFF86EFAC)
                                            : AppColors.borderSubtle,
                                        width: 1.2,
                                      ),
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          width: 30,
                                          height: 30,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: isOn
                                                ? const Color(0xFF059669)
                                                : AppColors.primaryNavy,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            item['letter']!,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w900,
                                              fontSize: 15,
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
                                                item['title']!,
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w800,
                                                  color: AppColors.darkSlate,
                                                ),
                                              ),
                                              const SizedBox(height: 1),
                                              Text(
                                                item['desc']!,
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  height: 1.3,
                                                  color: AppColors.textMuted,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Icon(
                                          isOn
                                              ? Icons.check_circle_rounded
                                              : Icons.radio_button_unchecked,
                                          size: 24,
                                          color: isOn
                                              ? const Color(0xFF059669)
                                              : AppColors.textMuted,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const Divider(height: 1, color: AppColors.borderSubtle),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'By confirming, I declare that I personally inspected this vehicle and that every item above is true. If anything fails, do not drive — report it to your dispatcher/operator.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 10,
                                  height: 1.3,
                                  color: AppColors.textMuted,
                                ),
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                width: double.infinity,
                                height: 46,
                                child: ElevatedButton.icon(
                                  icon: isSaving
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.verified_rounded,
                                          size: 20,
                                        ),
                                  label: Text(
                                    allDone
                                        ? 'CONFIRM PRE-TRIP CHECK'
                                        : 'CHECK ALL ITEMS TO CONTINUE',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 12.5,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF059669),
                                    foregroundColor: Colors.white,
                                    disabledBackgroundColor:
                                        const Color(0xFFCBD5E1),
                                    disabledForegroundColor: Colors.white,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  onPressed: (!allDone || isSaving)
                                      ? null
                                      : () async {
                                          setDialogState(() => isSaving = true);
                                          final ok = await _savePreTripCheck(
                                            vehicleId,
                                            checked,
                                          );
                                          if (!dialogCtx.mounted) return;
                                          if (ok) {
                                            Navigator.pop(dialogCtx, true);
                                          } else {
                                            setDialogState(
                                              () => isSaving = false,
                                            );
                                          }
                                        },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    return result == true;
  }

  Future<bool> _savePreTripCheck(
    String vehicleId,
    Map<String, bool> checked,
  ) async {
    final today = _todayKey();
    final db = FirebaseFirestore.instance;

    try {
      // Source of truth the dispatcher validates when scanning the QR pass.
      await db.collection('users').doc(widget.userId).update({
        'pretrip_date': today,
        'pretrip_verified_at': FieldValue.serverTimestamp(),
        'pretrip_vehicle': vehicleId,
      });
    } catch (e) {
      _showSnackbar('Failed to save pre-trip check: $e', isError: true);
      return false;
    }

    // Best-effort audit log (one doc per driver per day). Never blocks the driver.
    try {
      await db.collection('pretrip_inspections').doc('${widget.userId}_$today').set({
        'driver_id': widget.userId,
        'driver_name': _currentDriverName,
        'vehicle_id': vehicleId,
        'date': today,
        'items': checked,
        'all_passed': true,
        'cooperative_id': (widget.userData['cooperative_id'] ?? '').toString(),
        'verified_at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('Pre-trip audit log write failed (non-blocking): $e');
    }

    _preTripDoneToday = true;
    _showSnackbar('Pre-trip check verified. Safe travels!');
    return true;
  }

  Widget _buildPreTripCard({
    required String vehicleId,
    required bool done,
    Timestamp? verifiedAt,
  }) {
    if (done) {
      final t = verifiedAt?.toDate().toLocal();
      final timeStr = t == null
          ? ''
          : ' • ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFF0FDF4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF86EFAC)),
        ),
        child: Row(
          children: [
            const Icon(Icons.verified_rounded, size: 18, color: Color(0xFF059669)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Pre-trip check completed today$timeStr',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF047857),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFCD34D), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.fact_check_rounded, size: 20, color: Color(0xFFD97706)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'DAILY PRE-TRIP CHECK REQUIRED',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF92400E),
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Complete the B.L.O.W.B.A.G.E.T.S. inspection to unlock Biyahe (live location) and your terminal check-in QR pass.',
            style: TextStyle(fontSize: 11, height: 1.3, color: Color(0xFF78350F)),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.checklist_rounded, size: 18),
              label: const Text(
                'START PRE-TRIP CHECK',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD97706),
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () => _showPreTripChecklistModal(vehicleId),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // "BIYAHE" DUTY TOGGLE (LOCKED WHILE IN QUEUE / BAY)
  // ===========================================================================
  Future<void> _toggleDutyStatus({
    required String vehicleId,
    required bool currentEnRoute,
    bool isQueueLocked = false,
  }) async {
    if (isQueueLocked && !currentEnRoute) {
      HapticFeedback.mediumImpact();
      _showSnackbar(
        'Cannot activate Biyahe while staged in the terminal bay/queue. Your vehicle remains hidden from passenger maps until the dispatcher confirms departure.',
        isError: true,
      );
      return;
    }

    // Turning Biyahe ON (live location) requires today's pre-trip check.
    if (!currentEnRoute) {
      final verified = await _ensurePreTripVerified(vehicleId);
      if (!verified || !mounted) return;
    }

    AppTypography.selectionFeedback();
    setState(() => _isTogglingStatus = true);

    try {
      final newStatus = currentEnRoute ? 'STANDBY' : 'EN_ROUTE';

      await FirebaseFirestore.instance
          .collection('vehicles_live')
          .doc(vehicleId)
          .update({
            'current_status': newStatus,
            'visible_to_commuters': newStatus == 'EN_ROUTE',
            if (newStatus == 'STANDBY') ...{
              'transit_tag': null,
              'speed_kmh': 0,
            },
            'updated_at': FieldValue.serverTimestamp(),
          });

      _showSnackbar(
        newStatus == 'EN_ROUTE'
            ? 'Biyahe started! Live hardware coordinates visible on commuter map.'
            : 'Unit set to Standby mode (hidden from commuter map).',
      );
    } catch (e) {
      _showSnackbar('Failed to update status: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isTogglingStatus = false);
    }
  }

  // ===========================================================================
  // COMPLETE BIYAHE / END OF TRIP RESET
  // ===========================================================================
  Future<void> _confirmAndCompleteBiyahe(String vehicleId) async {
    AppTypography.lightFeedback();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.flag_circle_rounded, color: Color(0xFF059669), size: 22),
            SizedBox(width: 8),
            Text(
              'Complete Biyahe?',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 16,
                color: AppColors.darkSlate,
              ),
            ),
          ],
        ),
        content: const Text(
          'This will conclude your dispatched route trip, reset onboard passenger count to 0, hide your unit from passenger maps, and return to Standby status.',
          style: TextStyle(
            fontSize: 12.5,
            color: AppColors.textMuted,
            height: 1.35,
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
              backgroundColor: const Color(0xFF059669),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Finish Trip',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isTogglingStatus = true);

    try {
      await FirebaseFirestore.instance
          .collection('vehicles_live')
          .doc(vehicleId)
          .update({
            'current_status': 'STANDBY',
            'is_dispatched': false,
            'visible_to_commuters': false,
            'passenger_count': 0,
            'transit_tag': null,
            'speed_kmh': 0,
            'last_trip_completed_at': FieldValue.serverTimestamp(),
            'updated_at': FieldValue.serverTimestamp(),
          });

      _showSnackbar('Biyahe completed! Passenger occupancy reset to 0.');
    } catch (e) {
      _showSnackbar('Failed to complete biyahe: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isTogglingStatus = false);
    }
  }

  // ===========================================================================
  // FULLSCREEN HIGH-ALERT DISPATCH CALL HUD
  // ===========================================================================
  void _showAlarmModal(
    String vehicleId,
    String routeId,
    Map<String, dynamic> alertData,
  ) {
    _isAlarmModalShowing = true;

    final title = alertData['title'] ?? 'DISPATCH CALL';
    final message =
        alertData['message'] ?? 'Robinsons Terminal is calling your unit!';
    final caller = alertData['caller_name'] ?? 'Dispatcher';

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogCtx) => PopScope(
          canPop: false,
          child: Dialog.fullscreen(
            backgroundColor: const Color(0xFF1E3A8A),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 20),
                    Center(
                      child: Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.notifications_active_rounded,
                          size: 48,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      title.toString().toUpperCase(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white70,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Authorized by: $caller',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white54,
                      ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      height: 54,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.check_circle_rounded, size: 24),
                        label: const Text(
                          'ACKNOWLEDGE & DEPART',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 14.5,
                            letterSpacing: 0.5,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 6,
                        ),
                        onPressed: () async {
                          AppTypography.selectionFeedback();
                          _isAlarmModalShowing = false;
                          await _stopAlarm();
                          if (!context.mounted) return;
                          Navigator.pop(dialogCtx);

                          try {
                            final isRobinsonsCall =
                                alertData['type'] == 'CALL_TO_ROBINSONS';
                            // Process-based, so Lindero behaves like Guinsang-an.
                            final isGuinsangan =
                                RouteProcesses.of(routeId)?.hasApproachLeg ??
                                false;

                            await FirebaseFirestore.instance
                                .collection('vehicles_live')
                                .doc(vehicleId)
                                .update({
                                  'driver_alert.is_active': false,
                                  'driver_alert.acknowledged_at':
                                      FieldValue.serverTimestamp(),
                                  'current_status': 'EN_ROUTE',
                                  'visible_to_commuters': true,
                                  if (isRobinsonsCall && isGuinsangan)
                                    'transit_tag': 'Arriving to Robinsons',
                                  'updated_at': FieldValue.serverTimestamp(),
                                });

                            _showSnackbar(
                              'Alert acknowledged! Heading to terminal.',
                            );
                          } catch (e) {
                            _showSnackbar(
                              'Error updating status: $e',
                              isError: true,
                            );
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
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
                          Icon(Icons.mark_email_read_outlined, color: AppColors.primaryNavy, size: 22),
                          SizedBox(width: 8),
                          Text(
                            'Cooperative Notices & Memos',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                          ),
                        ],
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.textMuted),
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
                        return const Center(child: CircularProgressIndicator(color: AppColors.commuterTeal));
                      }

                      final userId = widget.userId.trim().toLowerCase();
                      final docs = snapshot.data?.docs.where((doc) {
                        final n = doc.data() as Map<String, dynamic>;
                        final nCoop = (n['cooperative_id'] ?? '').toString().trim();
                        if (nCoop.isNotEmpty && coopId.isNotEmpty && nCoop != coopId) return false;

                        final targetMode = (n['target_mode'] ?? 'BROADCAST_ALL').toString();
                        if (targetMode == 'BROADCAST_ALL' || targetMode == 'BROADCAST_DRIVERS') {
                          return true;
                        }
                        if (targetMode == 'INDIVIDUAL') {
                          return (n['target_user_id'] ?? '').toString().trim().toLowerCase() == userId;
                        }
                        return false;
                      }).toList() ?? [];

                      if (docs.isEmpty) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32.0),
                            child: Text(
                              'No broadcast notices or memos recorded yet.',
                              style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                            ),
                          ),
                        );
                      }

                      return ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: docs.length,
                        itemBuilder: (context, index) {
                          final n = docs[index].data() as Map<String, dynamic>;
                          final isUrgent = (n['priority'] ?? '').toString().toUpperCase() == 'URGENT';
                          final isDirect = n['target_mode'] == 'INDIVIDUAL';
                          final title = (n['title'] ?? 'Notice').toString();
                          final message = (n['message'] ?? '').toString();
                          final author = (n['author_name'] ?? 'Operations Office').toString();
                          final Timestamp? ts = n['created_at'] as Timestamp?;
                          final dateStr = ts != null ? ts.toDate().toLocal().toString().substring(0, 16) : 'Recent';

                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: isUrgent ? const Color(0xFFFEF2F2) : const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isUrgent ? const Color(0xFFFECACA) : AppColors.borderSubtle,
                                width: 1.2,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: isUrgent ? const Color(0xFFFEE2E2) : const Color(0xFFEFF6FF),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        isDirect ? 'DIRECT MEMO' : 'BROADCAST',
                                        style: TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w900,
                                          color: isUrgent ? const Color(0xFF991B1B) : const Color(0xFF1D4ED8),
                                        ),
                                      ),
                                    ),
                                    Text(dateStr, style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted)),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  title,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: isUrgent ? const Color(0xFF7F1D1D) : AppColors.darkSlate,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  message,
                                  style: const TextStyle(fontSize: 12.5, height: 1.35, color: AppColors.darkSlate),
                                ),
                                const Divider(height: 16, color: AppColors.borderSubtle),
                                Text(
                                  'Issued by: $author',
                                  style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: AppColors.textMuted),
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
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close Inbox', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.darkSlate)),
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
  // QR CODE DISPATCH CHECK-IN MODAL
  // ===========================================================================
  Future<void> _showDriverQrModal(
    BuildContext context,
    String vehicleId,
    String routeId,
    String driverName,
  ) async {
    // A suspended driver cannot generate a check-in pass.
    try {
      final me = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.userId)
          .get();
      final susp = DriverSuspension.fromUser(me.data());
      if (susp.active) {
        _showSnackbar(susp.message, isError: true);
        return;
      }
    } catch (_) {}

    // QR pass requires today's pre-trip check.
    final verified = await _ensurePreTripVerified(vehicleId);
    if (!verified || !context.mounted) return;

    AppTypography.lightFeedback();
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    final token = List.generate(
      8,
      (index) => chars[random.nextInt(chars.length)],
    ).join();
    final expiresAt = DateTime.now().add(const Duration(minutes: 30));

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.userId)
          .update({
            'qr_token': token,
            'qr_expires_at': Timestamp.fromDate(expiresAt),
          });
    } catch (e) {
      _showSnackbar('Failed to generate pass: $e', isError: true);
      return;
    }

    if (!context.mounted) return;

    final payload = jsonEncode({
      'type': 'TERMINAL_CHECK_IN',
      'driver_id': widget.userId,
      'driver_name': driverName,
      'vehicle_id': vehicleId,
      'route_id': routeId,
      'token': token,
      'pretrip_date': _todayKey(),
      'expires_at': expiresAt.millisecondsSinceEpoch,
    });

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => SafeArea(
        maintainBottomViewPadding: true,
        child: Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Queue Entry Pass',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.darkSlate,
                          ),
                        ),
                        Text(
                          'Valid for 30 mins • Single scan only',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: AppColors.textMuted,
                      ),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const Divider(height: 16, color: AppColors.borderSubtle),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.borderSubtle, width: 2),
                    boxShadow: const [
                      BoxShadow(color: Colors.black12, blurRadius: 10),
                    ],
                  ),
                  child: QrImageView(
                    data: payload,
                    version: QrVersions.auto,
                    size: 180.0,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Colors.black,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Colors.black,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  vehicleId,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                    color: AppColors.darkSlate,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'TOKEN: $token',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      letterSpacing: 2.0,
                      color: Color(0xFF1D4ED8),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.verified_rounded, size: 14, color: Color(0xFF059669)),
                    SizedBox(width: 4),
                    Text(
                      'Pre-trip check verified today',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF047857),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Present this code to the Terminal Dispatcher upon arrival to be placed in the route line-up.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textMuted,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      side: const BorderSide(
                        color: AppColors.borderSubtle,
                        width: 1.2,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text(
                      'Close Pass',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: AppColors.darkSlate,
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
  // ACCOUNT & SECURITY PIN MODAL
  // ===========================================================================
  void _showAccountSettingsModal(
    BuildContext context,
    Map<String, dynamic> currentData,
  ) {
    AppTypography.lightFeedback();
    final formKey = GlobalKey<FormState>();
    final pinController = TextEditingController(
      text: '',
    );
    final nameController = TextEditingController(
      text: currentData['full_name']?.toString() ?? '',
    );
    bool obscurePin = true;
    bool isSaving = false;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return SafeArea(
              maintainBottomViewPadding: true,
              child: Dialog(
                backgroundColor: Colors.white,
                elevation: 6,
                insetPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 24,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: AppColors.borderSubtle),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                    child: Form(
                      key: formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
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
                                  Icons.manage_accounts_rounded,
                                  color: AppColors.primaryNavy,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Driver Profile',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.darkSlate,
                                      ),
                                    ),
                                    Text(
                                      'Update your name and security PIN',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(
                                  Icons.close_rounded,
                                  size: 18,
                                  color: AppColors.textMuted,
                                ),
                                onPressed: () => Navigator.pop(dialogCtx),
                              ),
                            ],
                          ),
                          const Divider(
                            height: 18,
                            color: AppColors.borderSubtle,
                          ),
                          TextFormField(
                            controller: nameController,
                            style: const TextStyle(fontSize: 13),
                            decoration: _buildInputDeco(
                              'Full Name',
                              Icons.badge_outlined,
                            ),
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Name is required'
                                : null,
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: pinController,
                            obscureText: obscurePin,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(
                              fontSize: 13,
                              letterSpacing: 1.2,
                            ),
                            decoration: _buildInputDeco(
                              'New PIN (6+ digits, leave blank to keep)',
                              Icons.lock_outline_rounded,
                              suffix: IconButton(
                                icon: Icon(
                                  obscurePin
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 18,
                                  color: AppColors.textMuted,
                                ),
                                onPressed: () => setDialogState(
                                  () => obscurePin = !obscurePin,
                                ),
                              ),
                            ),
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) {
                                return null; // blank = keep current PIN
                              }
                              if (v.trim().length < 6) {
                                return 'Must be at least 6 digits';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: SizedBox(
                                  height: 40,
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppColors.darkSlate,
                                      side: const BorderSide(
                                        color: AppColors.borderSubtle,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                    onPressed: isSaving
                                        ? null
                                        : () => Navigator.pop(dialogCtx),
                                    child: const Text(
                                      'Cancel',
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: SizedBox(
                                  height: 40,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.primaryNavy,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      elevation: 0,
                                    ),
                                    onPressed: isSaving
                                        ? null
                                        : () async {
                                            if (!formKey.currentState!
                                                .validate()) {
                                              return;
                                            }
                                            setDialogState(
                                              () => isSaving = true,
                                            );

                                            try {
                                              await FirebaseFirestore.instance
                                                  .collection('users')
                                                  .doc(widget.userId)
                                                  .update({
                                                    'full_name': nameController.text.trim(),
                                                  });

                                              if (pinController.text.trim().isNotEmpty) {
                                                await StaffAuth.changeOwnPin(
                                                  pinController.text.trim(),
                                                );
                                              }

                                              if (!context.mounted) return;
                                              Navigator.pop(dialogCtx);
                                              _showSnackbar(
                                                'Profile updated successfully.',
                                              );
                                            } catch (e) {
                                              setDialogState(
                                                () => isSaving = false,
                                              );
                                              _showSnackbar(
                                                'Update failed: $e',
                                                isError: true,
                                              );
                                            }
                                          },
                                    child: isSaving
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              color: Colors.white,
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Text(
                                            'Save Changes',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12.5,
                                            ),
                                          ),
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
              ),
            );
          },
        );
      },
    );
  }

  void _showSnackbar(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError
            ? AppColors.errorCrimson
            : const Color(0xFF059669),
      ),
    );
  }

  InputDecoration _buildInputDeco(
    String label,
    IconData icon, {
    Widget? suffix,
  }) {
    return InputDecoration(
      labelText: label,
      isDense: true,
      prefixIcon: Icon(icon, size: 17, color: AppColors.textMuted),
      suffixIcon: suffix,
      labelStyle: const TextStyle(fontSize: 12, color: AppColors.textMuted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      filled: true,
      fillColor: AppColors.backgroundSlate,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.borderSubtle),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.commuterTeal, width: 1.3),
      ),
    );
  }

  // ===========================================================================
  // MAIN SCAFFOLD WITH STICKY BOTTOM CHECK-IN BAR
  // ===========================================================================
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(widget.userId)
          .snapshots(),
      builder: (context, userSnap) {
        final uData = userSnap.hasData && userSnap.data!.exists
            ? userSnap.data!.data() as Map<String, dynamic>
            : widget.userData;

        final driverName = uData['full_name'] ?? 'Driver';
        final license = uData['license_number'] ?? 'N/A';
        final vehicleId = (uData['assigned_vehicle'] ?? 'UNASSIGNED')
            .toString();
        final hasVehicle = vehicleId != 'UNASSIGNED' && vehicleId != 'None';
        final coopId = (uData['cooperative_id'] ?? '').toString();

        // Pre-trip is valid only for the current calendar day.
        _currentDriverName = driverName.toString();
        _preTripDoneToday = (uData['pretrip_date'] ?? '').toString() == _todayKey();
        final preTripVerifiedAt = uData['pretrip_verified_at'] as Timestamp?;

        return Scaffold(
          backgroundColor: AppColors.backgroundSlate,
          appBar: AppBar(
            elevation: 0.5,
            backgroundColor: AppColors.primaryNavy,
            automaticallyImplyLeading: false,
            titleSpacing: 16,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  driverName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Driver • License: $license',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 10.5,
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
                tooltip: 'Driver Menu',
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                onSelected: (value) async {
                  if (value == 'SETTINGS') {
                    _showAccountSettingsModal(context, uData);
                  } else if (value == 'LOGOUT') {
                    await StaffAuth.signOut();
                    if (!mounted) return;
                    Navigator.pushAndRemoveUntil(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const LoginScreen(),
                      ),
                      (route) => false,
                    );
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'SETTINGS',
                    height: 38,
                    child: Row(
                      children: [
                        Icon(
                          Icons.settings_outlined,
                          size: 16,
                          color: AppColors.darkSlate,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Profile Settings',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(height: 1),
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
                            fontSize: 12.5,
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
          ),
          body: SafeArea(
            maintainBottomViewPadding: true,
            child: !hasVehicle
                ? _buildUnassignedVehicleState()
                : StreamBuilder<DocumentSnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('vehicles_live')
                        .doc(vehicleId)
                        .snapshots(),
                    builder: (context, vSnap) {
                      if (!vSnap.hasData || !vSnap.data!.exists) {
                        return const Center(
                          child: CircularProgressIndicator(
                            color: AppColors.commuterTeal,
                          ),
                        );
                      }

                      final vData = vSnap.data!.data() as Map<String, dynamic>;
                      final plate = (vData['plate_number'] ?? vehicleId).toString();
                      final routeId = (vData['route_id'] ?? 'ROUTE_GUINSANGAN')
                          .toString();
                      final currentStatus =
                          (vData['current_status'] ?? 'STANDBY')
                              .toString()
                              .toUpperCase();
                      final isEnRoute = currentStatus == 'EN_ROUTE';
                      final isDispatched = vData['is_dispatched'] == true;
                      final curPassengers =
                          (vData['passenger_count'] as num?)?.toInt() ?? 0;
                      final maxCapacity =
                          (vData['max_capacity'] as num?)?.toInt() ?? 20;
                      final speed = (vData['speed_kmh'] as num?)?.toInt() ?? 0;
                      final alertData =
                          vData['driver_alert'] as Map<String, dynamic>?;

                      return StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('terminals_queue')
                            .snapshots(),
                        builder: (context, qSnap) {
                          final qDocs = qSnap.data?.docs ?? [];
                          Map<String, dynamic>? activeQueueDoc;
                          bool isAtSpot1 = false;
                          int queueIndex = -1;
                          int standbyIndex = -1;

                          for (var doc in qDocs) {
                            final data = doc.data() as Map<String, dynamic>;
                            final activeUnit = (data['active_loading_vehicle'] ?? '').toString();
                            final queuedList = (data['queued_vehicles'] as List<dynamic>?) ?? [];
                            final stagedList = (data['standby_staged_vehicles'] as List<dynamic>?) ?? [];

                            if (_isVehicleMatch(activeUnit, vehicleId, plate)) {
                              activeQueueDoc = data;
                              isAtSpot1 = true;
                              break;
                            }

                            final qPos = _findVehicleIndexInList(queuedList, vehicleId, plate);
                            if (qPos != -1) {
                              activeQueueDoc = data;
                              queueIndex = qPos;
                              break;
                            }

                            final sPos = _findVehicleIndexInList(stagedList, vehicleId, plate);
                            if (sPos != -1) {
                              activeQueueDoc = data;
                              standbyIndex = sPos;
                              break;
                            }
                          }

                          if (activeQueueDoc == null) {
                            for (var doc in qDocs) {
                              final data = doc.data() as Map<String, dynamic>;
                              if ((data['route_id'] ?? '').toString().trim() == routeId) {
                                activeQueueDoc = data;
                                break;
                              }
                            }
                          }

                          // Every queue doc of this route (Dalipe + Robinsons) so the
                          // line-up shows both terminals, connected by group.
                          final routeQueueDocs = _routeQueueDocs(qDocs, routeId);

                          final rawTerm = (activeQueueDoc?['terminal_name'] ??
                                  activeQueueDoc?['terminal_id'] ??
                                  'Terminal')
                              .toString();
                          final terminalDisplayName = rawTerm.contains('ROBINSON')
                              ? 'Robinsons Terminal'
                              : (rawTerm.contains('DALIPE')
                                  ? 'Dalipe Terminal'
                                  : rawTerm.replaceAll('TERM_', '').replaceAll('_', ' '));

                          final bool isQueueLocked = !isDispatched &&
                              (isAtSpot1 || queueIndex != -1 || standbyIndex != -1);

                          return ListView(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            children: [
                              if (alertData != null &&
                                  alertData['is_active'] == true) ...[
                                _buildActiveAlarmCard(
                                  vehicleId,
                                  routeId,
                                  alertData,
                                ),
                                const SizedBox(height: 12),
                              ],

                              if (isDispatched) ...[
                                _buildActiveTripActionBanner(
                                  vehicleId: vehicleId,
                                  routeId: routeId,
                                  passengerCount: curPassengers,
                                  maxCapacity: maxCapacity,
                                ),
                                const SizedBox(height: 12),
                              ],

                              // SPOT 1 LOADING BAY HERO CARD
                              if (isAtSpot1 && !isDispatched) ...[
                                _buildLoadingBayCard(
                                  vehicleId: vehicleId,
                                  plate: plate,
                                  terminalName: terminalDisplayName,
                                  passengerCount: curPassengers,
                                  maxCapacity: maxCapacity,
                                ),
                                const SizedBox(height: 12),
                              ],

                              // DAILY PRE-TRIP STATUS (hidden while a trip is in progress)
                              if (!isDispatched && !isEnRoute) ...[
                                _buildPreTripCard(
                                  vehicleId: vehicleId,
                                  done: _preTripDoneToday,
                                  verifiedAt: preTripVerifiedAt,
                                ),
                                const SizedBox(height: 12),
                              ],

                              // COOPERATIVE NOTICES & DIRECT MEMOS STREAM
                              StreamBuilder<QuerySnapshot>(
                                stream: FirebaseFirestore.instance
                                    .collection('notices')
                                    .orderBy('created_at', descending: true)
                                    .limit(10)
                                    .snapshots(),
                                builder: (context, noticeSnap) {
                                  if (!noticeSnap.hasData) return const SizedBox.shrink();

                                  final driverCoopId = coopId.trim().toLowerCase();
                                  final driverUserId = widget.userId.trim().toLowerCase();

                                  final myNotices = noticeSnap.data!.docs.where((doc) {
                                    final n = doc.data() as Map<String, dynamic>;
                                    final noticeCoopId = (n['cooperative_id'] ?? '').toString().trim().toLowerCase();
                                    
                                    if (driverCoopId.isNotEmpty && noticeCoopId.isNotEmpty && driverCoopId != noticeCoopId) {
                                      return false;
                                    }

                                    final targetMode = (n['target_mode'] ?? 'BROADCAST_ALL').toString();
                                    if (targetMode == 'BROADCAST_ALL' || targetMode == 'BROADCAST_DRIVERS') return true;
                                    if (targetMode == 'INDIVIDUAL') {
                                      final targetId = (n['target_user_id'] ?? '').toString().trim().toLowerCase();
                                      return targetId == driverUserId;
                                    }
                                    return false;
                                  }).toList();

                                  if (myNotices.isEmpty) return const SizedBox.shrink();

                                  final latest = myNotices.first.data() as Map<String, dynamic>;
                                  final isUrgent = (latest['priority'] ?? '').toString().toUpperCase() == 'URGENT';
                                  final isDirect = latest['target_mode'] == 'INDIVIDUAL';
                                  final title = (latest['title'] ?? 'Notice').toString();
                                  final message = (latest['message'] ?? '').toString();
                                  final author = (latest['author_name'] ?? 'Operations Office').toString();

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: isUrgent ? const Color(0xFFFEF2F2) : const Color(0xFFEFF6FF),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: isUrgent ? const Color(0xFFFECACA) : const Color(0xFFBFDBFE),
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              isUrgent ? Icons.warning_rounded : Icons.campaign_rounded,
                                              size: 20,
                                              color: isUrgent ? const Color(0xFFDC2626) : const Color(0xFF2563EB),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                isDirect ? 'DIRECT MEMO: $title' : 'COOP NOTICE: $title',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 13.5,
                                                  fontWeight: FontWeight.w900,
                                                  color: isUrgent ? const Color(0xFF991B1B) : const Color(0xFF1E40AF),
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
                                            color: isUrgent ? const Color(0xFF7F1D1D) : const Color(0xFF1E3A8A),
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          'Issued by: $author',
                                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textMuted),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),

                              _buildSunlightHUD(
                                vehicleId: vehicleId,
                                plate: plate,
                                isEnRoute: isEnRoute,
                                isAtSpot1: isAtSpot1,
                                isInQueue: queueIndex != -1,
                                queueSlot: queueIndex + 1,
                                isStandby: standbyIndex != -1,
                                isQueueLocked: isQueueLocked,
                                terminalName: terminalDisplayName,
                                speed: speed,
                                passengers: curPassengers,
                                maxCapacity: maxCapacity,
                              ),
                              const SizedBox(height: 14),

                              _buildRouteQueueObserver(
                                activeQueueDoc: activeQueueDoc,
                                vehicleId: vehicleId,
                                plate: plate,
                                routeId: routeId,
                                isAtSpot1: isAtSpot1,
                                queueIndex: queueIndex,
                                standbyIndex: standbyIndex,
                                routeQueueDocs: routeQueueDocs,
                              ),
                              const SizedBox(height: 20),
                            ],
                          );
                        },
                      );
                    },
                  ),
          ),
          bottomNavigationBar: hasVehicle
              ? StreamBuilder<DocumentSnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('vehicles_live')
                      .doc(vehicleId)
                      .snapshots(),
                  builder: (context, snapshot) {
                    final vData =
                        snapshot.data?.data() as Map<String, dynamic>?;
                    final routeId = (vData?['route_id'] ?? 'ROUTE_GUINSANGAN')
                        .toString();

                    return Container(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        10,
                        16,
                        MediaQuery.of(context).padding.bottom > 0
                            ? MediaQuery.of(context).padding.bottom + 6
                            : 14,
                      ),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black12,
                            blurRadius: 10,
                            offset: Offset(0, -2),
                          ),
                        ],
                      ),
                      child: SizedBox(
                        height: 50,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.qr_code_2_rounded, size: 22),
                          label: const Text(
                            'TERMINAL CHECK-IN PASS',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 13.5,
                              letterSpacing: 0.5,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryNavy,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 0,
                          ),
                          onPressed: () => _showDriverQrModal(
                            context,
                            vehicleId,
                            routeId,
                            driverName,
                          ),
                        ),
                      ),
                    );
                  },
                )
              : null,
        );
      },
    );
  }

  // ===========================================================================
  // COMPACT SPOT 1 LOADING BAY CARD
  // ===========================================================================
  Widget _buildLoadingBayCard({
    required String vehicleId,
    required String plate,
    required String terminalName,
    required int passengerCount,
    required int maxCapacity,
  }) {
    final bool isFull = passengerCount >= maxCapacity;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFECFDF5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF059669), width: 1.6),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0E059669),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                decoration: BoxDecoration(
                  color: const Color(0xFF059669),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.airline_seat_recline_normal_rounded,
                      size: 13,
                      color: Colors.white,
                    ),
                    SizedBox(width: 4),
                    Text(
                      'SPOT 1 • BOARDING',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isFull ? const Color(0xFFFEE2E2) : const Color(0xFFD1FAE5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '$passengerCount / $maxCapacity Seats',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    color: isFull ? AppColors.errorCrimson : const Color(0xFF065F46),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Stationed at $terminalName',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: AppColors.darkSlate,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '$passengerCount / $maxCapacity seats filled. Boarding in progress.',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: maxCapacity > 0 ? (passengerCount / maxCapacity).clamp(0.0, 1.0) : 0,
              minHeight: 5,
              backgroundColor: const Color(0xFFD1FAE5),
              valueColor: AlwaysStoppedAnimation<Color>(
                isFull ? AppColors.errorCrimson : const Color(0xFF059669),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 1. SUNLIGHT-READABLE DUTY HUD & OVERSIZED METRICS
  // ===========================================================================
  Widget _buildSunlightHUD({
    required String vehicleId,
    required String plate,
    required bool isEnRoute,
    required bool isAtSpot1,
    required bool isInQueue,
    required int queueSlot,
    required bool isStandby,
    required bool isQueueLocked,
    required String terminalName,
    required int speed,
    required int passengers,
    required int maxCapacity,
  }) {
    final bool isFull = passengers >= maxCapacity;

    Color hudBg = isEnRoute ? const Color(0xFF059669) : Colors.white;
    Color hudBorder = isEnRoute
        ? const Color(0xFF059669)
        : (isAtSpot1
            ? const Color(0xFF059669)
            : (isInQueue ? const Color(0xFF2563EB) : AppColors.borderSubtle));
    Color hudTextColor = isEnRoute ? Colors.white : AppColors.darkSlate;
    Color hudSubColor = isEnRoute ? Colors.white.withOpacity(0.9) : AppColors.textMuted;
    IconData hudIcon = Icons.sensors_off_rounded;
    String hudTitle = 'STANDBY';
    String hudSub = 'Tap to activate live GPS broadcasting';

    if (isEnRoute) {
      hudIcon = Icons.sensors_rounded;
      hudTitle = 'BIYAHE • ACTIVE';
      hudSub = 'Broadcasting live coordinates to passengers';
    } else if (isAtSpot1) {
      hudIcon = Icons.lock_clock_rounded;
      hudTitle = 'BAY SPOT 1 • BOARDING';
      hudSub = 'Hidden from passengers • Awaiting dispatcher departure signal';
    } else if (isInQueue) {
      hudIcon = Icons.lock_rounded;
      hudTitle = 'ON-DECK QUEUE • SLOT #$queueSlot';
      hudSub = 'In terminal line-up • Locked until dispatched';
    } else if (isStandby) {
      hudIcon = Icons.local_parking_rounded;
      hudTitle = 'STANDBY HOLDING POOL';
      hudSub = 'Staged at $terminalName • Awaiting dispatch call';
    }

    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _isTogglingStatus
                ? null
                : () {
                    if (isQueueLocked && !isEnRoute) {
                      HapticFeedback.mediumImpact();
                      _showSnackbar(
                        isAtSpot1
                            ? 'You are in the Loading Bay (Spot 1). Your vehicle is hidden from passengers until the dispatcher confirms departure.'
                            : 'You are in the terminal line-up. Only the terminal dispatcher can dispatch your biyahe.',
                        isError: true,
                      );
                      return;
                    }
                    _toggleDutyStatus(
                      vehicleId: vehicleId,
                      currentEnRoute: isEnRoute,
                      isQueueLocked: isQueueLocked,
                    );
                  },
            borderRadius: BorderRadius.circular(16),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              decoration: BoxDecoration(
                color: hudBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: hudBorder,
                  width: isAtSpot1 && !isEnRoute ? 2.0 : 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: isEnRoute
                        ? const Color(0xFF059669).withOpacity(0.3)
                        : Colors.black.withOpacity(0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: isEnRoute
                          ? Colors.white.withOpacity(0.2)
                          : (isAtSpot1
                              ? const Color(0xFFECFDF5)
                              : AppColors.backgroundSlate),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      hudIcon,
                      color: isEnRoute
                          ? Colors.white
                          : (isAtSpot1
                              ? const Color(0xFF059669)
                              : (isInQueue ? const Color(0xFF2563EB) : AppColors.textMuted)),
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                hudTitle,
                                style: TextStyle(
                                  fontSize: 16.5,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.3,
                                  color: hudTextColor,
                                ),
                              ),
                            ),
                            if (isQueueLocked && !isEnRoute) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFEE2E2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'LOCKED • HIDDEN ON MAP',
                                  style: TextStyle(
                                    fontSize: 8,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF991B1B),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hudSub,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: hudSubColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    isQueueLocked && !isEnRoute
                        ? Icons.lock_outline_rounded
                        : Icons.touch_app_rounded,
                    color: isEnRoute ? Colors.white70 : AppColors.textMuted,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),

        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 14,
                  horizontal: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: Column(
                  children: [
                    const Text(
                      'LIVE SPEED',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textMuted,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '$speed',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          color: AppColors.primaryNavy,
                          height: 1.0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'KM / H',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),

            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 14,
                  horizontal: 12,
                ),
                decoration: BoxDecoration(
                  color: isFull ? const Color(0xFFFEF2F2) : Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isFull
                        ? AppColors.errorCrimson.withOpacity(0.4)
                        : AppColors.borderSubtle,
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      'PASSENGERS',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        color: isFull
                            ? AppColors.errorCrimson
                            : AppColors.textMuted,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '$passengers',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          color: isFull
                              ? AppColors.errorCrimson
                              : const Color(0xFF059669),
                          height: 1.0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '/ $maxCapacity SEATS',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: isFull
                            ? AppColors.errorCrimson
                            : AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ===========================================================================
  // ACTIVE BIYAHE COMPLETION BANNER
  // ===========================================================================
  Widget _buildActiveTripActionBanner({
    required String vehicleId,
    required String routeId,
    required int passengerCount,
    required int maxCapacity,
  }) {
    final cleanRoute = routeId.replaceAll('ROUTE_', '').replaceAll('_', ' ');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF86EFAC), width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 2.5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFDCFCE7),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: const Text(
                  'DISPATCHED • BIYAHE IN PROGRESS',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF047857),
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              Text(
                '$passengerCount / $maxCapacity Onboard',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF047857),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Route: $cleanRoute',
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: AppColors.darkSlate,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'Finished dropping off passengers? Tap below to conclude this trip, reset passenger count to 0, and return to Standby.',
            style: TextStyle(
              fontSize: 11,
              color: AppColors.textMuted,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.check_circle_rounded, size: 17),
              label: const Text(
                'TAPUSIN ANG BIYAHE (RESET OCCUPANCY)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF059669),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                elevation: 0,
              ),
              onPressed: () => _confirmAndCompleteBiyahe(vehicleId),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // ACTIVE ALARM CARD
  // ===========================================================================
  Widget _buildActiveAlarmCard(
    String vehicleId,
    String routeId,
    Map<String, dynamic> alertData,
  ) {
    final title = alertData['title'] ?? 'DISPATCH CALL';
    final message =
        alertData['message'] ?? 'Robinsons Terminal is calling your unit!';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2563EB), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.notifications_active_rounded,
                color: Color(0xFF2563EB),
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: Color(0xFF1E40AF),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            message,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF1E3A8A),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                elevation: 0,
              ),
              onPressed: () async {
                await _stopAlarm();
                final isRobinsonsCall =
                    alertData['type'] == 'CALL_TO_ROBINSONS';
                final isGuinsangan =
                    RouteProcesses.of(routeId)?.hasApproachLeg ?? false;

                await FirebaseFirestore.instance
                    .collection('vehicles_live')
                    .doc(vehicleId)
                    .update({
                      'driver_alert.is_active': false,
                      'driver_alert.acknowledged_at':
                          FieldValue.serverTimestamp(),
                      'current_status': 'EN_ROUTE',
                      'visible_to_commuters': true,
                      if (isRobinsonsCall && isGuinsangan)
                        'transit_tag': 'Arriving to Robinsons',
                      'updated_at': FieldValue.serverTimestamp(),
                    });
              },
              child: const Text(
                'DISMISS & BROADCAST STATUS',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 2. "AM I NEXT?" QUEUE OBSERVER & COLLAPSIBLE LINEUP
  // ===========================================================================
  Widget _buildRouteQueueObserver({
    required Map<String, dynamic>? activeQueueDoc,
    required String vehicleId,
    required String plate,
    required String routeId,
    required bool isAtSpot1,
    required int queueIndex,
    required int standbyIndex,
    List<Map<String, dynamic>> routeQueueDocs = const [],
  }) {
    if (activeQueueDoc == null) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: const Row(
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 16,
              color: AppColors.textMuted,
            ),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'No active dispatch queue found. Scan your pass when you reach the terminal.',
                style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
              ),
            ),
          ],
        ),
      );
    }

    final rawTerm = (activeQueueDoc['terminal_name'] ??
            activeQueueDoc['terminal_id'] ??
            'Terminal')
        .toString();
    final terminalName = rawTerm.contains('ROBINSON')
        ? 'Robinsons Terminal'
        : (rawTerm.contains('DALIPE')
            ? 'Dalipe Terminal'
            : rawTerm.replaceAll('TERM_', '').replaceAll('_', ' '));

    final proc = RouteProcesses.of(routeId);
    final bool connected =
        (proc?.isTwoGroupRobinsons ?? false) && routeQueueDocs.length > 1;
    final List<Map<String, dynamic>> lineupDocs = connected
        ? ([...routeQueueDocs]
          ..sort((a, b) => _terminalOrder(a).compareTo(_terminalOrder(b))))
        : [activeQueueDoc];

    final bool isInQueue = queueIndex != -1;
    final bool isStandby = standbyIndex != -1;

    Color heroBg = Colors.white;
    Color heroAccent = AppColors.primaryNavy;
    String heroTitle = 'OUTSIDE TERMINAL QUEUE';
    String heroSub =
        'Scan check-in pass at the terminal gate to enter the line-up.';
    IconData heroIcon = Icons.location_off_rounded;

    if (isAtSpot1) {
      heroBg = const Color(0xFFF0FDF4);
      heroAccent = const Color(0xFF059669);
      heroTitle = 'SPOT 1 • BOARDING PASSENGERS';
      heroSub = 'Occupying terminal bay. Hidden on map until dispatcher confirms departure.';
      heroIcon = Icons.airline_seat_recline_normal_rounded;
    } else if (isInQueue) {
      heroBg = const Color(0xFFEFF6FF);
      heroAccent = const Color(0xFF2563EB);
      heroTitle = queueIndex == 0
          ? '#1 NEXT TO BOARD BAY'
          : '#${queueIndex + 1} IN ON-DECK QUEUE';
      heroSub = queueIndex == 0
          ? 'Prepare vehicle. Pull into Spot 1 as soon as bay departs.'
          : 'Hold position in queue. Advances forward automatically.';
      heroIcon = Icons.hourglass_top_rounded;
    } else if (isStandby) {
      heroBg = const Color(0xFFFFFBEB);
      heroAccent = const Color(0xFFD97706);
      heroTitle = 'HOLDING AT DALIPE STANDBY';
      heroSub =
          'Awaiting Robinsons dispatch call. Do not depart until notified.';
      heroIcon = Icons.local_parking_rounded;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: heroBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: heroAccent.withOpacity(0.35),
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: heroAccent.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(heroIcon, color: heroAccent, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      heroTitle,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.3,
                        color: heroAccent,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      heroSub,
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: AppColors.darkSlate,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            collapsedBackgroundColor: Colors.white,
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: AppColors.borderSubtle),
            ),
            collapsedShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: AppColors.borderSubtle),
            ),
            title: Text(
              connected
                  ? 'Your Group Line-Up (Dalipe + Robinsons)'
                  : 'Terminal Line-Up: $terminalName',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.bold,
                color: AppColors.darkSlate,
              ),
            ),
            children: [
              StreamBuilder<RotationConfig>(
                stream: (connected && proc != null && proc.hasRotation)
                    ? _rotationStream(proc)
                    : null,
                builder: (context, rotSnap) {
                  final cfg = rotSnap.data;
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Divider(
                          height: 14,
                          color: AppColors.borderSubtle,
                        ),
                        if (connected && cfg != null) ...[
                          _buildGroupFlowSummary(
                            cfg: cfg,
                            docs: lineupDocs,
                            vehicleId: vehicleId,
                            plate: plate,
                          ),
                          const SizedBox(height: 12),
                        ],
                        for (final doc in lineupDocs) ...[
                          ..._buildLineupStages(
                            doc: doc,
                            vehicleId: vehicleId,
                            plate: plate,
                            isAtSpot1: isAtSpot1,
                            cfg: cfg,
                            showTerminalHeader: connected,
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Finds every queue doc of this route the SAME way the dispatcher does:
  /// by document id ("{terminal}_{routeSuffix}"), and also by route_id for
  /// docs that were created with a different id. Matching on the route_id
  /// field alone missed docs that have no route_id or a differently written
  /// one, which is why the Robinsons line-up and Dalipe standby feed never
  /// showed up for drivers.
  List<Map<String, dynamic>> _routeQueueDocs(
      List<QueryDocumentSnapshot> docs, String routeId) {
    final wanted = routeId.trim().toUpperCase();
    final suffix = wanted.replaceFirst('ROUTE_', '');
    final proc = RouteProcesses.of(routeId);
    final ids = <String>{
      'TERM_DALIPE_1_$suffix',
      'TERM_ROBINSONS_$suffix',
      if (proc != null)
        for (final t in proc.boardingTerminals) '${t}_$suffix',
    };
    final out = <Map<String, dynamic>>[];
    for (final d in docs) {
      final m = d.data() as Map<String, dynamic>;
      final byRoute =
          (m['route_id'] ?? '').toString().trim().toUpperCase() == wanted;
      if (ids.contains(d.id) || byRoute) {
        out.add({...m, '_doc_id': d.id});
      }
    }
    return out;
  }

  /// Terminal identity of a queue doc: its terminal_id field, else its doc id.
  String _termKey(Map<String, dynamic> d) {
    final t = (d['terminal_id'] ?? '').toString().trim();
    return (t.isNotEmpty ? t : (d['_doc_id'] ?? '').toString()).toUpperCase();
  }

  /// Dalipe first, Robinsons last, so the driver reads the lineups in the
  /// order a unit travels through them.
  int _terminalOrder(Map<String, dynamic> d) {
    return _termKey(d).contains('ROBINSON') ? 1 : 0;
  }

  String _terminalLabel(Map<String, dynamic> d) {
    final raw = (d['terminal_name'] ?? _termKey(d)).toString().toUpperCase();
    return raw.contains('ROBINSON')
        ? 'Robinsons Terminal'
        : (raw.contains('DALIPE')
            ? 'Dalipe Terminal'
            : raw.replaceAll('TERM_', '').replaceAll('_', ' '));
  }

  Widget _buildTerminalHeader(Map<String, dynamic> d) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.backgroundSlate,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _terminalLabel(d).toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          color: AppColors.darkSlate,
        ),
      ),
    );
  }

  List<Widget> _buildLineupStages({
    required Map<String, dynamic> doc,
    required String vehicleId,
    required String plate,
    required bool isAtSpot1,
    RotationConfig? cfg,
    bool showTerminalHeader = false,
  }) {
    // Which group is allowed in each stage of this terminal:
    //   Dalipe Stage 1+2   -> Direct group
    //   Dalipe Stage 3     -> Robinsons group (standby pool)
    //   Robinsons Stage 1+2-> Robinsons group
    final isRobinsonsDoc = _termKey(doc).contains('ROBINSON');
    final directKey = cfg?.directGroupKey();
    String? viaKey;
    if (cfg != null) {
      for (final g in cfg.groups.values) {
        if (!g.isDirect) viaKey = g.key;
      }
    }
    final String? bayGroup = isRobinsonsDoc ? viaKey : directKey;
    final String? standbyGroup = viaKey;
    String suffix(String? k) => (cfg != null && k != null && cfg.groups[k] != null)
        ? '  •  ${_groupName(cfg, k)}'
        : '';

    final activeLoading =
        (doc['active_loading_vehicle'] ?? 'None').toString();
    final queuedList = ((doc['queued_vehicles'] as List<dynamic>?) ?? [])
        .map((e) => e.toString())
        .toList();
    final stagedList =
        ((doc['standby_staged_vehicles'] as List<dynamic>?) ?? [])
            .map((e) => e.toString())
            .toList();
    final selfAtSpot1 =
        isAtSpot1 && _isVehicleMatch(activeLoading, vehicleId, plate);

    // A driver only sees their OWN group. If the rotation list does not know
    // this unit yet, nothing is hidden.
    final String? myGroup = cfg?.groupKeyOf(vehicleId);
    bool mine(String u) =>
        myGroup == null ||
        cfg == null ||
        cfg.groupKeyOf(u) == myGroup ||
        _isVehicleMatch(u, vehicleId, plate);

    final bayHasMine = (activeLoading.isNotEmpty &&
            activeLoading != 'None' &&
            mine(activeLoading)) ||
        queuedList.any(mine);
    final standbyHasMine = stagedList.any(mine);

    final showBay =
        myGroup == null || bayGroup == myGroup || bayHasMine;
    final showStandby = (myGroup == null || standbyGroup == myGroup || standbyHasMine) &&
        (stagedList.isNotEmpty || _termKey(doc).contains('DALIPE'));
    if (!showBay && !showStandby) return const [];

    final activeIsOther = activeLoading.isNotEmpty &&
        activeLoading != 'None' &&
        !mine(activeLoading);

    return [
      if (showTerminalHeader) _buildTerminalHeader(doc),
      if (showBay) ...[
        _buildStageHeader(
          'Stage 1 • Loading Bay (Spot 1)${suffix(bayGroup)}',
          const Color(0xFF059669),
        ),
        const SizedBox(height: 6),
        if (activeIsOther)
          _buildEmptyNotice('Bay is in use by another group.')
        else
          _buildSpot1Box(activeLoading,
              isSelf: selfAtSpot1, cfg: cfg, expectedGroup: bayGroup),
        const SizedBox(height: 12),
        _buildStageHeader(
          'Stage 2 • On-Deck Queue (${queuedList.where(mine).length})${suffix(bayGroup)}',
          const Color(0xFF2563EB),
        ),
        const SizedBox(height: 6),
        if (!queuedList.any(mine))
          _buildEmptyNotice('No units waiting in on-deck line.')
        else
          ...queuedList.asMap().entries.where((e) => mine(e.value)).map((entry) {
            final pos = entry.key + 1; // real position in the terminal line
            final unit = entry.value;
            return _buildQueueItem(
              number: '$pos',
              vehicleId: unit,
              subtitle: pos == 1 ? 'Next to pull into bay' : 'Waiting in line',
              isSelf: _isVehicleMatch(unit, vehicleId, plate),
              badgeColor: const Color(0xFF2563EB),
              cfg: cfg,
              expectedGroup: bayGroup,
            );
          }),
      ],
      if (showStandby) ...[
        const SizedBox(height: 12),
        _buildStageHeader(
          'Stage 3 • Dalipe Standby Feed (${stagedList.where(mine).length})${suffix(standbyGroup)}',
          const Color(0xFFD97706),
        ),
        const SizedBox(height: 6),
        if (!stagedList.any(mine))
          _buildEmptyNotice('No units holding in standby.')
        else
          ...stagedList.asMap().entries.where((e) => mine(e.value)).map((entry) {
            final pos = entry.key + 1;
            final unit = entry.value;
            return _buildQueueItem(
              number: 'H$pos',
              vehicleId: unit,
              subtitle: 'Awaiting call to Robinsons',
              isSelf: _isVehicleMatch(unit, vehicleId, plate),
              badgeColor: const Color(0xFFD97706),
              cfg: cfg,
              expectedGroup: standbyGroup,
            );
          }),
      ],
      const SizedBox(height: 14),
    ];
  }

  Widget _buildStageHeader(String title, Color color) {
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          title,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildSpot1Box(String vehicleId,
      {required bool isSelf, RotationConfig? cfg, String? expectedGroup}) {
    final isEmpty = vehicleId == 'None' || vehicleId.isEmpty;
    if (isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: const Text(
          'Bay is Currently Empty',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 11.5,
            color: AppColors.textMuted,
          ),
        ),
      );
    }

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('vehicles_live')
          .doc(vehicleId)
          .snapshots(),
      builder: (context, snapshot) {
        final vData = snapshot.data?.data() as Map<String, dynamic>?;
        final plate = (vData?['plate_number'] ?? vehicleId).toString();
        final jeepName = (vData?['vehicle_name'] ?? plate).toString();
        final group = (vData?['group_assignment'] ?? '').toString();

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            color: isSelf ? const Color(0xFFF0FDF4) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelf ? const Color(0xFF86EFAC) : AppColors.borderSubtle,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.directions_bus_rounded,
                size: 16,
                color: isSelf ? const Color(0xFF059669) : AppColors.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  jeepName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    color: isSelf
                        ? const Color(0xFF059669)
                        : AppColors.darkSlate,
                  ),
                ),
              ),
              ..._buildGroupTags(cfg, vehicleId, group, expectedGroup),
              if (isSelf)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF059669),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'YOU (BOARDING)',
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                )
              else
                _buildLicenseBadge(plate),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQueueItem({
    required String number,
    required String vehicleId,
    required String subtitle,
    required bool isSelf,
    required Color badgeColor,
    RotationConfig? cfg,
    String? expectedGroup,
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
        final group = (vData?['group_assignment'] ?? '').toString();

        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: isSelf ? badgeColor.withOpacity(0.06) : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelf
                  ? badgeColor.withOpacity(0.35)
                  : AppColors.borderSubtle,
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: badgeColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  number,
                  style: TextStyle(
                    fontSize: 10,
                    color: badgeColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  jeepName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: AppColors.darkSlate,
                  ),
                ),
              ),
              ..._buildGroupTags(cfg, vehicleId, group, expectedGroup),
              if (isSelf)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'YOU',
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                )
              else
                _buildLicenseBadge(plate),
            ],
          ),
        );
      },
    );
  }

  // ── group helpers: the rotation list is the single source of truth ───────

  /// "Group 1 Direct" / "Group 2 via Robinsons".
  String _groupName(RotationConfig cfg, String key) {
    final g = cfg.groups[key];
    final base = groupLabel(key);
    if (g == null) return base;
    return g.isDirect ? '$base Direct' : '$base via Robinsons';
  }

  Color _groupColor(RotationConfig? cfg, String? key) {
    if (cfg == null || key == null) return const Color(0xFF64748B);
    return (cfg.groups[key]?.isDirect ?? false)
        ? const Color(0xFF0D9488) // Direct = teal everywhere
        : const Color(0xFF7C3AED); // Via Robinsons = purple everywhere
  }

  Widget _chip(String text, Color c, {bool solid = false}) => Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        decoration: BoxDecoration(
          color: solid ? c : c.withOpacity(0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 8.5,
            fontWeight: FontWeight.w900,
            color: solid ? Colors.white : c,
          ),
        ),
      );

  /// Group chip (+ master-list number) for a unit. Flags a unit that is in a
  /// line its group does not use (e.g. a Robinsons-group unit in Dalipe's
  /// direct bay).
  List<Widget> _buildGroupTags(RotationConfig? cfg, String unitId,
      String fallbackGroup, String? expectedGroup) {
    final key = cfg?.groupKeyOf(unitId);
    if (cfg != null && key != null) {
      final no = cfg.numberOf(unitId);
      final c = _groupColor(cfg, key);
      final label = (cfg.groups[key]?.isDirect ?? false) ? 'DIRECT' : 'ROBINSONS';
      return [
        _chip('G${groupLabel(key).replaceAll('Group ', '')} $label${no != null ? ' #$no' : ''}', c),
        if (expectedGroup != null && expectedGroup != key)
          _chip('WRONG LINE', const Color(0xFFDC2626), solid: true),
      ];
    }
    if (fallbackGroup.isNotEmpty) {
      return [_chip(fallbackGroup.toUpperCase(), const Color(0xFF64748B))];
    }
    return const [];
  }

  /// One row per group showing where its units are across BOTH terminals, so
  /// Stage 1/2/3 read as one flow: Dalipe standby -> Robinsons bay.
  Widget _buildGroupFlowSummary({
    required RotationConfig cfg,
    required List<Map<String, dynamic>> docs,
    required String vehicleId,
    required String plate,
  }) {
    final myKey = cfg.groupKeyOf(vehicleId);
    final rows = <Widget>[];
    for (final g in cfg.groups.values) {
      if (myKey != null && g.key != myKey) continue; // own group only
      final parts = <String>[];
      for (final d in docs) {
        final isRob = _termKey(d).contains('ROBINSON');
        final active = (d['active_loading_vehicle'] ?? 'None').toString();
        final bay = <String>[
          if (active.isNotEmpty && active != 'None') active,
          ...((d['queued_vehicles'] as List<dynamic>?) ?? [])
              .map((e) => e.toString()),
        ].where((u) => cfg.groupKeyOf(u) == g.key).length;
        final stby = ((d['standby_staged_vehicles'] as List<dynamic>?) ?? [])
            .map((e) => e.toString())
            .where((u) => cfg.groupKeyOf(u) == g.key)
            .length;
        if (bay > 0) parts.add('${isRob ? 'Robinsons' : 'Dalipe'} line-up: $bay');
        if (stby > 0) parts.add('Dalipe standby: $stby');
      }
      final mine = g.key == myKey;
      final c = _groupColor(cfg, g.key);
      rows.add(Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: mine ? c.withOpacity(0.08) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: mine ? c.withOpacity(0.4) : AppColors.borderSubtle),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _groupName(cfg, g.key) + (mine ? '  (YOUR GROUP)' : ''),
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w900,
                        color: c),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    g.isDirect
                        ? 'Flow: Dalipe Spot 1 → On-Deck → departs Direct'
                        : 'Flow: Dalipe Standby → called → Robinsons Spot 1 → On-Deck',
                    style: const TextStyle(
                        fontSize: 10, color: AppColors.textMuted),
                  ),
                  Text(
                    parts.isEmpty ? 'No units in line' : parts.join('  •  '),
                    style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.darkSlate),
                  ),
                ],
              ),
            ),
          ],
        ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  Widget _buildEmptyNotice(String msg) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        msg,
        style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted),
      ),
    );
  }

  Widget _buildUnassignedVehicleState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.directions_bus_outlined,
              size: 48,
              color: AppColors.textMuted.withOpacity(0.5),
            ),
            const SizedBox(height: 14),
            const Text(
              'No Vehicle Assigned',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: AppColors.darkSlate,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Ask your fleet operator to assign a jeepney to your driver account to begin shifts.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLicenseBadge(String plate) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        plate.replaceAll('_', ' ').toUpperCase(),
        style: const TextStyle(
          fontFamily: 'monospace',
          fontWeight: FontWeight.w700,
          fontSize: 10.5,
          color: Color(0xFF334155),
        ),
      ),
    );
  }
}