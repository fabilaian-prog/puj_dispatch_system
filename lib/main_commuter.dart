import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'views/commuter/commuter_home_screen.dart';
import 'utils/app_colors.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const CommuterPortalApp());
}

class CommuterPortalApp extends StatelessWidget {
  const CommuterPortalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Antique PUJ Transit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.backgroundSlate,
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primaryNavy),
      ),
      home: const CommuterHomeScreen(),
    );
  }
}