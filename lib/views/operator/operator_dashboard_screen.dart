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
import '../../utils/app_colors.dart';

class OperatorDashboardScreen extends StatefulWidget {
  final String userId;
  final Map<String, dynamic> userData;

  const OperatorDashboardScreen({
    super.key,
    required this.userId,
    required this.userData,
  });

  @override
  State<OperatorDashboardScreen> createState() => _OperatorDashboardScreenState();
}

class _OperatorDashboardScreenState extends State<OperatorDashboardScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Complaints Filter States
  String _selectedStatusFilter = 'ALL';
  String _selectedDateFilter = 'ALL';
  DateTimeRange? _customDateRange;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ===========================================================================
  // RESPONSIVE HELPERS
  // ===========================================================================

  /// Keeps the phone's system font scale inside a safe range so text stays
  /// readable without causing pixel overflow on narrow screens.
  Widget _ts(BuildContext context, Widget child) {
    final mq = MediaQuery.of(context);
    final bool narrow = mq.size.width < 360;
    return MediaQuery(
      data: mq.copyWith(
        textScaler: mq.textScaler.clamp(
          minScaleFactor: 0.9,
          maxScaleFactor: narrow ? 1.1 : 1.25,
        ),
      ),
      child: child,
    );
  }

  /// Dialog height cap that always fits inside the current phone screen.
  double _dialogMaxHeight(BuildContext context, double cap) {
    final h = MediaQuery.of(context).size.height;
    return (h * 0.9).clamp(240.0, cap).toDouble();
  }

  String _normalizePlate(String plate) {
    return plate.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  }

  List<String> _getAssignedJeepneys(Map<String, dynamic> data) {
    final list = data['assigned_jeepneys'] as List<dynamic>?;
    return list?.map((e) => e.toString()).toList() ?? [];
  }

  List<String> _getAssignedDrivers(Map<String, dynamic> data) {
    final list = data['assigned_drivers'] as List<dynamic>?;
    return list?.map((e) => e.toString()).toList() ?? [];
  }

  Color _resolveVehicleDotColor(String? colorStr) {
    if (colorStr == null || colorStr.trim().isEmpty) {
      return const Color(0xFF10B981);
    }
    final c = colorStr.toLowerCase();
    if (c.contains('red') || c.contains('crimson')) return const Color(0xFFEF4444);
    if (c.contains('blue') || c.contains('navy')) return const Color(0xFF2563EB);
    if (c.contains('green')) return const Color(0xFF10B981);
    if (c.contains('yellow') || c.contains('gold')) return const Color(0xFFF59E0B);
    if (c.contains('orange')) return const Color(0xFFF97316);
    if (c.contains('purple') || c.contains('violet')) return const Color(0xFF8B5CF6);
    if (c.contains('pink')) return const Color(0xFFEC4899);
    if (c.contains('silver') || c.contains('gray') || c.contains('grey')) return const Color(0xFF64748B);
    if (c.contains('white')) return const Color(0xFF0F172A);
    return const Color(0xFF10B981);
  }

  // ===========================================================================
  // ADD DRIVER DIALOG (WITH OCR LTO DRIVER'S LICENSE VALIDATION)
  // ===========================================================================
  void _showAddDriverModal(
    BuildContext context,
    List<String> availableJeepneys,
    Map<String, dynamic> opData,
  ) {
    final formKey = GlobalKey<FormState>();
    final firstNameController = TextEditingController();
    final lastNameController = TextEditingController();
    final middleInitialController = TextEditingController();
    final usernameController = TextEditingController();
    final licenseController = TextEditingController();
    final pinController = TextEditingController(text: '4321');
    final confirmPinController = TextEditingController();

    String selectedVehicle = 'UNASSIGNED';
    String? selectedSex; // 'MALE' or 'FEMALE'
    bool obscurePin = true;
    bool obscureConfirmPin = true;
    bool isSubmitting = false;

    // License OCR States
    Uint8List? licenseImageBytes;
    String? licenseImageFileName;
    String? scannedRawText;
    bool isOcrScanning = false;
    bool isLicenseVerified = false;
    String ocrVerificationMessage = '';
    final ImagePicker picker = ImagePicker();

    final coopId = (opData['cooperative_id'] ?? '').toString();
    final coopName = (opData['cooperative_name'] ?? '').toString();

    // Normalizes text for name comparison (uppercase, letters/digits/spaces only)
    String normalizeForMatch(String input) {
      return input
          .toUpperCase()
          .replaceAll('Ñ', 'N')
          .replaceAll(RegExp(r'[^A-Z0-9\s]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    // Returns the name tokens that are NOT found in the OCR text
    List<String> missingNameTokens(String normalizedOcr, String name) {
      final tokens = normalizeForMatch(name).split(' ').where((t) => t.length >= 2).toList();
      return tokens.where((t) => !normalizedOcr.contains(t)).toList();
    }

    // Attempts to read the Sex field (M/F) printed on the LTO card
    String? detectSexFromOcr(String rawUpper) {
      if (RegExp(r'\bFEMALE\b').hasMatch(rawUpper)) return 'FEMALE';
      if (RegExp(r'\bMALE\b').hasMatch(rawUpper)) return 'MALE';

      final labeled = RegExp(r'\bSEX\s*[:\-]?\s*(M|F)\b').firstMatch(rawUpper);
      if (labeled != null) return labeled.group(1) == 'F' ? 'FEMALE' : 'MALE';

      // LTO cards print Sex followed by height (e.g. "M 1.65")
      final withHeight = RegExp(r'\b(M|F)\s+[12][.,]\d{2}\b').firstMatch(rawUpper);
      if (withHeight != null) return withHeight.group(1) == 'F' ? 'FEMALE' : 'MALE';

      return null;
    }

    // Verifies whether extracted text matches an authentic LTO Driver's License
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

      // 1. Must contain official LTO Driver's License identifiers
      final bool hasDriverLicense = lower.contains('driver') && lower.contains('license');
      final bool hasLto = lower.contains('land transportation') || lower.contains('lto');
      final bool hasOfficialHeader = lower.contains('republika') || lower.contains('republic of the philippines') || lower.contains('pilipinas');

      final bool isLegitDlDocument = hasDriverLicense || (hasLto && lower.contains('license')) || (hasOfficialHeader && lower.contains('driver'));

      if (!isLegitDlDocument) {
        setDialogState(() {
          isLicenseVerified = false;
          ocrVerificationMessage = 'Unrecognized card: The document is not an official Land Transportation Office (LTO) Driver\'s License.';
        });
        return;
      }

      // 2. Cross-reference entered Last Name, First Name & Middle Initial
      final normalizedOcr = normalizeForMatch(rawText);
      final enteredFirst = firstNameController.text.trim();
      final enteredLast = lastNameController.text.trim();
      final enteredMi = normalizeForMatch(middleInitialController.text);

      if (enteredLast.isNotEmpty) {
        final missing = missingNameTokens(normalizedOcr, enteredLast);
        if (missing.isNotEmpty) {
          setDialogState(() {
            isLicenseVerified = false;
            ocrVerificationMessage = 'Last Name Mismatch: "$enteredLast" was not detected on this license.';
          });
          return;
        }
      }

      if (enteredFirst.isNotEmpty) {
        final missing = missingNameTokens(normalizedOcr, enteredFirst);
        if (missing.isNotEmpty) {
          setDialogState(() {
            isLicenseVerified = false;
            ocrVerificationMessage = 'First Name Mismatch: "$enteredFirst" was not detected on this license.';
          });
          return;
        }

        // Middle initial should begin the word right after the first name on the card
        if (enteredMi.isNotEmpty) {
          final firstTokens = normalizeForMatch(enteredFirst).split(' ').where((t) => t.isNotEmpty).toList();
          final lastFirstToken = firstTokens.isNotEmpty ? firstTokens.last : '';
          final idx = lastFirstToken.isEmpty ? -1 : normalizedOcr.indexOf(lastFirstToken);
          if (idx != -1) {
            final after = normalizedOcr.substring(idx + lastFirstToken.length).trimLeft();
            if (after.isNotEmpty && !after.startsWith(enteredMi[0])) {
              setDialogState(() {
                isLicenseVerified = false;
                ocrVerificationMessage = 'Middle Initial Mismatch: "${middleInitialController.text.trim().toUpperCase()}." does not match the middle name on this license.';
              });
              return;
            }
          }
        }
      }

      // 3. Cross-reference selected Sex against the card (when readable)
      String sexNote = '';
      if (selectedSex != null) {
        final detectedSex = detectSexFromOcr(rawText.toUpperCase());
        if (detectedSex != null && detectedSex != selectedSex) {
          setDialogState(() {
            isLicenseVerified = false;
            ocrVerificationMessage =
                'Sex Mismatch: Selected "${selectedSex == 'MALE' ? 'Male' : 'Female'}" but the card indicates "${detectedSex == 'MALE' ? 'Male' : 'Female'}".';
          });
          return;
        }
        if (detectedSex == null) {
          sexNote = ' (Sex could not be read from card.)';
        }
      }

      // 4. License Number Extraction & Cross-reference
      final cleanOcr = rawText.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
      final enteredLicense = licenseController.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();

      if (enteredLicense.isNotEmpty && enteredLicense.length >= 6) {
        if (!cleanOcr.contains(enteredLicense)) {
          setDialogState(() {
            isLicenseVerified = false;
            ocrVerificationMessage = 'License Number Mismatch: "${licenseController.text.trim()}" does not match the scanned card.';
          });
          return;
        }
      } else {
        // Auto-extract LTO license pattern (e.g., D01-12-345678 or N01-23-456789)
        final licenseRegex = RegExp(r'[A-Z]\d{2}[-\s]?\d{2}[-\s]?\d{6}');
        final match = licenseRegex.firstMatch(rawText.toUpperCase());
        if (match != null && licenseController.text.isEmpty) {
          licenseController.text = match.group(0)!.replaceAll(' ', '-');
        }
      }

      HapticFeedback.lightImpact();
      setDialogState(() {
        isLicenseVerified = true;
        ocrVerificationMessage = 'Official LTO Driver\'s License verified successfully.$sexNote';
      });
    }

    // Web Fallback for OCR (OCR.Space)
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

    // Handles Image Capture and invokes OCR text recognition
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
        verifyExtractedLicense(extractedText, setDialogState);
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
                                      'Requires verified LTO physical license card',
                                      style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.textMuted),
                                tooltip: 'Close',
                                onPressed: () => Navigator.pop(dialogCtx),
                              ),
                            ],
                          ),
                          const Divider(height: 18, color: AppColors.borderSubtle),

                          // FIRST NAME
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

                          // LAST NAME
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

                          // MIDDLE INITIAL + SEX
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
                            decoration: _buildInputDeco('LTO License Number *', Icons.credit_card_rounded, hint: 'e.g. D01-23-456789'),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'License number is required' : null,
                            onChanged: (_) {
                              if (scannedRawText != null) verifyExtractedLicense(scannedRawText!, setDialogState);
                            },
                          ),
                          const SizedBox(height: 12),

                          // LTO DRIVER'S LICENSE OCR UPLOAD & VERIFICATION CARD
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
                                            'LTO Driver\'s License Card *',
                                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: AppColors.darkSlate),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            licenseImageFileName ?? 'Front card photo required for verification',
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
                            style: const TextStyle(fontSize: 14, letterSpacing: 1.2),
                            decoration: _buildInputDeco(
                              'Security PIN (Password) *',
                              Icons.lock_outline_rounded,
                              hint: '4-digit PIN',
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
                              if (v.trim().length < 4) return 'Must be at least 4 digits';
                              return null;
                            },
                          ),
                          const SizedBox(height: 10),

                          // RETYPE PIN
                          TextFormField(
                            controller: confirmPinController,
                            obscureText: obscureConfirmPin,
                            keyboardType: TextInputType.number,
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

                                            if (licenseImageBytes == null) {
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                const SnackBar(
                                                  content: Text('Please scan the physical LTO Driver\'s License card.'),
                                                  backgroundColor: AppColors.errorCrimson,
                                                ),
                                              );
                                              return;
                                            }

                                            // Re-run cross-reference with the latest entered details
                                            if (scannedRawText != null) {
                                              verifyExtractedLicense(scannedRawText!, setDialogState);
                                            }

                                            if (!isLicenseVerified) {
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
                                              final base64Card = base64Encode(licenseImageBytes!);

                                              final batch = FirebaseFirestore.instance.batch();

                                              final newDriverRef = FirebaseFirestore.instance.collection('users').doc(newDriverDocId);
                                              batch.set(newDriverRef, {
                                                'assigned_vehicle': selectedVehicle,
                                                'full_name': driverName,
                                                'first_name': firstName,
                                                'last_name': lastName,
                                                'middle_initial': middleInitial,
                                                'sex': selectedSex,
                                                'license_number': licenseController.text.trim().toUpperCase(),
                                                'license_card_base64': base64Card,
                                                'is_license_verified': true,
                                                'license_verified_at': FieldValue.serverTimestamp(),
                                                'operator_id': widget.userId,
                                                'pin_code': pinController.text.trim(),
                                                'role': 'DRIVER',
                                                'username': inputUsername,
                                                'cooperative_id': coopId,
                                                'cooperative_name': coopName,
                                                'qr_expires_at': null,
                                                'qr_token': null,
                                              });

                                              final operatorRef = FirebaseFirestore.instance.collection('users').doc(widget.userId);
                                              batch.update(operatorRef, {
                                                'assigned_drivers': FieldValue.arrayUnion([newDriverDocId]),
                                              });

                                              if (selectedVehicle != 'UNASSIGNED') {
                                                final vehicleRef = FirebaseFirestore.instance.collection('vehicles_live').doc(selectedVehicle);
                                                batch.update(vehicleRef, {
                                                  'driver_id': newDriverDocId,
                                                  'driver_name': driverName,
                                                });
                                              }

                                              await batch.commit();

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
  // JEEPNEY LIVE LOCATION & QUEUE STATUS MODAL
  // ===========================================================================
  void _showVehicleMapModal(BuildContext context, String vehicleId) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        return _ts(dialogCtx, SafeArea(
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
              constraints: BoxConstraints(maxWidth: 440, maxHeight: _dialogMaxHeight(context, 720)),
              child: SingleChildScrollView(
                child: StreamBuilder<DocumentSnapshot>(
                  stream: FirebaseFirestore.instance.collection('vehicles_live').doc(vehicleId).snapshots(),
                  builder: (context, snapshot) {
                    final vData = snapshot.data?.data() as Map<String, dynamic>?;
                    final plate = (vData?['plate_number'] ?? vehicleId).toString();
                    final jeepName = (vData?['vehicle_name'] ?? plate).toString();
                    final driverName = (vData?['driver_name'] ?? 'Assigned Driver').toString();
                    final status = (vData?['current_status'] ?? 'STANDBY').toString().toUpperCase();
                    final isEnRoute = status == 'EN_ROUTE';
                    final speed = (vData?['speed_kmh'] as num?)?.toInt() ?? 0;
                    final seats = (vData?['passenger_count'] as num?)?.toInt() ?? 0;
                    final maxSeats = (vData?['max_capacity'] as num?)?.toInt() ?? 20;
                    final routeId = (vData?['route_id'] ?? 'UNASSIGNED')
                        .toString()
                        .replaceAll('ROUTE_', '')
                        .replaceAll('_', ' ');
                    final dotColor = _resolveVehicleDotColor(vData?['vehicle_color']?.toString());

                    final loc = vData?['location'] as Map<String, dynamic>?;
                    double? lat;
                    double? lng;

                    if (loc != null && loc['latitude'] != null && loc['longitude'] != null) {
                      lat = (loc['latitude'] as num).toDouble();
                      lng = (loc['longitude'] as num).toDouble();
                    } else if (vData?['latitude'] != null && vData?['longitude'] != null) {
                      lat = (vData!['latitude'] as num).toDouble();
                      lng = (vData['longitude'] as num).toDouble();
                    }

                    final LatLng? unitCoord = (lat != null && lng != null) ? LatLng(lat, lng) : null;

                    return Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(7),
                                decoration: BoxDecoration(
                                  color: isEnRoute ? const Color(0xFFECFDF5) : const Color(0xFFEFF6FF),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Icons.location_on_rounded,
                                  color: isEnRoute ? const Color(0xFF059669) : const Color(0xFF2563EB),
                                  size: 20,
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
                                      style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, color: AppColors.darkSlate),
                                    ),
                                    Text(
                                      'Plate: $plate • Route: $routeId',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
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

                          Container(
                            height: (MediaQuery.of(context).size.height * 0.24).clamp(150.0, 240.0).toDouble(),
                            decoration: BoxDecoration(
                              color: AppColors.backgroundSlate,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppColors.borderSubtle),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: unitCoord != null
                                ? FlutterMap(
                                    options: MapOptions(
                                      initialCenter: unitCoord,
                                      initialZoom: 14.0,
                                    ),
                                    children: [
                                      TileLayer(
                                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                        userAgentPackageName: 'com.example.puj_dispatch_system',
                                      ),
                                      MarkerLayer(
                                        markers: [
                                          Marker(
                                            point: unitCoord,
                                            width: 160,
                                            height: 48,
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: AppColors.primaryNavy.withOpacity(0.92),
                                                    borderRadius: BorderRadius.circular(4),
                                                    border: Border.all(color: Colors.white, width: 0.8),
                                                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
                                                  ),
                                                  child: Text(
                                                    '$plate • $speed km/h',
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    textScaler: TextScaler.noScaling,
                                                    style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold),
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Container(
                                                  width: 14,
                                                  height: 14,
                                                  decoration: BoxDecoration(
                                                    color: dotColor,
                                                    shape: BoxShape.circle,
                                                    border: Border.all(color: Colors.white, width: 2),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  )
                                : Center(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.location_off_outlined, size: 36, color: AppColors.textMuted.withOpacity(0.5)),
                                          const SizedBox(height: 6),
                                          const Text('Hardware GPS Offline', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.darkSlate)),
                                          const SizedBox(height: 2),
                                          const Text('Coordinates will appear when the unit starts its shift.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
                                        ],
                                      ),
                                    ),
                                  ),
                          ),
                          const SizedBox(height: 12),

                          // ===================================================
                          // LIVE TERMINAL QUEUE OBSERVER CARD (UNDER THE MAP)
                          // ===================================================
                          StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance.collection('terminals_queue').snapshots(),
                            builder: (context, qSnap) {
                              if (!qSnap.hasData) return const SizedBox.shrink();

                              Map<String, dynamic>? matchingQueue;
                              bool isSpot1 = false;
                              int onDeckPos = -1;
                              int totalOnDeck = 0;
                              int standbyPos = -1;
                              int totalStandby = 0;

                              for (var qDoc in qSnap.data!.docs) {
                                final qData = qDoc.data() as Map<String, dynamic>;
                                final active = (qData['active_loading_vehicle'] ?? '').toString();
                                final queued = (qData['queued_vehicles'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
                                final standby = (qData['standby_staged_vehicles'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];

                                if (active == vehicleId) {
                                  matchingQueue = qData;
                                  isSpot1 = true;
                                  break;
                                } else if (queued.contains(vehicleId)) {
                                  matchingQueue = qData;
                                  onDeckPos = queued.indexOf(vehicleId) + 1;
                                  totalOnDeck = queued.length;
                                  break;
                                } else if (standby.contains(vehicleId)) {
                                  matchingQueue = qData;
                                  standbyPos = standby.indexOf(vehicleId) + 1;
                                  totalStandby = standby.length;
                                  break;
                                }
                              }

                              if (matchingQueue == null) {
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 10),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFFE2E8F0)),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.location_off_rounded, size: 16, color: AppColors.textMuted),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: const [
                                            Text(
                                              'Outside Terminal Line-Up',
                                              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                                            ),
                                            Text(
                                              'Vehicle is not currently staged or queued at any terminal bay.',
                                              style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }

                              final rawTerm = (matchingQueue['terminal_name'] ?? matchingQueue['terminal_id'] ?? 'Terminal').toString();
                              final termClean = rawTerm.contains('ROBINSON')
                                  ? 'Robinsons Terminal'
                                  : (rawTerm.contains('DALIPE') ? 'Dalipe Terminal' : rawTerm.replaceAll('TERM_', '').replaceAll('_', ' '));

                              Color qBg;
                              Color qBorder;
                              Color qText;
                              IconData qIcon;
                              String qBadge;
                              String qSub;

                              if (isSpot1) {
                                qBg = const Color(0xFFECFDF5);
                                qBorder = const Color(0xFF86EFAC);
                                qText = const Color(0xFF065F46);
                                qIcon = Icons.airline_seat_recline_normal_rounded;
                                qBadge = 'SPOT 1 • BOARDING BAY';
                                qSub = 'Actively loading passengers at $termClean (First to depart)';
                              } else if (onDeckPos != -1) {
                                qBg = const Color(0xFFEFF6FF);
                                qBorder = const Color(0xFFBFDBFE);
                                qText = const Color(0xFF1D4ED8);
                                qIcon = Icons.hourglass_top_rounded;
                                qBadge = 'ON-DECK QUEUE • SLOT #$onDeckPos';
                                qSub = 'Slot $onDeckPos of $totalOnDeck in line-up at $termClean';
                              } else {
                                qBg = const Color(0xFFFFFBEB);
                                qBorder = const Color(0xFFFDE68A);
                                qText = const Color(0xFF92400E);
                                qIcon = Icons.local_parking_rounded;
                                qBadge = 'STANDBY POOL • HOLD #$standbyPos';
                                qSub = 'Holding slot $standbyPos of $totalStandby staged for $termClean';
                              }

                              return Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: qBg,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: qBorder, width: 1.2),
                                ),
                                child: Row(
                                  children: [
                                    Icon(qIcon, color: qText, size: 20),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  qBadge,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: qText, letterSpacing: 0.3),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Flexible(
                                                child: Text(
                                                  termClean,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  textAlign: TextAlign.right,
                                                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: qText.withOpacity(0.85)),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            qSub,
                                            style: TextStyle(fontSize: 11.5, color: qText.withOpacity(0.9), height: 1.25),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),

                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppColors.backgroundSlate,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.borderSubtle),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text('STATUS', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.textMuted)),
                                        const SizedBox(height: 1),
                                        Text(
                                          isEnRoute ? 'BIYAHE • LIVE' : 'STANDBY',
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.bold,
                                            color: isEnRoute ? const Color(0xFF059669) : const Color(0xFF2563EB),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      children: [
                                        const Text('SPEED', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.textMuted)),
                                        const SizedBox(height: 1),
                                        Text('$speed km/h', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF059669))),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerRight,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        const Text('OCCUPANCY', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.textMuted)),
                                        const SizedBox(height: 1),
                                        Text(
                                          '$seats / $maxSeats Seats',
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.bold,
                                            color: seats >= maxSeats ? AppColors.errorCrimson : AppColors.darkSlate,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),

                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Text('Assigned Driver: $driverName', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                          ),
                          const SizedBox(height: 14),

                          SizedBox(
                            height: 38,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primaryNavy,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                elevation: 0,
                              ),
                              onPressed: () => Navigator.pop(dialogCtx),
                              child: const Text('Close Map', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ));
      },
    );
  }

  // ===========================================================================
  // ACCOUNT & SECURITY SETTINGS DIALOG
  // ===========================================================================
  void _showAccountSettingsModal(BuildContext context, Map<String, dynamic> currentData) {
    final formKey = GlobalKey<FormState>();
    final usernameController = TextEditingController(text: currentData['username']?.toString() ?? '');
    final pinController = TextEditingController(text: currentData['pin_code']?.toString() ?? '');
    final contactController = TextEditingController(text: currentData['contact_number']?.toString() ?? '');
    final fullNameController = TextEditingController(text: currentData['full_name']?.toString() ?? '');

    bool obscurePin = true;
    bool isSaving = false;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
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
                  constraints: BoxConstraints(maxWidth: 420, maxHeight: _dialogMaxHeight(context, 640)),
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
                                  color: AppColors.primaryNavy.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.manage_accounts_rounded, color: AppColors.primaryNavy, size: 20),
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Operator Settings', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.darkSlate)),
                                    Text('Update credentials & contact info', style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
                                  ],
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.textMuted),
                                tooltip: 'Close',
                                onPressed: () => Navigator.pop(dialogCtx),
                              ),
                            ],
                          ),
                          const Divider(height: 18, color: AppColors.borderSubtle),

                          TextFormField(
                            controller: fullNameController,
                            style: const TextStyle(fontSize: 14),
                            decoration: _buildInputDeco('Full Name', Icons.badge_outlined),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'Name is required' : null,
                          ),
                          const SizedBox(height: 10),

                          TextFormField(
                            controller: usernameController,
                            style: const TextStyle(fontSize: 14),
                            decoration: _buildInputDeco('Username', Icons.person_outline_rounded),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'Username is required' : null,
                          ),
                          const SizedBox(height: 10),

                          TextFormField(
                            controller: pinController,
                            obscureText: obscurePin,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(fontSize: 14, letterSpacing: 1.2),
                            decoration: _buildInputDeco(
                              'Security PIN (Password)',
                              Icons.lock_outline_rounded,
                              suffix: IconButton(
                                icon: Icon(obscurePin ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18, color: AppColors.textMuted),
                                onPressed: () => setDialogState(() => obscurePin = !obscurePin),
                              ),
                            ),
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) return 'PIN is required';
                              if (v.trim().length < 4) return 'Must be at least 4 digits';
                              return null;
                            },
                          ),
                          const SizedBox(height: 10),

                          TextFormField(
                            controller: contactController,
                            keyboardType: TextInputType.phone,
                            style: const TextStyle(fontSize: 14),
                            decoration: _buildInputDeco('Contact Number', Icons.phone_outlined),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'Contact is required' : null,
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
                                    onPressed: isSaving ? null : () => Navigator.pop(dialogCtx),
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
                                      backgroundColor: AppColors.primaryNavy,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      elevation: 0,
                                    ),
                                    onPressed: isSaving
                                        ? null
                                        : () async {
                                            if (!formKey.currentState!.validate()) return;
                                            setDialogState(() => isSaving = true);

                                            try {
                                              await FirebaseFirestore.instance.collection('users').doc(widget.userId).update({
                                                'full_name': fullNameController.text.trim(),
                                                'username': usernameController.text.trim().toLowerCase(),
                                                'pin_code': pinController.text.trim(),
                                                'contact_number': contactController.text.trim(),
                                              });

                                              if (!context.mounted) return;
                                              Navigator.pop(dialogCtx);
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                const SnackBar(
                                                  content: Text('Account settings updated successfully.'),
                                                  backgroundColor: Color(0xFF059669),
                                                ),
                                              );
                                            } catch (e) {
                                              setDialogState(() => isSaving = false);
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(content: Text('Update failed: $e'), backgroundColor: AppColors.errorCrimson),
                                              );
                                            }
                                          },
                                    child: isSaving
                                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                        : const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
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
  // DRIVER ASSIGNMENT DIALOG
  // ===========================================================================
  void _showAssignDriverModal({
    required BuildContext context,
    required String vehicleId,
    required String? currentDriverId,
    required List<String> driverIds,
  }) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        return _ts(dialogCtx, SafeArea(
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
              constraints: BoxConstraints(maxWidth: 420, maxHeight: MediaQuery.of(context).size.height * 0.75),
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
                              Text('Assign Driver to $vehicleId', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.darkSlate)),
                              const Text('Select an enrolled driver from your fleet roster', style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
                            ],
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.textMuted),
                          tooltip: 'Close',
                          onPressed: () => Navigator.pop(dialogCtx),
                        ),
                      ],
                    ),
                    const Divider(height: 18, color: AppColors.borderSubtle),

                    if (driverIds.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text('No drivers registered under this operator.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppColors.textMuted)),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: driverIds.length,
                          itemBuilder: (context, index) {
                            final driverId = driverIds[index];
                            final isCurrent = driverId == currentDriverId;

                            return FutureBuilder<DocumentSnapshot>(
                              future: FirebaseFirestore.instance.collection('users').doc(driverId).get(),
                              builder: (context, snapshot) {
                                final dData = snapshot.data?.data() as Map<String, dynamic>?;
                                final name = dData?['full_name'] ?? driverId;
                                final license = dData?['license_number'] ?? 'N/A';
                                final currentAssigned = dData?['assigned_vehicle'] ?? 'None';

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
                                    title: Text(name.toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                                    subtitle: Text('License: $license • Assigned: $currentAssigned', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
                                    trailing: isCurrent
                                        ? const Chip(
                                            label: Text('ACTIVE', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF1D4ED8))),
                                            backgroundColor: Color(0xFFDBEAFE),
                                            padding: EdgeInsets.zero,
                                          )
                                        : OutlinedButton(
                                            style: OutlinedButton.styleFrom(
                                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                              minimumSize: Size.zero,
                                              side: const BorderSide(color: AppColors.commuterTeal),
                                            ),
                                            onPressed: () => _executeDriverAssignment(
                                              ctx: dialogCtx,
                                              vehicleId: vehicleId,
                                              newDriverId: driverId,
                                              newDriverName: name.toString(),
                                              oldDriverId: currentDriverId,
                                            ),
                                            child: const Text('Assign', style: TextStyle(fontSize: 12, color: AppColors.commuterTeal, fontWeight: FontWeight.bold)),
                                          ),
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
        ));
      },
    );
  }

  Future<void> _executeDriverAssignment({
    required BuildContext ctx,
    required String vehicleId,
    required String newDriverId,
    required String newDriverName,
    required String? oldDriverId,
  }) async {
    Navigator.pop(ctx);

    try {
      final batch = FirebaseFirestore.instance.batch();

      final vehicleRef = FirebaseFirestore.instance.collection('vehicles_live').doc(vehicleId);
      batch.update(vehicleRef, {
        'driver_id': newDriverId,
        'driver_name': newDriverName,
      });

      final newDriverRef = FirebaseFirestore.instance.collection('users').doc(newDriverId);
      batch.update(newDriverRef, {'assigned_vehicle': vehicleId});

      if (oldDriverId != null && oldDriverId.isNotEmpty && oldDriverId != newDriverId) {
        final oldDriverRef = FirebaseFirestore.instance.collection('users').doc(oldDriverId);
        batch.update(oldDriverRef, {'assigned_vehicle': 'UNASSIGNED'});
      }

      await batch.commit();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$newDriverName assigned to $vehicleId successfully.'),
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
  // READ-ONLY COMPLAINT DETAILS MODAL
  // ===========================================================================
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

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => _ts(dialogContext, SafeArea(
        child: Dialog(
          backgroundColor: Colors.white,
          elevation: 6,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.borderSubtle),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 440, maxHeight: _dialogMaxHeight(dialogContext, 720)),
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
                          color: AppColors.errorCrimson.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.report_problem_rounded, color: AppColors.errorCrimson, size: 20),
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
                              style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, color: AppColors.darkSlate),
                            ),
                            Text('Reported on $dateStr', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      _buildLicenseBadge(plate),
                      const SizedBox(width: 4),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.textMuted),
                        onPressed: () => Navigator.pop(dialogContext),
                      ),
                    ],
                  ),
                  const Divider(height: 20, color: AppColors.borderSubtle),

                  const Text('Incident Description', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.darkSlate)),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundSlate,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.borderSubtle),
                    ),
                    child: Text(desc, style: const TextStyle(fontSize: 13, height: 1.35, color: AppColors.darkSlate)),
                  ),
                  const SizedBox(height: 12),

                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundSlate,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.person_outline_rounded, size: 16, color: AppColors.primaryNavy),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('Complainant: $complainant ($contact)', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.darkSlate)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.borderSubtle),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Text('Investigation Status', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.darkSlate)),
                              SizedBox(height: 1),
                              Text('Managed directly by Transport Cooperative', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildComplaintStatusBadge(statusKey),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  SizedBox(
                    height: 38,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryNavy,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Close', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      )),
    );
  }

  String _normalizeStatusKey(String raw) {
    final s = raw.toUpperCase();
    if (s.contains('RESOLVED')) return 'RESOLVED';
    if (s.contains('REVIEW') || s.contains('INVESTIGAT')) return 'UNDER_REVIEW';
    if (s.contains('DISMISSED') || s.contains('REJECTED')) return 'DISMISSED';
    return 'PENDING_VERIFICATION';
  }

  Widget _buildComplaintStatusBadge(String statusKey) {
    Color bg;
    Color border;
    Color text;
    IconData icon;
    String label;

    switch (statusKey) {
      case 'RESOLVED':
        bg = const Color(0xFFECFDF5);
        border = const Color(0xFFA7F3D0);
        text = const Color(0xFF065F46);
        icon = Icons.check_circle_rounded;
        label = 'RESOLVED';
        break;
      case 'UNDER_REVIEW':
        bg = const Color(0xFFEFF6FF);
        border = const Color(0xFFBFDBFE);
        text = const Color(0xFF1D4ED8);
        icon = Icons.hourglass_top_rounded;
        label = 'UNDER REVIEW';
        break;
      case 'DISMISSED':
        bg = const Color(0xFFF1F5F9);
        border = const Color(0xFFCBD5E1);
        text = const Color(0xFF475569);
        icon = Icons.cancel_outlined;
        label = 'DISMISSED';
        break;
      case 'PENDING_VERIFICATION':
      default:
        bg = const Color(0xFFFEF3C7);
        border = const Color(0xFFFCD34D);
        text = const Color(0xFFB45309);
        icon = Icons.pending_actions_rounded;
        label = 'PENDING';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border, width: 1.0),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: text),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: text, letterSpacing: 0.2)),
        ],
      ),
    );
  }

  DateTime? _parseComplaintDate(dynamic val) {
    if (val is Timestamp) return val.toDate();
    if (val is String) return DateTime.tryParse(val);
    return null;
  }

  bool _matchesStatus(String statusStr) {
    final s = statusStr.toUpperCase();
    switch (_selectedStatusFilter) {
      case 'PENDING':
        return s.contains('PENDING');
      case 'UNDER_REVIEW':
        return s.contains('REVIEW') || s.contains('INVESTIGAT');
      case 'RESOLVED':
        return s.contains('RESOLVED');
      case 'DISMISSED':
        return s.contains('DISMISSED') || s.contains('REJECTED');
      case 'ALL':
      default:
        return true;
    }
  }

  bool _matchesDate(DateTime? dt) {
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

  PopupMenuItem<String> _buildPopupMenuItem(String value, String text, IconData icon, Color color) {
    return PopupMenuItem<String>(
      value: value,
      height: 38,
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color == AppColors.commuterTeal ? AppColors.darkSlate : color),
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
      case 'DISMISSED':
        return 'Dismissed';
      default:
        return 'All Statuses';
    }
  }

  String _getDateLabel(String key) {
    switch (key) {
      case 'TODAY':
        return 'Today';
      case '7DAYS':
        return 'Past 7 Days';
      case 'CUSTOM':
        return _customDateRange != null
            ? '${_customDateRange!.start.month}/${_customDateRange!.start.day}-${_customDateRange!.end.month}/${_customDateRange!.end.day}'
            : 'Custom Range';
      default:
        return 'All Time';
    }
  }

  // ===========================================================================
  // TAB 3: COMPLAINTS TAB (DESCENDING ORDER & FULLY CLICKABLE)
  // ===========================================================================
  Widget _buildComplaintsTab(List<String> assignedJeepneys) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('vehicles_live').snapshots(),
      builder: (context, vSnapshot) {
        if (vSnapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: AppColors.commuterTeal));
        }

        final Set<String> ownedPlates = {};
        for (var doc in vSnapshot.data?.docs ?? []) {
          final data = doc.data() as Map<String, dynamic>;
          final docId = doc.id;
          final opId = data['operator_id']?.toString().trim();
          final isOwned = assignedJeepneys.contains(docId) || opId == widget.userId;

          if (isOwned) {
            ownedPlates.add(_normalizePlate(docId));
            if (data['plate_number'] != null) {
              ownedPlates.add(_normalizePlate(data['plate_number'].toString()));
            }
            if (data['vehicle_name'] != null) {
              ownedPlates.add(_normalizePlate(data['vehicle_name'].toString()));
            }
          }
        }

        for (var j in assignedJeepneys) {
          ownedPlates.add(_normalizePlate(j));
        }

        if (ownedPlates.isEmpty) {
          return _buildEmptyState(
            icon: Icons.shield_outlined,
            title: 'Zero Complaints',
            subtitle: 'No registered jeepneys found under your operator account.',
          );
        }

        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection('complaints').snapshots(),
          builder: (context, cSnapshot) {
            if (cSnapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator(color: AppColors.commuterTeal));
            }

            final allComplaints = cSnapshot.data?.docs ?? [];

            final fleetComplaints = allComplaints.where((doc) {
              final c = doc.data() as Map<String, dynamic>;
              final cPlate = _normalizePlate(c['plate_number']?.toString() ?? '');
              final cVehicleId = _normalizePlate(c['vehicle_id']?.toString() ?? '');
              final cOpId = c['operator_id']?.toString().trim();

              if (cOpId != null && cOpId == widget.userId) return true;
              if (cPlate.isNotEmpty && ownedPlates.contains(cPlate)) return true;
              if (cVehicleId.isNotEmpty && ownedPlates.contains(cVehicleId)) return true;

              return ownedPlates.any((op) => op.isNotEmpty && (cPlate.contains(op) || op.contains(cPlate)));
            }).toList();

            final int totalCount = fleetComplaints.length;
            final int pendingCount = fleetComplaints.where((d) => (d['status'] ?? '').toString().toUpperCase().contains('PENDING')).length;
            final int resolvedCount = fleetComplaints.where((d) => (d['status'] ?? '').toString().toUpperCase().contains('RESOLVED')).length;

            final filteredComplaints = fleetComplaints.where((d) {
              final c = d.data() as Map<String, dynamic>;
              final statusMatch = _matchesStatus((c['status'] ?? '').toString());
              final dateMatch = _matchesDate(_parseComplaintDate(c['created_at']));
              return statusMatch && dateMatch;
            }).toList();

            // SORT DESCENDING: Latest complaints at the top
            filteredComplaints.sort((a, b) {
              final dtA = _parseComplaintDate((a.data() as Map<String, dynamic>)['created_at']);
              final dtB = _parseComplaintDate((b.data() as Map<String, dynamic>)['created_at']);
              if (dtA == null && dtB == null) return 0;
              if (dtA == null) return 1;
              if (dtB == null) return -1;
              return dtB.compareTo(dtA);
            });

            return ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              children: [
                Row(
                  children: [
                    _buildKpiCard('ALL REPORTS', '$totalCount', Icons.report_outlined, AppColors.primaryNavy),
                    const SizedBox(width: 6),
                    _buildKpiCard('PENDING', '$pendingCount', Icons.pending_actions_rounded, const Color(0xFFD97706)),
                    const SizedBox(width: 6),
                    _buildKpiCard('RESOLVED', '$resolvedCount', Icons.check_circle_outline_rounded, const Color(0xFF059669)),
                  ],
                ),
                const SizedBox(height: 10),

                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.borderSubtle),
                    boxShadow: const [BoxShadow(color: Color(0x03000000), blurRadius: 4, offset: Offset(0, 1.5))],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: PopupMenuButton<String>(
                          offset: const Offset(0, 42),
                          elevation: 4,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: AppColors.borderSubtle)),
                          color: Colors.white,
                          onSelected: (val) => setState(() => _selectedStatusFilter = val),
                          itemBuilder: (context) => [
                            _buildPopupMenuItem('ALL', 'All Statuses', Icons.tune_rounded, AppColors.primaryNavy),
                            _buildPopupMenuItem('PENDING', 'Pending', Icons.pending_actions_rounded, const Color(0xFFD97706)),
                            _buildPopupMenuItem('UNDER_REVIEW', 'Under Review', Icons.hourglass_top_rounded, const Color(0xFF2563EB)),
                            _buildPopupMenuItem('RESOLVED', 'Resolved', Icons.check_circle_rounded, const Color(0xFF059669)),
                            _buildPopupMenuItem('DISMISSED', 'Dismissed', Icons.cancel_outlined, const Color(0xFF64748B)),
                          ],
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppColors.backgroundSlate,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.borderSubtle.withOpacity(0.6)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(_getStatusLabel(_selectedStatusFilter), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: AppColors.darkSlate)),
                                ),
                                const Icon(Icons.expand_more_rounded, size: 16, color: AppColors.primaryNavy),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      Expanded(
                        child: PopupMenuButton<String>(
                          offset: const Offset(0, 42),
                          elevation: 4,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: AppColors.borderSubtle)),
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
                            _buildPopupMenuItem('ALL', 'All Time', Icons.calendar_month_rounded, AppColors.primaryNavy),
                            _buildPopupMenuItem('TODAY', 'Today', Icons.today_rounded, AppColors.commuterTeal),
                            _buildPopupMenuItem('7DAYS', 'Past 7 Days', Icons.date_range_rounded, AppColors.commuterTeal),
                            _buildPopupMenuItem('CUSTOM', 'Custom Range...', Icons.edit_calendar_rounded, AppColors.commuterTeal),
                          ],
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppColors.backgroundSlate,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.borderSubtle.withOpacity(0.6)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(_getDateLabel(_selectedDateFilter), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: AppColors.darkSlate)),
                                ),
                                const Icon(Icons.expand_more_rounded, size: 16, color: AppColors.primaryNavy),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),

                if (filteredComplaints.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 12),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.filter_alt_off_rounded, size: 36, color: AppColors.textMuted.withOpacity(0.5)),
                          const SizedBox(height: 8),
                          const Text('No matching complaints', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.darkSlate)),
                          const SizedBox(height: 2),
                          Text(
                            fleetComplaints.isEmpty ? 'No incident reports logged for your registered fleet.' : 'Try changing your status or date filter.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  ...filteredComplaints.map((doc) {
                    final c = doc.data() as Map<String, dynamic>;
                    final category = (c['category'] ?? 'General Infraction').toString();
                    final plate = (c['plate_number'] ?? 'N/A').toString();
                    final desc = (c['description'] ?? 'No description provided.').toString();
                    final rawStatus = (c['status'] ?? 'PENDING_VERIFICATION').toString();
                    final statusKey = _normalizeStatusKey(rawStatus);
                    final complainant = (c['complainant_name'] ?? 'Passenger').toString();
                    final contact = (c['complainant_contact'] ?? 'N/A').toString();
                    final dt = _parseComplaintDate(c['created_at']);
                    final dateStr = dt != null ? dt.toLocal().toString().substring(0, 16) : 'Recent';

                    // ENTIRE COMPLAINT CARD IS CLICKABLE
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.borderSubtle, width: 1),
                        boxShadow: const [BoxShadow(color: Color(0x03000000), blurRadius: 4, offset: Offset(0, 1.5))],
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _showComplaintDetailModal(doc),
                          child: Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Flexible(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                                        decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(4)),
                                        child: Text(category.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.errorCrimson)),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _buildComplaintStatusBadge(statusKey),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  desc,
                                  style: const TextStyle(fontSize: 13, color: AppColors.darkSlate, height: 1.35),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text('Reported: $dateStr', style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
                                const Divider(height: 14, color: AppColors.borderSubtle),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    _buildLicenseBadge(plate),
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                        child: Text(
                                          'By: $complainant ($contact)',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                                        ),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                      decoration: BoxDecoration(color: AppColors.backgroundSlate, borderRadius: BorderRadius.circular(4), border: Border.all(color: AppColors.borderSubtle)),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.info_outline_rounded, size: 12, color: AppColors.primaryNavy),
                                          SizedBox(width: 3),
                                          Text('Details', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: AppColors.primaryNavy)),
                                        ],
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
                  }),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDriverResolver({required String vehicleId, String? driverId, String? explicitName}) {
    if (explicitName != null && explicitName.isNotEmpty && explicitName != 'No Driver Assigned') {
      return Text(explicitName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.darkSlate));
    }

    if (driverId != null && driverId.isNotEmpty && driverId != 'UNASSIGNED') {
      return FutureBuilder<DocumentSnapshot>(
        future: FirebaseFirestore.instance.collection('users').doc(driverId.trim()).get(),
        builder: (context, snapshot) {
          final dData = snapshot.data?.data() as Map<String, dynamic>?;
          return Text(dData?['full_name'] ?? driverId, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.darkSlate));
        },
      );
    }

    return const Text('No Driver Assigned', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textMuted));
  }

  Widget _buildKpiCard(String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.borderSubtle)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(height: 4),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: color)),
            const SizedBox(height: 1),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.textMuted)),
          ],
        ),
      ),
    );
  }

  Widget _buildLicenseBadge(String plate) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 130),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
        decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(4)),
        child: Text(
          plate.replaceAll('_', ' ').toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800, fontSize: 12, color: Color(0xFF1E293B)),
        ),
      ),
    );
  }

  Widget _buildStatusPill(String status, bool isEnRoute) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: isEnRoute ? const Color(0xFFECFDF5) : const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: isEnRoute ? const Color(0xFF10B981) : const Color(0xFF93C5FD)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: isEnRoute ? const Color(0xFF10B981) : const Color(0xFF3B82F6), shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(status.replaceAll('_', ' '), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: isEnRoute ? const Color(0xFF059669) : const Color(0xFF1D4ED8))),
        ],
      ),
    );
  }

  Widget _buildCapacityBar(int current, int max) {
    final double ratio = (max > 0) ? (current / max).clamp(0.0, 1.0) : 0.0;
    final color = ratio >= 1.0 ? AppColors.errorCrimson : ratio >= 0.8 ? const Color(0xFFF59E0B) : const Color(0xFF059669);

    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(value: ratio, minHeight: 4, backgroundColor: Colors.black12, valueColor: AlwaysStoppedAnimation<Color>(color)),
    );
  }

  Widget _buildEmptyState({required IconData icon, required String title, required String subtitle}) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 38, color: AppColors.textMuted.withOpacity(0.5)),
            const SizedBox(height: 10),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.darkSlate)),
            const SizedBox(height: 3),
            Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          ],
        ),
      ),
    );
  }

  InputDecoration _buildInputDeco(String label, IconData icon, {String? hint, Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      prefixIcon: Icon(icon, size: 17, color: AppColors.textMuted),
      suffixIcon: suffix,
      labelStyle: const TextStyle(fontSize: 13, color: AppColors.textMuted),
      hintStyle: TextStyle(fontSize: 13, color: AppColors.textMuted.withOpacity(0.6)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      filled: true,
      fillColor: AppColors.backgroundSlate,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.borderSubtle)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.commuterTeal, width: 1.3)),
    );
  }

  // ===========================================================================
  // MAIN APP BAR & SCAFFOLD
  // ===========================================================================
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('users').doc(widget.userId).snapshots(),
      builder: (context, snapshot) {
        final opData = snapshot.hasData && snapshot.data!.exists ? snapshot.data!.data() as Map<String, dynamic> : widget.userData;

        final fullName = (opData['full_name'] ?? 'Fleet Operator').toString();
        final contact = (opData['contact_number'] ?? 'N/A').toString();
        final assignedJeepneys = _getAssignedJeepneys(opData);
        final assignedDrivers = _getAssignedDrivers(opData);

        final initialChar = fullName.trim().isNotEmpty ? fullName.trim()[0].toUpperCase() : 'O';

        return _ts(context, Scaffold(
          backgroundColor: AppColors.backgroundSlate,
          appBar: AppBar(
            elevation: 0.5,
            backgroundColor: AppColors.primaryNavy,
            automaticallyImplyLeading: false,
            titleSpacing: 14,
            title: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.12),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.commuterTeal.withOpacity(0.55), width: 1.4),
                  ),
                  child: Center(
                    child: Text(initialChar, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(fullName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: AppColors.commuterTeal.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: AppColors.commuterTeal.withOpacity(0.5), width: 0.8),
                            ),
                            child: const Text('OPERATOR', style: TextStyle(color: AppColors.commuterTeal, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 1.5),
                      Row(
                        children: [
                          Icon(Icons.phone_iphone_rounded, size: 11, color: Colors.white.withOpacity(0.6)),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(contact, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12, fontWeight: FontWeight.w500)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 20),
                tooltip: 'Operator Menu',
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                onSelected: (value) async {
                  if (value == 'SETTINGS') {
                    _showAccountSettingsModal(context, opData);
                  } else if (value == 'LOGOUT') {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.remove('staff_user_id');
                    await prefs.remove('staff_role');
                    if (!mounted) return;
                    Navigator.pushAndRemoveUntil(
                      context,
                      MaterialPageRoute(builder: (context) => const LoginScreen()),
                      (route) => false,
                    );
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'SETTINGS',
                    height: 38,
                    child: Row(
                      children: [
                        Icon(Icons.settings_outlined, size: 16, color: AppColors.darkSlate),
                        SizedBox(width: 8),
                        Text('Account Settings', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(height: 1),
                  const PopupMenuItem(
                    value: 'LOGOUT',
                    height: 38,
                    child: Row(
                      children: [
                        Icon(Icons.logout_rounded, size: 16, color: AppColors.errorCrimson),
                        SizedBox(width: 8),
                        Text('Log Out', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.errorCrimson)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(42),
              child: Container(
                decoration: const BoxDecoration(
                  color: AppColors.primaryNavy,
                  border: Border(bottom: BorderSide(color: Colors.white12)),
                ),
                child: TabBar(
                  controller: _tabController,
                  indicatorColor: AppColors.commuterTeal,
                  indicatorWeight: 2.5,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 10),
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white54,
                  labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.normal, fontSize: 13),
                  tabs: [
                    Tab(text: 'Fleet (${assignedJeepneys.length})'),
                    Tab(text: 'Drivers (${assignedDrivers.length})'),
                    const Tab(text: 'Complaints'),
                  ],
                ),
              ),
            ),
          ),
          floatingActionButton: _tabController.index == 1
              ? FloatingActionButton.extended(
                  backgroundColor: const Color(0xFF059669),
                  foregroundColor: Colors.white,
                  elevation: 4,
                  icon: const Icon(Icons.person_add_rounded, size: 18),
                  label: const Text('Add Driver', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  onPressed: () => _showAddDriverModal(context, assignedJeepneys, opData),
                )
              : null,
          body: SafeArea(
            bottom: true,
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildFleetTab(assignedJeepneys, assignedDrivers),
                _buildDriversTab(assignedDrivers),
                _buildComplaintsTab(assignedJeepneys),
              ],
            ),
          ),
        ));
      },
    );
  }

  // ===========================================================================
  // TAB 1: FLEET OVERVIEW
  // ===========================================================================
  Widget _buildFleetTab(List<String> jeepneys, List<String> drivers) {
    if (jeepneys.isEmpty) {
      return _buildEmptyState(
        icon: Icons.directions_bus_outlined,
        title: 'No Units Assigned Yet',
        subtitle: 'Franchise jeepneys assigned to your account by your Transport Cooperative will appear here.',
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('vehicles_live').where(FieldPath.documentId, whereIn: jeepneys).snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];
        final int enRouteCount = docs.where((d) => (d['current_status'] ?? '').toString().toUpperCase() == 'EN_ROUTE').length;
        final int standbyCount = docs.length - enRouteCount;

        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          children: [
            Row(
              children: [
                _buildKpiCard('FLEET UNITS', '${jeepneys.length}', Icons.commute_rounded, AppColors.primaryNavy),
                const SizedBox(width: 6),
                _buildKpiCard('EN ROUTE', '$enRouteCount', Icons.trending_up_rounded, const Color(0xFF059669)),
                const SizedBox(width: 6),
                _buildKpiCard('STANDBY', '$standbyCount', Icons.local_parking_rounded, const Color(0xFF2563EB)),
              ],
            ),
            const SizedBox(height: 10),

            ...jeepneys.map((vehicleId) => _buildCompactVehicleCard(vehicleId, drivers)),
          ],
        );
      },
    );
  }

  Widget _buildCompactVehicleCard(String vehicleId, List<String> drivers) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('vehicles_live').doc(vehicleId).snapshots(),
      builder: (context, snapshot) {
        final vData = snapshot.data?.data() as Map<String, dynamic>?;
        final plate = (vData?['plate_number'] ?? vehicleId).toString();
        final jeepName = (vData?['vehicle_name'] ?? plate).toString();
        final status = (vData?['current_status'] ?? 'STANDBY').toString().toUpperCase();
        final driverId = vData?['driver_id']?.toString();
        final driverName = vData?['driver_name']?.toString();
        final routeId = vData?['route_id'] ?? 'UNASSIGNED';
        final seats = (vData?['passenger_count'] as num?)?.toInt() ?? 0;
        final maxSeats = (vData?['max_capacity'] as num?)?.toInt() ?? 20;
        final speed = (vData?['speed_kmh'] as num?)?.toInt() ?? 0;
        final isEnRoute = status == 'EN_ROUTE';

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isEnRoute ? const Color(0xFF10B981).withOpacity(0.5) : AppColors.borderSubtle,
              width: isEnRoute ? 1.3 : 1,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _showVehicleMapModal(context, vehicleId),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            _buildLicenseBadge(plate),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(jeepName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, color: AppColors.darkSlate, fontWeight: FontWeight.w700)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Row(
                        children: [
                          _buildStatusPill(status, isEnRoute),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: AppColors.primaryNavy.withOpacity(0.06),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Icon(Icons.map_outlined, size: 14, color: AppColors.primaryNavy),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: AppColors.borderSubtle),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Row(
                    children: [
                      const Icon(Icons.person_rounded, size: 15, color: AppColors.primaryNavy),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _buildDriverResolver(vehicleId: vehicleId, driverId: driverId, explicitName: driverName),
                      ),
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: () => _showAssignDriverModal(
                          context: context,
                          vehicleId: vehicleId,
                          currentDriverId: driverId,
                          driverIds: drivers,
                        ),
                        borderRadius: BorderRadius.circular(5),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                          decoration: BoxDecoration(
                            color: AppColors.commuterTeal.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: AppColors.commuterTeal.withOpacity(0.3)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.swap_horiz_rounded, size: 13, color: AppColors.commuterTeal),
                              SizedBox(width: 3),
                              Text('Reassign', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.commuterTeal)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: const BoxDecoration(
                    color: AppColors.backgroundSlate,
                    borderRadius: BorderRadius.vertical(bottom: Radius.circular(9)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('ROUTE', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.textMuted)),
                            const SizedBox(height: 1),
                            Text(
                              routeId.toString().replaceAll('ROUTE_', '').replaceAll('_', ' '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.darkSlate),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        flex: 4,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Flexible(
                                  child: Text('CAPACITY', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.textMuted)),
                                ),
                                const SizedBox(width: 4),
                                Text('$seats/$maxSeats', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            const SizedBox(height: 2),
                            _buildCapacityBar(seats, maxSeats),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            const Text('SPEED', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.textMuted)),
                            const SizedBox(height: 1),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Text('$speed km/h', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF059669))),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================
  // TAB 2: DRIVERS ROSTER
  // ===========================================================================
  Widget _buildDriversTab(List<String> drivers) {
    if (drivers.isEmpty) {
      return _buildEmptyState(
        icon: Icons.person_off_outlined,
        title: 'No Drivers Enrolled',
        subtitle: 'Tap the "Add Driver" button below to register a driver under your fleet.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(left: 12, right: 12, top: 10, bottom: 80),
      itemCount: drivers.length,
      itemBuilder: (context, index) {
        final driverId = drivers[index];

        return FutureBuilder<DocumentSnapshot>(
          future: FirebaseFirestore.instance.collection('users').doc(driverId).get(),
          builder: (context, snapshot) {
            final dData = snapshot.data?.data() as Map<String, dynamic>?;
            final name = dData?['full_name'] ?? driverId;
            final license = dData?['license_number'] ?? 'N/A';
            final assignedVehicle = dData?['assigned_vehicle'] ?? 'UNASSIGNED';
            final pin = dData?['pin_code'] ?? '****';
            final isVerified = dData?['is_license_verified'] == true;
            final hasVehicle = assignedVehicle != 'UNASSIGNED' && assignedVehicle != 'None';

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                leading: CircleAvatar(
                  radius: 17,
                  backgroundColor: hasVehicle ? const Color(0xFFECFDF5) : Colors.grey.withOpacity(0.12),
                  child: Icon(Icons.person_rounded, color: hasVehicle ? const Color(0xFF059669) : AppColors.textMuted, size: 18),
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        name.toString(),
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.darkSlate),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isVerified) ...[
                      const SizedBox(width: 4),
                      const Tooltip(
                        message: 'Verified LTO Driver\'s License',
                        child: Icon(Icons.verified_rounded, size: 14, color: Color(0xFF059669)),
                      ),
                    ],
                  ],
                ),
                subtitle: Text('License: $license • PIN: $pin', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                trailing: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 110),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: hasVehicle ? const Color(0xFFEFF6FF) : const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: hasVehicle ? const Color(0xFF93C5FD) : const Color(0xFFFECACA)),
                    ),
                    child: Text(
                      hasVehicle ? assignedVehicle.toString() : 'UNASSIGNED',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: hasVehicle ? const Color(0xFF1D4ED8) : AppColors.errorCrimson,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}