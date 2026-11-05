import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'route_live_details_screen.dart';
import '../../utils/app_colors.dart';
import '../../utils/app_typography.dart';

class TerminalRoutesScreen extends StatelessWidget {
  final String terminalName;
  final String terminalId;
  final String location;
  final List<Map<String, String>> routes;

  /// Accent color of this terminal (the same color its card uses on the home
  /// screen). When null, route cards cycle through the brand colors.
  final Color? themeColor;

  const TerminalRoutesScreen({
    super.key,
    required this.terminalName,
    required this.terminalId,
    required this.location,
    required this.routes,
    this.themeColor,
  });

  static const Color _mint = Color(0xFF5EEAD4);
  static const Color _tealDeep = Color(0xFF0F766E);
  static const Color _ink = Color(0xFF0F172A);

  // Same scaling rule as CommuterHomeScreen: based on the usable screen
  // (status bar, nav bar and notches subtracted), not the raw width.
  double _getScale(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final insets = MediaQuery.paddingOf(context);
    final usableWidth = size.width - insets.left - insets.right;
    final usableHeight = size.height - insets.top - insets.bottom;
    return math.min(usableWidth / 390.0, usableHeight / 700.0).clamp(0.88, 1.22).toDouble();
  }

  Color _accentFor(int index) {
    if (themeColor != null) return themeColor!;
    switch (index % 3) {
      case 0:
        return AppColors.primaryNavy;
      case 1:
        return AppColors.commuterTeal;
      default:
        return const Color(0xFF1E3A8A);
    }
  }

  IconData _tagIcon(String subCategory) {
    final t = subCategory.toLowerCase();
    if (t.contains('standby')) return Icons.hourglass_bottom_rounded;
    if (t.contains('schedul')) return Icons.schedule_rounded;
    if (t.contains('direct')) return Icons.near_me_rounded;
    return Icons.alt_route_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final s = _getScale(context);
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);

    // Keep content in a 600px column on tablets, 14*s margins on phones.
    final side = math.max(
      14 * s + math.max(pad.left, pad.right),
      (size.width - 600) / 2,
    );

    final toolbarH = 60 * s;

    return MediaQuery.withClampedTextScaling(
      minScaleFactor: 1.0,
      maxScaleFactor: 1.3,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        // Keep the bottom nav bar matching the page instead of reverting to the
        // system default when this screen is pushed. The status bar comes from
        // the SliverAppBar below; Flutter merges the two.
        value: SystemUiOverlayStyle(
          systemNavigationBarColor: AppColors.backgroundSlate,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.dark,
          systemNavigationBarContrastEnforced: false,
        ),
        child: Scaffold(
        backgroundColor: AppColors.backgroundSlate,
        body: CustomScrollView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            _buildCompactAppBar(context, s, toolbarH),

            // Section heading
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, 14 * s, side, 0),
              sliver: SliverToBoxAdapter(child: _buildSectionHeading(s)),
            ),

