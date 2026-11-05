import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'views/auth/login_screen.dart';
import 'utils/app_colors.dart';
import 'utils/seed_fcfs_queues.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const StaffPortalApp());
}

class StaffPortalApp extends StatelessWidget {
  const StaffPortalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JeePeS Operations Portal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.backgroundSlate,
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primaryNavy),
      ),
      home: const LoginScreen(),
    );
  }
}