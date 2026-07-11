#!/usr/bin/env python3
"""Privacy-preserving reconciliation helpers for TokenScope usage data."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


TOKEN_FIELDS = (
    "input_tokens",
    "output_tokens",
    "cache_creation_tokens",
    "cache_read_tokens",
    "total_tokens",
)


def _zero_usage() -> Dict[str, int]:
    return {field: 0 for field in TOKEN_FIELDS}


def usage(
    input_tokens: int = 0,
    output_tokens: int = 0,
    cache_creation_tokens: int = 0,
    cache_read_tokens: int = 0,
) -> Dict[str, int]:
    values = {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cache_creation_tokens": cache_creation_tokens,
        "cache_read_tokens": cache_read_tokens,
    }
    values["total_tokens"] = sum(values.values())
    return values


def _add_usage(target: Dict[str, int], value: Dict[str, int]) -> None:
    for field in TOKEN_FIELDS:
        target[field] += int(value.get(field, 0))


def _subtract_usage(left: Dict[str, int], right: Dict[str, int]) -> Dict[str, int]:
    return {field: int(left.get(field, 0)) - int(right.get(field, 0)) for field in TOKEN_FIELDS}


def _parse_timestamp(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _swift_json_int(value: Any) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


@dataclass
class ClaudeAuditSession:
    session_id: str
    started_at: datetime
    ended_at: datetime
    usage_records: List[Dict[str, Any]]
    usage: Dict[str, int]
    message_count: int
    source_path: Optional[Path] = None

    @classmethod
    def fixture(
        cls,
        session_id: str,
        timestamps: List[datetime],
        total: int,
    ) -> "ClaudeAuditSession":
        records = [
            {
                "timestamp": timestamp,
                "usage": {
                    "input_tokens": total if index == 0 else 0,
                    "output_tokens": 0,
                    "cache_creation_tokens": 0,
                    "cache_read_tokens": 0,
                    "total_tokens": total if index == 0 else 0,
                },
            }
            for index, timestamp in enumerate(timestamps)
        ]
        usage = _zero_usage()
        usage["input_tokens"] = total
        usage["total_tokens"] = total
        return cls(
            session_id=session_id,
            started_at=min(timestamps),
            ended_at=max(timestamps),
            usage_records=records,
            usage=usage,
            message_count=len(records),
        )


def parse_claude_file(path: Path) -> ClaudeAuditSession:
    embedded_session_id: Optional[str] = None
    started_at: Optional[datetime] = None
    ended_at: Optional[datetime] = None
    usage_records: List[Dict[str, Any]] = []
    totals = _zero_usage()

    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            if not raw_line.strip():
                continue
            try:
                row = json.loads(raw_line)
            except (json.JSONDecodeError, TypeError):
                continue
            if not isinstance(row, dict):
                continue

            candidate = row.get("sessionId")
            if embedded_session_id is None and isinstance(candidate, str) and candidate:
                embedded_session_id = candidate

            timestamp = _parse_timestamp(row.get("timestamp"))
            if timestamp is not None:
                if started_at is None:
                    started_at = timestamp
                ended_at = timestamp

            message = row.get("message") if row.get("type") == "assistant" else None
            usage = message.get("usage") if isinstance(message, dict) else None
            model = message.get("model") if isinstance(message, dict) else None
            if not isinstance(usage, dict) or not isinstance(model, str):
                continue

            parsed_usage = {
                "input_tokens": _swift_json_int(usage.get("input_tokens")),
                "output_tokens": _swift_json_int(usage.get("output_tokens")),
                "cache_creation_tokens": _swift_json_int(usage.get("cache_creation_input_tokens")),
                "cache_read_tokens": _swift_json_int(usage.get("cache_read_input_tokens")),
            }
            parsed_usage["total_tokens"] = sum(parsed_usage.values())
            if parsed_usage["total_tokens"] <= 0:
                continue

            record_timestamp = timestamp or ended_at or datetime.now(timezone.utc)
            usage_records.append(
                {"timestamp": record_timestamp, "model": model, "usage": parsed_usage}
            )
            for field in TOKEN_FIELDS:
                totals[field] += parsed_usage[field]

    fallback = datetime.fromtimestamp(0, tz=timezone.utc)
    path_text = str(path)
    session_id = (
        "subagent:" + path.stem
        if "/subagents/" in path_text
        else embedded_session_id or path.stem
    )
    return ClaudeAuditSession(
        session_id=session_id,
        started_at=started_at or fallback,
        ended_at=ended_at or started_at or fallback,
        usage_records=usage_records,
        usage=totals,
        message_count=len(usage_records),
        source_path=path,
    )


def select_claude_samples(
    sessions: List[ClaudeAuditSession],
    week_start: datetime,
) -> Dict[str, Optional[ClaudeAuditSession]]:
    valid = [session for session in sessions if session.usage["total_tokens"] > 0]
    if not valid:
        return {
            "small": None,
            "largest": None,
            "cross_boundary": None,
            "boundary_alternative": None,
        }
    crossing = [
        session
        for session in valid
        if any(record["timestamp"] < week_start for record in session.usage_records)
        and any(record["timestamp"] >= week_start for record in session.usage_records)
    ]
    boundary_alternative = min(
        valid,
        key=lambda session: min(
            abs((record["timestamp"] - week_start).total_seconds())
            for record in session.usage_records
        ),
    )
    return {
        "small": min(valid, key=lambda session: session.usage["total_tokens"]),
        "largest": max(valid, key=lambda session: session.usage["total_tokens"]),
        "cross_boundary": max(crossing, key=lambda session: session.ended_at) if crossing else None,
        "boundary_alternative": boundary_alternative,
    }


def aggregate_claude_windows(
    sessions: List[ClaudeAuditSession],
    now: datetime,
) -> Dict[str, Any]:
    valid = [session for session in sessions if session.usage["total_tokens"] > 0]
    week_start = now - timedelta(days=7)
    all_time = _zero_usage()
    last_seven_days = _zero_usage()
    for session in valid:
        _add_usage(all_time, session.usage)
        for record in session.usage_records:
            if week_start <= record["timestamp"] <= now:
                _add_usage(last_seven_days, record["usage"])
    def activity_key(session: ClaudeAuditSession):
        latest_usage = max(
            (record["timestamp"] for record in session.usage_records),
            default=session.ended_at,
        )
        return (latest_usage, session.started_at, session.session_id)

    latest = max(valid, key=activity_key) if valid else None
    return {
        "all-time": all_time,
        "last-7d": last_seven_days,
        "latest-session": dict(latest.usage) if latest else _zero_usage(),
        "latest_session_id": latest.session_id if latest else None,
        "week_start": week_start.isoformat(),
    }


def compare_usage(expected: Dict[str, int], actual: Dict[str, int]) -> Dict[str, Any]:
    deltas = {field: int(actual.get(field, 0)) - int(expected.get(field, 0)) for field in TOKEN_FIELDS}
    max_absolute_delta = max(abs(value) for value in deltas.values())
    return {
        "passed": max_absolute_delta == 0,
        "deltas": deltas,
        "max_absolute_delta": max_absolute_delta,
    }


def extract_codex_windows(response: Dict[str, Any]) -> List[Dict[str, Any]]:
    rate_limit = response.get("rate_limit") or {}
    output: List[Dict[str, Any]] = []
    for source_key, identifier in (("primary_window", "session"), ("secondary_window", "weekly")):
        raw = rate_limit.get(source_key)
        if not isinstance(raw, dict):
            continue
        used_percent = raw.get("used_percent")
        output.append(
            {
                "id": identifier,
                "used_percent": used_percent,
                "remaining_percent": max(0, 100 - used_percent)
                if isinstance(used_percent, int) and not isinstance(used_percent, bool)
                else None,
                "reset_at": raw.get("reset_at"),
                "limit_window_seconds": raw.get("limit_window_seconds"),
            }
        )
    return output


def _epoch_seconds(value: Any) -> Optional[int]:
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        parsed = _parse_timestamp(value)
        return int(parsed.timestamp()) if parsed else None
    return None


def compare_codex_windows(
    official: List[Dict[str, Any]],
    cached: List[Dict[str, Any]],
    percent_tolerance: int = 1,
) -> Dict[str, Any]:
    required_ids = ["session", "weekly"]
    expected_window_seconds = {"session": 18_000, "weekly": 604_800}
    official_by_id = {row.get("id"): row for row in official}
    missing_official = [identifier for identifier in required_ids if identifier not in official_by_id]
    invalid_official = []
    for identifier in required_ids:
        row = official_by_id.get(identifier)
        if row is None:
            continue
        used_percent = row.get("used_percent")
        reset_at = row.get("reset_at")
        window_seconds = row.get("limit_window_seconds")
        valid = (
            isinstance(used_percent, int)
            and not isinstance(used_percent, bool)
            and 0 <= used_percent <= 100
            and isinstance(reset_at, int)
            and not isinstance(reset_at, bool)
            and reset_at > 0
            and window_seconds == expected_window_seconds[identifier]
        )
        if not valid:
            invalid_official.append(identifier)
    cached_by_id = {row.get("id"): row for row in cached}
    rows = []
    passed = not missing_official and not invalid_official
    for identifier in required_ids:
        expected = official_by_id.get(identifier)
        if expected is None:
            rows.append({"id": identifier, "passed": False, "reason": "missing_official"})
            continue
        if identifier in invalid_official:
            rows.append({"id": identifier, "passed": False, "reason": "invalid_official"})
            continue
        actual = cached_by_id.get(identifier)
        if actual is None:
            rows.append({"id": identifier, "passed": False, "reason": "missing_cache"})
            passed = False
            continue
        percent_delta = int(actual.get("usedPercent", 0)) - int(expected["used_percent"])
        reset_delta = (_epoch_seconds(actual.get("resetsAt")) or 0) - int(expected["reset_at"])
        row_passed = abs(percent_delta) <= percent_tolerance and reset_delta == 0
        rows.append(
            {
                "id": identifier,
                "used_percent_delta": percent_delta,
                "reset_seconds_delta": reset_delta,
                "passed": row_passed,
            }
        )
        passed = passed and row_passed
    return {
        "passed": passed,
        "windows": rows,
        "percent_tolerance": percent_tolerance,
        "missing_official_window_ids": missing_official,
        "invalid_official_window_ids": invalid_official,
    }


def select_codex_credentials(auth: Dict[str, Any]) -> Dict[str, Any]:
    tokens = auth.get("tokens")
    if isinstance(tokens, dict):
        access_token = tokens.get("access_token") or tokens.get("accessToken")
        refresh_token = tokens.get("refresh_token") or tokens.get("refreshToken")
        if isinstance(access_token, str) and access_token and isinstance(refresh_token, str):
            return {
                "source": "oauth_tokens",
                "access_token": access_token,
                "account_id": tokens.get("account_id") or tokens.get("accountId"),
                "oauth_precedence_verified": bool(auth.get("OPENAI_API_KEY")),
            }
    api_key = auth.get("OPENAI_API_KEY")
    if isinstance(api_key, str) and api_key.strip():
        return {
            "source": "api_key_fallback",
            "access_token": api_key,
            "account_id": None,
            "oauth_precedence_verified": False,
        }
    raise ValueError("No usable Codex credentials")


def public_codex_credential_summary(
    auth: Dict[str, Any],
    selected: Dict[str, Any],
) -> Dict[str, Any]:
    return {
        "source": selected["source"],
        "oauth_tokens_present": isinstance(auth.get("tokens"), dict),
        "api_key_present": bool(auth.get("OPENAI_API_KEY")),
        "oauth_precedence_verified": bool(selected.get("oauth_precedence_verified")),
        "account_id_present": bool(selected.get("account_id")),
    }


def _oauth_identity_email(auth: Dict[str, Any]) -> Optional[str]:
    tokens = auth.get("tokens")
    if not isinstance(tokens, dict):
        return None
    raw = tokens.get("id_token") or tokens.get("idToken")
    if not isinstance(raw, str) or raw.count(".") < 2:
        return None
    try:
        encoded_payload = raw.split(".", 2)[1]
        encoded_payload += "=" * ((4 - len(encoded_payload) % 4) % 4)
        payload = json.loads(base64.urlsafe_b64decode(encoded_payload).decode("utf-8"))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    email = payload.get("email") if isinstance(payload, dict) else None
    if not isinstance(email, str) and isinstance(payload, dict):
        profile = payload.get("https://api.openai.com/profile")
        email = profile.get("email") if isinstance(profile, dict) else None
    if not isinstance(email, str) or not email.strip():
        return None
    return email.strip().casefold()


def _identity_digest(value: str) -> bytes:
    normalized = value.strip().casefold()
    return hashlib.sha256(
        b"tokenscope/codex/email/v1\0" + normalized.encode("utf-8")
    ).digest()


def _account_id_fingerprint(account_id: Any) -> Optional[str]:
    if not isinstance(account_id, str):
        return None
    normalized = account_id.strip()
    if not normalized:
        return None
    return hashlib.sha256(
        b"tokenscope/codex/account-id/v1\0" + normalized.encode("utf-8")
    ).hexdigest()


def _codex_account_provenance(
    auth: Dict[str, Any],
    selected_credentials: Dict[str, Any],
    cached_snapshot: Dict[str, Any],
) -> Dict[str, Any]:
    live_identity = _oauth_identity_email(auth)
    cached_identity = cached_snapshot.get("identitySummary")
    cached_identity = (
        cached_identity.strip().casefold()
        if isinstance(cached_identity, str) and cached_identity.strip()
        else None
    )
    source_is_live_system_oauth = (
        selected_credentials.get("source") == "oauth_tokens"
        and cached_snapshot.get("selectedAccountID") == "live-system"
    )
    email_matched = bool(
        live_identity
        and cached_identity
        and hmac.compare_digest(
            _identity_digest(live_identity),
            _identity_digest(cached_identity),
        )
    )
    live_account_fingerprint = _account_id_fingerprint(
        selected_credentials.get("account_id")
    )
    cached_account_fingerprint = cached_snapshot.get("providerAccountFingerprint")
    cached_account_fingerprint = (
        cached_account_fingerprint.strip().lower()
        if isinstance(cached_account_fingerprint, str)
        else None
    )
    account_id_matched = bool(
        source_is_live_system_oauth
        and live_account_fingerprint
        and cached_account_fingerprint
        and hmac.compare_digest(
            live_account_fingerprint,
            cached_account_fingerprint,
        )
    )
    return {
        "live_identity_available": live_identity is not None,
        "cached_identity_available": cached_identity is not None,
        "cache_source_is_live_system_oauth": source_is_live_system_oauth,
        "provider_account_fingerprint_available": cached_account_fingerprint is not None,
        "provider_account_fingerprint_matched": account_id_matched,
        "email_diagnostic_matched": email_matched,
        "provenance_strength": "account_id" if account_id_matched else ("email" if email_matched else "none"),
        "account_provenance_passed": account_id_matched,
    }


def compare_cache_freshness(
    cached_updated_at: Optional[datetime],
    captured_at: datetime,
    tolerance_seconds: int = 60,
) -> Dict[str, Any]:
    raw_age_seconds = (
        (captured_at - cached_updated_at).total_seconds()
        if cached_updated_at is not None
        else None
    )
    passed = bool(
        raw_age_seconds is not None
        and 0 <= raw_age_seconds <= tolerance_seconds
    )
    return {
        "cache_age_seconds": round(raw_age_seconds, 6)
        if raw_age_seconds is not None
        else None,
        "freshness_tolerance_seconds": tolerance_seconds,
        "freshness_passed": passed,
    }


def cache_record(
    session_id: str,
    message_index: int,
    timestamp: str,
    input_tokens: int,
) -> Dict[str, Any]:
    return {
        "sessionId": session_id,
        "messageIndex": message_index,
        "provider": "claude_code",
        "timestamp": timestamp,
        "usage": {
            "inputTokens": input_tokens,
            "outputTokens": 0,
            "cacheCreationTokens": 0,
            "cacheReadTokens": 0,
        },
    }


def cache_claude_window(identifier: str, input_tokens: int) -> Dict[str, Any]:
    return {
        "id": identifier,
        "kind": "token_summary",
        "tokenUsage": {
            "inputTokens": input_tokens,
            "outputTokens": 0,
            "cacheCreationTokens": 0,
            "cacheReadTokens": 0,
        },
    }


def _usage_from_cache(raw: Optional[Dict[str, Any]]) -> Dict[str, int]:
    raw = raw or {}
    return usage(
        input_tokens=int(raw.get("inputTokens") or 0),
        output_tokens=int(raw.get("outputTokens") or 0),
        cache_creation_tokens=int(raw.get("cacheCreationTokens") or 0),
        cache_read_tokens=int(raw.get("cacheReadTokens") or 0),
    )


def _cached_usage_by_session(usage_cache: Dict[str, Any]) -> Dict[str, Dict[str, int]]:
    output: Dict[str, Dict[str, int]] = {}
    for record in usage_cache.get("records") or []:
        if record.get("provider") != "claude_code":
            continue
        session_id = record.get("sessionId")
        if not isinstance(session_id, str):
            continue
        aggregate = output.setdefault(session_id, _zero_usage())
        _add_usage(aggregate, _usage_from_cache(record.get("usage")))
    return output


def _cached_records_by_session(usage_cache: Dict[str, Any]) -> Dict[str, List[Dict[str, Any]]]:
    output: Dict[str, List[Dict[str, Any]]] = {}
    for record in usage_cache.get("records") or []:
        if record.get("provider") != "claude_code" or not isinstance(record.get("sessionId"), str):
            continue
        timestamp = _parse_timestamp(record.get("timestamp"))
        if timestamp is None:
            continue
        output.setdefault(record["sessionId"], []).append(
            {"timestamp": timestamp, "usage": _usage_from_cache(record.get("usage"))}
        )
    return output


def aggregate_claude_cache_windows(
    usage_cache: Dict[str, Any],
    now: datetime,
) -> Dict[str, Any]:
    records_by_session = _cached_records_by_session(usage_cache)
    sessions = [
        session
        for session in usage_cache.get("sessions") or []
        if session.get("provider") == "claude_code" and isinstance(session.get("id"), str)
    ]
    week_start = now - timedelta(days=7)
    all_time = _zero_usage()
    last_seven_days = _zero_usage()
    valid_sessions = []
    for session in sessions:
        session_id = session["id"]
        records = records_by_session.get(session_id, [])
        total = _zero_usage()
        for record in records:
            _add_usage(total, record["usage"])
        if not records:
            total = _usage_from_cache(session.get("totalUsage"))
        message_count = int(session.get("messageCount") or len(records))
        if message_count <= 0 or total["total_tokens"] <= 0:
            continue
        started_at = _parse_timestamp(session.get("startedAt"))
        if started_at is None and records:
            started_at = min(record["timestamp"] for record in records)
        started_at = started_at or datetime.fromtimestamp(0, tz=timezone.utc)
        ended_at = _parse_timestamp(session.get("endedAt")) or started_at
        activity_at = max(
            (record["timestamp"] for record in records),
            default=ended_at,
        )
        valid_sessions.append((session_id, started_at, activity_at, total, records))
        _add_usage(all_time, total)
        if records:
            for record in records:
                if week_start <= record["timestamp"] <= now:
                    _add_usage(last_seven_days, record["usage"])
        elif week_start <= started_at <= now:
            _add_usage(last_seven_days, total)
    latest = max(valid_sessions, key=lambda value: (value[2], value[1], value[0])) if valid_sessions else None
    return {
        "all-time": all_time,
        "last-7d": last_seven_days,
        "latest-session": dict(latest[3]) if latest else _zero_usage(),
        "latest_session_id": latest[0] if latest else None,
        "week_start": week_start.isoformat(),
    }


def _provider_claude_windows(provider_cache: Dict[str, Any]) -> Dict[str, Dict[str, int]]:
    for snapshot in provider_cache.get("snapshots") or []:
        if snapshot.get("provider") != "claude_code":
            continue
        return {
            window["id"]: _usage_from_cache(window.get("tokenUsage"))
            for window in snapshot.get("windows") or []
            if isinstance(window.get("id"), str)
        }
    return {}


def _public_sample(
    session: Optional[ClaudeAuditSession],
    cached_usage_by_session: Dict[str, Dict[str, int]],
) -> Optional[Dict[str, Any]]:
    if session is None:
        return None
    cached_usage = cached_usage_by_session.get(session.session_id, _zero_usage())
    comparison = compare_usage(session.usage, cached_usage)
    timestamps = [record["timestamp"] for record in session.usage_records]
    return {
        "session_hash": redact_identifier(session.session_id),
        "message_count": session.message_count,
        "first_usage_at": min(timestamps).isoformat() if timestamps else None,
        "last_usage_at": max(timestamps).isoformat() if timestamps else None,
        "raw_usage": session.usage,
        "production_cache_usage": cached_usage,
        "comparison": comparison,
    }


def _usage_sequence(session: ClaudeAuditSession) -> List[Any]:
    return [
        (
            record["timestamp"].astimezone(timezone.utc).isoformat(),
            tuple(int(record["usage"].get(field, 0)) for field in TOKEN_FIELDS),
        )
        for record in sorted(
            session.usage_records,
            key=lambda value: (
                value["timestamp"],
                tuple(int(value["usage"].get(field, 0)) for field in TOKEN_FIELDS),
            ),
        )
    ]


def build_claude_audit(
    claude_root: Path,
    usage_cache: Dict[str, Any],
    provider_cache: Dict[str, Any],
    now: datetime,
) -> Dict[str, Any]:
    files = sorted(claude_root.rglob("*.jsonl")) if claude_root.exists() else []
    parsed: List[ClaudeAuditSession] = []
    parse_errors = 0
    for path in files:
        try:
            parsed.append(parse_claude_file(path))
        except (OSError, ValueError, TypeError):
            parse_errors += 1

    valid = [session for session in parsed if session.message_count > 0 and session.usage["total_tokens"] > 0]
    week_start = now - timedelta(days=7)
    selected = select_claude_samples(valid, week_start)
    cached_usage = _cached_usage_by_session(usage_cache)
    samples = {
        name: _public_sample(session, cached_usage)
        for name, session in selected.items()
    }
    sample_comparisons = [
        sample["comparison"]["passed"]
        for sample in samples.values()
        if sample is not None
    ]

    raw_windows = aggregate_claude_windows(valid, now)
    sessions_by_id: Dict[str, List[ClaudeAuditSession]] = {}
    for session in valid:
        sessions_by_id.setdefault(session.session_id, []).append(session)
    deduplicated_sessions = [copies[0] for copies in sessions_by_id.values()]
    duplicate_copies = [copy for copies in sessions_by_id.values() for copy in copies[1:]]
    duplicate_conflicts = sum(
        1
        for copies in sessions_by_id.values()
        if len(copies) > 1
        and any(_usage_sequence(copy) != _usage_sequence(copies[0]) for copy in copies[1:])
    )
    deduplicated_windows = aggregate_claude_windows(deduplicated_sessions, now)
    history_cache_windows = aggregate_claude_cache_windows(usage_cache, now)
    production_windows = _provider_claude_windows(provider_cache)
    window_comparisons: Dict[str, Dict[str, Any]] = {}
    for identifier in ("all-time", "last-7d", "latest-session"):
        actual = production_windows.get(identifier, _zero_usage())
        window_comparisons[identifier] = compare_usage(history_cache_windows[identifier], actual)

    raw_ids = [session.session_id for session in valid]
    unique_raw_ids = set(raw_ids)
    cache_session_ids = {
        session.get("id")
        for session in usage_cache.get("sessions") or []
        if session.get("provider") == "claude_code" and isinstance(session.get("id"), str)
    }
    duplicate_ids = len(raw_ids) - len(unique_raw_ids)
    boundary_alternative = selected.get("boundary_alternative")
    boundary_distance = None
    if boundary_alternative is not None:
        boundary_distance = min(
            abs((record["timestamp"] - week_start).total_seconds())
            for record in boundary_alternative.usage_records
        )
    cache_only_usage = _zero_usage()
    for session_id in cache_session_ids - unique_raw_ids:
        _add_usage(cache_only_usage, cached_usage.get(session_id, _zero_usage()))
    duplicate_copy_usage = _zero_usage()
    for session in duplicate_copies:
        _add_usage(duplicate_copy_usage, session.usage)
    equation_expected = dict(deduplicated_windows["all-time"])
    _add_usage(equation_expected, cache_only_usage)
    equation_delta = _subtract_usage(history_cache_windows["all-time"], equation_expected)
    reconciliation_checks = {
        "parse_errors_zero": parse_errors == 0,
        "all_raw_sessions_cached": len(unique_raw_ids - cache_session_ids) == 0,
        "duplicate_usage_conflicts_zero": duplicate_conflicts == 0,
        "history_equation_delta_zero": all(value == 0 for value in equation_delta.values()),
    }
    return {
        "profile": {
            "jsonl_files": len(files),
            "parsed_files": len(parsed),
            "parse_errors": parse_errors,
            "valid_sessions": len(valid),
            "excluded_empty_or_zero": len(parsed) - len(valid),
            "duplicate_session_ids": duplicate_ids,
            "raw_sessions_missing_from_cache": len(unique_raw_ids - cache_session_ids),
            "cache_only_sessions": len(cache_session_ids - unique_raw_ids),
        },
        "samples": samples,
        "cross_boundary_sample_available": samples["cross_boundary"] is not None,
        "boundary_alternative_distance_seconds": boundary_distance,
        "sample_comparisons_passed": bool(sample_comparisons) and all(sample_comparisons),
        "raw_windows": {
            key: value for key, value in raw_windows.items() if key != "latest_session_id"
        },
        "current_log_windows": {
            key: value for key, value in raw_windows.items() if key != "latest_session_id"
        },
        "deduplicated_log_windows": {
            key: value for key, value in deduplicated_windows.items() if key != "latest_session_id"
        },
        "history_cache_windows": {
            key: value for key, value in history_cache_windows.items() if key != "latest_session_id"
        },
        "production_windows": production_windows,
        "window_comparisons": window_comparisons,
        "provider_windows_passed": all(row["passed"] for row in window_comparisons.values()),
        "current_log_window_deltas": {
            identifier: _subtract_usage(
                production_windows.get(identifier, _zero_usage()),
                raw_windows[identifier],
            )
            for identifier in ("all-time", "last-7d", "latest-session")
        },
        "history_reconciliation": {
            "cache_only_usage": cache_only_usage,
            "duplicate_copy_usage": duplicate_copy_usage,
            "duplicate_conflict_count": duplicate_conflicts,
            "equation_delta": equation_delta,
        },
        "reconciliation_checks": reconciliation_checks,
        "full_reconciliation_passed": all(reconciliation_checks.values()),
        "latest_session_hash": redact_identifier(raw_windows["latest_session_id"])
        if raw_windows.get("latest_session_id")
        else None,
    }


def build_codex_audit(
    auth: Dict[str, Any],
    response: Dict[str, Any],
    provider_cache: Dict[str, Any],
    captured_at: datetime,
    percent_tolerance: int = 1,
    freshness_tolerance_seconds: int = 60,
) -> Dict[str, Any]:
    selected_credentials = select_codex_credentials(auth)
    official_windows = extract_codex_windows(response)
    cached_snapshot = next(
        (
            snapshot
            for snapshot in provider_cache.get("snapshots") or []
            if snapshot.get("provider") == "codex"
        ),
        {},
    )
    cached_windows = [
        {
            "id": window.get("id"),
            "usedPercent": window.get("usedPercent"),
            "resetsAt": window.get("resetsAt"),
        }
        for window in cached_snapshot.get("windows") or []
    ]
    comparison = compare_codex_windows(
        official_windows,
        cached_windows,
        percent_tolerance=percent_tolerance,
    )
    cached_updated_at = _parse_timestamp(cached_snapshot.get("updatedAt"))
    freshness = compare_cache_freshness(
        cached_updated_at,
        captured_at,
        tolerance_seconds=freshness_tolerance_seconds,
    )
    provenance = _codex_account_provenance(auth, selected_credentials, cached_snapshot)
    verification = {
        **freshness,
        **provenance,
    }
    verification["passed"] = bool(
        comparison["passed"]
        and verification["freshness_passed"]
        and verification["account_provenance_passed"]
    )
    return {
        "credentials": public_codex_credential_summary(auth, selected_credentials),
        "plan": response.get("plan_type"),
        "captured_at": captured_at.isoformat(),
        "official_windows": official_windows,
        "cached_snapshot": {
            "updated_at": cached_snapshot.get("updatedAt"),
            "plan": cached_snapshot.get("planName"),
            "source": cached_snapshot.get("sourceLabel"),
            "windows": cached_windows,
        },
        "comparison": comparison,
        "verification": verification,
        "passed": verification["passed"],
        "cost_is_local_estimate": True,
        "cost_row_count": len(cached_snapshot.get("costRows") or []),
    }


def resolve_codex_usage_url(env: Optional[Dict[str, str]] = None) -> str:
    del env
    return "https://chatgpt.com/backend-api/wham/usage"


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        del req, fp, code, msg, headers, newurl
        return None


def fetch_codex_usage(
    credentials: Dict[str, Any],
    env: Optional[Dict[str, str]] = None,
    opener=None,
) -> Dict[str, Any]:
    headers = {
        "Authorization": "Bearer " + credentials["access_token"],
        "Accept": "application/json",
        "User-Agent": "TokenScope-Audit",
    }
    if credentials.get("account_id"):
        headers["ChatGPT-Account-Id"] = credentials["account_id"]
    request = urllib.request.Request(resolve_codex_usage_url(env), headers=headers, method="GET")
    if opener is None:
        opener = urllib.request.build_opener(NoRedirectHandler()).open
    with opener(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def summarize_status(
    claude: Dict[str, Any],
    codex: Optional[Dict[str, Any]],
) -> str:
    checks = [
        bool(claude.get("sample_comparisons_passed")),
        bool(claude.get("provider_windows_passed")),
        bool(claude.get("full_reconciliation_passed")),
        bool(codex and codex.get("passed")),
    ]
    return "passed" if all(checks) else "attention"


def _load_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def main(argv: Optional[List[str]] = None) -> int:
    home = Path.home()
    parser = argparse.ArgumentParser(
        description="Reconcile TokenScope Claude logs and Codex quota data without exposing content or credentials."
    )
    parser.add_argument("--claude-root", type=Path, default=home / ".claude" / "projects")
    parser.add_argument(
        "--usage-cache",
        type=Path,
        default=home / "Library" / "Application Support" / "TokenScope" / "usage_cache.json",
    )
    parser.add_argument(
        "--provider-cache",
        type=Path,
        default=home / "Library" / "Application Support" / "TokenScope" / "provider_usage_cache.json",
    )
    parser.add_argument("--codex-auth", type=Path, default=home / ".codex" / "auth.json")
    parser.add_argument("--live-codex", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--now", help="ISO-8601 audit time; defaults to current UTC time")
    args = parser.parse_args(argv)

    now = _parse_timestamp(args.now) if args.now else datetime.now(timezone.utc)
    if now is None:
        raise ValueError("Invalid --now timestamp")
    usage_cache = _load_json(args.usage_cache)
    provider_cache = _load_json(args.provider_cache)
    claude = build_claude_audit(args.claude_root, usage_cache, provider_cache, now)

    codex = None
    if args.live_codex:
        auth = _load_json(args.codex_auth)
        credentials = select_codex_credentials(auth)
        response = fetch_codex_usage(credentials)
        captured_at = datetime.now(timezone.utc)
        codex = build_codex_audit(
            auth,
            response,
            provider_cache,
            captured_at=captured_at,
        )

    result = {
        "schema_version": 1,
        "generated_at": now.isoformat(),
        "status": summarize_status(claude, codex),
        "acceptance_criteria": {
            "claude_token_delta": 0,
            "codex_used_percent_delta_max": 1,
            "codex_reset_seconds_delta": 0,
            "codex_cache_age_seconds_max": 60,
            "codex_account_provenance_required": True,
        },
        "claude": claude,
        "codex": codex,
    }
    encoded = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    return 0 if result["status"] == "passed" else 2


def _safe_error_payload(error: Exception) -> Dict[str, Any]:
    if isinstance(error, (FileNotFoundError, PermissionError)):
        code = "required_input_unavailable"
        message = "A required local input is unavailable."
    elif isinstance(error, json.JSONDecodeError):
        code = "invalid_json"
        message = "A required local JSON input is invalid."
    elif isinstance(error, urllib.error.HTTPError):
        code = "codex_http_error"
        message = "The Codex usage API returned an HTTP error."
    elif isinstance(error, (urllib.error.URLError, TimeoutError)):
        code = "codex_network_error"
        message = "The Codex usage API could not be reached."
    elif isinstance(error, ValueError):
        code = "invalid_input"
        message = "The audit input did not match the expected schema."
    else:
        code = "audit_failed"
        message = "The audit could not be completed."
    payload: Dict[str, Any] = {
        "schema_version": 1,
        "status": "error",
        "error": {"code": code, "message": message},
    }
    if isinstance(error, urllib.error.HTTPError):
        payload["error"]["http_status"] = error.code
    return payload


def cli(argv: Optional[List[str]] = None) -> int:
    try:
        return main(argv)
    except Exception as error:
        sys.stderr.write(json.dumps(_safe_error_payload(error), ensure_ascii=False, sort_keys=True) + "\n")
        return 1


def redact_identifier(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


if __name__ == "__main__":
    raise SystemExit(cli())
