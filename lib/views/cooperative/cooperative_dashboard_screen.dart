import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;

import '../auth/login_screen.dart';
import '../../utils/staff_auth.dart';
import '../../utils/app_colors.dart';
import 'rotation_master_list.dart';
import 'route_process_config.dart';
import 'coop_ui.dart';
import 'driver_suspension.dart';


// ── Navigation model ─────────────────────────────────────────────────────────
// Seven tabs became five destinations (six when the coop owns a rotation).
// Drivers + Dispatchers live under People; Complaints + Queue audits under Reports.
enum _Section { overview, fleet, map, people, reports, rotation }

extension _SectionInfo on _Section {
  String get label {
    switch (this) {
      case _Section.overview: return 'Overview';
      case _Section.fleet: return 'Fleet';
      case _Section.map: return 'Live map';
      case _Section.people: return 'People';
      case _Section.reports: return 'Reports';
      case _Section.rotation: return 'Rotation';
    }
  }

  String get title => label;

  String get subtitle {
    switch (this) {
      case _Section.overview: return 'How the cooperative is running right now';
      case _Section.fleet: return 'Every jeepney enrolled under your cooperative';
      case _Section.map: return 'Where your units are at this moment';
      case _Section.people: return 'Your drivers and terminal dispatchers';
      case _Section.reports: return 'Passenger complaints and queue changes';
      case _Section.rotation: return 'Queue order for the routes you own';
    }
  }

  IconData get icon {
    switch (this) {
      case _Section.overview: return Icons.space_dashboard_outlined;
      case _Section.fleet: return Icons.directions_bus_outlined;
      case _Section.map: return Icons.map_outlined;
      case _Section.people: return Icons.groups_outlined;
      case _Section.reports: return Icons.fact_check_outlined;
      case _Section.rotation: return Icons.autorenew_rounded;
    }
  }

  IconData get selectedIcon {
    switch (this) {
      case _Section.overview: return Icons.space_dashboard_rounded;
      case _Section.fleet: return Icons.directions_bus_rounded;
      case _Section.map: return Icons.map_rounded;
      case _Section.people: return Icons.groups_rounded;
      case _Section.reports: return Icons.fact_check_rounded;
      case _Section.rotation: return Icons.autorenew_rounded;
    }
  }
}

class _PrimaryAction {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _PrimaryAction(this.label, this.icon, this.onTap);
}

class CooperativeDashboardScreen extends StatefulWidget {
  final String userId;
  final Map<String, dynamic> userData;

  const CooperativeDashboardScreen({
    super.key,
    required this.userId,
    required this.userData,
  });

  @override
  State<CooperativeDashboardScreen> createState() =>
      _CooperativeDashboardScreenState();
}

