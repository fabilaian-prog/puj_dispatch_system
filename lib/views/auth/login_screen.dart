import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../admin/super_admin_dashboard_screen.dart';
import '../driver/driver_dashboard_screen.dart';
import '../dispatcher/dispatcher_dashboard_screen.dart';
import '../cooperative/cooperative_dashboard_screen.dart';
import '../../utils/app_colors.dart';
import '../../utils/staff_auth.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _pinController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePin = true;
  String? _errorMessage;

  // Slow looping animation for the background glows
  late final AnimationController _bgController;
  // One-shot entrance animation for the card & hero copy
  late final AnimationController _enterController;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  // Responsive scaling, recomputed on every build
  double _scale = 1.0;
  bool _compact = false;
  double _sc(double v) => v * _scale;

  // Background palette
  static const _bgTop = Color(0xFF1E40AF);
  static const _bgMid = Color(0xFF0F2A6B);
  static const _bgBottom = Color(0xFF060F2E);
  static const _accentCyan = Color(0xFF22D3EE);
  static const _accentAmber = Color(0xFFFFB020);
  static const _accentIndigo = Color(0xFF6366F1);

  @override
  void initState() {
    super.initState();

    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 16),
    )..repeat();

    _enterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    final curved = CurvedAnimation(
      parent: _enterController,
      curve: Curves.easeOutCubic,
    );
    _fade = curved;
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(curved);
    _enterController.forward();

    _checkExistingSession();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _pinController.dispose();
    _bgController.dispose();
    _enterController.dispose();
    super.dispose();
  }

  // Automatically redirects if a staff session was already saved
  Future<void> _checkExistingSession() async {
    final session = await StaffAuth.restoreSession();
    if (session != null && mounted) {
      _navigateToDashboard(session.role, session.userDocId, session.userData);
    }
  }

  void _navigateToDashboard(
      String role, String userId, Map<String, dynamic> userData) {
    Widget targetScreen;
    switch (role.toUpperCase()) {
      case 'SUPER_ADMIN':
        targetScreen = SuperAdminDashboardScreen();
        break;
      case 'DRIVER':
        targetScreen = DriverDashboardScreen(
          userId: userId,
          userData: userData,
        );
        break;
      case 'DISPATCHER':
        targetScreen = DispatcherDashboardScreen(
          userId: userId,
          userData: userData,
        );
        break;
      case 'COOPERATIVE':
        targetScreen = CooperativeDashboardScreen(
          userId: userId,
          userData: userData,
        );
        break;
      default:
        targetScreen = Scaffold(
          appBar: AppBar(title: Text('$role Dashboard')),
          body: Center(child: Text('Dashboard for "$role" coming next!')),
        );
        break;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => targetScreen),
    );
  }

  void _fillCredentials(String user, String pin) {
    setState(() {
      _errorMessage = null;
      _usernameController.text = user;
      _pinController.text = pin;
    });
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _errorMessage = message;
      _isLoading = false;
    });
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final session = await StaffAuth.signIn(
        _usernameController.text,
        _pinController.text.trim(),
      );
      if (!mounted) return;
      _navigateToDashboard(session.role, session.userDocId, session.userData);
    } on FirebaseAuthException catch (e) {
      debugPrint('Login failed: $e');
      if (e.code == 'too-many-requests') {
        _setError(
            'Too many attempts. Please wait a few minutes and try again.');
      } else if (e.code == 'network-request-failed') {
        _setError('No connection. Check your internet and try again.');
      } else {
        _setError('Invalid username or PIN. Please try again.');
      }
    } on StaffAuthException catch (e) {
      _setError(e.message);
    } catch (e) {
      debugPrint('Login failed: $e');
      _setError('Something went wrong. Check your connection and try again.');
    } finally {
      if (mounted && _isLoading) setState(() => _isLoading = false);
    }
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final bool isDesktop = size.width >= 960;

    // Lock scale cleanly at 1.0 on desktop so the login card stays crisp,
    // while keeping dynamic scaling intact for mobile phones.
    _scale = isDesktop
        ? 1.0
        : (size.width / 390).clamp(0.85, 1.15).toDouble();
    _compact = !isDesktop && (size.height < 640 || size.width < 340);
    final double maxCardWidth = size.width >= 600 ? 440 : 400;

    return MediaQuery(
      data: mq.copyWith(
        textScaler: mq.textScaler.clamp(
          minScaleFactor: 0.9,
          maxScaleFactor: _compact ? 1.1 : 1.25,
        ),
      ),
      child: isDesktop
          ? _buildDesktopScaffold()
          : _buildMobileScaffold(maxCardWidth),
    );
  }

  // ---------------------------------------------------------------------------
  // MOBILE SCAFFOLD (Unchanged behavior for phones & tablets < 960px)
  // ---------------------------------------------------------------------------
  Widget _buildMobileScaffold(double maxCardWidth) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Scaffold(
          resizeToAvoidBottomInset: true,
          body: Stack(
            children: [
              _buildBackground(),
              SafeArea(
                maintainBottomViewPadding: true,
                child: Center(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.symmetric(
                      horizontal: _sc(22).clamp(14.0, 26.0).toDouble(),
                      vertical: _compact ? 12 : 24,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxCardWidth),
                      child: FadeTransition(
                        opacity: _fade,
                        child: SlideTransition(
                          position: _slide,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildCard(),
                              SizedBox(height: _compact ? 14 : 22),
                              _buildFooter(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // DESKTOP LANDING PAGE SCAFFOLD (>= 960px: Left Words, Right Login)
  // ---------------------------------------------------------------------------
  Widget _buildDesktopScaffold() {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          body: Stack(
            children: [
              _buildBackground(),
              SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1200),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 56,
                        vertical: 32,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // LEFT SIDE: Hero Copy & Feature Highlights
                          Expanded(
                            flex: 6,
                            child: FadeTransition(
                              opacity: _fade,
                              child: SlideTransition(
                                position: _slide,
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.only(right: 48),
                                  child: _buildDesktopHeroContent(),
                                ),
                              ),
                            ),
                          ),

                          // RIGHT SIDE: Login Card
                          Expanded(
                            flex: 5,
                            child: Center(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.only(left: 48),
                                child: ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 430),
                                  child: FadeTransition(
                                    opacity: _fade,
                                    child: SlideTransition(
                                      position: _slide,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _buildCard(),
                                          const SizedBox(height: 20),
                                          _buildFooter(),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopHeroContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Top Brand Pill
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: _accentCyan.withOpacity(0.12),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: _accentCyan.withOpacity(0.35),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: _accentCyan,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'JEEPES SMART TRANSIT NETWORK',
                style: TextStyle(
                  color: _accentCyan,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 26),

        // Main Headline
        const Text(
          'Modernizing PUJ\nTerminal Dispatch &\nFleet Operations.',
          style: TextStyle(
            color: Colors.white,
            fontSize: 44,
            fontWeight: FontWeight.w800,
            height: 1.15,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 18),

        // Supporting Subtitle
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Text(
            'One portal for cooperatives, dispatchers and drivers: live tracking, automated queuing and transparent trip records.',
            style: TextStyle(
              color: Colors.white.withOpacity(0.86),
              fontSize: 16,
              height: 1.55,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
        const SizedBox(height: 36),

        // Feature Bullets
        _buildHeroFeatureRow(
          icon: Icons.qr_code_scanner_rounded,
          accent: _accentCyan,
          title: 'Automated Terminal Queueing',
          subtitle:
              'QR check-in for first-come queues, timed bays and group rotation.',
        ),
        const SizedBox(height: 18),
        _buildHeroFeatureRow(
          icon: Icons.satellite_alt_rounded,
          accent: _accentAmber,
          title: 'Live Fleet Telemetry & Occupancy',
          subtitle:
              'Live speed, routes and seat occupancy for every unit.',
        ),
        const SizedBox(height: 18),
        _buildHeroFeatureRow(
          icon: Icons.verified_user_rounded,
          accent: const Color(0xFF34D399),
          title: 'Safety & Audit Transparency',
          subtitle:
              'Daily pre-trip safety checks and tamper-evident queue logs.',
        ),
      ],
    );
  }

  Widget _buildHeroFeatureRow({
    required IconData icon,
    required Color accent,
    required String title,
    required String subtitle,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.14)),
          ),
          child: Icon(icon, color: accent, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.82),
                  fontSize: 13.5,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // SHARED BACKGROUND & CARD WIDGETS
  // ---------------------------------------------------------------------------

  // Layered background: gradient -> drifting glows -> dot grid -> road + pins
  Widget _buildBackground() {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_bgTop, _bgMid, _bgBottom],
                stops: [0.0, 0.48, 1.0],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _bgController,
              builder: (context, _) => CustomPaint(
                painter: _GlowPainter(
                  t: _bgController.value,
                  cyan: _accentCyan,
                  amber: _accentAmber,
                  indigo: _accentIndigo,
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(painter: _DotGridPainter()),
          ),
        ),
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(painter: _RoadPainter(pinColor: _accentCyan)),
          ),
        ),
      ],
    );
  }

  Widget _buildCard() {
    return Container(
          padding: EdgeInsets.fromLTRB(
            _sc(24),
            _compact ? 18 : _sc(28),
            _sc(24),
            _compact ? 16 : _sc(24),
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(_sc(28)),
            border:
                Border.all(color: Colors.white.withOpacity(0.9), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF020817).withOpacity(0.40),
                blurRadius: 40,
                offset: const Offset(0, 20),
              ),
            ],
          ),
          child: AutofillGroup(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Image.asset(
                      'assets/images/jeepes_logo.png',
                      height: _compact ? 62 : _sc(104),
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: _compact ? 52 : _sc(68),
                        height: _compact ? 52 : _sc(68),
                        decoration: BoxDecoration(
                          color: AppColors.primaryNavy.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: const Icon(
                          Icons.directions_bus_rounded,
                          color: AppColors.primaryNavy,
                          size: 34,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: _compact ? 8 : 14),
                  Text(
                    'Welcome back',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: _sc(21),
                      fontWeight: FontWeight.w800,
                      color: AppColors.darkSlate,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Super Admin · Cooperative · Dispatcher · Driver',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: _sc(12.5),
                      fontWeight: FontWeight.w500,
                      color: AppColors.textMuted,
                    ),
                  ),
                  SizedBox(height: _compact ? 14 : 24),
                  TextFormField(
                    controller: _usernameController,
                    autocorrect: false,
                    enableSuggestions: false,
                    autofillHints: const [AutofillHints.username],
                    textInputAction: TextInputAction.next,
                    onChanged: (_) {
                      if (_errorMessage != null) {
                        setState(() => _errorMessage = null);
                      }
                    },
                    style: TextStyle(
                      fontSize: _sc(15),
                      fontWeight: FontWeight.w600,
                      color: AppColors.darkSlate,
                    ),
                    decoration: _buildInputDecoration(
                      label: 'Username',
                      hint: 'e.g. admin or admin@jeepes.ph',
                      icon: Icons.person_outline_rounded,
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Enter your username or email'
                        : null,
                  ),
                  SizedBox(height: _compact ? 10 : 14),
                  TextFormField(
                    controller: _pinController,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.password],
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(8),
                    ],
                    onChanged: (_) {
                      if (_errorMessage != null) {
                        setState(() => _errorMessage = null);
                      }
                    },
                    onFieldSubmitted: (_) => _handleLogin(),
                    obscureText: _obscurePin,
                    style: TextStyle(
                      fontSize: _sc(16),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 3,
                      color: AppColors.darkSlate,
                    ),
                    decoration: _buildInputDecoration(
                      label: 'Security PIN',
                      hint: '••••',
                      icon: Icons.lock_outline_rounded,
                      suffix: IconButton(
                        splashRadius: 22,
                        icon: Icon(
                          _obscurePin
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 20,
                          color: AppColors.textMuted,
                        ),
                        onPressed: () =>
                            setState(() => _obscurePin = !_obscurePin),
                      ),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Enter your PIN';
                      }
                      if (v.trim().length < 6) {
                        return 'PIN must be at least 6 digits';
                      }
                      return null;
                    },
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: _errorMessage == null
                        ? const SizedBox(width: double.infinity)
                        : _buildInlineError(_errorMessage!),
                  ),
                  SizedBox(height: _compact ? 14 : 20),
                  _buildLoginButton(),
                ],
              ),
            ),
          ),
    );
  }

  Widget _buildInlineError(String message) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.errorCrimson.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.errorCrimson.withOpacity(0.35)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded,
                size: 18, color: AppColors.errorCrimson),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.errorCrimson,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoginButton() {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: _isLoading ? 0.75 : 1,
      child: Container(
        height: _compact ? 48 : 54,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [AppColors.primaryNavy, Color(0xFF2F5BEA)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF2F5BEA).withOpacity(0.38),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _isLoading ? null : _handleLogin,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _isLoading
                    ? const SizedBox(
                        key: ValueKey('loading'),
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.white,
                        ),
                      )
                    : const Row(
                        key: ValueKey('label'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Log In',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                              letterSpacing: 0.3,
                            ),
                          ),
                          SizedBox(width: 8),
                          Icon(Icons.arrow_forward_rounded,
                              color: Colors.white, size: 20),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Column(
      children: [
        Text(
          'Forgot your PIN? Contact your administrator.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Colors.white.withOpacity(0.88),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_user_outlined,
                size: 15, color: Colors.white.withOpacity(0.74)),
            const SizedBox(width: 6),
            Text(
              'Authorized personnel only',
              style: TextStyle(
                fontSize: 12.5,
                letterSpacing: 0.3,
                color: Colors.white.withOpacity(0.74),
              ),
            ),
          ],
        ),
      ],
    );
  }

  InputDecoration _buildInputDecoration({
    required String label,
    required String hint,
    required IconData icon,
    Widget? suffix,
  }) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: color, width: width),
        );

    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: Colors.white,
      labelStyle: const TextStyle(fontSize: 14, color: AppColors.textMuted),
      floatingLabelStyle: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: AppColors.primaryNavy,
      ),
      hintStyle: TextStyle(
        fontSize: 14,
        color: AppColors.textMuted.withOpacity(0.5),
      ),
      prefixIcon: Icon(icon, size: 20, color: AppColors.textMuted),
      suffixIcon: suffix,
      contentPadding:
          EdgeInsets.symmetric(horizontal: 16, vertical: _compact ? 13 : 17),
      border: border(const Color(0xFFCBD5E1)),
      enabledBorder: border(const Color(0xFFCBD5E1)),
      focusedBorder: border(AppColors.primaryNavy, 1.8),
      errorBorder: border(AppColors.errorCrimson),
      focusedErrorBorder: border(AppColors.errorCrimson, 1.8),
    );
  }
}

