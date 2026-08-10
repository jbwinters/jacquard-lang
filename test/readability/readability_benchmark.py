#!/usr/bin/env python3
"""Deterministic readability fixture verifier, planner, scorer, and dry runner.

The tool uses only the Python standard library.  It never collects participants
or calls a model.  Its UX.1 schedule commands emit de-identified execution
plans, not consent or study authority.  Invalid manifests, result rows, or
fixture evidence fail with a concise message and a nonzero exit status.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Callable, Iterable

from readability_analysis import (
    AnalysisError,
    encode_analysis_bundle,
    prepare_analysis_bundle,
)
from readability_descriptive import (
    DescriptiveError,
    encode_descriptive_bundle,
    prepare_descriptive_bundle,
)


SCHEMA_VERSION = "readability-result-v1"
PROTOCOL_VERSION = "readability-protocol-v1"
CARRIERS = ("jac", "jqd", "python")
JOBS = (
    "seeded-bug",
    "predict-output",
    "authority-escalation",
    "modify-behavior",
    "diagnostic-recovery",
)
RESERVED_ANSWER_IDS = frozenset(
    {"__timeout__", "__system_failure__", "__parse_failure__"}
)
HUMAN_PROFILE_FIELDS = (
    "programming_experience_years",
    "code_review_experience_years",
    "jacquard_familiarity",
    "functional_programming_familiarity",
)
SUPPORTED_SCHEMA_KEYS = frozenset(
    {
        "$schema",
        "$id",
        "title",
        "description",
        "type",
        "additionalProperties",
        "required",
        "properties",
        "const",
        "enum",
        "minimum",
        "maximum",
        "minLength",
        "maxLength",
        "pattern",
        "oneOf",
        "uniqueItems",
        "items",
        "allOf",
        "if",
        "then",
    }
)


def balanced_job_orders() -> tuple[tuple[str, ...], ...]:
    """Return the frozen ten-sequence Williams design for five jobs.

    Every job occurs twice in every position, and every ordered adjacent pair
    occurs twice.  That makes presentation order and first-order carryover
    estimable without exposing one participant to multiple carriers.
    """

    base = (0, 1, 4, 2, 3)
    orders: list[tuple[str, ...]] = []
    for shift in range(len(JOBS)):
        order = tuple(JOBS[(index + shift) % len(JOBS)] for index in base)
        orders.extend((order, tuple(reversed(order))))
    return tuple(orders)


JOB_ORDERS = balanced_job_orders()
FIXED_DRY_RUN_TIME = "2000-01-01T00:00:00Z"
CONFIRMATORY_SEED = "jacquard-readability-v1"
HUMAN_ENROLLMENT_COUNT = 480
HUMAN_SCHEDULE_VERSION = "readability-human-schedule-v1"
MODEL_SCHEDULE_VERSION = "readability-model-schedule-v1"
HUMAN_SCHEDULE_SHA256 = "356f000ba5af0421ef6eaaf246bbb78527ff9ffb97f61d84f5f795d96b114178"
MODEL_SCHEDULE_SHA256 = "69178f914457cbe0cf6081f10fa6b018267ec0876175ddc7b44bc8f92c735e4e"


class ProtocolError(RuntimeError):
    """Raised when reviewed protocol data or generated evidence is invalid."""


class JsonDocument(dict[str, Any]):
    """A loaded JSON object carrying the SHA-256 of its exact source bytes."""

    def __init__(self, value: dict[str, Any], source_sha256: str) -> None:
        super().__init__(value)
        self.source_sha256 = source_sha256


def digest_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest_text(text: str) -> str:
    return digest_bytes(text.encode("utf-8"))


def unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Build one JSON object while rejecting parser-ambiguous duplicate keys."""

    value: dict[str, Any] = {}
    for name, item in pairs:
        if name in value:
            raise ProtocolError(f"JSON object contains duplicate field: {name}")
        value[name] = item
    return value


def reject_json_constant(value: str) -> Any:
    """Reject NaN and infinities, which are not JSON values."""

    raise ProtocolError(f"JSON contains non-standard numeric constant: {value}")


def load_json(path: Path) -> JsonDocument:
    try:
        data = path.read_bytes()
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=unique_json_object,
            parse_constant=reject_json_constant,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ProtocolError(f"cannot load JSON {path}: {error}") from error
    if not isinstance(value, dict):
        raise ProtocolError(f"{path} must contain one JSON object")
    return JsonDocument(value, digest_bytes(data))


def document_sha256(document: dict[str, Any], label: str) -> str:
    """Return an exact source digest or reject an unbound in-memory document."""

    digest = getattr(document, "source_sha256", None)
    if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise ProtocolError(f"{label} must be loaded from exact reviewed JSON bytes")
    return digest


def fixture_index(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list):
        raise ProtocolError("manifest fixtures must be an array")
    indexed: dict[str, dict[str, Any]] = {}
    for fixture in fixtures:
        if not isinstance(fixture, dict) or not isinstance(fixture.get("id"), str):
            raise ProtocolError("every fixture must be an object with a string id")
        fixture_id = fixture["id"]
        if fixture_id in indexed:
            raise ProtocolError(f"duplicate fixture id: {fixture_id}")
        indexed[fixture_id] = fixture
    return indexed


def command_output(
    command: list[str], *, prelude: Path | None = None, expect_success: bool = True
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    if prelude is not None:
        environment["JACQUARD_PRELUDE"] = str(prelude)
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=environment,
    )
    if expect_success and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise ProtocolError(f"command failed ({result.returncode}): {' '.join(command)}\n{detail}")
    return result


def verify_plain_text(path: Path, data: bytes) -> None:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ProtocolError(f"fixture is not UTF-8: {path}: {error}") from error
    forbidden = {
        "\x1b": "ANSI escape",
        "```": "Markdown fence",
        "<span": "HTML span",
        "\r": "carriage return",
    }
    for marker, label in forbidden.items():
        if marker in text:
            raise ProtocolError(f"fixture presentation is not plain text ({label}): {path}")


def verify_manifest(manifest: dict[str, Any]) -> None:
    if manifest.get("schema_version") != "readability-fixtures-v1":
        raise ProtocolError("unexpected fixture manifest schema_version")
    if manifest.get("protocol_version") != PROTOCOL_VERSION:
        raise ProtocolError("fixture manifest protocol_version drift")
    if manifest.get("license") != "Apache-2.0":
        raise ProtocolError("fixture license must remain explicit and Apache-2.0")
    if tuple(manifest.get("carriers", ())) != CARRIERS:
        raise ProtocolError("carrier inventory or order drift")
    if tuple(manifest.get("jobs", ())) != JOBS:
        raise ProtocolError("reviewer-job inventory or order drift")
    outcome_families = {
        "comprehension",
        "review",
        "defect-detection",
        "modification-debugging",
        "diagnostic-recovery",
    }
    if set(manifest.get("outcome_families", ())) != outcome_families:
        raise ProtocolError("outcome-family inventory drift")
    presentation = manifest.get("presentation", {})
    if presentation != {
        "media_type": "text/plain; charset=utf-8",
        "syntax_highlighting": False,
        "ansi_styling": False,
        "timeout_ms": 300000,
    }:
        raise ProtocolError("plain-text presentation contract drift")

    limitations = manifest.get("python_matching_limits", [])
    limitation_text = " ".join(limitations).lower() if isinstance(limitations, list) else ""
    for required in (
        "task-equivalent",
        "hash_v0",
        "effect",
        "runtime",
        "stdout",
        "diagnostic",
    ):
        if required not in limitation_text:
            raise ProtocolError(f"Python matching limits must name {required}")

    if "model_condition" in manifest:
        raise ProtocolError("model pins belong in a versioned cohort manifest")

    indexed = fixture_index(manifest)
    if tuple(indexed) != JOBS:
        raise ProtocolError("there must be exactly one fixture per reviewer job, in protocol order")
    if {fixture.get("outcome_family") for fixture in indexed.values()} != outcome_families:
        raise ProtocolError("every outcome family must have exactly one fixture")
    for fixture_id, fixture in indexed.items():
        if fixture.get("job") != fixture_id:
            raise ProtocolError(f"fixture/job mismatch: {fixture_id}")
        if fixture.get("outcome_family") not in outcome_families:
            raise ProtocolError(f"fixture {fixture_id} has an unknown outcome family")
        verification_kind = fixture.get("verification_kind")
        if verification_kind not in {"success", "diagnostic"}:
            raise ProtocolError(f"fixture {fixture_id} has an unknown verification kind")
        if (fixture_id == "diagnostic-recovery") != (verification_kind == "diagnostic"):
            raise ProtocolError("only diagnostic-recovery may use diagnostic verification")
        options = fixture.get("options")
        if not isinstance(options, list) or len(options) < 2:
            raise ProtocolError(f"fixture {fixture_id} needs at least two answer options")
        option_ids = [option.get("id") for option in options if isinstance(option, dict)]
        if (
            len(option_ids) != len(options)
            or not all(isinstance(option_id, str) for option_id in option_ids)
            or len(set(option_ids)) != len(option_ids)
        ):
            raise ProtocolError(f"fixture {fixture_id} answer IDs must be unique strings")
        shadowed = RESERVED_ANSWER_IDS.intersection(option_ids)
        if shadowed:
            raise ProtocolError(
                f"fixture {fixture_id} shadows reserved answer ID: {sorted(shadowed)[0]}"
            )
        if fixture.get("correct_answer") not in option_ids:
            raise ProtocolError(f"fixture {fixture_id} correct answer is not an option")
        wrong = set(option_ids) - {fixture["correct_answer"]}
        if set(fixture.get("wrong_answer_errors", {})) != wrong:
            raise ProtocolError(f"fixture {fixture_id} must classify every wrong answer")
        sources = fixture.get("sources", {})
        if set(sources) != set(CARRIERS):
            raise ProtocolError(f"fixture {fixture_id} must have all three carriers")
        if verification_kind == "success":
            if not isinstance(fixture.get("semantic_hash_lines"), list):
                raise ProtocolError(f"fixture {fixture_id} must pin semantic hashes")
            if not isinstance(fixture.get("expected_stdout"), str):
                raise ProtocolError(f"fixture {fixture_id} must pin stdout")
        elif fixture.get("expected_diagnostic") != {
            "jacquard_code": "E0802",
            "python_exception": "TypeError",
        }:
            raise ProtocolError("diagnostic-recovery must pin E0802 and Python TypeError")


