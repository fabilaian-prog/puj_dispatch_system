import 'package:flutter/material.dart';
import '../../utils/app_colors.dart';

// =============================================================================
// COOP UI KIT
//
// Small, reusable building blocks for the cooperative dashboard so every tab
// looks and behaves the same way. Save as:
//   lib/screens/cooperative/coop_ui.dart   (same folder as the dashboard)
//
// Design rules used across the kit
//   * One status language: success (green) = moving / ok, info (blue) = waiting,
//     warning (amber) = needs a look, danger (red) = blocked, neutral = idle.
//   * Sentence-case labels, no shouting. Numbers are the loudest thing on a card.
//   * Three radii only: 10 (controls), 14 (panels), 999 (pills).
// =============================================================================

enum CoopTone { success, info, warning, danger, neutral }

extension CoopToneColors on CoopTone {
  Color get fg {
    switch (this) {
      case CoopTone.success:
        return const Color(0xFF059669);
      case CoopTone.info:
        return const Color(0xFF1D4ED8);
      case CoopTone.warning:
        return const Color(0xFFB45309);
      case CoopTone.danger:
        return const Color(0xFFDC2626);
      case CoopTone.neutral:
        return const Color(0xFF475569);
    }
  }

  Color get bg {
    switch (this) {
      case CoopTone.success:
        return const Color(0xFFECFDF5);
      case CoopTone.info:
        return const Color(0xFFEFF6FF);
      case CoopTone.warning:
        return const Color(0xFFFFFBEB);
      case CoopTone.danger:
        return const Color(0xFFFEF2F2);
      case CoopTone.neutral:
        return const Color(0xFFF1F5F9);
    }
  }

  Color get line {
    switch (this) {
      case CoopTone.success:
        return const Color(0xFF86EFAC);
      case CoopTone.info:
        return const Color(0xFFBFDBFE);
      case CoopTone.warning:
        return const Color(0xFFFDE68A);
      case CoopTone.danger:
        return const Color(0xFFFECACA);
      case CoopTone.neutral:
        return AppColors.borderSubtle;
    }
  }
}

// ── Panel ────────────────────────────────────────────────────────────────────

/// White surface with an optional title row. The base container for the page.
class CoopPanel extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? borderColor;

  const CoopPanel({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.all(16),
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor ?? AppColors.borderSubtle),
        boxShadow: const [
          BoxShadow(
              color: Color(0x0A0F172A), blurRadius: 10, offset: Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title!,
                          style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                              color: AppColors.darkSlate)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!,
                            style: const TextStyle(
                                fontSize: 12.5, color: AppColors.textMuted)),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 14),
          ],
          child,
        ],
      ),
    );
  }
}

// ── Stat tile ────────────────────────────────────────────────────────────────

class CoopStatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final CoopTone tone;
  final String? caption;
  final VoidCallback? onTap;

  const CoopStatTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.tone = CoopTone.neutral,
    this.caption,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: tone.bg, borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 20, color: tone.fg),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(value,
                        style: const TextStyle(
                            fontSize: 24,
                            height: 1.05,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                            color: AppColors.darkSlate)),
                    const SizedBox(height: 2),
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textMuted)),
                    if (caption != null)
                      Text(caption!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: tone == CoopTone.neutral
                                  ? AppColors.textMuted
                                  : tone.fg)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Pill / plate / bars ──────────────────────────────────────────────────────

class CoopPill extends StatelessWidget {
  final String text;
  final CoopTone tone;
  final IconData? icon;

  const CoopPill(this.text,
      {super.key, this.tone = CoopTone.neutral, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: tone.fg),
            const SizedBox(width: 4),
          ],
          Text(text,
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w800, color: tone.fg)),
        ],
      ),
    );
  }
}

/// Licence plate in the app's monospace plate style.
class CoopPlate extends StatelessWidget {
  final String plate;
  final double fontSize;
  const CoopPlate(this.plate, {super.key, this.fontSize = 12.5});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Text(
        plate.replaceAll('_', ' ').toUpperCase(),
        style: TextStyle(
          fontFamily: 'monospace',
          fontWeight: FontWeight.w800,
          fontSize: fontSize,
          letterSpacing: 0.8,
          color: const Color(0xFF1E293B),
        ),
      ),
    );
  }
}

class CoopSegment {
  final int value;
  final Color color;
  const CoopSegment(this.value, this.color);
}

/// A horizontal bar split into proportional segments (e.g. en route vs standby).
class CoopSplitBar extends StatelessWidget {
  final List<CoopSegment> segments;
  final double height;
  const CoopSplitBar({super.key, required this.segments, this.height = 12});

  @override
  Widget build(BuildContext context) {
    final live = segments.where((s) => s.value > 0).toList();
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: height,
        child: live.isEmpty
            ? Container(color: const Color(0xFFE2E8F0))
            : Row(
                children: [
                  for (int i = 0; i < live.length; i++) ...[
                    if (i > 0) const SizedBox(width: 2),
                    Expanded(
                      flex: live[i].value,
                      child: Container(color: live[i].color),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

class CoopLegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const CoopLegendDot(this.color, this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.darkSlate)),
      ],
    );
  }
}

// ── Inputs ───────────────────────────────────────────────────────────────────

class CoopSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  const CoopSearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => TextField(
          controller: controller,
          onChanged: onChanged,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle:
                const TextStyle(fontSize: 13, color: AppColors.textMuted),
            prefixIcon: const Icon(Icons.search_rounded,
                size: 20, color: AppColors.textMuted),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    color: AppColors.textMuted,
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
            contentPadding: EdgeInsets.zero,
            filled: true,
            fillColor: Colors.white,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.borderSubtle),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide:
                  const BorderSide(color: AppColors.commuterTeal, width: 1.4),
            ),
          ),
        ),
      ),
    );
  }
}