// -----------------------------------------------------------------------------
// BACKGROUND PAINTERS
// -----------------------------------------------------------------------------

class _GlowPainter extends CustomPainter {
  final double t;
  final Color cyan;
  final Color amber;
  final Color indigo;

  _GlowPainter({
    required this.t,
    required this.cyan,
    required this.amber,
    required this.indigo,
  });

  void _orb(Canvas canvas, Offset center, double radius, Color color) {
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color, color.withOpacity(0)],
      ).createShader(rect);
    canvas.drawCircle(center, radius, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final a = t * 2 * math.pi;
    final w = size.width;
    final h = size.height;
    final baseRadius = math.min(w, h);

    // Cyan, top-right
    _orb(
      canvas,
      Offset(w * (0.88 + 0.05 * math.sin(a)), h * (0.12 + 0.03 * math.cos(a))),
      baseRadius * 0.85,
      cyan.withOpacity(0.32),
    );
    // Indigo, mid-left
    _orb(
      canvas,
      Offset(w * (0.08 + 0.05 * math.cos(a)), h * (0.50 + 0.03 * math.sin(a))),
      baseRadius * 0.80,
      indigo.withOpacity(0.30),
    );
    // Deep indigo, bottom-right (was amber, which turned muddy brown on navy)
    _orb(
      canvas,
      Offset(w * (0.85 + 0.04 * math.sin(a + 2)), h * (0.95 + 0.02 * math.cos(a))),
      baseRadius * 0.75,
      indigo.withOpacity(0.18),
    );
  }

  @override
  bool shouldRepaint(covariant _GlowPainter old) => old.t != t;
}

