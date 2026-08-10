"""Deterministic analyzability and provenance for validated readability stores.

This module never computes outcome statistics or a readability claim.  Its
public entry point accepts rows only after the result-store validator has
accepted the complete store, selects the effective rows prescribed by the v1
protocol, and returns a canonical-JSON-compatible bundle.  Invalid transition
shapes raise :class:`AnalysisError`; no partial bundle is returned.
"""

from __future__ import annotations

from collections import Counter
import hashlib
import json
import re
from typing import Any, Iterable


ANALYSIS_VERSION = "readability-analysis-input-v1"
PROTOCOL_VERSION = "readability-protocol-v1"
HUMAN_SCHEDULE_VERSION = "readability-human-schedule-v1"
HUMAN_SCHEDULE_SHA256 = (
    "356f000ba5af0421ef6eaaf246bbb78527ff9ffb97f61d84f5f795d96b114178"
)
MODEL_SCHEDULE_VERSION = "readability-model-schedule-v1"
CARRIERS = ("jac", "jqd", "python")
HEX_SHA256 = re.compile(r"[0-9a-f]{64}")


class AnalysisError(RuntimeError):
    """Raised when validated-store assumptions cannot produce one exact bundle."""


def _canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    )


def encode_analysis_bundle(bundle: dict[str, Any]) -> str:
    """Return canonical JSON plus one newline for a prepared analysis bundle.

    The encoder rejects non-JSON numeric values through ``allow_nan=False``.
    Given an equal bundle, it always returns byte-identical UTF-8-compatible
    text and never adds a timestamp.
    """

    return _canonical_json(bundle) + "\n"


def _field(row: dict[str, Any], name: str) -> Any:
    if name not in row:
        raise AnalysisError(f"analysis row is missing required field: {name}")
    return row[name]


def _unique_values(rows: Iterable[dict[str, Any]], name: str) -> list[Any]:
    values: dict[str, Any] = {}
    for row in rows:
        value = _field(row, name)
        values[_canonical_json(value)] = value
    return [values[key] for key in sorted(values)]


def _single_value(rows: list[dict[str, Any]], name: str) -> Any:
    values = _unique_values(rows, name)
    if len(values) != 1:
        raise AnalysisError(f"analysis store has multiple values for {name}")
    return values[0]


def _ordered_subject_groups(
    rows: list[dict[str, Any]],
) -> list[list[dict[str, Any]]]:
    groups: list[list[dict[str, Any]]] = []
    indexes: dict[str, int] = {}
    for row in rows:
        subject_id = _field(row, "subject_id")
        if not isinstance(subject_id, str):
            raise AnalysisError("analysis subject_id must be a string")
        if subject_id not in indexes:
            indexes[subject_id] = len(groups)
            groups.append([])
        elif indexes[subject_id] != len(groups) - 1:
            raise AnalysisError("analysis subject rows are not contiguous")
        groups[indexes[subject_id]].append(row)
    return groups


def _row_ids(rows: Iterable[dict[str, Any]]) -> list[str]:
    ids: list[str] = []
    for row in rows:
        row_id = _field(row, "row_id")
        if not isinstance(row_id, str) or HEX_SHA256.fullmatch(row_id) is None:
            raise AnalysisError("analysis row_id must be a lowercase SHA-256")
        ids.append(row_id)
    return ids


def _trial_reference(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "job": _field(row, "job"),
        "outcome_family": _field(row, "outcome_family"),
        "presentation_order": _field(row, "presentation_order"),
        "row_id": _field(row, "row_id"),
        "trial_attempt": _field(row, "trial_attempt"),
    }


