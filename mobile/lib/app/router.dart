// Navigation (PRD §19.1).
//
// One route per screen named in PRD §19.1's navigation table, so a screen
// missing from the build is visible as a missing route rather than as a dead
// button.
//
// Auth gating is a `redirect`, not a per-screen check. That matters: a
// per-screen check is something a new screen can forget, and the thing being
// forgotten is patient-data access (PRD §25.1).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/login_screen.dart';
import '../features/history/history_screen.dart';
import '../features/home/home_screen.dart';
import '../features/imaging/imaging_screen.dart';
import '../features/joint/joint_assessment_screen.dart';
import '../features/joint/womac_screen.dart';
import '../features/patient/patient_detail_screen.dart';
import '../features/patient/patient_registration_screen.dart';
import '../features/questionnaire/questionnaire_screen.dart';
import '../features/report/report_screen.dart';
import '../features/result/result_screen.dart';
import '../features/risk/body_risk_map_screen.dart';
import '../features/screening/camera_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/wearable/wearable_screen.dart';
import 'providers.dart';

/// Route paths, so no screen builds a path from a string literal.
class Routes {
  const Routes._();

  static const String login = '/login';
  static const String home = '/home';
  static const String patientNew = '/patient/new';
  static const String patientDetail = '/patient/:id';
  static const String questionnaire = '/questionnaire';
  static const String camera = '/screen';
  static const String riskMap = '/risk-map';
  static const String joint = '/joint';
  static const String womac = '/womac';
  static const String wearable = '/wearable';
  static const String imaging = '/imaging';
  static const String result = '/result';
  static const String report = '/report';
  static const String history = '/history';
  static const String settings = '/settings';

  static String patientDetailFor(String id) => '/patient/$id';
}

final routerProvider = Provider<GoRouter>((ref) {
  // go_router needs a Listenable to re-evaluate `redirect`. Riverpod has no
  // Listenable of its own, so a counter is bumped whenever the signed-in worker
  // changes.
  final authListenable = ValueNotifier<int>(0);
  ref.listen(authProvider, (_, _) => authListenable.value++);
  ref.onDispose(authListenable.dispose);

  final router = GoRouter(
    initialLocation: Routes.login,
    refreshListenable: authListenable,
    redirect: (context, state) {
      final worker = ref.read(authProvider);
      final atLogin = state.matchedLocation == Routes.login;

      if (worker == null) return atLogin ? null : Routes.login;
      return atLogin ? Routes.home : null;
    },
    routes: [
      GoRoute(
        path: Routes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: Routes.home,
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: Routes.patientNew,
        builder: (context, state) => const PatientRegistrationScreen(),
      ),
      GoRoute(
        path: Routes.patientDetail,
        builder: (context, state) => PatientDetailScreen(
          arogyaPatientId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: Routes.questionnaire,
        builder: (context, state) => const QuestionnaireScreen(),
      ),
      GoRoute(
        path: Routes.camera,
        builder: (context, state) => const CameraScreen(),
      ),
      GoRoute(
        path: Routes.riskMap,
        builder: (context, state) => const BodyRiskMapScreen(),
      ),
      GoRoute(
        path: Routes.joint,
        builder: (context, state) => const JointAssessmentScreen(),
      ),
      GoRoute(
        path: Routes.womac,
        builder: (context, state) => const WomacScreen(),
      ),
      GoRoute(
        path: Routes.wearable,
        builder: (context, state) => const WearableScreen(),
      ),
      GoRoute(
        path: Routes.imaging,
        builder: (context, state) => const ImagingScreen(),
      ),
      GoRoute(
        path: Routes.result,
        builder: (context, state) => const ResultScreen(),
      ),
      GoRoute(
        path: Routes.report,
        builder: (context, state) => const ReportScreen(),
      ),
      GoRoute(
        path: Routes.history,
        builder: (context, state) => const HistoryScreen(),
      ),
      GoRoute(
        path: Routes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
    errorBuilder: (context, state) => _RouteErrorScreen(
      location: state.uri.toString(),
      message: state.error?.toString(),
    ),
  );

  ref.onDispose(router.dispose);
  return router;
});

class _RouteErrorScreen extends StatelessWidget {
  const _RouteErrorScreen({required this.location, this.message});

  final String location;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Screen not found')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('No route matches "$location".'),
            if (message != null) ...[
              const SizedBox(height: 12),
              Text(message!),
            ],
          ],
        ),
      ),
    );
  }
}
