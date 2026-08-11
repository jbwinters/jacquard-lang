"""Blinded rescoring and publication lineage for checked readability evidence.

The public entry points consume rows only after complete result-store
validation and require the exact ``readability-analysis-input-v1`` selection.
They can prepare an outcome-blinded rescore packet, verify a returned
assessment against the frozen answer key, and assemble one deterministic
candidate-evidence bundle.  They do not collect data, prove reviewer
independence, authorize publication, or create a readability verdict.
"""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any

from readability_analysis import (
    AnalysisError,
    encode_analysis_bundle,
    prepare_analysis_bundle,
)
from readability_comparative import (
    ComparativeError,
    encode_comparative_bundle,
    prepare_comparative_bundle,
)
from readability_descriptive import (
    DescriptiveError,
    encode_descriptive_bundle,
    prepare_descriptive_bundle,
)


RESCORE_PACKET_VERSION = "readability-rescore-packet-v1"
RESCORE_ASSESSMENT_VERSION = "readability-rescore-assessment-v1"
RESCORE_RECORD_VERSION = "readability-rescore-record-v1"
EVIDENCE_BUNDLE_VERSION = "readability-evidence-bundle-v1"
HEX_SHA256 = re.compile(r"[0-9a-f]{64}")


class EvidenceError(RuntimeError):
    """Raised when checked evidence cannot form one exact closure artifact."""


def _canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    )


def _encode(value: dict[str, Any]) -> str:
    return _canonical_json(value) + "\n"


def encode_rescore_packet(packet: dict[str, Any]) -> str:
    """Return canonical, timestamp-free JSON for a blinded rescore packet."""

    return _encode(packet)


def encode_rescore_record(record: dict[str, Any]) -> str:
    """Return canonical JSON for an answer-key-verified rescore record."""

    return _encode(record)


def encode_evidence_bundle(bundle: dict[str, Any]) -> str:
    """Return canonical JSON for a provenance-complete evidence candidate."""

    return _encode(bundle)


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha256_text(value: str) -> str:
    return _sha256_bytes(value.encode("utf-8"))


def _encoded_sha256(encoded: str) -> str:
    return _sha256_bytes(encoded.encode("utf-8"))


def _field(value: dict[str, Any], name: str, context: str) -> Any:
    if name not in value:
        raise EvidenceError(f"{context} is missing required field: {name}")
    return value[name]


def _require_sha256(value: Any, context: str) -> str:
    if not isinstance(value, str) or HEX_SHA256.fullmatch(value) is None:
        raise EvidenceError(f"{context} must be a lowercase SHA-256")
    return value


