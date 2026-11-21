import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/config/route_process_config.dart';
import 'rotation_repository.dart';

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
                    _confirmAndSwitchDirectGroup(target, other);
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

  // ── Group switch guard ────────────────────────────────────────────────────
  /// Called when the coop taps the swap-groups popup for a twoGroupRobinsons
  /// route. Reads every Dalipe queue document for this route. If any vehicles
  /// are still in the queue it blocks the switch and offers to clear them first;
  /// otherwise it shows a confirmation dialog before proceeding.
  Future<void> _confirmAndSwitchDirectGroup(
      String targetGroupKey, String otherGroupKey) async {
    if (!mounted) return;

    final p = RouteProcesses.of(widget.routeId);
    if (p == null) return;

    // ── 1. Read all Dalipe queue docs for this route ──────────────────────
    final db = FirebaseFirestore.instance;
    final suffix = p.suffix; // e.g. "GUINSANGAN"
    final dalipeDocIds = [
      'TERM_DALIPE_1_$suffix',
      'TERM_DALIPE_2_$suffix',
    ];

    final snaps = await Future.wait(
      dalipeDocIds.map((id) => db.collection('terminals_queue').doc(id).get()),
    );

    // Collect all occupied vehicles across both Dalipe docs.
    final Map<String, List<String>> queuedPerDoc = {};
    final Map<String, String?> activePerDoc = {};
    bool hasBlockingUnits = false;

    for (int i = 0; i < snaps.length; i++) {
      final data = snaps[i].data();
      if (data == null) continue;
      final docId = dalipeDocIds[i];
      final active = (data['active_loading_vehicle'] ?? '').toString().trim();
      final queued = (data['queued_vehicles'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList();
      final standby = (data['standby_staged_vehicles'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList();
      final allInDoc = [
        if (active.isNotEmpty && active != 'None') active,
        ...queued,
        ...standby,
      ];
      if (allInDoc.isNotEmpty) hasBlockingUnits = true;
      queuedPerDoc[docId] = allInDoc;
      activePerDoc[docId] = active.isNotEmpty && active != 'None' ? active : null;
    }

    if (!mounted) return;

    final targetLabel = groupLabel(targetGroupKey);
    final otherLabel = groupLabel(otherGroupKey);

    // ── 2a. Queue is occupied → block with clear-or-cancel dialog ─────────
    if (hasBlockingUnits) {
      final totalCount =
          queuedPerDoc.values.fold<int>(0, (s, l) => s + l.length);
      final proceed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Row(children: [
            const Icon(Icons.warning_amber_rounded,
                color: Color(0xFFD97706), size: 22),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Cannot Switch Groups',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
            ),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'There ${totalCount == 1 ? 'is' : 'are'} $totalCount jeepney${totalCount == 1 ? '' : 's'} '
                'currently in the terminal queue.',
                style: const TextStyle(fontSize: 13.5),
              ),
              const SizedBox(height: 8),
              const Text(
                'The group rotation cannot be switched while units are still '
                'waiting in the terminal. You can remove all queued units first, '
                'then the switch will proceed.',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.delete_sweep_rounded, size: 16),
              label: const Text('Remove All & Switch',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.errorCrimson,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;

      // Clear all Dalipe queue docs atomically.
      final batch = db.batch();
      for (final docId in dalipeDocIds) {
        batch.set(
          db.collection('terminals_queue').doc(docId),
          {
            'active_loading_vehicle': 'None',
            'queued_vehicles': [],
            'standby_staged_vehicles': [],
            'boarding_started_at': FieldValue.delete(),
            'updated_at': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      }
      // Also reset vehicle statuses for every cleared unit.
      for (final ids in queuedPerDoc.values) {
        for (final vid in ids) {
          batch.update(db.collection('vehicles_live').doc(vid), {
            'current_status': 'STANDBY',
            'is_dispatched': false,
            'staged_at_dalipe': false,
            'called_by_robinsons': false,
            'updated_at': FieldValue.serverTimestamp(),
          });
        }
      }
      await batch.commit();
    } else {
      // ── 2b. Queue is clear → ask for confirmation ───────────────────────
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Row(children: [
            const Icon(Icons.swap_horiz_rounded,
                color: AppColors.primaryNavy, size: 22),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Switch Group Rotation?',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
            ),
          ]),
          content: Text(
            '$targetLabel will become Dalipe Direct and $otherLabel will '
            'be routed via Robinsons. All affected vehicle assignments will '
            'update automatically.',
            style: const TextStyle(fontSize: 13.5),
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
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Yes, Switch',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    // ── 3. Run the actual group switch ────────────────────────────────────
    await _run(
      () => RotationRepo.setDirectGroup(
          widget.coopId, widget.routeId, widget.actorName, targetGroupKey),
      '$targetLabel is now Dalipe Direct; $otherLabel goes via Robinsons.',
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