def verify_cohort_manifest(
    cohort: dict[str, Any], cohort_path: Path, *, require_collectible: bool = False
) -> None:
    """Validate one model cohort without treating it as collection authority."""

    expected_keys = {
        "schema_version",
        "protocol_version",
        "cohort_id",
        "role",
        "access_status",
        "provider",
        "model_id",
        "client",
        "control",
        "prompt",
        "repetitions_per_condition",
        "tools",
        "session_memory",
        "fresh_session_required",
        "training_cutoff_attestation",
        "quota_constraints",
        "collection_authorized",
    }
    if set(cohort) != expected_keys:
        raise ProtocolError("model cohort manifest fields drifted")
    if cohort["schema_version"] != "readability-model-cohort-v1":
        raise ProtocolError("unexpected model cohort schema_version")
    if cohort["protocol_version"] != PROTOCOL_VERSION:
        raise ProtocolError("model cohort protocol_version drift")
    if re.fullmatch(r"[A-Z][A-Z0-9-]{1,31}", cohort["cohort_id"] or "") is None:
        raise ProtocolError("model cohort_id must be a stable public identifier")
    if cohort["role"] not in {"reference", "exploratory"}:
        raise ProtocolError("model cohort role must be reference or exploratory")
    if cohort["access_status"] not in {"not-confirmed", "available"}:
        raise ProtocolError("model cohort access status is invalid")
    for name in ("provider", "model_id"):
        if not isinstance(cohort[name], str) or not cohort[name]:
            raise ProtocolError(f"model cohort {name} must be nonempty")

    client = cohort["client"]
    if not isinstance(client, dict) or set(client) != {"name", "version"}:
        raise ProtocolError("model cohort client pin is malformed")
    if not all(isinstance(client[name], str) and client[name] for name in client):
        raise ProtocolError("model cohort client name/version must be nonempty")

    control = cohort["control"]
    if not isinstance(control, dict) or set(control) != {"kind", "value"}:
        raise ProtocolError("model cohort control pin is malformed")
    if control["kind"] not in {"effort", "temperature"}:
        raise ProtocolError("model cohort must pin effort or temperature")
    if not isinstance(control["value"], (str, int, float)) or isinstance(
        control["value"], bool
    ):
        raise ProtocolError("model cohort control value is invalid")
    if control["kind"] == "temperature" and (
        not isinstance(control["value"], (int, float))
        or not 0 <= control["value"] <= 2
    ):
        raise ProtocolError("model temperature must be numeric from 0 through 2")
    if control["kind"] == "effort" and (
        not isinstance(control["value"], str) or not control["value"]
    ):
        raise ProtocolError("model effort control must be a nonempty label")

    prompt = cohort["prompt"]
    if not isinstance(prompt, dict) or set(prompt) != {"path", "sha256"}:
        raise ProtocolError("model cohort prompt pin is malformed")
    prompt_path = (cohort_path.parent / prompt["path"]).resolve()
    benchmark_root = cohort_path.parent.parent.resolve()
    if not prompt_path.is_relative_to(benchmark_root):
        raise ProtocolError("model cohort prompt must remain in test/readability")
    try:
        prompt_digest = digest_bytes(prompt_path.read_bytes())
    except OSError as error:
        raise ProtocolError(f"cannot read model prompt {prompt_path}: {error}") from error
    if prompt_digest != prompt["sha256"]:
        raise ProtocolError("model cohort prompt digest drift")

    repetitions = cohort["repetitions_per_condition"]
    if (
        not isinstance(repetitions, int)
        or isinstance(repetitions, bool)
        or not 1 <= repetitions <= 100
    ):
        raise ProtocolError("model repetitions must be an integer from 1 through 100")
    if (
        cohort["tools"] != "disabled"
        or cohort["session_memory"] != "disabled"
        or cohort["fresh_session_required"] is not True
    ):
        raise ProtocolError("model cohort weakened fresh-session isolation")

    attestation = cohort["training_cutoff_attestation"]
    attestation_keys = {"status", "attested_by", "attested_at", "evidence_sha256"}
    if not isinstance(attestation, dict) or set(attestation) != attestation_keys:
        raise ProtocolError("training-cutoff attestation record is malformed")
    if attestation["status"] not in {"pending", "attested"}:
        raise ProtocolError("training-cutoff attestation status is invalid")
    attested_values = (
        attestation["attested_by"],
        attestation["attested_at"],
        attestation["evidence_sha256"],
    )
    if attestation["status"] == "pending" and any(value is not None for value in attested_values):
        raise ProtocolError("pending training-cutoff attestation must not claim evidence")
    if attestation["status"] == "attested":
        if not all(isinstance(value, str) and value for value in attested_values):
            raise ProtocolError("attested training cutoff must identify its evidence")
        if re.fullmatch(r"[0-9a-f]{64}", attestation["evidence_sha256"]) is None:
            raise ProtocolError("training-cutoff evidence digest is malformed")
        if re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z",
            attestation["attested_at"],
        ) is None:
            raise ProtocolError("training-cutoff attestation time is malformed")

    quota = cohort["quota_constraints"]
    quota_keys = {"status", "maximum_sessions", "rate_limit", "notes"}
    if not isinstance(quota, dict) or set(quota) != quota_keys:
        raise ProtocolError("model quota record is malformed")
    if quota["status"] not in {"unconfirmed", "confirmed"}:
        raise ProtocolError("model quota status is invalid")
    if not isinstance(quota["notes"], str) or not quota["notes"]:
        raise ProtocolError("model quota record must explain its constraints")
    if quota["status"] == "unconfirmed" and (
        quota["maximum_sessions"] is not None or quota["rate_limit"] is not None
    ):
        raise ProtocolError("unconfirmed model quota must not claim limits")
    if quota["status"] == "confirmed":
        if not isinstance(quota["maximum_sessions"], int) or quota["maximum_sessions"] < 1:
            raise ProtocolError("confirmed model quota must name a positive session limit")
        if not isinstance(quota["rate_limit"], str) or not quota["rate_limit"]:
            raise ProtocolError("confirmed model quota must name its rate limit")
        required_sessions = len(CARRIERS) * len(JOBS) * repetitions
        if quota["maximum_sessions"] < required_sessions:
            raise ProtocolError("confirmed model quota cannot cover the reviewed schedule")

    if cohort["collection_authorized"] is not False and cohort["collection_authorized"] is not True:
        raise ProtocolError("model collection_authorized must be boolean")
    collectible = (
        cohort["collection_authorized"]
        and cohort["access_status"] == "available"
        and attestation["status"] == "attested"
        and quota["status"] == "confirmed"
    )
    if cohort["collection_authorized"] and not collectible:
        raise ProtocolError("model collection authorization lacks access, attestation, or quota")
    if require_collectible and not collectible:
        raise ProtocolError("model cohort is not authorized for collection")


AUTHORITY_APPROVALS = {
    "accountable_owner_and_operator",
    "ethics_and_privacy",
    "information_sheet_and_consent",
    "recruitment_and_eligibility",
    "compensation_and_withdrawal",
    "accessibility_review",
    "retention_and_incident_response",
    "publication_license",
    "data_governance",
}


def verify_authority_manifest(
    authority: dict[str, Any], *, require_authorized: bool = False
) -> None:
    """Validate external study authority and fail closed when approval is required."""

    expected_keys = {
        "schema_version",
        "protocol_version",
        "authority_id",
        "collection_authorized",
        "approvals",
        "approved_by",
        "approved_at",
        "evidence_sha256",
    }
    if set(authority) != expected_keys:
        raise ProtocolError("study authority manifest fields drifted")
    if authority["schema_version"] != "readability-authority-v1":
        raise ProtocolError("unexpected study authority schema_version")
    if authority["protocol_version"] != PROTOCOL_VERSION:
        raise ProtocolError("study authority protocol_version drift")
    if re.fullmatch(r"[A-Z][A-Z0-9-]{2,63}", authority["authority_id"] or "") is None:
        raise ProtocolError("study authority_id must be a stable public identifier")
    approvals = authority["approvals"]
    if not isinstance(approvals, dict) or set(approvals) != AUTHORITY_APPROVALS:
        raise ProtocolError("study authority approval inventory drift")
    if any(status not in {"pending", "approved"} for status in approvals.values()):
        raise ProtocolError("study authority approval status is invalid")
    authorized = authority["collection_authorized"] is True
    if authority["collection_authorized"] is not False and not authorized:
        raise ProtocolError("study collection_authorized must be boolean")
    evidence = (authority["approved_by"], authority["approved_at"], authority["evidence_sha256"])
    complete = all(status == "approved" for status in approvals.values()) and all(
        isinstance(value, str) and value for value in evidence
    )
    if complete and re.fullmatch(r"[0-9a-f]{64}", authority["evidence_sha256"]) is None:
        raise ProtocolError("study authority evidence digest is malformed")
    if complete and re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z",
        authority["approved_at"],
    ) is None:
        raise ProtocolError("study authority approval time is malformed")
    if authorized and not complete:
        raise ProtocolError("study collection authorization lacks required approvals")
    if require_authorized and not (authorized and complete):
        raise ProtocolError("real collection is not authorized")


def verify_fixtures(
    manifest: dict[str, Any], manifest_path: Path, jacquard: Path, prelude: Path
) -> None:
    for fixture in fixture_index(manifest).values():
        fixture_id = fixture["id"]
        paths: dict[str, Path] = {}
        for carrier in CARRIERS:
            source = fixture["sources"][carrier]
            path = manifest_path.parent / source["path"]
            try:
                data = path.read_bytes()
            except OSError as error:
                raise ProtocolError(f"cannot read fixture {path}: {error}") from error
            if digest_bytes(data) != source["sha256"]:
                raise ProtocolError(f"source digest drift: {path}")
            verify_plain_text(path, data)
            paths[carrier] = path

        if fixture["verification_kind"] == "diagnostic":
            expected = fixture["expected_diagnostic"]
            for carrier in ("jac", "jqd"):
                checked = command_output(
                    [str(jacquard), "check", str(paths[carrier])],
                    prelude=prelude,
                    expect_success=False,
                )
                marker = f"error[{expected['jacquard_code']}]"
                if checked.returncode == 0 or marker not in checked.stderr:
                    raise ProtocolError(
                        f"pinned diagnostic drifted for {fixture_id}.{carrier}"
                    )
            python = command_output(
                [sys.executable, str(paths["python"])], expect_success=False
            )
            if python.returncode == 0 or expected["python_exception"] not in python.stderr:
                raise ProtocolError(f"task-equivalent Python diagnostic drifted for {fixture_id}")
            continue

        expected_hash = "\n".join(fixture["semantic_hash_lines"]) + "\n"
        hash_outputs = []
        for carrier in ("jac", "jqd"):
            result = command_output(
                [str(jacquard), "hash", str(paths[carrier])], prelude=prelude
            )
            hash_outputs.append(result.stdout)
            if result.stdout != expected_hash:
                raise ProtocolError(f"pinned semantic hashes drifted for {fixture_id}.{carrier}")
        if hash_outputs[0] != hash_outputs[1]:
            raise ProtocolError(f"surface/bootstrap semantic hash mismatch: {fixture_id}")

        run_outputs = []
        run_args = fixture.get("jacquard_run_args", [])
        for carrier in ("jac", "jqd"):
            result = command_output(
                [str(jacquard), "run", str(paths[carrier]), *run_args], prelude=prelude
            )
            run_outputs.append(result.stdout)
            if result.stdout != fixture["expected_stdout"]:
                raise ProtocolError(f"pinned observable output drifted for {fixture_id}.{carrier}")
        if run_outputs[0] != run_outputs[1]:
            raise ProtocolError(f"surface/bootstrap observable behavior mismatch: {fixture_id}")

        python = command_output([sys.executable, str(paths["python"])])
        if python.stdout != fixture["expected_stdout"]:
            raise ProtocolError(f"task-equivalent Python stdout drifted for {fixture_id}")

        refusal_code = fixture.get("refusal_without_args")
        if refusal_code is not None:
            for carrier in ("jac", "jqd"):
                refused = command_output(
                    [str(jacquard), "run", str(paths[carrier])],
                    prelude=prelude,
                    expect_success=False,
                )
                if refused.returncode == 0 or f"error[{refusal_code}]" not in refused.stderr:
                    raise ProtocolError(
                        f"{fixture_id}.{carrier} must fail closed with {refusal_code} "
                        "without its grant"
                    )


def assignment(seed: str, ordinal: int) -> dict[str, Any]:
    if not seed:
        raise ProtocolError("assignment seed must be nonempty")
    if ordinal < 0:
        raise ProtocolError("enrollment ordinal must be nonnegative")
    cells = [(carrier, order) for carrier in CARRIERS for order in JOB_ORDERS]
    block, position = divmod(ordinal, len(cells))
    ranked = sorted(
        cells,
        key=lambda cell: digest_text(
            f"{seed}\0block={block}\0carrier={cell[0]}\0order={','.join(cell[1])}"
        ),
    )
    carrier, order = ranked[position]
    return {
        "ordinal": ordinal,
        "block": block,
        "position": position,
        "carrier": carrier,
        "job_order": list(order),
        "assignment_seed_sha256": digest_text(seed),
    }


def human_schedule() -> list[dict[str, Any]]:
    """Return the frozen de-identified 480-enrollment assignment plan.

    The rows contain enrollment ordinals and presentation assignments only.
    They never contain participant, consent, contact, or compensation data.
    """

    rows: list[dict[str, Any]] = []
    for ordinal in range(HUMAN_ENROLLMENT_COUNT):
        row = assignment(CONFIRMATORY_SEED, ordinal)
        rows.append(
            {
                "schedule_schema_version": HUMAN_SCHEDULE_VERSION,
                "protocol_version": PROTOCOL_VERSION,
                **row,
            }
        )
    return rows


def model_schedule(
    manifest: dict[str, Any], cohort: dict[str, Any], cohort_sha256: str
) -> list[dict[str, Any]]:
    """Return the frozen model trial plan without starting model sessions.

    Every carrier/job/repetition appears exactly once.  Dispatch order is the
    lexicographic order of SHA-256 over the documented UTF-8/NUL-separated key.
    Each row carries the reviewed fixture, prompt, and runtime pins needed to
    detect drift before a result can enter confirmatory evidence.
    """

    repetitions = cohort["repetitions_per_condition"]
    fixtures = fixture_index(manifest)
    trials: list[tuple[str, str, int, str]] = []
    for carrier in CARRIERS:
        for job in JOBS:
            for repetition in range(1, repetitions + 1):
                key = (
                    f"{CONFIRMATORY_SEED}\0cohort={cohort['cohort_id']}\0carrier={carrier}"
                    f"\0job={job}\0repetition={repetition}"
                )
                trials.append((carrier, job, repetition, digest_text(key)))
    trials.sort(key=lambda trial: trial[3])

    seed_digest = digest_text(CONFIRMATORY_SEED)
    return [
        {
            "schedule_schema_version": MODEL_SCHEDULE_VERSION,
            "protocol_version": PROTOCOL_VERSION,
            "ordinal": ordinal,
            "condition_id": f"{carrier}/{job}",
            "carrier": carrier,
            "job": job,
            "repetition": repetition,
            "dispatch_key_sha256": dispatch_key,
            "assignment_seed_sha256": seed_digest,
            "fixture_sha256": fixtures[job]["sources"][carrier]["sha256"],
            "cohort_id": cohort["cohort_id"],
            "cohort_manifest_sha256": cohort_sha256,
            "cohort_role": cohort["role"],
            "provider": cohort["provider"],
            "model_id": cohort["model_id"],
            "client_name": cohort["client"]["name"],
            "client_version": cohort["client"]["version"],
            "control_kind": cohort["control"]["kind"],
            "control_value": cohort["control"]["value"],
            "prompt_sha256": cohort["prompt"]["sha256"],
            "tools": cohort["tools"],
            "session_memory": cohort["session_memory"],
            "fresh_session_required": cohort["fresh_session_required"],
            "training_cutoff_attestation": cohort["training_cutoff_attestation"]["status"],
            "quota_status": cohort["quota_constraints"]["status"],
            "collection_authorized": cohort["collection_authorized"],
        }
        for ordinal, (carrier, job, repetition, dispatch_key) in enumerate(trials)
    ]