def _human_decision(group: list[dict[str, Any]]) -> dict[str, Any]:
    first_attempts = [row for row in group if _field(row, "trial_attempt") == 1]
    retries = [row for row in group if _field(row, "trial_attempt") == 2]
    first_attempts.sort(key=lambda row: _field(row, "presentation_order"))
    system_failures = sum(
        _field(row, "error_code") == "system-failure" for row in group
    )
    stable_codes = sorted(
        {
            code
            for row in group
            for code in _field(row, "exclusion_codes")
            if code != "system-failure"
        }
    )
    subject_codes = list(stable_codes)
    if system_failures > 1:
        subject_codes.append("system-failure")
        subject_codes.sort()

    effective: list[dict[str, Any]] = []
    if not subject_codes:
        retry_by_job = {_field(row, "job"): row for row in retries}
        for first in first_attempts:
            if _field(first, "error_code") == "system-failure":
                selected = retry_by_job.get(_field(first, "job"))
                if selected is None or _field(selected, "error_code") == "system-failure":
                    raise AnalysisError(
                        "analyzable human system failure lacks a successful final retry"
                    )
            else:
                selected = first
            if _field(selected, "excluded"):
                raise AnalysisError("an analyzable human trial remains row-excluded")
            effective.append(selected)
        if len(effective) != 5:
            raise AnalysisError("an analyzable human must contribute five effective trials")

    effective_ids = _row_ids(effective)
    effective_set = set(effective_ids)
    excluded = [row for row in group if _field(row, "row_id") not in effective_set]
    source_ids = _row_ids(group)
    excluded_ids = _row_ids(excluded)
    return {
        "analyzable": not subject_codes,
        "carrier": _single_value(group, "carrier"),
        "effective_row_ids": effective_ids,
        "effective_trials": [_trial_reference(row) for row in effective],
        "excluded_row_ids": excluded_ids,
        "schedule_ordinal": _single_value(group, "schedule_ordinal"),
        "source_row_ids": source_ids,
        "subject_exclusion_codes": subject_codes,
        "subject_id": _single_value(group, "subject_id"),
        "system_failure_count": system_failures,
    }


def _single_session_decision(
    group: list[dict[str, Any]], subject_kind: str
) -> dict[str, Any]:
    if subject_kind == "model" and len(group) != 1:
        raise AnalysisError("each model subject must identify exactly one fresh session")
    subject_codes = sorted(
        {code for row in group for code in _field(row, "exclusion_codes")}
    )
    excluded_flags = {_field(row, "excluded") for row in group}
    if excluded_flags - {True, False}:
        raise AnalysisError("analysis excluded flags must be booleans")
    if subject_codes and not all(excluded_flags):
        raise AnalysisError("excluded session rows do not share their exclusion decision")
    if not subject_codes and any(excluded_flags):
        raise AnalysisError("session row is excluded without an exclusion code")
    effective = [] if subject_codes else list(group)
    effective_ids = _row_ids(effective)
    effective_set = set(effective_ids)
    excluded = [row for row in group if _field(row, "row_id") not in effective_set]
    return {
        "analyzable": not subject_codes,
        "carrier": _single_value(group, "carrier"),
        "effective_row_ids": effective_ids,
        "effective_trials": [_trial_reference(row) for row in effective],
        "excluded_row_ids": _row_ids(excluded),
        "schedule_ordinal": _single_value(group, "schedule_ordinal"),
        "source_row_ids": _row_ids(group),
        "subject_exclusion_codes": subject_codes,
        "subject_id": _single_value(group, "subject_id"),
        "system_failure_count": sum(
            _field(row, "error_code") == "system-failure" for row in group
        ),
    }


def _counter_dict(values: Iterable[str]) -> dict[str, int]:
    counts = Counter(values)
    return {key: counts[key] for key in sorted(counts)}


