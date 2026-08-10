"""Deterministic descriptive tables for validated readability result stores.

The public entry point consumes rows only after complete result-store
validation and requires the exact effective-row selection emitted by
``readability-analysis-input-v1``.  It reports prespecified descriptive
summaries and strata, never an inferential comparison or readability claim.
Mismatched provenance or selection raises :class:`DescriptiveError`; no
partial table bundle is returned.
"""

from __future__ import annotations

from collections import Counter
import hashlib
import json
import math
import re
from typing import Any, Iterable

from readability_analysis import (
    AnalysisError,
    encode_analysis_bundle,
    prepare_analysis_bundle,
)


DESCRIPTIVE_VERSION = "readability-descriptive-v1"
ANALYSIS_INPUT_VERSION = "readability-analysis-input-v1"
CARRIERS = ("jac", "jqd", "python")
JOBS = (
    "seeded-bug",
    "predict-output",
    "authority-escalation",
    "modify-behavior",
    "diagnostic-recovery",
)
OUTCOME_FAMILIES = (
    "comprehension",
    "review",
    "defect-detection",
    "modification-debugging",
    "diagnostic-recovery",
)
HUMAN_PROFILE_FIELDS = (
    "programming_experience_years",
    "code_review_experience_years",
    "jacquard_familiarity",
    "functional_programming_familiarity",
)
HEX_SHA256 = re.compile(r"[0-9a-f]{64}")
DECIMAL_PLACES = 12
CONFIDENCE_LEVEL = 0.975
# Standard-normal quantile at 0.9875 for a two-sided alpha of 0.025.
WILSON_Z = 2.241402727604947


class DescriptiveError(RuntimeError):
    """Raised when checked rows and analysis selection cannot form one bundle."""


def _canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    )


def encode_descriptive_bundle(bundle: dict[str, Any]) -> str:
    """Return canonical JSON plus one newline for a descriptive bundle.

    Numeric summaries are fixed-width decimal strings, so equal validated
    inputs produce byte-identical output without timestamps or locale effects.
    Non-JSON numeric values are rejected by the canonical encoder.
    """

    return _canonical_json(bundle) + "\n"


def _field(row: dict[str, Any], name: str) -> Any:
    if name not in row:
        raise DescriptiveError(f"descriptive row is missing required field: {name}")
    return row[name]


def _decimal(value: float) -> str:
    if not math.isfinite(value):
        raise DescriptiveError("descriptive statistic is not finite")
    rounded = 0.0 if abs(value) < 0.5 * (10 ** -DECIMAL_PLACES) else value
    return f"{rounded:.{DECIMAL_PLACES}f}"


def _fraction(numerator: int, denominator: int) -> str | None:
    if denominator == 0:
        return None
    return _decimal(numerator / denominator)


def _median(values: list[int]) -> str | None:
    if not values:
        return None
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        value = float(ordered[middle])
    else:
        value = (ordered[middle - 1] + ordered[middle]) / 2
    return _decimal(value)


def _mean(values: list[int]) -> str | None:
    if not values:
        return None
    return _decimal(math.fsum(values) / len(values))


def _wilson(correct: int, rows: int) -> dict[str, Any]:
    if rows == 0:
        return {
            "confidence_level": _decimal(CONFIDENCE_LEVEL),
            "lower": None,
            "upper": None,
        }
    proportion = correct / rows
    z_squared = WILSON_Z * WILSON_Z
    denominator = 1 + z_squared / rows
    center = (proportion + z_squared / (2 * rows)) / denominator
    half_width = (
        WILSON_Z
        * math.sqrt(
            proportion * (1 - proportion) / rows
            + z_squared / (4 * rows * rows)
        )
        / denominator
    )
    return {
        "confidence_level": _decimal(CONFIDENCE_LEVEL),
        "lower": _decimal(max(0.0, center - half_width)),
        "upper": _decimal(min(1.0, center + half_width)),
    }


