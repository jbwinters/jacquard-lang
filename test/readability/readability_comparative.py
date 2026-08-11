"""Deterministic comparative summaries for validated readability evidence.

The public entry point consumes a complete store and its exact
``readability-analysis-input-v1`` selection.  It compares only ``.jac`` with
``.jqd``; Python remains descriptive context, model stores are refused, and
synthetic stores remain non-citable.  The output contains effect estimates and
prespecified uncertainty, never an automatic readability or product verdict.
"""

from __future__ import annotations

from collections import defaultdict
import hashlib
import json
import math
import re
from statistics import NormalDist
from typing import Any, Iterable

from readability_descriptive import (
    DescriptiveError,
    encode_descriptive_bundle,
    prepare_descriptive_bundle,
)


COMPARATIVE_VERSION = "readability-comparative-v1"
ANALYSIS_INPUT_VERSION = "readability-analysis-input-v1"
DESCRIPTIVE_VERSION = "readability-descriptive-v1"
FUNCTIONAL_OUTCOMES = (
    "comprehension",
    "review",
    "defect-detection",
    "modification-debugging",
    "diagnostic-recovery",
)
JACQUARD_CARRIERS = ("jac", "jqd")
HEX_SHA256 = re.compile(r"[0-9a-f]{64}")
DECIMAL_PLACES = 12
ACCURACY_FAMILY_ALPHA = 0.025
ACCURACY_COMPARISONS = len(FUNCTIONAL_OUTCOMES)
ACCURACY_PER_COMPARISON_ALPHA = ACCURACY_FAMILY_ALPHA / ACCURACY_COMPARISONS
TIME_ALPHA = 0.025
ACCURACY_Z = NormalDist().inv_cdf(1.0 - (ACCURACY_PER_COMPARISON_ALPHA / 2.0))


class ComparativeError(RuntimeError):
    """Raised when checked evidence cannot form one exact comparison bundle."""


def _canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    )


def encode_comparative_bundle(bundle: dict[str, Any]) -> str:
    """Return canonical JSON plus one newline for a comparison bundle.

    Derived decimals are fixed-width strings and the bundle carries no
    timestamp, so equal validated input produces byte-identical output.
    """

    return _canonical_json(bundle) + "\n"


def _field(row: dict[str, Any], name: str) -> Any:
    if name not in row:
        raise ComparativeError(f"comparative row is missing required field: {name}")
    return row[name]


def _decimal(value: float) -> str:
    if not math.isfinite(value):
        raise ComparativeError("comparative statistic is not finite")
    rounded = 0.0 if abs(value) < 0.5 * (10**-DECIMAL_PLACES) else value
    return f"{rounded:.{DECIMAL_PLACES}f}"


def _fraction(numerator: int, denominator: int) -> str:
    if denominator <= 0:
        raise ComparativeError("comparative proportion has no observations")
    return _decimal(numerator / denominator)


def _wilson_bounds(correct: int, rows: int, z: float) -> tuple[float, float]:
    if rows <= 0 or not 0 <= correct <= rows:
        raise ComparativeError("comparative Wilson inputs are invalid")
    estimate = correct / rows
    z_squared = z * z
    denominator = 1.0 + (z_squared / rows)
    center = (estimate + (z_squared / (2.0 * rows))) / denominator
    half_width = (
        z
        * math.sqrt(
            (estimate * (1.0 - estimate) / rows)
            + (z_squared / (4.0 * rows * rows))
        )
        / denominator
    )
    return max(0.0, center - half_width), min(1.0, center + half_width)