def encode_jsonl(rows: Iterable[dict[str, Any]]) -> str:
    """Encode evidence rows as stable UTF-8-compatible JSON Lines."""

    return "".join(
        json.dumps(
            row,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        )
        + "\n"
        for row in rows
    )


def verify_schedule_files(human_path: Path, model_path: Path) -> None:
    """Fail unless CLI-generated schedule files match the reviewed byte plans."""

    expected = (
        ("human", human_path, HUMAN_SCHEDULE_SHA256),
        ("model", model_path, MODEL_SCHEDULE_SHA256),
    )
    for label, path, expected_digest in expected:
        try:
            actual_digest = digest_bytes(path.read_bytes())
        except OSError as error:
            raise ProtocolError(f"cannot read {label} schedule {path}: {error}") from error
        if actual_digest != expected_digest:
            raise ProtocolError(
                f"{label} schedule digest drift: expected {expected_digest}, got {actual_digest}"
            )


def score_answer(fixture: dict[str, Any], answer_id: str) -> tuple[bool, str | None]:
    options = {option["id"] for option in fixture["options"]}
    if answer_id == "__timeout__":
        return False, "timeout"
    if answer_id == "__system_failure__":
        return False, "system-failure"
    if answer_id == "__parse_failure__":
        return False, "prompt-parse-failure"
    if answer_id not in options:
        return False, "invalid-answer"
    if answer_id == fixture["correct_answer"]:
        return True, None
    return False, fixture["wrong_answer_errors"][answer_id]


def exclusion_codes(subject_kind: str, facts: dict[str, Any], cohort: dict[str, Any]) -> list[str]:
    codes: list[str] = []
    if subject_kind == "human":
        checks = (
            (not facts.get("consent", False), "no-consent"),
            (not facts.get("eligible", False), "eligibility-failed"),
            (facts.get("prior_fixture_exposure", False), "prior-fixture-exposure"),
            (facts.get("prohibited_tools", False), "prohibited-tools"),
            (facts.get("duplicate_enrollment", False), "duplicate-enrollment"),
            (
                facts.get("trial_system_failure", False) or facts.get("system_failures", 0) > 1,
                "system-failure",
            ),
        )
    elif subject_kind == "model":
        checks = (
            (
                not facts.get("training_cutoff_attested", False),
                "model-training-contamination",
            ),
            (
                facts.get("provider") != cohort["provider"]
                or facts.get("model_id") != cohort["model_id"]
                or facts.get("client_name") != cohort["client"]["name"]
                or facts.get("client_version") != cohort["client"]["version"],
                "model-version-drift",
            ),
            (facts.get("prompt_parse_failure", False), "prompt-parse-failure"),
            (
                facts.get("trial_system_failure", False) or facts.get("system_failures", 0) > 1,
                "system-failure",
            ),
        )
    elif subject_kind == "synthetic":
        checks = ()
    else:
        raise ProtocolError(f"unknown subject kind: {subject_kind}")
    for applies, code in checks:
        if applies and code not in codes:
            codes.append(code)
    return codes


def json_type_matches(value: Any, declared: str | list[str]) -> bool:
    names = [declared] if isinstance(declared, str) else declared
    for name in names:
        if name == "null" and value is None:
            return True
        if name == "boolean" and isinstance(value, bool):
            return True
        if name == "integer" and isinstance(value, int) and not isinstance(value, bool):
            return True
        if (
            name == "number"
            and isinstance(value, (int, float))
            and not isinstance(value, bool)
            and (not isinstance(value, float) or math.isfinite(value))
        ):
            return True
        if name == "string" and isinstance(value, str):
            return True
        if name == "array" and isinstance(value, list):
            return True
        if name == "object" and isinstance(value, dict):
            return True
    return False


def json_values_equal(left: Any, right: Any) -> bool:
    """Compare JSON values without Python's boolean/integer aliasing.

    Draft 2020-12 treats booleans as distinct from numbers, while numerically
    equal integer and finite floating-point representations denote the same
    JSON number. Arrays and objects apply that rule recursively.
    """

    if isinstance(left, bool) or isinstance(right, bool):
        return (
            isinstance(left, bool) and isinstance(right, bool) and left is right
        )
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return left == right
    if isinstance(left, list) or isinstance(right, list):
        return (
            isinstance(left, list)
            and isinstance(right, list)
            and len(left) == len(right)
            and all(json_values_equal(a, b) for a, b in zip(left, right))
        )
    if isinstance(left, dict) or isinstance(right, dict):
        return (
            isinstance(left, dict)
            and isinstance(right, dict)
            and left.keys() == right.keys()
            and all(json_values_equal(left[key], right[key]) for key in left)
        )
    return type(left) is type(right) and left == right


def schema_matches(value: Any, rule: dict[str, Any]) -> bool:
    """Return whether a value satisfies a schema branch without leaking errors."""

    try:
        validate_schema_value("conditional", value, rule)
    except ProtocolError:
        return False
    return True


def validate_schema_value(name: str, value: Any, rule: dict[str, Any]) -> None:
    """Validate the Draft 2020-12 keywords used by the checked result schema.

    This deliberately implements the repository's bounded schema vocabulary,
    including nested object branches, oneOf, allOf, and if/then. The checked
    schema is separately rejected if it uses an unsupported keyword.
    """

    if not isinstance(rule, dict):
        raise ProtocolError(f"schema rule for {name} must be an object")
    declared_type = rule.get("type")
    if declared_type is not None and not json_type_matches(value, declared_type):
        raise ProtocolError(f"result {name} has the wrong JSON type")
    if "const" in rule and not json_values_equal(value, rule["const"]):
        raise ProtocolError(f"result {name} must equal {rule['const']!r}")
    if "enum" in rule and not any(
        json_values_equal(value, candidate) for candidate in rule["enum"]
    ):
        raise ProtocolError(f"result {name} is outside its enum")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in rule and value < rule["minimum"]:
            raise ProtocolError(f"result {name} is below its minimum")
        if "maximum" in rule and value > rule["maximum"]:
            raise ProtocolError(f"result {name} is above its maximum")
    if isinstance(value, str):
        if "minLength" in rule and len(value) < rule["minLength"]:
            raise ProtocolError(f"result {name} is too short")
        if "maxLength" in rule and len(value) > rule["maxLength"]:
            raise ProtocolError(f"result {name} is too long")
        if "pattern" in rule and re.fullmatch(rule["pattern"], value) is None:
            raise ProtocolError(f"result {name} does not match its pattern")
    if isinstance(value, list):
        encoded_items = {json.dumps(item, sort_keys=True) for item in value}
        if rule.get("uniqueItems") and len(encoded_items) != len(value):
            raise ProtocolError(f"result {name} must contain unique items")
        item_rule = rule.get("items")
        if item_rule:
            for index, item in enumerate(value):
                validate_schema_value(f"{name}[{index}]", item, item_rule)
    if isinstance(value, dict):
        required = set(rule.get("required", []))
        missing = required - set(value)
        if missing:
            raise ProtocolError(
                f"result {name} is missing fields: {', '.join(sorted(missing))}"
            )
        properties = rule.get("properties", {})
        if not isinstance(properties, dict):
            raise ProtocolError(f"schema properties for {name} must be an object")
        if rule.get("additionalProperties") is False:
            extra = set(value) - set(properties)
            if extra:
                raise ProtocolError(
                    f"result {name} has unknown fields: {', '.join(sorted(extra))}"
                )
        for property_name, property_rule in properties.items():
            if property_name in value:
                validate_schema_value(
                    f"{name}.{property_name}", value[property_name], property_rule
                )
    if "oneOf" in rule:
        branches = rule["oneOf"]
        if not isinstance(branches, list):
            raise ProtocolError(f"schema oneOf for {name} must be an array")
        matches = sum(schema_matches(value, branch) for branch in branches)
        if matches != 1:
            raise ProtocolError(f"result {name} must match exactly one schema branch")
    for branch in rule.get("allOf", []):
        validate_schema_value(name, value, branch)
    if "if" in rule and schema_matches(value, rule["if"]):
        if "then" in rule:
            validate_schema_value(name, value, rule["then"])


def verify_schema_rule(rule: Any, path: str) -> None:
    """Reject schema syntax outside the validator's reviewed vocabulary."""

    if not isinstance(rule, dict):
        raise ProtocolError(f"result schema rule {path} must be an object")
    unknown = set(rule) - SUPPORTED_SCHEMA_KEYS
    if unknown:
        raise ProtocolError(
            f"result schema uses unsupported keyword at {path}: {sorted(unknown)[0]}"
        )
    required = rule.get("required")
    if required is not None and (
        not isinstance(required, list)
        or not all(isinstance(name, str) for name in required)
        or len(required) != len(set(required))
    ):
        raise ProtocolError(f"result schema required fields at {path} are malformed")
    properties = rule.get("properties", {})
    if not isinstance(properties, dict):
        raise ProtocolError(f"result schema properties at {path} must be an object")
    for name, child in properties.items():
        verify_schema_rule(child, f"{path}.properties.{name}")
    if "items" in rule:
        verify_schema_rule(rule["items"], f"{path}.items")
    for keyword in ("oneOf", "allOf"):
        if keyword not in rule:
            continue
        branches = rule[keyword]
        if not isinstance(branches, list) or not branches:
            raise ProtocolError(f"result schema {keyword} at {path} must be nonempty")
        for index, branch in enumerate(branches):
            verify_schema_rule(branch, f"{path}.{keyword}[{index}]")
    for keyword in ("if", "then"):
        if keyword in rule:
            verify_schema_rule(rule[keyword], f"{path}.{keyword}")


def verify_result_schema(schema: dict[str, Any]) -> None:
    """Validate the exact structural contract expected of result schema v1."""

    verify_schema_rule(schema, "root")
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        raise ProtocolError("result schema must pin JSON Schema draft 2020-12")
    if schema.get("type") != "object" or schema.get("additionalProperties") is not False:
        raise ProtocolError("result schema root must be a closed object")
    properties = schema.get("properties")
    required = schema.get("required")
    if not isinstance(properties, dict):
        raise ProtocolError("result schema properties are malformed")
    if not isinstance(required, list):
        raise ProtocolError("result schema required fields are malformed")
    if set(required) != set(properties):
        raise ProtocolError("every result property must remain required")
    model_rule = properties.get("model", {})
    if not isinstance(model_rule.get("oneOf"), list) or len(model_rule["oneOf"]) != 2:
        raise ProtocolError("result schema must retain null/object model branches")
    all_of = schema.get("allOf", [])
    if not isinstance(all_of, list) or len(all_of) != 5:
        raise ProtocolError("result schema must retain five conditional branches")
    conditionals: set[tuple[str, str]] = set()
    for branch in all_of:
        if_rule = branch.get("if", {}).get("properties", {})
        if len(if_rule) != 1:
            raise ProtocolError("result schema conditional must test exactly one field")
        field, field_rule = next(iter(if_rule.items()))
        value = field_rule.get("const") if isinstance(field_rule, dict) else None
        if not isinstance(value, str) or "then" not in branch:
            raise ProtocolError("result schema conditional is malformed")
        conditionals.add((field, value))
    expected_conditionals = {
        ("subject_kind", "human"),
        ("subject_kind", "model"),
        ("subject_kind", "synthetic"),
        ("run_kind", "dry-run"),
        ("run_kind", "exploratory"),
    }
    if conditionals != expected_conditionals:
        raise ProtocolError("result schema conditional inventory drifted")


def canonical_row_id(row: dict[str, Any]) -> str:
    body = {key: value for key, value in row.items() if key != "row_id"}
    encoded = json.dumps(
        body,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    )
    return digest_text(encoded)


