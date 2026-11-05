import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../utils/app_colors.dart';
import '../../utils/app_typography.dart';

const String _googleVisionApiKey = 'YOUR_GOOGLE_CLOUD_VISION_API_KEY';
const String _philSmsToken = '4996|N53HM3ofC0YqJXkdkS9sRsFeaeMNlEaUuPyY6VIw99a6f0d0';

class PassengerComplaintScreen extends StatefulWidget {
  final String? terminalName;
  final String? terminalId;
  final String? destination;
  final String? routeId;

  const PassengerComplaintScreen({
    super.key,
    this.terminalName,
    this.terminalId,
    this.destination,
    this.routeId,
  });

  @override
  State<PassengerComplaintScreen> createState() => _PassengerComplaintScreenState();
}

class _PassengerComplaintScreenState extends State<PassengerComplaintScreen> {
  final _formKey = GlobalKey<FormState>();

  final _lastNameController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _miController = TextEditingController();

  final _contactController = TextEditingController();
  final _plateController = TextEditingController();
  final _plateFocusNode = FocusNode();
  final _descriptionController = TextEditingController();

  String _selectedCategory = 'Reckless Driving';
  bool _isSubmitting = false;
  List<String> _routePlates = [];
  List<String> _recentDispatchedPlates = [];

  Uint8List? _idImageBytes;
  String? _idImageFileName;
  String? _scannedRawText;
  bool _isOcrScanning = false;
  bool _isIdRecognized = false;
  bool _isNameMatched = false;
  String _ocrVerificationMessage = '';
  final ImagePicker _picker = ImagePicker();

  final List<String> _categories = [
    'Reckless Driving',
    'Overcharging / Fare Issue',
    'Overloading',
    'Rude Driver / Conductor',
    'Trip Cutting (Short Route)',
    'Refusal of Conveyance',
    'Others',
  ];

  static const List<String> _validIdKeywords = [
    'republika ng pilipinas',
    'republic of the philippines',
    'pambansang pagkakakilanlan',
    'philippine identification',
    'philid',
    'pilipinas',
    'driver',
    'license',
    'identity',
    'identification',
    'philhealth',
    'social security',
    'sss',
    'umid',
    'tin',
    'prc',
    'postal',
    'voter',
    'student',
    'school',
    'college',
    'university',
    'id no',
    'cardholder',
    'signature',
    'birth',
    'apelyido',
    'pangalan',
  ];

  double _scale(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return (width / 375.0).clamp(0.95, 1.25);
  }

  @override
  void initState() {
    super.initState();
    _fetchRoutePlates();
    _fetchRecentlyDispatchedPlates();
  }

