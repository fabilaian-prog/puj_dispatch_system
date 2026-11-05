import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../utils/app_colors.dart';
import '../../utils/fare_config.dart';

/// Super admin tab for editing the fare criteria.
class FareSettingsTab extends StatefulWidget {
  const FareSettingsTab({super.key});

  @override
  State<FareSettingsTab> createState() => _FareSettingsTabState();
}

class _FareSettingsTabState extends State<FareSettingsTab> {
  final _baseCtrl = TextEditingController();
  final _baseDiscCtrl = TextEditingController();
  final _baseKmCtrl = TextEditingController();
  final _perKmCtrl = TextEditingController();
  final _perKmDiscCtrl = TextEditingController();

  FareConfig _saved = FareConfig.defaults;
  bool _loaded = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    for (final c in [
      _baseCtrl,
      _baseDiscCtrl,
      _baseKmCtrl,
      _perKmCtrl,
      _perKmDiscCtrl
    ]) {
      c.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _baseDiscCtrl.dispose();
    _baseKmCtrl.dispose();
    _perKmCtrl.dispose();
    _perKmDiscCtrl.dispose();
    super.dispose();
  }

  String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  void _fill(FareConfig c) {
    _baseCtrl.text = _fmt(c.baseFare);
    _baseDiscCtrl.text = _fmt(c.baseFareDiscounted);
    _baseKmCtrl.text = c.baseKm.toString();
    _perKmCtrl.text = _fmt(c.perKmFare);
    _perKmDiscCtrl.text = _fmt(c.perKmFareDiscounted);
  }

  Future<void> _load() async {
    try {
      final snap = await FareConfig.docRef.get();
      _saved = FareConfig.fromMap(snap.data());
    } catch (_) {
      _saved = FareConfig.defaults;
      _error = 'Could not load saved rates. Showing defaults.';
    }
    if (!mounted) return;
    _fill(_saved);
    setState(() => _loaded = true);
  }

  /// Parses the form; returns null if any field is invalid.
  FareConfig? _draft() {
    final base = double.tryParse(_baseCtrl.text.trim());
    final baseD = double.tryParse(_baseDiscCtrl.text.trim());
    final km = int.tryParse(_baseKmCtrl.text.trim());
    final per = double.tryParse(_perKmCtrl.text.trim());
    final perD = double.tryParse(_perKmDiscCtrl.text.trim());
    if (base == null || baseD == null || km == null || per == null || perD == null) {
      return null;
    }
    if (base <= 0 || baseD <= 0 || per < 0 || perD < 0 || km < 1 || km > 50) {
      return null;
    }
    return FareConfig(
      baseFare: base,
      baseFareDiscounted: baseD,
      baseKm: km,
      perKmFare: per,
      perKmFareDiscounted: perD,
    );
  }

  bool _same(FareConfig a, FareConfig b) =>
      a.baseFare == b.baseFare &&
      a.baseFareDiscounted == b.baseFareDiscounted &&
      a.baseKm == b.baseKm &&
      a.perKmFare == b.perKmFare &&
      a.perKmFareDiscounted == b.perKmFareDiscounted;