def _fixture_index(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    fixtures = manifest.get("fixtures") if isinstance(manifest, dict) else None
    if not isinstance(fixtures, list) or not fixtures:
        raise EvidenceError("rescore fixture manifest has no fixtures")
    indexed: dict[str, dict[str, Any]] = {}
    for fixture in fixtures:
        if not isinstance(fixture, dict):
            raise EvidenceError("rescore fixture entries must be objects")
        fixture_id = fixture.get("id")
        if not isinstance(fixture_id, str) or not fixture_id:
            raise EvidenceError("rescore fixture ID must be a nonempty string")
        if fixture_id in indexed:
            raise EvidenceError(f"rescore fixture ID is duplicated: {fixture_id}")
        indexed[fixture_id] = fixture
    return indexed


def score_answer(fixture: dict[str, Any], answer_id: str) -> tuple[bool, str | None]:
    """Score one opaque answer ID against a verified fixture answer key.

    Reserved failure sentinels retain their protocol meanings.  A non-option
    answer is ``invalid-answer``.  Malformed fixture data raises
    :class:`EvidenceError`; no answer receives a partial or guessed score.
    """

    options = fixture.get("options") if isinstance(fixture, dict) else None
    correct_answer = (
        fixture.get("correct_answer") if isinstance(fixture, dict) else None
    )
    wrong_errors = (
        fixture.get("wrong_answer_errors") if isinstance(fixture, dict) else None
    )
    if (
        not isinstance(options, list)
        or not isinstance(correct_answer, str)
        or not isinstance(wrong_errors, dict)
        or not isinstance(answer_id, str)
    ):
        raise EvidenceError("rescore answer key or submitted answer is malformed")
    option_ids = {
        option.get("id")
        for option in options
        if isinstance(option, dict) and isinstance(option.get("id"), str)
    }
    if len(option_ids) != len(options) or correct_answer not in option_ids:
        raise EvidenceError("rescore answer-key option inventory is malformed")
    if answer_id == "__timeout__":
        return False, "timeout"
    if answer_id == "__system_failure__":
        return False, "system-failure"
    if answer_id == "__parse_failure__":
        return False, "prompt-parse-failure"
    if answer_id not in option_ids:
        return False, "invalid-answer"
    if answer_id == correct_answer:
        return True, None
    error_code = wrong_errors.get(answer_id)
    if not isinstance(error_code, str) or not error_code:
        raise EvidenceError("rescore wrong-answer taxonomy is incomplete")
    return False, error_code


def _exact_analysis(
    rows: list[dict[str, Any]], input_sha256: str, analysis: dict[str, Any]
) -> dict[str, Any]:
    if not isinstance(rows, list) or not rows or any(
        not isinstance(row, dict) for row in rows
    ):
        raise EvidenceError("rescore requires one validated nonempty object store")
    _require_sha256(input_sha256, "rescore source digest")
    if not isinstance(analysis, dict):
        raise EvidenceError("rescore analysis input must be an object")
    try:
        expected = prepare_analysis_bundle(rows, input_sha256)
    except AnalysisError as error:
        raise EvidenceError(f"rescore cannot reproduce analysis input: {error}") from error
    if encode_analysis_bundle(analysis) != encode_analysis_bundle(expected):
        raise EvidenceError("rescore analysis input is not the exact derived bundle")
    return expected


def _effective_rows(
    rows: list[dict[str, Any]], analysis: dict[str, Any]
) -> list[dict[str, Any]]:
    decisions = analysis.get("subjects")
    if not isinstance(decisions, list):
        raise EvidenceError("rescore analysis lacks subject decisions")
    effective_ids: list[str] = []
    for decision in decisions:
        values = (
            decision.get("effective_row_ids")
            if isinstance(decision, dict)
            else None
        )
        if not isinstance(values, list):
            raise EvidenceError("rescore subject decision has malformed effective rows")
        for row_id in values:
            effective_ids.append(_require_sha256(row_id, "rescore effective row ID"))
    if len(effective_ids) != len(set(effective_ids)):
        raise EvidenceError("rescore effective row IDs are duplicated")
    row_by_id: dict[str, dict[str, Any]] = {}
    for row in rows:
        row_id = _require_sha256(row.get("row_id"), "rescore source row ID")
        if row_id in row_by_id:
            raise EvidenceError("rescore source row IDs are duplicated")
        row_by_id[row_id] = row
    if any(row_id not in row_by_id for row_id in effective_ids):
        raise EvidenceError("rescore effective selection names an absent source row")
    return [row_by_id[row_id] for row_id in effective_ids]


def _rank(sample_seed: str, row_id: str) -> str:
    return _sha256_text(
        f"{RESCORE_PACKET_VERSION}\0rank\0{sample_seed}\0{row_id}"
    )


def _blind_id(sample_seed: str, row_id: str) -> str:
    return _sha256_text(
        f"{RESCORE_PACKET_VERSION}\0blind\0{sample_seed}\0{row_id}"
    )


def prepare_rescore_packet(
    rows: list[dict[str, Any]],
    input_sha256: str,
    analysis: dict[str, Any],
    manifest: dict[str, Any],
    sample_seed: str,
    sample_size: int,
) -> dict[str, Any]:
    """Prepare one deterministic, outcome-blinded independent-rescore packet.

    The caller supplies a previously reviewed seed and positive sample count;
    this function deliberately chooses neither.  Selection ranks exact
    effective row IDs with domain-separated SHA-256.  Packet trials expose
    only opaque blind IDs, fixture IDs, and submitted answer IDs.  Carrier,
    subject/source row identity, original score, time, confidence, rating, and
    outcome fields are omitted.  Invalid provenance or an oversized sample
    raises :class:`EvidenceError`.
    """

    exact_analysis = _exact_analysis(rows, input_sha256, analysis)
    if not isinstance(sample_seed, str) or not sample_seed:
        raise EvidenceError("rescore sample seed must be a nonempty string")
    if (
        isinstance(sample_size, bool)
        or not isinstance(sample_size, int)
        or sample_size < 1
    ):
        raise EvidenceError("rescore sample size must be a positive integer")
    indexed = _fixture_index(manifest)
    effective = _effective_rows(rows, exact_analysis)
    if sample_size > len(effective):
        raise EvidenceError(
            "rescore sample size exceeds the validated effective-row count"
        )
    ranked = sorted(
        effective,
        key=lambda row: (
            _rank(sample_seed, _field(row, "row_id", "rescore row")),
            _field(row, "row_id", "rescore row"),
        ),
    )
    trials: list[dict[str, Any]] = []
    for row in ranked[:sample_size]:
        row_id = _require_sha256(row.get("row_id"), "rescore selected row ID")
        fixture_id = _field(row, "fixture_id", "rescore selected row")
        answer_id = _field(row, "answer_id", "rescore selected row")
        if fixture_id not in indexed or not isinstance(answer_id, str):
            raise EvidenceError("rescore selected row disagrees with the fixture manifest")
        trials.append(
            {
                "answer_id": answer_id,
                "blind_id": _blind_id(sample_seed, row_id),
                "fixture_id": fixture_id,
            }
        )
    blind_ids = [trial["blind_id"] for trial in trials]
    if len(blind_ids) != len(set(blind_ids)):
        raise EvidenceError("rescore blind IDs collided")
    effective_ids = [row["row_id"] for row in effective]
    source = exact_analysis.get("source")
    if not isinstance(source, dict):
        raise EvidenceError("rescore analysis source is malformed")
    return {
        "claim_status": "not-evaluated",
        "evidence_class": exact_analysis.get("evidence_class"),
        "packet_scope": "outcome-blinded-answer-rescore",
        "packet_version": RESCORE_PACKET_VERSION,
        "protocol_version": exact_analysis.get("protocol_version"),
        "sample": {
            "effective_row_count": len(effective),
            "requested_row_count": sample_size,
            "sample_seed_sha256": _sha256_text(
                f"{RESCORE_PACKET_VERSION}\0seed\0{sample_seed}"
            ),
            "selection_rule": "sha256-rank-over-effective-row-id-v1",
        },
        "source": {
            "analysis_input_sha256": _encoded_sha256(
                encode_analysis_bundle(exact_analysis)
            ),
            "effective_row_sequence_sha256": _sha256_text(
                "\n".join(effective_ids) + "\n"
            ),
            "fixture_manifest_sha256": source.get("fixture_manifest_sha256"),
            "input_jsonl_sha256": input_sha256,
        },
        "subject_kind": exact_analysis.get("subject_kind"),
        "trials": trials,
    }


def _strict_assessment(assessment: dict[str, Any]) -> None:
    expected = {
        "assessment_version",
        "decisions",
        "independence_attestation_sha256",
        "packet_sha256",
    }
    if not isinstance(assessment, dict) or set(assessment) != expected:
        raise EvidenceError("rescore assessment field inventory is malformed")
    if assessment.get("assessment_version") != RESCORE_ASSESSMENT_VERSION:
        raise EvidenceError("rescore assessment version drifted")
    _require_sha256(
        assessment.get("packet_sha256"), "rescore assessment packet digest"
    )
    decisions = assessment.get("decisions")
    if not isinstance(decisions, list):
        raise EvidenceError("rescore assessment decisions must be a list")


def _strict_packet(packet: dict[str, Any]) -> None:
    expected = {
        "claim_status",
        "evidence_class",
        "packet_scope",
        "packet_version",
        "protocol_version",
        "sample",
        "source",
        "subject_kind",
        "trials",
    }
    if not isinstance(packet, dict) or set(packet) != expected:
        raise EvidenceError("rescore packet field inventory is malformed")
    if (
        packet.get("packet_version") != RESCORE_PACKET_VERSION
        or packet.get("protocol_version") != "readability-protocol-v1"
        or packet.get("packet_scope") != "outcome-blinded-answer-rescore"
        or packet.get("claim_status") != "not-evaluated"
    ):
        raise EvidenceError("rescore packet contract or version drifted")
    expected_classes = {
        "human": "human-candidate",
        "model": "model-candidate",
        "synthetic": "synthetic-non-citable",
    }
    subject_kind = packet.get("subject_kind")
    if expected_classes.get(subject_kind) != packet.get("evidence_class"):
        raise EvidenceError("rescore subject kind and evidence class disagree")
    sample = packet.get("sample")
    if not isinstance(sample, dict) or set(sample) != {
        "effective_row_count",
        "requested_row_count",
        "sample_seed_sha256",
        "selection_rule",
    }:
        raise EvidenceError("rescore packet sample metadata is malformed")
    effective_count = sample.get("effective_row_count")
    requested_count = sample.get("requested_row_count")
    if (
        isinstance(effective_count, bool)
        or not isinstance(effective_count, int)
        or isinstance(requested_count, bool)
        or not isinstance(requested_count, int)
        or requested_count < 1
        or effective_count < requested_count
        or sample.get("selection_rule")
        != "sha256-rank-over-effective-row-id-v1"
    ):
        raise EvidenceError("rescore packet sample counts or selection rule drifted")
    _require_sha256(sample.get("sample_seed_sha256"), "rescore sample seed digest")
    source = packet.get("source")
    if not isinstance(source, dict) or set(source) != {
        "analysis_input_sha256",
        "effective_row_sequence_sha256",
        "fixture_manifest_sha256",
        "input_jsonl_sha256",
    }:
        raise EvidenceError("rescore packet source metadata is malformed")
    for name, value in source.items():
        _require_sha256(value, f"rescore packet {name}")
    trials = packet.get("trials")
    if not isinstance(trials, list) or len(trials) != requested_count:
        raise EvidenceError("rescore packet trial count disagrees with its sample")


def verify_rescore_assessment(
    packet: dict[str, Any],
    assessment: dict[str, Any],
    manifest: dict[str, Any],
) -> dict[str, Any]:
    """Verify a returned blinded assessment against the frozen answer key.

    Real candidate evidence requires a SHA-256 binding separately retained
    reviewer-independence evidence.  The hash proves only byte binding: this
    function explicitly does not prove the reviewer's identity or
    independence.  Synthetic assessments must leave that field null and stay
    non-citable.  Every decision must preserve packet order and agree exactly
    with the answer key or the whole record is refused.
    """

    _strict_packet(packet)
    _strict_assessment(assessment)
    packet_sha256 = _encoded_sha256(encode_rescore_packet(packet))
    if assessment.get("packet_sha256") != packet_sha256:
        raise EvidenceError("rescore assessment is bound to a different packet")
    evidence_class = packet.get("evidence_class")
    attestation = assessment.get("independence_attestation_sha256")
    if evidence_class == "synthetic-non-citable":
        if attestation is not None:
            raise EvidenceError("synthetic rescoring cannot assert reviewer independence")
        attestation_status = "not-applicable-synthetic"
    else:
        _require_sha256(attestation, "rescore independence attestation digest")
        attestation_status = "external-attestation-present-not-machine-verified"

    trials = packet.get("trials")
    decisions = assessment.get("decisions")
    if not isinstance(trials, list) or len(trials) != len(decisions):
        raise EvidenceError("rescore assessment does not cover every packet trial")
    indexed = _fixture_index(manifest)
    normalized: list[dict[str, Any]] = []
    seen: set[str] = set()
    for trial, decision in zip(trials, decisions, strict=True):
        if not isinstance(trial, dict) or set(trial) != {
            "answer_id",
            "blind_id",
            "fixture_id",
        }:
            raise EvidenceError("rescore packet trial field inventory is malformed")
        if not isinstance(decision, dict) or set(decision) != {
            "blind_id",
            "correct",
            "error_code",
        }:
            raise EvidenceError("rescore decision field inventory is malformed")
        blind_id = _require_sha256(trial.get("blind_id"), "rescore blind ID")
        if blind_id in seen or decision.get("blind_id") != blind_id:
            raise EvidenceError("rescore decisions are duplicated, missing, or reordered")
        seen.add(blind_id)
        fixture_id = trial.get("fixture_id")
        answer_id = trial.get("answer_id")
        if fixture_id not in indexed or not isinstance(answer_id, str):
            raise EvidenceError("rescore packet trial has an unknown fixture or answer")
        expected_correct, expected_error = score_answer(
            indexed[fixture_id], answer_id
        )
        correct = decision.get("correct")
        error_code = decision.get("error_code")
        if not isinstance(correct, bool) or (
            error_code is not None and not isinstance(error_code, str)
        ):
            raise EvidenceError("rescore decision score fields are malformed")
        if correct != expected_correct or error_code != expected_error:
            raise EvidenceError("rescore decision disagrees with the frozen answer key")
        normalized.append(
            {
                "blind_id": blind_id,
                "correct": correct,
                "error_code": error_code,
            }
        )

    normalized_assessment = {
        "assessment_version": RESCORE_ASSESSMENT_VERSION,
        "decisions": normalized,
        "independence_attestation_sha256": attestation,
        "packet_sha256": packet_sha256,
    }
    return {
        "assessment_sha256": _sha256_text(_encode(normalized_assessment)),
        "attestation": {
            "independence_evidence_sha256": attestation,
            "status": attestation_status,
        },
        "claim_status": "not-evaluated",
        "decision_count": len(normalized),
        "decisions_sha256": _sha256_text(_canonical_json(normalized)),
        "evidence_class": evidence_class,
        "machine_verification": "exact-answer-key-agreement",
        "packet_sha256": packet_sha256,
        "record_version": RESCORE_RECORD_VERSION,
        "reviewer_independence": (
            "not-applicable-synthetic"
            if evidence_class == "synthetic-non-citable"
            else "external-fact-not-machine-proven"
        ),
        "sample": json.loads(_canonical_json(packet.get("sample"))),
    }


def _artifact(encoded: str, value: dict[str, Any]) -> dict[str, Any]:
    return {
        "sha256": _encoded_sha256(encoded),
        "value": json.loads(_canonical_json(value)),
    }


def prepare_evidence_bundle(
    rows: list[dict[str, Any]],
    input_sha256: str,
    analysis: dict[str, Any],
    manifest: dict[str, Any],
    sample_seed: str,
    sample_size: int,
    assessment: dict[str, Any],
) -> dict[str, Any]:
    """Assemble one deterministic, provenance-complete evidence candidate.

    The bundle regenerates descriptive tables and the applicable human carrier
    comparison from the exact admitted source and embeds them with canonical
    byte digests.  A model bundle remains descriptive and cannot enter the
    human comparison.  The rescore record must agree with the frozen answer
    key.  The returned object remains ``not-evaluated`` and requires external
    publication authority, reviewer-independence validation, and honest
    interpretation before any measured claim can be made.
    """

    exact_analysis = _exact_analysis(rows, input_sha256, analysis)
    try:
        descriptive = prepare_descriptive_bundle(
            rows, input_sha256, exact_analysis
        )
    except DescriptiveError as error:
        raise EvidenceError(
            f"evidence bundle cannot derive descriptive tables: {error}"
        ) from error
    subject_kind = exact_analysis.get("subject_kind")
    comparative: dict[str, Any] | None
    if subject_kind == "model":
        comparative = None
    else:
        try:
            comparative = prepare_comparative_bundle(
                rows, input_sha256, exact_analysis
            )
        except ComparativeError as error:
            raise EvidenceError(
                f"evidence bundle cannot derive carrier comparison: {error}"
            ) from error
    packet = prepare_rescore_packet(
        rows,
        input_sha256,
        exact_analysis,
        manifest,
        sample_seed,
        sample_size,
    )
    rescore = verify_rescore_assessment(packet, assessment, manifest)

    artifacts: dict[str, Any] = {
        "analysis_input": _artifact(
            encode_analysis_bundle(exact_analysis), exact_analysis
        ),
        "descriptive": _artifact(
            encode_descriptive_bundle(descriptive), descriptive
        ),
        "rescore_packet": _artifact(encode_rescore_packet(packet), packet),
        "rescore_record": _artifact(encode_rescore_record(rescore), rescore),
    }
    artifacts["comparative"] = (
        None
        if comparative is None
        else _artifact(encode_comparative_bundle(comparative), comparative)
    )
    return {
        "artifacts": artifacts,
        "bundle_scope": "checked-readability-evidence-candidate",
        "bundle_version": EVIDENCE_BUNDLE_VERSION,
        "claim_status": "not-evaluated",
        "evidence_class": exact_analysis.get("evidence_class"),
        "interpretation": {
            "automatic_product_gate": "none",
            "external_required": [
                "reviewer-identity-and-independence-validation",
                "publication-authority-and-license",
                "actual-sample-exclusions-uncertainty-and-limitations",
            ],
            "machine_verified_scope": (
                "exact embedded artifact bytes derive from the admitted source; "
                "rescore decisions agree with the frozen answer key"
            ),
            "minimum_human_count": None,
            "prose_number_rule": (
                "external prose is outside this verification unless it cites this "
                "exact bundle and JSON path"
            ),
        },
        "protocol_version": exact_analysis.get("protocol_version"),
        "source": {
            "fixture_manifest_sha256": exact_analysis.get("source", {}).get(
                "fixture_manifest_sha256"
            ),
            "input_jsonl_sha256": input_sha256,
            "source_row_count": len(rows),
        },
        "subject_kind": subject_kind,
    }