def _accuracy(rows: list[dict[str, Any]]) -> dict[str, Any]:
    correct_values = [_field(row, "correct") for row in rows]
    if any(not isinstance(value, bool) for value in correct_values):
        raise DescriptiveError("descriptive correctness values must be booleans")
    correct = sum(correct_values)
    return {
        "correct": correct,
        "estimate": _fraction(correct, len(rows)),
        "rows": len(rows),
        "wilson": _wilson(correct, len(rows)),
    }


def _completion(rows: list[dict[str, Any]]) -> dict[str, Any]:
    values = [_field(row, "completion_ms") for row in rows]
    if any(
        not isinstance(value, int) or isinstance(value, bool) or value < 0
        for value in values
    ):
        raise DescriptiveError("descriptive completion_ms values must be nonnegative integers")
    nonpositive = sum(value <= 0 for value in values)
    log_mean: str | None = None
    geometric_mean: str | None = None
    if values and nonpositive == 0:
        log_value = math.fsum(math.log(value) for value in values) / len(values)
        log_mean = _decimal(log_value)
        geometric_mean = _decimal(math.exp(log_value))
    return {
        "geometric_mean_ms": geometric_mean,
        "log_mean": log_mean,
        "maximum_ms": max(values) if values else None,
        "median_ms": _median(values),
        "minimum_ms": min(values) if values else None,
        "nonpositive_rows": nonpositive,
        "rows": len(values),
    }


def _confidence(rows: list[dict[str, Any]]) -> dict[str, Any]:
    values = [_field(row, "confidence") for row in rows]
    if any(
        not isinstance(value, int)
        or isinstance(value, bool)
        or not 0 <= value <= 100
        for value in values
    ):
        raise DescriptiveError("descriptive confidence values must be integers from 0 to 100")
    counts = Counter(values)
    calibration: list[dict[str, Any]] = []
    for confidence in sorted(counts):
        bucket = [row for row in rows if _field(row, "confidence") == confidence]
        correct = sum(_field(row, "correct") for row in bucket)
        calibration.append(
            {
                "accuracy": _fraction(correct, len(bucket)),
                "confidence": confidence,
                "correct": correct,
                "rows": len(bucket),
            }
        )
    return {
        "calibration": calibration,
        "distribution": [
            {"count": counts[value], "value": value} for value in sorted(counts)
        ],
        "mean": _mean(values),
        "rows": len(values),
    }


def _ratings(rows: list[dict[str, Any]]) -> dict[str, Any]:
    values = [_field(row, "perceived_readability") for row in rows]
    if any(
        not isinstance(value, int)
        or isinstance(value, bool)
        or not 1 <= value <= 7
        for value in values
    ):
        raise DescriptiveError(
            "descriptive perceived_readability values must be integers from 1 to 7"
        )
    counts = Counter(values)
    return {
        "distribution": [
            {"count": counts[value], "value": value} for value in range(1, 8)
        ],
        "mean": _mean(values),
        "median": _median(values),
        "rows": len(values),
    }


def _error_counts(rows: list[dict[str, Any]]) -> dict[str, int]:
    values = [_field(row, "error_code") for row in rows]
    if any(value is not None and not isinstance(value, str) for value in values):
        raise DescriptiveError("descriptive error_code values must be strings or null")
    counts = Counter(value for value in values if value is not None)
    return {value: counts[value] for value in sorted(counts)}


def _outcomes(rows: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "accuracy": _accuracy(rows),
        "completion_ms": _completion(rows),
        "confidence": _confidence(rows),
        "error_counts": _error_counts(rows),
        "perceived_readability": _ratings(rows),
        "timeout_rows": sum(_field(row, "error_code") == "timeout" for row in rows),
    }


def _condition_rows(
    rows: Iterable[dict[str, Any]],
) -> dict[tuple[str, str], list[dict[str, Any]]]:
    conditions: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for row in rows:
        carrier = _field(row, "carrier")
        job = _field(row, "job")
        if carrier not in CARRIERS or job not in JOBS:
            raise DescriptiveError("descriptive row has an unknown carrier or job")
        conditions.setdefault((carrier, job), []).append(row)
    return conditions