def validate_row(
    row: dict[str, Any],
    manifest: dict[str, Any],
    schema: dict[str, Any],
    *,
    cohort: dict[str, Any] | None = None,
    authority: dict[str, Any] | None = None,
) -> None:
    """Validate one result against the schema and its exact admission context.

    Synthetic rows need no external context. Real rows require a previously
    loaded authority manifest and its exact file digest; model rows additionally
    require a previously validated collectible cohort and its exact file digest.
    Cross-row completeness and retry/session rules are enforced by
    ``validate_result_store``.
    """

    if not isinstance(row, dict):
        raise ProtocolError("each result row must be a JSON object")
    validate_schema_value("row", row, schema)

    if row["condition_id"] != f"{row['carrier']}/{row['job']}":
        raise ProtocolError("condition_id must be carrier/job")
    if row["fixture_id"] != row["job"]:
        raise ProtocolError("fixture_id must identify the job's frozen fixture")
    fixture = fixture_index(manifest)[row["fixture_id"]]
    if row["outcome_family"] != fixture["outcome_family"]:
        raise ProtocolError("result outcome_family does not match the fixture")
    expected_correct, expected_error = score_answer(fixture, row["answer_id"])
    if (row["correct"], row["error_code"]) != (expected_correct, expected_error):
        raise ProtocolError("correct/error_code does not follow deterministic scoring")
    if row["answer_id"] == "__timeout__" and row["completion_ms"] != 300000:
        raise ProtocolError("timeout rows must use the frozen timeout duration")
    if row["fixture_sha256"] != fixture["sources"][row["carrier"]]["sha256"]:
        raise ProtocolError("result fixture digest does not match the manifest")
    if row["excluded"] != bool(row["exclusion_codes"]):
        raise ProtocolError("excluded must exactly reflect exclusion_codes")
    failure_exclusions = {
        "system-failure": "system-failure",
        "prompt-parse-failure": "prompt-parse-failure",
    }
    for error_code, exclusion_code in failure_exclusions.items():
        if (row["error_code"] == error_code) != (
            exclusion_code in row["exclusion_codes"]
        ):
            raise ProtocolError(
                f"{error_code} result/exclusion code must appear together"
            )
    if row["row_id"] != canonical_row_id(row):
        raise ProtocolError("row_id is not the canonical SHA-256 of the result row")
    if row["run_kind"] != "dry-run" and row["assignment_seed_sha256"] != digest_text(
        CONFIRMATORY_SEED
    ):
        raise ProtocolError("real result row does not use the frozen assignment seed")
    if row["fixture_manifest_sha256"] != document_sha256(
        manifest, "fixture manifest"
    ):
        raise ProtocolError("result fixture manifest digest drifted")
    if row["schema_sha256"] != document_sha256(schema, "result schema"):
        raise ProtocolError("result schema digest drifted")

    subject_kind = row["subject_kind"]
    if subject_kind == "human":
        allowed_exclusions = {
            "no-consent",
            "eligibility-failed",
            "prior-fixture-exposure",
            "prohibited-tools",
            "duplicate-enrollment",
            "system-failure",
        }
        if not set(row["exclusion_codes"]) <= allowed_exclusions:
            raise ProtocolError("human row carries a non-human exclusion code")
        pre_assignment = {"no-consent", "eligibility-failed"}.intersection(
            row["exclusion_codes"]
        )
        if pre_assignment:
            raise ProtocolError(
                "pre-assignment consent/eligibility exclusions belong in enrollment flow"
            )
        if authority is None:
            raise ProtocolError("human row lacks an authority admission context")
        verify_authority_manifest(authority, require_authorized=True)
        authority_sha256 = document_sha256(authority, "authority manifest")
        if row["authority_manifest_sha256"] != authority_sha256:
            raise ProtocolError("human row authority manifest digest drifted")
        ordinal = row["schedule_ordinal"]
        if not isinstance(ordinal, int) or isinstance(ordinal, bool) or not (
            0 <= ordinal < HUMAN_ENROLLMENT_COUNT
        ):
            raise ProtocolError("human row schedule ordinal is invalid")
        planned = assignment(CONFIRMATORY_SEED, ordinal)
        if row["carrier"] != planned["carrier"]:
            raise ProtocolError("human row carrier drifted from its assignment")
        planned_job = planned["job_order"][row["presentation_order"] - 1]
        if row["job"] != planned_job:
            raise ProtocolError("human row job/order drifted from its assignment")
        if any(row[name] is None for name in HUMAN_PROFILE_FIELDS):
            raise ProtocolError("human row is missing the de-identified expertise profile")
        if row["answer_id"] == "__parse_failure__":
            raise ProtocolError("human rows cannot report a model prompt parse failure")
    elif subject_kind == "model":
        allowed_exclusions = {
            "model-training-contamination",
            "model-version-drift",
            "prompt-parse-failure",
            "system-failure",
        }
        if not set(row["exclusion_codes"]) <= allowed_exclusions:
            raise ProtocolError("model row carries a non-model exclusion code")
        if (
            cohort is None
            or authority is None
        ):
            raise ProtocolError("model row lacks cohort or authority admission context")
        verify_authority_manifest(authority, require_authorized=True)
        authority_sha256 = document_sha256(authority, "authority manifest")
        if row["authority_manifest_sha256"] != authority_sha256:
            raise ProtocolError("model row authority manifest digest drifted")
        cohort_sha256 = document_sha256(cohort, "model cohort manifest")
        collectible = (
            cohort["collection_authorized"] is True
            and cohort["access_status"] == "available"
            and cohort["training_cutoff_attestation"]["status"] == "attested"
            and cohort["quota_constraints"]["status"] == "confirmed"
        )
        if not collectible:
            raise ProtocolError("model cohort is not authorized for collection")
        expected_run_kind = "confirmatory" if cohort["role"] == "reference" else "exploratory"
        if row["run_kind"] != expected_run_kind:
            raise ProtocolError("model row run_kind does not match its cohort role")
        model = row["model"]
        if not isinstance(model, dict):
            raise ProtocolError("model row lacks its pinned model record")
        if (
            model["cohort_id"] != cohort["cohort_id"]
            or model["cohort_manifest_sha256"] != cohort_sha256
        ):
            raise ProtocolError("model row belongs to a substituted or cross-cohort trial")
        expected_model = {
            "provider": cohort["provider"],
            "model_id": cohort["model_id"],
            "client_name": cohort["client"]["name"],
            "client_version": cohort["client"]["version"],
            "control_kind": cohort["control"]["kind"],
            "control_value": cohort["control"]["value"],
            "prompt_sha256": cohort["prompt"]["sha256"],
        }
        pin_mismatch = any(model[name] != expected for name, expected in expected_model.items())
        if pin_mismatch != ("model-version-drift" in row["exclusion_codes"]):
            raise ProtocolError("model pin drift/exclusion mismatch")
        ordinal = row["schedule_ordinal"]
        if not isinstance(ordinal, int) or isinstance(ordinal, bool) or ordinal < 0:
            raise ProtocolError("model row schedule ordinal is invalid")
        planned_models = model_schedule(manifest, cohort, cohort_sha256)
        if ordinal >= len(planned_models):
            raise ProtocolError("model row schedule ordinal is outside its cohort plan")
        planned = planned_models[ordinal]
        planned_fields = {
            "carrier": row["carrier"],
            "job": row["job"],
            "fixture_sha256": row["fixture_sha256"],
            "repetition": model["repetition"],
        }
        if any(planned[name] != value for name, value in planned_fields.items()):
            raise ProtocolError("model row drifted from its cohort schedule")
        if row["presentation_order"] != 1:
            raise ProtocolError("fresh model sessions must use presentation_order 1")
        if any(row[name] is not None for name in HUMAN_PROFILE_FIELDS):
            raise ProtocolError("model rows must not claim a human expertise profile")
        if row["trial_attempt"] != 1:
            raise ProtocolError("model trials are never retried")
        contaminated = not model["training_cutoff_attested"]
        if contaminated != ("model-training-contamination" in row["exclusion_codes"]):
            raise ProtocolError("model training-cutoff attestation/exclusion mismatch")
    elif subject_kind == "synthetic":
        nullable_fields = (
            "consent_version",
            "model",
            "schedule_ordinal",
            "authority_manifest_sha256",
            "programming_experience_years",
            "code_review_experience_years",
            "jacquard_familiarity",
            "functional_programming_familiarity",
        )
        if row["run_kind"] != "dry-run" or any(row[name] is not None for name in nullable_fields):
            raise ProtocolError("synthetic rows are dry-run only and carry no consent/model record")
        if row["exclusion_codes"]:
            raise ProtocolError("synthetic rows cannot carry real-study exclusion codes")
        if row["trial_attempt"] != 1:
            raise ProtocolError("synthetic trials must be first attempts")
    else:
        raise ProtocolError(f"unknown result subject kind: {subject_kind}")


def make_dry_run_rows(
    seed: str, manifest: dict[str, Any], schema: dict[str, Any]
) -> list[dict[str, Any]]:
    indexed = fixture_index(manifest)
    seed_digest = digest_text(seed)
    rows: list[dict[str, Any]] = []
    for carrier in CARRIERS:
        order = sorted(
            JOBS, key=lambda job: digest_text(f"{seed}\0{carrier}\0{job}")
        )
        subject_id = digest_text(f"synthetic\0{seed}\0{carrier}")[:24]
        for position, job in enumerate(order, start=1):
            fixture = indexed[job]
            row: dict[str, Any] = {
                "schema_version": SCHEMA_VERSION,
                "protocol_version": PROTOCOL_VERSION,
                "row_id": "",
                "run_kind": "dry-run",
                "subject_kind": "synthetic",
                "subject_id": subject_id,
                "carrier": carrier,
                "job": job,
                "outcome_family": fixture["outcome_family"],
                "fixture_id": fixture["id"],
                "condition_id": f"{carrier}/{job}",
                "presentation_order": position,
                "trial_attempt": 1,
                "schedule_ordinal": None,
                "answer_id": fixture["correct_answer"],
                "correct": True,
                "completion_ms": 1000 + len(rows),
                "confidence": 100,
                "perceived_readability": 4,
                "error_code": None,
                "excluded": False,
                "exclusion_codes": [],
                "assignment_seed_sha256": seed_digest,
                "fixture_manifest_sha256": document_sha256(
                    manifest, "fixture manifest"
                ),
                "fixture_sha256": fixture["sources"][carrier]["sha256"],
                "schema_sha256": document_sha256(schema, "result schema"),
                "plain_text": True,
                "syntax_highlighting": False,
                "consent_version": None,
                "authority_manifest_sha256": None,
                "programming_experience_years": None,
                "code_review_experience_years": None,
                "jacquard_familiarity": None,
                "functional_programming_familiarity": None,
                "model": None,
                "recorded_at": FIXED_DRY_RUN_TIME,
            }
            row["row_id"] = canonical_row_id(row)
            validate_row(row, manifest, schema)
            rows.append(row)
    return rows


def render_trial(manifest: dict[str, Any], manifest_path: Path, carrier: str, job: str) -> str:
    fixture = fixture_index(manifest)[job]
    source_path = manifest_path.parent / fixture["sources"][carrier]["path"]
    source = source_path.read_text(encoding="utf-8")
    lines = [
        f"Trial: {carrier}/{job}",
        fixture["prompt"],
        "Answers:",
        *[f"[{option['id']}] {option['label']}" for option in fixture["options"]],
        "Source begins",
        source.rstrip("\n"),
        "Source ends",
    ]
    rendered = "\n".join(lines) + "\n"
    verify_plain_text(source_path, rendered.encode("utf-8"))
    return rendered


def verify_protocol_document(protocol_path: Path) -> None:
    text = protocol_path.read_text(encoding="utf-8").lower()
    anchors = (
        "seeded bug",
        "predict observable output",
        "authority escalation",
        "modification/debugging",
        "diagnostic recovery",
        "perceived readability",
        "between-subject",
        "williams",
        "completion time",
        "confidence",
        "human evidence is primary",
        "model-family neutral",
        "cohort manifest",
        "expertise",
        "prior jacquard",
        "plain text",
        "sample size",
        "70% from 90% accuracy",
        "0.025 / 5 = 0.005",
        "readability-descriptive-v1",
        "97.5% wilson",
        "exact confidence-level calibration",
        "consent",
        "compensation",
        "accessibility",
        "retention",
        "publication license",
        "data governance",
        "de-ident",
        "contamination",
        "pass",
        "fail",
        "inconclusive",
        ".scratch",
    )
    for anchor in anchors:
        if anchor not in text:
            raise ProtocolError(f"protocol document is missing required topic: {anchor}")


