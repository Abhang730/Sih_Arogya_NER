// Stage 1 — whole-body joint risk localisation (PRD §9.5, §10.4, §11).
//
// PRD §6.2 is precise about what this stage means: it produces "a map of
// potential movement-related risk markers ... a triage mechanism for selecting
// what to assess next, not a whole-body OA diagnosis". So the output is a map of
// candidates, not a verdict.
//
// The honesty problem this file has to solve: there is no public dataset that
// pairs whole-body pose with joint-level OA labels (PRD §33, "No NER-specific
// labelled dataset"). A joint with no trained model therefore reports
// `insufficientData` and NO score. It does not report 0.0, and it does not fall
// back to a heuristic wearing a model's clothes.
//
// One thing is always available and always honest: the patient's own reported
// pain map from the Stage-1 questionnaire. That is a SYMPTOM REPORT, not a model
// output, and it is returned as a separate field so the two can never be
// confused on screen or in a report (PRD §8.2 "Treat pain location as one
// evidence stream").

import '../domain/protocol/models.dart';
import '../domain/protocol/registry.dart';
import 'branch.dart';
import 'tflite_branch.dart';

/// Why a joint has no model-derived marker.
enum RiskMarkerStatus {
  /// A trained model produced this marker.
  scored,

  /// No trained model exists. This is the honest default, not a failure.
  insufficientData,

  /// A model exists but this capture could not feed it.
  captureUnavailable;

  String get wire => switch (this) {
        RiskMarkerStatus.scored => 'scored',
        RiskMarkerStatus.insufficientData => 'insufficient_data',
        RiskMarkerStatus.captureUnavailable => 'capture_unavailable',
      };

  String get explanation => switch (this) {
        RiskMarkerStatus.scored => '',
        RiskMarkerStatus.insufficientData =>
          'No validated model is available for this joint. It was not scored.',
        RiskMarkerStatus.captureUnavailable =>
          'This capture could not produce the data this joint needs.',
      };

  /// Whether the joint may be offered as a machine-suggested follow-up.
  bool get canSuggestFollowUp => this == RiskMarkerStatus.scored;
}

/// A reported symptom, kept separate from any model output.
class ReportedSymptom {
  const ReportedSymptom({
    required this.region,
    required this.sides,
    required this.painScore,
  });

  final String region;
  final List<String> sides;

  /// 0-10 current pain scale for this region, when recorded (PRD §8.6).
  final double? painScore;

  Map<String, dynamic> toJson() => {
        'region': region,
        'sides': sides,
        'pain_score': painScore,
        'source': 'patient_reported',
      };
}

/// One joint's position on the Stage-1 body map.
class JointRiskMarker {
  const JointRiskMarker({
    required this.jointId,
    required this.side,
    required this.status,
    required this.score,
    required this.confidence,
    required this.modelId,
    required this.modelVersion,
    required this.caveats,
  });

  final String jointId;
  final String side;

  final RiskMarkerStatus status;

  /// Null unless [status] is scored.
  final double? score;
  final double confidence;

  final String? modelId;
  final String? modelVersion;
  final List<String> caveats;

  bool get isScored => status == RiskMarkerStatus.scored && score != null;

  /// The map key used by the UI, e.g. 'knee.right'.
  String get key => '$jointId.$side';

  /// Screening priority for ranking the follow-up list. Unscored joints sort
  /// last rather than being ranked at zero, which would put an unassessed joint
  /// below a genuinely low-risk one.
  double get rankingPriority => score ?? -1;

  Map<String, dynamic> toJson() => {
        'joint_id': jointId,
        'side': side,
        'status': status.wire,
        'score': score,
        'confidence': confidence,
        'model_id': modelId,
        'model_version': modelVersion,
        'caveats': caveats,
      };
}

/// The Stage-1 result: a triage map, plus the symptom evidence kept separate.
class JointRiskMap {
  const JointRiskMap({
    required this.markers,
    required this.reportedSymptoms,
    required this.notes,
    required this.followUpThreshold,
  });

  final List<JointRiskMarker> markers;
  final List<ReportedSymptom> reportedSymptoms;
  final List<String> notes;

  /// Threshold above which a scored joint is suggested for targeted assessment
  /// (PRD §11.2).
  final double followUpThreshold;