def _condition_base(
    source_rows: list[dict[str, Any]], effective_rows: list[dict[str, Any]]
) -> dict[str, Any]:
    first = source_rows[0]
    carrier = _field(first, "carrier")
    job = _field(first, "job")
    family = _field(first, "outcome_family")
    if any(
        (_field(row, "carrier"), _field(row, "job"), _field(row, "outcome_family"))
        != (carrier, job, family)
        for row in source_rows
    ):
        raise DescriptiveError("descriptive condition rows disagree on identity")
    return {
        "carrier": carrier,
        "effective_rows": len(effective_rows),
        "excluded_rows": len(source_rows) - len(effective_rows),
        "job": job,
        "outcome_family": family,
        "source_rows": len(source_rows),
    }


def _tables(
    source_rows: list[dict[str, Any]], effective_rows: list[dict[str, Any]]
) -> dict[str, list[dict[str, Any]]]:
    source = _condition_rows(source_rows)
    effective = _condition_rows(effective_rows)
    expected = {(carrier, job) for carrier in CARRIERS for job in JOBS}
    if set(source) != expected:
        raise DescriptiveError("descriptive source store does not cover all 15 conditions")

    perceived: list[dict[str, Any]] = []
    functional: dict[str, list[dict[str, Any]]] = {
        family: [] for family in OUTCOME_FAMILIES
    }
    for carrier in CARRIERS:
        for job in JOBS:
            condition = (carrier, job)
            source_condition = source[condition]
            effective_condition = effective.get(condition, [])
            base = _condition_base(source_condition, effective_condition)
            family = base["outcome_family"]
            if family not in functional:
                raise DescriptiveError("descriptive row has an unknown outcome family")
            perceived.append({**base, "ratings": _ratings(effective_condition)})
            functional[family].append(
                {**base, **_outcomes(effective_condition)}
            )
    return {"perceived-readability": perceived, **functional}


def _stratum_entry(
    keys: dict[str, Any], rows: list[dict[str, Any]]
) -> dict[str, Any]:
    return {**keys, **_outcomes(rows)}


def _presentation_order(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, int, str, str], list[dict[str, Any]]] = {}
    for row in rows:
        carrier = _field(row, "carrier")
        order = _field(row, "presentation_order")
        family = _field(row, "outcome_family")
        job = _field(row, "job")
        if not isinstance(order, int) or isinstance(order, bool) or not 1 <= order <= 5:
            raise DescriptiveError("descriptive presentation_order must be from 1 to 5")
        grouped.setdefault((carrier, order, family, job), []).append(row)
    return [
        _stratum_entry(
            {
                "carrier": carrier,
                "job": job,
                "outcome_family": family,
                "presentation_order": order,
            },
            grouped[(carrier, order, family, job)],
        )
        for carrier in CARRIERS
        for order in range(1, 6)
        for job in JOBS
        for family in OUTCOME_FAMILIES
        if (carrier, order, family, job) in grouped
    ]


def _subject_rows(
    rows: list[dict[str, Any]],
) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        subject_id = _field(row, "subject_id")
        if not isinstance(subject_id, str):
            raise DescriptiveError("descriptive subject_id must be a string")
        grouped.setdefault(subject_id, []).append(row)
    return grouped


def _human_expertise(
    source_rows: list[dict[str, Any]], analysis: dict[str, Any]
) -> dict[str, list[dict[str, Any]]]:
    grouped = _subject_rows(source_rows)
    counts: dict[str, Counter[tuple[str, int]]] = {
        field: Counter() for field in HUMAN_PROFILE_FIELDS
    }
    for decision in analysis["subjects"]:
        if not decision.get("analyzable"):
            continue
        subject_id = decision.get("subject_id")
        subject = grouped.get(subject_id)
        if not subject:
            raise DescriptiveError("an analyzable subject is absent from descriptive rows")
        carriers = {_field(row, "carrier") for row in subject}
        if len(carriers) != 1:
            raise DescriptiveError("descriptive human subject mixes carriers")
        carrier = next(iter(carriers))
        for field in HUMAN_PROFILE_FIELDS:
            values = {_field(row, field) for row in subject}
            if len(values) != 1:
                raise DescriptiveError(f"descriptive human subject mixes {field}")
            value = next(iter(values))
            if not isinstance(value, int) or isinstance(value, bool):
                raise DescriptiveError(f"descriptive human {field} must be an integer")
            counts[field][(carrier, value)] += 1
    return {
        field: [
            {"carrier": carrier, "subjects": counts[field][(carrier, value)], "value": value}
            for carrier in CARRIERS
            for value in sorted(
                observed
                for observed_carrier, observed in counts[field]
                if observed_carrier == carrier
            )
        ]
        for field in HUMAN_PROFILE_FIELDS
    }