def self_test(
    manifest: dict[str, Any],
    manifest_path: Path,
    schema: dict[str, Any],
    protocol_path: Path,
    cohort: dict[str, Any],
    cohort_path: Path,
    authority: dict[str, Any],
) -> None:
    verify_manifest(manifest)
    verify_cohort_manifest(cohort, cohort_path)
    verify_authority_manifest(authority)
    verify_result_schema(schema)
    verify_protocol_document(protocol_path)

    first = assignment("ux1-self-test", 0)
    if first != assignment("ux1-self-test", 0):
        raise ProtocolError("assignment is not deterministic")
    block_size = len(CARRIERS) * len(JOB_ORDERS)
    block = [assignment("ux1-self-test", ordinal) for ordinal in range(block_size)]
    if {item["carrier"] for item in block} != set(CARRIERS):
        raise ProtocolError("assignment block omitted a carrier")
    for carrier in CARRIERS:
        orders = [tuple(item["job_order"]) for item in block if item["carrier"] == carrier]
        if set(orders) != set(JOB_ORDERS):
            raise ProtocolError(
                f"assignment block does not include every Williams order for {carrier}"
            )
    for position in range(len(JOBS)):
        counts = {job: sum(order[position] == job for order in JOB_ORDERS) for job in JOBS}
        if set(counts.values()) != {2}:
            raise ProtocolError("Williams orders do not balance presentation positions")
    pair_counts = {
        (left, right): sum(
            order[index : index + 2] == (left, right)
            for order in JOB_ORDERS
            for index in range(len(JOBS) - 1)
        )
        for left in JOBS
        for right in JOBS
        if left != right
    }
    if set(pair_counts.values()) != {2}:
        raise ProtocolError("Williams orders do not balance first-order carryover")

    humans = human_schedule()
    if len(humans) != HUMAN_ENROLLMENT_COUNT:
        raise ProtocolError("human schedule must contain exactly 480 enrollment ordinals")
    if [row["ordinal"] for row in humans] != list(range(HUMAN_ENROLLMENT_COUNT)):
        raise ProtocolError("human schedule ordinals must be contiguous and zero-based")
    human_carrier_counts = {
        carrier: sum(row["carrier"] == carrier for row in humans) for carrier in CARRIERS
    }
    if human_carrier_counts != {carrier: 160 for carrier in CARRIERS}:
        raise ProtocolError("human schedule must assign exactly 160 enrollments per carrier")
    for row in humans:
        expected = assignment(CONFIRMATORY_SEED, row["ordinal"])
        if any(row[key] != value for key, value in expected.items()):
            raise ProtocolError("human schedule drifted from frozen seeded assignment")

    cohort_sha256 = digest_bytes(cohort_path.read_bytes())
    models = model_schedule(manifest, cohort, cohort_sha256)
    expected_model_count = len(CARRIERS) * len(JOBS) * cohort["repetitions_per_condition"]
    if len(models) != expected_model_count:
        raise ProtocolError("model schedule has the wrong number of fresh trials")
    if models != model_schedule(manifest, cohort, cohort_sha256):
        raise ProtocolError("model schedule generation is not deterministic")
    if [row["ordinal"] for row in models] != list(range(expected_model_count)):
        raise ProtocolError("model schedule ordinals must be contiguous and zero-based")
    if [row["dispatch_key_sha256"] for row in models] != sorted(
        row["dispatch_key_sha256"] for row in models
    ):
        raise ProtocolError("model schedule is not ordered by its SHA-256 dispatch key")
    if len({row["dispatch_key_sha256"] for row in models}) != expected_model_count:
        raise ProtocolError("model schedule dispatch keys must be unique")
    for carrier in CARRIERS:
        for job in JOBS:
            repetitions = {
                row["repetition"]
                for row in models
                if row["carrier"] == carrier and row["job"] == job
            }
            if repetitions != set(range(1, cohort["repetitions_per_condition"] + 1)):
                raise ProtocolError(f"model schedule is incomplete for {carrier}/{job}")
    for row in models:
        if (
            not row["fresh_session_required"]
            or row["tools"] != "disabled"
            or row["session_memory"] != "disabled"
            or row["cohort_manifest_sha256"] != cohort_sha256
        ):
            raise ProtocolError("model schedule weakened cohort isolation")
    if encode_jsonl(humans) != encode_jsonl(human_schedule()):
        raise ProtocolError("human schedule JSONL is not byte-deterministic")
    if encode_jsonl(models) != encode_jsonl(model_schedule(manifest, cohort, cohort_sha256)):
        raise ProtocolError("model schedule JSONL is not byte-deterministic")
    if digest_text(encode_jsonl(humans)) != HUMAN_SCHEDULE_SHA256:
        raise ProtocolError("human schedule bytes drifted from the reviewed plan")
    if digest_text(encode_jsonl(models)) != MODEL_SCHEDULE_SHA256:
        raise ProtocolError("model schedule bytes drifted from the reviewed plan")

    for fixture in fixture_index(manifest).values():
        if score_answer(fixture, fixture["correct_answer"]) != (True, None):
            raise ProtocolError(f"correct scoring failed for {fixture['id']}")
        for wrong_answer, error_code in fixture["wrong_answer_errors"].items():
            if score_answer(fixture, wrong_answer) != (False, error_code):
                raise ProtocolError(f"wrong-answer taxonomy failed for {fixture['id']}")
        if score_answer(fixture, "not-an-option") != (False, "invalid-answer"):
            raise ProtocolError("invalid-answer scoring failed")
        if score_answer(fixture, "__timeout__") != (False, "timeout"):
            raise ProtocolError("timeout scoring failed")
        if score_answer(fixture, "__system_failure__") != (False, "system-failure"):
            raise ProtocolError("system-failure scoring failed")
        if score_answer(fixture, "__parse_failure__") != (False, "prompt-parse-failure"):
            raise ProtocolError("prompt-parse-failure scoring failed")

    human_codes = exclusion_codes(
        "human",
        {
            "consent": False,
            "eligible": False,
            "prior_fixture_exposure": True,
            "prohibited_tools": True,
            "duplicate_enrollment": True,
            "system_failures": 2,
        },
        cohort,
    )
    expected_human_codes = {
        "no-consent",
        "eligibility-failed",
        "prior-fixture-exposure",
        "prohibited-tools",
        "duplicate-enrollment",
        "system-failure",
    }
    if set(human_codes) != expected_human_codes:
        raise ProtocolError("human exclusion rules are incomplete")
    clean_model = {
        "training_cutoff_attested": True,
        "provider": cohort["provider"],
        "model_id": cohort["model_id"],
        "client_name": cohort["client"]["name"],
        "client_version": cohort["client"]["version"],
        "prompt_parse_failure": False,
        "system_failures": 0,
    }
    if exclusion_codes("model", clean_model, cohort):
        raise ProtocolError("eligible pinned model was excluded")
    contaminated = dict(clean_model, training_cutoff_attested=False)
    if exclusion_codes("model", contaminated, cohort) != ["model-training-contamination"]:
        raise ProtocolError("model contamination exclusion failed")

    rows = make_dry_run_rows("ux1-self-test", manifest, schema)
    expected_conditions = {f"{carrier}/{job}" for carrier in CARRIERS for job in JOBS}
    if len(rows) != 15 or {row["condition_id"] for row in rows} != expected_conditions:
        raise ProtocolError("dry run must emit exactly one valid row per condition")
    if len({row["row_id"] for row in rows}) != len(rows):
        raise ProtocolError("dry-run row IDs must be unique")

    approved_authority = copy.deepcopy(dict(authority))
    approved_authority.update(
        {
            "authority_id": "SELF-TEST-AUTHORITY",
            "collection_authorized": True,
            "approved_by": "self-test",
            "approved_at": FIXED_DRY_RUN_TIME,
            "evidence_sha256": digest_text("self-test-authority"),
        }
    )
    approved_authority["approvals"] = {
        name: "approved" for name in AUTHORITY_APPROVALS
    }
    authority_json = json.dumps(
        approved_authority, sort_keys=True, separators=(",", ":")
    )
    approved_authority = JsonDocument(
        approved_authority, digest_text(authority_json)
    )
    authority_sha256 = document_sha256(approved_authority, "self-test authority")

    approved_cohort = copy.deepcopy(dict(cohort))
    approved_cohort.update({"access_status": "available", "collection_authorized": True})
    approved_cohort["training_cutoff_attestation"] = {
        "status": "attested",
        "attested_by": "self-test",
        "attested_at": FIXED_DRY_RUN_TIME,
        "evidence_sha256": digest_text("self-test-cutoff"),
    }
    approved_cohort["quota_constraints"] = {
        "status": "confirmed",
        "maximum_sessions": expected_model_count,
        "rate_limit": "self-test",
        "notes": "Synthetic validator fixture only.",
    }
    cohort_json = json.dumps(approved_cohort, sort_keys=True, separators=(",", ":"))
    approved_cohort = JsonDocument(approved_cohort, digest_text(cohort_json))
    verify_cohort_manifest(approved_cohort, cohort_path, require_collectible=True)
    approved_cohort_sha256 = document_sha256(
        approved_cohort, "self-test model cohort"
    )
    dry_by_condition = {row["condition_id"]: row for row in rows}

    def test_human_result(
        plan: dict[str, Any], position: int, job: str
    ) -> dict[str, Any]:
        result = copy.deepcopy(dry_by_condition[f"{plan['carrier']}/{job}"])
        result.update(
            {
                "run_kind": "confirmatory",
                "subject_kind": "human",
                "subject_id": digest_text(f"human-self-test\0{plan['ordinal']}")[:24],
                "schedule_ordinal": plan["ordinal"],
                "presentation_order": position,
                "assignment_seed_sha256": digest_text(CONFIRMATORY_SEED),
                "consent_version": "consent-v1",
                "authority_manifest_sha256": authority_sha256,
                "programming_experience_years": 5,
                "code_review_experience_years": 2,
                "jacquard_familiarity": 0,
                "functional_programming_familiarity": 2,
            }
        )
        result["row_id"] = canonical_row_id(result)
        return result

    def test_model_result(plan: dict[str, Any]) -> dict[str, Any]:
        result = copy.deepcopy(dry_by_condition[plan["condition_id"]])
        result.update(
            {
                "run_kind": (
                    "confirmatory" if approved_cohort["role"] == "reference" else "exploratory"
                ),
                "subject_kind": "model",
                "subject_id": digest_text(f"model-self-test\0{plan['ordinal']}")[:24],
                "schedule_ordinal": plan["ordinal"],
                "presentation_order": 1,
                "assignment_seed_sha256": digest_text(CONFIRMATORY_SEED),
                "authority_manifest_sha256": authority_sha256,
                "model": {
                    "cohort_id": approved_cohort["cohort_id"],
                    "cohort_manifest_sha256": approved_cohort_sha256,
                    "provider": approved_cohort["provider"],
                    "model_id": approved_cohort["model_id"],
                    "client_name": approved_cohort["client"]["name"],
                    "client_version": approved_cohort["client"]["version"],
                    "control_kind": approved_cohort["control"]["kind"],
                    "control_value": approved_cohort["control"]["value"],
                    "prompt_sha256": approved_cohort["prompt"]["sha256"],
                    "repetition": plan["repetition"],
                    "training_cutoff_attested": True,
                },
            }
        )
        result["row_id"] = canonical_row_id(result)
        return result

    def validate_test_human(
        result: dict[str, Any], authority_document: dict[str, Any] = approved_authority
    ) -> None:
        validate_row(result, manifest, schema, authority=authority_document)

    def validate_test_model(
        result: dict[str, Any], cohort_document: dict[str, Any] = approved_cohort
    ) -> None:
        validate_row(
            result,
            manifest,
            schema,
            cohort=cohort_document,
            authority=approved_authority,
        )

    def validate_test_human_store(results: list[dict[str, Any]]) -> None:
        validate_result_store(
            results, manifest, schema, authority=approved_authority
        )

    def validate_test_model_store(results: list[dict[str, Any]]) -> None:
        validate_result_store(
            results,
            manifest,
            schema,
            cohort=approved_cohort,
            authority=approved_authority,
        )

    human_plan = humans[0]
    human = test_human_result(human_plan, 1, human_plan["job_order"][0])
    validate_test_human(human)

    approved_model_plan = model_schedule(
        manifest, approved_cohort, approved_cohort_sha256
    )
    model = test_model_result(approved_model_plan[0])
    validate_test_model(model)

    validate_result_store(rows, manifest, schema)
    human_store = [
        test_human_result(plan, position, job)
        for plan in humans
        for position, job in enumerate(plan["job_order"], start=1)
    ]
    validate_test_human_store(human_store)
    model_store = [test_model_result(plan) for plan in approved_model_plan]
    validate_test_model_store(model_store)

    human_store_with_retry = copy.deepcopy(human_store)
    failed = human_store_with_retry[0]
    failed.update(
        {
            "answer_id": "__system_failure__",
            "correct": False,
            "error_code": "system-failure",
            "excluded": True,
            "exclusion_codes": ["system-failure"],
        }
    )
    failed["row_id"] = canonical_row_id(failed)
    retry = copy.deepcopy(human_store[0])
    retry["trial_attempt"] = 2
    retry["row_id"] = canonical_row_id(retry)
    human_store_with_retry.insert(5, retry)
    validate_test_human_store(human_store_with_retry)

    synthetic_jsonl = encode_jsonl(rows)
    synthetic_digest = digest_text(synthetic_jsonl)
    synthetic_analysis = prepare_analysis_bundle(rows, synthetic_digest)
    if (
        synthetic_analysis["evidence_class"] != "synthetic-non-citable"
        or synthetic_analysis["claim_status"] != "not-evaluated"
        or synthetic_analysis["source"]["input_jsonl_sha256"] != synthetic_digest
        or synthetic_analysis["flow"]["overall"]["subjects"]
        != {"analyzable": 3, "answer_store": 3, "excluded": 0}
        or synthetic_analysis["flow"]["overall"]["trials"]["effective_rows"] != 15
    ):
        raise ProtocolError("synthetic analysis provenance or non-citable flow drifted")
    if encode_analysis_bundle(synthetic_analysis) != encode_analysis_bundle(
        prepare_analysis_bundle(rows, synthetic_digest)
    ):
        raise ProtocolError("analysis bundle bytes are not deterministic")
    changed_source_analysis = prepare_analysis_bundle(
        rows, digest_text(synthetic_jsonl + "\n")
    )
    if (
        changed_source_analysis["source"]["input_jsonl_sha256"] == synthetic_digest
        or encode_analysis_bundle(changed_source_analysis)
        == encode_analysis_bundle(synthetic_analysis)
    ):
        raise ProtocolError("analysis bundle does not bind exact source JSONL bytes")

    synthetic_descriptive = prepare_descriptive_bundle(
        rows, synthetic_digest, synthetic_analysis
    )
    descriptive_tables = synthetic_descriptive["tables"]
    expected_descriptive_tables = {
        "perceived-readability",
        "comprehension",
        "review",
        "defect-detection",
        "modification-debugging",
        "diagnostic-recovery",
    }
    jac_comprehension = next(
        table
        for table in descriptive_tables["comprehension"]
        if table["carrier"] == "jac"
    )
    if (
        synthetic_descriptive["evidence_class"] != "synthetic-non-citable"
        or synthetic_descriptive["claim_status"] != "not-evaluated"
        or synthetic_descriptive["source"]["input_jsonl_sha256"]
        != synthetic_digest
        or synthetic_descriptive["source"]["effective_row_count"] != 15
        or set(descriptive_tables) != expected_descriptive_tables
        or len(descriptive_tables["perceived-readability"]) != 15
        or any(
            len(descriptive_tables[name]) != 3
            for name in expected_descriptive_tables - {"perceived-readability"}
        )
        or jac_comprehension["accuracy"]["correct"] != 1
        or jac_comprehension["accuracy"]["estimate"] != "1.000000000000"
        or jac_comprehension["accuracy"]["wilson"]
        != {
            "confidence_level": "0.975000000000",
            "lower": "0.166005792424",
            "upper": "1.000000000000",
        }
        or jac_comprehension["confidence"]["calibration"]
        != [
            {
                "accuracy": "1.000000000000",
                "confidence": 100,
                "correct": 1,
                "rows": 1,
            }
        ]
    ):
        raise ProtocolError("synthetic descriptive tables drifted")
    synthetic_descriptive_bytes = encode_descriptive_bundle(synthetic_descriptive)
    if (
        synthetic_descriptive_bytes
        != encode_descriptive_bundle(
            prepare_descriptive_bundle(rows, synthetic_digest, synthetic_analysis)
        )
        or FIXED_DRY_RUN_TIME in synthetic_descriptive_bytes
        or '"recorded_at"' in synthetic_descriptive_bytes
    ):
        raise ProtocolError("descriptive bundle bytes or timestamp exclusion drifted")
    mismatched_analysis = copy.deepcopy(synthetic_analysis)
    mismatched_analysis["source"]["input_jsonl_sha256"] = digest_text(
        synthetic_jsonl + "\n"
    )
    try:
        prepare_descriptive_bundle(rows, synthetic_digest, mismatched_analysis)
    except DescriptiveError:
        pass
    else:
        raise ProtocolError("descriptive analysis accepted mismatched provenance")
    zero_time_store = copy.deepcopy(rows)
    zero_time_store[0]["completion_ms"] = 0
    zero_time_store[0]["row_id"] = canonical_row_id(zero_time_store[0])
    validate_result_store(zero_time_store, manifest, schema)
    zero_time_jsonl = encode_jsonl(zero_time_store)
    zero_time_digest = digest_text(zero_time_jsonl)
    zero_time_analysis = prepare_analysis_bundle(
        zero_time_store, zero_time_digest
    )
    zero_time_descriptive = prepare_descriptive_bundle(
        zero_time_store, zero_time_digest, zero_time_analysis
    )
    zero_time_row = zero_time_store[0]
    zero_time_table = next(
        table
        for table in zero_time_descriptive["tables"][
            zero_time_row["outcome_family"]
        ]
        if table["carrier"] == zero_time_row["carrier"]
        and table["job"] == zero_time_row["job"]
    )
    if (
        zero_time_table["completion_ms"]["nonpositive_rows"] != 1
        or zero_time_table["completion_ms"]["log_mean"] is not None
        or zero_time_table["completion_ms"]["geometric_mean_ms"] is not None
    ):
        raise ProtocolError("zero completion time was dropped or silently shifted")

    clean_human_analysis = prepare_analysis_bundle(
        human_store, digest_text(encode_jsonl(human_store))
    )
    if (
        clean_human_analysis["evidence_class"] != "human-candidate"
        or clean_human_analysis["pre_assignment_flow"]["status"]
        != "external-required"
        or clean_human_analysis["flow"]["overall"]["subjects"]
        != {"analyzable": 480, "answer_store": 480, "excluded": 0}
        or clean_human_analysis["flow"]["overall"]["trials"]["effective_rows"]
        != 2400
        or clean_human_analysis["source"]["schedule"]
        != {
            "schema_version": HUMAN_SCHEDULE_VERSION,
            "sha256": HUMAN_SCHEDULE_SHA256,
        }
    ):
        raise ProtocolError("clean human analyzability flow drifted")
    clean_human_descriptive = prepare_descriptive_bundle(
        human_store,
        digest_text(encode_jsonl(human_store)),
        clean_human_analysis,
    )
    human_expertise = clean_human_descriptive["strata"]["human_expertise"]
    programming_strata = human_expertise["programming_experience_years"]
    if (
        clean_human_descriptive["evidence_class"] != "human-candidate"
        or clean_human_descriptive["pre_assignment_flow"]["status"]
        != "external-required"
        or clean_human_descriptive["source"]["source_row_count"] != 2400
        or clean_human_descriptive["source"]["effective_row_count"] != 2400
        or programming_strata
        != [
            {"carrier": carrier, "subjects": 160, "value": 5}
            for carrier in CARRIERS
        ]
        or len(clean_human_descriptive["strata"]["presentation_order"]) != 75
        or any(
            len(clean_human_descriptive["strata"]["human_profile_outcomes"][field])
            != 15
            for field in HUMAN_PROFILE_FIELDS
        )
    ):
        raise ProtocolError("human descriptive expertise or learning strata drifted")

    retry_analysis = prepare_analysis_bundle(
        human_store_with_retry,
        digest_text(encode_jsonl(human_store_with_retry)),
    )
    retry_subject = retry_analysis["subjects"][0]
    retry_trials = retry_analysis["flow"]["overall"]["trials"]
    if (
        not retry_subject["analyzable"]
        or retry_subject["system_failure_count"] != 1
        or failed["row_id"] not in retry_subject["excluded_row_ids"]
        or retry["row_id"] not in retry_subject["effective_row_ids"]
        or retry_trials["source_rows"] != 2401
        or retry_trials["effective_rows"] != 2400
        or retry_trials["excluded_rows"] != 1
        or retry_trials["effective_retry_rows"] != 1
    ):
        raise ProtocolError("successful human retry did not replace its failed first row")
    retry_descriptive = prepare_descriptive_bundle(
        human_store_with_retry,
        digest_text(encode_jsonl(human_store_with_retry)),
        retry_analysis,
    )
    if (
        retry_descriptive["source"]["source_row_count"] != 2401
        or retry_descriptive["source"]["effective_row_count"] != 2400
        or failed["row_id"] in retry_descriptive["source"]["effective_row_ids"]
        or retry["row_id"] not in retry_descriptive["source"]["effective_row_ids"]
    ):
        raise ProtocolError("descriptive tables did not honor effective retry selection")

    failed_retry_store = copy.deepcopy(human_store_with_retry)
    failed_retry = failed_retry_store[5]
    failed_retry.update(
        {
            "answer_id": "__system_failure__",
            "correct": False,
            "error_code": "system-failure",
            "excluded": True,
            "exclusion_codes": ["system-failure"],
        }
    )
    failed_retry["row_id"] = canonical_row_id(failed_retry)
    validate_test_human_store(failed_retry_store)
    failed_retry_analysis = prepare_analysis_bundle(
        failed_retry_store, digest_text(encode_jsonl(failed_retry_store))
    )
    failed_retry_subject = failed_retry_analysis["subjects"][0]
    if (
        failed_retry_subject["analyzable"]
        or failed_retry_subject["subject_exclusion_codes"] != ["system-failure"]
        or failed_retry_subject["system_failure_count"] != 2
        or failed_retry_subject["effective_row_ids"]
        or failed_retry_analysis["flow"]["overall"]["subjects"]["excluded"] != 1
        or failed_retry_analysis["flow"]["overall"]["trials"]["effective_rows"]
        != 2395
    ):
        raise ProtocolError("failed retry did not exclude the complete human subject")

    two_failure_store = copy.deepcopy(human_store)
    for failure in two_failure_store[:2]:
        failure.update(
            {
                "answer_id": "__system_failure__",
                "correct": False,
                "error_code": "system-failure",
                "excluded": True,
                "exclusion_codes": ["system-failure"],
            }
        )
        failure["row_id"] = canonical_row_id(failure)
    validate_test_human_store(two_failure_store)
    two_failure_analysis = prepare_analysis_bundle(
        two_failure_store, digest_text(encode_jsonl(two_failure_store))
    )
    if (
        two_failure_analysis["subjects"][0]["subject_exclusion_codes"]
        != ["system-failure"]
        or two_failure_analysis["flow"]["overall"]["trials"]["effective_rows"]
        != 2395
    ):
        raise ProtocolError("multiple first-attempt failures did not exclude the subject")

    stable_exclusion_store = copy.deepcopy(human_store)
    for excluded_row in stable_exclusion_store[:5]:
        excluded_row.update(
            {"excluded": True, "exclusion_codes": ["prohibited-tools"]}
        )
        excluded_row["row_id"] = canonical_row_id(excluded_row)
    validate_test_human_store(stable_exclusion_store)
    stable_exclusion_analysis = prepare_analysis_bundle(
        stable_exclusion_store,
        digest_text(encode_jsonl(stable_exclusion_store)),
    )
    if (
        stable_exclusion_analysis["subjects"][0]["subject_exclusion_codes"]
        != ["prohibited-tools"]
        or stable_exclusion_analysis["subjects"][0]["effective_row_ids"]
    ):
        raise ProtocolError("stable human exclusion did not exclude the complete subject")

    drift_store = copy.deepcopy(model_store)
    drift_store[0]["model"]["client_version"] = "observed-unreviewed-client"
    drift_store[0].update(
        {"excluded": True, "exclusion_codes": ["model-version-drift"]}
    )
    drift_store[0]["row_id"] = canonical_row_id(drift_store[0])
    validate_test_model_store(drift_store)
    clean_model_analysis = prepare_analysis_bundle(
        model_store, digest_text(encode_jsonl(model_store))
    )
    drift_model_analysis = prepare_analysis_bundle(
        drift_store, digest_text(encode_jsonl(drift_store))
    )
    if (
        clean_model_analysis["evidence_class"] != "model-candidate"
        or clean_model_analysis["flow"]["overall"]["trials"]["effective_rows"]
        != expected_model_count
        or drift_model_analysis["flow"]["overall"]["subjects"]["excluded"] != 1
        or drift_model_analysis["flow"]["overall"]["trials"]["effective_rows"]
        != expected_model_count - 1
    ):
        raise ProtocolError("model session analyzability flow drifted")
    clean_model_descriptive = prepare_descriptive_bundle(
        model_store,
        digest_text(encode_jsonl(model_store)),
        clean_model_analysis,
    )
    if (
        clean_model_descriptive["evidence_class"] != "model-candidate"
        or clean_model_descriptive["subject_kind"] != "model"
        or clean_model_descriptive["strata"]["human_expertise"] is not None
        or clean_model_descriptive["source"]["effective_row_count"]
        != expected_model_count
    ):
        raise ProtocolError("model descriptive tables were not kept cohort-separate")

    def expect_rejection(label: str, operation: Callable[[], Any]) -> None:
        try:
            operation()
        except ProtocolError:
            return
        raise ProtocolError(f"admission validator accepted {label}")

    expect_rejection(
        "duplicate JSON object fields",
        lambda: json.loads(
            '{"row_id":"a","row_id":"b"}',
            object_pairs_hook=unique_json_object,
        ),
    )
    expect_rejection(
        "a non-standard NaN JSON value",
        lambda: json.loads(
            '{"control_value":NaN}', parse_constant=reject_json_constant
        ),
    )

    drifted_model = copy.deepcopy(model)
    drifted_model["model"]["client_version"] = "observed-unreviewed-client"
    drifted_model.update(
        {"excluded": True, "exclusion_codes": ["model-version-drift"]}
    )
    drifted_model["row_id"] = canonical_row_id(drifted_model)
    validate_test_model(drifted_model)

    wrong_run_kind = copy.deepcopy(model)
    wrong_run_kind["run_kind"] = "exploratory"
    wrong_run_kind["row_id"] = canonical_row_id(wrong_run_kind)
    expect_rejection(
        "a model run kind that disagrees with its cohort role",
        lambda: validate_test_model(wrong_run_kind),
    )
    under_quota = copy.deepcopy(dict(approved_cohort))
    under_quota["quota_constraints"]["maximum_sessions"] = expected_model_count - 1
    expect_rejection(
        "a model cohort whose quota cannot cover its frozen schedule",
        lambda: verify_cohort_manifest(
            under_quota, cohort_path, require_collectible=True
        ),
    )

    wrong_authority = copy.deepcopy(human)
    wrong_authority["authority_manifest_sha256"] = "0" * 64
    wrong_authority["row_id"] = canonical_row_id(wrong_authority)
    expect_rejection(
        "a drifted authority digest",
        lambda: validate_test_human(wrong_authority),
    )
    wrong_fixture_manifest = copy.deepcopy(human)
    wrong_fixture_manifest["fixture_manifest_sha256"] = "0" * 64
    wrong_fixture_manifest["row_id"] = canonical_row_id(wrong_fixture_manifest)
    expect_rejection(
        "a drifted fixture-manifest digest",
        lambda: validate_test_human(wrong_fixture_manifest),
    )
    wrong_schema_digest = copy.deepcopy(human)
    wrong_schema_digest["schema_sha256"] = "0" * 64
    wrong_schema_digest["row_id"] = canonical_row_id(wrong_schema_digest)
    expect_rejection(
        "a drifted schema digest",
        lambda: validate_test_human(wrong_schema_digest),
    )
    expect_rejection(
        "the pending authority template",
        lambda: validate_test_human(human, authority),
    )
    no_consent_result = copy.deepcopy(human)
    no_consent_result.update(
        {"excluded": True, "exclusion_codes": ["no-consent"]}
    )
    no_consent_result["row_id"] = canonical_row_id(no_consent_result)
    expect_rejection(
        "a pre-assignment no-consent record in answer data",
        lambda: validate_test_human(no_consent_result),
    )
    wrong_human_carrier = copy.deepcopy(human)
    wrong_human_carrier["carrier"] = next(
        carrier for carrier in CARRIERS if carrier != human["carrier"]
    )
    wrong_human_carrier["condition_id"] = (
        f"{wrong_human_carrier['carrier']}/{wrong_human_carrier['job']}"
    )
    wrong_human_carrier["fixture_sha256"] = fixture_index(manifest)[human["job"]][
        "sources"
    ][wrong_human_carrier["carrier"]]["sha256"]
    wrong_human_carrier["row_id"] = canonical_row_id(wrong_human_carrier)
    expect_rejection(
        "a human carrier substituted for its frozen assignment",
        lambda: validate_test_human(wrong_human_carrier),
    )
    wrong_schema_branch = copy.deepcopy(human)
    wrong_schema_branch["model"] = copy.deepcopy(model["model"])
    wrong_schema_branch["row_id"] = canonical_row_id(wrong_schema_branch)
    expect_rejection(
        "a human row that violates the Draft 2020-12 conditional branch",
        lambda: validate_test_human(wrong_schema_branch),
    )
    newline_subject = copy.deepcopy(human)
    newline_subject["subject_id"] += "\n"
    newline_subject["row_id"] = canonical_row_id(newline_subject)
    expect_rejection(
        "a subject ID with a trailing line terminator",
        lambda: validate_test_human(newline_subject),
    )

    cross_cohort = copy.deepcopy(model)
    cross_cohort["model"]["cohort_id"] = "M1"
    cross_cohort["row_id"] = canonical_row_id(cross_cohort)
    expect_rejection(
        "a cross-cohort model row",
        lambda: validate_test_model(cross_cohort),
    )
    wrong_repetition = copy.deepcopy(model)
    wrong_repetition["model"]["repetition"] = (
        wrong_repetition["model"]["repetition"] % 100
    ) + 1
    wrong_repetition["row_id"] = canonical_row_id(wrong_repetition)
    expect_rejection(
        "a model repetition substituted for its schedule cell",
        lambda: validate_test_model(wrong_repetition),
    )
    expect_rejection(
        "the pending model cohort",
        lambda: validate_test_model(model, cohort),
    )

    invented_human_failure = copy.deepcopy(human)
    invented_human_failure.update(
        {"excluded": True, "exclusion_codes": ["system-failure"]}
    )
    invented_human_failure["row_id"] = canonical_row_id(invented_human_failure)
    expect_rejection(
        "a successful human row mislabeled as a system failure",
        lambda: validate_test_human(invented_human_failure),
    )
    invented_model_parse_failure = copy.deepcopy(model)
    invented_model_parse_failure.update(
        {"excluded": True, "exclusion_codes": ["prompt-parse-failure"]}
    )
    invented_model_parse_failure["row_id"] = canonical_row_id(
        invented_model_parse_failure
    )
    expect_rejection(
        "a parsed model row mislabeled as a prompt parse failure",
        lambda: validate_test_model(invented_model_parse_failure),
    )

    expect_rejection(
        "an empty result store",
        lambda: validate_result_store([], manifest, schema),
    )
    expect_rejection(
        "an incomplete synthetic store",
        lambda: validate_result_store(rows[:-1], manifest, schema),
    )
    expect_rejection(
        "an incomplete human store",
        lambda: validate_test_human_store(human_store[:-1]),
    )
    reordered_humans = human_store.copy()
    reordered_humans[0], reordered_humans[1] = (
        reordered_humans[1],
        reordered_humans[0],
    )
    expect_rejection(
        "reordered human trials",
        lambda: validate_test_human_store(reordered_humans),
    )
    retry_without_failure = human_store.copy()
    invalid_retry = copy.deepcopy(human_store[0])
    invalid_retry["trial_attempt"] = 2
    invalid_retry["row_id"] = canonical_row_id(invalid_retry)
    retry_without_failure.insert(5, invalid_retry)
    expect_rejection(
        "a human retry without its preserved failed attempt",
        lambda: validate_test_human_store(retry_without_failure),
    )
    expect_rejection(
        "an incomplete model cohort store",
        lambda: validate_test_model_store(model_store[:-1]),
    )
    reordered_models = model_store.copy()
    reordered_models[0], reordered_models[1] = (
        reordered_models[1],
        reordered_models[0],
    )
    expect_rejection(
        "reordered model schedule cells",
        lambda: validate_test_model_store(reordered_models),
    )
    reused_session = model_store.copy()
    reused_session[1] = copy.deepcopy(reused_session[1])
    reused_session[1]["subject_id"] = reused_session[0]["subject_id"]
    reused_session[1]["row_id"] = canonical_row_id(reused_session[1])
    expect_rejection(
        "a reused model session subject_id",
        lambda: validate_test_model_store(reused_session),
    )
    duplicate_synthetic = rows + [copy.deepcopy(rows[0])]
    expect_rejection(
        "a duplicate synthetic row",
        lambda: validate_result_store(duplicate_synthetic, manifest, schema),
    )
    mixed_subject_kinds = [
        copy.deepcopy(human_store[0]),
        copy.deepcopy(model_store[0]),
    ]
    expect_rejection(
        "a mixed human/model result store",
        lambda: validate_result_store(
            mixed_subject_kinds,
            manifest,
            schema,
            cohort=approved_cohort,
            authority=approved_authority,
        ),
    )

    sentinel_manifest = copy.deepcopy(dict(manifest))
    sentinel_manifest["fixtures"][0]["options"].append(
        {"id": "__timeout__", "label": "reserved self-test option"}
    )
    expect_rejection(
        "a fixture option that shadows a reserved failure sentinel",
        lambda: verify_manifest(sentinel_manifest),
    )

    for carrier in CARRIERS:
        for job in JOBS:
            rendered = render_trial(manifest, manifest_path, carrier, job)
            if "\x1b" in rendered or "```" in rendered or "<span" in rendered:
                raise ProtocolError("presentation added highlighting or markup")

    mutations = (
        ("syntax highlighting", "syntax_highlighting", True),
        ("numeric plain-text boolean", "plain_text", 1),
        ("numeric syntax-highlighting boolean", "syntax_highlighting", 0),
        ("readability scale", "perceived_readability", 0),
        ("outcome family", "outcome_family", "review"),
    )
    for label, field, value in mutations:
        mutation = copy.deepcopy(rows[0])
        mutation[field] = value
        mutation["row_id"] = canonical_row_id(mutation)
        try:
            validate_row(mutation, manifest, schema)
        except ProtocolError:
            pass
        else:
            raise ProtocolError(f"schema validator accepted invalid {label}")
    equality_cases = (
        (1, 1.0, True),
        (True, 1, False),
        ([False], [0], False),
        ({"flag": True}, {"flag": 1}, False),
    )
    for left, right, expected_equal in equality_cases:
        if json_values_equal(left, right) is not expected_equal:
            raise ProtocolError("JSON value equality drifted from Draft 2020-12")
    mutation = copy.deepcopy(rows[0])
    del mutation["confidence"]
    try:
        validate_row(mutation, manifest, schema)
    except ProtocolError:
        pass
    else:
        raise ProtocolError("schema validator accepted a missing required field")
    try:
        verify_authority_manifest(authority, require_authorized=True)
    except ProtocolError:
        pass
    else:
        raise ProtocolError("unapproved authority template allowed collection")
    try:
        verify_cohort_manifest(cohort, cohort_path, require_collectible=True)
    except ProtocolError:
        pass
    else:
        raise ProtocolError("pending model cohort allowed collection")