            // Route cards with safe bottom clearance for Android/iOS navigation bars
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                side,
                10 * s,
                side,
                24 * s + math.max(pad.bottom, 16.0),
              ),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => Padding(
                    padding: EdgeInsets.only(bottom: 9 * s),
                    child: _AnimatedIn(
                      index: index,
                      child: _buildRouteCard(
                        context,
                        routes[index],
                        index,
                        _accentFor(index),
                        s,
                      ),
                    ),
                  ),
                  childCount: routes.length,
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  // ─────────────────────────── Compact Pinned App Bar

  Widget _buildCompactAppBar(BuildContext context, double s, double toolbarH) {
    return SliverAppBar(
      pinned: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: AppColors.primaryNavy,
      systemOverlayStyle: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
      iconTheme: const IconThemeData(color: Colors.white),
      toolbarHeight: toolbarH,
      titleSpacing: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(18 * s)),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            terminalName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: 16.5 * s,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
            ),
          ),
          SizedBox(height: 1.5 * s),
          Row(
            children: [
              Icon(Icons.location_on_rounded, size: 12 * s, color: _mint),
              SizedBox(width: 3 * s),
              Expanded(
                child: Text(
                  location,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.85),
                    fontSize: 11.5 * s,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      flexibleSpace: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/images/header_jeepney.jpg',
            fit: BoxFit.cover,
            alignment: Alignment.centerRight,
            errorBuilder: (context, error, stackTrace) => Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.primaryNavy, Color(0xFF1E3A8A)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.primaryNavy.withOpacity(0.98),
                  AppColors.primaryNavy.withOpacity(0.92),
                  AppColors.primaryNavy.withOpacity(0.65),
                  AppColors.primaryNavy.withOpacity(0.35),
                ],
                stops: const [0.0, 0.45, 0.75, 1.0],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────── Section heading

  Widget _buildSectionHeading(double s) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 4 * s,
          height: 32 * s,
          margin: EdgeInsets.only(top: 1 * s),
          decoration: BoxDecoration(
            color: AppColors.commuterTeal,
            borderRadius: BorderRadius.circular(4 * s),
          ),
        ),
        SizedBox(width: 10 * s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose your destination',
                style: TextStyle(
                  fontSize: 17 * s,
                  fontWeight: FontWeight.w800,
                  color: AppColors.darkSlate,
                ),
              ),
              SizedBox(height: 1 * s),
              Text(
                'Tap a route to see live vehicle positions and the queue line-up.',
                style: TextStyle(
                  fontSize: 12 * s,
                  height: 1.25,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─────────────────────────── Compact Route card

  Widget _buildRouteCard(
    BuildContext context,
    Map<String, String> route,
    int index,
    Color accent,
    double s,
  ) {
    final destination = route['destination'] ?? '';
    final subCategory = route['subCategory'] ?? '';
    final dispatchRule = route['dispatchRule'] ?? 'Continuous departure queue.';
    final number = (index + 1).toString().padLeft(2, '0');
    final deep = Color.lerp(accent, _ink, 0.35)!;
    final radius = BorderRadius.circular(16 * s);

    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        child: InkWell(
          onTap: () {
            AppTypography.lightFeedback();
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => RouteLiveDetailsScreen(
                  terminalName: terminalName,
                  terminalId: terminalId,
                  destination: destination,
                  subCategory: subCategory,
                  dispatchRule: dispatchRule,
                ),
              ),
            );
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Gradient Header
              Ink(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [accent, deep],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      right: -6 * s,
                      bottom: -16 * s,
                      child: Icon(
                        Icons.directions_bus_rounded,
                        size: 78 * s,
                        color: Colors.white.withOpacity(0.08),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(12 * s, 10 * s, 10 * s, 10 * s),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            width: 34 * s,
                            height: 34 * s,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.16),
                              borderRadius: BorderRadius.circular(10 * s),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.24),
                              ),
                            ),
                            child: Text(
                              number,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14.5 * s,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          SizedBox(width: 10 * s),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (subCategory.isNotEmpty) ...[
                                  Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 7 * s,
                                      vertical: 2 * s,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.18),
                                      borderRadius: BorderRadius.circular(16 * s),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _tagIcon(subCategory),
                                          size: 11 * s,
                                          color: Colors.white,
                                        ),
                                        SizedBox(width: 3 * s),
                                        Flexible(
                                          child: Text(
                                            subCategory,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 11 * s,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.2,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  SizedBox(height: 3 * s),
                                ],
                                Text(
                                  destination,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 17.5 * s,
                                    height: 1.15,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(width: 8 * s),
                          Container(
                            width: 28 * s,
                            height: 28 * s,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.arrow_forward_rounded,
                              size: 16 * s,
                              color: accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Body: live queue status + boarding status & capacity + dispatch rule
              Padding(
                padding: EdgeInsets.fromLTRB(12 * s, 10 * s, 12 * s, 11 * s),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _QueueStatusChip(
                      queueDocId: _queueDocId(terminalId, destination),
                      isScheduled: subCategory.toLowerCase().contains('schedul'),
                      accent: _tealDeep,
                      s: s,
                    ),
                    if (dispatchRule.isNotEmpty) ...[
                      SizedBox(height: 7 * s),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 14 * s,
                            color: AppColors.textMuted,
                          ),
                          SizedBox(width: 5 * s),
                          Expanded(
                            child: Text(
                              dispatchRule,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12 * s,
                                height: 1.3,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Must match RouteLiveDetailsScreen._getQueueDocId().
  static String _queueDocId(String terminalId, String destination) {
    String suffix = 'GUINSANGAN';
    if (destination.contains('Sibalom')) suffix = 'SIBALOM';
    if (destination.contains('Belison')) suffix = 'BELISON';
    if (destination.contains('Patnongon')) suffix = 'PATNONGON';
    if (destination.contains('Bugasong')) suffix = 'BUGASONG';
    if (destination.contains('Anini-y')) suffix = 'ANINIY';
    if (destination.contains('DAO')) suffix = 'DAO';
    if (destination.contains('San Remigio')) suffix = 'SAN_REMIGIO';
    if (destination.contains('Valderrama')) suffix = 'VALDERRAMA';
    if (destination.contains('Lindero')) suffix = 'LINDERO';
    return '${terminalId}_$suffix';
  }
}

/// Fade + slide-up entrance.
class _AnimatedIn extends StatelessWidget {
  final int index;
  final Widget child;

  const _AnimatedIn({required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 340 + math.min(index, 6) * 70),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - v)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Live "Boarding Status", "Real-Time Capacity", and "Units in Queue" chips.
class _QueueStatusChip extends StatelessWidget {
  final String queueDocId;
  final bool isScheduled;
  final Color accent;
  final double s;

  const _QueueStatusChip({
    required this.queueDocId,
    required this.isScheduled,
    required this.accent,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('terminals_queue')
          .doc(queueDocId)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return Container(
            padding: EdgeInsets.symmetric(horizontal: 9 * s, vertical: 5 * s),
            decoration: BoxDecoration(
              color: AppColors.textMuted.withOpacity(0.08),
              borderRadius: BorderRadius.circular(16 * s),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 12 * s,
                  height: 12 * s,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: AppColors.textMuted.withOpacity(0.7),
                  ),
                ),
                SizedBox(width: 6 * s),
                Text(
                  'Checking bay status...',
                  style: TextStyle(
                    fontSize: 11.5 * s,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          );
        }

        final data = snap.data?.data();
        final rawActive = data?['active_loading_vehicle'];
        final String? activeVehicle = (rawActive != null &&
                rawActive != 'None' &&
                rawActive != 'null' &&
                rawActive.toString().trim().isNotEmpty)
            ? rawActive.toString().trim()
            : null;

        final queued = (data?['queued_vehicles'] as List<dynamic>?)?.length ?? 0;
        final staged = (data?['standby_staged_vehicles'] as List<dynamic>?)?.length ?? 0;
        final totalQueued = queued + staged;

        // Uses Wrap to prevent any pixel overflowing on narrow phone screens
        return Wrap(
          spacing: 6 * s,
          runSpacing: 5 * s,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // 1. Boarding indicator & live capacity badge
            if (activeVehicle != null) ...[
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 4 * s),
                decoration: BoxDecoration(
                  color: const Color(0xFFECFDF5),
                  borderRadius: BorderRadius.circular(16 * s),
                  border: Border.all(color: const Color(0xFF86EFAC), width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6 * s,
                      height: 6 * s,
                      decoration: const BoxDecoration(
                        color: Color(0xFF059669),
                        shape: BoxShape.circle,
                      ),
                    ),
                    SizedBox(width: 4.5 * s),
                    Text(
                      'BOARDING',
                      style: TextStyle(
                        fontSize: 11 * s,
                        fontWeight: FontWeight.w900,
                        color: const Color(0xFF065F46),
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
              _LiveBoardingCapacityBadge(vehicleId: activeVehicle, s: s),
            ],

            // 2. Queue line-up count chip
            if (totalQueued > 0)
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 4 * s),
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.09),
                  borderRadius: BorderRadius.circular(16 * s),
                  border: Border.all(color: accent.withOpacity(0.24), width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      activeVehicle != null
                          ? Icons.format_list_numbered_rounded
                          : Icons.directions_bus_rounded,
                      size: 12.5 * s,
                      color: accent,
                    ),
                    SizedBox(width: 4 * s),
                    Text(
                      totalQueued == 1
                          ? (activeVehicle != null ? '1 next in line' : '1 unit in line')
                          : (activeVehicle != null ? '$totalQueued in queue' : '$totalQueued units in line'),
                      style: TextStyle(
                        fontSize: 11.5 * s,
                        fontWeight: FontWeight.w800,
                        color: accent,
                      ),
                    ),
                  ],
                ),
              )
            else if (activeVehicle == null) ...[
              if (isScheduled)
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 4 * s),
                  decoration: BoxDecoration(
                    color: AppColors.textMuted.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(16 * s),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.schedule_rounded, size: 12.5 * s, color: AppColors.textMuted),
                      SizedBox(width: 4 * s),
                      Text(
                        'Fixed schedule',
                        style: TextStyle(
                          fontSize: 11.5 * s,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 4 * s),
                  decoration: BoxDecoration(
                    color: AppColors.textMuted.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(16 * s),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.hourglass_empty_rounded, size: 12.5 * s, color: AppColors.textMuted),
                      SizedBox(width: 4 * s),
                      Text(
                        'No units queued',
                        style: TextStyle(
                          fontSize: 11.5 * s,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// Live passenger capacity counter for the currently boarding jeepney.
class _LiveBoardingCapacityBadge extends StatelessWidget {
  final String vehicleId;
  final double s;

  const _LiveBoardingCapacityBadge({
    required this.vehicleId,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('vehicles_live')
          .doc(vehicleId)
          .snapshots(),
      builder: (context, vSnap) {
        final vData = vSnap.data?.data();
        final int currentSeats = (vData?['passenger_count'] as num?)?.toInt() ?? 0;
        final int maxSeats = (vData?['max_capacity'] as num?)?.toInt() ?? 20;

        final bool isFull = currentSeats >= maxSeats && maxSeats > 0;
        final bool isAlmostFull = maxSeats > 0 && currentSeats >= (maxSeats * 0.8);

        final Color textColor = isFull
            ? AppColors.errorCrimson
            : (isAlmostFull ? const Color(0xFFD97706) : const Color(0xFF047857));
        final Color bgColor = isFull
            ? const Color(0xFFFEF2F2)
            : (isAlmostFull ? const Color(0xFFFFFBEB) : const Color(0xFFECFDF5));
        final Color borderColor = isFull
            ? const Color(0xFFFECACA)
            : (isAlmostFull ? const Color(0xFFFDE68A) : const Color(0xFFA7F3D0));

        return Container(
          padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 4 * s),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(16 * s),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.airline_seat_recline_normal_rounded,
                size: 13 * s,
                color: textColor,
              ),
              SizedBox(width: 3.5 * s),
              Text(
                isFull ? 'FULL ($currentSeats/$maxSeats)' : '$currentSeats/$maxSeats seats',
                style: TextStyle(
                  fontSize: 11.5 * s,
                  fontWeight: FontWeight.w800,
                  color: textColor,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}