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
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Iterable


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


def digest_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest_text(text: str) -> str:
    return digest_bytes(text.encode("utf-8"))


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ProtocolError(f"cannot load JSON {path}: {error}") from error
    if not isinstance(value, dict):
        raise ProtocolError(f"{path} must contain one JSON object")
    return value


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
        json.dumps(row, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n"
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
        if name == "number" and isinstance(value, (int, float)) and not isinstance(value, bool):
            return True
        if name == "string" and isinstance(value, str):
            return True
        if name == "array" and isinstance(value, list):
            return True
        if name == "object" and isinstance(value, dict):
            return True
    return False


def validate_property(name: str, value: Any, rule: dict[str, Any]) -> None:
    declared_type = rule.get("type")
    if declared_type is not None and not json_type_matches(value, declared_type):
        raise ProtocolError(f"result {name} has the wrong JSON type")
    if "const" in rule and value != rule["const"]:
        raise ProtocolError(f"result {name} must equal {rule['const']!r}")
    if "enum" in rule and value not in rule["enum"]:
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
            for item in value:
                validate_property(f"{name}[]", item, item_rule)


def canonical_row_id(row: dict[str, Any]) -> str:
    body = {key: value for key, value in row.items() if key != "row_id"}
    encoded = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return digest_text(encoded)


def validate_row(
    row: dict[str, Any],
    manifest: dict[str, Any],
    schema: dict[str, Any],
) -> None:
    if not isinstance(row, dict):
        raise ProtocolError("each result row must be a JSON object")
    required = set(schema.get("required", []))
    properties = schema.get("properties", {})
    missing = required - set(row)
    extra = set(row) - set(properties)
    if missing:
        raise ProtocolError(f"result row is missing fields: {', '.join(sorted(missing))}")
    if schema.get("additionalProperties") is False and extra:
        raise ProtocolError(f"result row has unknown fields: {', '.join(sorted(extra))}")
    for name, value in row.items():
        rule = properties[name]
        if "oneOf" in rule:
            if value is None:
                validate_property(name, value, rule["oneOf"][0])
            elif isinstance(value, dict):
                object_rule = rule["oneOf"][1]
                if set(value) != set(object_rule["required"]):
                    raise ProtocolError("result model fields do not match the pinned schema")
                for model_name, model_value in value.items():
                    validate_property(
                        f"model.{model_name}", model_value, object_rule["properties"][model_name]
                    )
            else:
                raise ProtocolError(f"result {name} matches no schema branch")
        else:
            validate_property(name, value, rule)

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
    if row["error_code"] in failure_exclusions:
        required_exclusion = failure_exclusions[row["error_code"]]
        if required_exclusion not in row["exclusion_codes"]:
            raise ProtocolError("failure result is missing its required exclusion code")
    if row["row_id"] != canonical_row_id(row):
        raise ProtocolError("row_id is not the canonical SHA-256 of the result row")
    if row["run_kind"] != "dry-run" and row["assignment_seed_sha256"] != digest_text(
        CONFIRMATORY_SEED
    ):
        raise ProtocolError("real result row does not use the frozen assignment seed")

    subject_kind = row["subject_kind"]
    if subject_kind == "synthetic":
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
        raise ProtocolError(
            "real result admission is not enabled by the planning harness; "
            "collection remains closed"
        )


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
                "fixture_sha256": fixture["sources"][carrier]["sha256"],
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
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        raise ProtocolError("result schema must pin JSON Schema draft 2020-12")
    if schema.get("additionalProperties") is not False:
        raise ProtocolError("result schema must reject unknown fields")
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

    real_row = copy.deepcopy(rows[0])
    real_row.update(
        {
            "run_kind": "confirmatory",
            "subject_kind": "human",
            "assignment_seed_sha256": digest_text(CONFIRMATORY_SEED),
        }
    )
    real_row["row_id"] = canonical_row_id(real_row)
    try:
        validate_row(real_row, manifest, schema)
    except ProtocolError:
        pass
    else:
        raise ProtocolError("planning harness accepted a real result row")

    for carrier in CARRIERS:
        for job in JOBS:
            rendered = render_trial(manifest, manifest_path, carrier, job)
            if "\x1b" in rendered or "```" in rendered or "<span" in rendered:
                raise ProtocolError("presentation added highlighting or markup")

    mutations = (
        ("syntax highlighting", "syntax_highlighting", True),
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


def validate_jsonl(
    input_path: Path,
    manifest: dict[str, Any],
    schema: dict[str, Any],
) -> tuple[int, set[str]]:
    count = 0
    conditions: set[str] = set()
    row_ids: set[str] = set()
    for line_number, raw in enumerate(input_path.read_text(encoding="utf-8").splitlines(), start=1):
        if not raw.strip():
            continue
        try:
            row = json.loads(raw)
            validate_row(row, manifest, schema)
        except (json.JSONDecodeError, ProtocolError) as error:
            raise ProtocolError(f"{input_path}:{line_number}: {error}") from error
        if row["row_id"] in row_ids:
            raise ProtocolError(f"{input_path}:{line_number}: duplicate row_id")
        row_ids.add(row["row_id"])
        conditions.add(row["condition_id"])
        count += 1
    return count, conditions


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
        help="validate v1 synthetic JSONL; real-result admission remains closed",
    )
    add_common_paths(validate)
    validate.add_argument("--input", type=Path, required=True)
    validate.add_argument("--cohort", type=Path, required=True)
    validate.add_argument("--authority", type=Path, required=True)

    assign = commands.add_parser("assign", help="print one seeded balanced assignment as JSON")
    assign.add_argument("--seed", required=True)
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
        manifest = load_json(args.manifest)
        verify_manifest(manifest)
        if args.command == "model-schedule":
            cohort = load_json(args.cohort)
            verify_cohort_manifest(cohort, args.cohort)
            cohort_sha256 = digest_bytes(args.cohort.read_bytes())
            sys.stdout.write(encode_jsonl(model_schedule(manifest, cohort, cohort_sha256)))
            return 0
        if args.command == "present":
            sys.stdout.write(render_trial(manifest, args.manifest, args.carrier, args.job))
            return 0

        schema = load_json(args.schema)
        if args.command == "dry-run":
            for row in make_dry_run_rows(args.seed, manifest, schema):
                print(json.dumps(row, sort_keys=True, separators=(",", ":")))
            return 0
        if args.command == "validate-results":
            cohort = load_json(args.cohort)
            authority = load_json(args.authority)
            verify_cohort_manifest(cohort, args.cohort)
            verify_authority_manifest(authority)
            count, conditions = validate_jsonl(args.input, manifest, schema)
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
    except (OSError, ProtocolError) as error:
        print(f"readability protocol: FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
