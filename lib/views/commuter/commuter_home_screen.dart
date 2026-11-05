import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'terminal_routes_screen.dart';
import '../auth/login_screen.dart';
import '../../utils/app_colors.dart';
import '../../utils/app_typography.dart';

class CommuterHomeScreen extends StatelessWidget {
  const CommuterHomeScreen({super.key});

  final List<Map<String, String>> dalipe1NorthboundRoutes = const [
    {
      'destination': 'Sibalom',
      'subCategory': 'Direct Route',
      'dispatchRule': 'Continuous departure queue.',
    },
    {
      'destination': 'Belison',
      'subCategory': 'Direct Route',
      'dispatchRule': 'Continuous departure queue.',
    },
    {
      'destination': 'Patnongon',
      'subCategory': 'Direct Route',
      'dispatchRule': 'Continuous departure queue.',
    },
    {
      'destination': 'Bugasong',
      'subCategory': 'Northbound Line',
      'dispatchRule': 'Continuous departure queue.',
    },
  ];

  final List<Map<String, String>> dalipe2Routes = const [
    {
      'destination': 'Guinsang-an (Direct & Business Park)',
      'subCategory': 'Active Line-up List 1',
      'dispatchRule': 'Boards passengers at terminal. On-call for Business Park pickup point when requested by dispatcher.',
    },
    {
      'destination': 'Anini-y',
      'subCategory': 'Scheduled Departure',
      'dispatchRule': 'Leaves on fixed schedule toward Robinsons regardless of passenger count.',
    },
    {
      'destination': 'Lindero',
      'subCategory': 'Active Line-up List 1',
      'dispatchRule': 'Same process as Guinsang-an: Group A boards here, Group B waits in the standby pool until called by the Robinsons dispatcher.',
    },
    {
      'destination': 'San Remigio',
      'subCategory': 'Interior Route',
      'dispatchRule': 'Direct terminal loading.',
    },
    {
      'destination': 'Valderrama',
      'subCategory': 'Interior Route',
      'dispatchRule': 'Direct terminal loading.',
    },
  ];

  final List<Map<String, String>> robinsonsRoutes = const [
    {
      'destination': 'Guinsang-an',
      'subCategory': 'Dispatched Line',
      'dispatchRule': 'Units called in directly from Dalipe 2 standby pool by Robinsons dispatcher.',
    },
    {
      'destination': 'Anini-y',
      'subCategory': 'Scheduled Transfer / Direct',
      'dispatchRule': 'Regular route link.',
    },
    {
      'destination': 'DAO (Tobias Fornier)',
      'subCategory': 'Scheduled Southbound Route',
      'dispatchRule': 'Scheduled units arrive from Dalipe and board here at their scheduled arrival time.',
    },
    {
      'destination': 'Lindero',
      'subCategory': 'Dispatched Line',
      'dispatchRule': 'Units called in directly from the Dalipe standby pool by the Robinsons dispatcher.',
    },
  ];

  // Largest system font scale this screen is designed for. Anything bigger is
  // clamped so fixed-height cards can't overflow (the scroll fallback in
  // _buildBody handles the rest).
  static const double _maxTextScale = 1.3;

  // Responsive scale based on the *usable* screen: width, and height with the
  // status bar, nav bar and notches/cutouts subtracted. Using only the raw
  // width made short phones, 3-button-nav phones and landscape overflow.
  double _getScale(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final insets = MediaQuery.paddingOf(context);
    final usableWidth = size.width - insets.left - insets.right;
    final usableHeight = size.height - insets.top - insets.bottom;

    final widthScale = usableWidth / 390.0;
    final heightScale = usableHeight / 700.0;
    return math.min(widthScale, heightScale).clamp(0.88, 1.22).toDouble();
  }

  // Effective system font scale (1.0 – _maxTextScale), used to grow fixed heights.
  double _textFactor(BuildContext context) {
    final factor = MediaQuery.textScalerOf(context).scale(100) / 100;
    return factor.clamp(1.0, _maxTextScale).toDouble();
  }

  Future<void> _handleTrackComplaints(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final savedPhone = prefs.getString('commuter_phone');

    if (!context.mounted) return;

    if (savedPhone != null && savedPhone.isNotEmpty) {
      _showTrackResultsDialog(context, savedPhone);
    } else {
      _promptPhoneNumberDialog(context);
    }
  }

