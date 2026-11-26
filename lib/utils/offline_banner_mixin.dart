import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

/// Mix this into any [State] to get a live [_isOnline] flag and a
/// [buildOfflineBanner] helper that renders an amber "No internet" bar.
///
/// Usage:
///   class _MyScreenState extends State<MyScreen> with OfflineBannerMixin {
///     @override void initState() { super.initState(); initConnectivity(); }
///     @override void dispose()   { disposeConnectivity(); super.dispose(); }
///   }
///
/// Then in your build, insert `buildOfflineBanner()` at the top of the body
/// Column (before any Scaffold body content).
mixin OfflineBannerMixin<T extends StatefulWidget> on State<T> {
  bool _isOnline = true;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// Call from [initState] after [super.initState()].
  void initConnectivity() {
    // Check current status immediately.
    Connectivity().checkConnectivity().then((results) {
      if (mounted) {
        setState(() => _isOnline = _hasConnection(results));
      }
    });
    // Then listen for changes.
    _connectivitySub = Connectivity()
        .onConnectivityChanged
        .listen((results) {
      if (!mounted) return;
      final online = _hasConnection(results);
      if (online != _isOnline) setState(() => _isOnline = online);
    });
  }

  /// Call from [dispose] before [super.dispose()].
  void disposeConnectivity() {
    _connectivitySub?.cancel();
  }

  bool _hasConnection(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  /// Renders a slim amber banner when offline; returns [SizedBox.shrink]
  /// when the device is online (zero layout cost).
  Widget buildOfflineBanner() {
    if (_isOnline) return const SizedBox.shrink();
    return Material(
      color: const Color(0xFFFEF3C7), // amber-100
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.wifi_off_rounded,
                size: 16, color: Color(0xFF92400E)),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'No internet connection — data may be outdated. '
                'Your last action will sync when you reconnect.',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF78350F),
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