def _newcombe_interval(
    jac_correct: int, jac_rows: int, jqd_correct: int, jqd_rows: int
) -> tuple[float, float, float]:
    jac_estimate = jac_correct / jac_rows
    jqd_estimate = jqd_correct / jqd_rows
    difference = jac_estimate - jqd_estimate
    jac_lower, jac_upper = _wilson_bounds(jac_correct, jac_rows, ACCURACY_Z)
    jqd_lower, jqd_upper = _wilson_bounds(jqd_correct, jqd_rows, ACCURACY_Z)
    lower = difference - math.sqrt(
        ((jac_estimate - jac_lower) ** 2) + ((jqd_upper - jqd_estimate) ** 2)
    )
    upper = difference + math.sqrt(
        ((jac_upper - jac_estimate) ** 2) + ((jqd_estimate - jqd_lower) ** 2)
    )
    return difference, max(-1.0, lower), min(1.0, upper)


def _pooled_score_p_value(
    jac_correct: int, jac_rows: int, jqd_correct: int, jqd_rows: int
) -> float:
    jac_estimate = jac_correct / jac_rows
    jqd_estimate = jqd_correct / jqd_rows
    pooled = (jac_correct + jqd_correct) / (jac_rows + jqd_rows)
    variance = pooled * (1.0 - pooled) * ((1.0 / jac_rows) + (1.0 / jqd_rows))
    if variance == 0.0:
        if jac_estimate != jqd_estimate:
            raise ComparativeError("zero pooled variance disagrees with accuracy estimates")
        return 1.0
    score = (jac_estimate - jqd_estimate) / math.sqrt(variance)
    return min(1.0, max(0.0, 2.0 * NormalDist().cdf(-abs(score))))


def _holm_adjust(raw_values: list[float]) -> list[float]:
    if not raw_values or any(
        not math.isfinite(value) or not 0.0 <= value <= 1.0
        for value in raw_values
    ):
        raise ComparativeError("Holm adjustment requires finite p-values from zero to one")
    ordered = sorted(range(len(raw_values)), key=lambda index: (raw_values[index], index))
    adjusted = [0.0] * len(raw_values)
    running = 0.0
    count = len(raw_values)
    for rank, index in enumerate(ordered):
        candidate = min(1.0, (count - rank) * raw_values[index])
        running = max(running, candidate)
        adjusted[index] = running
    return adjusted


def _beta_fraction(a: float, b: float, value: float) -> float:
    maximum_iterations = 240
    epsilon = 3.0e-14
    minimum = 1.0e-300
    total = a + b
    a_plus = a + 1.0
    a_minus = a - 1.0
    c_value = 1.0
    d_value = 1.0 - (total * value / a_plus)
    if abs(d_value) < minimum:
        d_value = minimum
    d_value = 1.0 / d_value
    result = d_value
    for iteration in range(1, maximum_iterations + 1):
        doubled = 2 * iteration
        coefficient = (
            iteration
            * (b - iteration)
            * value
            / ((a_minus + doubled) * (a + doubled))
        )
        d_value = 1.0 + (coefficient * d_value)
        if abs(d_value) < minimum:
            d_value = minimum
        c_value = 1.0 + (coefficient / c_value)
        if abs(c_value) < minimum:
            c_value = minimum
        d_value = 1.0 / d_value
        result *= d_value * c_value

        coefficient = -(
            (a + iteration)
            * (total + iteration)
            * value
            / ((a + doubled) * (a_plus + doubled))
        )
        d_value = 1.0 + (coefficient * d_value)
        if abs(d_value) < minimum:
            d_value = minimum
        c_value = 1.0 + (coefficient / c_value)
        if abs(c_value) < minimum:
            c_value = minimum
        d_value = 1.0 / d_value
        change = d_value * c_value
        result *= change
        if abs(change - 1.0) <= epsilon:
            return result
    raise ComparativeError("regularized beta continued fraction did not converge")


def _regularized_beta(value: float, a: float, b: float) -> float:
    if not 0.0 <= value <= 1.0 or a <= 0.0 or b <= 0.0:
        raise ComparativeError("regularized beta inputs are outside their domain")
    if value == 0.0:
        return 0.0
    if value == 1.0:
        return 1.0
    factor = math.exp(
        math.lgamma(a + b)
        - math.lgamma(a)
        - math.lgamma(b)
        + (a * math.log(value))
        + (b * math.log1p(-value))
    )
    if value < (a + 1.0) / (a + b + 2.0):
        return factor * _beta_fraction(a, b, value) / a
    return 1.0 - (factor * _beta_fraction(b, a, 1.0 - value) / b)