class _CooperativeDashboardScreenState extends State<CooperativeDashboardScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  String _coopId = '';
  String _coopName = 'Transport Cooperative';
  String _fullName = 'Operations Office';
  String _username = '';

  // Tab 1: Fleet Search & Filter
  String _fleetSearchQuery = '';
  String _fleetStatusFilter = 'ALL';
  String _fleetRouteFilter = 'ALL';

  // Tab 3: Dispatchers Search & Filter
  String _dispatcherSearchQuery = '';
  String _dispatcherTerminalFilter = 'ALL';

  // Tab 4: Drivers Search
  String _driverSearchQuery = '';

  // Search boxes keep their own controllers, and every Firestore stream used by
  // a searchable tab is created ONCE. Creating a stream inside build() meant
  // every keystroke (and the keyboard opening) resubscribed, flashed the
  // spinner and destroyed the search box, so typing never worked.
  final TextEditingController _fleetSearchCtrl = TextEditingController();
  final TextEditingController _driverSearchCtrl = TextEditingController();
  final TextEditingController _dispatcherSearchCtrl = TextEditingController();
  final TextEditingController _auditSearchCtrl = TextEditingController();

  late final Stream<QuerySnapshot> _vehiclesStream =
      FirebaseFirestore.instance.collection('vehicles_live').snapshots();
  // Overview tab: People / Reports sub-switches and the complaints stream.
  int _peopleSegment = 0;
  int _reportsSegment = 0;
  // The Overview tab gets its OWN streams. Firestore streams do not replay
  // their last value to a second listener, so sharing one stream between the
  // Overview and the Fleet / People / Reports tabs left whichever tab opened
  // second stuck on its loading spinner.
  late final Stream<QuerySnapshot> _ovVehiclesStream =
      FirebaseFirestore.instance.collection('vehicles_live').snapshots();
  late final Stream<QuerySnapshot> _ovDriversStream = FirebaseFirestore.instance
      .collection('users')
      .where('role', isEqualTo: 'DRIVER')
      .snapshots();
  late final Stream<QuerySnapshot> _ovDispatchersStream = FirebaseFirestore
      .instance
      .collection('users')
      .where('role', isEqualTo: 'DISPATCHER')
      .snapshots();
  late final Stream<QuerySnapshot> _ovComplaintsStream =
      FirebaseFirestore.instance.collection('complaints').snapshots();
  Stream<QuerySnapshot>? _ovAuditStream;
  String _ovAuditCoop = '';
  Stream<QuerySnapshot> _overviewAuditStream() {
    if (_ovAuditStream == null || _ovAuditCoop != _coopId) {
      _ovAuditCoop = _coopId;
      _ovAuditStream = FirebaseFirestore.instance
          .collection('queue_audit_logs')
          .where('affected_cooperative_ids', arrayContains: _coopId)
          .snapshots();
    }
    return _ovAuditStream!;
  }

  late final Stream<QuerySnapshot> _driversStream = FirebaseFirestore.instance
      .collection('users')
      .where('role', isEqualTo: 'DRIVER')
      .snapshots();
  late final Stream<QuerySnapshot> _dispatchersStream = FirebaseFirestore
      .instance
      .collection('users')
      .where('role', isEqualTo: 'DISPATCHER')
      .snapshots();

  Stream<QuerySnapshot>? _auditStream;
  String _auditStreamCoop = '';
  Stream<QuerySnapshot> _auditLogStream() {
    if (_auditStream == null || _auditStreamCoop != _coopId) {
      _auditStreamCoop = _coopId;
      _auditStream = FirebaseFirestore.instance
          .collection('queue_audit_logs')
          .where('affected_cooperative_ids', arrayContains: _coopId)
          .snapshots();
    }
    return _auditStream!;
  }

  // Tab 5: Queue Audit Filter
  String _auditSearchQuery = '';
  String _auditTypeFilter = 'ALL';

  // Tab 6: Complaints Filtering State
  String _selectedStatusFilter = 'ALL';
  String _selectedDateFilter = '7DAYS';
  DateTimeRange? _customDateRange;

  static const LatLng _defaultAntiqueCenter = LatLng(10.7420, 121.9470);

  // Set after the coop edits its CPC so the change applies immediately,
  // without needing to log out and back in.
  String? _cpcOverride;

  // Coop CPC / Prangkisa number. No hard-coded fallback: if the coop has not
  // set one, this is empty and enrollment is blocked until they set it.
  String get _coopCpc {
    if (_cpcOverride != null) return _cpcOverride!;
    final direct = widget.userData['franchise_case_number'] ??
        widget.userData['cpc_case_number'];
    return (direct ?? '').toString().trim();
  }

  bool get _hasCpc => _coopCpc.isNotEmpty;

  // Reads the logged-in coop's authorized routes array dynamically from Firestore
  List<String> get _coopAuthorizedRoutes {
    final raw = widget.userData['authorized_routes'];
    if (raw is List) {
      final list = raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
      if (list.isNotEmpty) return list;
    }
    return ['ROUTE_GUINSANGAN'];
  }

  // Formats route IDs into clean display names without exposing raw IDs
  String _formatRouteDisplayName(String rawRouteId) {
    String clean = rawRouteId.replaceAll('ROUTE_', '').replaceAll('_', ' ').trim();

    if (clean.toUpperCase() == 'GUINSANGAN') {
      return 'San Jose - Guinsang-an';
    }

    final words = clean.toLowerCase().split(' ').map((w) {
      if (w.isEmpty) return '';
      return '${w[0].toUpperCase()}${w.substring(1)}';
    }).join(' ');

    if (words.toLowerCase().startsWith('san jose')) {
      return words;
    }
    return 'San Jose - $words';
  }
  

  @override
  void initState() {
    super.initState();
    // _syncUserData first: the tab count depends on the coop id + routes.
    _syncUserData();
    _tabController = TabController(length: _tabCount, vsync: this);
    _tabController.addListener(_onTabChanged);
    
  }
  

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant CooperativeDashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncUserData();
    // The Rotation tab only exists when this coop owns a rotation route.
    if (_tabController.length != _tabCount) {
      final keep = _tabController.index.clamp(0, _tabCount - 1);
      _tabController.removeListener(_onTabChanged);
      _tabController.dispose();
      _tabController = TabController(
          length: _tabCount, vsync: this, initialIndex: keep);
      _tabController.addListener(_onTabChanged);
    }
  }

  // Routes this coop owns a rotation for (driven by RouteProcesses).
  List<RouteProcessConfig> get _rotationRoutes =>
      RouteProcesses.rotationRoutesForCoop(_coopId, _coopAuthorizedRoutes);

  // 5 destinations + Rotation (only when the coop owns a rotation route).
  int get _tabCount => _rotationRoutes.isEmpty ? 5 : 6;

  void _syncUserData() {
    _coopId = (widget.userData['cooperative_id'] ?? widget.userId).toString().trim();
    _coopName = (widget.userData['cooperative_name'] ?? 'Transport Cooperative').toString().trim();
    _fullName = (widget.userData['full_name'] ?? 'Operations Office').toString().trim();
    _username = (widget.userData['username'] ?? '').toString().trim();
  }

  @override
  void dispose() {
    _fleetSearchCtrl.dispose();
    _driverSearchCtrl.dispose();
    _dispatcherSearchCtrl.dispose();
    _auditSearchCtrl.dispose();
    _tabController.dispose();
    super.dispose();
  }

  String _normalizePlate(String plate) {
    return plate.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  }

  Widget _ts(BuildContext context, Widget child) {
    final mq = MediaQuery.of(context);
    final bool narrow = mq.size.width < 360;
    return MediaQuery(
      data: mq.copyWith(
        textScaler: mq.textScaler.clamp(
          minScaleFactor: 0.95,
          maxScaleFactor: narrow ? 1.15 : 1.3,
        ),
      ),
      child: child,
    );
  }

  double _dialogMaxHeight(BuildContext context, double cap) {
    final h = MediaQuery.of(context).size.height;
    return (h * 0.9).clamp(240.0, cap).toDouble();
  }

  bool _matchesCooperative(Map<String, dynamic> data) {
    final docCoopName = (data['cooperative_name'] ?? '').toString().trim().toLowerCase();
    final docCoopId = (data['cooperative_id'] ?? '').toString().trim().toLowerCase();

    final targetName = _coopName.toLowerCase();
    final targetId = _coopId.toLowerCase();

    if (docCoopId.isNotEmpty && docCoopId == targetId) return true;
    if (docCoopName.isNotEmpty &&
        (docCoopName == targetName ||
            docCoopName.contains(targetName) ||
            targetName.contains(docCoopName))) {
      return true;
    }
    return false;
  }

  String _formatTerminalName(String raw) {
    final clean = raw.trim().toUpperCase();
    if (clean.contains('ROBINSON')) return 'Robinsons Terminal';
    if (clean.contains('DALIPE_1') || clean.contains('DALIPE 1')) return 'Dalipe 1 (Northbound)';
    if (clean.contains('DALIPE_2') || clean.contains('DALIPE 2')) return 'Dalipe 2 (Southbound)';
    if (clean.contains('DALIPE')) return 'Dalipe Terminal';
    return clean.replaceAll('TERM_', '').replaceAll('_', ' ');
  }

  String _formatRouteName(String raw) {
    final clean = raw.trim();
    return clean.replaceAll('ROUTE_', '').replaceAll('_', ' ');
  }

  Color _resolveVehicleDotColor(String? colorStr) {
    if (colorStr == null || colorStr.trim().isEmpty) return const Color(0xFF10B981);
    final c = colorStr.toLowerCase();
    if (c.contains('red') || c.contains('crimson')) return const Color(0xFFEF4444);
    if (c.contains('blue') || c.contains('navy')) return const Color(0xFF2563EB);
    if (c.contains('green')) return const Color(0xFF10B981);
    if (c.contains('yellow') || c.contains('gold')) return const Color(0xFFF59E0B);
    if (c.contains('orange')) return const Color(0xFFF97316);
    if (c.contains('purple') || c.contains('violet')) return const Color(0xFF8B5CF6);
    return const Color(0xFF10B981);
  }

  // ===========================================================================
  // MODAL: CREATE NOTICE / BROADCAST ANNOUNCEMENT
  // ===========================================================================
  Future<void> _showCreateNoticeModal({
    String? preselectedUserId,
    String? preselectedUserName,
    String? preselectedRole,
  }) async {
    final formKey = GlobalKey<FormState>();
    final titleController = TextEditingController();
    final messageController = TextEditingController();

    String targetMode = preselectedUserId != null ? 'INDIVIDUAL' : 'BROADCAST_ALL';
    String priority = 'NORMAL'; // 'NORMAL' or 'URGENT'
    String? selectedUserId = preselectedUserId;
    String? selectedUserName = preselectedUserName;
    String? selectedUserRole = preselectedRole;
    bool isSaving = false;

    // Fetch all drivers and dispatchers of this cooperative
    List<Map<String, dynamic>> coopPersonnel = [];
    try {
      final snap = await FirebaseFirestore.instance.collection('users').get();
      coopPersonnel = snap.docs
          .where((d) => _matchesCooperative(d.data()))
          .where((d) {
            final r = (d.data()['role'] ?? '').toString().toUpperCase();
            return r == 'DRIVER' || r == 'DISPATCHER';
          })
          .map((d) {
            final data = d.data();
            return {
              'id': d.id,
              'name': (data['full_name'] ?? d.id).toString(),
              'role': (data['role'] ?? 'MEMBER').toString().toUpperCase(),
            };
          })
          .toList();
    } catch (_) {}
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setModalState) {
          return SafeArea(
            child: Dialog(
              backgroundColor: Colors.white,
              elevation: 8,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: priority == 'URGENT'
                                    ? const Color(0xFFFEE2E2)
                                    : const Color(0xFFEFF6FF),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.campaign_rounded,
                                color: priority == 'URGENT'
                                    ? AppColors.errorCrimson
                                    : const Color(0xFF2563EB),
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    preselectedUserId != null
                                        ? 'Issue Individual Notice'
                                        : 'Post Notice / Announcement',
                                    style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, color: AppColors.darkSlate),
                                  ),
                                  Text(
                                    preselectedUserId != null
                                        ? 'Direct memo to $preselectedUserName'
                                        : 'Broadcast to cooperative drivers & dispatchers',
                                    style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.textMuted),
                              onPressed: () => Navigator.pop(dialogCtx),
                            ),
                          ],
                        ),
                        const Divider(height: 20, color: AppColors.borderSubtle),

                        // Priority Switcher
                        Row(
                          children: [
                            const Text('Priority:', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: AppColors.darkSlate)),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('Normal (Notice)', style: TextStyle(fontSize: 12)),
                              selected: priority == 'NORMAL',
                              selectedColor: const Color(0xFFEFF6FF),
                              onSelected: (val) => setModalState(() => priority = 'NORMAL'),
                            ),
                            const SizedBox(width: 6),
                            ChoiceChip(
                              label: const Text('Urgent (Warning)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              selected: priority == 'URGENT',
                              selectedColor: const Color(0xFFFEE2E2),
                              labelStyle: TextStyle(color: priority == 'URGENT' ? AppColors.errorCrimson : AppColors.darkSlate),
                              onSelected: (val) => setModalState(() => priority = 'URGENT'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),

                        // Target Audience Selector
                        DropdownButtonFormField<String>(
                          value: targetMode,
                          isDense: true,
                          isExpanded: true,
                          decoration: _buildInputDeco('Recipient / Target Audience *', Icons.people_outline_rounded),
                          items: const [
                            DropdownMenuItem(value: 'BROADCAST_ALL', child: Text('Broadcast to All (Drivers & Dispatchers)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
                            DropdownMenuItem(value: 'BROADCAST_DRIVERS', child: Text('All Drivers Only', style: TextStyle(fontSize: 13))),
                            DropdownMenuItem(value: 'BROADCAST_DISPATCHERS', child: Text('All Dispatchers Only', style: TextStyle(fontSize: 13))),
                            DropdownMenuItem(value: 'INDIVIDUAL', child: Text('Specific Individual Personnel', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              setModalState(() {
                                targetMode = val;
                                if (val != 'INDIVIDUAL') {
                                  selectedUserId = null;
                                  selectedUserName = null;
                                  selectedUserRole = null;
                                }
                              });
                            }
                          },
                        ),
                        const SizedBox(height: 10),

                        // Specific Personnel Picker (Conditional)
                        if (targetMode == 'INDIVIDUAL') ...[
                          DropdownButtonFormField<String>(
                            value: selectedUserId,
                            isDense: true,
                            isExpanded: true,
                            decoration: _buildInputDeco('Select Driver or Dispatcher *', Icons.person_search_rounded),
                            hint: const Text('Choose personnel...', style: TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
                            items: coopPersonnel.map((p) {
                              return DropdownMenuItem<String>(
                                value: p['id'].toString(),
                                child: Text(
                                  '${p['name']} (${p['role']})',
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                              );
                            }).toList(),
                            onChanged: (val) {
                              if (val != null) {
                                final match = coopPersonnel.firstWhere((p) => p['id'] == val);
                                setModalState(() {
                                  selectedUserId = val;
                                  selectedUserName = match['name'];
                                  selectedUserRole = match['role'];
                                });
                              }
                            },
                            validator: (v) => (targetMode == 'INDIVIDUAL' && (v == null || v.isEmpty))
                                ? 'Please select a recipient'
                                : null,
                          ),
                          const SizedBox(height: 10),
                        ],

                        // Title
                        TextFormField(
                          controller: titleController,
                          textCapitalization: TextCapitalization.sentences,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                          decoration: _buildInputDeco('Subject / Notice Title *', Icons.title_rounded, hint: 'e.g. Schedule Change, Meeting Notice, or Caution'),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'Title is required' : null,
                        ),
                        const SizedBox(height: 10),

                        // Message Body
                        TextFormField(
                          controller: messageController,
                          maxLines: 4,
                          textCapitalization: TextCapitalization.sentences,
                          style: const TextStyle(fontSize: 13, height: 1.3),
                          decoration: _buildInputDeco('Notice Message *', Icons.notes_rounded, hint: 'Provide details, instructions, date/time, or warnings...'),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'Message content is required' : null,
                        ),
                        const SizedBox(height: 18),

                        Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 42,
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(color: AppColors.borderSubtle),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  onPressed: isSaving ? null : () => Navigator.pop(dialogCtx),
                                  child: const Text('Cancel', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.darkSlate)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SizedBox(
                                height: 42,
                                child: ElevatedButton.icon(
                                  icon: const Icon(Icons.send_rounded, size: 16),
                                  label: Text(
                                    targetMode == 'INDIVIDUAL' ? 'Send Notice' : 'Post Broadcast',
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: priority == 'URGENT' ? AppColors.errorCrimson : AppColors.primaryNavy,
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  onPressed: isSaving
                                      ? null
                                      : () async {
                                          if (!formKey.currentState!.validate()) return;
                                          setModalState(() => isSaving = true);

                                          try {
                                            await FirebaseFirestore.instance.collection('notices').add({
                                              'cooperative_id': _coopId,
                                              'cooperative_name': _coopName,
                                              'author_name': _fullName,
                                              'title': titleController.text.trim(),
                                              'message': messageController.text.trim(),
                                              'priority': priority,
                                              'target_mode': targetMode,
                                              'target_audience': targetMode == 'BROADCAST_DRIVERS'
                                                  ? 'DRIVERS'
                                                  : (targetMode == 'BROADCAST_DISPATCHERS' ? 'DISPATCHERS' : 'ALL'),
                                              'target_user_id': selectedUserId,
                                              'target_user_name': selectedUserName,
                                              'target_role': selectedUserRole,
                                              'created_at': FieldValue.serverTimestamp(),
                                            });

                                            if (!mounted) return;
                                            Navigator.pop(dialogCtx);
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  targetMode == 'INDIVIDUAL'
                                                      ? 'Notice sent to $selectedUserName.'
                                                      : 'Broadcast announcement published.',
                                                ),
                                                backgroundColor: const Color(0xFF059669),
                                              ),
                                            );
                                          } catch (e) {
                                            setModalState(() => isSaving = false);
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(content: Text('Failed: $e'), backgroundColor: AppColors.errorCrimson),
                                            );
                                          }
                                        },
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
      ),
    );
  }

  // ===========================================================================
  // MODAL: DRIVER FULL PROFILE & VERIFIED LTO CARD INSPECTOR
  // ===========================================================================
  void _showDriverDetailModal(Map<String, dynamic> dData, String driverId) {
    final fullName = (dData['full_name'] ?? driverId).toString();
    final username = (dData['username'] ?? '').toString();
    final licenseNumber = (dData['license_number'] ?? 'N/A').toString();
    final assignedVehicle = (dData['assigned_vehicle'] ?? 'UNASSIGNED').toString();
    final sex = (dData['sex'] ?? 'UNSPECIFIED').toString();
    final isVerified = dData['is_license_verified'] == true;
    final pin = (dData['pin_code'] ?? '****').toString();
    final cardBase64 = dData['license_card_base64'] as String?;
    final contact = (dData['contact_number'] ?? 'Not provided').toString();

    Timestamp? verifiedAt = dData['license_verified_at'] as Timestamp?;
    String verifiedDateStr = verifiedAt != null
        ? verifiedAt.toDate().toLocal().toString().substring(0, 16)
        : 'Registered';

    Uint8List? cardBytes;
    if (cardBase64 != null && cardBase64.isNotEmpty) {
      try {
        cardBytes = base64Decode(cardBase64);
      } catch (_) {}
    }

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => SafeArea(
        child: Dialog(
          backgroundColor: Colors.white,
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.borderSubtle),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 720),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: isVerified
                            ? const Color(0xFFECFDF5)
                            : AppColors.primaryNavy.withOpacity(0.08),
                        child: Icon(
                          Icons.person_rounded,
                          color: isVerified ? const Color(0xFF059669) : AppColors.primaryNavy,
                          size: 26,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    fullName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.darkSlate,
                                    ),
                                  ),
                                ),
                                if (isVerified) ...[
                                  const SizedBox(width: 6),
                                  const Icon(Icons.verified_rounded, size: 18, color: Color(0xFF059669)),
                                ],
                              ],
                            ),
                            Text(
                              'ID: $driverId • @$username',
                              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close_rounded, size: 22, color: AppColors.textMuted),
                        onPressed: () => Navigator.pop(dialogCtx),
                      ),
                    ],
                  ),
                  const Divider(height: 24, color: AppColors.borderSubtle),

                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: isVerified ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isVerified ? const Color(0xFFA7F3D0) : const Color(0xFFFECACA),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isVerified ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                          size: 18,
                          color: isVerified ? const Color(0xFF059669) : const Color(0xFFDC2626),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isVerified
                                ? 'Compliant & Verified with LTO Driver\'s License ($verifiedDateStr)'
                                : 'Pending physical LTO License accreditation',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isVerified ? const Color(0xFF065F46) : const Color(0xFF991B1B),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  if (cardBytes != null) ...[
                    const Text(
                      'Physical LTO License Card Record',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: AppColors.borderSubtle),
                        ),
                        child: Image.memory(
                          cardBytes,
                          height: 190,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],

                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundSlate,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.borderSubtle),
                    ),
                    child: Column(
                      children: [
                        _buildDetailRow(Icons.credit_card_rounded, 'LTO License No.', licenseNumber),
                        const Divider(height: 16, color: AppColors.borderSubtle),
                        _buildDetailRow(Icons.wc_rounded, 'Sex', sex),
                        const Divider(height: 16, color: AppColors.borderSubtle),
                        _buildDetailRow(Icons.phone_outlined, 'Contact Number', contact),
                        const Divider(height: 16, color: AppColors.borderSubtle),
                        _buildDetailRow(Icons.directions_bus_rounded, 'Assigned Jeepney', assignedVehicle),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),

                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.campaign_rounded, size: 17),
                          label: const Text('Send Notice', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFD97706),
                            side: const BorderSide(color: Color(0xFFD97706)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: () {
                            Navigator.pop(dialogCtx);
                            _showCreateNoticeModal(
                              preselectedUserId: driverId,
                              preselectedUserName: fullName,
                              preselectedRole: 'DRIVER',
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.swap_horiz_rounded, size: 17),
                          label: const Text('Reassign', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.commuterTeal,
                            side: const BorderSide(color: AppColors.commuterTeal),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: () {
                            Navigator.pop(dialogCtx);
                            if (assignedVehicle != 'UNASSIGNED') {
                              _showAssignDriverModal(
                                vehicleId: assignedVehicle,
                                currentDriverId: driverId,
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Assign vehicle directly from the Fleet tab.'),
                                  backgroundColor: AppColors.primaryNavy,
                                ),
                              );
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.lock_reset_rounded, size: 17),
                          label: const Text('Reset PIN', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.primaryNavy,
                            side: const BorderSide(color: AppColors.primaryNavy),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: () {
                            Navigator.pop(dialogCtx);
                            _showResetPinModal(
                              targetUserId: driverId,
                              targetUserName: fullName,
                              targetRole: 'Driver',
                              currentPin: pin,
                            );
                          },
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
  }

  // ===========================================================================
  // MODAL: JEEPNEY DETAILS & LIVE MINI-MAP
  // ===========================================================================
  void _showVehicleDetailModal(Map<String, dynamic> vData, String docId) {
    final plate = (vData['plate_number'] ?? docId).toString();
    final jeepName = (vData['vehicle_name'] ?? plate).toString();
    final driverName = (vData['driver_name'] ?? 'Unassigned Driver').toString();
    final ownerName = (vData['member_owner'] ?? vData['operator_name'] ?? 'Coop Member').toString();
    final ownerContact = (vData['member_owner_contact'] ?? 'N/A').toString();
    final status = (vData['current_status'] ?? 'STANDBY').toString().toUpperCase();
    final isEnRoute = status == 'EN_ROUTE';
    final route = _formatRouteName((vData['route_id'] ?? 'UNASSIGNED').toString());
    final speed = (vData['speed_kmh'] as num?)?.toInt() ?? 0;
    final seats = (vData['passenger_count'] as num?)?.toInt() ?? 0;
    final maxSeats = (vData['max_capacity'] as num?)?.toInt() ?? 20;
    final cpc = (vData['franchise_case_number'] ?? _coopCpc).toString();
    final dotColor = _resolveVehicleDotColor(vData['vehicle_color']?.toString());
    final vehicleColor = (vData['vehicle_color'] ?? 'Standard').toString();

    final loc = vData['location'] as Map<String, dynamic>?;
    double? rawLat;
    double? rawLng;

    if (loc != null && loc['latitude'] != null && loc['longitude'] != null) {
      rawLat = (loc['latitude'] as num).toDouble();
      rawLng = (loc['longitude'] as num).toDouble();
    } else if (vData['latitude'] != null && vData['longitude'] != null) {
      rawLat = (vData['latitude'] as num).toDouble();
      rawLng = (vData['longitude'] as num).toDouble();
    }

    final double? safeLat = rawLat;
    final double? safeLng = rawLng;
    final hasCoordinates = safeLat != null && safeLng != null;
    final LatLng unitCoord = (safeLat != null && safeLng != null)
        ? LatLng(safeLat, safeLng)
        : _defaultAntiqueCenter;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        return SafeArea(
          maintainBottomViewPadding: true,
          child: Dialog(
            backgroundColor: Colors.white,
            elevation: 8,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: const BorderSide(color: AppColors.borderSubtle),
            ),
            insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: isEnRoute ? const Color(0xFFECFDF5) : const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.directions_bus_rounded,
                            color: isEnRoute ? const Color(0xFF059669) : const Color(0xFF2563EB),
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                jeepName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.darkSlate,
                                ),
                              ),
                              Text(
                                'Route: $route',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                              ),
                            ],
                          ),
                        ),
                        _buildLicenseBadge(plate, fontSize: 12),
                        const SizedBox(width: 4),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.textMuted),
                          onPressed: () => Navigator.pop(dialogCtx),
                        ),
                      ],
                    ),
                    const Divider(height: 20, color: AppColors.borderSubtle),

                    Container(
                      height: 190,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE2E8F0),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        children: [
                          FlutterMap(
                            options: MapOptions(
                              initialCenter: unitCoord,
                              initialZoom: hasCoordinates ? 14.5 : 12.0,
                            ),
                            children: [
                              TileLayer(
                                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                userAgentPackageName: 'com.example.puj_dispatch_system',
                              ),
                              if (hasCoordinates)
                                MarkerLayer(
                                  markers: [
                                    Marker(
                                      point: unitCoord,
                                      width: 140,
                                      height: 56,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: AppColors.primaryNavy.withOpacity(0.92),
                                              borderRadius: BorderRadius.circular(4),
                                              border: Border.all(color: Colors.white, width: 0.8),
                                              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
                                            ),
                                            child: Text(
                                              '$plate • $speed km/h',
                                              maxLines: 1,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Container(
                                            width: 14,
                                            height: 14,
                                            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                          Positioned(
                            bottom: 6,
                            left: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.primaryNavy.withOpacity(0.90),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                hasCoordinates
                                    ? 'Hardware Telemetry Active • $speed km/h'
                                    : 'Awaiting Live Hardware GPS Fix',
                                style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.backgroundSlate,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('STATUS', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: AppColors.textMuted)),
                              const SizedBox(height: 2),
                              Text(
                                isEnRoute ? 'BIYAHE • EN ROUTE' : 'STANDBY',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: isEnRoute ? const Color(0xFF059669) : const Color(0xFF2563EB),
                                ),
                              ),
                            ],
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Text('OCCUPANCY', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: AppColors.textMuted)),
                              const SizedBox(height: 2),
                              Text(
                                '$seats / $maxSeats Seats',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: seats >= maxSeats ? AppColors.errorCrimson : AppColors.darkSlate,
                                ),
                              ),
                            ],
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Text('COLOR', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: AppColors.textMuted)),
                              const SizedBox(height: 2),
                              Text(
                                vehicleColor,
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: Column(
                        children: [
                          _buildDetailRow(Icons.person_rounded, 'Driver', driverName),
                          const Divider(height: 14, color: AppColors.borderSubtle),
                          _buildDetailRow(Icons.person_pin_circle_outlined, 'Member Owner', ownerName),
                          const Divider(height: 14, color: AppColors.borderSubtle),
                          _buildDetailRow(Icons.phone_outlined, 'Owner Contact', ownerContact),
                          const Divider(height: 14, color: AppColors.borderSubtle),
                          _buildDetailRow(Icons.verified_user_outlined, 'Franchise CPC', cpc),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    SizedBox(
                      height: 42,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.swap_horiz_rounded, size: 17),
                        label: const Text('Assign / Change Driver', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.commuterTeal,
                          side: const BorderSide(color: AppColors.commuterTeal),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: () {
                          Navigator.pop(dialogCtx);
                          _showAssignDriverModal(
                            vehicleId: docId,
                            currentDriverId: vData['driver_id']?.toString(),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),

                    SizedBox(
                      height: 42,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryNavy,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          elevation: 0,
                        ),
                        onPressed: () => Navigator.pop(dialogCtx),
                        child: const Text('Close Overview', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
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
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.primaryNavy),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
        const Spacer(),
        Expanded(
          flex: 2,
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.darkSlate),
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // TAB 4: DRIVERS ROSTER
  // ===========================================================================
  Widget _buildDriversTab() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isDesktop = constraints.maxWidth >= 850;

        return StreamBuilder<QuerySnapshot>(
          stream: _driversStream,
          builder: (context, snapshot) {
            if (!snapshot.hasData && !snapshot.hasError) {
              return const Center(child: CircularProgressIndicator(color: AppColors.commuterTeal));
            }

            final allDocs = snapshot.data?.docs.where((d) => _matchesCooperative(d.data() as Map<String, dynamic>)).toList() ?? [];

            bool hasVehicleOf(Map<String, dynamic> d) {
              final v = (d['assigned_vehicle'] ?? 'UNASSIGNED').toString();
              return v.isNotEmpty && v != 'UNASSIGNED' && v != 'None';
            }

            final assignedCount = allDocs.where((d) => hasVehicleOf(d.data() as Map<String, dynamic>)).length;
            final unassignedCount = allDocs.length - assignedCount;

            final docs = allDocs.where((d) {
              final data = d.data() as Map<String, dynamic>;
              final name = (data['full_name'] ?? '').toString().toLowerCase();
              final username = (data['username'] ?? '').toString().toLowerCase();
              final license = (data['license_number'] ?? '').toString().toLowerCase();
              final q = _driverSearchQuery.trim().toLowerCase();
              if (q.isNotEmpty && !name.contains(q) && !username.contains(q) && !license.contains(q)) {
                return false;
              }
              return true;
            }).toList();

            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: ListView(
                  padding: const EdgeInsets.only(left: 18, right: 18, top: 18, bottom: 90),
                  children: [
                    Row(
                      children: [
                        _buildKpiCard('DRIVERS', '${allDocs.length}', Icons.badge_rounded, AppColors.primaryNavy, isDesktop: isDesktop),
                        const SizedBox(width: 8),
                        _buildKpiCard('ASSIGNED', '$assignedCount', Icons.directions_bus_rounded, const Color(0xFF059669), isDesktop: isDesktop),
                        const SizedBox(width: 8),
                        _buildKpiCard('UNASSIGNED', '$unassignedCount', Icons.person_off_outlined, const Color(0xFFD97706), isDesktop: isDesktop),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 42,
                      child: TextField(
                        controller: _driverSearchCtrl,
                        onChanged: (val) => setState(() => _driverSearchQuery = val),
                        style: const TextStyle(fontSize: 13.5),
                        decoration: InputDecoration(
                          hintText: 'Search driver by name, @username, or license...',
                          hintStyle: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
                          prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppColors.textMuted),
                          contentPadding: EdgeInsets.zero,
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.borderSubtle)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.borderSubtle)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    if (docs.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(32.0),
                        child: Center(
                          child: Text(
                            allDocs.isEmpty
                                ? 'No drivers enrolled yet. Tap "Add Driver" to register one.'
                                : 'No drivers match your search.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
                          ),
                        ),
                      )
                    else if (isDesktop)
                      GridView.builder(
                        physics: const NeverScrollableScrollPhysics(),
                        shrinkWrap: true,
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 580,
                          mainAxisExtent: 145,
                          crossAxisSpacing: 14,
                          mainAxisSpacing: 14,
                        ),
                        itemCount: docs.length,
                        itemBuilder: (context, index) {
                          final doc = docs[index];
                          return _buildDriverCard(doc, hasVehicleOf, inGrid: true);
                        },
                      )
                    else
                      ...docs.map((doc) => _buildDriverCard(doc, hasVehicleOf, inGrid: false)),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDriverCard(QueryDocumentSnapshot doc, bool Function(Map<String, dynamic>) hasVehicleOf, {bool inGrid = false}) {
    final d = doc.data() as Map<String, dynamic>;
    final name = (d['full_name'] ?? doc.id).toString();
    final username = (d['username'] ?? '').toString();
    final license = (d['license_number'] ?? 'N/A').toString();
    final assignedVehicle = (d['assigned_vehicle'] ?? 'UNASSIGNED').toString();
    final isVerified = d['is_license_verified'] == true;
    final hasVehicle = hasVehicleOf(d);

    return Container(
      margin: inGrid ? EdgeInsets.zero : const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showDriverDetailModal(d, doc.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: hasVehicle ? const Color(0xFFECFDF5) : Colors.grey.withOpacity(0.12),
                      child: Icon(Icons.person_rounded, size: 20, color: hasVehicle ? const Color(0xFF059669) : AppColors.textMuted),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, color: AppColors.darkSlate),
                                ),
                              ),
                              if (isVerified) ...[
                                const SizedBox(width: 5),
                                const Tooltip(
                                  message: 'Verified LTO Driver\'s License',
                                  child: Icon(Icons.verified_rounded, size: 16, color: Color(0xFF059669)),
                                ),
                              ],
                              if (DriverSuspension.fromUser(d).active) ...[
                                const SizedBox(width: 5),
                                Tooltip(
                                  message: DriverSuspension.fromUser(d).message,
                                  child: const Icon(Icons.block_rounded, size: 16, color: AppColors.errorCrimson),
                                ),
                              ],
                            ],
                          ),
                          Text(
                            'ID: ${doc.id} • @$username',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textMuted),
                  ],
                ),
                const Divider(height: 16, color: AppColors.borderSubtle),
                Row(
                  children: [
                    const Icon(Icons.credit_card_rounded, size: 15, color: AppColors.textMuted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'License: $license',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                      decoration: BoxDecoration(
                        color: hasVehicle ? const Color(0xFFEFF6FF) : const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: hasVehicle ? const Color(0xFF93C5FD) : const Color(0xFFFECACA)),
                      ),
                      child: Text(
                        hasVehicle ? assignedVehicle : 'UNASSIGNED',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: hasVehicle ? const Color(0xFF1D4ED8) : AppColors.errorCrimson,
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
    );
  }

  // ===========================================================================
  // RESET PIN MODAL
  // ===========================================================================
  void _showResetPinModal({
    required String targetUserId,
    required String targetUserName,
    required String targetRole,
    required String currentPin,
  }) {
    final pinController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool obscurePin = true;
    bool isSaving = false;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return SafeArea(
            maintainBottomViewPadding: true,
            child: Dialog(
              backgroundColor: Colors.white,
              elevation: 6,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppColors.borderSubtle),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: AppColors.primaryNavy.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.lock_reset_rounded,
                                color: AppColors.primaryNavy,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Reset Security PIN',
                                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                                  ),
                                  Text(
                                    'Account: $targetUserName ($targetRole)',
                                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.textMuted),
                              onPressed: isSaving ? null : () => Navigator.pop(dialogCtx),
                            ),
                          ],
                        ),
                        const Divider(height: 20, color: AppColors.borderSubtle),

                        const Text(
                          'Assign a new 6 to 8-digit authentication PIN for this accredited account:',
                          style: TextStyle(fontSize: 12, color: AppColors.textMuted, height: 1.3),
                        ),
                        const SizedBox(height: 12),

                        TextFormField(
                          controller: pinController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
                          obscureText: obscurePin,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 2),
                          decoration: _buildInputDeco(
                            'New Security PIN *',
                            Icons.lock_outline_rounded,
                            hint: '6 to 8 digits',
                            suffix: IconButton(
                              icon: Icon(
                                obscurePin ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                size: 18,
                                color: AppColors.textMuted,
                              ),
                              onPressed: () => setDialogState(() => obscurePin = !obscurePin),
                            ),
                          ),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return 'PIN is required';
                            if (v.trim().length < 6 || v.trim().length > 8) return 'PIN must be 6 to 8 digits';
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
                                    side: const BorderSide(color: AppColors.borderSubtle),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  onPressed: isSaving ? null : () => Navigator.pop(dialogCtx),
                                  child: const Text('Cancel', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.darkSlate)),
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
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  onPressed: isSaving
                                      ? null
                                      : () async {
                                          if (!formKey.currentState!.validate()) return;
                                          setDialogState(() => isSaving = true);
                                          try {
                                            await StaffAuth.resetPin(
                                              userDocId: targetUserId,
                                              newPin: pinController.text.trim(),
                                            );

                                            if (!mounted) return;
                                            Navigator.pop(dialogCtx);
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text('PIN for $targetUserName reset successfully.'),
                                                backgroundColor: const Color(0xFF059669),
                                              ),
                                            );
                                          } catch (e) {
                                            setDialogState(() => isSaving = false);
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(content: Text('Failed: $e'), backgroundColor: AppColors.errorCrimson),
                                            );
                                          }
                                        },
                                  child: isSaving
                                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                      : const Text('Update PIN', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
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
      ),
    );
  }

  // ===========================================================================
  // ADD DRIVER OCR & REGISTRATION MODAL
  // ===========================================================================
  Future<void> _showAddDriverModal() async {
    List<String> availableJeepneys = [];
    try {
      final vSnap = await FirebaseFirestore.instance.collection('vehicles_live').get();
      availableJeepneys = vSnap.docs
          .where((d) => _matchesCooperative(d.data()))
          .map((d) => d.id)
          .toList()
        ..sort();
    } catch (_) {}
    if (!mounted) return;

    final formKey = GlobalKey<FormState>();
    final firstNameController = TextEditingController();
    final lastNameController = TextEditingController();
    final middleInitialController = TextEditingController();
    final usernameController = TextEditingController();
    final licenseController = TextEditingController();
    final pinController = TextEditingController();
    final confirmPinController = TextEditingController();

    String selectedVehicle = 'UNASSIGNED';
    String? selectedSex;
    bool obscurePin = true;
    bool obscureConfirmPin = true;
    bool isSubmitting = false;

    Uint8List? licenseImageBytes;
    String? licenseImageFileName;
    String? scannedRawText;
    bool isOcrScanning = false;
    bool isLicenseVerified = false;
    String ocrVerificationMessage = '';
    bool detailsAutoFilled = false;
    final ImagePicker picker = ImagePicker();

    final coopId = _coopId;
    final coopName = _coopName;

    String normalizeForMatch(String input) {
      return _LicenseOcrParser.stripAccents(input)
          .toUpperCase()
          .replaceAll('Ñ', 'N')
          .replaceAll(RegExp(r'[^A-Z0-9\s]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    List<String> missingNameTokens(String normalizedOcr, String name) {
      final tokens = normalizeForMatch(name).split(' ').where((t) => t.length >= 2).toList();
      return tokens.where((t) => !normalizedOcr.contains(t)).toList();
    }

    String? detectSexFromOcr(String rawUpper) => _LicenseOcrParser.detectSex(rawUpper);

    void verifyExtractedLicense(String rawText, StateSetter setDialogState) {
      final trimmed = rawText.trim();
      if (trimmed.length < 15) {
        setDialogState(() {
          isLicenseVerified = false;
          ocrVerificationMessage = 'Card is blurry or unreadable. Please capture closer under good lighting.';
        });
        return;
      }

      final lower = trimmed.toLowerCase();
      final bool hasDriverLicense = lower.contains('driver') && lower.contains('license');
      final bool hasLto = lower.contains('land transportation') || lower.contains('lto');
      final bool hasOfficialHeader = lower.contains('republika') || lower.contains('republic of the philippines') || lower.contains('pilipinas');

      final bool isLegitDlDocument = hasDriverLicense || (hasLto && lower.contains('license')) || (hasOfficialHeader && lower.contains('driver'));

      if (!isLegitDlDocument) {
        setDialogState(() {
          isLicenseVerified = false;
          ocrVerificationMessage = 'Unrecognized card: Document is not an official LTO Driver\'s License.';
        });
        return;
      }

      final normalizedOcr = normalizeForMatch(rawText);
      final ocrForNames =
          '$normalizedOcr ${normalizeForMatch(_LicenseOcrParser.fixConfusables(rawText))}';
      final enteredFirst = firstNameController.text.trim();
      final enteredLast = lastNameController.text.trim();
      final enteredMi = normalizeForMatch(middleInitialController.text);

      if (enteredLast.isNotEmpty) {
        final missing = missingNameTokens(ocrForNames, enteredLast);
        if (missing.isNotEmpty) {
          setDialogState(() {
            isLicenseVerified = false;
            ocrVerificationMessage = 'Last Name Mismatch: "$enteredLast" was not detected on this license.';
          });
          return;
        }
      }

      if (enteredFirst.isNotEmpty) {
        final missing = missingNameTokens(ocrForNames, enteredFirst);
        if (missing.isNotEmpty) {
          setDialogState(() {
            isLicenseVerified = false;
            ocrVerificationMessage = 'First Name Mismatch: "$enteredFirst" was not detected on this license.';
          });
          return;
        }

        if (enteredMi.isNotEmpty) {
          final firstTokens = normalizeForMatch(enteredFirst).split(' ').where((t) => t.isNotEmpty).toList();
          final lastFirstToken = firstTokens.isNotEmpty ? firstTokens.last : '';
          final idx = lastFirstToken.isEmpty ? -1 : normalizedOcr.indexOf(lastFirstToken);
          if (idx != -1) {
            final after = normalizedOcr.substring(idx + lastFirstToken.length).trimLeft();
            if (after.isNotEmpty && !after.startsWith(enteredMi[0])) {
              setDialogState(() {
                isLicenseVerified = false;
                ocrVerificationMessage = 'Middle Initial Mismatch: "${middleInitialController.text.trim().toUpperCase()}." does not match license.';
              });
              return;
            }
          }
        }
      }

      String sexNote = '';
      if (selectedSex != null) {
        final detectedSex = detectSexFromOcr(rawText.toUpperCase());
        if (detectedSex != null && detectedSex != selectedSex) {
          setDialogState(() {
            isLicenseVerified = false;
            ocrVerificationMessage = 'Sex Mismatch: Card indicates "${detectedSex == 'MALE' ? 'Male' : 'Female'}".';
          });
          return;
        }
      }

      final cleanOcr = rawText.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
      final enteredLicense = licenseController.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();

      if (enteredLicense.isNotEmpty && enteredLicense.length >= 6) {
        if (!_LicenseOcrParser.digitize(cleanOcr).contains(_LicenseOcrParser.digitize(enteredLicense))) {
          setDialogState(() {
            isLicenseVerified = false;
            ocrVerificationMessage = 'License Number Mismatch: "${licenseController.text.trim()}" not detected.';
          });
          return;
        }
      } else {
        final licenseRegex = RegExp(r'[A-Z]\d{2}[-\s]?\d{2}[-\s]?\d{6}');
        final match = licenseRegex.firstMatch(rawText.toUpperCase());
        if (match != null && licenseController.text.isEmpty) {
          licenseController.text = match.group(0)!.replaceAll(' ', '-');
        }
      }

      HapticFeedback.lightImpact();
      setDialogState(() {
        isLicenseVerified = true;
        ocrVerificationMessage = 'Official LTO Driver\'s License verified successfully.$sexNote'
            '${detailsAutoFilled ? ' Details were filled in from the card, please double-check them.' : ''}';
      });
    }

    Future<String> performWebCloudOcr(Uint8List imageBytes) async {
      try {
        final base64Image = 'data:image/jpeg;base64,${base64Encode(imageBytes)}';
        final response = await http.post(
          Uri.parse('https://api.ocr.space/parse/image'),
          headers: {'apikey': 'helloworld'},
          body: {
            'base64Image': base64Image,
            'language': 'eng',
            'isOverlayRequired': 'false',
            'OCREngine': '2',
          },
        );
        if (response.statusCode == 200) {
          final json = jsonDecode(response.body);
          final parsedResults = json['ParsedResults'] as List<dynamic>?;
          if (parsedResults != null && parsedResults.isNotEmpty) {
            return (parsedResults[0]['ParsedText'] ?? '').toString();
          }
        }
      } catch (_) {}
      return '';
    }

    Future<void> pickAndProcessLicense(ImageSource source, StateSetter setDialogState) async {
      try {
        final XFile? file = await picker.pickImage(
          source: source,
          maxWidth: 1400,
          maxHeight: 1400,
          imageQuality: 85,
        );

        if (file == null) return;

        final bytes = await file.readAsBytes();
        if (bytes.lengthInBytes > 1024 * 1024 * 2) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Image file is too large. Please take a clear, cropped photo.'),
              backgroundColor: AppColors.errorCrimson,
            ),
          );
          return;
        }

        setDialogState(() {
          licenseImageBytes = bytes;
          licenseImageFileName = file.name;
          isOcrScanning = true;
          ocrVerificationMessage = '';
          detailsAutoFilled = false;
        });

        String extractedText = '';

        if (kIsWeb) {
          extractedText = await performWebCloudOcr(bytes);
        } else {
          final inputImage = InputImage.fromFilePath(file.path);
          final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
          final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
          await textRecognizer.close();
          extractedText = recognizedText.text;
        }

        scannedRawText = extractedText;

        // Auto-fill the form from what is printed on the license.
        final parsed = _LicenseOcrParser.parse(extractedText);
        if (parsed != null) {
          setDialogState(() {
            if (parsed.hasName) {
              lastNameController.text = parsed.lastName!;
              firstNameController.text = parsed.firstName!;
              final mid = parsed.middleName;
              middleInitialController.text =
                  (mid == null || mid.isEmpty) ? '' : mid[0].toUpperCase();
            }
            if (parsed.sex != null) selectedSex = parsed.sex;
            if (parsed.licenseNumber != null) {
              licenseController.text = parsed.licenseNumber!;
            }
            detailsAutoFilled = parsed.hasName ||
                parsed.sex != null ||
                parsed.licenseNumber != null;
          });
        }

        verifyExtractedLicense(extractedText, setDialogState);

        if ((parsed == null || !parsed.hasName) &&
            _LicenseOcrParser.looksLikeLicense(extractedText) &&
            context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Couldn't read the name from this license. Please type it exactly as printed."),
            ),
          );
        }
      } catch (e) {
        setDialogState(() {
          isLicenseVerified = false;
          ocrVerificationMessage = 'Scanner error: $e';
        });
      } finally {
        setDialogState(() => isOcrScanning = false);
      }
    }

    void showImageSourcePicker(StateSetter setDialogState) {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => _ts(ctx, SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppColors.borderSubtle,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Text('Attach LTO Driver\'s License', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                const SizedBox(height: 6),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.camera_alt_outlined, color: AppColors.commuterTeal, size: 22),
                  title: const Text('Capture Card with Camera', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  onTap: () {
                    Navigator.pop(ctx);
                    pickAndProcessLicense(ImageSource.camera, setDialogState);
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.photo_library_outlined, color: AppColors.commuterTeal, size: 22),
                  title: const Text('Choose from Photo Gallery', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  onTap: () {
                    Navigator.pop(ctx);
                    pickAndProcessLicense(ImageSource.gallery, setDialogState);
                  },
                ),
              ],
            ),
          ),
        )),
      );
    }

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final hasImage = licenseImageBytes != null;

            return _ts(context, SafeArea(
              maintainBottomViewPadding: true,
              child: Dialog(
                backgroundColor: Colors.white,
                elevation: 6,
                insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: AppColors.borderSubtle),
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 440, maxHeight: _dialogMaxHeight(context, 680)),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
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
                                  color: const Color(0xFFECFDF5),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.person_add_rounded, color: Color(0xFF059669), size: 20),
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Enroll New Driver',
                                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                                    ),
                                    Text(
                                      'LTO license card is optional; if attached, it must verify',
                                      style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.textMuted),
                                onPressed: () => Navigator.pop(dialogCtx),
                              ),
                            ],
                          ),
                          const Divider(height: 18, color: AppColors.borderSubtle),

                          TextFormField(
                            controller: firstNameController,
                            textCapitalization: TextCapitalization.words,
                            style: const TextStyle(fontSize: 14),
                            decoration: _buildInputDeco('First Name *', Icons.badge_outlined, hint: 'e.g. Pedro'),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'First name is required' : null,
                            onChanged: (_) {
                              if (scannedRawText != null) verifyExtractedLicense(scannedRawText!, setDialogState);
                            },
                          ),
                          const SizedBox(height: 10),

                          TextFormField(
                            controller: lastNameController,
                            textCapitalization: TextCapitalization.words,
                            style: const TextStyle(fontSize: 14),
                            decoration: _buildInputDeco('Last Name *', Icons.badge_outlined, hint: 'e.g. Penduko'),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'Last name is required' : null,
                            onChanged: (_) {
                              if (scannedRawText != null) verifyExtractedLicense(scannedRawText!, setDialogState);
                            },
                          ),
                          const SizedBox(height: 10),

                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 4,
                                child: TextFormField(
                                  controller: middleInitialController,
                                  textCapitalization: TextCapitalization.characters,
                                  inputFormatters: [
                                    LengthLimitingTextInputFormatter(1),
                                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z]')),
                                  ],
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                                  decoration: _buildInputDeco('M.I.', Icons.text_fields_rounded, hint: 'e.g. S'),
                                  onChanged: (_) {
                                    if (scannedRawText != null) verifyExtractedLicense(scannedRawText!, setDialogState);
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 6,
                                child: DropdownButtonFormField<String>(
                                  value: selectedSex,
                                  isDense: true,
                                  isExpanded: true,
                                  hint: const Text('Select', style: TextStyle(fontSize: 13.5, color: AppColors.textMuted)),
                                  decoration: _buildInputDeco('Sex *', Icons.wc_rounded),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'MALE',
                                      child: Text('Male', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
                                    ),
                                    DropdownMenuItem(
                                      value: 'FEMALE',
                                      child: Text('Female', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                  validator: (v) => v == null ? 'Sex is required' : null,
                                  onChanged: (val) {
                                    if (val != null) {
                                      setDialogState(() => selectedSex = val);
                                      if (scannedRawText != null) verifyExtractedLicense(scannedRawText!, setDialogState);
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),

                          TextFormField(
                            controller: usernameController,
                            style: const TextStyle(fontSize: 14),
                            decoration: _buildInputDeco('Login Username *', Icons.account_circle_outlined, hint: 'e.g. drv_pedro'),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'Username is required' : null,
                          ),
                          const SizedBox(height: 10),

                          TextFormField(
                            controller: licenseController,
                            textCapitalization: TextCapitalization.characters,
                            style: const TextStyle(fontSize: 14, fontFamily: 'monospace', fontWeight: FontWeight.w700),
                            decoration: _buildInputDeco('LTO License Number (optional)', Icons.credit_card_rounded, hint: 'e.g. D01-23-456789'),
                            onChanged: (_) {
                              if (scannedRawText != null) verifyExtractedLicense(scannedRawText!, setDialogState);
                            },
                          ),
                          const SizedBox(height: 12),

                          Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFC),
                              border: Border.all(
                                color: isLicenseVerified
                                    ? const Color(0xFF10B981)
                                    : (hasImage ? const Color(0xFFEF4444) : const Color(0xFFCBD5E1)),
                                width: 1.4,
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                            'LTO Driver\'s License Card (optional)',
                                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: AppColors.darkSlate),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            licenseImageFileName ?? 'Front card photo (optional, verified if attached)',
                                            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: isOcrScanning ? null : () => showImageSourcePicker(setDialogState),
                                      icon: Icon(hasImage ? Icons.refresh_rounded : Icons.camera_alt_outlined, size: 15),
                                      label: Text(hasImage ? 'Re-scan' : 'Scan Card', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: AppColors.commuterTeal,
                                        side: const BorderSide(color: AppColors.commuterTeal, width: 1.2),
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        minimumSize: Size.zero,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                      ),
                                    ),
                                  ],
                                ),

                                if (isOcrScanning) ...[
                                  const SizedBox(height: 10),
                                  Row(
                                    children: const [
                                      SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.commuterTeal)),
                                      SizedBox(width: 8),
                                      Expanded(child: Text('Validating LTO credentials via OCR...', style: TextStyle(fontSize: 13, color: AppColors.textMuted, fontWeight: FontWeight.w600))),
                                    ],
                                  ),
                                ],

                                if (hasImage && !isOcrScanning) ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                    decoration: BoxDecoration(
                                      color: isLicenseVerified ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: isLicenseVerified ? const Color(0xFFA7F3D0) : const Color(0xFFFECACA),
                                        width: 1.0,
                                      ),
                                    ),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.only(top: 1.0),
                                          child: Icon(
                                            isLicenseVerified ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                                            color: isLicenseVerified ? const Color(0xFF059669) : const Color(0xFFDC2626),
                                            size: 16,
                                          ),
                                        ),
                                        const SizedBox(width: 7),
                                        Expanded(
                                          child: Text(
                                            ocrVerificationMessage.isNotEmpty
                                                ? ocrVerificationMessage
                                                : 'Unverified license card.',
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w700,
                                              height: 1.3,
                                              color: isLicenseVerified ? const Color(0xFF065F46) : const Color(0xFF991B1B),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: Image.memory(licenseImageBytes!, height: 120, width: double.infinity, fit: BoxFit.cover),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),

                          TextFormField(
                            controller: pinController,
                            obscureText: obscurePin,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
                            style: const TextStyle(fontSize: 14, letterSpacing: 1.2),
                            decoration: _buildInputDeco(
                              'Security PIN (Password) *',
                              Icons.lock_outline_rounded,
                              hint: '6 to 8 digits',
                              suffix: IconButton(
                                icon: Icon(
                                  obscurePin ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                  size: 18,
                                  color: AppColors.textMuted,
                                ),
                                onPressed: () => setDialogState(() => obscurePin = !obscurePin),
                              ),
                            ),
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) return 'PIN is required';
                              if (v.trim().length < 6 || v.trim().length > 8) return 'PIN must be 6 to 8 digits';
                              return null;
                            },
                          ),
                          const SizedBox(height: 10),

                          TextFormField(
                            controller: confirmPinController,
                            obscureText: obscureConfirmPin,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
                            style: const TextStyle(fontSize: 14, letterSpacing: 1.2),
                            decoration: _buildInputDeco(
                              'Retype PIN *',
                              Icons.lock_reset_rounded,
                              hint: 'Re-enter the PIN',
                              suffix: IconButton(
                                icon: Icon(
                                  obscureConfirmPin ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                  size: 18,
                                  color: AppColors.textMuted,
                                ),
                                onPressed: () => setDialogState(() => obscureConfirmPin = !obscureConfirmPin),
                              ),
                            ),
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) return 'Please retype the PIN';
                              if (v.trim() != pinController.text.trim()) return 'PINs do not match';
                              return null;
                            },
                          ),
                          const SizedBox(height: 10),

                          DropdownButtonFormField<String>(
                            value: selectedVehicle,
                            isDense: true,
                            isExpanded: true,
                            decoration: _buildInputDeco('Assign Vehicle (Optional)', Icons.directions_bus_outlined),
                            items: [
                              const DropdownMenuItem(
                                value: 'UNASSIGNED',
                                child: Text('UNASSIGNED', style: TextStyle(fontSize: 13.5, color: AppColors.textMuted)),
                              ),
                              ...availableJeepneys.map(
                                (jp) => DropdownMenuItem(
                                  value: jp,
                                  child: Text(jp, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ],
                            onChanged: (val) {
                              if (val != null) setDialogState(() => selectedVehicle = val);
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
                                      side: const BorderSide(color: AppColors.borderSubtle),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    onPressed: isSubmitting ? null : () => Navigator.pop(dialogCtx),
                                    child: const Text('Cancel', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: SizedBox(
                                  height: 40,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF059669),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      elevation: 0,
                                    ),
                                    onPressed: isSubmitting
                                        ? null
                                        : () async {
                                            if (!formKey.currentState!.validate()) return;

                                            // License card is optional. If one was attached, it must still verify.
                                            final bool hasLicenseCard = licenseImageBytes != null;

                                            if (hasLicenseCard && scannedRawText != null) {
                                              verifyExtractedLicense(scannedRawText!, setDialogState);
                                            }

                                            if (hasLicenseCard && !isLicenseVerified) {
                                              HapticFeedback.mediumImpact();
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                const SnackBar(
                                                  content: Text('Cannot enroll: Legitimate LTO Driver\'s License verification failed.'),
                                                  backgroundColor: AppColors.errorCrimson,
                                                  duration: Duration(seconds: 4),
                                                ),
                                              );
                                              return;
                                            }

                                            setDialogState(() => isSubmitting = true);

                                            try {
                                              final inputUsername = usernameController.text.trim().toLowerCase();

                                              final existingUserQuery = await FirebaseFirestore.instance
                                                  .collection('users')
                                                  .where('username', isEqualTo: inputUsername)
                                                  .limit(1)
                                                  .get();

                                              if (existingUserQuery.docs.isNotEmpty) {
                                                setDialogState(() => isSubmitting = false);
                                                if (!context.mounted) return;
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  SnackBar(
                                                    content: Text('Username "$inputUsername" is already taken.'),
                                                    backgroundColor: AppColors.errorCrimson,
                                                  ),
                                                );
                                                return;
                                              }

                                              final allDrivers = await FirebaseFirestore.instance
                                                  .collection('users')
                                                  .where('role', isEqualTo: 'DRIVER')
                                                  .get();

                                              int maxId = 0;
                                              for (var doc in allDrivers.docs) {
                                                if (doc.id.startsWith('USER_DRV_')) {
                                                  final numPart = int.tryParse(doc.id.replaceFirst('USER_DRV_', ''));
                                                  if (numPart != null && numPart > maxId) {
                                                    maxId = numPart;
                                                  }
                                                }
                                              }
                                              final newDriverDocId = 'USER_DRV_${(maxId + 1).toString().padLeft(3, '0')}';

                                              final firstName = firstNameController.text.trim();
                                              final lastName = lastNameController.text.trim();
                                              final middleInitial = middleInitialController.text.trim().toUpperCase();
                                              final driverName = middleInitial.isNotEmpty
                                                  ? '$firstName $middleInitial. $lastName'
                                                  : '$firstName $lastName';
                                              final String? base64Card = licenseImageBytes != null ? base64Encode(licenseImageBytes!) : null;
                                              final String licenseNo = licenseController.text.trim().toUpperCase();
                                              final newAuthUid = await StaffAuth.createAccount(
                                                inputUsername,
                                                pinController.text.trim(),
                                              );

                                              final batch = FirebaseFirestore.instance.batch();

                                              final newDriverRef = FirebaseFirestore.instance.collection('users').doc(newDriverDocId);
                                              batch.set(newDriverRef, {
                                                'assigned_vehicle': selectedVehicle,
                                                'full_name': driverName,
                                                'first_name': firstName,
                                                'last_name': lastName,
                                                'middle_initial': middleInitial,
                                                'sex': selectedSex,
                                                'license_number': licenseNo.isEmpty ? null : licenseNo,
                                                'license_card_base64': base64Card,
                                                'is_license_verified': base64Card != null && isLicenseVerified,
                                                'license_verified_at': (base64Card != null && isLicenseVerified)
                                                    ? FieldValue.serverTimestamp()
                                                    : null,
                                                'auth_uid': newAuthUid,
                                                'role': 'DRIVER',
                                                'username': inputUsername,
                                                'cooperative_id': coopId,
                                                'cooperative_name': coopName,
                                                'qr_expires_at': null,
                                                'qr_token': null,
                                              });

                                              if (selectedVehicle != 'UNASSIGNED') {
                                                final vehicleRef = FirebaseFirestore.instance.collection('vehicles_live').doc(selectedVehicle);
                                                batch.update(vehicleRef, {
                                                  'driver_id': newDriverDocId,
                                                  'driver_name': driverName,
                                                });
                                              }

                                              await batch.commit();
                                              await StaffAuth.writeRole(newAuthUid, 'DRIVER', newDriverDocId, inputUsername);

                                              if (!context.mounted) return;
                                              Navigator.pop(dialogCtx);
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(
                                                  content: Text('Verified driver "$driverName" enrolled successfully ($newDriverDocId).'),
                                                  backgroundColor: const Color(0xFF059669),
                                                ),
                                              );
                                            } catch (e) {
                                              setDialogState(() => isSubmitting = false);
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(
                                                  content: Text('Enrollment failed: $e'),
                                                  backgroundColor: AppColors.errorCrimson,
                                                ),
                                              );
                                            }
                                          },
                                    child: isSubmitting
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                          )
                                        : const Text(
                                            'Add Driver',
                                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
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
            ));
          },
        );
      },
    );
  }

  // ===========================================================================
  // DRIVER ASSIGNMENT
  // ===========================================================================
  Future<void> _showAssignDriverModal({
    required String vehicleId,
    required String? currentDriverId,
  }) async {
    List<QueryDocumentSnapshot<Map<String, dynamic>>> drivers = [];
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .where('role', isEqualTo: 'DRIVER')
          .get();
      drivers = snap.docs.where((d) => _matchesCooperative(d.data())).toList();
    } catch (_) {}
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        return _ts(
          dialogCtx,
          SafeArea(
            maintainBottomViewPadding: true,
            child: Dialog(
              backgroundColor: Colors.white,
              elevation: 6,
              insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppColors.borderSubtle),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 420, maxHeight: _dialogMaxHeight(dialogCtx, 560)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              color: AppColors.commuterTeal.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.swap_horiz_rounded, color: AppColors.commuterTeal, size: 20),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Assign Driver to $vehicleId',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                                ),
                                const Text(
                                  'Select an enrolled driver of your cooperative',
                                  style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.textMuted),
                            onPressed: () => Navigator.pop(dialogCtx),
                          ),
                        ],
                      ),
                      const Divider(height: 18, color: AppColors.borderSubtle),
                      if (drivers.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text(
                              'No drivers enrolled yet. Add one from the Drivers tab.',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
                            ),
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: drivers.length,
                            itemBuilder: (context, index) {
                              final doc = drivers[index];
                              final dData = doc.data();
                              final name = (dData['full_name'] ?? doc.id).toString();
                              final license = (dData['license_number'] ?? 'N/A').toString();
                              final currentAssigned = (dData['assigned_vehicle'] ?? 'None').toString();
                              final isCurrent = doc.id == currentDriverId;

                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                decoration: BoxDecoration(
                                  color: isCurrent ? const Color(0xFFEFF6FF) : AppColors.backgroundSlate,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isCurrent ? const Color(0xFF3B82F6) : AppColors.borderSubtle,
                                    width: isCurrent ? 1.3 : 1,
                                  ),
                                ),
                                child: ListTile(
                                  dense: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                                  title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                  subtitle: Text(
                                    'License: $license • Assigned: $currentAssigned',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                                  ),
                                  trailing: isCurrent
                                      ? const Chip(
                                          label: Text('ACTIVE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF1D4ED8))),
                                          backgroundColor: Color(0xFFDBEAFE),
                                          padding: EdgeInsets.zero,
                                        )
                                      : OutlinedButton(
                                          style: OutlinedButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                            minimumSize: Size.zero,
                                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            side: const BorderSide(color: AppColors.commuterTeal),
                                          ),
                                          onPressed: () => _executeDriverAssignment(
                                            ctx: dialogCtx,
                                            vehicleId: vehicleId,
                                            newDriverId: doc.id,
                                            newDriverName: name,
                                            oldDriverId: currentDriverId,
                                          ),
                                          child: const Text('Assign', style: TextStyle(fontSize: 11.5, color: AppColors.commuterTeal, fontWeight: FontWeight.bold)),
                                        ),
                                ),
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
      },
    );
  }

  bool _hasAssignment(String? v) {
    if (v == null) return false;
    final t = v.trim();
    return t.isNotEmpty && t != 'UNASSIGNED' && t != 'None' && t != 'null';
  }

  Future<void> _executeDriverAssignment({
    required BuildContext ctx,
    required String vehicleId,
    required String newDriverId,
    required String newDriverName,
    required String? oldDriverId,
  }) async {
    final db = FirebaseFirestore.instance;
    try {
      // What is already assigned on each side?
      final newDriverSnap = await db.collection('users').doc(newDriverId).get();
      final newDriverVehicleRaw =
          (newDriverSnap.data()?['assigned_vehicle'] ?? '').toString().trim();
      final newDriverVehicle =
          _hasAssignment(newDriverVehicleRaw) && newDriverVehicleRaw != vehicleId
              ? newDriverVehicleRaw
              : null;

      final oldDriverIdClean =
          (_hasAssignment(oldDriverId) && oldDriverId != newDriverId)
              ? oldDriverId!.trim()
              : null;

      String oldDriverName = '';
      if (oldDriverIdClean != null) {
        final oldSnap = await db.collection('users').doc(oldDriverIdClean).get();
        oldDriverName =
            (oldSnap.data()?['full_name'] ?? oldDriverIdClean).toString();
      }

      // The other jeepney is only touched if it really exists.
      DocumentReference<Map<String, dynamic>>? otherVehicleRef;
      if (newDriverVehicle != null) {
        final ref = db.collection('vehicles_live').doc(newDriverVehicle);
        if ((await ref.get()).exists) otherVehicleRef = ref;
      }
      final bool movesNewDriver = otherVehicleRef != null;
      final bool swap = movesNewDriver && oldDriverIdClean != null;

      // Confirmation is required whenever somebody is already assigned.
      if (oldDriverIdClean != null || movesNewDriver) {
        if (!ctx.mounted) return;
        final lines = <String>[];
        if (swap) {
          lines.add('$newDriverName is currently on $newDriverVehicle and '
              '$oldDriverName is currently on $vehicleId.');
          lines.add('Both drivers will be switched:\n'
              '• $newDriverName → $vehicleId\n'
              '• $oldDriverName → $newDriverVehicle');
        } else if (oldDriverIdClean != null) {
          lines.add('$vehicleId already has a driver: $oldDriverName.');
          lines.add('$newDriverName will take $vehicleId and $oldDriverName '
              'will become unassigned.');
        } else {
          lines.add('$newDriverName is currently on $newDriverVehicle.');
          lines.add('$newDriverName will move to $vehicleId and '
              '$newDriverVehicle will have no driver.');
        }
        final ok = await showDialog<bool>(
          context: ctx,
          builder: (c) => AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            title: Text(swap ? 'Switch drivers?' : 'Reassign driver?',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            content: Text(lines.join('\n\n'),
                style: const TextStyle(fontSize: 13, height: 1.4)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.commuterTeal,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(c, true),
                child: Text(swap ? 'Switch drivers' : 'Confirm'),
              ),
            ],
          ),
        );
        if (ok != true) return;
      }

      if (ctx.mounted) Navigator.pop(ctx);

      final batch = db.batch();

      // The chosen jeepney gets the new driver.
      batch.update(db.collection('vehicles_live').doc(vehicleId), {
        'driver_id': newDriverId,
        'driver_name': newDriverName,
      });
      batch.update(db.collection('users').doc(newDriverId),
          {'assigned_vehicle': vehicleId});

      if (swap) {
        // The old driver takes the new driver's previous jeepney.
        batch.update(otherVehicleRef!, {
          'driver_id': oldDriverIdClean,
          'driver_name': oldDriverName,
        });
        batch.update(db.collection('users').doc(oldDriverIdClean!),
            {'assigned_vehicle': newDriverVehicle});
      } else {
        if (oldDriverIdClean != null) {
          batch.update(db.collection('users').doc(oldDriverIdClean),
              {'assigned_vehicle': 'UNASSIGNED'});
        }
        if (movesNewDriver) {
          batch.update(otherVehicleRef!, {
            'driver_id': 'UNASSIGNED',
            'driver_name': FieldValue.delete(),
          });
        }
      }

      await batch.commit();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(swap
              ? 'Switched: $newDriverName → $vehicleId, '
                  '$oldDriverName → $newDriverVehicle.'
              : '$newDriverName assigned to $vehicleId successfully.'),
          backgroundColor: const Color(0xFF059669),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Assignment failed: $e'), backgroundColor: AppColors.errorCrimson),
      );
    }
  }

  // ===========================================================================
  // ADD DISPATCHER MODAL
  // ===========================================================================
  void _showAddDispatcherModal() {
    final formKey = GlobalKey<FormState>();
    final firstNameController = TextEditingController();
    final middleNameController = TextEditingController();
    final lastNameController = TextEditingController();
    final fullNameController = TextEditingController();
    final usernameController = TextEditingController();
    final contactController = TextEditingController();
    final pinController = TextEditingController();
    final dispatcherRoutes = _coopAuthorizedRoutes;
    String selectedRoute = dispatcherRoutes.first;
    // Terminal choices depend on the route (Dao boards at Robinsons only).
    String selectedTerminal =
        RouteProcesses.terminalsForDispatcher(selectedRoute).contains(kTermRobinsons)
            ? kTermRobinsons
            : RouteProcesses.terminalsForDispatcher(selectedRoute).first;

    String buildFullName() => [
          firstNameController.text.trim(),
          middleNameController.text.trim(),
          lastNameController.text.trim(),
        ].where((p) => p.isNotEmpty).join(' ');

    bool obscurePin = true;
    bool isSaving = false;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          void syncFullName() {
            fullNameController.text = buildFullName();
            setDialogState(() {});
          }

          return SafeArea(
            maintainBottomViewPadding: true,
            child: Dialog(
              backgroundColor: Colors.white,
              elevation: 6,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppColors.borderSubtle),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: AppColors.primaryNavy.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.person_add_alt_1_rounded,
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
                                    'Create Dispatcher Account',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.darkSlate,
                                    ),
                                  ),
                                  Text(
                                    'Assign terminal post and manage trips',
                                    style: TextStyle(fontSize: 10.5, color: AppColors.textMuted),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.textMuted),
                              onPressed: isSaving ? null : () => Navigator.pop(dialogCtx),
                            ),
                          ],
                        ),
                        const Divider(height: 18, color: AppColors.borderSubtle),

                        TextFormField(
                          controller: firstNameController,
                          textCapitalization: TextCapitalization.words,
                          style: const TextStyle(fontSize: 13),
                          onChanged: (_) => syncFullName(),
                          decoration: _buildInputDeco('First Name *', Icons.badge_outlined, hint: 'e.g. Maria'),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'First name is required' : null,
                        ),
                        const SizedBox(height: 10),

                        TextFormField(
                          controller: middleNameController,
                          textCapitalization: TextCapitalization.words,
                          style: const TextStyle(fontSize: 13),
                          onChanged: (_) => syncFullName(),
                          decoration: _buildInputDeco('Middle Name (optional)', Icons.badge_outlined, hint: 'e.g. Reyes'),
                        ),
                        const SizedBox(height: 10),

                        TextFormField(
                          controller: lastNameController,
                          textCapitalization: TextCapitalization.words,
                          style: const TextStyle(fontSize: 13),
                          onChanged: (_) => syncFullName(),
                          decoration: _buildInputDeco('Last Name *', Icons.badge_outlined, hint: 'e.g. Santos'),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'Last name is required' : null,
                        ),
                        const SizedBox(height: 10),

                        TextFormField(
                          controller: fullNameController,
                          readOnly: true,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                          decoration: _buildInputDeco('Full Name (automatic)', Icons.person_outline_rounded),
                        ),
                        const SizedBox(height: 10),

                        TextFormField(
                          controller: usernameController,
                          style: const TextStyle(fontSize: 13),
                          decoration: _buildInputDeco('Login Username *', Icons.account_circle_outlined, hint: 'e.g. disp_maria'),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'Username is required' : null,
                        ),
                        const SizedBox(height: 10),

                        TextFormField(
                          controller: contactController,
                          keyboardType: TextInputType.phone,
                          style: const TextStyle(fontSize: 13),
                          decoration: _buildInputDeco('Contact Number *', Icons.phone_outlined, hint: '09XXXXXXXXX'),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'Contact number is required' : null,
                        ),
                        const SizedBox(height: 10),

                        DropdownButtonFormField<String>(
                          value: selectedRoute,
                          isExpanded: true,
                          style: const TextStyle(fontSize: 13, color: AppColors.darkSlate),
                          decoration: _buildInputDeco('Assigned Route *', Icons.alt_route_rounded),
                          items: dispatcherRoutes.map((rId) {
                            return DropdownMenuItem<String>(
                              value: rId,
                              child: Text(
                                _formatRouteDisplayName(rId),
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                            );
                          }).toList(),
                          onChanged: isSaving
                              ? null
                              : (val) => setDialogState(() {
                                    selectedRoute = val ?? selectedRoute;
                                    final allowed = RouteProcesses.terminalsForDispatcher(selectedRoute);
                                    if (!allowed.contains(selectedTerminal)) {
                                      selectedTerminal = allowed.first;
                                    }
                                  }),
                          validator: (v) => (v == null || v.isEmpty) ? 'Route is required' : null,
                        ),
                        const SizedBox(height: 10),

                        DropdownButtonFormField<String>(
                          value: selectedTerminal,
                          isExpanded: true,
                          style: const TextStyle(fontSize: 13, color: AppColors.darkSlate),
                          decoration: _buildInputDeco('Assigned Terminal *', Icons.location_on_outlined),
                          items: RouteProcesses.terminalsForDispatcher(selectedRoute).map((t) {
                            return DropdownMenuItem<String>(
                              value: t,
                              child: Text(
                                _formatTerminalName(t),
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                            );
                          }).toList(),
                          onChanged: isSaving
                              ? null
                              : (val) => setDialogState(() => selectedTerminal = val ?? selectedTerminal),
                          validator: (v) => (v == null || v.isEmpty) ? 'Terminal is required' : null,
                        ),
                        const SizedBox(height: 10),

                        TextFormField(
                          controller: pinController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
                          obscureText: obscurePin,
                          style: const TextStyle(fontSize: 13, letterSpacing: 2),
                          decoration: _buildInputDeco(
                            'Login PIN (6-8 digits) *',
                            Icons.lock_outline_rounded,
                            hint: '6 to 8 digits',
                            suffix: IconButton(
                              icon: Icon(
                                obscurePin ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                size: 18,
                                color: AppColors.textMuted,
                              ),
                              onPressed: () => setDialogState(() => obscurePin = !obscurePin),
                            ),
                          ),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return 'PIN is required';
                            if (v.trim().length < 6 || v.trim().length > 8) return 'PIN must be 6 to 8 digits';
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
                                    side: const BorderSide(color: AppColors.borderSubtle),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  onPressed: isSaving ? null : () => Navigator.pop(dialogCtx),
                                  child: const Text('Cancel', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.darkSlate)),
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
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  onPressed: isSaving
                                      ? null
                                      : () async {
                                          if (!formKey.currentState!.validate()) return;
                                          setDialogState(() => isSaving = true);
                                          try {
                                            final uName = usernameController.text.trim().toLowerCase();
                                            final exists = await FirebaseFirestore.instance
                                                .collection('users')
                                                .where('username', isEqualTo: uName)
                                                .limit(1)
                                                .get();

                                            if (exists.docs.isNotEmpty) {
                                              setDialogState(() => isSaving = false);
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(
                                                  content: Text('Username "$uName" is already in use.'),
                                                  backgroundColor: AppColors.errorCrimson,
                                                ),
                                              );
                                              return;
                                            }

                                            final allDisp = await FirebaseFirestore.instance
                                                .collection('users')
                                                .where('role', isEqualTo: 'DISPATCHER')
                                                .get();
                                            int maxId = 0;
                                            for (var doc in allDisp.docs) {
                                              if (doc.id.startsWith('USER_DISP_')) {
                                                final numPart = int.tryParse(doc.id.replaceFirst('USER_DISP_', ''));
                                                if (numPart != null && numPart > maxId) maxId = numPart;
                                              }
                                            }
                                            final newDocId = 'USER_DISP_${(maxId + 1).toString().padLeft(3, '0')}';
                                            final newAuthUid = await StaffAuth.createAccount(
                                              uName,
                                              pinController.text.trim(),
                                            );

                                            await FirebaseFirestore.instance.collection('users').doc(newDocId).set({
                                              'first_name': firstNameController.text.trim(),
                                              'middle_name': middleNameController.text.trim(),
                                              'last_name': lastNameController.text.trim(),
                                              'full_name': buildFullName(),
                                              'username': uName,
                                              'contact_number': contactController.text.trim(),
                                              'auth_uid': newAuthUid,
                                              'assigned_terminal': selectedTerminal,
                                              'assigned_route': selectedRoute,
                                              'role': 'DISPATCHER',
                                              'cooperative_id': _coopId,
                                              'cooperative_name': _coopName,
                                              'created_at': FieldValue.serverTimestamp(),
                                            });
                                            await StaffAuth.writeRole(newAuthUid, 'DISPATCHER', newDocId, uName);

                                            if (!mounted) return;
                                            Navigator.pop(dialogCtx);
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text('Dispatcher created successfully ($newDocId).'),
                                                backgroundColor: const Color(0xFF059669),
                                              ),
                                            );
                                          } catch (e) {
                                            setDialogState(() => isSaving = false);
                                            if (!context.mounted) return;
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(content: Text('Failed: $e'), backgroundColor: AppColors.errorCrimson),
                                            );
                                          }
                                        },
                                  child: isSaving
                                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                      : const Text('Save Dispatcher', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
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
      ),
    );
  }

  // ===========================================================================
  // ENROLL JEEPNEY MODAL (WITH MEMBER OWNER NAME, NUMBER & DYNAMIC ROUTES)
  // ===========================================================================
  // ---------------------------------------------------------------------------
  // EDIT COOP CPC / PRANGKISA NUMBER
  // Saved on every users doc of this cooperative, then applied automatically
  // to each new jeepney enrolled afterwards. Existing units are not touched.
  // Returns true if a new value was saved.
  // ---------------------------------------------------------------------------
  Future<bool> _showEditCpcDialog() async {
    final controller = TextEditingController(text: _coopCpc);
    final formKey = GlobalKey<FormState>();
    bool saving = false;

    final saved = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Franchise CPC / Prangkisa No.'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Applied automatically to every new jeepney you enroll. '
                  'Units already registered keep their current number.',
                  style: TextStyle(fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: controller,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'CPC / Case Number',
                    hintText: 'e.g. CPC-2023-VI-0892',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return 'Required';
                    if (t.length < 5) return 'Too short';
                    if (!RegExp(r'^[A-Za-z0-9\-\/ ]+$').hasMatch(t)) {
                      return 'Letters, numbers, - and / only';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (!formKey.currentState!.validate()) return;
                      setS(() => saving = true);
                      final value = controller.text
                          .trim()
                          .toUpperCase()
                          .replaceAll(RegExp(r'\s+'), ' ');
                      try {
                        final db = FirebaseFirestore.instance;
                        final batch = db.batch();
                        final update = <String, dynamic>{
                          'franchise_case_number': value,
                          'cpc_updated_at': FieldValue.serverTimestamp(),
                        };

                        // Keep every admin account of this coop in sync.
                        final snap = await db
                            .collection('users')
                            .where('cooperative_id', isEqualTo: _coopId)
                            .get();
                        final ids = <String>{for (final d in snap.docs) d.id};
                        ids.add(widget.userId); // always include this account
                        for (final id in ids) {
                          batch.update(db.collection('users').doc(id), update);
                        }
                        await batch.commit();
                        if (ctx.mounted) Navigator.pop(ctx, value);
                      } catch (e) {
                        setS(() => saving = false);
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text('Could not save CPC: $e')),
                          );
                        }
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved == null) return false;
    if (mounted) setState(() => _cpcOverride = saved);
    return true;
  }

  void _showAddJeepneyModal() {
    final formKey = GlobalKey<FormState>();
    final plateController = TextEditingController();
    final nameController = TextEditingController();
    final ownerController = TextEditingController();
    final ownerContactController = TextEditingController();
    final capacityController = TextEditingController(text: '20');

    final routes = _coopAuthorizedRoutes;
    String selectedRoute = routes.isNotEmpty ? routes.first : 'ROUTE_GUINSANGAN';
    String vehicleColor = 'Blue';
    bool isSaving = false;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return SafeArea(
            maintainBottomViewPadding: true,
            child: Dialog(
              backgroundColor: Colors.white,
              elevation: 6,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppColors.borderSubtle),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFECFDF5),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.directions_bus_filled_rounded,
                                color: Color(0xFF059669),
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Enroll Fleet Jeepney',
                                    style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                                  ),
                                  Text(
                                    'Register unit under Cooperative Consolidated CPC',
                                    style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.textMuted),
                              onPressed: isSaving ? null : () => Navigator.pop(dialogCtx),
                            ),
                          ],
                        ),
                        const Divider(height: 18, color: AppColors.borderSubtle),

                        // Consolidated CPC Franchise Badge
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppColors.backgroundSlate,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.borderSubtle),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.verified_user_outlined, size: 16, color: Color(0xFF059669)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'CONSOLIDATED ROUTE FRANCHISE (CPC)',
                                      style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.textMuted),
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      _hasCpc ? _coopCpc : 'Not set. Tap the pencil to add it',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                        color: _hasCpc ? AppColors.darkSlate : const Color(0xFFDC2626),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _hasCpc ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: _hasCpc ? const Color(0xFFA7F3D0) : const Color(0xFFFECACA),
                                  ),
                                ),
                                child: Text(
                                  _hasCpc ? 'AUTO' : 'NOT SET',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w900,
                                    color: _hasCpc ? const Color(0xFF059669) : const Color(0xFFDC2626),
                                  ),
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                tooltip: 'Change CPC',
                                icon: const Icon(Icons.edit_rounded, size: 18, color: AppColors.textMuted),
                                onPressed: isSaving
                                    ? null
                                    : () async {
                                        await _showEditCpcDialog();
                                        setDialogState(() {}); // refresh badge in this modal
                                      },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Plate / Body Number
                        TextFormField(
                          controller: plateController,
                          textCapitalization: TextCapitalization.characters,
                          style: const TextStyle(fontSize: 14),
                          decoration: _buildInputDeco('Plate / Body Number *', Icons.pin_outlined, hint: 'e.g. FAS-1234'),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'Plate/Body ID is required' : null,
                        ),
                        const SizedBox(height: 10),

                        // Jeepney Body Name
                        TextFormField(
                          controller: nameController,
                          style: const TextStyle(fontSize: 14),
                          decoration: _buildInputDeco('Jeepney Body Name *', Icons.drive_file_rename_outline_rounded, hint: 'e.g. Pearl'),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'Body name is required' : null,
                        ),
                        const SizedBox(height: 10),

                        // Member Owner Name and Contact Number (Side-by-Side)
                        Row(
                          children: [
                            Expanded(
                              flex: 6,
                              child: TextFormField(
                                controller: ownerController,
                                textCapitalization: TextCapitalization.words,
                                style: const TextStyle(fontSize: 14),
                                decoration: _buildInputDeco('Owner / Member *', Icons.person_outline_rounded, hint: 'Roberto Ramos'),
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'Owner name is required' : null,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 5,
                              child: TextFormField(
                                controller: ownerContactController,
                                keyboardType: TextInputType.phone,
                                style: const TextStyle(fontSize: 14),
                                decoration: _buildInputDeco('Owner Phone *', Icons.phone_outlined, hint: '09123456789'),
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'Contact is required' : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        // Capacity & Color
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: capacityController,
                                keyboardType: TextInputType.number,
                                style: const TextStyle(fontSize: 14),
                                decoration: _buildInputDeco('Capacity', Icons.airline_seat_recline_normal_rounded),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                value: vehicleColor,
                                isDense: true,
                                isExpanded: true,
                                decoration: _buildInputDeco('Color', Icons.palette_outlined),
                                items: ['Blue', 'Red', 'Green', 'Yellow', 'White', 'Silver', 'Orange']
                                    .map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 13))))
                                    .toList(),
                                onChanged: (val) => setDialogState(() => vehicleColor = val ?? 'Blue'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        // Authorized Route (Dynamically loaded array from Firestore)
                        DropdownButtonFormField<String>(
                          value: selectedRoute,
                          isDense: true,
                          isExpanded: true,
                          decoration: _buildInputDeco('Authorized Route', Icons.alt_route_rounded),
                          items: routes.map((rId) {
                            return DropdownMenuItem<String>(
                              value: rId,
                              child: Text(
                                _formatRouteDisplayName(rId),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                            );
                          }).toList(),
                          onChanged: (val) => setDialogState(() => selectedRoute = val ?? selectedRoute),
                        ),
                        const SizedBox(height: 16),

                        Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 40,
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(color: AppColors.borderSubtle),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  onPressed: isSaving ? null : () => Navigator.pop(dialogCtx),
                                  child: const Text('Cancel', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.darkSlate)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SizedBox(
                                height: 40,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF059669),
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  onPressed: (isSaving || !_hasCpc)
                                      ? null
                                      : () async {
                                          if (!formKey.currentState!.validate()) return;
                                          setDialogState(() => isSaving = true);
                                          try {
                                            final docId = plateController.text.trim().toUpperCase();

                                            await FirebaseFirestore.instance.collection('vehicles_live').doc(docId).set({
                                              'plate_number': docId,
                                              'vehicle_name': nameController.text.trim(),
                                              'franchise_case_number': _coopCpc,
                                              'max_capacity': int.tryParse(capacityController.text) ?? 20,
                                              'passenger_count': 0,
                                              'speed_kmh': 0,
                                              'current_status': 'STANDBY',
                                              'route_id': selectedRoute,
                                              'vehicle_color': vehicleColor,
                                              'driver_id': 'UNASSIGNED',
                                              'driver_name': 'Unassigned Driver',
                                              'cooperative_id': _coopId,
                                              'cooperative_name': _coopName,
                                              'member_owner': ownerController.text.trim(),
                                              'member_owner_contact': ownerContactController.text.trim(),
                                              'operator_name': ownerController.text.trim(),
                                              'created_at': FieldValue.serverTimestamp(),
                                            }, SetOptions(merge: true));

                                            if (!mounted) return;
                                            Navigator.pop(dialogCtx);
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text('Unit "$docId" enrolled with Franchise $_coopCpc.'),
                                                backgroundColor: const Color(0xFF059669),
                                              ),
                                            );
                                          } catch (e) {
                                            setDialogState(() => isSaving = false);
                                            if (!context.mounted) return;
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(content: Text('Failed: $e'), backgroundColor: AppColors.errorCrimson),
                                            );
                                          }
                                        },
                                  child: isSaving
                                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                      : const Text('Enroll Unit', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
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
      ),
    );
  }

  // ===========================================================================
  // EDIT ACCOUNT DETAILS MODAL
  // ===========================================================================
  void _showEditAccountDialog() {
    final nameController = TextEditingController(text: _fullName);
    final coopNameController = TextEditingController(text: _coopName);
    final pinController = TextEditingController(
      text: '',
    );
    final formKey = GlobalKey<FormState>();
    bool isSaving = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          return Dialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: AppColors.primaryNavy.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.manage_accounts_rounded,
                              color: AppColors.primaryNavy,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Edit Account Details',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.darkSlate,
                                  ),
                                ),
                                SizedBox(height: 1),
                                Text(
                                  'Update cooperative profile and security PIN',
                                  style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.textMuted),
                            onPressed: isSaving ? null : () => Navigator.pop(dialogContext),
                          ),
                        ],
                      ),
                      const Divider(height: 22, color: AppColors.borderSubtle),

                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.backgroundSlate,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.borderSubtle),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'User: @$_username',
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                            ),
                            Text(
                              'ID: $_coopId',
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.commuterTeal),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      TextFormField(
                        controller: coopNameController,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        decoration: _buildInputDeco('Cooperative Name *', Icons.corporate_fare_rounded),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Cooperative name is required' : null,
                      ),
                      const SizedBox(height: 10),

                      TextFormField(
                        controller: nameController,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        decoration: _buildInputDeco('Officer / Manager Name *', Icons.badge_outlined),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Officer name is required' : null,
                      ),
                      const SizedBox(height: 10),

                      TextFormField(
                        controller: pinController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 2),
                        decoration: _buildInputDeco('New sign-in PIN (6-8 digits, leave blank to keep)', Icons.lock_outline_rounded),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return null; // blank = keep current PIN
                          if (v.trim().length < 6 || v.trim().length > 8) return 'PIN must be 6 to 8 digits';
                          return null;
                        },
                      ),
                      const SizedBox(height: 18),

                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: AppColors.borderSubtle),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              onPressed: isSaving ? null : () => Navigator.pop(dialogContext),
                              child: const Text('Cancel', style: TextStyle(color: AppColors.darkSlate, fontSize: 12.5, fontWeight: FontWeight.w700)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primaryNavy,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              onPressed: isSaving
                                  ? null
                                  : () async {
                                      if (!formKey.currentState!.validate()) return;
                                      setDialogState(() => isSaving = true);
                                      try {
                                        final updatedName = nameController.text.trim();
                                        final updatedCoop = coopNameController.text.trim();
                                        final updatedPin = pinController.text.trim();

                                        await FirebaseFirestore.instance
                                            .collection('users')
                                            .doc(widget.userId)
                                            .update({
                                          'full_name': updatedName,
                                          'cooperative_name': updatedCoop,
                                        });

                                        if (updatedPin.isNotEmpty) {
                                          await StaffAuth.changeOwnPin(updatedPin);
                                        }

                                        setState(() {
                                          _fullName = updatedName;
                                          _coopName = updatedCoop;
                                          widget.userData['full_name'] = updatedName;
                                          widget.userData['cooperative_name'] = updatedCoop;
                                        });

                                        if (!mounted) return;
                                        Navigator.pop(dialogContext);
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            content: Text('Account updated successfully.'),
                                            backgroundColor: Color(0xFF059669),
                                            duration: Duration(seconds: 2),
                                          ),
                                        );
                                      } catch (e) {
                                        setDialogState(() => isSaving = false);
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('Failed: $e'), backgroundColor: AppColors.errorCrimson),
                                        );
                                      }
                                    },
                              child: isSaving
                                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                  : const Text('Save Changes', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // TAB 1: FLEET TELEMETRY (RESPONSIVE GRID)
  // ===========================================================================
  Widget _buildFleetTab() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isDesktop = constraints.maxWidth >= 850;
        final bool roomy = constraints.maxWidth >= 640;
        final double pad = isDesktop ? 28 : 16;

        return StreamBuilder<QuerySnapshot>(
          stream: _vehiclesStream,
          builder: (context, snapshot) {
            if (!snapshot.hasData && !snapshot.hasError) {
              return const Center(child: CircularProgressIndicator(color: AppColors.commuterTeal));
            }

            final allDocs = snapshot.data?.docs ?? [];
            final coopDocs = allDocs.where((d) => _matchesCooperative(d.data() as Map<String, dynamic>)).toList();

            final Set<String> availableRoutes = {'ALL'};
            int enRouteCount = 0;
            for (var d in coopDocs) {
              final data = d.data() as Map<String, dynamic>;
              final r = data['route_id']?.toString() ?? '';
              if (r.isNotEmpty) availableRoutes.add(r);
              if ((data['current_status'] ?? '').toString().toUpperCase() == 'EN_ROUTE') enRouteCount++;
            }
            final standbyCount = coopDocs.length - enRouteCount;

            final q = _fleetSearchQuery.trim().toLowerCase();
            final filteredDocs = coopDocs.where((d) {
              final data = d.data() as Map<String, dynamic>;
              final plate = (data['plate_number'] ?? d.id).toString().toLowerCase();
              final vName = (data['vehicle_name'] ?? '').toString().toLowerCase();
              final driver = (data['driver_name'] ?? '').toString().toLowerCase();
              final owner = (data['member_owner'] ?? data['operator_name'] ?? '').toString().toLowerCase();
              final status = (data['current_status'] ?? 'STANDBY').toString().toUpperCase();
              final route = (data['route_id'] ?? '').toString();

              if (q.isNotEmpty && !plate.contains(q) && !vName.contains(q) && !driver.contains(q) && !owner.contains(q)) return false;
              if (_fleetStatusFilter != 'ALL' && status != _fleetStatusFilter) return false;
              if (_fleetRouteFilter != 'ALL' && route != _fleetRouteFilter) return false;
              return true;
            }).toList();

            final bool filtering = q.isNotEmpty || _fleetStatusFilter != 'ALL' || _fleetRouteFilter != 'ALL';
            void clearFilters() => setState(() {
                  _fleetSearchQuery = '';
                  _fleetSearchCtrl.clear();
                  _fleetStatusFilter = 'ALL';
                  _fleetRouteFilter = 'ALL';
                });

            final searchField = CoopSearchField(
              controller: _fleetSearchCtrl,
              hint: 'Search plate, body name, driver or owner',
              onChanged: (val) => setState(() => _fleetSearchQuery = val),
            );

            final routeSelect = PopupMenuButton<String>(
              offset: const Offset(0, 50),
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: AppColors.borderSubtle),
              ),
              color: Colors.white,
              onSelected: (v) => setState(() => _fleetRouteFilter = v),
              itemBuilder: (context) => availableRoutes
                  .map((r) => _buildPopupMenuItem(r, r == 'ALL' ? 'All routes' : _formatRouteName(r), Icons.alt_route_rounded, AppColors.primaryNavy))
                  .toList(),
              child: CoopSelectPill(
                icon: Icons.alt_route_rounded,
                label: _fleetRouteFilter == 'ALL' ? 'All routes' : _formatRouteName(_fleetRouteFilter),
                active: _fleetRouteFilter != 'ALL',
              ),
            );

            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1240),
                child: ListView(
                  padding: EdgeInsets.fromLTRB(pad, 16, pad, 96),
                  children: [
                    if (roomy)
                      Row(children: [
                        Expanded(child: searchField),
                        const SizedBox(width: 10),
                        SizedBox(width: 240, child: routeSelect),
                      ])
                    else ...[
                      searchField,
                      const SizedBox(height: 10),
                      routeSelect,
                    ],
                    const SizedBox(height: 12),
                    CoopChoiceChips(
                      value: _fleetStatusFilter,
                      onChanged: (v) => setState(() => _fleetStatusFilter = v),
                      choices: [
                        CoopChoice('ALL', 'All units', count: coopDocs.length),
                        CoopChoice('EN_ROUTE', 'On the road', count: enRouteCount),
                        CoopChoice('STANDBY', 'Standby', count: standbyCount),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Showing ${filteredDocs.length} of ${coopDocs.length} unit${coopDocs.length == 1 ? '' : 's'}',
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.textMuted),
                          ),
                        ),
                        if (filtering)
                          TextButton(
                            onPressed: clearFilters,
                            child: const Text('Clear filters', style: TextStyle(fontWeight: FontWeight.w800)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (coopDocs.isEmpty)
                      CoopEmptyState(
                        icon: Icons.directions_bus_outlined,
                        title: 'No jeepneys enrolled yet',
                        message: 'Add your first unit to start tracking it.',
                        actionLabel: 'Add jeepney',
                        onAction: _showAddJeepneyModal,
                      )
                    else if (filteredDocs.isEmpty)
                      CoopEmptyState(
                        icon: Icons.search_off_rounded,
                        title: 'No units match',
                        message: 'Try a different search, or clear the filters.',
                        actionLabel: 'Clear filters',
                        onAction: clearFilters,
                      )
                    else if (isDesktop)
                      GridView.builder(
                        physics: const NeverScrollableScrollPhysics(),
                        shrinkWrap: true,
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 560,
                          mainAxisExtent: 176,
                          crossAxisSpacing: 14,
                          mainAxisSpacing: 14,
                        ),
                        itemCount: filteredDocs.length,
                        itemBuilder: (context, index) {
                          final doc = filteredDocs[index];
                          return _buildCoopVehicleTile(doc.data() as Map<String, dynamic>, doc.id, inGrid: true);
                        },
                      )
                    else
                      ...filteredDocs.map((doc) => SizedBox(
                            height: 176,
                            child: _buildCoopVehicleTile(doc.data() as Map<String, dynamic>, doc.id, inGrid: true),
                          )).expand((w) => [w, const SizedBox(height: 12)]),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ===========================================================================
  // TAB 2: LIVE MAP
  // ===========================================================================
  Widget _buildMapTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('vehicles_live').snapshots(),
      builder: (context, snapshot) {
        final allDocs = snapshot.data?.docs ?? [];
        final docs = allDocs.where((d) => _matchesCooperative(d.data() as Map<String, dynamic>)).toList();
        final markers = <Marker>[];

        for (var doc in docs) {
          final data = doc.data() as Map<String, dynamic>;
          final loc = data['location'] as Map<String, dynamic>?;
          final plate = (data['plate_number'] ?? doc.id).toString();
          final jeepName = (data['vehicle_name'] ?? plate).toString();
          final speed = (data['speed_kmh'] as num?)?.toInt() ?? 0;
          final status = (data['current_status'] ?? 'STANDBY').toString().toUpperCase();
          final isEnRoute = status == 'EN_ROUTE';
          final dotColor = _resolveVehicleDotColor(data['vehicle_color']?.toString());

          double? rawLat;
          double? rawLng;

          if (loc != null && loc['latitude'] != null && loc['longitude'] != null) {
            rawLat = (loc['latitude'] as num).toDouble();
            rawLng = (loc['longitude'] as num).toDouble();
          } else if (data['latitude'] != null && data['longitude'] != null) {
            rawLat = (data['latitude'] as num).toDouble();
            rawLng = (data['longitude'] as num).toDouble();
          }

          final double? finalLat = rawLat;
          final double? finalLng = rawLng;

          if (finalLat != null && finalLng != null) {
            markers.add(
              Marker(
                point: LatLng(finalLat, finalLng),
                width: 140,
                height: 56,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: isEnRoute ? AppColors.primaryNavy.withOpacity(0.92) : const Color(0xFF475569),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: Colors.white70, width: 1),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
                      ),
                      child: Text(
                        '$jeepName • $speed km/h',
                        maxLines: 1,
                        style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                    ),
                  ],
                ),
              ),
            );
          }
        }

        return Stack(
          children: [
            FlutterMap(
              options: const MapOptions(
                initialCenter: _defaultAntiqueCenter,
                initialZoom: 12.0,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.puj_dispatch_system',
                ),
                MarkerLayer(markers: markers),
              ],
            ),
            Positioned(
              top: 12,
              left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.borderSubtle),
                  boxShadow: const [BoxShadow(color: Color(0x290F172A), blurRadius: 10, offset: Offset(0, 3))],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${markers.length} of ${docs.length} units on the map',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.darkSlate)),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _legendDot(AppColors.primaryNavy, 'On the road'),
                        const SizedBox(width: 14),
                        _legendDot(const Color(0xFF475569), 'Standby'),
                      ],
                    ),
                    if (docs.length > markers.length) ...[
                      const SizedBox(height: 6),
                      Text('${docs.length - markers.length} without a GPS signal',
                          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: CoopTone.warning.fg)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ===========================================================================
  // TAB 3: DISPATCHERS ROSTER
  // ===========================================================================
  Widget _buildDispatchersTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: _dispatchersStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) {
          return const Center(child: CircularProgressIndicator(color: AppColors.commuterTeal));
        }

        final allDocs = snapshot.data?.docs.where((d) => _matchesCooperative(d.data() as Map<String, dynamic>)).toList() ?? [];

        final docs = allDocs.where((d) {
          final data = d.data() as Map<String, dynamic>;
          final name = (data['full_name'] ?? '').toString().toLowerCase();
          final username = (data['username'] ?? '').toString().toLowerCase();
          final terminal = (data['assigned_terminal'] ?? '').toString();
          final q = _dispatcherSearchQuery.trim().toLowerCase();

          if (q.isNotEmpty && !name.contains(q) && !username.contains(q)) {
            return false;
          }
          if (_dispatcherTerminalFilter != 'ALL' && !terminal.contains(_dispatcherTerminalFilter)) {
            return false;
          }
          return true;
        }).toList();

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              padding: const EdgeInsets.all(18),
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: TextField(
                            controller: _dispatcherSearchCtrl,
                            onChanged: (val) => setState(() => _dispatcherSearchQuery = val),
                            style: const TextStyle(fontSize: 13),
                            decoration: InputDecoration(
                              hintText: 'Search dispatcher by name...',
                              hintStyle: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                              prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppColors.textMuted),
                              contentPadding: EdgeInsets.zero,
                              filled: true,
                              fillColor: AppColors.backgroundSlate,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),

                      PopupMenuButton<String>(
                        offset: const Offset(0, 44),
                        elevation: 4,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: const BorderSide(color: AppColors.borderSubtle),
                        ),
                        color: Colors.white,
                        onSelected: (v) => setState(() => _dispatcherTerminalFilter = v),
                        itemBuilder: (context) => [
                          _buildPopupMenuItem('ALL', 'All Terminals', Icons.location_city_rounded, AppColors.primaryNavy),
                          _buildPopupMenuItem('ROBINSON', 'Robinsons Terminal', Icons.storefront_rounded, const Color(0xFF1D4ED8)),
                          _buildPopupMenuItem('DALIPE', 'Dalipe Terminal', Icons.directions_bus_rounded, AppColors.commuterTeal),
                        ],
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.backgroundSlate,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.borderSubtle.withOpacity(0.5)),
                          ),
                          child: Row(
                            children: [
                              Text(
                                _getDispatcherTerminalLabel(_dispatcherTerminalFilter),
                                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                              ),
                              const SizedBox(width: 6),
                              const Icon(Icons.expand_more_rounded, size: 18, color: AppColors.primaryNavy),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                if (docs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(28.0),
                    child: Center(
                      child: Text('No dispatchers match the filter criteria.', style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
                    ),
                  )
                else
                  ...docs.map((doc) {
                    final d = doc.data() as Map<String, dynamic>;
                    final name = (d['full_name'] ?? 'Terminal Officer').toString();
                    final contact = (d['contact_number'] ?? 'N/A').toString();
                    final rawTerminal = (d['assigned_terminal'] ?? 'General Post').toString();
                    final rawRoute = (d['assigned_route'] ?? 'All Routes').toString();
                    final terminal = _formatTerminalName(rawTerminal);
                    final route = _formatRouteName(rawRoute);
                    final pin = (d['pin_code'] ?? '****').toString();

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          backgroundColor: AppColors.primaryNavy.withOpacity(0.08),
                          child: const Icon(Icons.person_pin_circle_rounded, color: AppColors.primaryNavy, size: 22),
                        ),
                        title: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: AppColors.darkSlate)),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.campaign_rounded, size: 13, color: Color(0xFFD97706)),
                                  label: const Text('Notice', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFD97706))),
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(color: Color(0xFFFDE68A)),
                                    backgroundColor: const Color(0xFFFFFBEB),
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: () => _showCreateNoticeModal(
                                    preselectedUserId: doc.id,
                                    preselectedUserName: name,
                                    preselectedRole: 'DISPATCHER',
                                  ),
                                ),
                                const SizedBox(width: 6),
                                OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(color: AppColors.borderSubtle),
                                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: () => _showResetPinModal(
                                    targetUserId: doc.id,
                                    targetUserName: name,
                                    targetRole: 'Dispatcher',
                                    currentPin: pin,
                                  ),
                                  child: const Text('Reset PIN', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: AppColors.primaryNavy)),
                                ),
                              ],
                            ),
                          ],
                        ),
                        subtitle: Text('Terminal: $terminal\nRoute: $route • Ph: $contact', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                      ),
                    );
                  }),
              ],
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================
  // TAB 5: QUEUE AUDITS
  // ===========================================================================
  Widget _buildQueueAuditsTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: _auditLogStream(),
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) {
          return const Center(child: CircularProgressIndicator(color: AppColors.commuterTeal));
        }

        final rawDocs = List<QueryDocumentSnapshot>.from(snapshot.data?.docs ?? []);

        rawDocs.sort((a, b) {
          final Timestamp? tA = (a.data() as Map<String, dynamic>)['timestamp'] as Timestamp?;
          final Timestamp? tB = (b.data() as Map<String, dynamic>)['timestamp'] as Timestamp?;
          if (tA == null && tB == null) return 0;
          if (tA == null) return 1;
          if (tB == null) return -1;
          return tB.compareTo(tA);
        });

        final docs = rawDocs.where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          final reason = (data['reason'] ?? '').toString().toLowerCase();
          final dispatcher = (data['dispatcher_name'] ?? '').toString().toLowerCase();
          final affectedCoops = (data['affected_cooperative_names'] as List<dynamic>?) ?? [];
          final isCross = affectedCoops.length > 1;

          final q = _auditSearchQuery.trim().toLowerCase();
          if (q.isNotEmpty && !reason.contains(q) && !dispatcher.contains(q)) {
            return false;
          }
          if (_auditTypeFilter == 'CROSS_COOP' && !isCross) {
            return false;
          }
          if (_auditTypeFilter == 'INTERNAL' && isCross) {
            return false;
          }
          return true;
        }).toList();

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              padding: const EdgeInsets.all(18),
              children: [
                Row(
                  children: [
                    _buildKpiCard('QUEUE OVERRIDES', '${rawDocs.length}', Icons.swap_vert_circle_rounded, const Color(0xFFD97706)),
                  ],
                ),
                const SizedBox(height: 14),

                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: TextField(
                            controller: _auditSearchCtrl,
                            onChanged: (val) => setState(() => _auditSearchQuery = val),
                            style: const TextStyle(fontSize: 13),
                            decoration: InputDecoration(
                              hintText: 'Search by reason or dispatcher...',
                              hintStyle: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                              prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppColors.textMuted),
                              contentPadding: EdgeInsets.zero,
                              filled: true,
                              fillColor: AppColors.backgroundSlate,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),

                      PopupMenuButton<String>(
                        offset: const Offset(0, 44),
                        elevation: 4,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: const BorderSide(color: AppColors.borderSubtle),
                        ),
                        color: Colors.white,
                        onSelected: (v) => setState(() => _auditTypeFilter = v),
                        itemBuilder: (context) => [
                          _buildPopupMenuItem('ALL', 'All Events', Icons.tune_rounded, AppColors.primaryNavy),
                          _buildPopupMenuItem('CROSS_COOP', 'Cross-Coop', Icons.swap_vert_circle_rounded, const Color(0xFFD97706)),
                          _buildPopupMenuItem('INTERNAL', 'Internal Only', Icons.shield_outlined, const Color(0xFF2563EB)),
                        ],
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.backgroundSlate,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.borderSubtle.withOpacity(0.5)),
                          ),
                          child: Row(
                            children: [
                              Text(
                                _getAuditTypeLabel(_auditTypeFilter),
                                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                              ),
                              const SizedBox(width: 6),
                              const Icon(Icons.expand_more_rounded, size: 18, color: AppColors.primaryNavy),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                if (docs.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Column(
                        children: [
                          Icon(Icons.verified_user_outlined, size: 48, color: AppColors.textMuted.withOpacity(0.5)),
                          const SizedBox(height: 10),
                          const Text('No Queue Alterations Recorded', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5, color: AppColors.darkSlate)),
                          const SizedBox(height: 4),
                          Text(
                            'Dispatcher overrides affecting $_coopName will appear here with full transparency notes.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  ...docs.map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final reason = (data['reason'] ?? 'No operational reason recorded.').toString();
                    final dispatcher = (data['dispatcher_name'] ?? 'Dispatcher').toString();
                    final route = _formatRouteName((data['route_id'] ?? '').toString());
                    final prevOrder = (data['previous_order'] as List<dynamic>?)?.map((e) => e.toString()).join(' ➔ ') ?? 'None';
                    final newOrder = (data['new_order'] as List<dynamic>?)?.map((e) => e.toString()).join(' ➔ ') ?? 'None';
                    final affectedCoops = (data['affected_cooperative_names'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
                    final Timestamp? ts = data['timestamp'] as Timestamp?;
                    final dateStr = ts != null ? ts.toDate().toLocal().toString().substring(0, 16) : 'Just now';

                    final isCrossCoop = affectedCoops.length > 1;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isCrossCoop ? const Color(0xFFF59E0B) : AppColors.borderSubtle,
                          width: isCrossCoop ? 1.3 : 1.0,
                        ),
                        boxShadow: const [BoxShadow(color: Color(0x04000000), blurRadius: 4, offset: Offset(0, 1.5))],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                                  decoration: BoxDecoration(
                                    color: isCrossCoop ? const Color(0xFFFEF3C7) : const Color(0xFFEFF6FF),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    isCrossCoop ? 'CROSS-COOPERATIVE OVERRIDE' : 'INTERNAL OVERRIDE',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w900,
                                      color: isCrossCoop ? const Color(0xFF92400E) : const Color(0xFF1D4ED8),
                                    ),
                                  ),
                                ),
                                Text(
                                  dateStr,
                                  style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),

                            Text(
                              'Operational Reason: "$reason"',
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w800,
                                color: AppColors.darkSlate,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Route: $route • Authorized by: $dispatcher',
                              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                            ),
                            const Divider(height: 16, color: AppColors.borderSubtle),

                            if (isCrossCoop) ...[
                              Row(
                                children: [
                                  const Icon(Icons.corporate_fare_rounded, size: 15, color: Color(0xFFD97706)),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Involved Cooperatives: ${affectedCoops.join(" & ")}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF92400E),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                            ],

                            Text(
                              'Previous Order: $prevOrder',
                              style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'New Order: $newOrder',
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF1D4ED8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================
  // TAB 6: COMPLAINTS & INCIDENTS (DESKTOP OPTIMIZED)
  // ===========================================================================
  DateTime? _parseComplaintDate(dynamic val) {
    if (val is Timestamp) return val.toDate();
    if (val is String) return DateTime.tryParse(val);
    return null;
  }

  bool _matchesComplaintStatus(String rawStatus) {
    final s = rawStatus.trim().toUpperCase();
    if (_selectedStatusFilter == 'ALL') return true;
    if (_selectedStatusFilter == 'PENDING') return s.contains('PENDING');
    if (_selectedStatusFilter == 'UNDER_REVIEW') return s.contains('REVIEW') || s.contains('INVESTIGAT');
    if (_selectedStatusFilter == 'RESOLVED') return s.contains('RESOLVED');
    return false;
  }

  bool _matchesComplaintDate(DateTime? dt) {
    // 'All time' shows everything, even reports with no timestamp.
    if (_selectedDateFilter == 'ALL') return true;
    if (dt == null) return false;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final itemDate = DateTime(dt.year, dt.month, dt.day);

    if (_selectedDateFilter == 'TODAY') {
      return itemDate.isAtSameMomentAs(today);
    } else if (_selectedDateFilter == '7DAYS') {
      final sevenDaysAgo = today.subtract(const Duration(days: 7));
      return itemDate.isAfter(sevenDaysAgo.subtract(const Duration(seconds: 1)));
    } else if (_selectedDateFilter == 'CUSTOM' && _customDateRange != null) {
      final start = DateTime(_customDateRange!.start.year, _customDateRange!.start.month, _customDateRange!.start.day);
      final end = DateTime(_customDateRange!.end.year, _customDateRange!.end.month, _customDateRange!.end.day, 23, 59, 59);
      return dt.isAfter(start.subtract(const Duration(seconds: 1))) && dt.isBefore(end.add(const Duration(seconds: 1)));
    }
    return true;
  }

  String _normalizeStatusKey(String raw) {
    final s = raw.toUpperCase();
    if (s.contains('RESOLVED')) return 'RESOLVED';
    if (s.contains('REVIEW') || s.contains('INVESTIGAT')) return 'UNDER_REVIEW';
    return 'PENDING_VERIFICATION';
  }

  Future<void> _updateComplaintStatus(String docId, String newStatus) async {
    try {
      await FirebaseFirestore.instance.collection('complaints').doc(docId).update({
        'status': newStatus,
        'updated_at': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Status updated to ${newStatus.replaceAll('_', ' ')}.'),
          backgroundColor: const Color(0xFF059669),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e'), backgroundColor: AppColors.errorCrimson),
      );
    }
  }

  Future<void> _addCooperativeComment(String docId, String comment) async {
    if (comment.trim().isEmpty) return;

    try {
      await FirebaseFirestore.instance.collection('complaints').doc(docId).update({
        'cooperative_comments': FieldValue.arrayUnion([
          {
            'author_name': _fullName,
            'coop_name': _coopName,
            'message': comment.trim(),
            'created_at': Timestamp.now(),
          }
        ]),
        'latest_coop_comment': comment.trim(),
        'updated_at': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Action note recorded successfully.'),
          backgroundColor: Color(0xFF059669),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to post comment: $e'),
          backgroundColor: AppColors.errorCrimson,
        ),
      );
    }
  }

  Widget _buildStatusDropdownPill({
    required String docId,
    required String currentStatus,
    bool isFullWidth = false,
  }) {
    Color bg;
    Color border;
    Color text;
    IconData icon;

    switch (currentStatus) {
      case 'RESOLVED':
        bg = const Color(0xFFECFDF5);
        border = const Color(0xFFA7F3D0);
        text = const Color(0xFF065F46);
        icon = Icons.check_circle_rounded;
        break;
      case 'UNDER_REVIEW':
        bg = const Color(0xFFEFF6FF);
        border = const Color(0xFFBFDBFE);
        text = const Color(0xFF1D4ED8);
        icon = Icons.hourglass_top_rounded;
        break;
      case 'PENDING_VERIFICATION':
      default:
        bg = const Color(0xFFFEF3C7);
        border = const Color(0xFFFCD34D);
        text = const Color(0xFFB45309);
        icon = Icons.pending_actions_rounded;
        break;
    }

    return PopupMenuButton<String>(
      offset: const Offset(0, 38),
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.borderSubtle),
      ),
      color: Colors.white,
      onSelected: (newVal) {
        if (newVal != currentStatus) {
          _updateComplaintStatus(docId, newVal);
        }
      },
      itemBuilder: (context) => [
        _buildPopupMenuItem('PENDING_VERIFICATION', 'Pending', Icons.pending_actions_rounded, const Color(0xFFD97706)),
        _buildPopupMenuItem('UNDER_REVIEW', 'Under Review', Icons.hourglass_top_rounded, const Color(0xFF2563EB)),
        _buildPopupMenuItem('RESOLVED', 'Resolved', Icons.check_circle_rounded, const Color(0xFF059669)),
      ],
      child: Container(
        width: isFullWidth ? double.infinity : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border, width: 1.1),
        ),
        child: Row(
          mainAxisSize: isFullWidth ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: text),
                const SizedBox(width: 6),
                Text(
                  _getStatusLabel(currentStatus),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: text),
                ),
              ],
            ),
            const SizedBox(width: 6),
            Icon(Icons.expand_more_rounded, size: 16, color: text),
          ],
        ),
      ),
    );
  }

  void _showComplaintDetailModal(DocumentSnapshot doc) {
    final cData = doc.data() as Map<String, dynamic>;
    final category = (cData['category'] ?? 'General Infraction').toString();
    final plate = (cData['plate_number'] ?? 'N/A').toString();
    final desc = (cData['description'] ?? 'No description provided.').toString();
    final complainant = (cData['complainant_name'] ?? 'Passenger').toString();
    final contact = (cData['complainant_contact'] ?? 'N/A').toString();
    final statusKey = _normalizeStatusKey((cData['status'] ?? 'PENDING_VERIFICATION').toString());
    final Timestamp? ts = cData['created_at'] as Timestamp?;
    final dateStr = ts != null ? ts.toDate().toLocal().toString().substring(0, 16) : 'Recent';

    final commentController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool isPosting = false;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setModalState) {
          return SafeArea(
            child: Dialog(
              backgroundColor: Colors.white,
              elevation: 6,
              insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppColors.borderSubtle),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500, maxHeight: 680),
                child: StreamBuilder<DocumentSnapshot>(
                  stream: FirebaseFirestore.instance.collection('complaints').doc(doc.id).snapshots(),
                  builder: (context, snapshot) {
                    final currentData = snapshot.data?.data() as Map<String, dynamic>? ?? cData;
                    final rawList = currentData['cooperative_comments'] as List<dynamic>? ?? [];
                    final comments = rawList.reversed.toList();
                    final currentStatus = _normalizeStatusKey((currentData['status'] ?? statusKey).toString());

                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(22),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: AppColors.errorCrimson.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.report_problem_rounded,
                                  color: AppColors.errorCrimson,
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      category,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 16.5,
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.darkSlate,
                                      ),
                                    ),
                                    Text(
                                      'Reported on $dateStr',
                                      style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              _buildLicenseBadge(plate, fontSize: 12.5),
                              const SizedBox(width: 4),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.close_rounded, size: 22, color: AppColors.textMuted),
                                onPressed: () => Navigator.pop(dialogContext),
                              ),
                            ],
                          ),
                          const Divider(height: 22, color: AppColors.borderSubtle),

                          const Text(
                            'Incident Description',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.backgroundSlate,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.borderSubtle),
                            ),
                            child: Text(
                              desc,
                              style: const TextStyle(fontSize: 13, height: 1.35, color: AppColors.darkSlate),
                            ),
                          ),
                          const SizedBox(height: 10),

                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppColors.backgroundSlate,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.person_outline_rounded, size: 18, color: AppColors.primaryNavy),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Complainant: $complainant ($contact)',
                                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.darkSlate),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),

                          const Text(
                            'Update Investigation Status',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                          ),
                          const SizedBox(height: 6),
                          _buildStatusDropdownPill(
                            docId: doc.id,
                            currentStatus: currentStatus,
                            isFullWidth: true,
                          ),
                          ComplaintSuspensionPanel(
                            plate: plate,
                            complaintId: doc.id,
                            complaintCategory: category,
                            officerName: _fullName,
                            coopId: _coopId,
                            coopName: _coopName,
                            belongsToCoop: _matchesCooperative,
                          ),
                          const Divider(height: 24, color: AppColors.borderSubtle),

                          Row(
                            children: [
                              const Icon(Icons.forum_outlined, size: 17, color: AppColors.primaryNavy),
                              const SizedBox(width: 6),
                              const Text(
                                'Cooperative Actions & Remarks',
                                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: AppColors.darkSlate),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEFF6FF),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '${comments.length} notes',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1D4ED8)),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),

                          if (comments.isEmpty)
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppColors.backgroundSlate,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: AppColors.borderSubtle),
                              ),
                              child: const Center(
                                child: Text(
                                  'No notes recorded yet. Add actions taken below.',
                                  style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                                ),
                              ),
                            )
                          else
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 160),
                              child: ListView.builder(
                                shrinkWrap: true,
                                itemCount: comments.length,
                                itemBuilder: (ctx, i) {
                                  final item = comments[i] as Map<String, dynamic>;
                                  final author = item['author_name'] ?? 'Officer';
                                  final coop = item['coop_name'] ?? '';
                                  final msg = item['message'] ?? '';
                                  final cTs = item['created_at'] as Timestamp?;
                                  final time = cTs != null ? cTs.toDate().toLocal().toString().substring(5, 16) : '';

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 6),
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF8FAFC),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: const Color(0xFFE2E8F0)),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              '$author ($coop)',
                                              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.primaryNavy),
                                            ),
                                            Text(time, style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted)),
                                          ],
                                        ),
                                        const SizedBox(height: 3),
                                        Text(msg, style: const TextStyle(fontSize: 12.5, color: AppColors.darkSlate, height: 1.25)),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          const SizedBox(height: 12),

                          Form(
                            key: formKey,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: commentController,
                                    maxLines: 2,
                                    style: const TextStyle(fontSize: 13),
                                    decoration: InputDecoration(
                                      hintText: 'e.g. Driver issued 1st warning; summoned for mediation...',
                                      hintStyle: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                                      filled: true,
                                      fillColor: AppColors.backgroundSlate,
                                      isDense: true,
                                      contentPadding: const EdgeInsets.all(10),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: const BorderSide(color: AppColors.borderSubtle),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: const BorderSide(color: AppColors.primaryNavy, width: 1.2),
                                      ),
                                    ),
                                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a comment' : null,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.primaryNavy,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    elevation: 0,
                                  ),
                                  onPressed: isPosting
                                      ? null
                                      : () async {
                                          if (!formKey.currentState!.validate()) return;
                                          setModalState(() => isPosting = true);
                                          await _addCooperativeComment(doc.id, commentController.text);
                                          commentController.clear();
                                          setModalState(() => isPosting = false);
                                        },
                                  child: isPosting
                                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                      : const Text('Post', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),

                          SizedBox(
                            height: 40,
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: AppColors.borderSubtle),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () => Navigator.pop(dialogContext),
                              child: const Text('Close', style: TextStyle(color: AppColors.darkSlate, fontSize: 13, fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ===========================================================================
  // TAB 6: COMPLAINTS TAB LIST
  // ===========================================================================
  Widget _buildComplaintsTab() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isDesktop = constraints.maxWidth >= 850;

        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection('vehicles_live').snapshots(),
          builder: (context, vSnapshot) {
            if (vSnapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator(color: AppColors.commuterTeal));
            }

            final Set<String> coopPlates = {};
            for (var doc in vSnapshot.data?.docs ?? []) {
              final data = doc.data() as Map<String, dynamic>;
              if (_matchesCooperative(data)) {
                coopPlates.add(_normalizePlate(doc.id));
                if (data['plate_number'] != null) {
                  coopPlates.add(_normalizePlate(data['plate_number'].toString()));
                }
              }
            }

            return StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('complaints').snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator(color: AppColors.commuterTeal));
                }

                final allDocs = snapshot.data?.docs ?? [];
                final coopDocs = allDocs.where((d) {
                  final cData = d.data() as Map<String, dynamic>;
                  if (_matchesCooperative(cData)) return true;
                  final cPlate = _normalizePlate(cData['plate_number']?.toString() ?? '');
                  return cPlate.isNotEmpty && coopPlates.contains(cPlate);
                }).toList();

                final totalCoop = coopDocs.length;
                final pendingCoop = coopDocs.where((d) => (d['status'] ?? '').toString().toUpperCase().contains('PENDING')).length;
                final resolvedCoop = coopDocs.where((d) => (d['status'] ?? '').toString().toUpperCase().contains('RESOLVED')).length;

                final filteredDocs = coopDocs.where((d) {
                  final cData = d.data() as Map<String, dynamic>;
                  return _matchesComplaintStatus((cData['status'] ?? '').toString()) &&
                      _matchesComplaintDate(_parseComplaintDate(cData['created_at']));
                }).toList();

                filteredDocs.sort((a, b) {
                  final dtA = _parseComplaintDate((a.data() as Map<String, dynamic>)['created_at']);
                  final dtB = _parseComplaintDate((b.data() as Map<String, dynamic>)['created_at']);
                  if (dtA == null && dtB == null) return 0;
                  if (dtA == null) return 1;
                  if (dtB == null) return -1;
                  return dtB.compareTo(dtA);
                });

                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1200),
                    child: ListView(
                      padding: const EdgeInsets.all(18),
                      children: [
                        Row(
                          children: [
                            _buildKpiCard('ALL REPORTS', '$totalCoop', Icons.report_outlined, AppColors.primaryNavy, isDesktop: isDesktop),
                            const SizedBox(width: 8),
                            _buildKpiCard('PENDING', '$pendingCoop', Icons.pending_actions_rounded, const Color(0xFFD97706), isDesktop: isDesktop),
                            const SizedBox(width: 8),
                            _buildKpiCard('RESOLVED', '$resolvedCoop', Icons.check_circle_outline_rounded, const Color(0xFF059669), isDesktop: isDesktop),
                          ],
                        ),
                        const SizedBox(height: 14),

                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.borderSubtle),
                            boxShadow: const [BoxShadow(color: Color(0x02000000), blurRadius: 4, offset: Offset(0, 1.5))],
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: PopupMenuButton<String>(
                                  offset: const Offset(0, 44),
                                  elevation: 4,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: const BorderSide(color: AppColors.borderSubtle),
                                  ),
                                  color: Colors.white,
                                  onSelected: (val) => setState(() => _selectedStatusFilter = val),
                                  itemBuilder: (context) => [
                                    _buildPopupMenuItem('ALL', 'All Statuses', Icons.tune_rounded, AppColors.primaryNavy),
                                    _buildPopupMenuItem('PENDING', 'Pending', Icons.pending_actions_rounded, const Color(0xFFD97706)),
                                    _buildPopupMenuItem('UNDER_REVIEW', 'Under Review', Icons.hourglass_top_rounded, const Color(0xFF2563EB)),
                                    _buildPopupMenuItem('RESOLVED', 'Resolved', Icons.check_circle_rounded, const Color(0xFF059669)),
                                  ],
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: AppColors.backgroundSlate,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: AppColors.borderSubtle.withOpacity(0.5)),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            _getStatusLabel(_selectedStatusFilter),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                                          ),
                                        ),
                                        const Icon(Icons.expand_more_rounded, size: 18, color: AppColors.primaryNavy),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),

                              Expanded(
                                child: PopupMenuButton<String>(
                                  offset: const Offset(0, 44),
                                  elevation: 4,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: const BorderSide(color: AppColors.borderSubtle),
                                  ),
                                  color: Colors.white,
                                  onSelected: (val) async {
                                    if (val == 'CUSTOM') {
                                      final picked = await showDateRangePicker(
                                        context: context,
                                        firstDate: DateTime(2025, 1, 1),
                                        lastDate: DateTime.now().add(const Duration(days: 365)),
                                        initialDateRange: _customDateRange ??
                                            DateTimeRange(
                                              start: DateTime.now().subtract(const Duration(days: 7)),
                                              end: DateTime.now(),
                                            ),
                                      );
                                      if (picked != null) {
                                        setState(() {
                                          _customDateRange = picked;
                                          _selectedDateFilter = 'CUSTOM';
                                        });
                                      }
                                    } else {
                                      setState(() => _selectedDateFilter = val);
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    _buildPopupMenuItem('ALL', 'All time', Icons.all_inclusive_rounded, AppColors.commuterTeal),
                                    _buildPopupMenuItem('TODAY', 'Today', Icons.today_rounded, AppColors.commuterTeal),
                                    _buildPopupMenuItem('7DAYS', 'Past 7 Days', Icons.date_range_rounded, AppColors.commuterTeal),
                                    _buildPopupMenuItem('CUSTOM', 'Custom Range...', Icons.edit_calendar_rounded, AppColors.commuterTeal),
                                  ],
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: AppColors.backgroundSlate,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: AppColors.borderSubtle.withOpacity(0.5)),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            _getDateLabel(_selectedDateFilter),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                                          ),
                                        ),
                                        const Icon(Icons.expand_more_rounded, size: 18, color: AppColors.primaryNavy),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),

                        if (filteredDocs.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(32.0),
                            child: Center(
                              child: Text('No complaints match current filters.', style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
                            ),
                          )
                        else if (isDesktop)
                          GridView.builder(
                            physics: const NeverScrollableScrollPhysics(),
                            shrinkWrap: true,
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 580,
                              mainAxisExtent: 160,
                              crossAxisSpacing: 14,
                              mainAxisSpacing: 14,
                            ),
                            itemCount: filteredDocs.length,
                            itemBuilder: (context, index) {
                              final doc = filteredDocs[index];
                              return _buildComplaintCard(doc, inGrid: true);
                            },
                          )
                        else
                          ...filteredDocs.map((doc) => _buildComplaintCard(doc, inGrid: false)),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildComplaintCard(DocumentSnapshot doc, {bool inGrid = false}) {
    final cData = doc.data() as Map<String, dynamic>;
    final category = (cData['category'] ?? 'Infraction').toString();
    final plate = (cData['plate_number'] ?? 'N/A').toString();
    final desc = (cData['description'] ?? '').toString();
    final statusKey = _normalizeStatusKey((cData['status'] ?? 'PENDING_VERIFICATION').toString());
    final latestNote = (cData['latest_coop_comment'] ?? '').toString();

    return Container(
      margin: inGrid ? EdgeInsets.zero : const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: InkWell(
        onTap: () => _showComplaintDetailModal(doc),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(category.toUpperCase(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.errorCrimson)),
                  _buildStatusDropdownPill(docId: doc.id, currentStatus: statusKey),
                ],
              ),
              const SizedBox(height: 6),
              Text(desc, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: AppColors.darkSlate)),

              if (latestNote.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFBFDBFE), width: 0.8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.shield_outlined, size: 14, color: Color(0xFF1D4ED8)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Coop Action: $latestNote',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1E40AF),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const Divider(height: 16, color: AppColors.borderSubtle),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildLicenseBadge(plate, fontSize: 12),
                  const Text('Tap to review & respond', style: TextStyle(fontSize: 11.5, color: AppColors.commuterTeal, fontWeight: FontWeight.bold)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // POPUP HELPERS & LABELS
  // ===========================================================================
  PopupMenuItem<String> _buildPopupMenuItem(String value, String text, IconData icon, Color color) {
    return PopupMenuItem<String>(
      value: value,
      height: 40,
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color == AppColors.commuterTeal ? AppColors.darkSlate : color,
            ),
          ),
        ],
      ),
    );
  }

  String _getStatusLabel(String key) {
    switch (key) {
      case 'PENDING':
      case 'PENDING_VERIFICATION':
        return 'Pending';
      case 'UNDER_REVIEW':
        return 'Under Review';
      case 'RESOLVED':
        return 'Resolved';
      default:
        return 'All Statuses';
    }
  }

  String _getDateLabel(String key) {
    switch (key) {
      case 'ALL':
        return 'All time';
      case 'TODAY':
        return 'Today';
      case '7DAYS':
        return 'Past 7 Days';
      case 'CUSTOM':
        return _customDateRange != null
            ? '${_customDateRange!.start.month}/${_customDateRange!.start.day}-${_customDateRange!.end.month}/${_customDateRange!.end.day}'
            : 'Custom Range';
      default:
        return 'Past 7 Days';
    }
  }

  String _getFleetStatusLabel(String key) {
    switch (key) {
      case 'EN_ROUTE':
        return 'En Route (Biyahe)';
      case 'STANDBY':
        return 'Standby';
      default:
        return 'All Statuses';
    }
  }

  String _getDispatcherTerminalLabel(String key) {
    switch (key) {
      case 'ROBINSON':
        return 'Robinsons Terminal';
      case 'DALIPE':
        return 'Dalipe Terminal';
      default:
        return 'All Terminals';
    }
  }

  String _getAuditTypeLabel(String key) {
    switch (key) {
      case 'CROSS_COOP':
        return 'Cross-Coop';
      case 'INTERNAL':
        return 'Internal Only';
      default:
        return 'All Events';
    }
  }

  // ===========================================================================
  // COMPACT & LOW-PROFILE KPI CARD (OPTIMIZED FOR ANDROID & DESKTOP)
  // ===========================================================================
  String _sentence(String s) {
    final t = s.trim();
    if (t.isEmpty) return t;
    return t[0].toUpperCase() + t.substring(1).toLowerCase();
  }

  // Compact stat used at the top of the Drivers / Dispatchers / Complaints tabs.
  Widget _buildKpiCard(String title, String val, IconData icon, Color col, {bool isDesktop = false}) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 14 : 10, vertical: isDesktop ? 12 : 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: Row(
          children: [
            Container(
              width: isDesktop ? 36 : 30,
              height: isDesktop ? 36 : 30,
              decoration: BoxDecoration(
                color: col.withOpacity(0.10),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: isDesktop ? 19 : 16, color: col),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(val,
                      style: TextStyle(
                          fontSize: isDesktop ? 22 : 19,
                          fontWeight: FontWeight.w900,
                          height: 1.05,
                          letterSpacing: -0.4,
                          color: AppColors.darkSlate)),
                  Text(_sentence(title),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: isDesktop ? 12 : 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLicenseBadge(String plate, {double fontSize = 12.5}) =>
      CoopPlate(plate, fontSize: fontSize);

  Widget _buildCoopVehicleTile(Map<String, dynamic> vData, String docId, {bool inGrid = false}) {
    final plate = (vData['plate_number'] ?? docId).toString();
    final jeepName = (vData['vehicle_name'] ?? plate).toString();
    final driverName = (vData['driver_name'] ?? '').toString();
    final ownerName = (vData['member_owner'] ?? vData['operator_name'] ?? 'Coop member').toString();
    final status = (vData['current_status'] ?? 'STANDBY').toString().toUpperCase();
    final isEnRoute = status == 'EN_ROUTE';
    final route = _formatRouteName((vData['route_id'] ?? 'UNASSIGNED').toString());
    final speed = (vData['speed_kmh'] as num?)?.toInt() ?? 0;
    final seats = (vData['passenger_count'] as num?)?.toInt() ?? 0;
    final maxSeats = (vData['max_capacity'] as num?)?.toInt() ?? 20;
    final cpc = (vData['franchise_case_number'] ?? _coopCpc).toString();

    final noDriver = _isUnassignedDriver(driverName);
    final showName = jeepName.trim().toUpperCase() != plate.trim().toUpperCase();
    final fill = maxSeats > 0 ? (seats / maxSeats).clamp(0.0, 1.0) : 0.0;
    final barColor = !isEnRoute
        ? const Color(0xFFCBD5E1)
        : fill >= 1
            ? CoopTone.danger.fg
            : fill >= 0.8
                ? CoopTone.warning.fg
                : CoopTone.success.fg;

    return Container(
      margin: inGrid ? EdgeInsets.zero : const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isEnRoute ? CoopTone.success.line : AppColors.borderSubtle),
        boxShadow: const [BoxShadow(color: Color(0x0A0F172A), blurRadius: 10, offset: Offset(0, 3))],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _showVehicleDetailModal(vData, docId),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          CoopPlate(plate),
                          if (showName) ...[
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(jeepName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, color: AppColors.darkSlate)),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    CoopPill(
                      isEnRoute ? 'Biyahe  $speed km/h' : 'Standby',
                      tone: isEnRoute ? CoopTone.success : CoopTone.info,
                      icon: isEnRoute ? Icons.navigation_rounded : Icons.local_parking_rounded,
                    ),
                  ],
                ),
                Row(
                  children: [
                    Icon(noDriver ? Icons.person_off_outlined : Icons.person_rounded,
                        size: 17, color: noDriver ? CoopTone.warning.fg : AppColors.primaryNavy),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(noDriver ? 'No driver assigned' : driverName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: noDriver ? CoopTone.warning.fg : AppColors.darkSlate)),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(route,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: AppColors.commuterTeal)),
                    ),
                  ],
                ),
                Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(isEnRoute ? '$seats of $maxSeats seats taken' : 'Capacity $maxSeats seats',
                              style: const TextStyle(fontSize: 12, color: AppColors.textMuted, fontWeight: FontWeight.w600)),
                        ),
                        if (isEnRoute)
                          Text('${(fill * 100).round()}%',
                              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900, color: AppColors.darkSlate)),
                      ],
                    ),
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: isEnRoute ? fill : 0,
                        minHeight: 6,
                        backgroundColor: const Color(0xFFE2E8F0),
                        valueColor: AlwaysStoppedAnimation<Color>(barColor),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text('Owner: $ownerName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted, fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 8),
                    Text('Prangkisa $cpc',
                        maxLines: 1,
                        style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted, fontWeight: FontWeight.w600)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _buildInputDeco(String label, IconData icon, {String? hint, Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      labelStyle: const TextStyle(fontSize: 13, color: AppColors.textMuted),
      prefixIcon: Icon(icon, size: 18, color: AppColors.primaryNavy),
      suffixIcon: suffix,
      filled: true,
      fillColor: AppColors.backgroundSlate,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.borderSubtle),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.commuterTeal, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.errorCrimson),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.errorCrimson, width: 1.4),
      ),
    );
  }

  // Rotation (Tab 7): only built when _rotationRoutes is not empty. The host
  // shows a route picker when the coop owns more than one rotation route.
  Widget _buildRotationTab() {
    return RotationTabHost(
      coopId: _coopId,
      coopName: _coopName,
      actorName: _fullName,
      routes: _rotationRoutes,
      matchesCooperative: _matchesCooperative,
    );
  }

  // ===========================================================================
  // NAVIGATION + PAGE SHELL
  // ===========================================================================

  List<_Section> get _sections => [
        _Section.overview,
        _Section.fleet,
        _Section.map,
        _Section.people,
        _Section.reports,
        if (_rotationRoutes.isNotEmpty) _Section.rotation,
      ];

  _Section get _current {
    final s = _sections;
    return s[_tabController.index.clamp(0, s.length - 1)];
  }

  void _goTo(_Section s) {
    final i = _sections.indexOf(s);
    if (i < 0) return;
    _tabController.animateTo(i, duration: Duration.zero);
  }

  Widget _pageFor(_Section s) {
    switch (s) {
      case _Section.overview:
        return _buildOverviewTab();
      case _Section.fleet:
        return _buildFleetTab();
      case _Section.map:
        return _buildMapTab();
      case _Section.people:
        return _buildPeopleTab();
      case _Section.reports:
        return _buildReportsTab();
      case _Section.rotation:
        return _buildRotationTab();
    }
  }

  // Drivers | Dispatchers share one destination.
  Widget _buildPeopleTab() {
    return Column(
      children: [
        _segmentBar(
          labels: const ['Drivers', 'Dispatchers'],
          icons: const [Icons.badge_rounded, Icons.person_pin_circle_rounded],
          index: _peopleSegment,
          onChanged: (i) => setState(() => _peopleSegment = i),
        ),
        Expanded(
          child: _peopleSegment == 0
              ? _buildDriversTab()
              : _buildDispatchersTab(),
        ),
      ],
    );
  }

  // Complaints | Queue audits share one destination.
  Widget _buildReportsTab() {
    return Column(
      children: [
        _segmentBar(
          labels: const ['Passenger complaints', 'Queue changes'],
          icons: const [
            Icons.report_problem_rounded,
            Icons.swap_vert_circle_rounded
          ],
          index: _reportsSegment,
          onChanged: (i) => setState(() => _reportsSegment = i),
        ),
        Expanded(
          child: _reportsSegment == 0
              ? _buildComplaintsTab()
              : _buildQueueAuditsTab(),
        ),
      ],
    );
  }

  Widget _segmentBar({
    required List<String> labels,
    required List<IconData> icons,
    required int index,
    required ValueChanged<int> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: CoopSegmented(
              labels: labels, icons: icons, index: index, onChanged: onChanged),
        ),
      ),
    );
  }

  _PrimaryAction? _primaryAction() {
    switch (_current) {
      case _Section.fleet:
        return _PrimaryAction('Add jeepney', Icons.directions_bus_rounded,
            _showAddJeepneyModal);
      case _Section.people:
        return _peopleSegment == 0
            ? _PrimaryAction(
                'Add driver', Icons.person_add_rounded, _showAddDriverModal)
            : _PrimaryAction('Add dispatcher',
                Icons.person_pin_circle_rounded, _showAddDispatcherModal);
      default:
        return null;
    }
  }

  Widget? _buildFab(bool wide) {
    final a = _primaryAction();
    if (a == null || wide) return null;
    return FloatingActionButton.extended(
      heroTag: 'coop_primary_action',
      backgroundColor: AppColors.commuterTeal,
      foregroundColor: Colors.white,
      elevation: 3,
      icon: Icon(a.icon, size: 20),
      label: Text(a.label,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
      onPressed: a.onTap,
    );
  }

  Future<void> _onAccountAction(String value) async {
    if (value == 'edit') {
      _showEditAccountDialog();
    } else if (value == 'logout') {
      await StaffAuth.signOut();
      if (!mounted) return;
      if (Navigator.canPop(context)) {
        Navigator.pop(context);
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const LoginScreen()),
        );
      }
    }
  }

  Widget _accountMenu({required Widget child, Offset offset = const Offset(0, 48)}) {
    return PopupMenuButton<String>(
      tooltip: 'Account',
      color: Colors.white,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      offset: offset,
      onSelected: _onAccountAction,
      itemBuilder: (context) => const [
        PopupMenuItem<String>(
          value: 'edit',
          height: 42,
          child: Row(
            children: [
              Icon(Icons.manage_accounts_outlined,
                  color: AppColors.primaryNavy, size: 18),
              SizedBox(width: 10),
              Text('Edit account',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.darkSlate)),
            ],
          ),
        ),
        PopupMenuDivider(height: 1),
        PopupMenuItem<String>(
          value: 'logout',
          height: 42,
          child: Row(
            children: [
              Icon(Icons.logout_rounded,
                  color: AppColors.errorCrimson, size: 18),
              SizedBox(width: 10),
              Text('Log out',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.errorCrimson)),
            ],
          ),
        ),
      ],
      child: child,
    );
  }

  Widget _avatar({double size = 36}) {
    final initial = _fullName.trim().isEmpty
        ? '?'
        : _fullName.trim()[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.14),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white30),
      ),
      child: Text(initial,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
    );
  }

  PreferredSizeWidget _mobileAppBar(_Section s) {
    return AppBar(
      elevation: 0,
      backgroundColor: AppColors.primaryNavy,
      automaticallyImplyLeading: false,
      toolbarHeight: 62,
      titleSpacing: 16,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white24),
            ),
            child: const Icon(Icons.corporate_fare_rounded,
                color: Colors.white, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_coopName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                        color: Colors.white)),
                const SizedBox(height: 1),
                Text(s.title,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withOpacity(0.78))),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.campaign_rounded, color: Colors.white, size: 23),
          tooltip: 'Send a notice',
          onPressed: () => _showCreateNoticeModal(),
        ),
        _accountMenu(child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: _avatar(size: 34),
        )),
        const SizedBox(width: 12),
      ],
    );
  }

  Widget _desktopHeader(_Section s, _PrimaryAction? action) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 18, 28, 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.title,
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                        color: AppColors.darkSlate)),
                const SizedBox(height: 2),
                Text(s.subtitle,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textMuted)),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => _showCreateNoticeModal(),
            icon: const Icon(Icons.campaign_rounded, size: 18),
            label: const Text('Send a notice',
                style: TextStyle(fontWeight: FontWeight.w800)),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primaryNavy,
              side: const BorderSide(color: AppColors.borderSubtle),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 10),
            ElevatedButton.icon(
              onPressed: action.onTap,
              icon: Icon(action.icon, size: 18),
              label: Text(action.label,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.commuterTeal,
                foregroundColor: Colors.white,
                elevation: 0,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ===========================================================================
  // OVERVIEW (new home tab)
  // ===========================================================================

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  String _todayLabel() {
    const wd = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
      'Sunday'
    ];
    const mo = [
      'January', 'February', 'March', 'April', 'May', 'June', 'July',
      'August', 'September', 'October', 'November', 'December'
    ];
    final n = DateTime.now();
    return '${wd[n.weekday - 1]}, ${mo[n.month - 1]} ${n.day}';
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} hr ago';
    return '${d.inDays} d ago';
  }

  bool _isUnassignedDriver(String? name) {
    final n = (name ?? '').trim().toLowerCase();
    return n.isEmpty || n.contains('unassigned') || n == 'none';
  }

  Widget _buildOverviewTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: _ovVehiclesStream,
      builder: (context, vSnap) => StreamBuilder<QuerySnapshot>(
        stream: _ovDriversStream,
        builder: (context, dSnap) => StreamBuilder<QuerySnapshot>(
          stream: _ovDispatchersStream,
          builder: (context, xSnap) => StreamBuilder<QuerySnapshot>(
            stream: _ovComplaintsStream,
            builder: (context, cSnap) {
              if (!vSnap.hasData && !vSnap.hasError) {
                return const Center(
                    child:
                        CircularProgressIndicator(color: AppColors.commuterTeal));
              }
              return _overviewBody(
                vSnap.data?.docs ?? <QueryDocumentSnapshot>[],
                dSnap.data?.docs ?? <QueryDocumentSnapshot>[],
                xSnap.data?.docs ?? <QueryDocumentSnapshot>[],
                cSnap.data?.docs ?? <QueryDocumentSnapshot>[],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _overviewBody(
    List<QueryDocumentSnapshot> allVehicles,
    List<QueryDocumentSnapshot> allDrivers,
    List<QueryDocumentSnapshot> allDispatchers,
    List<QueryDocumentSnapshot> allComplaints,
  ) {
    Map<String, dynamic> m(QueryDocumentSnapshot d) =>
        d.data() as Map<String, dynamic>;

    final vehicles = allVehicles.where((d) => _matchesCooperative(m(d))).toList();
    final drivers = allDrivers.where((d) => _matchesCooperative(m(d))).toList();
    final dispatchers =
        allDispatchers.where((d) => _matchesCooperative(m(d))).toList();

    int enRoute = 0, standby = 0, noDriver = 0, seats = 0, cap = 0;
    final routeTotal = <String, int>{};
    final routeLive = <String, int>{};
    final plates = <String>{};

    for (final d in vehicles) {
      final v = m(d);
      final live =
          (v['current_status'] ?? 'STANDBY').toString().toUpperCase() ==
              'EN_ROUTE';
      if (live) {
        enRoute++;
        seats += (v['passenger_count'] as num?)?.toInt() ?? 0;
        cap += (v['max_capacity'] as num?)?.toInt() ?? 20;
      } else {
        standby++;
      }
      if (_isUnassignedDriver(v['driver_name']?.toString())) noDriver++;
      final r = (v['route_id'] ?? '').toString();
      if (r.isNotEmpty) {
        routeTotal[r] = (routeTotal[r] ?? 0) + 1;
        if (live) routeLive[r] = (routeLive[r] ?? 0) + 1;
      }
      plates.add(_normalizePlate(d.id));
      if (v['plate_number'] != null) {
        plates.add(_normalizePlate(v['plate_number'].toString()));
      }
    }

    final freeDrivers = drivers.where((d) {
      final v = (m(d)['assigned_vehicle'] ?? 'UNASSIGNED').toString();
      return v.isEmpty || v == 'UNASSIGNED' || v == 'None';
    }).length;

    final openReports = allComplaints.where((d) {
      final c = m(d);
      final mine = _matchesCooperative(c) ||
          plates.contains(_normalizePlate(c['plate_number']?.toString() ?? ''));
      if (!mine) return false;
      return !(c['status'] ?? '').toString().toUpperCase().contains('RESOLVED');
    }).length;

    final fill = cap > 0 ? seats / cap : 0.0;
    final firstName = _fullName.trim().split(' ').first;

    final routeIds = <String>{..._coopAuthorizedRoutes, ...routeTotal.keys}.toList();

    // ── pieces ────────────────────────────────────────────────────────────
    final header = Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${_greeting()}, $firstName',
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                  color: AppColors.darkSlate)),
          const SizedBox(height: 2),
          Text(_todayLabel(),
              style:
                  const TextStyle(fontSize: 13, color: AppColors.textMuted)),
        ],
      ),
    );

    final board = CoopPanel(
      title: 'Fleet right now',
      subtitle: vehicles.isEmpty
          ? null
          : 'Cooperative units by status',
      trailing: TextButton(
        onPressed: () => _goTo(_Section.map),
        child: const Text('Open map',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      child: vehicles.isEmpty
          ? CoopEmptyState(
              icon: Icons.directions_bus_outlined,
              title: 'No jeepneys enrolled yet',
              message: 'Add your first unit to start tracking it here.',
              actionLabel: 'Add jeepney',
              onAction: _showAddJeepneyModal,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('$enRoute',
                        style: const TextStyle(
                            fontSize: 44,
                            height: 1,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -1.5,
                            color: AppColors.darkSlate)),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(
                          'of ${vehicles.length} unit${vehicles.length == 1 ? '' : 's'} on the road',
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textMuted)),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                CoopSplitBar(
                  height: 14,
                  segments: [
                    CoopSegment(enRoute, CoopTone.success.fg),
                    CoopSegment(standby, const Color(0xFF93C5FD)),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 18,
                  runSpacing: 6,
                  children: [
                    CoopLegendDot(CoopTone.success.fg, 'On the road  $enRoute'),
                    CoopLegendDot(const Color(0xFF93C5FD), 'Standby  $standby'),
                  ],
                ),
                if (enRoute > 0) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text('Seats filled on the road',
                            style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textMuted)),
                      ),
                      Text('${(fill * 100).round()}%',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              color: AppColors.darkSlate)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: fill.clamp(0.0, 1.0),
                      minHeight: 7,
                      backgroundColor: const Color(0xFFE2E8F0),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          AppColors.commuterTeal),
                    ),
                  ),
                ],
              ],
            ),
    );

    // Needs attention
    final attention = <Widget>[];
    if (!_hasCpc) {
      attention.add(_attentionRow(
        CoopTone.danger,
        Icons.gpp_maybe_rounded,
        'Franchise (CPC) number is not set',
        'You cannot enroll new jeepneys until it is added.',
        'Set number',
        () async {
          await _showEditCpcDialog();
          if (mounted) setState(() {});
        },
      ));
    }
    if (noDriver > 0) {
      attention.add(_attentionRow(
        CoopTone.warning,
        Icons.no_accounts_rounded,
        '$noDriver unit${noDriver == 1 ? ' has' : 's have'} no driver',
        'These jeepneys cannot take passengers yet.',
        'View fleet',
        () => _goTo(_Section.fleet),
      ));
    }
    if (freeDrivers > 0) {
      attention.add(_attentionRow(
        CoopTone.info,
        Icons.badge_outlined,
        '$freeDrivers driver${freeDrivers == 1 ? '' : 's'} without a jeepney',
        'Assign them to a unit from the drivers list.',
        'View drivers',
        () {
          setState(() => _peopleSegment = 0);
          _goTo(_Section.people);
        },
      ));
    }
    if (openReports > 0) {
      attention.add(_attentionRow(
        CoopTone.warning,
        Icons.report_problem_outlined,
        '$openReports open passenger report${openReports == 1 ? '' : 's'}',
        'Review them and update the status.',
        'Open reports',
        () {
          setState(() => _reportsSegment = 0);
          _goTo(_Section.reports);
        },
      ));
    }

    final attentionPanel = CoopPanel(
      title: 'Needs your attention',
      child: attention.isEmpty
          ? Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                      color: CoopTone.success.bg,
                      borderRadius: BorderRadius.circular(10)),
                  child: Icon(Icons.check_rounded,
                      size: 20, color: CoopTone.success.fg),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Everything is in order. Nothing is waiting on you.',
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.darkSlate)),
                ),
              ],
            )
          : Column(
              children: [
                for (int i = 0; i < attention.length; i++) ...[
                  if (i > 0) const SizedBox(height: 10),
                  attention[i],
                ],
              ],
            ),
    );

    // Routes
    final routesPanel = CoopPanel(
      title: 'Routes',
      subtitle: 'Tap a route to see its units',
      child: routeIds.isEmpty
          ? const Text('No routes assigned to this cooperative.',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted))
          : Column(
              children: [
                for (int i = 0; i < routeIds.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 22, color: AppColors.borderSubtle),
                  _routeRow(routeIds[i], routeTotal[routeIds[i]] ?? 0,
                      routeLive[routeIds[i]] ?? 0),
                ],
              ],
            ),
    );

    // Quick actions
    final quick = CoopPanel(
      title: 'Quick actions',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _quickAction(Icons.directions_bus_rounded, 'Add jeepney',
              _showAddJeepneyModal),
          _quickAction(
              Icons.person_add_rounded, 'Add driver', _showAddDriverModal),
          _quickAction(Icons.person_pin_circle_rounded, 'Add dispatcher',
              _showAddDispatcherModal),
          _quickAction(
              Icons.campaign_rounded, 'Send a notice', () => _showCreateNoticeModal()),
        ],
      ),
    );

    final activity = _recentActivityPanel();

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final wide = w >= 900;
        final pad = wide ? 28.0 : 16.0;

        final cols = w >= 1000 ? 4 : 2;
        final inner = (w.clamp(0, 1240) as num).toDouble() - pad * 2;
        final tileW = (inner - 10 * (cols - 1)) / cols;

        Widget tile(Widget t) => SizedBox(width: tileW, child: t);

        final tiles = Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            tile(CoopStatTile(
              label: 'Jeepneys',
              value: '${vehicles.length}',
              icon: Icons.directions_bus_rounded,
              tone: CoopTone.info,
              caption: '$enRoute on the road',
              onTap: () => _goTo(_Section.fleet),
            )),
            tile(CoopStatTile(
              label: 'Drivers',
              value: '${drivers.length}',
              icon: Icons.badge_rounded,
              tone: freeDrivers > 0 ? CoopTone.warning : CoopTone.success,
              caption: freeDrivers > 0
                  ? '$freeDrivers without a jeepney'
                  : 'All assigned',
              onTap: () {
                setState(() => _peopleSegment = 0);
                _goTo(_Section.people);
              },
            )),
            tile(CoopStatTile(
              label: 'Dispatchers',
              value: '${dispatchers.length}',
              icon: Icons.person_pin_circle_rounded,
              tone: CoopTone.neutral,
              onTap: () {
                setState(() => _peopleSegment = 1);
                _goTo(_Section.people);
              },
            )),
            tile(CoopStatTile(
              label: 'Open reports',
              value: '$openReports',
              icon: Icons.report_problem_rounded,
              tone: openReports > 0 ? CoopTone.warning : CoopTone.success,
              caption: openReports > 0 ? 'Waiting for a reply' : 'All clear',
              onTap: () {
                setState(() => _reportsSegment = 0);
                _goTo(_Section.reports);
              },
            )),
          ],
        );

        final Widget content;
        if (wide) {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              const SizedBox(height: 16),
              tiles,
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      children: [board, const SizedBox(height: 16), routesPanel],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: Column(
                      children: [
                        attentionPanel,
                        const SizedBox(height: 16),
                        activity,
                        const SizedBox(height: 16),
                        quick,
                      ],
                    ),
                  ),
                ],
              ),
            ],
          );
        } else {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              const SizedBox(height: 14),
              attentionPanel,
              const SizedBox(height: 14),
              tiles,
              const SizedBox(height: 14),
              board,
              const SizedBox(height: 14),
              quick,
              const SizedBox(height: 14),
              routesPanel,
              const SizedBox(height: 14),
              activity,
            ],
          );
        }

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1240),
            child: ListView(
              padding: EdgeInsets.fromLTRB(pad, 18, pad, 32),
              children: [content],
            ),
          ),
        );
      },
    );
  }

  Widget _attentionRow(CoopTone tone, IconData icon, String title, String body,
      String actionLabel, VoidCallback onTap) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.line),
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: tone.fg),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.darkSlate)),
                const SizedBox(height: 2),
                Text(body,
                    style: const TextStyle(
                        fontSize: 12, height: 1.3, color: AppColors.textMuted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              foregroundColor: tone.fg,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 36),
            ),
            child: Text(actionLabel,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  Widget _routeRow(String routeId, int total, int live) {
    final cfg = RouteProcesses.of(routeId);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        setState(() {
          _fleetRouteFilter = routeId;
          _fleetStatusFilter = 'ALL';
          _fleetSearchQuery = '';
          _fleetSearchCtrl.clear();
        });
        _goTo(_Section.fleet);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_formatRouteDisplayName(routeId),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: AppColors.darkSlate)),
                ),
                Text(
                    total == 0
                        ? 'No units'
                        : '$live of $total on the road',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: live > 0
                            ? CoopTone.success.fg
                            : AppColors.textMuted)),
              ],
            ),
            if (cfg != null) ...[
              const SizedBox(height: 2),
              Text(cfg.processLabel,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textMuted)),
            ],
            const SizedBox(height: 8),
            CoopSplitBar(
              height: 6,
              segments: [
                CoopSegment(live, CoopTone.success.fg),
                CoopSegment(total - live, const Color(0xFFCBD5E1)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickAction(IconData icon, String label, VoidCallback onTap) {
    return Material(
      color: AppColors.backgroundSlate,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: AppColors.primaryNavy),
              const SizedBox(width: 8),
              Text(label,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: AppColors.darkSlate)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _recentActivityPanel() {
    return CoopPanel(
      title: 'Recent queue changes',
      trailing: TextButton(
        onPressed: () {
          setState(() => _reportsSegment = 1);
          _goTo(_Section.reports);
        },
        child: const Text('See all', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      child: StreamBuilder<QuerySnapshot>(
        stream: _overviewAuditStream(),
        builder: (context, snap) {
          if (!snap.hasData && !snap.hasError) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                  child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: AppColors.commuterTeal))),
            );
          }
          final docs = List<QueryDocumentSnapshot>.from(snap.data?.docs ?? []);
          docs.sort((a, b) {
            final ta = (a.data() as Map<String, dynamic>)['timestamp'] as Timestamp?;
            final tb = (b.data() as Map<String, dynamic>)['timestamp'] as Timestamp?;
            if (ta == null && tb == null) return 0;
            if (ta == null) return 1;
            if (tb == null) return -1;
            return tb.compareTo(ta);
          });
          final recent = docs.take(4).toList();
          if (recent.isEmpty) {
            return const Text('No queue changes recorded yet.',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted));
          }
          return Column(
            children: [
              for (int i = 0; i < recent.length; i++) ...[
                if (i > 0)
                  const Divider(height: 18, color: AppColors.borderSubtle),
                _activityRow(recent[i].data() as Map<String, dynamic>),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _activityRow(Map<String, dynamic> d) {
    final who = (d['dispatcher_name'] ?? 'Dispatcher').toString();
    final reason = (d['reason'] ?? 'No reason recorded.').toString();
    final route = _formatRouteName((d['route_id'] ?? '').toString());
    final ts = (d['timestamp'] as Timestamp?)?.toDate();
    final cross =
        ((d['affected_cooperative_names'] as List<dynamic>?) ?? []).length > 1;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
              color: (cross ? CoopTone.warning : CoopTone.neutral).bg,
              borderRadius: BorderRadius.circular(10)),
          child: Icon(Icons.swap_vert_rounded,
              size: 18, color: (cross ? CoopTone.warning : CoopTone.neutral).fg),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$who changed the $route queue',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: AppColors.darkSlate)),
              const SizedBox(height: 2),
              Text(reason,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, height: 1.3, color: AppColors.textMuted)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (ts != null)
          Text(_ago(ts),
              style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted)),
      ],
    );
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================
  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final wide = width >= 900;
    final sections = _sections;
    final idx = _tabController.index.clamp(0, sections.length - 1);
    final current = sections[idx];

    // Swiping is off: it fought with the map and with horizontal scrolling.
    final body = TabBarView(
      controller: _tabController,
      physics: const NeverScrollableScrollPhysics(),
      children: [for (final s in sections) _pageFor(s)],
    );

    if (wide) {
      final extended = width >= 1150;
      return Scaffold(
        backgroundColor: AppColors.backgroundSlate,
        body: Row(
          children: [
            CoopSideRail(
              title: _coopName,
              subtitle: 'Cooperative office',
              extended: extended,
              selected: idx,
              onSelect: (i) =>
                  _tabController.animateTo(i, duration: Duration.zero),
              items: [
                for (final s in sections)
                  CoopNavItem(s.label, s.icon, s.selectedIcon),
              ],
              footer: _accountMenu(
                offset: const Offset(0, -110),
                child: Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: extended ? 10 : 0, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: extended
                        ? MainAxisAlignment.start
                        : MainAxisAlignment.center,
                    children: [
                      _avatar(size: 34),
                      if (extended) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(_fullName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                        ),
                        const Icon(Icons.unfold_more_rounded,
                            size: 18, color: Colors.white70),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  _desktopHeader(current, _primaryAction()),
                  Expanded(child: body),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.backgroundSlate,
      appBar: _mobileAppBar(current),
      floatingActionButton: _buildFab(false),
      body: body,
      bottomNavigationBar: NavigationBar(
        height: 68,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        indicatorColor: AppColors.commuterTealLight,
        selectedIndex: idx,
        labelBehavior: sections.length > 5
            ? NavigationDestinationLabelBehavior.onlyShowSelected
            : NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) =>
            _tabController.animateTo(i, duration: Duration.zero),
        destinations: [
          for (final s in sections)
            NavigationDestination(
              icon: Icon(s.icon, color: AppColors.textMuted),
              selectedIcon:
                  Icon(s.selectedIcon, color: AppColors.primaryNavy),
              label: s.label,
            ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) => CoopLegendDot(color, label);
}

// =============================================================================
// LTO DRIVER'S LICENSE TEXT PARSER
// Used by the Add Driver modal to auto-fill name, M.I., sex and license number
// from the OCR text of a scanned license.
// =============================================================================
class _ParsedLicense {
  final String? firstName;
  final String? middleName;
  final String? lastName;
  final String? sex; // 'MALE' | 'FEMALE'
  final String? licenseNumber; // e.g. D01-23-456789

  const _ParsedLicense({
    this.firstName,
    this.middleName,
    this.lastName,
    this.sex,
    this.licenseNumber,
  });

  bool get hasName => firstName != null && lastName != null;
}

class _LicenseName {
  final String first;
  final String middle;
  final String last;
  const _LicenseName(this.first, this.middle, this.last);
}

class _LicenseOcrParser {
  _LicenseOcrParser._();

  static final RegExp _midLabel =
      RegExp(r'gitnang|middle\s*name', caseSensitive: false);
  static final RegExp _lastLabel = RegExp(
    r'ap[e3]l[yi1l]+[dg]o|last\s*name|surname|family\s*name',
    caseSensitive: false,
  );
  static final RegExp _givenLabel = RegExp(
    r'mga\s*pang[ao]l[ao]n|pang[ao]l[ao]n|given\s*names?|first\s*name',
    caseSensitive: false,
  );
  static final RegExp _labelPrefix = RegExp(
    r'^[\s:/\-,]*((gitnang\s*)?ap[e3]l[yi1l]+[dg]o|(last|first|middle|given)\s*names?|surname|family\s*name|mga\s*pang[ao]l[ao]n|pang[ao]l[ao]n)',
    caseSensitive: false,
  );
  static final RegExp _nonNameWords = RegExp(
    r'republi|pilipinas|philippine|birth|petsa|kasarian|\bsex\b|address|tirahan|signature|license|identification|nationality|\bno\b|valid|expir|transport|department|agency|height|weight|blood|eyes|condition|restriction',
    caseSensitive: false,
  );
  static final RegExp _addressWords = RegExp(
    r'\b(city|municipality|metro|manila|barangay|brgy|street|avenue|road|province|purok|zone|blk|block|lot|subdivision|village|poblacion|region)\b',
    caseSensitive: false,
  );

  // ── text cleanup helpers ──────────────────────────────────────────────────

  static const Map<String, String> _accentMap = {
    'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
    'Á': 'A', 'À': 'A', 'Â': 'A', 'Ä': 'A', 'Ã': 'A',
    'É': 'E', 'È': 'E', 'Ê': 'E', 'Ë': 'E',
    'Í': 'I', 'Ì': 'I', 'Î': 'I', 'Ï': 'I',
    'Ó': 'O', 'Ò': 'O', 'Ô': 'O', 'Ö': 'O', 'Õ': 'O',
    'Ú': 'U', 'Ù': 'U', 'Û': 'U', 'Ü': 'U',
  };

  /// "JOSÉ" -> "JOSE". Ñ/ñ are kept (real letters in Filipino names).
  static String stripAccents(String s) => s.replaceAllMapped(
        RegExp('[áàâäãéèêëíìîïóòôöõúùûüÁÀÂÄÃÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜ]'),
        (m) => _accentMap[m[0]!] ?? m[0]!,
      );

  static const Map<String, String> _digitToLetter = {
    '0': 'o', '1': 'i', '2': 'z', '3': 'e', '4': 'a', '5': 's', '6': 'g', '8': 'b',
  };

  /// OCR often reads letters as digits inside a word ("D3LA").
  /// Only digits sitting between two letters are converted.
  static String fixConfusables(String s) => s.replaceAllMapped(
        RegExp(r'(?<=[A-Za-zÑñ])[0-9](?=[A-Za-zÑñ])'),
        (m) => _digitToLetter[m[0]!] ?? m[0]!,
      );

  /// Letters OCR confuses with digits -> digits (for license-number matching).
  static String digitize(String s) {
    const map = {'O': '0', 'I': '1', 'L': '1', 'S': '5', 'B': '8', 'Z': '2'};
    return s.toUpperCase().split('').map((c) => map[c] ?? c).join();
  }

  static String titleCase(String input) {
    return input
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w.replaceAllMapped(
              RegExp(r"(^|[-'.])([a-zñ])"),
              (m) => '${m[1]}${m[2]!.toUpperCase()}',
            ))
        .join(' ');
  }

  // ── public API ────────────────────────────────────────────────────────────

  static bool looksLikeLicense(String text) {
    final lower = text.toLowerCase();
    final hasDriverLicense = lower.contains('driver') && lower.contains('license');
    final hasLto = lower.contains('land transportation') || lower.contains('lto');
    final hasOfficialHeader = lower.contains('republika') ||
        lower.contains('republic of the philippines') ||
        lower.contains('pilipinas');
    return hasDriverLicense ||
        (hasLto && lower.contains('license')) ||
        (hasOfficialHeader && lower.contains('driver'));
  }

  /// Null when the text is not a recognizable license or nothing was found.
  static _ParsedLicense? parse(String text) {
    if (text.trim().length < 15 || !looksLikeLicense(text)) return null;

    final name = _extractName(text);
    final sex = detectSex(text.toUpperCase());
    final number = findLicenseNumber(text);
    if (name == null && sex == null && number == null) return null;

    return _ParsedLicense(
      firstName: name == null ? null : titleCase(name.first),
      lastName: name == null ? null : titleCase(name.last),
      middleName: (name == null || name.middle.isEmpty) ? null : titleCase(name.middle),
      sex: sex,
      licenseNumber: number,
    );
  }

  static String? detectSex(String rawUpper) {
    if (RegExp(r'\bFEMALE\b').hasMatch(rawUpper)) return 'FEMALE';
    if (RegExp(r'\bMALE\b').hasMatch(rawUpper)) return 'MALE';

    final labeled = RegExp(r'\bSEX\s*[:\-]?\s*(M|F)\b').firstMatch(rawUpper);
    if (labeled != null) return labeled.group(1) == 'F' ? 'FEMALE' : 'MALE';

    // LTO cards print: "PHL  M  1990/01/01  70  1.70" (nationality, sex, birth date).
    final withNationality = RegExp(r'\bPHL\s*(M|F)\b').firstMatch(rawUpper);
    if (withNationality != null) {
      return withNationality.group(1) == 'F' ? 'FEMALE' : 'MALE';
    }

    final withBirthDate = RegExp(
      r'\b(M|F)\s+(\d{4}[/\-.]\d{1,2}[/\-.]\d{1,2}|\d{1,2}[/\-.]\d{1,2}[/\-.]\d{4})\b',
    ).firstMatch(rawUpper);
    if (withBirthDate != null) {
      return withBirthDate.group(1) == 'F' ? 'FEMALE' : 'MALE';
    }

    final withHeight = RegExp(r'\b(M|F)\s+[12][.,]\d{2}\b').firstMatch(rawUpper);
    if (withHeight != null) return withHeight.group(1) == 'F' ? 'FEMALE' : 'MALE';

    return null;
  }

  /// Finds an LTO license number such as D01-23-456789, tolerating letters
  /// OCR confuses with digits (O->0, I->1, ...). Returns it formatted.
  static String? findLicenseNumber(String rawText) {
    final re = RegExp(
      r'\b([A-Z])([0-9OILSBZ]{2})[-\s]?([0-9OILSBZ]{2})[-\s]?([0-9OILSBZ]{6})\b',
    );
    for (final m in re.allMatches(rawText.toUpperCase())) {
      final digitCount = RegExp(r'[0-9]').allMatches(m.group(0)!).length;
      if (digitCount < 6) continue; // mostly letters: not a license number
      return '${m.group(1)}${digitize(m.group(2)!)}-${digitize(m.group(3)!)}-${digitize(m.group(4)!)}';
    }
    return null;
  }

  // ── name extraction ───────────────────────────────────────────────────────

  static String? _cleanNameValue(String raw) {
    var v = fixConfusables(stripAccents(raw))
        .replaceAll(RegExp(r"[^A-Za-zÑñ\s.'\-]"), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    v = v.replaceAll(RegExp(r'^[.\-\s]+|[.\-\s]+$'), '');
    if (v.length < 2 || v.split(' ').length > 5) return null;
    if (_nonNameWords.hasMatch(v) ||
        _midLabel.hasMatch(v) ||
        _lastLabel.hasMatch(v) ||
        _givenLabel.hasMatch(v)) {
      return null;
    }
    return v;
  }

  static bool _isLabelLine(String line) =>
      _midLabel.hasMatch(line) ||
      _lastLabel.hasMatch(line) ||
      _givenLabel.hasMatch(line) ||
      _nonNameWords.hasMatch(line);

  /// 'last' | 'given' | 'middle' when [line] holds exactly one name label.
  static String? _labelKind(String line) {
    final isMid = _midLabel.hasMatch(line);
    final isLast = !isMid && _lastLabel.hasMatch(line);
    final isGiven = _givenLabel.hasMatch(line);
    final count = [isMid, isLast, isGiven].where((b) => b).length;
    if (count != 1) return null; // no label, or a combined header line
    return isMid ? 'middle' : (isLast ? 'last' : 'given');
  }

  static RegExp _labelRegex(String kind) =>
      kind == 'middle' ? _midLabel : (kind == 'last' ? _lastLabel : _givenLabel);

  static String? _valueOnLabelLine(String line, String kind) {
    final m = _labelRegex(kind).firstMatch(line);
    if (m == null) return null;
    var rest = line.substring(m.end);
    for (int k = 0; k < 3; k++) {
      final stripped = rest.replaceFirst(_labelPrefix, '');
      if (stripped == rest) break;
      rest = stripped;
    }
    return _cleanNameValue(rest);
  }

  static String? _valueForLabel(List<String> lines, int i, String kind) {
    final same = _valueOnLabelLine(lines[i], kind);
    if (same != null) return same;
    for (int j = i + 1; j < lines.length && j <= i + 2; j++) {
      if (_isLabelLine(lines[j])) break;
      final v = _cleanNameValue(lines[j]);
      if (v != null) return v;
    }
    return null;
  }

  static _LicenseName? _extractName(String text) {
    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    // 1) Label with its value on the same / next line.
    String? last, given, middle;
    for (int i = 0; i < lines.length; i++) {
      final kind = _labelKind(lines[i]);
      if (kind == null) continue;
      final value = _valueForLabel(lines, i, kind);
      if (kind == 'middle') {
        middle ??= value;
      } else if (kind == 'last') {
        last ??= value;
      } else {
        given ??= value;
      }
    }
    if (last != null && given != null) {
      return _LicenseName(given, middle ?? '', last);
    }

    // 2) Labels grouped together, values grouped right after them.
    int idx = 0;
    while (idx < lines.length) {
      final kinds = <String>[];
      int end = idx;
      while (end < lines.length) {
        final k = _labelKind(lines[end]);
        if (k == null || _valueOnLabelLine(lines[end], k) != null) break;
        kinds.add(k);
        end++;
      }
      if (kinds.length < 2) {
        idx++;
        continue;
      }

      final values = <String>[];
      final wanted = end + kinds.length + 3;
      final limit = wanted < lines.length ? wanted : lines.length;
      for (int v = end; v < limit && values.length < kinds.length; v++) {
        if (_isLabelLine(lines[v])) break;
        final cleaned = _cleanNameValue(lines[v]);
        if (cleaned != null) values.add(cleaned);
      }

      if (values.length == kinds.length) {
        String? l2, g2, m2;
        for (int n = 0; n < kinds.length; n++) {
          if (kinds[n] == 'last') {
            l2 ??= values[n];
          } else if (kinds[n] == 'given') {
            g2 ??= values[n];
          } else {
            m2 ??= values[n];
          }
        }
        if (l2 != null && g2 != null) return _LicenseName(g2, m2 ?? '', l2);
      }
      idx = end;
    }

    // 3) LTO style: header "Last Name, First Name, Middle Name" followed by
    //    one line "DELA CRUZ, JUAN CARLOS SANTOS".
    if (_lastLabel.hasMatch(text) && _givenLabel.hasMatch(text)) {
      final comma = RegExp(
        r"^([A-ZÑ][A-ZÑ.'\-\s]*[A-ZÑ.]),\s*([A-ZÑ][A-ZÑ.'\-\s]*[A-ZÑ.])$",
      );
      for (final l in lines) {
        final m = comma.firstMatch(stripAccents(l));
        if (m == null || _nonNameWords.hasMatch(l) || _addressWords.hasMatch(l)) {
          continue;
        }
        final lastName = _cleanNameValue(m.group(1)!);
        final rest = _cleanNameValue(m.group(2)!);
        if (lastName == null || rest == null) continue;
        final parts = rest.split(' ');
        if (parts.length >= 2) {
          return _LicenseName(
            parts.sublist(0, parts.length - 1).join(' '),
            parts.last,
            lastName,
          );
        }
        return _LicenseName(rest, '', lastName);
      }
    }
    return null;
  }
}