def _flow_for(
    rows: list[dict[str, Any]], decisions: list[dict[str, Any]]
) -> dict[str, Any]:
    effective_ids = {
        row_id for decision in decisions for row_id in decision["effective_row_ids"]
    }
    excluded_ids = {
        row_id for decision in decisions for row_id in decision["excluded_row_ids"]
    }
    source_ids = set(_row_ids(rows))
    if effective_ids.intersection(excluded_ids) or effective_ids.union(excluded_ids) != source_ids:
        raise AnalysisError("analysis decisions do not partition every source row exactly once")
    return {
        "row_exclusion_counts": _counter_dict(
            code for row in rows for code in _field(row, "exclusion_codes")
        ),
        "subject_exclusion_counts": _counter_dict(
            code
            for decision in decisions
            for code in decision["subject_exclusion_codes"]
        ),
        "subjects": {
            "analyzable": sum(decision["analyzable"] for decision in decisions),
            "answer_store": len(decisions),
            "excluded": sum(not decision["analyzable"] for decision in decisions),
        },
        "trials": {
            "effective_retry_rows": sum(
                _field(row, "row_id") in effective_ids
                and _field(row, "trial_attempt") == 2
                for row in rows
            ),
            "effective_rows": len(effective_ids),
            "excluded_rows": len(excluded_ids),
            "missing_expected_rows": 0,
            "source_retries": sum(_field(row, "trial_attempt") == 2 for row in rows),
            "source_rows": len(rows),
            "system_failure_rows": sum(
                _field(row, "error_code") == "system-failure" for row in rows
            ),
            "timeout_rows": sum(_field(row, "error_code") == "timeout" for row in rows),
        },
    }


def _flow(
    rows: list[dict[str, Any]], decisions: list[dict[str, Any]]
) -> dict[str, Any]:
    by_carrier: dict[str, Any] = {}
    for carrier in CARRIERS:
        carrier_rows = [row for row in rows if _field(row, "carrier") == carrier]
        carrier_decisions = [
            decision for decision in decisions if decision["carrier"] == carrier
        ]
        if carrier_rows:
            by_carrier[carrier] = _flow_for(carrier_rows, carrier_decisions)
    return {"by_carrier": by_carrier, "overall": _flow_for(rows, decisions)}


def _fixture_pins(rows: list[dict[str, Any]]) -> dict[str, str]:
    pins: dict[str, str] = {}
    for row in rows:
        condition = _field(row, "condition_id")
        fixture_sha256 = _field(row, "fixture_sha256")
        if condition in pins and pins[condition] != fixture_sha256:
            raise AnalysisError(f"analysis fixture pin drift for {condition}")
        pins[condition] = fixture_sha256
    return {condition: pins[condition] for condition in sorted(pins)}