def _student_t_cdf(value: float, degrees_of_freedom: float) -> float:
    if not math.isfinite(value) or not math.isfinite(degrees_of_freedom):
        raise ComparativeError("Student t inputs must be finite")
    if degrees_of_freedom <= 0.0:
        raise ComparativeError("Student t degrees of freedom must be positive")
    if value == 0.0:
        return 0.5
    beta_value = degrees_of_freedom / (
        degrees_of_freedom + (value * value)
    )
    tail = 0.5 * _regularized_beta(beta_value, degrees_of_freedom / 2.0, 0.5)
    return 1.0 - tail if value > 0.0 else tail


def _student_t_quantile(probability: float, degrees_of_freedom: float) -> float:
    if not 0.0 < probability < 1.0:
        raise ComparativeError("Student t probability must be strictly between zero and one")
    if probability == 0.5:
        return 0.0
    if probability < 0.5:
        return -_student_t_quantile(1.0 - probability, degrees_of_freedom)
    lower = 0.0
    upper = 1.0
    while _student_t_cdf(upper, degrees_of_freedom) < probability:
        upper *= 2.0
        if upper > 1.0e12:
            raise ComparativeError("Student t quantile search did not find an upper bound")
    for _ in range(120):
        middle = (lower + upper) / 2.0
        if _student_t_cdf(middle, degrees_of_freedom) < probability:
            lower = middle
        else:
            upper = middle
    return (lower + upper) / 2.0


def verify_comparative_methods() -> None:
    """Check bounded hand-derived pins for the statistical primitives.

    Failures raise :class:`ComparativeError`; this helper performs no I/O and
    does not inspect or generate study evidence.
    """

    one_df = _student_t_quantile(0.9875, 1.0)
    expected_one_df = math.tan(math.pi * (0.9875 - 0.5))
    if abs(one_df - expected_one_df) > 1.0e-10:
        raise ComparativeError("Student t quantile drifted from the analytic df=1 result")
    two_df = _student_t_quantile(0.9875, 2.0)
    centered_probability = (2.0 * 0.9875) - 1.0
    expected_two_df = (
        math.sqrt(2.0)
        * centered_probability
        / math.sqrt(1.0 - (centered_probability * centered_probability))
    )
    if abs(two_df - expected_two_df) > 1.0e-10:
        raise ComparativeError("Student t quantile drifted from the analytic df=2 result")
    adjusted = _holm_adjust([0.01, 0.04, 0.03, 0.002, 0.005])
    if any(
        abs(observed - expected) > 1.0e-15
        for observed, expected in zip(adjusted, [0.03, 0.06, 0.06, 0.01, 0.02])
    ):
        raise ComparativeError("Holm adjustment drifted from the hand-derived example")
    _, lower, upper = _newcombe_interval(90, 100, 70, 100)
    if abs(lower - 0.04050718010598) > 1.0e-14 or abs(
        upper - 0.3505105019724275
    ) > 1.0e-14:
        raise ComparativeError("Newcombe method-10 interval drifted from its pinned example")


def _effective_selection(
    rows: list[dict[str, Any]], input_sha256: str, analysis: dict[str, Any]
) -> tuple[list[dict[str, Any]], dict[str, Any], str]:
    try:
        descriptive = prepare_descriptive_bundle(rows, input_sha256, analysis)
    except DescriptiveError as error:
        raise ComparativeError(
            f"comparative rows cannot reproduce descriptive input: {error}"
        ) from error
    source = descriptive.get("source")
    if not isinstance(source, dict):
        raise ComparativeError("comparative descriptive source is missing")
    effective_ids = source.get("effective_row_ids")
    if not isinstance(effective_ids, list) or any(
        not isinstance(row_id, str) or HEX_SHA256.fullmatch(row_id) is None
        for row_id in effective_ids
    ):
        raise ComparativeError("comparative effective row identities are malformed")
    effective_set = set(effective_ids)
    if len(effective_set) != len(effective_ids):
        raise ComparativeError("comparative effective row identities are duplicated")
    effective_rows = [
        row for row in rows if _field(row, "row_id") in effective_set
    ]
    if [_field(row, "row_id") for row in effective_rows] != effective_ids:
        raise ComparativeError("comparative effective rows disagree with selected order")
    descriptive_sha256 = hashlib.sha256(
        encode_descriptive_bundle(descriptive).encode("utf-8")
    ).hexdigest()
    return effective_rows, descriptive, descriptive_sha256


