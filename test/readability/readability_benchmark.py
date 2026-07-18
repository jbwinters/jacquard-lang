#!/usr/bin/env python3
"""Deterministic UX.0 fixture verifier, assignment tool, scorer, and dry runner.

The tool uses only the Python standard library.  It never collects participants
or calls a model; real-study orchestration belongs to the separately reviewed
execution phase.  Invalid manifests, result rows, or fixture evidence fail with
a concise message and a nonzero exit status.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Iterable


SCHEMA_VERSION = "readability-result-v0"
PROTOCOL_VERSION = "readability-protocol-v0"
CARRIERS = ("jac", "jqd", "python")
JOBS = ("seeded-bug", "predict-output", "authority-escalation")
JOB_ORDERS = tuple(itertools.permutations(JOBS))
FIXED_DRY_RUN_TIME = "2000-01-01T00:00:00Z"
CONFIRMATORY_SEED = "jacquard-readability-v0"


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


def verify_manifest(manifest: dict[str, Any], manifest_path: Path) -> None:
    if manifest.get("schema_version") != "readability-fixtures-v0":
        raise ProtocolError("unexpected fixture manifest schema_version")
    if manifest.get("protocol_version") != PROTOCOL_VERSION:
        raise ProtocolError("fixture manifest protocol_version drift")
    if manifest.get("license") != "Apache-2.0":
        raise ProtocolError("fixture license must remain explicit and Apache-2.0")
    if tuple(manifest.get("carriers", ())) != CARRIERS:
        raise ProtocolError("carrier inventory or order drift")
    if tuple(manifest.get("jobs", ())) != JOBS:
        raise ProtocolError("reviewer-job inventory or order drift")
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
    for required in ("task-equivalent", "hash_v0", "effect", "runtime", "stdout"):
        if required not in limitation_text:
            raise ProtocolError(f"Python matching limits must name {required}")

    model = manifest.get("model_condition", {})
    required_model = {
        "provider": "Anthropic",
        "model": "claude-fable-5",
        "client": "Claude Code 2.1.212",
        "temperature": 0.0,
        "repetitions_per_condition": 30,
        "tools": "disabled",
        "session_memory": "disabled",
    }
    for key, expected in required_model.items():
        if model.get(key) != expected:
            raise ProtocolError(f"model condition {key} must be pinned to {expected!r}")
    prompt_path = manifest_path.parent / model.get("prompt", "")
    try:
        prompt_digest = digest_bytes(prompt_path.read_bytes())
    except OSError as error:
        raise ProtocolError(f"cannot read model prompt {prompt_path}: {error}") from error
    if prompt_digest != model.get("prompt_sha256"):
        raise ProtocolError("model prompt digest drift")

    indexed = fixture_index(manifest)
    if tuple(indexed) != JOBS:
        raise ProtocolError("there must be exactly one fixture per reviewer job, in protocol order")
    for fixture_id, fixture in indexed.items():
        if fixture.get("job") != fixture_id:
            raise ProtocolError(f"fixture/job mismatch: {fixture_id}")
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
                        f"{fixture_id}.{carrier} must fail closed with {refusal_code} without its grant"
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


def score_answer(fixture: dict[str, Any], answer_id: str) -> tuple[bool, str | None]:
    options = {option["id"] for option in fixture["options"]}
    if answer_id == "__timeout__":
        return False, "timeout"
    if answer_id not in options:
        return False, "invalid-answer"
    if answer_id == fixture["correct_answer"]:
        return True, None
    return False, fixture["wrong_answer_errors"][answer_id]


def exclusion_codes(subject_kind: str, facts: dict[str, Any], manifest: dict[str, Any]) -> list[str]:
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
        pinned = manifest["model_condition"]
        checks = (
            (
                not facts.get("training_cutoff_attested", False),
                "model-training-contamination",
            ),
            (
                facts.get("model") != pinned["model"]
                or facts.get("client") != pinned["client"],
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
        if rule.get("uniqueItems") and len({json.dumps(item, sort_keys=True) for item in value}) != len(value):
            raise ProtocolError(f"result {name} must contain unique items")
        item_rule = rule.get("items")
        if item_rule:
            for item in value:
                validate_property(f"{name}[]", item, item_rule)


def canonical_row_id(row: dict[str, Any]) -> str:
    body = {key: value for key, value in row.items() if key != "row_id"}
    encoded = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return digest_text(encoded)


def validate_row(row: dict[str, Any], manifest: dict[str, Any], schema: dict[str, Any]) -> None:
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
    expected_correct, expected_error = score_answer(fixture, row["answer_id"])
    if (row["correct"], row["error_code"]) != (expected_correct, expected_error):
        raise ProtocolError("correct/error_code does not follow deterministic scoring")
    if row["answer_id"] == "__timeout__" and row["completion_ms"] != 300000:
        raise ProtocolError("timeout rows must use the frozen timeout duration")
    if row["fixture_sha256"] != fixture["sources"][row["carrier"]]["sha256"]:
        raise ProtocolError("result fixture digest does not match the manifest")
    if row["excluded"] != bool(row["exclusion_codes"]):
        raise ProtocolError("excluded must exactly reflect exclusion_codes")
    if row["row_id"] != canonical_row_id(row):
        raise ProtocolError("row_id is not the canonical SHA-256 of the result row")
    if row["run_kind"] == "confirmatory" and row["assignment_seed_sha256"] != digest_text(
        CONFIRMATORY_SEED
    ):
        raise ProtocolError("confirmatory row does not use the frozen assignment seed")

    subject_kind = row["subject_kind"]
    if subject_kind == "human":
        if row["run_kind"] != "confirmatory" or not row["consent_version"] or row["model"] is not None:
            raise ProtocolError("human row consent/model contract violated")
    elif subject_kind == "model":
        pinned = manifest["model_condition"]
        model = row["model"]
        if row["run_kind"] != "confirmatory" or row["consent_version"] is not None or not isinstance(model, dict):
            raise ProtocolError("model row consent/model contract violated")
        for key in ("provider", "model", "client", "prompt_sha256", "temperature"):
            if model[key] != pinned[key]:
                raise ProtocolError(f"model result drifted from pinned {key}")
        contaminated = not model["training_cutoff_attested"]
        if contaminated != ("model-training-contamination" in row["exclusion_codes"]):
            raise ProtocolError("model training-cutoff attestation/exclusion mismatch")
    elif subject_kind == "synthetic":
        if row["run_kind"] != "dry-run" or row["consent_version"] is not None or row["model"] is not None:
            raise ProtocolError("synthetic rows are dry-run only and carry no consent/model record")


def make_dry_run_rows(seed: str, manifest: dict[str, Any], schema: dict[str, Any]) -> list[dict[str, Any]]:
    indexed = fixture_index(manifest)
    seed_digest = digest_text(seed)
    rows: list[dict[str, Any]] = []
    for carrier in CARRIERS:
        order = sorted(JOBS, key=lambda job: digest_text(f"{seed}\0{carrier}\0{job}"))
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
                "fixture_id": fixture["id"],
                "condition_id": f"{carrier}/{job}",
                "presentation_order": position,
                "answer_id": fixture["correct_answer"],
                "correct": True,
                "completion_ms": 1000 + len(rows),
                "confidence": 100,
                "error_code": None,
                "excluded": False,
                "exclusion_codes": [],
                "assignment_seed_sha256": seed_digest,
                "fixture_sha256": fixture["sources"][carrier]["sha256"],
                "plain_text": True,
                "syntax_highlighting": False,
                "consent_version": None,
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
        "between-subject",
        "counterbalance",
        "completion time",
        "confidence",
        "human and model results",
        "plain text",
        "sample size",
        "consent",
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
    manifest: dict[str, Any], manifest_path: Path, schema: dict[str, Any], protocol_path: Path
) -> None:
    verify_manifest(manifest, manifest_path)
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        raise ProtocolError("result schema must pin JSON Schema draft 2020-12")
    if schema.get("additionalProperties") is not False:
        raise ProtocolError("result schema must reject unknown fields")
    verify_protocol_document(protocol_path)

    first = assignment("ux0-self-test", 0)
    if first != assignment("ux0-self-test", 0):
        raise ProtocolError("assignment is not deterministic")
    block = [assignment("ux0-self-test", ordinal) for ordinal in range(18)]
    if {item["carrier"] for item in block} != set(CARRIERS):
        raise ProtocolError("assignment block omitted a carrier")
    for carrier in CARRIERS:
        orders = [tuple(item["job_order"]) for item in block if item["carrier"] == carrier]
        if set(orders) != set(JOB_ORDERS):
            raise ProtocolError(f"assignment block does not counterbalance all job orders for {carrier}")

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
        manifest,
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
    pinned = manifest["model_condition"]
    clean_model = {
        "training_cutoff_attested": True,
        "model": pinned["model"],
        "client": pinned["client"],
        "prompt_parse_failure": False,
        "system_failures": 0,
    }
    if exclusion_codes("model", clean_model, manifest):
        raise ProtocolError("eligible pinned model was excluded")
    contaminated = dict(clean_model, training_cutoff_attested=False)
    if exclusion_codes("model", contaminated, manifest) != ["model-training-contamination"]:
        raise ProtocolError("model contamination exclusion failed")

    rows = make_dry_run_rows("ux0-self-test", manifest, schema)
    expected_conditions = {f"{carrier}/{job}" for carrier in CARRIERS for job in JOBS}
    if len(rows) != 9 or {row["condition_id"] for row in rows} != expected_conditions:
        raise ProtocolError("dry run must emit exactly one valid row per condition")
    if len({row["row_id"] for row in rows}) != len(rows):
        raise ProtocolError("dry-run row IDs must be unique")

    human = copy.deepcopy(rows[0])
    human.update(
        {
            "run_kind": "confirmatory",
            "subject_kind": "human",
            "subject_id": digest_text("human-self-test")[:24],
            "assignment_seed_sha256": digest_text(CONFIRMATORY_SEED),
            "consent_version": "consent-v0",
        }
    )
    human["row_id"] = canonical_row_id(human)
    validate_row(human, manifest, schema)

    model = copy.deepcopy(rows[1])
    pinned_model = manifest["model_condition"]
    model.update(
        {
            "run_kind": "confirmatory",
            "subject_kind": "model",
            "subject_id": digest_text("model-self-test")[:24],
            "assignment_seed_sha256": digest_text(CONFIRMATORY_SEED),
            "model": {
                "provider": pinned_model["provider"],
                "model": pinned_model["model"],
                "client": pinned_model["client"],
                "prompt_sha256": pinned_model["prompt_sha256"],
                "temperature": pinned_model["temperature"],
                "repetition": 1,
                "training_cutoff_attested": True,
            },
        }
    )
    model["row_id"] = canonical_row_id(model)
    validate_row(model, manifest, schema)

    for carrier in CARRIERS:
        for job in JOBS:
            rendered = render_trial(manifest, manifest_path, carrier, job)
            if "\x1b" in rendered or "```" in rendered or "<span" in rendered:
                raise ProtocolError("presentation added highlighting or markup")

    mutation = copy.deepcopy(rows[0])
    mutation["syntax_highlighting"] = True
    mutation["row_id"] = canonical_row_id(mutation)
    try:
        validate_row(mutation, manifest, schema)
    except ProtocolError:
        pass
    else:
        raise ProtocolError("schema validator accepted syntax highlighting")
    mutation = copy.deepcopy(rows[0])
    del mutation["confidence"]
    try:
        validate_row(mutation, manifest, schema)
    except ProtocolError:
        pass
    else:
        raise ProtocolError("schema validator accepted a missing required field")
    mutation = copy.deepcopy(human)
    mutation["assignment_seed_sha256"] = digest_text("wrong-seed")
    mutation["row_id"] = canonical_row_id(mutation)
    try:
        validate_row(mutation, manifest, schema)
    except ProtocolError:
        pass
    else:
        raise ProtocolError("schema validator accepted confirmatory assignment-seed drift")
    mutation = copy.deepcopy(model)
    mutation["model"]["client"] = "unreviewed-client"
    mutation["row_id"] = canonical_row_id(mutation)
    try:
        validate_row(mutation, manifest, schema)
    except ProtocolError:
        pass
    else:
        raise ProtocolError("schema validator accepted model-version drift")


def validate_jsonl(
    input_path: Path, manifest: dict[str, Any], schema: dict[str, Any]
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

    dry_run = commands.add_parser("dry-run", help="emit deterministic synthetic JSONL rows")
    add_common_paths(dry_run)
    dry_run.add_argument("--seed", required=True)

    validate = commands.add_parser("validate-results", help="validate a JSONL result artifact")
    add_common_paths(validate)
    validate.add_argument("--input", type=Path, required=True)

    assign = commands.add_parser("assign", help="print one seeded balanced assignment as JSON")
    assign.add_argument("--seed", required=True)
    assign.add_argument("--ordinal", type=int, required=True)

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

        manifest = load_json(args.manifest)
        verify_manifest(manifest, args.manifest)
        if args.command == "present":
            sys.stdout.write(render_trial(manifest, args.manifest, args.carrier, args.job))
            return 0

        schema = load_json(args.schema)
        if args.command == "dry-run":
            for row in make_dry_run_rows(args.seed, manifest, schema):
                print(json.dumps(row, sort_keys=True, separators=(",", ":")))
            return 0
        if args.command == "validate-results":
            count, conditions = validate_jsonl(args.input, manifest, schema)
            print(f"validated {count} rows across {len(conditions)} conditions")
            return 0
        if args.command == "verify":
            self_test(manifest, args.manifest, schema, args.protocol)
            verify_fixtures(manifest, args.manifest, args.jacquard, args.prelude)
            print("readability protocol: PASS (3 jobs, 3 carriers, 9 dry-run conditions)")
            return 0
        raise ProtocolError(f"unknown command: {args.command}")
    except (OSError, ProtocolError) as error:
        print(f"readability protocol: FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