def _human_profile_outcomes(
    rows: list[dict[str, Any]],
) -> dict[str, list[dict[str, Any]]]:
    output: dict[str, list[dict[str, Any]]] = {}
    for field in HUMAN_PROFILE_FIELDS:
        grouped: dict[tuple[str, int, str, str], list[dict[str, Any]]] = {}
        for row in rows:
            carrier = _field(row, "carrier")
            value = _field(row, field)
            family = _field(row, "outcome_family")
            job = _field(row, "job")
            if not isinstance(value, int) or isinstance(value, bool):
                raise DescriptiveError(f"descriptive human {field} must be an integer")
            grouped.setdefault((carrier, value, family, job), []).append(row)
        output[field] = [
            _stratum_entry(
                {
                    "carrier": carrier,
                    "job": job,
                    "outcome_family": family,
                    "value": value,
                },
                grouped[(carrier, value, family, job)],
            )
            for carrier in CARRIERS
            for value in sorted(
                {
                    observed
                    for observed_carrier, observed, _, _ in grouped
                    if observed_carrier == carrier
                }
            )
            for job in JOBS
            for family in OUTCOME_FAMILIES
            if (carrier, value, family, job) in grouped
        ]
    return output


def _selection(
    rows: list[dict[str, Any]], input_sha256: str, analysis: dict[str, Any]
) -> tuple[list[dict[str, Any]], str]:
    if (
        not isinstance(input_sha256, str)
        or HEX_SHA256.fullmatch(input_sha256) is None
    ):
        raise DescriptiveError("descriptive input digest must be a lowercase SHA-256")
    if not isinstance(analysis, dict):
        raise DescriptiveError("descriptive analysis input must be an object")
    if analysis.get("analysis_version") != ANALYSIS_INPUT_VERSION:
        raise DescriptiveError("descriptive analysis input version drifted")
    if analysis.get("claim_status") != "not-evaluated":
        raise DescriptiveError("descriptive analysis input already claims an outcome")
    try:
        expected_analysis = prepare_analysis_bundle(rows, input_sha256)
    except AnalysisError as error:
        raise DescriptiveError(
            f"descriptive rows cannot reproduce analysis input: {error}"
        ) from error
    analysis_bytes = encode_analysis_bundle(analysis).encode("utf-8")
    expected_bytes = encode_analysis_bundle(expected_analysis).encode("utf-8")
    if analysis_bytes != expected_bytes:
        raise DescriptiveError("descriptive analysis input is not the exact derived bundle")
    source = analysis.get("source")
    if not isinstance(source, dict) or source.get("input_jsonl_sha256") != input_sha256:
        raise DescriptiveError("descriptive source digest disagrees with analysis input")

    row_ids = [_field(row, "row_id") for row in rows]
    if any(
        not isinstance(row_id, str) or HEX_SHA256.fullmatch(row_id) is None
        for row_id in row_ids
    ):
        raise DescriptiveError("descriptive row IDs must be lowercase SHA-256 values")
    if len(set(row_ids)) != len(row_ids):
        raise DescriptiveError("descriptive source row IDs must be unique")
    if source.get("source_row_ids") != row_ids:
        raise DescriptiveError("descriptive source row sequence disagrees with analysis input")

    decisions = analysis.get("subjects")
    if not isinstance(decisions, list):
        raise DescriptiveError("descriptive analysis input lacks subject decisions")
    decision_source: list[str] = []
    effective_ids: list[str] = []
    excluded_ids: list[str] = []
    for decision in decisions:
        if not isinstance(decision, dict):
            raise DescriptiveError("descriptive subject decision must be an object")
        for name, destination in (
            ("source_row_ids", decision_source),
            ("effective_row_ids", effective_ids),
            ("excluded_row_ids", excluded_ids),
        ):
            values = decision.get(name)
            if not isinstance(values, list) or any(
                not isinstance(value, str) for value in values
            ):
                raise DescriptiveError(f"descriptive decision {name} is malformed")
            destination.extend(values)
    if decision_source != row_ids:
        raise DescriptiveError("descriptive subject decisions reorder source rows")
    if (
        len(effective_ids) != len(set(effective_ids))
        or len(excluded_ids) != len(set(excluded_ids))
        or set(effective_ids).intersection(excluded_ids)
        or set(effective_ids).union(excluded_ids) != set(row_ids)
    ):
        raise DescriptiveError("descriptive decisions do not partition source rows")

    effective_set = set(effective_ids)
    effective_rows = [row for row in rows if _field(row, "row_id") in effective_set]
    return effective_rows, hashlib.sha256(analysis_bytes).hexdigest()


