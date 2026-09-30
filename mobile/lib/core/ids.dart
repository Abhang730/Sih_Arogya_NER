// The Arogya Patient ID (PRD §7.2, §28 FR-03, §21.1).
//
// PRD §1.2 makes the safety boundary binding, and §7.2's own privacy note says a
// protected identity reference "must not become the visible longitudinal
// identifier". So the platform generates its own identifier and uses it
// everywhere: on screen, in the local database, in the sync payload and in the
// report.
//
// Two properties are deliberate:
//
//   1. The ID is RANDOM, not derived from the patient. Hashing a name or a
//      phone number into the ID would reintroduce exactly the linkability the
//      separate identifier exists to remove.
//   2. It carries a check character. Field workers read these aloud and write
//      them on paper; a transposed character has to be detectable before it
//      attaches a result to the wrong person.

import 'dart:math' as math;

class ArogyaPatientId {
  const ArogyaPatientId._();

  /// Crockford-style alphabet: no I, L, O or U, so a handwritten ID cannot be
  /// confused, and it never spells an unfortunate word.
  static const String alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static const String prefix = 'ARO';

  static const int bodyLength = 8;

  static final math.Random _random = math.Random.secure();

  /// Generates a new ID, e.g. `ARO-7K4M-2QP9-C`.
  static String generate() {
    final body = List.generate(
      bodyLength,
      (_) => alphabet[_random.nextInt(alphabet.length)],
      growable: false,
    );
    final joined = body.join();
    return format(joined);
  }

  /// Groups an 8-character body as XXXX-XXXX plus its check character.
  static String format(String body) {
    final normalised = normalise(body);
    final groups = <String>[];
    for (var i = 0; i < normalised.length; i += 4) {
      groups.add(normalised.substring(i, math.min(i + 4, normalised.length)));
    }
    return '$prefix-${groups.join('-')}-${checkCharacter(normalised)}';
  }

  /// Uppercases and strips separators, and maps the characters that are
  /// commonly misread onto their canonical form (I/L -> 1, O -> 0).
  static String normalise(String input) {
    final buffer = StringBuffer();
    for (final rune in input.toUpperCase().runes) {
      final char = String.fromCharCode(rune);
      final mapped = switch (char) {
        'I' || 'L' => '1',
        'O' => '0',
        'U' => 'V',
        _ => char,
      };
      if (alphabet.contains(mapped)) buffer.write(mapped);
    }
    return buffer.toString();
  }

  /// Modulo-37 check character in the same alphabet.
  ///
  /// 37 is coprime with 32, which is what makes a single-character substitution
  /// or a transposition detectable rather than coincidentally valid.
  static String checkCharacter(String body) {
    var sum = 0;
    for (var i = 0; i < body.length; i++) {
      sum = (sum * 32 + alphabet.indexOf(body[i])) % 37;
    }
    return alphabet[sum % 32];
  }

  /// Validates a full or body-only ID, reporting WHY it failed so the UI can
  /// say something useful rather than "invalid".
  static PatientIdValidation validate(String input) {
    final body = normalise(input);
    if (body.isEmpty) {
      return const PatientIdValidation(false, 'Enter an Arogya Patient ID.');
    }
    if (body.length != bodyLength) {
      return PatientIdValidation(
        false,
        'An Arogya Patient ID has $bodyLength characters after the "$prefix-" '
        'prefix; this has ${body.length}.',
      );
    }
    final supplied = _trailingCheckCharacter(input);
    if (supplied != null && supplied != checkCharacter(body)) {
      return const PatientIdValidation(
        false,
        'The last character is a check digit and does not match. Re-read the ID.',
      );
    }
    return const PatientIdValidation(true, '');
  }

  static String? _trailingCheckCharacter(String input) {
    final tail = input.trim().toUpperCase().replaceAll('-', '');
    if (tail.length != bodyLength + 1) return null;
    final last = tail.substring(bodyLength);
    if (last == 'I' || last == 'L') return '1';
    if (last == 'O') return '0';
    return alphabet.contains(last) ? last : null;
  }

  /// Masks a protected identity reference for routine display (PRD §25.1,
  /// §28 FR-04).
  ///
  /// Shows only the last four characters. Deliberately length-independent: the
  /// mask must not leak the length of the underlying value.
  static String maskIdentity(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.length <= 4) return '••••';
    return '${'•' * 6}${trimmed.substring(trimmed.length - 4)}';
  }

  /// A short, non-reversible token for the protected identity field.
  ///
  /// This is a lookup-key digest, not encryption. It exists so the app can, for
  /// example, notice that two records were entered for the same document
  /// without ever storing that document. The raw value is stored separately
  /// under the encrypted database (PRD §21.2, §25.1).
  static String identityToken(String raw, String recordSalt) {
    // Deliberately NOT a plain hash of the value: the salt is per-record, so
    // two records for the same person do not produce equal tokens unless the
    // caller supplies the same salt on purpose.
    final bytes = <int>[];
    final salted = '$recordSalt|${raw.trim().toUpperCase()}';
    for (final unit in salted.codeUnits) {
      bytes.add(unit & 0xFF);
    }
    var hash = 0x811c9dc5;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}

class PatientIdValidation {
  const PatientIdValidation(this.isValid, this.message);

  final bool isValid;
  final String message;
}

/// BMI, computed only when both inputs are present (PRD §30 Phase 2).
///
/// Returns null rather than 0 when a measurement is missing, for the same reason
/// fusion returns null instead of 0: an absent measurement and a measured zero
/// are different statements (PRD §26.5).
double? computeBmi({required double? heightCm, required double? weightKg}) {
  if (heightCm == null || weightKg == null) return null;
  if (heightCm <= 0 || weightKg <= 0) return null;
  final metres = heightCm / 100.0;
  return weightKg / (metres * metres);
}