  void _promptPhoneNumberDialog(BuildContext context) {
    final s = _getScale(context);
    final phoneController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogCtx) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: _maxTextScale,
        child: Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16 * s)),
        insetPadding: EdgeInsets.symmetric(horizontal: 20 * s, vertical: 24 * s),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(20 * s),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(8 * s),
                      decoration: BoxDecoration(
                        color: AppColors.commuterTeal.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10 * s),
                      ),
                      child: Icon(Icons.phone_iphone_rounded, color: AppColors.commuterTeal, size: 22 * s),
                    ),
                    SizedBox(width: 12 * s),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Track Filed Reports', style: TextStyle(fontSize: 16.5 * s, fontWeight: FontWeight.w800, color: AppColors.darkSlate)),
                          SizedBox(height: 2 * s),
                          Text('Enter your contact number to view updates', style: TextStyle(fontSize: 12 * s, color: AppColors.textMuted)),
                        ],
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.close_rounded, size: 20 * s, color: AppColors.textMuted),
                      onPressed: () => Navigator.pop(dialogCtx),
                    ),
                  ],
                ),
                Divider(height: 22 * s, color: AppColors.borderSubtle),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  style: TextStyle(fontSize: 15 * s, fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    labelText: 'Contact Number',
                    hintText: 'e.g. 09123456789',
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.backgroundSlate,
                    prefixIcon: Icon(Icons.phone_outlined, size: 18 * s, color: AppColors.textMuted),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10 * s), borderSide: const BorderSide(color: AppColors.borderSubtle)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10 * s), borderSide: const BorderSide(color: AppColors.commuterTeal, width: 1.5)),
                  ),
                ),
                SizedBox(height: 18 * s),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryNavy,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10 * s)),
                    padding: EdgeInsets.symmetric(vertical: 13 * s),
                    elevation: 0,
                  ),
                  onPressed: () async {
                    final phone = phoneController.text.trim();
                    if (phone.isEmpty) return;

                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString('commuter_phone', phone);

                    if (!context.mounted) return;
                    Navigator.pop(dialogCtx);
                    _showTrackResultsDialog(context, phone);
                  },
                  child: Text('View Reports', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5 * s)),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  void _showTrackResultsDialog(BuildContext context, String phone) {
    final s = _getScale(context);

    showDialog(
      context: context,
      builder: (dialogCtx) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: _maxTextScale,
        child: Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16 * s)),
        insetPadding: EdgeInsets.symmetric(horizontal: 16 * s, vertical: 24 * s),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 480,
            maxHeight: (MediaQuery.sizeOf(context).height -
                    MediaQuery.paddingOf(context).vertical) *
                0.78,
          ),
          child: Padding(
            padding: EdgeInsets.all(18 * s),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('My Incident Reports', style: TextStyle(fontSize: 17 * s, fontWeight: FontWeight.w800, color: AppColors.darkSlate)),
                          SizedBox(height: 2 * s),
                          Text('Linked: $phone', style: TextStyle(fontSize: 12.5 * s, color: AppColors.textMuted)),
                        ],
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.symmetric(horizontal: 8 * s)),
                      onPressed: () async {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.remove('commuter_phone');
                        if (!context.mounted) return;
                        Navigator.pop(dialogCtx);
                        _promptPhoneNumberDialog(context);
                      },
                      child: Text('Switch Phone', style: TextStyle(fontSize: 12.5 * s, color: AppColors.commuterTeal, fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.close_rounded, size: 22 * s, color: AppColors.textMuted),
                      onPressed: () => Navigator.pop(dialogCtx),
                    ),
                  ],
                ),
                Divider(height: 18 * s, color: AppColors.borderSubtle),
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('complaints').where('complainant_contact', isEqualTo: phone).snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator(color: AppColors.commuterTeal));
                      }
                      final docs = snapshot.data?.docs ?? [];
                      if (docs.isEmpty) {
                        return Center(
                          child: Text('No complaints found for this number.', style: TextStyle(fontSize: 13.5 * s, color: AppColors.textMuted)),
                        );
                      }
                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (context, index) {
                          final data = docs[index].data() as Map<String, dynamic>;
                          final category = (data['category'] ?? 'Incident').toString();
                          final plate = (data['plate_number'] ?? 'N/A').toString();
                          final desc = (data['description'] ?? '').toString();
                          final status = (data['status'] ?? 'PENDING_VERIFICATION').toString().toUpperCase();
                          final latestCoopComment = (data['latest_coop_comment'] ?? '').toString();

                          return Container(
                            margin: EdgeInsets.only(bottom: 12 * s),
                            padding: EdgeInsets.all(12 * s),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12 * s),
                              border: Border.all(color: AppColors.borderSubtle),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Text(category, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5 * s, color: AppColors.darkSlate)),
                                    ),
                                    Container(
                                      padding: EdgeInsets.symmetric(horizontal: 7 * s, vertical: 3 * s),
                                      decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(4 * s)),
                                      child: Text(plate.toUpperCase(), style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 12 * s)),
                                    ),
                                  ],
                                ),
                                if (desc.isNotEmpty) ...[
                                  SizedBox(height: 6 * s),
                                  Text(desc, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5 * s, color: AppColors.textMuted)),
                                ],
                                SizedBox(height: 10 * s),
                                _buildInvestigationStepper(status, s),
                                if (latestCoopComment.isNotEmpty) ...[
                                  SizedBox(height: 10 * s),
                                  Container(
                                    width: double.infinity,
                                    padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 7 * s),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEFF6FF),
                                      borderRadius: BorderRadius.circular(8 * s),
                                      border: Border.all(color: const Color(0xFFBFDBFE)),
                                    ),
                                    child: Text(
                                      'Coop Action: $latestCoopComment',
                                      style: TextStyle(fontSize: 12 * s, fontWeight: FontWeight.w600, color: const Color(0xFF1E40AF)),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildInvestigationStepper(String rawStatus, double s) {
    int currentStep = 1;
    bool isDismissed = rawStatus.contains('DISMISSED') || rawStatus.contains('REJECTED');
    if (rawStatus.contains('RESOLVED')) {
      currentStep = 3;
    } else if (rawStatus.contains('REVIEW') || rawStatus.contains('INVESTIGAT')) {
      currentStep = 2;
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 9 * s),
      decoration: BoxDecoration(color: AppColors.backgroundSlate, borderRadius: BorderRadius.circular(8 * s)),
      child: Row(
        children: [
          _buildStepNode(1, 'Logged', currentStep >= 1, isCompleted: currentStep > 1, s: s),
          Expanded(child: Container(height: 2.5, color: currentStep >= 2 ? const Color(0xFF059669) : Colors.grey.shade300)),
          _buildStepNode(2, 'In Review', currentStep >= 2, isCompleted: currentStep > 2, s: s),
          Expanded(child: Container(height: 2.5, color: currentStep >= 3 || isDismissed ? const Color(0xFF059669) : Colors.grey.shade300)),
          _buildStepNode(3, isDismissed ? 'Closed' : 'Actioned', currentStep == 3 || isDismissed, isDismissed: isDismissed, s: s),
        ],
      ),
    );
  }

  Widget _buildStepNode(int stepNumber, String title, bool isActive, {bool isCompleted = false, bool isDismissed = false, required double s}) {
    Color color = Colors.grey.shade400;
    if (isDismissed) {
      color = const Color(0xFF64748B);
    } else if (isActive) {
      color = const Color(0xFF059669);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 22 * s,
          height: 22 * s,
          decoration: BoxDecoration(
            color: isActive ? color : Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 1.5),
          ),
          child: Center(
            child: isCompleted || isActive
                ? Icon(isDismissed ? Icons.close_rounded : Icons.check_rounded, size: 13 * s, color: isActive ? Colors.white : color)
                : Text('$stepNumber', style: TextStyle(fontSize: 10 * s, color: color, fontWeight: FontWeight.bold)),
          ),
        ),
        SizedBox(height: 3 * s),
        Text(title, style: TextStyle(fontSize: 10.5 * s, fontWeight: isActive ? FontWeight.w800 : FontWeight.w500, color: isActive ? AppColors.darkSlate : AppColors.textMuted)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _getScale(context);
    final tf = _textFactor(context);
    // Toolbar grows a little with the font scale so the two-line title fits.
    final appBarHeight = 62 * s * (1 + (tf - 1) * 0.6);

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: _maxTextScale,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        // Bottom (gesture / 3-button) nav bar blends with the page background.
        // The top status bar style is set by the AppBar below. Flutter merges both.
        value: SystemUiOverlayStyle(
          systemNavigationBarColor: AppColors.backgroundSlate,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.dark,
          systemNavigationBarContrastEnforced: false,
        ),
        child: Scaffold(
          backgroundColor: AppColors.backgroundSlate,
          appBar: PreferredSize(
            // Scaffold adds the status-bar / notch height on top of this.
            preferredSize: Size.fromHeight(appBarHeight),
            child: AppBar(
              elevation: 0,
              backgroundColor: AppColors.primaryNavy,
              // Navy bar -> light status bar icons, transparent so it never
              // flashes a different color on devices that tint the status bar.
              systemOverlayStyle: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
              titleSpacing: 16 * s,
              title: Row(
                children: [
                  Image.asset(
                    'assets/images/jeepes_logo.png',
                    height: 38 * s,
                    color: Colors.white,
                    colorBlendMode: BlendMode.srcIn,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => Text(
                      'JeePes',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 23 * s),
                    ),
                  ),
                  SizedBox(width: 12 * s),
                  Container(height: 22 * s, width: 1.5, color: Colors.white.withOpacity(0.24)),
                  SizedBox(width: 12 * s),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Antique PUJ Network', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: 15 * s, fontWeight: FontWeight.w800)),
                        Text('Public Transit Portal', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white70, fontSize: 11.5 * s)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // SafeArea keeps content clear of the bottom nav bar / gesture bar and
          // of side notches in landscape (the AppBar already handles the top).
          body: SafeArea(child: _buildBody(context, s, tf)),
        ),
      ),
    );
  }

  /// Fills the screen exactly when there is room (the original "zero-scroll"
  /// look). When the usable height is too small - short phones, 3-button nav,
  /// landscape, split-screen, big fonts - each section keeps a safe minimum
  /// height and the page scrolls instead of overflowing.
  Widget _buildBody(BuildContext context, double s, double tf) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const heroFlex = 25, cardFlex = 20, bannerFlex = 15, totalFlex = 100;

            final hPad = 14 * s;
            final vPad = 8 * s;
            final gap = 8 * s;

            // Minimum comfortable height of each section (grows with font scale).
            final heroMin = 124 * s * tf;
            final cardMin = 110 * s * tf; // room for a 2-line route list
            final bannerMin = 66 * s * tf;

            // Height the flex layout needs so that NO section drops below its minimum.
            final neededHeight = math.max(
              heroMin * totalFlex / heroFlex,
              math.max(cardMin * totalFlex / cardFlex, bannerMin * totalFlex / bannerFlex),
            );
            final availableHeight = constraints.maxHeight - (vPad * 2) - (gap * 4);
            final fillsScreen = availableHeight >= neededHeight;

            Widget slot(int flex, double minHeight, Widget child) =>
                fillsScreen ? Expanded(flex: flex, child: child) : SizedBox(height: minHeight, child: child);

            Widget terminal({
              required String name,
              required String location,
              required String subtext,
              required String id,
              required List<Map<String, String>> routes,
              required Color color,
            }) {
              return slot(
                cardFlex,
                cardMin,
                _buildTerminalCard(
                  context: context,
                  terminalName: name,
                  location: location,
                  subtext: subtext,
                  routeCount: routes.length,
                  themeColor: color,
                  scale: s,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => TerminalRoutesScreen(
                        terminalName: name,
                        terminalId: id,
                        location: location,
                        routes: routes,
                      ),
                    ),
                  ),
                ),
              );
            }

            final column = Column(
              mainAxisSize: fillsScreen ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                slot(heroFlex, heroMin, _buildHeroBanner(s)),
                SizedBox(height: gap),
                terminal(
                  name: 'Dalipe 1 (Northbound)',
                  location: 'Dalipe, San Jose de Buenavista',
                  subtext: 'Sibalom • Belison • Patnongon • Bugasong',
                  id: 'TERM_DALIPE_1',
                  routes: dalipe1NorthboundRoutes,
                  color: AppColors.primaryNavy,
                ),
                SizedBox(height: gap),
                terminal(
                  name: 'Dalipe 2',
                  location: 'Dalipe, San Jose de Buenavista',
                  subtext: 'Guinsang-an (Direct) • Lindero • Anini-y • San Remigio • Valderrama',
                  id: 'TERM_DALIPE_2',
                  routes: dalipe2Routes,
                  color: AppColors.commuterTeal,
                ),
                SizedBox(height: gap),
                terminal(
                  name: 'Robinsons Terminal',
                  location: 'Brgy. San Angel, San Jose de Buenavista',
                  subtext: 'Guinsang-an • Anini-y • DAO • Lindero',
                  id: 'TERM_ROBINSONS',
                  routes: robinsonsRoutes,
                  color: const Color(0xFF1E3A8A),
                ),
                SizedBox(height: gap),
                slot(bannerFlex, bannerMin, _buildSafetyBanner(context, s)),
              ],
            );

            final padding = EdgeInsets.symmetric(horizontal: hPad, vertical: vPad);

            if (fillsScreen) {
              return Padding(padding: padding, child: column);
            }
            return SingleChildScrollView(padding: padding, child: column);
          },
        ),
      ),
    );
  }

  Widget _buildHeroBanner(double s) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14 * s),
        color: AppColors.primaryNavy,
        boxShadow: const [BoxShadow(color: Color(0x18000000), blurRadius: 8, offset: Offset(0, 3))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14 * s),
        child: Stack(
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
                    AppColors.primaryNavy.withOpacity(0.97),
                    AppColors.primaryNavy.withOpacity(0.88),
                    AppColors.primaryNavy.withOpacity(0.35),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 0.72, 1.0],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16 * s, vertical: 10 * s),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 7 * s, vertical: 2.5 * s),
                    decoration: BoxDecoration(
                      color: AppColors.commuterTeal.withOpacity(0.25),
                      borderRadius: BorderRadius.circular(5 * s),
                      border: Border.all(color: AppColors.commuterTeal.withOpacity(0.6), width: 0.8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.route_rounded, size: 12 * s, color: const Color(0xFF5EEAD4)),
                        SizedBox(width: 4 * s),
                        Text(
                          'PUJ TRANSIT NETWORK',
                          style: TextStyle(color: const Color(0xFF5EEAD4), fontSize: 10 * s, fontWeight: FontWeight.w900, letterSpacing: 0.8),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 4 * s),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'Antique PUJ Network',
                      style: TextStyle(color: Colors.white, fontSize: 19 * s, fontWeight: FontWeight.w900, letterSpacing: -0.3),
                    ),
                  ),
                  SizedBox(height: 2 * s),
                  Text(
                    'Real-time line-ups, live telemetry & transit corridors.',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white.withOpacity(0.92), fontSize: 12 * s),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTerminalCard({
    required BuildContext context,
    required String terminalName,
    required String location,
    required String subtext,
    required int routeCount,
    required Color themeColor,
    required double scale,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14 * scale),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [BoxShadow(color: Color(0x060F172A), blurRadius: 8, offset: Offset(0, 2))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            AppTypography.lightFeedback();
            onTap();
          },
          child: Row(
            children: [
              Container(width: 5 * scale, color: themeColor),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 8 * scale),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    terminalName,
                                    style: TextStyle(fontSize: 16.5 * scale, fontWeight: FontWeight.w800, color: AppColors.darkSlate),
                                  ),
                                ),
                                Text(
                                  location,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11.5 * scale, color: AppColors.textMuted),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: EdgeInsets.symmetric(horizontal: 9 * scale, vertical: 4 * scale),
                            decoration: BoxDecoration(
                              color: themeColor.withOpacity(0.09),
                              borderRadius: BorderRadius.circular(6 * scale),
                              border: Border.all(color: themeColor.withOpacity(0.25)),
                            ),
                            child: Text(
                              '$routeCount Lines',
                              style: TextStyle(color: themeColor, fontSize: 12 * scale, fontWeight: FontWeight.w800),
                            ),
                          ),
                        ],
                      ),
                      Container(height: 1, color: AppColors.borderSubtle),
                      Text(
                        subtext,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5 * scale, fontWeight: FontWeight.w600, color: AppColors.darkSlate.withOpacity(0.85)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSafetyBanner(BuildContext context, double s) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDFA),
        borderRadius: BorderRadius.circular(14 * s),
        border: Border.all(color: const Color(0xFFCCFBF1)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            AppTypography.lightFeedback();
            _handleTrackComplaints(context);
          },
          borderRadius: BorderRadius.circular(14 * s),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 14 * s, vertical: 6 * s),
            child: Row(
              children: [
                Container(
                  width: 36 * s,
                  height: 36 * s,
                  decoration: BoxDecoration(color: AppColors.commuterTeal, borderRadius: BorderRadius.circular(10 * s)),
                  child: Icon(Icons.verified_rounded, color: Colors.white, size: 20 * s),
                ),
                SizedBox(width: 10 * s),
                Container(width: 1.2, height: 28 * s, color: const Color(0xFFCCFBF1)),
                SizedBox(width: 10 * s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Commuter Safety First', style: TextStyle(fontSize: 14 * s, fontWeight: FontWeight.w800, color: const Color(0xFF0F172A))),
                      SizedBox(height: 1 * s),
                      Text('Track filed reports or report infractions.', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11 * s, color: AppColors.textMuted)),
                    ],
                  ),
                ),
                SizedBox(width: 6 * s),
                Icon(Icons.arrow_forward_ios_rounded, color: AppColors.commuterTeal, size: 14 * s),
              ],
            ),
          ),
        ),
      ),
    );
  }
}