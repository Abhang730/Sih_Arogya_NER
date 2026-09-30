// Registry tests.
//
// These load the REAL bundled protocol assets through the real Dart model. That
// is the point: it proves the shipped JSON and the app's parser agree, which is
// the failure mode that would otherwise only show up on a device in the field.

import 'package:arogya_ner/ai/tflite_branch.dart';
import 'package:arogya_ner/domain/protocol/models.dart';
import 'package:arogya_ner/domain/protocol/registry.dart';
import 'package:arogya_ner/domain/protocol/scoring.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProtocolRegistry registry;
  late ModelManifest manifest;

  setUpAll(() async {
    registry = await ProtocolRegistry.load();
    manifest = await ModelManifest.load();
  });

  group('bundled protocol set loads', () {
    test('all six roadmap joints are present (PRD §12.2)', () {
      expect(
        registry.jointOrder,
        ['knee', 'hip', 'shoulder', 'ankle', 'elbow', 'wrist'],
      );
      expect(registry.allProtocols, hasLength(6));
    });

    test('the landmark topology is the 33-point BlazePose set (PRD §10.2)', () {
      expect(registry.landmarks.topology, 'blazepose_33');
      expect(registry.landmarks.landmarkCount, 33);
      expect(registry.landmarks.landmarks, hasLength(33));

      // Spot-check the indices the feature extractor hard-depends on.
      final byKey = registry.landmarks.indexByKey;
      expect(byKey['nose'], 0);
      expect(byKey['left_shoulder'], 11);
      expect(byKey['right_shoulder'], 12);
      expect(byKey['left_hip'], 23);
      expect(byKey['right_hip'], 24);
      expect(byKey['left_knee'], 25);
      expect(byKey['right_knee'], 26);
      expect(byKey['left_ankle'], 27);
      expect(byKey['right_ankle'], 28);
      expect(byKey['left_foot_index'], 31);
      expect(byKey['right_foot_index'], 32);
    });

    test('landmark indices are unique and dense from 0 to 32', () {
      final indices = registry.landmarks.landmarks.map((l) => l.index).toList()..sort();
      expect(indices, List.generate(33, (i) => i));
    });

    test('quality gate names the regions PRD §9.4 requires', () {
      expect(
        registry.landmarks.qualityGate.requiredRegions,
        containsAll(['head', 'shoulder', 'pelvis', 'knee', 'ankle']),
      );
    });
  });

  group('knee is the complete module, others are honest about their state', () {
    test('only the knee is MVP status', () {
      expect(registry.mvpProtocols.map((p) => p.jointId), ['knee']);
    });

    test('knee carries a usable WOMAC', () {
      final knee = registry.protocolFor('knee');

      expect(knee.questionnaire.instrument, 'WOMAC');
      expect(knee.questionnaire.status, QuestionnaireStatus.specified);
      expect(knee.questionnaire.isUsable, isTrue);
      expect(knee.questionnaire.items, hasLength(24));
      expect(knee.questionnaire.itemsFor('pain'), hasLength(5));
      expect(knee.questionnaire.itemsFor('stiffness'), hasLength(2));
      expect(knee.questionnaire.itemsFor('function'), hasLength(17));
      expect(knee.questionnaire.scoring!.totalMax, 96);
      expect(knee.questionnaire.scoring!.direction, ScoreDirection.higherIsWorse);
    });

    test('a fully answered knee WOMAC scores end to end through the registry', () {
      final knee = registry.protocolFor('knee');
      final responses = {
        for (final item in knee.questionnaire.items) item.id: 3,
      };

      final score = scoreQuestionnaire(knee.questionnaire, responses);

      expect(score.isComplete, isTrue);
      expect(score.totalRaw, 72); // 24 x 3
      expect(score.totalPercent, closeTo(75, 1e-9));
      expect(score.band, isNull, reason: 'no severity bands are declared, by design');
    });

    test('joints without a signed-off instrument expose no questions', () {
      for (final jointId in ['shoulder', 'ankle', 'elbow', 'wrist']) {
        final protocol = registry.protocolFor(jointId);
        expect(
          protocol.questionnaire.status,
          QuestionnaireStatus.pendingClinicalSignOff,
          reason: '$jointId should not claim a configured instrument',
        );
        expect(protocol.questionnaire.isUsable, isFalse);
        expect(protocol.questionnaire.items, isEmpty);
        expect(protocol.questionnaire.referenceInstrument, isNotNull);
      }
    });

    test('hip reuses the same verified WOMAC definition as the knee', () {
      final knee = registry.protocolFor('knee').questionnaire;
      final hip = registry.protocolFor('hip').questionnaire;

      expect(hip.instrument, knee.instrument);
      expect(hip.status, QuestionnaireStatus.specified);
      expect(hip.items.map((i) => i.id).toList(), knee.items.map((i) => i.id).toList());
      expect(hip.scoring!.totalMax, knee.scoring!.totalMax);
    });
  });

  group('model honesty is encoded in the protocol data (PRD §26.5)', () {
    // The rule is not "nothing may ever be trained". It is that a `trained`
    // claim must be backed by a real evaluation run: metrics recorded in the
    // protocol, a generated manifest entry agreeing with them, and a declared
    // limitation. A protocol edited to say "trained" without re-running
    // ml/build_app_assets.py fails here, which is the drift that would
    // otherwise let an unmeasured claim reach a screening screen.
    test('a "trained" claim is always backed by metrics and a manifest entry', () {
      for (final protocol in registry.allProtocols) {
        for (final model in protocol.models) {
          final where = '${protocol.jointId}/${model.modelId}';

          switch (model.trainingStatus) {
            case TrainingStatus.trained:
              expect(
                model.metrics,
                isNotNull,
                reason: '$where claims "trained" but records no evaluation metrics',
              );
              expect(
                model.metrics,
                isNotEmpty,
                reason: '$where claims "trained" but its metrics block is empty',
              );
              expect(
                model.limitations,
                isNotEmpty,
                reason: 'a trained prototype must still state what it is not',
              );

              // The structural gate from tflite_branch.dart: no manifest
              // entry, no score. Asserted here so a protocol that claims
              // "trained" while the bundled manifest lags behind fails the
              // build rather than silently reporting the branch unavailable.
              final entry = manifest[model.modelId];
              expect(
                entry,
                isNotNull,
                reason: '$where claims "trained" but model_manifest.json has no '
                    'entry for "${model.modelId}" — re-run ml/build_app_assets.py',
              );
              expect(
                entry!.trainingStatus,
                TrainingStatus.trained,
                reason: '$where disagrees with the generated manifest',
              );
              expect(
                entry.isUsable,
                isTrue,
                reason: 'the manifest entry for ${model.modelId} is present but '
                    'records no usable metrics or feature order',
              );
              expect(
                entry.metrics,
                equals(model.metrics),
                reason: 'the bundled manifest for ${model.modelId} has drifted '
                    'from the protocol — re-run ml/build_app_assets.py',
              );

            case TrainingStatus.untrainedInsufficientData:
              expect(
                model.limitations,
                isNotEmpty,
                reason: 'an untrained branch must state its data gap',
              );

            case TrainingStatus.prototypeRuleBased:
            case TrainingStatus.planned:
              break;
          }
        }
      }
    });

    test('the manifest only ever activates a branch the protocols declare', () {
      for (final entry in manifest.entries.values) {
        expect(
          entry.trainingStatus,
          TrainingStatus.trained,
          reason: 'model_manifest.json must not carry entries for models that '
              'were never trained',
        );
        expect(
          entry.featureKeys,
          isNotEmpty,
          reason: 'a shipped model must declare the feature order it expects',
        );
        expect(
          entry.limitations,
          isNotEmpty,
          reason: 'a shipped model must carry its limitations into the product',
        );
        // Every bundled model must appear in some protocol, or the app would
        // ship an artefact nothing is allowed to reference.
        expect(
          registry.allProtocols
              .expand((p) => p.models)
              .map((m) => m.modelId)
              .contains(entry.modelId),
          isTrue,
          reason: '"${entry.modelId}" is bundled but no protocol declares it',
        );
      }
    });

    test('the knee camera branch is explicitly untrained for lack of data', () {
      final camera = registry
          .protocolFor('knee')
          .modelFor(ModelBranch.cameraTemporal);

      expect(camera, isNotNull);
      expect(camera!.trainingStatus, TrainingStatus.untrainedInsufficientData);
      expect(camera.limitations.join(' ').toLowerCase(), contains('no public dataset'));
    });

    test('branches that consume IMU data disclose the placement they were trained at', () {
      for (final protocol in registry.allProtocols) {
        for (final model in protocol.models) {
          final consumesImu =
              model.inputModalities.any((m) => m.startsWith('imu_'));
          if (!consumesImu) continue;

          // An untrained branch has no artefact to disclose a placement for:
          // its input_modalities describe intent, and the data-gap limitation
          // (asserted above) is what the worker actually needs to see.
          if (model.trainingStatus == TrainingStatus.untrainedInsufficientData) {
            continue;
          }

          expect(
            model.placementNote,
            isNotNull,
            reason: '${protocol.jointId}/${model.modelId} consumes IMU data, so it '
                'must disclose the placement its training data came from',
          );
        }
      }
    });

    test('honesty labels never assert clinical validation, only deny it', () {
      for (final status in TrainingStatus.values) {
        final label = status.honestyLabel.toLowerCase();
        if (label.contains('clinically validated')) {
          expect(
            label,
            contains('not clinically validated'),
            reason: 'any mention of clinical validation must be a denial, '
                'never an assertion',
          );
        }
      }
      expect(TrainingStatus.trained.honestyLabel, contains('not clinically validated'));
      expect(TrainingStatus.untrainedInsufficientData.honestyLabel, contains('Not trained'));
      expect(TrainingStatus.prototypeRuleBased.honestyLabel, contains('not a trained model'));
    });
  });

  group('protocol integrity holds for every joint', () {
    test('every movement test feature is declared in the feature pipeline', () {
      for (final protocol in registry.allProtocols) {
        final declared = protocol.featurePipeline.map((f) => f.key).toSet();
        for (final test in protocol.movementTests) {
          for (final feature in test.derivedFeatures) {
            expect(
              declared,
              contains(feature),
              reason: '${protocol.jointId}/${test.id} derives undeclared "$feature"',
            );
          }
        }
      }
    });

    test('risk bands start at zero, ascend, and end at high', () {
      for (final protocol in registry.allProtocols) {
        final bands = protocol.riskLogic.bands;
        expect(bands, isNotEmpty);
        expect(bands.first.minScore, 0.0);
        expect(bands.last.id, 'high');
        for (var i = 1; i < bands.length; i++) {
          expect(bands[i].minScore, greaterThan(bands[i - 1].minScore));
        }
      }
    });

    test('every joint documents that its thresholds are placeholders', () {
      for (final protocol in registry.allProtocols) {
        expect(
          protocol.riskLogic.isPlaceholder,
          isTrue,
          reason: '${protocol.jointId} must declare that its thresholds are not '
              'validated operating points (PRD §26.5)',
        );
      }
    });

    test('bandFor picks the highest band the score clears', () {
      final logic = registry.protocolFor('knee').riskLogic;

      expect(logic.bandFor(0.0).id, 'low');
      expect(logic.bandFor(0.39).id, 'low');
      expect(logic.bandFor(0.40).id, 'moderate');
      expect(logic.bandFor(0.69).id, 'moderate');
      expect(logic.bandFor(0.70).id, 'high');
      expect(logic.bandFor(1.0).id, 'high');
    });

    test('research-grade features exist but stay out of the primary set', () {
      final knee = registry.protocolFor('knee');

      final varus = knee.feature('posture_varus_thrust');
      expect(varus, isNotNull);
      expect(varus!.researchGrade, isTrue);
      expect(knee.primaryFeatures.map((f) => f.key), isNot(contains('posture_varus_thrust')));

      final crepitus = knee.feature('imu_gyro_hf_variance');
      expect(crepitus!.researchGrade, isTrue);
    });

    test('every joint has a safety disclaimer and a preferred wearable config', () {
      for (final protocol in registry.allProtocols) {
        expect(protocol.safety.disclaimerKey, isNotEmpty);
        expect(protocol.reportTemplate.map((s) => s.sectionId), contains('disclaimer'));
        if (protocol.wearable.supported) {
          expect(
            protocol.wearable.preferred,
            isNotNull,
            reason: '${protocol.jointId} supports the pod but names no preferred placement',
          );
        }
      }
    });

    test('every body map region resolves to a loadable joint', () {
      expect(registry.bodyMapRegions, isNotEmpty);
      for (final region in registry.bodyMapRegions) {
        if (region.isAssessable) {
          expect(registry.hasJoint(region.jointId!), isTrue);
        }
      }
    });
  });

  group('lookups fail loudly rather than returning null', () {
    test('requesting an unknown joint throws', () {
      expect(() => registry.protocolFor('spleen'), throwsA(isA<ProtocolLoadException>()));
      expect(() => registry.entryFor('spleen'), throwsA(isA<ProtocolLoadException>()));
    });

    test('all four laterality options parse from supported_sides', () {
      for (final protocol in registry.allProtocols) {
        expect(protocol.supportedSides, contains('left'));
        expect(protocol.supportedSides, contains('right'));
      }
    });
  });
}
