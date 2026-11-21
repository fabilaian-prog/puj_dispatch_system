import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../utils/app_colors.dart';
import 'rotation_master_list.dart';
import 'route_process_config.dart';

// =============================================================================
// Dispatcher-side cards for the non-two-group processes.
//   ScheduleBoardCard  -> Dao (boards at Robinsons) and Aniniy (boards at Dalipe)
//   DispatchTimerCard  -> Sibalom (dispatch when full, or when the timer ends)
// =============================================================================

String _two(int n) => n.toString().padLeft(2, '0');

/// Read-only list of today's schedule slots with the unit assigned to each.
class ScheduleBoardCard extends StatefulWidget {
  final RouteProcessConfig process;
  final RotationConfig rotation;

  /// Units currently checked into this terminal (Spot 1 + on-deck).
  final Set<String> presentUnits;

  const ScheduleBoardCard({
    super.key,
    required this.process,
    required this.rotation,
    required this.presentUnits,
  });

  @override
  State<ScheduleBoardCard> createState() => _ScheduleBoardCardState();
}

class _ScheduleBoardCardState extends State<ScheduleBoardCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.process;
    final cfg = widget.rotation;
    final gKey = cfg.runningGroupKey;
    final order = cfg.groups[gKey]?.order ?? const <String>[];
    final slots = cfg.schedule[gKey] ?? const <ScheduleSlot>[];
    final now = TimeOfDay.now();
    final nowMin = now.hour * 60 + now.minute;
    final boardsAtRobinsons = p.hasActiveGroupChoice;

    // First slot whose boarding time has not passed yet.
    int nextIdx = -1;
    for (int i = 0; i < slots.length; i++) {
      final m = slots[i].boardMinutes;
      if (m != null && m >= nowMin) {
        nextIdx = i;
        break;
      }
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF7C3AED).withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.schedule_rounded,
                  size: 18, color: Color(0xFF7C3AED)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  p.hasActiveGroupChoice
                      ? 'SCHEDULE • ${groupLabel(gKey).toUpperCase()} RUNNING'
                      : 'SCHEDULED DEPARTURES',
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w900,
                      color: AppColors.darkSlate),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            boardsAtRobinsons
                ? 'Units drive Dalipe → Robinsons and board here at their scheduled arrival time.'
                : 'Units depart on their scheduled time even if not full.',
            style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
          const SizedBox(height: 8),
          if (slots.isEmpty)
            const Text('The coop has not set any times yet.',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted))
          else
            for (int i = 0; i < slots.length; i++)
              _slotRow(
                  i, slots[i], i < order.length ? order[i] : null, i == nextIdx),
        ],
      ),
    );
  }

  Widget _slotRow(int i, ScheduleSlot s, String? unit, bool isNext) {
    final boardsAtRobinsons = widget.process.hasActiveGroupChoice;
    final here = unit != null && widget.presentUnits.contains(unit);
    final timeText = boardsAtRobinsons
        ? 'Board ${s.arrive.isEmpty ? '—' : s.arrive}  (left Dalipe ${s.depart})'
        : 'Departs ${s.depart}';

    final String status;
    final Color color;
    if (unit == null) {
      status = 'NO UNIT';
      color = const Color(0xFF94A3B8);
    } else if (here) {
      status = 'AT TERMINAL';
      color = const Color(0xFF059669);
    } else {
      status = 'EXPECTED';
      color = const Color(0xFFD97706);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isNext ? const Color(0xFFF5F3FF) : AppColors.backgroundSlate,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: isNext ? const Color(0xFFC4B5FD) : AppColors.borderSubtle),
      ),
      child: Row(
        children: [
          Text('#${i + 1}',
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w900,
                  color: AppColors.darkSlate)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(unit ?? 'Unassigned',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w800)),
                Text(timeText,
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.textMuted)),
              ],
            ),
          ),
          if (isNext)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Text('NEXT',
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF6D28D9))),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(status,
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    color: color)),
          ),
        ],
      ),
    );
  }
}

/// Countdown + "change timer" for first-come-first-serve routes with a
/// boarding timer (Sibalom, Belison, Patnongon, Bugasong, San Remigio,
/// Valderrama). It only reminds the dispatcher; dispatch is always manual.
class DispatchTimerCard extends StatefulWidget {
  final Map<String, dynamic> queueData;
  final int defaultMinutes;
  final String activeVehicleId;
  final Future<void> Function(int minutes) onChangeTimer;

  const DispatchTimerCard({
    super.key,
    required this.queueData,
    required this.defaultMinutes,
    required this.activeVehicleId,
    required this.onChangeTimer,
  });

  @override
  State<DispatchTimerCard> createState() => _DispatchTimerCardState();
}

class _DispatchTimerCardState extends State<DispatchTimerCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  int get _minutes =>
      (widget.queueData['dispatch_timer_minutes'] as num?)?.toInt() ??
      widget.defaultMinutes;

  Future<void> _askMinutes() async {
    final c = TextEditingController(text: '$_minutes');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Boarding timer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Minutes a unit may wait at Spot 1 before you are reminded to '
                'dispatch it, even if it is not full. You always dispatch by hand.',
                style: TextStyle(fontSize: 13)),
            const SizedBox(height: 10),
            TextField(
              controller: c,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Minutes (1 – 180)', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final n = int.tryParse(c.text.trim());
              if (n == null || n < 1 || n > 180) return;
              Navigator.pop(ctx, n);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (v != null && v != _minutes) await widget.onChangeTimer(v);
  }

  @override
  Widget build(BuildContext context) {
    final started =
        (widget.queueData['boarding_started_at'] as Timestamp?)?.toDate();
    final hasUnit =
        widget.activeVehicleId.isNotEmpty && widget.activeVehicleId != 'None';

    String countdown = '—';
    bool expired = false;
    if (hasUnit && started != null) {
      final left = started
          .add(Duration(minutes: _minutes))
          .difference(DateTime.now());
      expired = left.isNegative || left.inSeconds == 0;
      final s = left.isNegative ? 0 : left.inSeconds;
      countdown = '${_two(s ~/ 60)}:${_two(s % 60)}';
    }

    final color = expired ? const Color(0xFFDC2626) : const Color(0xFF2563EB);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.timer_outlined, color: color, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('BOARDING TIMER • DISPATCH MANUALLY',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w900,
                        color: AppColors.darkSlate)),
                const SizedBox(height: 2),
                Text(
                  hasUnit
                      ? (expired
                          ? 'Time is up. Dispatch this unit  •  timer $_minutes min'
                          : 'Spot 1 timer: $countdown left  •  timer $_minutes min')
                      : 'Timer starts when a unit takes Spot 1  •  $_minutes min',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: color),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _askMinutes,
            child: const Text('Change',
                style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}