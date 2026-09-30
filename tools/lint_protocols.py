#!/usr/bin/env python3
"""Arogya-NER protocol linter.

Why this exists
---------------
The protocols directory is the single source of truth for what the product is
allowed to claim. PRD section 1.2 makes honesty a *binding* product guardrail,
so the guardrails are enforced by a test rather than by reviewer memory.

Two classes of check:

1. Schema conformance  - every protocol validates against joint_protocol.schema.json.
2. Semantic integrity  - cross-file rules the schema cannot express:
   * movement_test.derived_features must exist in feature_pipeline
   * landmark_chains must reference real landmarks from core/landmarks.json
   * identical instrument names must have identical item sets and scoring
   * risk bands must be ordered, non-overlapping and cover 0..1
   * a model with training_status "trained" must carry real metrics and a
     dataset reference; a model with metrics must not be "untrained_insufficient_data"
   * "trained" is still only a prototype - clinical validation is tracked
     separately in docs/validation/
   * only joints declared in index.json become reachable, and every protocol
     must be registered

Exit code 0 = clean, 1 = errors found. Warnings do not fail the build.
"""

from __future__ import annotations

import json
import pathlib
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROTOCOLS = ROOT / "protocols"

ERRORS: list[str] = []
WARNINGS: list[str] = []


def err(msg: str) -> None:
    ERRORS.append(msg)


def warn(msg: str) -> None:
    WARNINGS.append(msg)