def validate_human_store(rows: list[dict[str, Any]]) -> None:
    """Require one ordered, complete five-job record for every frozen ordinal.

    Rows are chronological JSONL evidence: ordinals are contiguous, each
    participant's five first attempts appear in presentation order, and the
    only optional sixth row is the single preregistered system-failure retry.
    """

    groups: list[list[dict[str, Any]]] = []
    for row in rows:
        if not groups or groups[-1][0]["schedule_ordinal"] != row["schedule_ordinal"]:
            groups.append([])
        groups[-1].append(row)
    ordinals = [group[0]["schedule_ordinal"] for group in groups]
    if ordinals != list(range(HUMAN_ENROLLMENT_COUNT)):
        raise ProtocolError("human result store is incomplete or reordered")
    subject_ids = [group[0]["subject_id"] for group in groups]
    if len(set(subject_ids)) != HUMAN_ENROLLMENT_COUNT:
        raise ProtocolError("human result store reuses a subject across enrollment ordinals")

    shared_fields = (
        "subject_id",
        "schedule_ordinal",
        "carrier",
        "consent_version",
        "authority_manifest_sha256",
        *HUMAN_PROFILE_FIELDS,
    )
    for ordinal, group in enumerate(groups):
        baseline = group[0]
        for row in group:
            if any(row[name] != baseline[name] for name in shared_fields):
                raise ProtocolError(f"human profile drift at schedule ordinal {ordinal}")
        first_attempts = [row for row in group if row["trial_attempt"] == 1]
        retries = [row for row in group if row["trial_attempt"] == 2]
        if (
            len(first_attempts) != len(JOBS)
            or [row["presentation_order"] for row in first_attempts] != list(range(1, 6))
            or group[: len(JOBS)] != first_attempts
        ):
            raise ProtocolError(f"human first attempts are incomplete or reordered at {ordinal}")
        if len({row["job"] for row in first_attempts}) != len(JOBS):
            raise ProtocolError(f"human first attempts duplicate a job at {ordinal}")
        stable_exclusions = [
            set(row["exclusion_codes"]) - {"system-failure"} for row in group
        ]
        if any(codes != stable_exclusions[0] for codes in stable_exclusions[1:]):
            raise ProtocolError(f"human subject-level exclusions drift at {ordinal}")
        failed_firsts = [
            row for row in first_attempts if row["error_code"] == "system-failure"
        ]
        if len(failed_firsts) == 1:
            if (
                len(retries) != 1
                or group[-1] is not retries[0]
                or retries[0]["job"] != failed_firsts[0]["job"]
                or retries[0]["presentation_order"]
                != failed_firsts[0]["presentation_order"]
            ):
                raise ProtocolError(f"human system failure lacks its one final retry at {ordinal}")
        elif retries:
            raise ProtocolError(f"human retry is not allowed after {len(failed_firsts)} failures")