class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final spacing = (size.width / 15).clamp(22.0, 34.0).toDouble();
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.06)
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    final points = <Offset>[];
    for (double y = spacing / 2; y < size.height; y += spacing) {
      for (double x = spacing / 2; x < size.width; x += spacing) {
        points.add(Offset(x, y));
      }
    }
    canvas.drawPoints(PointMode.points, points, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _RoadPainter extends CustomPainter {
  final Color pinColor;
  _RoadPainter({required this.pinColor});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Wide screens: the road runs along the bottom and up behind the login
    // card, so it never crosses the hero text on the left.
    final wide = w >= 960;
    final path = wide
        ? (Path()
          ..moveTo(-w * 0.10, h * 0.97)
          ..cubicTo(w * 0.30, h * 1.05, w * 0.55, h * 0.92, w * 0.70, h * 0.70)
          ..cubicTo(w * 0.82, h * 0.52, w * 0.80, h * 0.20, w * 1.10, h * 0.02))
        : (Path()
          ..moveTo(-w * 0.10, h * 0.92)
          ..cubicTo(w * 0.45, h * 1.02, w * 0.18, h * 0.50, w * 0.62, h * 0.38)
          ..cubicTo(w * 0.92, h * 0.29, w * 0.85, h * 0.12, w * 1.10, h * 0.04));

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 68 * (w / 400).clamp(0.7, 1.3)
        ..color = Colors.white.withOpacity(0.03),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 54 * (w / 400).clamp(0.7, 1.3)
        ..color = Colors.white.withOpacity(0.05),
    );

    final dashPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.4
      ..color = Colors.white.withOpacity(0.26);

    final metrics = path.computeMetrics().toList();
    for (final m in metrics) {
      double d = 0;
      while (d < m.length) {
        canvas.drawPath(
          m.extractPath(d, math.min(d + 14, m.length)),
          dashPaint,
        );
        d += 28;
      }
    }

    if (metrics.isNotEmpty) {
      final metric = metrics.first;
      for (final t in (wide ? const [0.35, 0.88] : const [0.22, 0.78])) {
        final tangent = metric.getTangentForOffset(metric.length * t);
        if (tangent != null) _drawPin(canvas, tangent.position);
      }
    }
  }

  void _drawPin(Canvas canvas, Offset p) {
    final glowRect = Rect.fromCircle(center: p, radius: 34);
    canvas.drawCircle(
      p,
      34,
      Paint()
        ..shader = RadialGradient(
          colors: [pinColor.withOpacity(0.55), pinColor.withOpacity(0)],
        ).createShader(glowRect),
    );
    canvas.drawCircle(
      p,
      18,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withOpacity(0.25),
    );
    canvas.drawCircle(
      p,
      9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withOpacity(0.9),
    );
    canvas.drawCircle(p, 5, Paint()..color = pinColor);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}