def _carrier_accuracy(rows: Iterable[dict[str, Any]]) -> dict[str, Any]:
    values = [_field(row, "correct") for row in rows]
    if not values or any(not isinstance(value, bool) for value in values):
        raise ComparativeError("comparative accuracy requires Boolean observations")
    correct = sum(values)
    return {
        "correct": correct,
        "estimate": _fraction(correct, len(values)),
        "rows": len(values),
    }


def _accuracy_summaries(effective_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in effective_rows:
        carrier = _field(row, "carrier")
        family = _field(row, "outcome_family")
        if carrier in JACQUARD_CARRIERS:
            if family not in FUNCTIONAL_OUTCOMES:
                raise ComparativeError("comparative row has an unknown functional outcome")
            grouped[(family, carrier)].append(row)
    summaries: list[dict[str, Any]] = []
    raw_p_values: list[float] = []
    for family in FUNCTIONAL_OUTCOMES:
        jac_rows = grouped.get((family, "jac"), [])
        jqd_rows = grouped.get((family, "jqd"), [])
        jac = _carrier_accuracy(jac_rows)
        jqd = _carrier_accuracy(jqd_rows)
        jobs = {
            _field(row, "job") for row in [*jac_rows, *jqd_rows]
        }
        if len(jobs) != 1:
            raise ComparativeError("comparative outcome does not map to exactly one job")
        difference, lower, upper = _newcombe_interval(
            jac["correct"], jac["rows"], jqd["correct"], jqd["rows"]
        )
        raw_p = _pooled_score_p_value(
            jac["correct"], jac["rows"], jqd["correct"], jqd["rows"]
        )
        raw_p_values.append(raw_p)
        summaries.append(
            {
                "accuracy": {"jac": jac, "jqd": jqd},
                "difference_jac_minus_jqd": _decimal(difference),
                "job": next(iter(jobs)),
                "newcombe_interval": {
                    "confidence_level": _decimal(
                        1.0 - ACCURACY_PER_COMPARISON_ALPHA
                    ),
                    "lower": _decimal(lower),
                    "upper": _decimal(upper),
                },
                "outcome_family": family,
                "pooled_score_two_sided_p": _decimal(raw_p),
            }
        )
    for summary, adjusted in zip(summaries, _holm_adjust(raw_p_values)):
        summary["holm_adjusted_p"] = _decimal(adjusted)
    return summaries


def _subject_log_means(
    effective_rows: list[dict[str, Any]],
) -> tuple[dict[str, list[float]], dict[str, int], dict[str, int]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in effective_rows:
        carrier = _field(row, "carrier")
        if carrier in JACQUARD_CARRIERS:
            subject_id = _field(row, "subject_id")
            if not isinstance(subject_id, str):
                raise ComparativeError("comparative subject identifier must be a string")
            grouped[subject_id].append(row)
    log_means = {carrier: [] for carrier in JACQUARD_CARRIERS}
    nonpositive = {carrier: 0 for carrier in JACQUARD_CARRIERS}
    subject_counts = {carrier: 0 for carrier in JACQUARD_CARRIERS}
    for subject_rows in grouped.values():
        carriers = {_field(row, "carrier") for row in subject_rows}
        if len(carriers) != 1:
            raise ComparativeError("comparative subject crosses carriers")
        carrier = next(iter(carriers))
        by_family: dict[str, dict[str, Any]] = {}
        for row in subject_rows:
            family = _field(row, "outcome_family")
            if family in by_family or family not in FUNCTIONAL_OUTCOMES:
                raise ComparativeError("comparative subject has duplicate or unknown outcomes")
            by_family[family] = row
        if set(by_family) != set(FUNCTIONAL_OUTCOMES):
            raise ComparativeError("comparative subject lacks a functional outcome")
        subject_counts[carrier] += 1
        values: list[int] = []
        for family in FUNCTIONAL_OUTCOMES:
            value = _field(by_family[family], "completion_ms")
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ComparativeError(
                    "comparative completion_ms must be a nonnegative integer"
                )
            values.append(value)
        nonpositive[carrier] += sum(value <= 0 for value in values)
        if all(value > 0 for value in values):
            log_means[carrier].append(
                math.fsum(math.log(value) for value in values) / len(values)
            )
    return log_means, nonpositive, subject_counts


def _mean(values: list[float]) -> float:
    return math.fsum(values) / len(values)


def _sample_variance(values: list[float], mean: float) -> float:
    return math.fsum((value - mean) ** 2 for value in values) / (len(values) - 1)


def _completion_time_summary(effective_rows: list[dict[str, Any]]) -> dict[str, Any]:
    log_means, nonpositive, subject_counts = _subject_log_means(effective_rows)
    log_counts = {carrier: len(log_means[carrier]) for carrier in JACQUARD_CARRIERS}
    base: dict[str, Any] = {
        "carrier_subjects": subject_counts,
        "log_summary_subjects": log_counts,
        "nonpositive_rows": nonpositive,
    }
    if any(nonpositive.values()):
        return {
            **base,
            "confidence_interval": None,
            "log_difference_jac_minus_jqd": None,
            "ratio_jac_over_jqd": None,
            "status": "nonpositive-observation",
        }
    jac_values = log_means["jac"]
    jqd_values = log_means["jqd"]
    if not jac_values or not jqd_values:
        raise ComparativeError("comparative time has no Jacquard carrier observations")
    jac_mean = _mean(jac_values)
    jqd_mean = _mean(jqd_values)
    difference = jac_mean - jqd_mean
    ratio = math.exp(difference)
    base.update(
        {
            "carrier_geometric_mean_ms": {
                "jac": _decimal(math.exp(jac_mean)),
                "jqd": _decimal(math.exp(jqd_mean)),
            },
            "log_difference_jac_minus_jqd": _decimal(difference),
            "ratio_jac_over_jqd": _decimal(ratio),
        }
    )
    if len(jac_values) < 2 or len(jqd_values) < 2:
        return {**base, "confidence_interval": None, "status": "insufficient-subjects"}
    jac_variance = _sample_variance(jac_values, jac_mean)
    jqd_variance = _sample_variance(jqd_values, jqd_mean)
    jac_component = jac_variance / len(jac_values)
    jqd_component = jqd_variance / len(jqd_values)
    standard_error_squared = jac_component + jqd_component
    if standard_error_squared == 0.0:
        return {**base, "confidence_interval": None, "status": "zero-variance"}
    denominator = (
        (jac_component * jac_component) / (len(jac_values) - 1)
        + (jqd_component * jqd_component) / (len(jqd_values) - 1)
    )
    if denominator <= 0.0:
        raise ComparativeError("Welch degrees-of-freedom denominator is invalid")
    degrees_of_freedom = (standard_error_squared * standard_error_squared) / denominator
    standard_error = math.sqrt(standard_error_squared)
    critical = _student_t_quantile(1.0 - (TIME_ALPHA / 2.0), degrees_of_freedom)
    lower_log = difference - (critical * standard_error)
    upper_log = difference + (critical * standard_error)
    return {
        **base,
        "confidence_interval": {
            "confidence_level": _decimal(1.0 - TIME_ALPHA),
            "degrees_of_freedom": _decimal(degrees_of_freedom),
            "lower_ratio": _decimal(math.exp(lower_log)),
            "standard_error_log": _decimal(standard_error),
            "upper_ratio": _decimal(math.exp(upper_log)),
        },
        "status": "available",
    }


def prepare_comparative_bundle(
    rows: list[dict[str, Any]], input_sha256: str, analysis: dict[str, Any]
) -> dict[str, Any]:
    """Build deterministic `.jac`/`.jqd` effect summaries.

    ``rows`` must already pass complete result-store validation and ``analysis``
    must be the exact analyzability bundle for the same source bytes.  Human
    output remains candidate evidence, synthetic output is non-citable, and
    model stores are refused.  The function returns no threshold verdict or
    readability claim and raises :class:`ComparativeError` on any provenance,
    selection, coverage, or numerical disagreement.
    """

    if not isinstance(rows, list) or not rows or any(
        not isinstance(row, dict) for row in rows
    ):
        raise ComparativeError("comparative analysis requires one nonempty object store")
    if not isinstance(input_sha256, str) or HEX_SHA256.fullmatch(input_sha256) is None:
        raise ComparativeError("comparative input digest must be a lowercase SHA-256")
    if not isinstance(analysis, dict):
        raise ComparativeError("comparative analysis input must be an object")
    effective_rows, descriptive, descriptive_sha256 = _effective_selection(
        rows, input_sha256, analysis
    )
    subject_kind = descriptive.get("subject_kind")
    if subject_kind == "model":
        raise ComparativeError("model stores cannot enter the human carrier comparison")
    if subject_kind not in {"human", "synthetic"}:
        raise ComparativeError("comparative subject kind is unknown")
    verify_comparative_methods()
    descriptive_source = descriptive["source"]
    return {
        "accuracy": _accuracy_summaries(effective_rows),
        "bundle_scope": "jac-versus-jqd-evidence-summary",
        "claim_status": "not-evaluated",
        "comparative_version": COMPARATIVE_VERSION,
        "completion_time": _completion_time_summary(effective_rows),
        "evidence_class": descriptive.get("evidence_class"),
        "flow": json.loads(_canonical_json(descriptive.get("flow"))),
        "interpretation": {
            "automatic_product_gate": "none",
            "minimum_human_count": None,
            "population_claim_rule": "report-actual-sample-uncertainty-and-limitations",
        },
        "methods": {
            "accuracy": {
                "effect": "jac-minus-jqd-correct-proportion",
                "family_alpha": _decimal(ACCURACY_FAMILY_ALPHA),
                "interval": "newcombe-method-10-no-continuity-correction",
                "interval_family_coverage": "nominal-bonferroni",
                "per_outcome_alpha": _decimal(ACCURACY_PER_COMPARISON_ALPHA),
                "p_adjustment": "holm",
                "p_value": "pooled-two-proportion-score-two-sided",
            },
            "completion_time": {
                "alpha": _decimal(TIME_ALPHA),
                "effect": "jac-over-jqd-geometric-mean-ratio",
                "interval": "welch-on-subject-log-means",
                "subject_summary": "geometric-mean-across-five-functional-jobs",
            },
        },
        "pre_assignment_flow": json.loads(
            _canonical_json(descriptive.get("pre_assignment_flow"))
        ),
        "protocol_version": descriptive.get("protocol_version"),
        "run_kind": descriptive.get("run_kind"),
        "source": {
            "analysis_input_sha256": descriptive_source["analysis_input_sha256"],
            "analysis_input_version": ANALYSIS_INPUT_VERSION,
            "descriptive_bundle_sha256": descriptive_sha256,
            "descriptive_version": DESCRIPTIVE_VERSION,
            "effective_row_count": descriptive_source["effective_row_count"],
            "effective_row_ids": descriptive_source["effective_row_ids"],
            "input_jsonl_sha256": input_sha256,
            "source_row_count": descriptive_source["source_row_count"],
            "source_row_ids": descriptive_source["source_row_ids"],
        },
        "subject_kind": subject_kind,
    }