  /// Joints a model scored above the follow-up threshold, highest first.
  List<JointRiskMarker> get suggestedFollowUps => markers
      .where((m) => m.isScored && m.score! >= followUpThreshold)
      .toList()
    ..sort((a, b) => b.rankingPriority.compareTo(a.rankingPriority));

  /// Joints with no model, so the UI can state the coverage gap explicitly
  /// rather than rendering a blank. Blank space reads as "fine"; this does not.
  List<JointRiskMarker> get unscoredJoints =>
      markers.where((m) => !m.isScored).toList(growable: false);

  bool get hasAnyScoredMarker => markers.any((m) => m.isScored);

  Map<String, dynamic> toJson() => {
        'markers': markers.map((m) => m.toJson()).toList(growable: false),
        'reported_symptoms': reportedSymptoms.map((s) => s.toJson()).toList(growable: false),
        'suggested_follow_ups': suggestedFollowUps.map((m) => m.key).toList(growable: false),
        'follow_up_threshold': followUpThreshold,
        'notes': notes,
      };
}

/// Builds the Stage-1 body risk map.
class Stage1Localizer {
  Stage1Localizer({
    required this.registry,
    required this.manifest,
    required this.branchInput,
    this.followUpThreshold,
  });

  final ProtocolRegistry registry;
  final ModelManifest manifest;
  final BranchInput branchInput;

  /// Defaults to the knee protocol's moderate band floor, so Stage 1 and Stage 2
  /// agree on what "worth a closer look" means instead of each having its own
  /// invented cut-off.
  final double? followUpThreshold;

  double get _threshold =>
      followUpThreshold ?? registry.protocolFor('knee').riskLogic.bands[1].minScore;

  /// Runs every joint that has a usable Stage-1 model and reports the rest as
  /// insufficient data.
  Future<JointRiskMap> localize({
    Map<String, List<String>> reportedPain = const {},
    Map<String, double> reportedPainScores = const {},
  }) async {
    final markers = <JointRiskMarker>[];
    final notes = <String>[];

    for (final jointId in registry.jointOrder) {
      final protocol = registry.protocolFor(jointId);
      final model = protocol.modelFor(ModelBranch.stage1Localisation);

      for (final side in ['right', 'left']) {
        if (model == null) {
          markers.add(JointRiskMarker(
            jointId: jointId,
            side: side,
            status: RiskMarkerStatus.insufficientData,
            score: null,
            confidence: 0,
            modelId: null,
            modelVersion: null,
            caveats: const [],
          ));
          continue;
        }

        final branch = TfliteBranch(spec: model, manifest: manifest);
        final result = await branch.score(branchInput);

        if (result.isAvailable && result.score != null) {
          markers.add(JointRiskMarker(
            jointId: jointId,
            side: side,
            status: RiskMarkerStatus.scored,
            score: result.score,
            confidence: result.confidence,
            modelId: result.modelId,
            modelVersion: result.modelVersion,
            caveats: [
              ...result.limitations,
              if (result.placementNote != null) result.placementNote!,
            ],
          ));
        } else {
          final reason = result.reason;
          markers.add(JointRiskMarker(
            jointId: jointId,
            side: side,
            status: reason == BranchUnavailableReason.untrained
                ? RiskMarkerStatus.insufficientData
                : RiskMarkerStatus.captureUnavailable,
            score: null,
            confidence: 0,
            modelId: result.modelId,
            modelVersion: result.modelVersion,
            caveats: [reason?.explanation ?? 'Unavailable.'],
          ));
        }
      }
    }

    final unscored = markers.where((m) => !m.isScored).length;
    if (unscored > 0) {
      notes.add(
        '$unscored of ${markers.length} joint markers could not be scored because '
        'no validated model exists for them. They are shown as not assessed, not '
        'as low risk.',
      );
    }
    notes.add(
      'Stage 1 identifies where further assessment may be warranted. It does not '
      'indicate the presence or absence of osteoarthritis.',
    );

    return JointRiskMap(
      markers: markers,
      reportedSymptoms: _symptoms(reportedPain, reportedPainScores),
      notes: notes,
      followUpThreshold: _threshold,
    );
  }

  List<ReportedSymptom> _symptoms(
    Map<String, List<String>> pain,
    Map<String, double> scores,
  ) =>
      pain.entries
          .map((entry) => ReportedSymptom(
                region: entry.key,
                sides: entry.value,
                painScore: scores[entry.key],
              ))
          .toList(growable: false);
}