def load(path: pathlib.Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        err(f"MISSING FILE {path.relative_to(ROOT)}")
    except json.JSONDecodeError as exc:
        err(f"INVALID JSON {path.relative_to(ROOT)}: {exc}")
    return None


# ---------------------------------------------------------------- schema ----

def strip_annotations(node: Any) -> Any:
    """Remove authoring-annotation keys before schema validation.

    Protocol files carry $-prefixed keys ($schema, $note, $status_reason, ...)
    purely as machine-readable documentation for a human reader. They are not
    product data, the app never reads them, and validating them would mean
    loosening the schema with patternProperties everywhere. Stripping them here
    keeps the schema strict about real fields while annotations stay free-form.
    """
    if isinstance(node, dict):
        return {k: strip_annotations(v) for k, v in node.items() if not k.startswith("$")}
    if isinstance(node, list):
        return [strip_annotations(v) for v in node]
    return node


def validate_schema(protocol: dict, rel: str) -> None:
    try:
        import jsonschema  # type: ignore
    except ImportError:
        warn("jsonschema not installed - schema validation skipped (pip install jsonschema)")
        return

    schema = load(PROTOCOLS / "schema" / "joint_protocol.schema.json")
    if schema is None:
        return
    validator = jsonschema.Draft202012Validator(schema)
    for error in sorted(validator.iter_errors(strip_annotations(protocol)), key=lambda e: list(e.path)):
        location = "/".join(str(p) for p in error.path) or "<root>"
        err(f"SCHEMA {rel} @ {location}: {error.message}")


# -------------------------------------------------------------- semantics ----

LANDMARK_KEYS: set[str] = set()


def load_landmarks() -> None:
    data = load(PROTOCOLS / "core" / "landmarks.json")
    if not isinstance(data, dict):
        return
    for lm in data.get("landmarks", []):
        LANDMARK_KEYS.add(lm["key"])
    declared = data.get("landmark_count")
    if declared != len(data.get("landmarks", [])):
        err(f"core/landmarks.json landmark_count={declared} but {len(data.get('landmarks', []))} entries")


def check_semantics(joint_id: str, p: dict, rel: str) -> None:
    # -- feature references ------------------------------------------------
    feature_keys = {f["key"] for f in p.get("feature_pipeline", [])}
    for test in p.get("movement_tests", []):
        for feat in test.get("derived_features", []):
            if feat not in feature_keys:
                err(f"{rel}: movement_test '{test['id']}' references unknown feature '{feat}' (not in feature_pipeline)")

    # -- landmark chain integrity ------------------------------------------
    for chain in p.get("landmark_subset", {}).get("joint_chains", []):
        for lm in chain.get("landmarks", []):
            if LANDMARK_KEYS and lm not in LANDMARK_KEYS:
                err(f"{rel}: joint_chain '{chain['name']}' references unknown landmark '{lm}'")
        angle_feature = chain.get("angle_feature")
        if angle_feature and angle_feature not in feature_keys:
            # a chain may name a per-side angle not enumerated in feature_pipeline
            warn(f"{rel}: joint_chain '{chain['name']}' angle_feature '{angle_feature}' is not listed in feature_pipeline")

    # -- wearable placement integrity --------------------------------------
    for cfg in p.get("wearable", {}).get("configurations", []):
        for pod in cfg.get("pods", []):
            if not pod.get("placement_key"):
                err(f"{rel}: wearable config '{cfg['id']}' pod {pod.get('pod_index')} has no placement_key")

    # -- risk band integrity -----------------------------------------------
    bands = p.get("risk_logic", {}).get("bands", [])
    if bands:
        mins = [b["min_score"] for b in bands]
        if mins != sorted(mins):
            err(f"{rel}: risk_logic bands are not ordered by min_score: {mins}")
        if mins[0] != 0.0:
            err(f"{rel}: risk_logic bands must start at 0.0, found {mins[0]}")
        for b in bands:
            if not 0.0 <= b["min_score"] <= 1.0:
                err(f"{rel}: band '{b['id']}' min_score {b['min_score']} outside [0,1]")
        ids = [b["id"] for b in bands]
        if len(ids) != len(set(ids)):
            err(f"{rel}: duplicate risk band ids: {ids}")
        if "high" in ids and bands[-1]["id"] != "high":
            err(f"{rel}: the highest band must be 'high' (found '{bands[-1]['id']}')")
        provenance = p.get("risk_logic", {}).get("threshold_provenance", "")
        if not provenance:
            err(f"{rel}: risk_logic.threshold_provenance is required - thresholds must declare their origin")
        elif "PLACEHOLDER" in provenance.upper() and p.get("status") == "mvp":
            warn(f"{rel}: MVP joint still uses placeholder thresholds - must be re-derived before field use (PRD 33)")

    # -- questionnaire coherence -------------------------------------------
    q = p.get("clinical_questionnaire", {})
    status = q.get("status")
    if status == "pending_clinical_sign_off":
        if q.get("items"):
            err(f"{rel}: questionnaire status is pending_clinical_sign_off but carries {len(q['items'])} items")
        if not q.get("reference_instrument"):
            warn(f"{rel}: pending questionnaire should name a reference_instrument")
        for m in p.get("models", []):
            if m.get("branch") == "clinical_tabular" and m.get("training_status") == "trained":
                err(f"{rel}: clinical model claims 'trained' but the questionnaire is not signed off")
    if status == "specified":
        items = q.get("items", [])
        scoring = q.get("scoring", {})
        if items and scoring:
            subscale_counts: dict[str, int] = {}
            for item in items:
                subscale_counts[item["subscale"]] = subscale_counts.get(item["subscale"], 0) + 1
            option_max = max(o["value"] for o in scoring.get("response_options", []))
            item_sum_max = 0
            for sub in scoring.get("subscales", []):
                n = subscale_counts.get(sub["name"], 0)
                expected_max = n * option_max
                if expected_max != sub["max"]:
                    err(
                        f"{rel}: subscale '{sub['name']}' max={sub['max']} but "
                        f"{n} items x max response {option_max} = {expected_max}"
                    )
                item_sum_max += sub["max"]
            if scoring.get("total", {}).get("max") != item_sum_max:
                err(
                    f"{rel}: scoring.total.max={scoring.get('total', {}).get('max')} "
                    f"but subscale maxima sum to {item_sum_max}"
                )
            if scoring.get("total", {}).get("max") != len(items) * option_max:
                err(
                    f"{rel}: scoring.total.max={scoring.get('total', {}).get('max')} "
                    f"but {len(items)} items x {option_max} = {len(items) * option_max}"
                )

    # -- model honesty rules -----------------------------------------------
    for m in p.get("models", []):
        ts = m.get("training_status")
        branch = m.get("branch")
        model_id = m.get("model_id")
        if ts == "trained":
            if not m.get("dataset"):
                err(f"{rel}: model '{model_id}' is trained but has no dataset reference")
            if not m.get("metrics"):
                err(f"{rel}: model '{model_id}' is trained but carries no metrics - PRD 26.5 forbids unmeasured claims")
            if not m.get("limitations"):
                warn(f"{rel}: model '{model_id}' is trained but lists no limitations")
            if "NONE AVAILABLE" in str(m.get("target", {}).get("label_source", "")).upper():
                err(f"{rel}: model '{model_id}' is trained but its label_source says no labels are available")
        if ts == "untrained_insufficient_data" and m.get("metrics"):
            err(f"{rel}: model '{model_id}' is marked untrained but carries metrics - inconsistent")
        if ts == "untrained_insufficient_data" and not m.get("limitations"):
            warn(f"{rel}: untrained model '{model_id}' should state the specific data gap")
        prov = m.get("target", {}).get("label_provenance", "")
        if "NER" not in prov and ts == "trained" and branch != "fusion":
            warn(f"{rel}: model '{model_id}' is trained without any NER-specific provenance (PRD 26.2)")

    # -- report section integrity ------------------------------------------
    sections = [s["section_id"] for s in p.get("report_template", [])]
    if "disclaimer" not in sections:
        err(f"{rel}: report_template must include the 'disclaimer' section (PRD 24.1, FR-25)")
    if len(sections) != len(set(sections)):
        err(f"{rel}: duplicate report section ids: {sections}")


def check_instrument_consistency(protocols: dict[str, dict]) -> None:
    """The same instrument must never be defined two different ways.

    Protocols are intentionally self-contained (one file per joint keeps the
    mobile loader trivial), so drift is caught here instead.
    """
    seen: dict[str, tuple[str, str]] = {}
    for joint_id, p in protocols.items():
        q = p.get("clinical_questionnaire", {})
        if q.get("status") != "specified":
            continue
        name = q.get("instrument")
        # Annotations are documentation, not definition: a $-prefixed note added
        # to one joint's copy of an instrument must not read as a divergence in
        # the clinical definition itself.
        fingerprint = json.dumps(
            strip_annotations({"items": q.get("items"), "scoring": q.get("scoring")}),
            sort_keys=True,
        )
        if name in seen:
            other_joint, other_fp = seen[name]
            if fingerprint != other_fp:
                err(
                    f"instrument '{name}' is defined differently in {other_joint} and {joint_id} - "
                    "shared instruments must have identical items and scoring"
                )
        else:
            seen[name] = (joint_id, fingerprint)


def check_registry(protocols: dict[str, dict]) -> None:
    registry = load(PROTOCOLS / "index.json")
    if not isinstance(registry, dict):
        return

    registered = [e["joint_id"] for e in registry.get("protocols", [])]
    for joint_id in protocols:
        if joint_id not in registered:
            err(f"protocol '{joint_id}' exists on disk but is not listed in protocols/index.json")
    for joint_id in registered:
        if joint_id not in protocols:
            err(f"registry lists '{joint_id}' but protocols/{joint_id}/protocol.json is missing")

    # registry metadata must not drift from the protocol files
    for entry in registry.get("protocols", []):
        joint_id = entry["joint_id"]
        p = protocols.get(joint_id)
        if not p:
            continue
        if entry.get("version") != p.get("protocol_version"):
            err(f"registry version {entry.get('version')} != {joint_id} protocol_version {p.get('protocol_version')}")
        if entry.get("status") != p.get("status"):
            err(f"registry status {entry.get('status')} != {joint_id} status {p.get('status')}")

    # body map regions must resolve to real joints
    for region in registry.get("stage1", {}).get("body_map_regions", []):
        jid = region.get("joint_id")
        if jid and jid not in protocols:
            err(f"body_map region '{region['region']}' points at unknown joint '{jid}'")

    order = registry.get("stage1", {}).get("joint_order", [])
    if sorted(order) != sorted(registered):
        err(f"stage1.joint_order {order} does not match registered protocols {registered}")

    # instrument registry agreement
    for inst in registry.get("instrument_registry", []):
        for joint_id in inst.get("used_by", []):
            p = protocols.get(joint_id)
            if not p:
                continue
            q = p.get("clinical_questionnaire", {})
            if q.get("instrument") != inst.get("instrument"):
                err(
                    f"{joint_id} clinical_questionnaire.instrument='{q.get('instrument')}' "
                    f"but registry instrument_registry says '{inst.get('instrument')}'"
                )
            if q.get("status") != inst.get("status"):
                err(f"{joint_id} questionnaire status mismatch: protocol='{q.get('status')}' registry='{inst.get('status')}'")
            if inst.get("items") is not None and q.get("items") and len(q["items"]) != inst["items"]:
                err(f"{joint_id} has {len(q['items'])} items but registry declares {inst['items']}")


def main() -> int:
    load_landmarks()

    protocols: dict[str, dict] = {}
    for protocol_file in sorted(PROTOCOLS.glob("*/protocol.json")):
        data = load(protocol_file)
        if data is None:
            continue
        rel = str(protocol_file.relative_to(ROOT)).replace("\\", "/")
        joint_id = data.get("joint_id", protocol_file.parent.name)
        if joint_id != protocol_file.parent.name:
            err(f"{rel}: joint_id '{joint_id}' does not match its directory name '{protocol_file.parent.name}'")
        protocols[joint_id] = data
        validate_schema(data, rel)
        check_semantics(joint_id, data, rel)

    if not protocols:
        err("no protocols found")

    check_instrument_consistency(protocols)
    check_registry(protocols)

    for w in WARNINGS:
        print(f"  warn  {w}")
    for e in ERRORS:
        print(f"  FAIL  {e}")

    print()
    print(f"protocols checked : {len(protocols)}  ({', '.join(sorted(protocols))})")
    print(f"errors            : {len(ERRORS)}")
    print(f"warnings          : {len(WARNINGS)}")
    if ERRORS:
        print("\nPROTOCOL LINT FAILED")
        return 1
    print("\nPROTOCOL LINT PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