def validate_model_store(rows: list[dict[str, Any]], expected_count: int) -> None:
    """Require one ordered fresh-session row for every cohort schedule cell."""

    if len(rows) != expected_count:
        raise ProtocolError("model result store is incomplete")
    if [row["schedule_ordinal"] for row in rows] != list(range(expected_count)):
        raise ProtocolError("model result store is duplicated or reordered")
    subject_ids = [row["subject_id"] for row in rows]
    if len(set(subject_ids)) != expected_count:
        raise ProtocolError("model result store reuses a session subject_id")


def validate_result_store(
    rows: list[dict[str, Any]],
    manifest: dict[str, Any],
    schema: dict[str, Any],
    *,
    cohort: dict[str, Any] | None = None,
    authority: dict[str, Any] | None = None,
) -> tuple[int, set[str]]:
    """Validate one complete, single-kind result store and all cross-row pins."""

    verify_manifest(manifest)
    verify_result_schema(schema)
    if not rows:
        raise ProtocolError("result store is empty")
    kinds = {row.get("subject_kind") for row in rows if isinstance(row, dict)}
    if len(kinds) != 1:
        raise ProtocolError("human, model, and synthetic evidence must use separate stores")
    row_ids: set[str] = set()
    for row_number, row in enumerate(rows, start=1):
        try:
            validate_row(
                row,
                manifest,
                schema,
                cohort=cohort,
                authority=authority,
            )
        except ProtocolError as error:
            raise ProtocolError(f"row {row_number}: {error}") from error
        if row["row_id"] in row_ids:
            raise ProtocolError(f"row {row_number}: duplicate row_id")
        row_ids.add(row["row_id"])

    subject_kind = rows[0]["subject_kind"]
    conditions = {row["condition_id"] for row in rows}
    if subject_kind == "synthetic":
        expected = {f"{carrier}/{job}" for carrier in CARRIERS for job in JOBS}
        if len(rows) != len(expected) or conditions != expected:
            raise ProtocolError("synthetic result store must cover all 15 conditions once")
    elif subject_kind == "human":
        validate_human_store(rows)
    elif subject_kind == "model":
        if cohort is None:
            raise ProtocolError("model result store requires its exact cohort manifest")
        validate_model_store(
            rows, len(CARRIERS) * len(JOBS) * cohort["repetitions_per_condition"]
        )
    else:
        raise ProtocolError(f"unknown result store subject kind: {subject_kind}")
    return len(rows), conditions