  @override
  void dispose() {
    _lastNameController.dispose();
    _firstNameController.dispose();
    _miController.dispose();
    _contactController.dispose();
    _plateController.dispose();
    _plateFocusNode.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _fetchRoutePlates() async {
    try {
      Query<Map<String, dynamic>> query =
          FirebaseFirestore.instance.collection('vehicles_live');
      if (widget.routeId != null && widget.routeId!.isNotEmpty) {
        query = query.where('route_id', isEqualTo: widget.routeId);
      } else {
        query = query.limit(500);
      }
      final querySnapshot = await query.get();

      final Set<String> plates = {};
      for (var doc in querySnapshot.docs) {
        final data = doc.data();
        final plate = (data['plate_number'] ?? doc.id).toString().trim().toUpperCase();
        if (plate.isNotEmpty) plates.add(plate);
      }

      if (mounted) {
        setState(() {
          _routePlates = plates.toList()..sort();
        });
      }
    } catch (_) {}
  }

  Future<void> _fetchRecentlyDispatchedPlates() async {
    if (widget.routeId == null || widget.routeId!.isEmpty) return;

    try {
      final routeVehicles = await FirebaseFirestore.instance
          .collection('vehicles_live')
          .where('route_id', isEqualTo: widget.routeId)
          .get();

      final Map<String, String> vehicleIdToPlateMap = {};
      for (var doc in routeVehicles.docs) {
        final data = doc.data();
        final plate = (data['plate_number'] ?? '').toString().trim().toUpperCase();
        if (plate.isNotEmpty) {
          vehicleIdToPlateMap[doc.id.toUpperCase()] = plate;
        }
      }

      final logsSnapshot = await FirebaseFirestore.instance
          .collection('dispatch_logs')
          .where('route_id', isEqualTo: widget.routeId)
          .limit(10)
          .get();

      final Set<String> resolvedPlates = {};
      for (var doc in logsSnapshot.docs) {
        final data = doc.data();
        final directPlate = (data['plate_number'] ?? '').toString().trim().toUpperCase();

        if (directPlate.isNotEmpty) {
          resolvedPlates.add(directPlate);
        } else {
          final vId = (data['vehicle_id'] ?? '').toString().trim().toUpperCase();
          if (vehicleIdToPlateMap.containsKey(vId)) {
            resolvedPlates.add(vehicleIdToPlateMap[vId]!);
          } else if (vId.isNotEmpty) {
            resolvedPlates.add(vId);
          }
        }
        if (resolvedPlates.length >= 4) break;
      }

      if (mounted && resolvedPlates.isNotEmpty) {
        setState(() {
          _recentDispatchedPlates = resolvedPlates.toList();
        });
      }
    } catch (_) {}
  }

  void _showImageSourcePicker(double s) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16 * s)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 14.0 * s),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38 * s,
                height: 4 * s,
                margin: EdgeInsets.only(bottom: 12 * s),
                decoration: BoxDecoration(
                  color: AppColors.borderSubtle,
                  borderRadius: BorderRadius.circular(2 * s),
                ),
              ),
              Text('Attach Identification Card', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16 * s)),
              SizedBox(height: 6 * s),
              ListTile(
                dense: true,
                leading: Icon(Icons.camera_alt_outlined, color: AppColors.commuterTeal, size: 22 * s),
                title: Text('Capture Card with Camera', style: TextStyle(fontSize: 14 * s, fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndProcessIdImage(ImageSource.camera);
                },
              ),
              ListTile(
                dense: true,
                leading: Icon(Icons.photo_library_outlined, color: AppColors.commuterTeal, size: 22 * s),
                title: Text('Choose from Gallery', style: TextStyle(fontSize: 14 * s, fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndProcessIdImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAndProcessIdImage(ImageSource source) async {
    try {
      final XFile? file = await _picker.pickImage(
        source: source,
        maxWidth: 1400,
        maxHeight: 1400,
        imageQuality: 85,
      );

      if (file == null) return;

      final bytes = await file.readAsBytes();
      if (bytes.lengthInBytes > 1024 * 1024) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Image is too large. Please take a clear, cropped photo.'),
            backgroundColor: AppColors.errorCrimson,
          ),
        );
        return;
      }

      setState(() {
        _idImageBytes = bytes;
        _idImageFileName = file.name;
        _isOcrScanning = true;
        _ocrVerificationMessage = '';
      });

      String extractedText = '';
      List<_OcrLine> ocrLines = const [];

      if (kIsWeb) {
        final result = await _performOcrSpaceFallback(bytes);
        extractedText = result.text;
        ocrLines = result.lines;
      } else {
        final inputImage = InputImage.fromFilePath(file.path);
        final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
        final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
        await textRecognizer.close();
        extractedText = recognizedText.text;
        ocrLines = [
          for (final block in recognizedText.blocks)
            for (final line in block.lines) _OcrLine(line.text, line.boundingBox),
        ];
      }

      if (kDebugMode) {
        debugPrint('ID OCR text:\n$extractedText');
      }

      if (!mounted) return;
      _scannedRawText = extractedText;
      final nameFilled = _autofillNameFromId(extractedText, ocrLines);
      _verifyExtractedText(extractedText);

      if (!nameFilled && _isIdRecognized && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Couldn't read a name from this ID. Please type it exactly as printed."),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isOcrScanning = false;
        _isIdRecognized = false;
        _isNameMatched = false;
        _ocrVerificationMessage = 'Scanner error: $e';
      });
    }
  }

  Future<_OcrResult> _performOcrSpaceFallback(Uint8List imageBytes) async {
    try {
      final base64Image = 'data:image/jpeg;base64,${base64Encode(imageBytes)}';
      final response = await http.post(
        Uri.parse('https://api.ocr.space/parse/image'),
        headers: {'apikey': 'helloworld'},
        body: {
          'base64Image': base64Image,
          'language': 'eng',
          'isOverlayRequired': 'true', // gives each line's position
          'OCREngine': '2',
        },
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final parsedResults = json['ParsedResults'] as List<dynamic>?;
        if (parsedResults != null && parsedResults.isNotEmpty) {
          final first = parsedResults[0] as Map<String, dynamic>;
          final text = (first['ParsedText'] ?? '').toString();

          final lines = <_OcrLine>[];
          final overlay = first['TextOverlay'];
          final rawLines = overlay is Map ? overlay['Lines'] : null;
          if (rawLines is List) {
            for (final l in rawLines) {
              final words = l is Map ? l['Words'] : null;
              if (words is! List || words.isEmpty) continue;

              double left = double.infinity;
              double top = double.infinity;
              double right = 0;
              double bottom = 0;
              final parts = <String>[];
              for (final w in words) {
                if (w is! Map) continue;
                final wl = (w['Left'] as num?)?.toDouble() ?? 0;
                final wt = (w['Top'] as num?)?.toDouble() ?? 0;
                final ww = (w['Width'] as num?)?.toDouble() ?? 0;
                final wh = (w['Height'] as num?)?.toDouble() ?? 0;
                if (wl < left) left = wl;
                if (wt < top) top = wt;
                if (wl + ww > right) right = wl + ww;
                if (wt + wh > bottom) bottom = wt + wh;
                parts.add((w['WordText'] ?? '').toString());
              }
              if (left == double.infinity || top == double.infinity) continue;
              final lineText = (l['LineText'] ?? parts.join(' ')).toString();
              lines.add(_OcrLine(lineText, Rect.fromLTRB(left, top, right, bottom)));
            }
          }
          return _OcrResult(text, lines);
        }
      }
    } catch (_) {}
    return const _OcrResult('', []);
  }

  // ===========================================================================
  // ID NAME AUTO-FILL
  // Reads the printed name off the scanned ID and fills First / M.I. / Last.
  // Layouts handled:
  //   1. Label + value on the same or next line (PhilID, UMID, school IDs):
  //        "Apelyido/Last Name"  ->  "DELA CRUZ"
  //   2. All labels first, all values afterwards (a common OCR reading order)
  //   3. One "LAST, FIRST MIDDLE" line (driver's license)
  // When no name is found the fields are left exactly as the user typed them.
  // ===========================================================================
  bool _nameAutoFilled = false;

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
    r'republi|pilipinas|philippine|birth|petsa|kasarian|\bsex\b|address|tirahan|signature|license|identification|nationality|\bno\b|valid|expir',
    caseSensitive: false,
  );
  static final RegExp _addressWords = RegExp(
    r'\b(city|municipality|metro|manila|barangay|brgy|street|avenue|road|province|purok|zone|blk|block|lot|subdivision|village|poblacion|region)\b',
    caseSensitive: false,
  );

  bool _looksLikeId(String text) {
    if (text.trim().length < 15) return false;
    final t = text.replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), ' ').toLowerCase();
    return _validIdKeywords.any((k) => t.contains(k));
  }

  /// "dela cruz" -> "Dela Cruz", "o'brien" -> "O'Brien", "ann-marie" -> "Ann-Marie".
  String _titleCase(String input) {
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

  String? _cleanNameValue(String raw) {
    var v = _fixOcrConfusables(_stripAccents(raw))
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

  bool _isLabelLine(String line) =>
      _midLabel.hasMatch(line) ||
      _lastLabel.hasMatch(line) ||
      _givenLabel.hasMatch(line) ||
      _nonNameWords.hasMatch(line);

  /// 'last' | 'given' | 'middle' when [line] holds exactly one name label.
  String? _labelKind(String line) {
    final isMid = _midLabel.hasMatch(line);
    final isLast = !isMid && _lastLabel.hasMatch(line);
    final isGiven = _givenLabel.hasMatch(line);
    final count = [isMid, isLast, isGiven].where((b) => b).length;
    if (count != 1) return null; // no label, or a combined header line
    return isMid ? 'middle' : (isLast ? 'last' : 'given');
  }

  RegExp _labelRegex(String kind) =>
      kind == 'middle' ? _midLabel : (kind == 'last' ? _lastLabel : _givenLabel);

  /// The value written after the label on the same line, if there is one.
  String? _valueOnLabelLine(String line, String kind) {
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

  /// Value for the label on line [i]: the text after the label on the same
  /// line, otherwise the next one or two lines (stopping at another label).
  String? _valueForLabel(List<String> lines, int i, String kind) {
    final same = _valueOnLabelLine(lines[i], kind);
    if (same != null) return same;
    for (int j = i + 1; j < lines.length && j <= i + 2; j++) {
      if (_isLabelLine(lines[j])) break;
      final v = _cleanNameValue(lines[j]);
      if (v != null) return v;
    }
    return null;
  }

  _IdName? _extractNameFromId(String text) {
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
      return _IdName(first: given, middle: middle ?? '', last: last);
    }

    // 2) Labels grouped together, values grouped right after them
    //    (values are read in the same order as the labels).
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
      final limit = min(lines.length, end + kinds.length + 3);
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
        if (l2 != null && g2 != null) {
          return _IdName(first: g2, middle: m2 ?? '', last: l2);
        }
      }
      idx = end;
    }

    // 3) Driver's license style: one line "DELA CRUZ, JUAN CARLOS SANTOS",
    //    only trusted when the card has the name labels somewhere.
    if (_lastLabel.hasMatch(text) && _givenLabel.hasMatch(text)) {
      final comma = RegExp(
        r"^([A-ZÑ][A-ZÑ.'\-\s]*[A-ZÑ.]),\s*([A-ZÑ][A-ZÑ.'\-\s]*[A-ZÑ.])$",
      );
      for (final l in lines) {
        final m = comma.firstMatch(l);
        if (m == null || _nonNameWords.hasMatch(l) || _addressWords.hasMatch(l)) {
          continue;
        }
        final lastName = _cleanNameValue(m.group(1)!);
        final rest = _cleanNameValue(m.group(2)!);
        if (lastName == null || rest == null) continue;
        final parts = rest.split(' ');
        if (parts.length >= 2) {
          return _IdName(
            first: parts.sublist(0, parts.length - 1).join(' '),
            middle: parts.last,
            last: lastName,
          );
        }
        return _IdName(first: rest, middle: '', last: lastName);
      }
    }
    return null;
  }

  static const Map<String, String> _digitToLetter = {
    '0': 'o', '1': 'i', '2': 'z', '3': 'e', '4': 'a', '5': 's', '6': 'g', '8': 'b',
  };

  /// OCR often reads letters as digits inside a word ("D3LA", "CR0Z").
  /// Only digits sitting between two letters are converted.
  String _fixOcrConfusables(String s) => s.replaceAllMapped(
        RegExp(r'(?<=[A-Za-zÑñ])[0-9](?=[A-Za-zÑñ])'),
        (m) => _digitToLetter[m[0]!] ?? m[0]!,
      );

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

  /// "JOSÉ" -> "JOSE". Ñ/ñ are kept (they are real letters in Filipino names).
  String _stripAccents(String s) => s.replaceAllMapped(
        RegExp('[áàâäãéèêëíìîïóòôöõúùûüÁÀÂÄÃÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜ]'),
        (m) => _accentMap[m[0]!] ?? m[0]!,
      );

  String _foldN(String s) => s.replaceAll('ñ', 'n').replaceAll('Ñ', 'N');

  /// Position-aware extraction: for every name label, takes the closest value
  /// line directly below it (same column) or to its right (same row).
  /// Returns null unless both last and given names are found.
  _IdName? _extractNameFromLayout(List<_OcrLine> lines) {
    if (lines.length < 4) return null;

    final used = <int>{};
    String? last, given, middle;

    for (int i = 0; i < lines.length; i++) {
      final kind = _labelKind(lines[i].text);
      if (kind == null) continue;

      String? value = _valueOnLabelLine(lines[i].text, kind);
      if (value == null) {
        final j = _nearestValueIndex(lines, i, used);
        if (j != null) {
          used.add(j);
          value = _cleanNameValue(lines[j].text);
        }
      }
      if (value == null) continue;

      if (kind == 'middle') {
        middle ??= value;
      } else if (kind == 'last') {
        last ??= value;
      } else {
        given ??= value;
      }
    }

    if (last != null && given != null) {
      return _IdName(first: given, middle: middle ?? '', last: last);
    }
    return null;
  }

  int? _nearestValueIndex(List<_OcrLine> lines, int labelIdx, Set<int> used) {
    final label = lines[labelIdx].box;
    final h = max(label.height, 1.0);
    int? best;
    double bestScore = double.infinity;

    double overlapX(Rect a, Rect b) => min(a.right, b.right) - max(a.left, b.left);

    for (int j = 0; j < lines.length; j++) {
      if (j == labelIdx || used.contains(j)) continue;
      if (_isLabelLine(lines[j].text)) continue;
      if (_cleanNameValue(lines[j].text) == null) continue;
      final box = lines[j].box;

      double? score;

      // (a) directly below the label, same column, no other label in between.
      final gapBelow = box.top - label.bottom;
      if (overlapX(box, label) > 0.3 * min(box.width, label.width) &&
          gapBelow >= -0.5 * h &&
          gapBelow <= 3 * h) {
        final blocked = lines.asMap().entries.any((e) {
          if (e.key == labelIdx || e.key == j) return false;
          if (!_isLabelLine(e.value.text)) return false;
          final o = e.value.box;
          return o.center.dy > label.center.dy &&
              o.center.dy < box.center.dy &&
              overlapX(o, label) > 0;
        });
        if (!blocked) score = gapBelow < 0 ? 0.0 : gapBelow;
      }

      // (b) to the right of the label on the same row.
      final gapRight = box.left - label.right;
      if ((box.center.dy - label.center.dy).abs() <= 0.6 * max(h, box.height) &&
          gapRight >= -0.3 * h &&
          gapRight <= 15 * h) {
        final rightScore = (gapRight < 0 ? 0.0 : gapRight) * 1.5;
        if (score == null || rightScore < score) score = rightScore;
      }

      if (score != null && score < bestScore) {
        bestScore = score;
        best = j;
      }
    }
    return best;
  }

  /// Fills the name fields from the ID. Returns false when no name was found,
  /// in which case the fields are left as typed.
  bool _autofillNameFromId(String text, [List<_OcrLine> lines = const []]) {
    _nameAutoFilled = false;
    if (!_looksLikeId(text)) return false;
    final name = _extractNameFromLayout(lines) ?? _extractNameFromId(text);
    if (name == null) return false;

    _lastNameController.text = _titleCase(name.last);
    _firstNameController.text = _titleCase(name.first);
    _miController.text =
        name.middle.isEmpty ? '' : name.middle[0].toUpperCase();
    _nameAutoFilled = true;
    return true;
  }

  void _verifyExtractedText(String ocrText) {
    final trimmed = ocrText.trim();

    if (trimmed.isEmpty || trimmed.length < 15) {
      setState(() {
        _isOcrScanning = false;
        _isIdRecognized = false;
        _isNameMatched = false;
        _ocrVerificationMessage = 'Picture is blurry or unreadable. Please capture closer in good lighting without glare.';
      });
      return;
    }

    final sanitizedOcr = _stripAccents(trimmed).replaceAll(RegExp(r'[^a-zA-Z0-9ñÑ\s]'), ' ').toLowerCase();
    // Searchable copy: digit/letter OCR confusions fixed and Ñ folded to N.
    final searchableOcr = _foldN('$sanitizedOcr ${_fixOcrConfusables(sanitizedOcr)}');
    bool has(String token) => searchableOcr.contains(_foldN(token));

    bool hasIdMarker = false;
    for (final marker in _validIdKeywords) {
      if (sanitizedOcr.contains(marker)) {
        hasIdMarker = true;
        break;
      }
    }

    if (!hasIdMarker) {
      setState(() {
        _isOcrScanning = false;
        _isIdRecognized = false;
        _isNameMatched = false;
        _ocrVerificationMessage = 'Unrecognized document: Card header or document title is not recognized as an accredited ID.';
      });
      return;
    }

    final rawFirst = _firstNameController.text.trim().toLowerCase();
    final rawLast = _lastNameController.text.trim().toLowerCase();
    final rawMi = _miController.text.trim().toLowerCase();

    if (rawFirst.isEmpty || rawLast.isEmpty) {
      setState(() {
        _isOcrScanning = false;
        _isIdRecognized = true;
        _isNameMatched = false;
        _ocrVerificationMessage = 'Please enter your First Name and Last Name above to cross-reference with this ID.';
      });
      return;
    }

    final firstTokens = rawFirst.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final lastTokens = rawLast.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

    final missingLast = lastTokens.where((token) => !has(token)).toList();
    final missingFirst = firstTokens.where((token) => !has(token)).toList();

    if (missingLast.isNotEmpty) {
      setState(() {
        _isOcrScanning = false;
        _isIdRecognized = true;
        _isNameMatched = false;
        _ocrVerificationMessage = 'Last Name Mismatch: "${_lastNameController.text}" was not detected on this card.';
      });
      return;
    }

    if (missingFirst.isNotEmpty) {
      setState(() {
        _isOcrScanning = false;
        _isIdRecognized = true;
        _isNameMatched = false;
        _ocrVerificationMessage = 'First Name Mismatch: "${_firstNameController.text}" was not detected on this card.';
      });
      return;
    }

    if (rawMi.isNotEmpty) {
      final miClean = _foldN(rawMi.replaceAll('.', '').trim());
      final words = searchableOcr.split(RegExp(r'\s+'));
      final miMatched = words.any((w) => w == miClean || (w.length > 1 && w.startsWith(miClean)));

      if (!miMatched) {
        setState(() {
          _isOcrScanning = false;
          _isIdRecognized = true;
          _isNameMatched = false;
          _ocrVerificationMessage = 'M.I. Mismatch: Initial "${_miController.text}" does not match the middle name on this card.';
        });
        return;
      }
    }

    HapticFeedback.lightImpact();
    setState(() {
      _isOcrScanning = false;
      _isIdRecognized = true;
      _isNameMatched = true;
      _ocrVerificationMessage =
          'ID Verified: Card matches ${_firstNameController.text.trim()} ${_lastNameController.text.trim()}.'
          '${_nameAutoFilled ? ' Name was filled in from your ID, please double-check it.' : ''}';
    });
  }

  // ===========================================================================
  // PHILIPPINES PHONE NORMALIZATION
  // ===========================================================================
  String? _formatPhilippinePhoneForPhilSms(String raw) {
    String clean = raw.replaceAll(RegExp(r'[^0-9]'), '').trim();
    if (clean.startsWith('09') && clean.length == 11) {
      return '63${clean.substring(1)}';
    } else if (clean.startsWith('9') && clean.length == 10) {
      return '63$clean';
    } else if (clean.startsWith('639') && clean.length == 12) {
      return clean;
    }
    return null;
  }

  // ===========================================================================
  // PHILIPPINES SMS API CALL VIA PHILSMS
  // ===========================================================================
  Future<bool> _sendPhilSmsOtpRequest({
    required String recipient,
    required String otpCode,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('https://dashboard.philsms.com/api/v3/sms/send'),
        headers: {
          'Authorization': 'Bearer $_philSmsToken',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'recipient': recipient,
          'sender_id': 'PhilSMS',
          'type': 'plain',
          'message': 'Your JeePeS incident report verification PIN is: $otpCode. Valid for 5 minutes.',
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return data['status'] == 'success' || data['code'] == '200' || response.statusCode == 200;
      } else {
        debugPrint('PhilSMS Error: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('Failed to reach PhilSMS API: $e');
      return false;
    }
  }

  // ===========================================================================
  // PHILSMS OTP VERIFICATION MODAL DIALOG
  // ===========================================================================
  Future<bool> _verifyPhoneWithPhilSms(String recipientNumber, double s) async {
    String generatedCode = (100000 + Random().nextInt(900000)).toString();
    final otpInputController = TextEditingController();
    int secondsRemaining = 60;
    Timer? countdownTimer;
    String errorText = '';
    bool isSendingSms = true;
    bool smsSentSuccess = false;

    if (!mounted) return false;

    final bool? verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (isSendingSms) {
            isSendingSms = false;
            _sendPhilSmsOtpRequest(recipient: recipientNumber, otpCode: generatedCode).then((success) {
              setDialogState(() {
                smsSentSuccess = success;
                if (!success) {
                  errorText = 'Failed to transmit SMS via carrier. (Ensure the recipient is a Globe/TM SIM)';
                }
              });

              countdownTimer ??= Timer.periodic(const Duration(seconds: 1), (timer) {
                if (secondsRemaining > 0) {
                  setDialogState(() => secondsRemaining--);
                } else {
                  timer.cancel();
                }
              });
            });
          }

          return Dialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16 * s)),
            insetPadding: EdgeInsets.symmetric(horizontal: 20 * s, vertical: 24 * s),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
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
                          child: Icon(Icons.mark_email_read_rounded, color: AppColors.commuterTeal, size: 22 * s),
                        ),
                        SizedBox(width: 12 * s),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('SMS Verification', style: TextStyle(fontSize: 16 * s, fontWeight: FontWeight.w800, color: AppColors.darkSlate)),
                              SizedBox(height: 2 * s),
                              Text('PhilSMS Carrier Delivery', style: TextStyle(fontSize: 11.5 * s, color: AppColors.textMuted)),
                            ],
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.close_rounded, size: 20 * s, color: AppColors.textMuted),
                          onPressed: () {
                            countdownTimer?.cancel();
                            Navigator.pop(dialogCtx, false);
                          },
                        ),
                      ],
                    ),
                    Divider(height: 20 * s, color: AppColors.borderSubtle),

                    Text(
                      'Enter the 6-digit code delivered via text message to +$recipientNumber:',
                      style: TextStyle(fontSize: 13 * s, height: 1.35, color: AppColors.darkSlate),
                    ),
                    SizedBox(height: 14 * s),

                    TextField(
                      controller: otpInputController,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      maxLength: 6,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: TextStyle(
                        fontSize: 24 * s,
                        letterSpacing: 8 * s,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w900,
                        color: AppColors.primaryNavy,
                      ),
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: '------',
                        filled: true,
                        fillColor: AppColors.backgroundSlate,
                        contentPadding: EdgeInsets.symmetric(vertical: 12 * s),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10 * s),
                          borderSide: const BorderSide(color: Color(0xFFCBD5E1), width: 1.3),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10 * s),
                          borderSide: const BorderSide(color: AppColors.commuterTeal, width: 2.0),
                        ),
                      ),
                      onChanged: (_) {
                        if (errorText.isNotEmpty) {
                          setDialogState(() => errorText = '');
                        }
                      },
                    ),

                    if (errorText.isNotEmpty) ...[
                      SizedBox(height: 8 * s),
                      Text(
                        errorText,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12 * s, fontWeight: FontWeight.bold, color: AppColors.errorCrimson),
                      ),
                    ],

                    SizedBox(height: 12 * s),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          secondsRemaining > 0 ? 'Resend in ${secondsRemaining}s' : 'Did not receive SMS?',
                          style: TextStyle(fontSize: 12 * s, color: AppColors.textMuted),
                        ),
                        TextButton(
                          onPressed: secondsRemaining == 0
                              ? () async {
                                  setDialogState(() {
                                    generatedCode = (100000 + Random().nextInt(900000)).toString();
                                    secondsRemaining = 60;
                                    errorText = '';
                                  });
                                  final resendOk = await _sendPhilSmsOtpRequest(
                                    recipient: recipientNumber,
                                    otpCode: generatedCode,
                                  );
                                  if (!resendOk) {
                                    setDialogState(() => errorText = 'Resend failed. Verify PhilSMS credits and mobile network.');
                                  }
                                }
                              : null,
                          child: Text(
                            'Resend Code',
                            style: TextStyle(
                              fontSize: 12 * s,
                              fontWeight: FontWeight.bold,
                              color: secondsRemaining == 0 ? AppColors.commuterTeal : AppColors.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),

                    SizedBox(height: 16 * s),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.commuterTeal,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10 * s)),
                        padding: EdgeInsets.symmetric(vertical: 13 * s),
                        elevation: 0,
                      ),
                      onPressed: () {
                        final input = otpInputController.text.trim();
                        if (input.length != 6) {
                          setDialogState(() => errorText = 'Please enter the 6-digit code.');
                          return;
                        }

                        if (input == generatedCode) {
                          countdownTimer?.cancel();
                          HapticFeedback.lightImpact();
                          Navigator.pop(dialogCtx, true);
                        } else {
                          HapticFeedback.mediumImpact();
                          setDialogState(() => errorText = 'Incorrect OTP code. Please check your SMS inbox.');
                        }
                      },
                      child: Text('Confirm & Submit', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5 * s)),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    countdownTimer?.cancel();
    return verified == true;
  }

  // ===========================================================================
  // COMPLAINT SUBMISSION
  // ===========================================================================
  Future<void> _submitComplaint() async {
    if (!_formKey.currentState!.validate()) return;

    if (_idImageBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please attach an ID photo for verification.'), backgroundColor: AppColors.errorCrimson),
      );
      return;
    }

    if (!_isNameMatched) {
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot submit: Entered name must match the name printed on the attached ID.'),
          backgroundColor: AppColors.errorCrimson,
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }

    final rawContact = _contactController.text.trim();
    final philSmsFormattedRecipient = _formatPhilippinePhoneForPhilSms(rawContact);

    if (philSmsFormattedRecipient == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid Philippine mobile number (e.g. 09123456789).'),
          backgroundColor: AppColors.errorCrimson,
        ),
      );
      return;
    }

    final s = _scale(context);
    final bool isPhoneVerified = await _verifyPhoneWithPhilSms(philSmsFormattedRecipient, s);

    if (!isPhoneVerified) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Submission cancelled: Mobile OTP verification is required.'),
          backgroundColor: AppColors.errorCrimson,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final String base64Image = base64Encode(_idImageBytes!);
      final lastName = _lastNameController.text.trim();
      final firstName = _firstNameController.text.trim();
      final mi = _miController.text.trim();
      final fullName = mi.isEmpty ? '$firstName $lastName' : '$firstName $mi. $lastName';

      await FirebaseFirestore.instance.collection('complaints').add({
        'first_name': firstName,
        'middle_initial': mi,
        'last_name': lastName,
        'complainant_name': fullName,
        'complainant_contact': rawContact,
        'phone_verified': true,
        'phone_verified_at': FieldValue.serverTimestamp(),
        'verification_id_base64': base64Image,
        'plate_number': _plateController.text.trim().toUpperCase(),
        'category': _selectedCategory,
        'description': _descriptionController.text.trim(),
        'route_id': widget.routeId,
        'terminal_name': widget.terminalName,
        'terminal_id': widget.terminalId,
        'destination': widget.destination,
        'status': 'PENDING_VERIFICATION',
        'is_verified_id': _isIdRecognized,
        'is_name_matched': _isNameMatched,
        'ocr_extracted_snippet': _scannedRawText != null && _scannedRawText!.length > 150
            ? _scannedRawText!.substring(0, 150)
            : _scannedRawText,
        'created_at': FieldValue.serverTimestamp(),
      });


      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Phone verified & complaint filed successfully.'), backgroundColor: Color(0xFF059669)),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Submission failed: $e'), backgroundColor: AppColors.errorCrimson),
      );
      setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _scale(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        elevation: 0.5,
        backgroundColor: AppColors.primaryNavy,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text('Incident Reporting', style: TextStyle(color: Colors.white, fontSize: 17 * s, fontWeight: FontWeight.bold)),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: 16.0 * s, vertical: 14.0 * s),
              child: Card(
                color: Colors.white,
                elevation: 1.5,
                shadowColor: Colors.black.withOpacity(0.08),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16 * s),
                  side: const BorderSide(color: Color(0xFFCBD5E1), width: 1.2),
                ),
                child: Padding(
                  padding: EdgeInsets.all(18.0 * s),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Report a PUJ Incident', style: TextStyle(fontSize: 18 * s, fontWeight: FontWeight.w900, color: AppColors.darkSlate)),
                        SizedBox(height: 3 * s),
                        Text(
                          'Provide authentic passenger and ID details so cooperatives can take immediate disciplinary action.',
                          style: TextStyle(fontSize: 12.5 * s, color: AppColors.darkSlate.withOpacity(0.75), height: 1.3),
                        ),
                        Divider(height: 24 * s, color: const Color(0xFFE2E8F0)),

                        _sectionTitle('1. Passenger Identification', Icons.person_rounded, s),
                        SizedBox(height: 12 * s),

                        TextFormField(
                          controller: _firstNameController,
                          textCapitalization: TextCapitalization.words,
                          style: TextStyle(fontSize: 14.5 * s, fontWeight: FontWeight.w600, color: AppColors.darkSlate),
                          decoration: _inputDeco('First Name *', 'e.g. Juan', Icons.badge_outlined, s),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'First name is required' : null,
                          onChanged: (_) {
                            if (_scannedRawText != null) _verifyExtractedText(_scannedRawText!);
                          },
                        ),
                        SizedBox(height: 12 * s),

                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: _miController,
                                maxLength: 2,
                                textCapitalization: TextCapitalization.characters,
                                style: TextStyle(fontSize: 14.5 * s, fontWeight: FontWeight.w600, color: AppColors.darkSlate),
                                decoration: _inputDeco('M.I.', 'C', Icons.badge_outlined, s).copyWith(
                                  counterText: '',
                                ),
                                onChanged: (_) {
                                  if (_scannedRawText != null) _verifyExtractedText(_scannedRawText!);
                                },
                              ),
                            ),
                            SizedBox(width: 10 * s),
                            Expanded(
                              flex: 7,
                              child: TextFormField(
                                controller: _lastNameController,
                                textCapitalization: TextCapitalization.words,
                                style: TextStyle(fontSize: 14.5 * s, fontWeight: FontWeight.w600, color: AppColors.darkSlate),
                                decoration: _inputDeco('Last Name *', 'e.g. Dela Cruz', Icons.badge_outlined, s),
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'Last name is required' : null,
                                onChanged: (_) {
                                  if (_scannedRawText != null) _verifyExtractedText(_scannedRawText!);
                                },
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 12 * s),

                        TextFormField(
                          controller: _contactController,
                          keyboardType: TextInputType.phone,
                          style: TextStyle(fontSize: 14.5 * s, fontWeight: FontWeight.w600, color: AppColors.darkSlate),
                          decoration: _inputDeco('Contact Number *', '0912 345 6789', Icons.phone_outlined, s),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'Contact number is required' : null,
                        ),
                        SizedBox(height: 14 * s),

                        _buildIdUploadWidget(s),
                        SizedBox(height: 20 * s),

                        _sectionTitle('2. Incident Details', Icons.directions_bus_rounded, s),
                        SizedBox(height: 12 * s),

                        _buildPlateAutocomplete(s),

                        if (_recentDispatchedPlates.isNotEmpty) ...[
                          SizedBox(height: 8 * s),
                          Row(
                            children: [
                              Icon(Icons.history_rounded, size: 15 * s, color: AppColors.commuterTeal),
                              SizedBox(width: 5 * s),
                              Text('Recent on trip: ', style: TextStyle(fontSize: 12 * s, fontWeight: FontWeight.w700, color: AppColors.textMuted)),
                              Expanded(
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children: _recentDispatchedPlates.map((plateNum) {
                                      final isSelected = _plateController.text.toUpperCase() == plateNum;
                                      return Padding(
                                        padding: EdgeInsets.only(right: 6 * s),
                                        child: InkWell(
                                          onTap: () => setState(() => _plateController.text = plateNum),
                                          borderRadius: BorderRadius.circular(6 * s),
                                          child: Container(
                                            padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 4 * s),
                                            decoration: BoxDecoration(
                                              color: isSelected ? AppColors.commuterTeal.withOpacity(0.18) : const Color(0xFFEFF6FF),
                                              border: Border.all(color: isSelected ? AppColors.commuterTeal : const Color(0xFFBFDBFE), width: 1.1),
                                              borderRadius: BorderRadius.circular(6 * s),
                                            ),
                                            child: Text(
                                              plateNum,
                                              style: TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 12 * s,
                                                fontWeight: FontWeight.bold,
                                                color: isSelected ? AppColors.commuterTeal : const Color(0xFF1D4ED8),
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],

                        SizedBox(height: 12 * s),
                        DropdownButtonFormField<String>(
                          initialValue: _selectedCategory,
                          isExpanded: true,
                          style: TextStyle(fontSize: 14 * s, fontWeight: FontWeight.w600, color: AppColors.darkSlate),
                          decoration: _inputDeco('Violation Category *', '', Icons.category_outlined, s),
                          items: _categories
                              .map((c) => DropdownMenuItem(value: c, child: Text(c, style: TextStyle(fontSize: 13.5 * s))))
                              .toList(),
                          onChanged: (v) => setState(() => _selectedCategory = v!),
                        ),
                        SizedBox(height: 14 * s),

                        TextFormField(
                          controller: _descriptionController,
                          maxLines: 4,
                          style: TextStyle(fontSize: 13.5 * s, height: 1.35, color: AppColors.darkSlate, fontWeight: FontWeight.w500),
                          decoration: _inputDeco(
                            'Incident Description *',
                            'Describe what occurred (location, time, speed, or driver action)...',
                            Icons.notes_rounded,
                            s,
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'Description is required' : null,
                        ),
                        SizedBox(height: 20 * s),

                        SizedBox(
                          height: 50 * s,
                          child: ElevatedButton(
                            onPressed: _isSubmitting ? null : _submitComplaint,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.commuterTeal,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10 * s)),
                              elevation: 0,
                            ),
                            child: _isSubmitting
                                ? SizedBox(height: 20 * s, width: 20 * s, child: const CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                : Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.send_rounded, size: 18 * s),
                                      SizedBox(width: 8 * s),
                                      Text('Submit Verified Report', style: TextStyle(fontSize: 15.5 * s, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ───────────── Plate number autocomplete

  String _normPlate(String v) => v.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// Plates that start with what was typed come first, then plates that merely
  /// contain it. Dashes/spaces are ignored, so "fas1" still finds "FAS-1234".
  List<String> _plateSuggestions(String input) {
    final q = _normPlate(input);

    if (q.isEmpty) {
      final recent = _recentDispatchedPlates.toSet();
      return [
        ..._recentDispatchedPlates,
        ..._routePlates.where((p) => !recent.contains(p)),
      ];
    }

    final all = <String>{..._routePlates, ..._recentDispatchedPlates};
    final starts = <String>[];
    final contains = <String>[];
    for (final p in all) {
      final n = _normPlate(p);
      if (n.startsWith(q)) {
        starts.add(p);
      } else if (n.contains(q)) {
        contains.add(p);
      }
    }
    starts.sort();
    contains.sort();
    final result = [...starts, ...contains];

    // Nothing left to guess once the exact plate is typed.
    if (result.length == 1 && _normPlate(result.first) == q) return [];
    return result;
  }

  Widget _buildPlateAutocomplete(double s) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final fieldWidth = constraints.maxWidth;

        return RawAutocomplete<String>(
          textEditingController: _plateController,
          focusNode: _plateFocusNode,
          optionsBuilder: (value) => _plateSuggestions(value.text),
          onSelected: (_) {
            setState(() {});
            FocusScope.of(context).unfocus();
          },
          fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
            return ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                return TextFormField(
                  controller: controller,
                  focusNode: focusNode,
                  textCapitalization: TextCapitalization.characters,
                  // Leaves room above the keyboard so the suggestion list is visible.
                  scrollPadding: EdgeInsets.only(bottom: 320 * s),
                  style: TextStyle(fontSize: 15 * s, fontFamily: 'monospace', fontWeight: FontWeight.w800, color: AppColors.darkSlate),
                  decoration: _inputDeco(
                    'Jeepney Plate Number *',
                    _routePlates.isNotEmpty ? 'Type to search plate, e.g. W' : 'e.g. FAS-1234',
                    Icons.pin_outlined,
                    s,
                    suffix: value.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.close_rounded, color: AppColors.textMuted, size: 20 * s),
                            onPressed: () {
                              controller.clear();
                              setState(() {});
                              focusNode.requestFocus();
                            },
                          )
                        : (_routePlates.isNotEmpty
                            ? IconButton(
                                icon: Icon(Icons.arrow_drop_down_circle_outlined, color: AppColors.commuterTeal, size: 22 * s),
                                onPressed: () => focusNode.requestFocus(),
                              )
                            : null),
                  ),
                  onChanged: (_) => setState(() {}),
                  onFieldSubmitted: (_) => onFieldSubmitted(),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Plate number is required' : null,
                );
              },
            );
          },
          optionsViewBuilder: (context, onSelected, options) {
            final list = options.toList();
            final query = _plateController.text;

            return Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: EdgeInsets.only(top: 4 * s),
                child: Material(
                  elevation: 6,
                  color: Colors.white,
                  shadowColor: AppColors.primaryNavy.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(12 * s),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: fieldWidth, maxHeight: 250 * s),
                    child: SizedBox(
                      width: fieldWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            color: const Color(0xFFF0FDFA),
                            padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 7 * s),
                            child: Text(
                              query.trim().isEmpty
                                  ? '${list.length} jeepney${list.length == 1 ? '' : 's'} available'
                                  : '${list.length} matching jeepney${list.length == 1 ? '' : 's'}',
                              style: TextStyle(fontSize: 11.5 * s, fontWeight: FontWeight.w800, color: const Color(0xFF0F766E)),
                            ),
                          ),
                          Flexible(
                            child: ListView.separated(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: list.length,
                              separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFF1F5F9)),
                              itemBuilder: (context, index) {
                                final plate = list[index];
                                final isHighlighted = AutocompleteHighlightedOption.of(context) == index;
                                final isRecent = _recentDispatchedPlates.contains(plate);

                                return InkWell(
                                  onTap: () => onSelected(plate),
                                  child: Container(
                                    color: isHighlighted ? AppColors.commuterTeal.withOpacity(0.08) : null,
                                    padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 9 * s),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 32 * s,
                                          height: 32 * s,
                                          decoration: BoxDecoration(
                                            color: AppColors.commuterTeal.withOpacity(0.12),
                                            borderRadius: BorderRadius.circular(9 * s),
                                          ),
                                          child: Icon(Icons.directions_bus_rounded, size: 18 * s, color: AppColors.commuterTeal),
                                        ),
                                        SizedBox(width: 10 * s),
                                        Expanded(child: _plateOptionText(plate, query, s)),
                                        if (isRecent) ...[
                                          SizedBox(width: 6 * s),
                                          Icon(Icons.history_rounded, size: 16 * s, color: AppColors.textMuted),
                                        ],
                                      ],
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
      },
    );
  }

  /// Plate text with the part the user typed highlighted.
  Widget _plateOptionText(String plate, String query, double s) {
    final base = TextStyle(
      fontFamily: 'monospace',
      fontSize: 14.5 * s,
      fontWeight: FontWeight.w700,
      color: AppColors.darkSlate,
    );
    final q = query.trim().toUpperCase();
    final i = q.isEmpty ? -1 : plate.toUpperCase().indexOf(q);
    if (i < 0) return Text(plate, style: base);

    return RichText(
      text: TextSpan(
        style: base,
        children: [
          TextSpan(text: plate.substring(0, i)),
          TextSpan(
            text: plate.substring(i, i + q.length),
            style: base.copyWith(
              fontWeight: FontWeight.w900,
              color: const Color(0xFF0F766E),
              backgroundColor: AppColors.commuterTeal.withOpacity(0.15),
            ),
          ),
          TextSpan(text: plate.substring(i + q.length)),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, IconData icon, double s) {
    return Row(
      children: [
        Container(
          padding: EdgeInsets.all(6 * s),
          decoration: BoxDecoration(
            color: AppColors.commuterTeal.withOpacity(0.12),
            borderRadius: BorderRadius.circular(6 * s),
          ),
          child: Icon(icon, size: 17 * s, color: AppColors.commuterTeal),
        ),
        SizedBox(width: 8 * s),
        Text(title, style: TextStyle(fontSize: 15 * s, fontWeight: FontWeight.w800, color: AppColors.darkSlate)),
      ],
    );
  }

  Widget _buildIdUploadWidget(double s) {
    final hasImage = _idImageBytes != null;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        border: Border.all(
          color: _isNameMatched
              ? const Color(0xFF10B981)
              : (hasImage ? const Color(0xFFF59E0B) : const Color(0xFFCBD5E1)),
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(10 * s),
      ),
      padding: EdgeInsets.all(12 * s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Valid ID Verification *', style: TextStyle(fontSize: 13.5 * s, fontWeight: FontWeight.w800, color: AppColors.darkSlate)),
                    SizedBox(height: 2 * s),
                    Text(
                      _idImageFileName ?? 'Government, School, or Student ID',
                      style: TextStyle(fontSize: 11.5 * s, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _isOcrScanning
                    ? null
                    : () {
                        AppTypography.lightFeedback();
                        _showImageSourcePicker(s);
                      },
                icon: Icon(hasImage ? Icons.refresh : Icons.camera_alt_outlined, size: 16 * s),
                label: Text(hasImage ? 'Re-scan' : 'Scan ID', style: TextStyle(fontSize: 12 * s, fontWeight: FontWeight.bold)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.commuterTeal,
                  side: const BorderSide(color: AppColors.commuterTeal, width: 1.3),
                  padding: EdgeInsets.symmetric(horizontal: 11 * s, vertical: 7 * s),
                  minimumSize: Size.zero,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8 * s)),
                ),
              ),
            ],
          ),

          if (_isOcrScanning) ...[
            SizedBox(height: 10 * s),
            Row(
              children: [
                SizedBox(width: 15 * s, height: 15 * s, child: const CircularProgressIndicator(strokeWidth: 2, color: AppColors.commuterTeal)),
                SizedBox(width: 8 * s),
                Text('Verifying card credentials with OCR...', style: TextStyle(fontSize: 12 * s, color: AppColors.textMuted, fontWeight: FontWeight.w600)),
              ],
            ),
          ],

          if (hasImage && !_isOcrScanning) ...[
            SizedBox(height: 10 * s),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 8 * s),
              decoration: BoxDecoration(
                color: _isNameMatched ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(8 * s),
                border: Border.all(color: _isNameMatched ? const Color(0xFFA7F3D0) : const Color(0xFFFECACA), width: 1.1),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1.0),
                    child: Icon(
                      _isNameMatched ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                      color: _isNameMatched ? const Color(0xFF059669) : const Color(0xFFDC2626),
                      size: 18 * s,
                    ),
                  ),
                  SizedBox(width: 8 * s),
                  Expanded(
                    child: Text(
                      _ocrVerificationMessage.isNotEmpty
                          ? _ocrVerificationMessage
                          : 'Not a valid ID: Please upload a clear photo of an official ID.',
                      style: TextStyle(
                        fontSize: 12 * s,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                        color: _isNameMatched ? const Color(0xFF065F46) : const Color(0xFF991B1B),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 10 * s),
            ClipRRect(
              borderRadius: BorderRadius.circular(8 * s),
              child: Image.memory(_idImageBytes!, height: 140 * s, width: double.infinity, fit: BoxFit.cover),
            ),
          ],
        ],
      ),
    );
  }

  InputDecoration _inputDeco(String label, String hint, IconData? icon, double s, {Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: icon != null ? Icon(icon, color: AppColors.primaryNavy.withOpacity(0.85), size: 19 * s) : null,
      suffixIcon: suffix,
      labelStyle: TextStyle(color: const Color(0xFF334155), fontSize: 13.5 * s, fontWeight: FontWeight.w700),
      floatingLabelStyle: TextStyle(color: AppColors.commuterTeal, fontSize: 13.5 * s, fontWeight: FontWeight.w800),
      hintStyle: TextStyle(color: const Color(0xFF94A3B8), fontSize: 12.5 * s),
      filled: true,
      fillColor: Colors.white,
      contentPadding: EdgeInsets.symmetric(horizontal: 14 * s, vertical: 13 * s),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10 * s),
        borderSide: const BorderSide(color: Color(0xFF94A3B8), width: 1.4),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10 * s),
        borderSide: const BorderSide(color: AppColors.commuterTeal, width: 2.0),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10 * s),
        borderSide: const BorderSide(color: AppColors.errorCrimson, width: 1.4),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10 * s),
        borderSide: const BorderSide(color: AppColors.errorCrimson, width: 2.0),
      ),
    );
  }
}

class _OcrLine {
  final String text;
  final Rect box;
  const _OcrLine(this.text, this.box);
}

class _OcrResult {
  final String text;
  final List<_OcrLine> lines;
  const _OcrResult(this.text, this.lines);
}

class _IdName {
  final String first;
  final String middle;
  final String last;
  const _IdName({required this.first, required this.middle, required this.last});
}