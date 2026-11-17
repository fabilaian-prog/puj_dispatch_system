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
      _perKmDiscCtrl,
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

  FareConfig? _draft() {
    final base = double.tryParse(_baseCtrl.text.trim());
    final baseD = double.tryParse(_baseDiscCtrl.text.trim());
    final km = int.tryParse(_baseKmCtrl.text.trim());
    final per = double.tryParse(_perKmCtrl.text.trim());
    final perD = double.tryParse(_perKmDiscCtrl.text.trim());
    if (base == null ||
        baseD == null ||
        km == null ||
        per == null ||
        perD == null) return null;
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Update fare rates?',
            style: TextStyle(fontWeight: FontWeight.w800)),
        content: const Text(
            'The new rates will show to all commuters immediately. This change is logged.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.primaryNavy),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Update'),
          ),
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
        const SnackBar(
          content: Text('Fare rates updated successfully.'),
          backgroundColor: AppColors.commuterTeal,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e'),
              backgroundColor: AppColors.errorCrimson));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── Input field ────────────────────────────────────────────────────────────
  Widget _fareField(String label, TextEditingController c,
      {bool integer = false, String? suffix}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textMuted,
                letterSpacing: 0.3)),
        const SizedBox(height: 6),
        TextField(
          controller: c,
          keyboardType:
              TextInputType.numberWithOptions(decimal: !integer),
          inputFormatters: [
            FilteringTextInputFormatter.allow(
                integer ? RegExp(r'[0-9]') : RegExp(r'[0-9.]')),
          ],
          style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.darkSlate),
          decoration: InputDecoration(
            prefixText: integer ? null : '₱ ',
            prefixStyle: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textMuted),
            suffixText: suffix,
            suffixStyle: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textMuted),
            filled: true,
            fillColor: AppColors.backgroundSlate,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    const BorderSide(color: AppColors.borderSubtle)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    const BorderSide(color: AppColors.borderSubtle)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(
                    color: AppColors.primaryNavy, width: 1.8)),
          ),
        ),
      ],
    );
  }

  // ── Section card ───────────────────────────────────────────────────────────
  Widget _section({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: iconColor, size: 18),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: AppColors.darkSlate)),
                    Text(subtitle,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textMuted)),
                  ],
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18),
            child: Divider(height: 20, color: AppColors.borderSubtle),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: child,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.primaryNavy));
    }

    final draft = _draft();
    final changed = draft != null && !_same(draft, _saved);
    final warn = draft != null &&
        (draft.baseFareDiscounted > draft.baseFare ||
            draft.perKmFareDiscounted > draft.perKmFare);

    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 860;
      return wide
          ? _buildWideLayout(draft, changed, warn)
          : _buildNarrowLayout(draft, changed, warn);
    });
  }

  // ── Shared banner widgets ──────────────────────────────────────────────────

  Widget _errorBanner() => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFECACA)),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: AppColors.errorCrimson, size: 18),
            const SizedBox(width: 8),
            Expanded(
                child: Text(_error!,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.errorCrimson))),
          ],
        ),
      );

  Widget _warnBanner() => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBEB),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFDE68A)),
        ),
        child: const Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                color: Color(0xFFD97706), size: 18),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Heads up: a discounted rate is higher than the regular rate.',
                style: TextStyle(fontSize: 13, color: Color(0xFF92400E)),
              ),
            ),
          ],
        ),
      );

  Widget _actionBar(FareConfig? draft, bool changed) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: changed
                ? AppColors.primaryNavy.withValues(alpha: 0.3)
                : AppColors.borderSubtle,
          ),
        ),
        child: Row(
          children: [
            if (changed) ...[
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFFF59E0B),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              const Text('Unsaved changes',
                  style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textMuted,
                      fontWeight: FontWeight.w500)),
            ] else
              const Text('No pending changes',
                  style:
                      TextStyle(fontSize: 13, color: AppColors.textMuted)),
            const Spacer(),
            TextButton(
              onPressed: (changed && !_saving)
                  ? () => setState(() => _fill(_saved))
                  : null,
              child: const Text('Discard'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primaryNavy,
                disabledBackgroundColor: AppColors.borderSubtle,
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed:
                  (_saving || !changed) ? null : () => _save(draft!),
              icon: _saving
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save_rounded, size: 17),
              label: const Text('Save rates',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );

  // ── Wide layout: two columns ───────────────────────────────────────────────

  Widget _buildWideLayout(FareConfig? draft, bool changed, bool warn) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left column — edit panels + action bar
        Expanded(
          flex: 5,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 24, 12, 40),
            children: [
              if (_error != null) _errorBanner(),
              if (warn) _warnBanner(),
              _section(
                icon: Icons.person_rounded,
                iconColor: AppColors.primaryNavy,
                iconBg: const Color(0xFFEFF6FF),
                title: 'Regular Fare',
                subtitle: 'Standard rate for all passengers',
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _fareField('Base fare', _baseCtrl)),
                    const SizedBox(width: 14),
                    Expanded(child: _fareField('Per extra km', _perKmCtrl)),
                  ],
                ),
              ),
              _section(
                icon: Icons.school_rounded,
                iconColor: AppColors.commuterTeal,
                iconBg: AppColors.commuterTealLight,
                title: 'Discounted Fare',
                subtitle: 'Students, PWDs & Senior Citizens',
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                        child: _fareField('Base fare', _baseDiscCtrl)),
                    const SizedBox(width: 14),
                    Expanded(
                        child: _fareField('Per extra km', _perKmDiscCtrl)),
                  ],
                ),
              ),
              _section(
                icon: Icons.route_rounded,
                iconColor: const Color(0xFF7C3AED),
                iconBg: const Color(0xFFF5F3FF),
                title: 'Base Distance',
                subtitle: 'Kilometres the base fare already covers',
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SizedBox(
                      width: 160,
                      child: _fareField('Base distance', _baseKmCtrl,
                          integer: true, suffix: 'km'),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: 4),
                        child: Text(
                          'Fares are rounded up to the next whole peso.\nPartial km counts as a full km.',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: AppColors.textMuted,
                              height: 1.5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _actionBar(draft, changed),
            ],
          ),
        ),

        // Right column — preview + history
        Expanded(
          flex: 4,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 24, 24, 40),
            children: [
              _section(
                icon: Icons.table_chart_rounded,
                iconColor: const Color(0xFF059669),
                iconBg: const Color(0xFFECFDF5),
                title: 'Live Preview',
                subtitle: 'What commuters will see at these rates',
                child: draft == null
                    ? _previewError()
                    : _previewTable(draft),
              ),
              _history(),
            ],
          ),
        ),
      ],
    );
  }

  // ── Narrow layout: single column ──────────────────────────────────────────

  Widget _buildNarrowLayout(FareConfig? draft, bool changed, bool warn) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        if (_error != null) _errorBanner(),
        if (warn) _warnBanner(),
        _section(
          icon: Icons.person_rounded,
          iconColor: AppColors.primaryNavy,
          iconBg: const Color(0xFFEFF6FF),
          title: 'Regular Fare',
          subtitle: 'Standard rate for all passengers',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _fareField('Base fare', _baseCtrl)),
              const SizedBox(width: 14),
              Expanded(child: _fareField('Per extra km', _perKmCtrl)),
            ],
          ),
        ),
        _section(
          icon: Icons.school_rounded,
          iconColor: AppColors.commuterTeal,
          iconBg: AppColors.commuterTealLight,
          title: 'Discounted Fare',
          subtitle: 'Students, PWDs & Senior Citizens',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _fareField('Base fare', _baseDiscCtrl)),
              const SizedBox(width: 14),
              Expanded(child: _fareField('Per extra km', _perKmDiscCtrl)),
            ],
          ),
        ),
        _section(
          icon: Icons.route_rounded,
          iconColor: const Color(0xFF7C3AED),
          iconBg: const Color(0xFFF5F3FF),
          title: 'Base Distance',
          subtitle: 'Kilometres the base fare already covers',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(
                width: 140,
                child: _fareField('Base distance', _baseKmCtrl,
                    integer: true, suffix: 'km'),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text(
                    'Fares are rounded up to the next whole peso.\nPartial km counts as a full km.',
                    style: TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textMuted,
                        height: 1.5),
                  ),
                ),
              ),
            ],
          ),
        ),
        _section(
          icon: Icons.table_chart_rounded,
          iconColor: const Color(0xFF059669),
          iconBg: const Color(0xFFECFDF5),
          title: 'Live Preview',
          subtitle: 'What commuters will see at these rates',
          child: draft == null ? _previewError() : _previewTable(draft),
        ),
        _actionBar(draft, changed),
        const SizedBox(height: 20),
        _history(),
      ],
    );
  }

  Widget _previewError() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFECACA)),
        ),
        child: const Row(
          children: [
            Icon(Icons.error_outline_rounded,
                color: AppColors.errorCrimson, size: 16),
            SizedBox(width: 8),
            Text(
              'Enter valid numbers above (base distance: 1–50 km).',
              style: TextStyle(fontSize: 13, color: AppColors.errorCrimson),
            ),
          ],
        ),
      );

  Widget _previewTable(FareConfig draft) {
    const kms = [1, 4, 5, 10, 20, 30];
    return Column(
      children: [
        // Header row
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.backgroundSlate,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Row(
            children: [
              Expanded(
                  child: Text('Distance',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textMuted,
                          letterSpacing: 0.5))),
              Expanded(
                  child: Text('Regular',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryNavy,
                          letterSpacing: 0.5))),
              Expanded(
                  child: Text('Discounted',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.commuterTeal,
                          letterSpacing: 0.5))),
            ],
          ),
        ),
        const SizedBox(height: 4),
        for (int i = 0; i < kms.length; i++)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color:
                  i.isEven ? Colors.white : AppColors.backgroundSlate,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('${kms[i]} km',
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primaryNavy)),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Text(
                    '₱${draft.regularForKm(kms[i]).round()}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.darkSlate),
                  ),
                ),
                Expanded(
                  child: Text(
                    '₱${draft.discountedForKm(kms[i]).round()}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.commuterTeal),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _history() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F3FF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.history_rounded,
                      color: Color(0xFF7C3AED), size: 18),
                ),
                const SizedBox(width: 12),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Recent Changes',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: AppColors.darkSlate)),
                    Text('Last 8 fare rate updates',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textMuted)),
                  ],
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18),
            child: Divider(height: 20, color: AppColors.borderSubtle),
          ),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('fare_history')
                .orderBy('changed_at', descending: true)
                .limit(8)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return const Padding(
                  padding: EdgeInsets.fromLTRB(18, 0, 18, 18),
                  child: Text('Could not load history.',
                      style: TextStyle(color: AppColors.textMuted)),
                );
              }
              final docs = snap.data?.docs ?? const [];
              if (docs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.fromLTRB(18, 0, 18, 18),
                  child: Text('No changes recorded yet.',
                      style: TextStyle(color: AppColors.textMuted)),
                );
              }
              return Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                child: Column(
                  children: [
                    for (int i = 0; i < docs.length; i++)
                      Builder(builder: (_) {
                        final m = docs[i].data();
                        final n = (m['new'] as Map?) ?? const {};
                        final ts =
                            (m['changed_at'] as Timestamp?)?.toDate();
                        final when = ts == null
                            ? '...'
                            : '${ts.year}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')}  ${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';
                        final isLast = i == docs.length - 1;
                        return Padding(
                          padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.backgroundSlate,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: AppColors.borderSubtle),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  margin: const EdgeInsets.only(top: 2),
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: AppColors.primaryNavy,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Regular ₱${n['base_fare']} + ₱${n['per_km_fare']}/km  •  '
                                        'Discounted ₱${n['base_fare_discounted']} + ₱${n['per_km_fare_discounted']}/km  •  '
                                        'First ${n['base_km']} km',
                                        style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.darkSlate,
                                            height: 1.4),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${m['changed_by'] ?? 'unknown'}  •  $when',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            color: AppColors.textMuted),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