def prepare_descriptive_bundle(
    rows: list[dict[str, Any]], input_sha256: str, analysis: dict[str, Any]
) -> dict[str, Any]:
    """Build deterministic descriptive tables for one validated result store.

    ``rows`` must first pass complete single-kind result-store validation, and
    ``analysis`` must be the exact ``readability-analysis-input-v1`` bundle for
    those source bytes.  Only its effective row IDs contribute outcome values;
    excluded rows remain visible through source/effective counts and copied
    flow evidence.  Human expertise and presentation-order strata are
    descriptive only.  The result contains no timestamp, inferential carrier
    comparison, threshold verdict, or readability claim.

    The function raises :class:`DescriptiveError` on provenance, selection,
    type, or coverage disagreement rather than returning partial statistics.
    """

    if not isinstance(rows, list) or not rows:
        raise DescriptiveError("descriptive analysis requires one nonempty store")
    if any(not isinstance(row, dict) for row in rows):
        raise DescriptiveError("descriptive rows must be JSON objects")
    effective_rows, analysis_sha256 = _selection(rows, input_sha256, analysis)
    subject_kind = analysis.get("subject_kind")
    if subject_kind not in {"human", "model", "synthetic"}:
        raise DescriptiveError("descriptive subject kind is unknown")
    if any(_field(row, "subject_kind") != subject_kind for row in rows):
        raise DescriptiveError("descriptive rows disagree with analysis subject kind")

    if subject_kind == "human":
        human_expertise: dict[str, list[dict[str, Any]]] | None = _human_expertise(
            rows, analysis
        )
        human_profile_outcomes: dict[str, list[dict[str, Any]]] | None = (
            _human_profile_outcomes(effective_rows)
        )
    else:
        human_expertise = None
        human_profile_outcomes = None

    row_ids = [_field(row, "row_id") for row in rows]
    effective_ids = [_field(row, "row_id") for row in effective_rows]
    return {
        "bundle_scope": "descriptive-outcomes",
        "claim_status": "not-evaluated",
        "descriptive_version": DESCRIPTIVE_VERSION,
        "evidence_class": analysis.get("evidence_class"),
        "flow": json.loads(_canonical_json(analysis.get("flow"))),
        "pre_assignment_flow": json.loads(
            _canonical_json(analysis.get("pre_assignment_flow"))
        ),
        "protocol_version": analysis.get("protocol_version"),
        "run_kind": analysis.get("run_kind"),
        "source": {
            "analysis_input_sha256": analysis_sha256,
            "analysis_input_version": ANALYSIS_INPUT_VERSION,
            "effective_row_count": len(effective_rows),
            "effective_row_ids": effective_ids,
            "input_jsonl_sha256": input_sha256,
            "source_row_count": len(rows),
            "source_row_ids": row_ids,
        },
        "strata": {
            "human_expertise": human_expertise,
            "human_profile_outcomes": human_profile_outcomes,
            "presentation_order": _presentation_order(effective_rows),
        },
        "subject_kind": subject_kind,
        "tables": _tables(rows, effective_rows),
    }