/// Look of a dropdown trigger. Wrap in a PopupMenuButton.
class CoopSelectPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  const CoopSelectPill(
      {super.key,
      required this.icon,
      required this.label,
      this.active = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: active ? AppColors.commuterTealLight : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: active ? AppColors.commuterTeal : AppColors.borderSubtle),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.primaryNavy),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.darkSlate)),
          ),
          const Icon(Icons.expand_more_rounded,
              size: 20, color: AppColors.textMuted),
        ],
      ),
    );
  }
}

class CoopChoice {
  final String value;
  final String label;
  final int? count;
  const CoopChoice(this.value, this.label, {this.count});
}

/// Single-select chips with optional counts (replaces status dropdowns).
class CoopChoiceChips extends StatelessWidget {
  final List<CoopChoice> choices;
  final String value;
  final ValueChanged<String> onChanged;

  const CoopChoiceChips({
    super.key,
    required this.choices,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final c in choices) ...[
            _chip(c, c.value == value),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _chip(CoopChoice c, bool selected) {
    return Material(
      color: selected ? AppColors.primaryNavy : Colors.white,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => onChanged(c.value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: selected
                    ? AppColors.primaryNavy
                    : AppColors.borderSubtle),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(c.label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: selected ? Colors.white : AppColors.darkSlate)),
              if (c.count != null) ...[
                const SizedBox(width: 8),
                Text('${c.count}',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: selected
                            ? Colors.white70
                            : AppColors.textMuted)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Two or three way switch used to merge related tabs (Drivers | Dispatchers).
class CoopSegmented extends StatelessWidget {
  final List<String> labels;
  final List<IconData> icons;
  final int index;
  final ValueChanged<int> onChanged;

  const CoopSegmented({
    super.key,
    required this.labels,
    required this.icons,
    required this.index,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFE8EDF3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: i == index ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: i == index
                        ? const [
                            BoxShadow(
                                color: Color(0x140F172A),
                                blurRadius: 4,
                                offset: Offset(0, 1)),
                          ]
                        : null,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icons[i],
                          size: 17,
                          color: i == index
                              ? AppColors.primaryNavy
                              : AppColors.textMuted),
                      const SizedBox(width: 7),
                      Text(labels[i],
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              color: i == index
                                  ? AppColors.darkSlate
                                  : AppColors.textMuted)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Empty state ──────────────────────────────────────────────────────────────

class CoopEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const CoopEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                  color: Color(0xFFF1F5F9), shape: BoxShape.circle),
              child: Icon(icon, size: 26, color: AppColors.textMuted),
            ),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AppColors.darkSlate)),
            const SizedBox(height: 4),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13, height: 1.35, color: AppColors.textMuted)),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primaryNavy,
                  side: const BorderSide(color: AppColors.borderSubtle),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(actionLabel!,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Desktop side rail ────────────────────────────────────────────────────────

class CoopNavItem {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final int badge;
  const CoopNavItem(this.label, this.icon, this.selectedIcon, {this.badge = 0});
}

class CoopSideRail extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<CoopNavItem> items;
  final int selected;
  final ValueChanged<int> onSelect;
  final Widget footer;
  final bool extended;

  const CoopSideRail({
    super.key,
    required this.title,
    required this.subtitle,
    required this.items,
    required this.selected,
    required this.onSelect,
    required this.footer,
    required this.extended,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: extended ? 244 : 84,
      color: AppColors.primaryNavy,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(extended ? 18 : 0, 22, 14, 22),
              child: Row(
                mainAxisAlignment: extended
                    ? MainAxisAlignment.start
                    : MainAxisAlignment.center,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Icon(Icons.corporate_fare_rounded,
                        color: Colors.white, size: 22),
                  ),
                  if (extended) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 14.5,
                                  height: 1.2,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white)),
                          const SizedBox(height: 2),
                          Text(subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.white.withOpacity(0.7))),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: [
                  for (int i = 0; i < items.length; i++) _item(i),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 14),
              child: footer,
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(int i) {
    final it = items[i];
    final sel = i == selected;
    final row = Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: EdgeInsets.symmetric(
          horizontal: extended ? 14 : 0, vertical: 12),
      decoration: BoxDecoration(
        color: sel ? Colors.white.withOpacity(0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(
              color: sel ? AppColors.commuterTeal : Colors.transparent,
              width: 3),
        ),
      ),
      child: Row(
        mainAxisAlignment:
            extended ? MainAxisAlignment.start : MainAxisAlignment.center,
        children: [
          Icon(sel ? it.selectedIcon : it.icon,
              size: 21, color: sel ? Colors.white : Colors.white70),
          if (extended) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(it.label,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                      color: sel ? Colors.white : Colors.white70)),
            ),
            if (it.badge > 0)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                    color: AppColors.commuterTeal,
                    borderRadius: BorderRadius.circular(999)),
                child: Text('${it.badge}',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
              ),
          ],
        ],
      ),
    );

    return Tooltip(
      message: extended ? '' : it.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onSelect(i),
        child: row,
      ),
    );
  }
}