def validate_jsonl(
    input_path: Path,
    manifest: dict[str, Any],
    schema: dict[str, Any],
    *,
    cohort: dict[str, Any] | None = None,
    authority: dict[str, Any] | None = None,
) -> tuple[int, set[str]]:
    """Load JSONL with line-local diagnostics, then validate the complete store."""

    _, _, count, conditions = load_validated_jsonl(
        input_path,
        manifest,
        schema,
        cohort=cohort,
        authority=authority,
    )
    return count, conditions


def load_jsonl_rows(input_path: Path) -> tuple[list[dict[str, Any]], str]:
    """Load JSONL rows and bind them to the SHA-256 of their exact source bytes.

    Duplicate fields, non-standard constants, invalid UTF-8, and non-object
    rows fail before result-store validation or analysis can begin.
    """

    try:
        source_bytes = input_path.read_bytes()
        source_text = source_bytes.decode("utf-8")
    except (OSError, UnicodeError) as error:
        raise ProtocolError(f"cannot load result JSONL {input_path}: {error}") from error
    rows: list[dict[str, Any]] = []
    for line_number, raw in enumerate(source_text.splitlines(), start=1):
        if not raw.strip():
            continue
        try:
            row = json.loads(
                raw,
                object_pairs_hook=unique_json_object,
                parse_constant=reject_json_constant,
            )
        except (json.JSONDecodeError, ProtocolError) as error:
            raise ProtocolError(f"{input_path}:{line_number}: {error}") from error
        if not isinstance(row, dict):
            raise ProtocolError(f"{input_path}:{line_number}: result row must be an object")
        rows.append(row)
    return rows, digest_bytes(source_bytes)


def load_validated_jsonl(
    input_path: Path,
    manifest: dict[str, Any],
    schema: dict[str, Any],
    *,
    cohort: dict[str, Any] | None = None,
    authority: dict[str, Any] | None = None,
) -> tuple[list[dict[str, Any]], str, int, set[str]]:
    """Load and validate a complete store before returning rows or provenance.

    Store-level failures retain the input path in their diagnostic.  No caller
    can prepare an analysis bundle from this helper unless the existing schema,
    admission-context, completeness, ordering, and retry checks all pass.
    """

    rows, input_sha256 = load_jsonl_rows(input_path)
    try:
        count, conditions = validate_result_store(
            rows,
            manifest,
            schema,
            cohort=cohort,
            authority=authority,
        )
    except ProtocolError as error:
        raise ProtocolError(f"{input_path}: {error}") from error
    return rows, input_sha256, count, conditions


def add_common_paths(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--schema", type=Path, required=True)


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    verify = commands.add_parser("verify", help="run all protocol and fixture conformance checks")
    add_common_paths(verify)
    verify.add_argument("--protocol", type=Path, required=True)
    verify.add_argument("--jacquard", type=Path, required=True)
    verify.add_argument("--prelude", type=Path, required=True)
    verify.add_argument("--cohort", type=Path, required=True)
    verify.add_argument("--authority", type=Path, required=True)

    dry_run = commands.add_parser("dry-run", help="emit deterministic synthetic JSONL rows")
    add_common_paths(dry_run)
    dry_run.add_argument("--seed", required=True)

    validate = commands.add_parser(
        "validate-results",
        help="validate one complete synthetic, human, or model result store",
    )
    add_common_paths(validate)
    validate.add_argument("--input", type=Path, required=True)
    validate.add_argument("--cohort", type=Path)
    validate.add_argument("--authority", type=Path, required=True)

    analysis = commands.add_parser(
        "prepare-analysis",
        help="validate a complete store and emit deterministic analyzability provenance",
    )
    add_common_paths(analysis)
    analysis.add_argument("--input", type=Path, required=True)
    analysis.add_argument("--cohort", type=Path)
    analysis.add_argument("--authority", type=Path, required=True)

    descriptive = commands.add_parser(
        "analyze-descriptive",
        help="validate a complete store and emit deterministic descriptive tables",
    )
    add_common_paths(descriptive)
    descriptive.add_argument("--input", type=Path, required=True)
    descriptive.add_argument("--cohort", type=Path)
    descriptive.add_argument("--authority", type=Path, required=True)

    assign = commands.add_parser(
        "assign", help="debug one seeded assignment; admitted rows always use the frozen seed"
    )
    assign.add_argument("--seed", required=True, help="debug-only assignment seed")
    assign.add_argument("--ordinal", type=int, required=True)

    commands.add_parser(
        "human-schedule",
        help="emit the frozen 480-enrollment de-identified assignment plan",
    )

    model_plan = commands.add_parser(
        "model-schedule",
        help="emit one cohort-specific model plan without calling a model",
    )
    model_plan.add_argument("--manifest", type=Path, required=True)
    model_plan.add_argument("--cohort", type=Path, required=True)

    collection_gate = commands.add_parser(
        "collection-gate",
        help="require approved study authority and an optional collectible model cohort",
    )
    add_common_paths(collection_gate)
    collection_gate.add_argument("--authority", type=Path, required=True)
    collection_gate.add_argument("--cohort", type=Path)

    verify_plans = commands.add_parser(
        "verify-schedules",
        help="verify CLI-generated human and model schedule bytes",
    )
    verify_plans.add_argument("--human", type=Path, required=True)
    verify_plans.add_argument("--model", type=Path, required=True)

    present = commands.add_parser("present", help="render one accessible plain-text trial")
    present.add_argument("--manifest", type=Path, required=True)
    present.add_argument("--carrier", choices=CARRIERS, required=True)
    present.add_argument("--job", choices=JOBS, required=True)
    return parser.parse_args(list(argv))


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    try:
        if args.command == "assign":
            print(json.dumps(assignment(args.seed, args.ordinal), sort_keys=True))
            return 0
        if args.command == "human-schedule":
            sys.stdout.write(encode_jsonl(human_schedule()))
            return 0
        if args.command == "verify-schedules":
            verify_schedule_files(args.human, args.model)
            print("readability schedules: PASS (480 human assignments, 450 M0 model trials)")
            return 0
        if args.command == "collection-gate":
            manifest = load_json(args.manifest)
            verify_manifest(manifest)
            schema = load_json(args.schema)
            verify_result_schema(schema)
            authority = load_json(args.authority)
            verify_authority_manifest(authority, require_authorized=True)
            subject = "human"
            pins = [
                f"fixtures={document_sha256(manifest, 'fixture manifest')}",
                f"schema={document_sha256(schema, 'result schema')}",
                f"authority={document_sha256(authority, 'authority manifest')}",
            ]
            if args.cohort is not None:
                cohort = load_json(args.cohort)
                verify_cohort_manifest(cohort, args.cohort, require_collectible=True)
                subject = f"model cohort {cohort['cohort_id']}"
                pins.append(f"cohort={document_sha256(cohort, 'model cohort manifest')}")
            print(f"readability collection gate: PASS ({subject}; {'; '.join(pins)})")
            return 0
        manifest = load_json(args.manifest)
        verify_manifest(manifest)
        if args.command == "model-schedule":
            cohort = load_json(args.cohort)
            verify_cohort_manifest(cohort, args.cohort)
            cohort_sha256 = document_sha256(cohort, "model cohort manifest")
            sys.stdout.write(encode_jsonl(model_schedule(manifest, cohort, cohort_sha256)))
            return 0
        if args.command == "present":
            sys.stdout.write(render_trial(manifest, args.manifest, args.carrier, args.job))
            return 0

        schema = load_json(args.schema)
        verify_result_schema(schema)
        if args.command == "dry-run":
            for row in make_dry_run_rows(args.seed, manifest, schema):
                print(
                    json.dumps(
                        row, sort_keys=True, separators=(",", ":"), allow_nan=False
                    )
                )
            return 0
        if args.command in {
            "validate-results",
            "prepare-analysis",
            "analyze-descriptive",
        }:
            authority = load_json(args.authority)
            verify_authority_manifest(authority)
            cohort = None
            if args.cohort is not None:
                cohort = load_json(args.cohort)
                verify_cohort_manifest(cohort, args.cohort)
            rows, input_sha256, count, conditions = load_validated_jsonl(
                args.input,
                manifest,
                schema,
                cohort=cohort,
                authority=authority,
            )
            if args.command == "prepare-analysis":
                sys.stdout.write(
                    encode_analysis_bundle(
                        prepare_analysis_bundle(rows, input_sha256)
                    )
                )
                return 0
            if args.command == "analyze-descriptive":
                analysis_input = prepare_analysis_bundle(rows, input_sha256)
                sys.stdout.write(
                    encode_descriptive_bundle(
                        prepare_descriptive_bundle(
                            rows, input_sha256, analysis_input
                        )
                    )
                )
                return 0
            print(f"validated {count} rows across {len(conditions)} conditions")
            return 0
        if args.command == "verify":
            cohort = load_json(args.cohort)
            authority = load_json(args.authority)
            self_test(
                manifest,
                args.manifest,
                schema,
                args.protocol,
                cohort,
                args.cohort,
                authority,
            )
            verify_fixtures(manifest, args.manifest, args.jacquard, args.prelude)
            print("readability protocol: PASS (5 jobs, 3 carriers, 15 dry-run conditions)")
            return 0
        raise ProtocolError(f"unknown command: {args.command}")
    except (OSError, ProtocolError, AnalysisError, DescriptiveError) as error:
        print(f"readability protocol: FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