def _observed_model_pins(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    names = (
        "cohort_id",
        "cohort_manifest_sha256",
        "provider",
        "model_id",
        "client_name",
        "client_version",
        "control_kind",
        "control_value",
        "prompt_sha256",
        "training_cutoff_attested",
    )
    variants: dict[str, dict[str, Any]] = {}
    for row in rows:
        model = _field(row, "model")
        if not isinstance(model, dict):
            raise AnalysisError("model analysis row lacks its model pin record")
        variant = {name: _field(model, name) for name in names}
        variants[_canonical_json(variant)] = variant
    return [variants[key] for key in sorted(variants)]


def _source_provenance(
    rows: list[dict[str, Any]], subject_kind: str, input_sha256: str
) -> dict[str, Any]:
    row_ids = _row_ids(rows)
    provenance: dict[str, Any] = {
        "assignment_seed_sha256": _single_value(rows, "assignment_seed_sha256"),
        "authority_manifest_sha256": _single_value(
            rows, "authority_manifest_sha256"
        ),
        "fixture_manifest_sha256": _single_value(
            rows, "fixture_manifest_sha256"
        ),
        "fixture_sha256_by_condition": _fixture_pins(rows),
        "input_jsonl_sha256": input_sha256,
        "row_count": len(rows),
        "row_id_sequence_sha256": hashlib.sha256(
            ("\n".join(row_ids) + "\n").encode("ascii")
        ).hexdigest(),
        "schema_sha256": _single_value(rows, "schema_sha256"),
        "schema_version": _single_value(rows, "schema_version"),
        "source_row_ids": row_ids,
    }
    if subject_kind == "human":
        provenance["consent_versions"] = _unique_values(rows, "consent_version")
        provenance["schedule"] = {
            "schema_version": HUMAN_SCHEDULE_VERSION,
            "sha256": HUMAN_SCHEDULE_SHA256,
        }
    elif subject_kind == "model":
        models = [_field(row, "model") for row in rows]
        cohort_ids = {_field(model, "cohort_id") for model in models}
        cohort_digests = {
            _field(model, "cohort_manifest_sha256") for model in models
        }
        if len(cohort_ids) != 1 or len(cohort_digests) != 1:
            raise AnalysisError("model analysis store mixes cohort identity")
        provenance["observed_model_pins"] = _observed_model_pins(rows)
        provenance["schedule"] = {
            "cohort_id": next(iter(cohort_ids)),
            "cohort_manifest_sha256": next(iter(cohort_digests)),
            "derivation": "validated-cohort-fixture-and-assignment-pins",
            "ordinal_count": len(rows),
            "schema_version": MODEL_SCHEDULE_VERSION,
        }
    else:
        provenance["schedule"] = {
            "condition_count": len(provenance["fixture_sha256_by_condition"]),
            "kind": "synthetic-dry-run",
        }
    return provenance


def prepare_analysis_bundle(
    rows: list[dict[str, Any]], input_sha256: str
) -> dict[str, Any]:
    """Prepare deterministic row selection and provenance for one valid store.

    ``rows`` must first pass the complete single-kind result-store validator;
    ``input_sha256`` must be the digest of the exact JSONL bytes that produced
    them.  Human subjects with more than one verified system-failure row are
    excluded as a whole.  Exactly one failed first attempt is replaced by its
    non-system-failure final retry.  Stable human exclusions exclude the whole
    subject; model sessions are effective exactly when their row is not
    excluded.  Synthetic bundles are always marked non-citable.

    The function returns no outcome statistic and no claim.  It raises
    :class:`AnalysisError` rather than returning a partial or ambiguous bundle.
    """

    if not isinstance(rows, list) or not rows:
        raise AnalysisError("analysis requires one validated nonempty result store")
    if any(not isinstance(row, dict) for row in rows):
        raise AnalysisError("analysis rows must be JSON objects")
    if not isinstance(input_sha256, str) or HEX_SHA256.fullmatch(input_sha256) is None:
        raise AnalysisError("analysis input digest must be a lowercase SHA-256")
    row_ids = _row_ids(rows)
    if len(set(row_ids)) != len(row_ids):
        raise AnalysisError("analysis source row IDs must be unique")

    protocol_version = _single_value(rows, "protocol_version")
    if protocol_version != PROTOCOL_VERSION:
        raise AnalysisError("analysis protocol version drifted")
    subject_kind = _single_value(rows, "subject_kind")
    run_kind = _single_value(rows, "run_kind")
    if subject_kind not in {"human", "model", "synthetic"}:
        raise AnalysisError(f"unknown analysis subject kind: {subject_kind}")
    expected_run_kind = {
        "human": "confirmatory",
        "synthetic": "dry-run",
    }.get(subject_kind)
    if expected_run_kind is not None and run_kind != expected_run_kind:
        raise AnalysisError("analysis run kind disagrees with its subject kind")

    groups = _ordered_subject_groups(rows)
    if subject_kind == "human":
        decisions = [_human_decision(group) for group in groups]
        evidence_class = "human-candidate"
        pre_assignment_flow = {
            "included_in_answer_store": False,
            "reason": "consent and eligibility records remain outside answer JSONL",
            "status": "external-required",
        }
    else:
        decisions = [
            _single_session_decision(group, subject_kind) for group in groups
        ]
        evidence_class = (
            "model-candidate" if subject_kind == "model" else "synthetic-non-citable"
        )
        pre_assignment_flow = {"status": "not-applicable"}

    return {
        "analysis_version": ANALYSIS_VERSION,
        "bundle_scope": "answer-store-analyzability",
        "claim_status": "not-evaluated",
        "evidence_class": evidence_class,
        "flow": _flow(rows, decisions),
        "pre_assignment_flow": pre_assignment_flow,
        "protocol_version": protocol_version,
        "run_kind": run_kind,
        "source": _source_provenance(rows, subject_kind, input_sha256),
        "subject_kind": subject_kind,
        "subjects": decisions,
    }