  Future<void> _save(FareConfig next) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update fare rates?'),
        content: const Text(
            'The new rates will show to all commuters immediately. This change is logged.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Update')),
        ],
      ),
    );
    if (go != true) return;

    setState(() => _saving = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      final who = user?.email ?? user?.uid ?? 'unknown';
      final db = FirebaseFirestore.instance;
      final batch = db.batch();
      batch.set(FareConfig.docRef, {
        ...next.toMap(),
        'updated_by': who,
        'updated_at': FieldValue.serverTimestamp(),
      });
      batch.set(db.collection('fare_history').doc(), {
        'previous': _saved.toMap(),
        'new': next.toMap(),
        'changed_by': who,
        'changed_at': FieldValue.serverTimestamp(),
      });
      await batch.commit();
      _saved = next;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fare rates updated.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(String label, TextEditingController c,
      {String? prefix, String? suffix, bool integer = false}) {
    return TextField(
      controller: c,
      keyboardType: TextInputType.numberWithOptions(decimal: !integer),
      inputFormatters: [
        FilteringTextInputFormatter.allow(
            integer ? RegExp(r'[0-9]') : RegExp(r'[0-9.]')),
      ],
      decoration: InputDecoration(
        labelText: label,
        prefixText: prefix,
        suffixText: suffix,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        isDense: true,
      ),
    );
  }

  Widget _card({required String title, required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppColors.darkSlate)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _row2(Widget a, Widget b) => Row(children: [
        Expanded(child: a),
        const SizedBox(width: 12),
        Expanded(child: b),
      ]);

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());

    final draft = _draft();
    final changed = draft != null && !_same(draft, _saved);
    final warn = draft != null &&
        (draft.baseFareDiscounted > draft.baseFare ||
            draft.perKmFareDiscounted > draft.perKmFare);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
            _card(
              title: 'Regular fare',
              child: _row2(
                _field('Base fare', _baseCtrl, prefix: '₱ '),
                _field('Per extra km', _perKmCtrl, prefix: '₱ '),
              ),
            ),
            _card(
              title: 'Student / PWD / Senior fare',
              child: _row2(
                _field('Base fare', _baseDiscCtrl, prefix: '₱ '),
                _field('Per extra km', _perKmDiscCtrl, prefix: '₱ '),
              ),
            ),
            _card(
              title: 'Base distance',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 220,
                    child: _field('Base fare covers first',
                        _baseKmCtrl,
                        suffix: 'km', integer: true),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Fares are rounded up to the next whole peso. Partial km count as a full km.',
                    style:
                        TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
            _card(
              title: 'Preview',
              child: draft == null
                  ? const Text(
                      'Enter valid numbers (base distance 1 to 50 km).',
                      style: TextStyle(color: Colors.redAccent))
                  : Table(
                      columnWidths: const {
                        0: FlexColumnWidth(1),
                        1: FlexColumnWidth(1),
                        2: FlexColumnWidth(1),
                      },
                      children: [
                        const TableRow(children: [
                          Padding(
                              padding: EdgeInsets.only(bottom: 6),
                              child: Text('Distance',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w700))),
                          Text('Regular',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          Text('Discounted',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                        ]),
                        for (final km in [1, 4, 5, 10, 20, 30])
                          TableRow(children: [
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 3),
                                child: Text('$km km')),
                            Text('₱${draft.regularForKm(km).round()}'),
                            Text('₱${draft.discountedForKm(km).round()}'),
                          ]),
                      ],
                    ),
            ),
            if (warn)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text(
                  'Heads up: a discounted rate is higher than the regular rate.',
                  style: TextStyle(color: Colors.orange),
                ),
              ),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _saving
                      ? null
                      : () => setState(() => _fill(FareConfig.defaults)),
                  icon: const Icon(Icons.restore_rounded),
                  label: const Text('Load LTFRB defaults'),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: _saving ? null : () => setState(() => _fill(_saved)),
                  child: const Text('Discard changes'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: (_saving || !changed) ? null : () => _save(draft!),
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_rounded),
                  label: const Text('Save'),
                ),
              ],
            ),
            const SizedBox(height: 22),
            _history(),
          ],
        ),
      ),
    );
  }

  Widget _history() {
    return _card(
      title: 'Recent changes',
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('fare_history')
            .orderBy('changed_at', descending: true)
            .limit(8)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const Text('Could not load history.',
                style: TextStyle(color: AppColors.textMuted));
          }
          final docs = snap.data?.docs ?? const [];
          if (docs.isEmpty) {
            return const Text('No changes recorded yet.',
                style: TextStyle(color: AppColors.textMuted));
          }
          return Column(
            children: [
              for (final d in docs)
                Builder(builder: (_) {
                  final m = d.data();
                  final n = (m['new'] as Map?) ?? const {};
                  final ts = (m['changed_at'] as Timestamp?)?.toDate();
                  final when = ts == null
                      ? '...'
                      : '${ts.year}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')} '
                          '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                        'Regular ₱${n['base_fare']} + ₱${n['per_km_fare']}/km, '
                        'Discounted ₱${n['base_fare_discounted']} + ₱${n['per_km_fare_discounted']}/km '
                        '(first ${n['base_km']} km)'),
                    subtitle: Text('${m['changed_by'] ?? 'unknown'}  •  $when'),
                  );
                }),
            ],
          );
        },
      ),
    );
  }
}