// Protocol registry: loads the bundled protocol set and exposes lookups.
//
// The registry is the only place that knows where protocols live. Screens ask
// the registry for a joint; they never construct a protocol path or branch on a
// joint name (PRD §6.1, §29).

import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'models.dart';

/// One entry in protocols/index.json.
class ProtocolEntry {
  const ProtocolEntry({
    required this.jointId,
    required this.path,
    required this.version,
    required this.status,
    required this.sides,
    required this.titleKey,
  });

  final String jointId;
  final String path;
  final String version;
  final ProtocolStatus status;
  final List<String> sides;
  final String titleKey;

  factory ProtocolEntry.fromJson(Map<String, dynamic> json) => ProtocolEntry(
        jointId: json['joint_id'] as String,
        path: json['path'] as String,
        version: json['version'] as String,
        status: ProtocolStatus.fromWire(json['status'] as String?),
        sides: (json['sides'] as List).cast<String>(),
        titleKey: json['title_key'] as String,
      );
}

/// A region on the Stage-1 body map (PRD §11.1).
class BodyMapRegion {
  const BodyMapRegion({
    required this.region,
    required this.labelKey,
    required this.jointId,
    required this.sides,
  });

  final String region;
  final String labelKey;

  /// Null for regions that have no joint module (head/neck).
  final String? jointId;
  final List<String> sides;

  bool get isAssessable => jointId != null;

  factory BodyMapRegion.fromJson(Map<String, dynamic> json) => BodyMapRegion(
        region: json['region'] as String,
        labelKey: json['label_key'] as String,
        jointId: json['joint_id'] as String?,
        sides: (json['sides'] as List?)?.cast<String>() ?? const [],
      );
}

/// Raised when the bundled protocol set is missing, malformed or inconsistent.
class ProtocolLoadException implements Exception {
  ProtocolLoadException(this.message);

  final String message;

  @override
  String toString() => 'ProtocolLoadException: $message';
}

class ProtocolRegistry {
  ProtocolRegistry._({
    required this.registryVersion,
    required this.landmarks,
    required this.entries,
    required this.jointOrder,
    required this.bodyMapRegions,
    required this.protocols,
  });

  final String registryVersion;
  final LandmarkTopology landmarks;
  final List<ProtocolEntry> entries;
  final List<String> jointOrder;
  final List<BodyMapRegion> bodyMapRegions;

  /// Joint id to protocol. Exposed so tooling can enumerate the bundle, but
  /// screens should go through [protocolFor] so a missing joint fails loudly.
  final Map<String, JointProtocol> protocols;

  static const String assetRoot = 'assets/protocols';

  List<JointProtocol> get allProtocols =>
      jointOrder.map((id) => protocols[id]!).toList(growable: false);

  /// Joints with a complete end-to-end module (PRD §12.2).
  List<JointProtocol> get mvpProtocols => allProtocols
      .where((p) => p.status == ProtocolStatus.mvp)
      .toList(growable: false);

  JointProtocol protocolFor(String jointId) {
    final protocol = protocols[jointId];
    if (protocol == null) {
      throw ProtocolLoadException('No protocol registered for joint "$jointId".');
    }
    return protocol;
  }

  bool hasJoint(String jointId) => protocols.containsKey(jointId);

  ProtocolEntry entryFor(String jointId) {
    final match = entries.where((e) => e.jointId == jointId);
    if (match.isEmpty) {
      throw ProtocolLoadException('Joint "$jointId" is not in the registry index.');
    }
    return match.first;
  }

  /// Loads and cross-validates the whole bundled protocol set.
  ///
  /// Validation here is intentionally shallow (references resolve, versions
  /// agree): the deep structural checks live in tools/lint_protocols.py, which
  /// runs in CI. Doing the heavyweight validation on every app start would cost
  /// launch time on the low-end devices this product targets.
  static Future<ProtocolRegistry> load({AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;

    final indexJson = await _readJson(assets, '$assetRoot/index.json');
    final landmarksJson = await _readJson(assets, '$assetRoot/core/landmarks.json');

    final landmarks = LandmarkTopology.fromJson(landmarksJson);

    final entries = (indexJson['protocols'] as List)
        .map((e) => ProtocolEntry.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);

    final protocols = <String, JointProtocol>{};
    for (final entry in entries) {
      final json = await _readJson(assets, '$assetRoot/${entry.path}');
      final protocol = JointProtocol.fromJson(json);

      if (protocol.jointId != entry.jointId) {
        throw ProtocolLoadException(
          'Registry entry "${entry.jointId}" points at a protocol declaring '
          'joint_id "${protocol.jointId}".',
        );
      }
      if (protocol.protocolVersion != entry.version) {
        throw ProtocolLoadException(
          'Registry version ${entry.version} for "${entry.jointId}" does not '
          'match protocol_version ${protocol.protocolVersion}.',
        );
      }

      // Every landmark a protocol names must exist in the topology, otherwise
      // the feature extractor would silently produce a null-derived angle.
      final knownKeys = landmarks.indexByKey.keys.toSet();
      for (final chain in protocol.landmarks.jointChains) {
        for (final key in chain.landmarks) {
          if (!knownKeys.contains(key)) {
            throw ProtocolLoadException(
              'Protocol "${entry.jointId}" chain "${chain.name}" references '
              'unknown landmark "$key".',
            );
          }
        }
      }

      protocols[entry.jointId] = protocol;
    }

    final stage1 = indexJson['stage1'] as Map<String, dynamic>? ?? const {};
    final jointOrder = (stage1['joint_order'] as List?)?.cast<String>() ??
        entries.map((e) => e.jointId).toList(growable: false);

    for (final id in jointOrder) {
      if (!protocols.containsKey(id)) {
        throw ProtocolLoadException(
          'stage1.joint_order lists "$id" but no protocol was loaded for it.',
        );
      }
    }

    final regions = (stage1['body_map_regions'] as List?)
            ?.map((e) => BodyMapRegion.fromJson(e as Map<String, dynamic>))
            .toList(growable: false) ??
        const <BodyMapRegion>[];

    return ProtocolRegistry._(
      registryVersion: indexJson['registry_version'] as String? ?? '0.0.0',
      landmarks: landmarks,
      entries: entries,
      jointOrder: jointOrder,
      bodyMapRegions: regions,
      protocols: protocols,
    );
  }

  static Future<Map<String, dynamic>> _readJson(AssetBundle bundle, String path) async {
    final String raw;
    try {
      raw = await bundle.loadString(path);
    } catch (error) {
      throw ProtocolLoadException('Could not load bundled asset "$path": $error');
    }
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException catch (error) {
      throw ProtocolLoadException('Asset "$path" is not valid JSON: ${error.message}');
    }
  }
}
