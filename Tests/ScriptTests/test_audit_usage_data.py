import base64
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


SCRIPT_PATH = Path(__file__).parents[2] / "Scripts" / "audit_usage_data.py"
SPEC = importlib.util.spec_from_file_location("audit_usage_data", SCRIPT_PATH)
AUDIT = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


class AuditUsageDataTests(unittest.TestCase):
    @staticmethod
    def synthetic_id_token(email: str) -> str:
        payload = base64.urlsafe_b64encode(
            json.dumps({"email": email}).encode("utf-8")
        ).decode("ascii").rstrip("=")
        return f"synthetic.{payload}.signature"

    @staticmethod
    def synthetic_id_token_with_profile_email(email: str) -> str:
        payload = base64.urlsafe_b64encode(
            json.dumps({"https://api.openai.com/profile": {"email": email}}).encode("utf-8")
        ).decode("ascii").rstrip("=")
        return f"synthetic.{payload}.signature"

    def test_parse_claude_file_splits_all_token_components_and_skips_zero_usage(self):
        lines = [
            {
                "type": "user",
                "sessionId": "session-a",
                "cwd": "/private/project",
                "timestamp": "2026-07-01T00:00:00.000Z",
            },
            {
                "type": "assistant",
                "sessionId": "session-a",
                "timestamp": "2026-07-01T00:01:00.000Z",
                "message": {
                    "model": "claude-test",
                    "usage": {
                        "input_tokens": 10,
                        "output_tokens": 20,
                        "cache_creation_input_tokens": 30,
                        "cache_read_input_tokens": 40,
                    },
                },
            },
            {
                "type": "assistant",
                "sessionId": "session-a",
                "timestamp": "2026-07-01T00:02:00.000Z",
                "message": {"model": "claude-test", "usage": {}},
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session-a.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in lines), encoding="utf-8")
            session = AUDIT.parse_claude_file(path)

        self.assertEqual(session.session_id, "session-a")
        self.assertEqual(session.message_count, 1)
        self.assertEqual(
            session.usage,
            {
                "input_tokens": 10,
                "output_tokens": 20,
                "cache_creation_tokens": 30,
                "cache_read_tokens": 40,
                "total_tokens": 100,
            },
        )

    def test_parse_claude_file_matches_swift_integer_type_semantics(self):
        row = {
            "type": "assistant",
            "sessionId": "typed",
            "timestamp": "2026-07-01T00:01:00.000Z",
            "message": {
                "model": "claude-test",
                "usage": {"input_tokens": "99", "output_tokens": 1, "cache_read_input_tokens": True},
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "typed.jsonl"
            path.write_text(json.dumps(row), encoding="utf-8")
            session = AUDIT.parse_claude_file(path)

        self.assertEqual(session.usage, AUDIT.usage(output_tokens=1))

    def test_parse_claude_file_ignores_invalid_timestamp_like_production_parser(self):
        rows = [
            [],
            {"type": "user", "sessionId": "timestamped", "timestamp": "not-a-date"},
            {
                "type": "assistant",
                "sessionId": "timestamped",
                "timestamp": "2026-07-01T00:01:00.000Z",
                "message": {"model": "claude-test", "usage": {"input_tokens": 2}},
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "timestamped.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
            session = AUDIT.parse_claude_file(path)

        self.assertEqual(session.usage["total_tokens"], 2)
        self.assertEqual(session.message_count, 1)

    def test_select_samples_returns_smallest_largest_and_cross_boundary(self):
        week_start = datetime(2026, 7, 4, tzinfo=timezone.utc)
        sessions = [
            AUDIT.ClaudeAuditSession.fixture("small", [week_start], total=5),
            AUDIT.ClaudeAuditSession.fixture("large", [week_start], total=500),
            AUDIT.ClaudeAuditSession.fixture(
                "cross",
                [
                    datetime(2026, 7, 3, 23, 59, tzinfo=timezone.utc),
                    datetime(2026, 7, 4, 0, 1, tzinfo=timezone.utc),
                ],
                total=100,
            ),
        ]

        selected = AUDIT.select_claude_samples(sessions, week_start)

        self.assertEqual(selected["small"].session_id, "small")
        self.assertEqual(selected["largest"].session_id, "large")
        self.assertEqual(selected["cross_boundary"].session_id, "cross")

    def test_select_samples_uses_nearest_boundary_alternative_when_no_cross_exists(self):
        week_start = datetime(2026, 7, 4, tzinfo=timezone.utc)
        farther = AUDIT.ClaudeAuditSession.fixture(
            "farther", [datetime(2026, 7, 7, tzinfo=timezone.utc)], total=100
        )
        nearer = AUDIT.ClaudeAuditSession.fixture(
            "nearer", [datetime(2026, 7, 4, 0, 1, tzinfo=timezone.utc)], total=200
        )

        selected = AUDIT.select_claude_samples([farther, nearer], week_start)

        self.assertIsNone(selected["cross_boundary"])
        self.assertEqual(selected["boundary_alternative"].session_id, "nearer")

    def test_compare_usage_requires_exact_integer_equality(self):
        expected = {
            "input_tokens": 10,
            "output_tokens": 20,
            "cache_creation_tokens": 30,
            "cache_read_tokens": 40,
            "total_tokens": 100,
        }
        exact = AUDIT.compare_usage(expected, dict(expected))
        changed = AUDIT.compare_usage(expected, {**expected, "cache_read_tokens": 39, "total_tokens": 99})

        self.assertTrue(exact["passed"])
        self.assertEqual(exact["max_absolute_delta"], 0)
        self.assertFalse(changed["passed"])
        self.assertEqual(changed["deltas"]["cache_read_tokens"], -1)

    def test_codex_mapping_and_cache_comparison_use_one_point_live_tolerance(self):
        response = {
            "plan_type": "pro",
            "rate_limit": {
                "primary_window": {
                    "used_percent": 95,
                    "reset_at": 1_800_000_000,
                    "limit_window_seconds": 18_000,
                },
                "secondary_window": {
                    "used_percent": 16,
                    "reset_at": 1_800_500_000,
                    "limit_window_seconds": 604_800,
                },
            },
        }
        official = AUDIT.extract_codex_windows(response)
        cache = [
            {"id": "session", "usedPercent": 96, "resetsAt": "2027-01-15T08:00:00Z"},
            {"id": "weekly", "usedPercent": 16, "resetsAt": "2027-01-21T02:53:20Z"},
        ]

        comparison = AUDIT.compare_codex_windows(official, cache, percent_tolerance=1)
        strict = AUDIT.compare_codex_windows(official, cache, percent_tolerance=0)

        self.assertEqual(official[0]["remaining_percent"], 5)
        self.assertTrue(comparison["passed"])
        self.assertFalse(strict["passed"])

    def test_codex_comparison_fails_when_official_windows_are_missing(self):
        comparison = AUDIT.compare_codex_windows([], [], percent_tolerance=1)

        self.assertFalse(comparison["passed"])
        self.assertEqual(comparison["missing_official_window_ids"], ["session", "weekly"])

    def test_codex_comparison_rejects_wrong_window_duration(self):
        official = [
            {"id": "session", "used_percent": 10, "reset_at": 1_800_000_000, "limit_window_seconds": 18_000},
            {"id": "weekly", "used_percent": 20, "reset_at": 1_800_500_000, "limit_window_seconds": 123},
        ]
        cached = [
            {"id": "session", "usedPercent": 10, "resetsAt": "2027-01-15T08:00:00Z"},
            {"id": "weekly", "usedPercent": 20, "resetsAt": "2027-01-21T02:53:20Z"},
        ]

        comparison = AUDIT.compare_codex_windows(official, cached)

        self.assertFalse(comparison["passed"])
        self.assertEqual(comparison["invalid_official_window_ids"], ["weekly"])

    def test_identifier_redaction_is_stable_and_does_not_leak_input(self):
        first = AUDIT.redact_identifier("sensitive-session-id")
        second = AUDIT.redact_identifier("sensitive-session-id")

        self.assertEqual(first, second)
        self.assertNotIn("sensitive", first)
        self.assertEqual(len(first), 12)

    def test_aggregate_windows_use_record_timestamps_and_latest_valid_start(self):
        now = datetime(2026, 7, 11, tzinfo=timezone.utc)
        week_start = datetime(2026, 7, 4, tzinfo=timezone.utc)
        cross = AUDIT.ClaudeAuditSession(
            session_id="cross",
            started_at=datetime(2026, 7, 3, tzinfo=timezone.utc),
            ended_at=datetime(2026, 7, 5, tzinfo=timezone.utc),
            usage_records=[
                {
                    "timestamp": datetime(2026, 7, 3, 23, 59, tzinfo=timezone.utc),
                    "usage": AUDIT.usage(60),
                },
                {
                    "timestamp": datetime(2026, 7, 4, 0, 1, tzinfo=timezone.utc),
                    "usage": AUDIT.usage(40),
                },
            ],
            usage=AUDIT.usage(100),
            message_count=2,
        )
        latest = AUDIT.ClaudeAuditSession.fixture(
            "latest", [datetime(2026, 7, 10, tzinfo=timezone.utc)], total=5
        )

        windows = AUDIT.aggregate_claude_windows([cross, latest], now)

        self.assertEqual(windows["all-time"]["total_tokens"], 105)
        self.assertEqual(windows["last-7d"]["total_tokens"], 45)
        self.assertEqual(windows["latest-session"]["total_tokens"], 5)
        self.assertEqual(windows["week_start"], week_start.isoformat())

    def test_latest_window_uses_last_usage_activity_for_logs_and_cache(self):
        now = datetime(2026, 7, 11, tzinfo=timezone.utc)
        newer_start = AUDIT.ClaudeAuditSession(
            session_id="newer-start",
            started_at=datetime(2026, 7, 10, 0, 0, tzinfo=timezone.utc),
            ended_at=datetime(2026, 7, 10, 1, 0, tzinfo=timezone.utc),
            usage_records=[
                {"timestamp": datetime(2026, 7, 10, 1, 0, tzinfo=timezone.utc), "usage": AUDIT.usage(10)}
            ],
            usage=AUDIT.usage(10),
            message_count=1,
        )
        later_activity = AUDIT.ClaudeAuditSession(
            session_id="later-activity",
            started_at=datetime(2026, 7, 9, 0, 0, tzinfo=timezone.utc),
            ended_at=datetime(2026, 7, 10, 2, 0, tzinfo=timezone.utc),
            usage_records=[
                {"timestamp": datetime(2026, 7, 10, 2, 0, tzinfo=timezone.utc), "usage": AUDIT.usage(200)}
            ],
            usage=AUDIT.usage(200),
            message_count=1,
        )
        usage_cache = {
            "sessions": [
                {"id": "newer-start", "provider": "claude_code", "startedAt": "2026-07-10T00:00:00Z"},
                {"id": "later-activity", "provider": "claude_code", "startedAt": "2026-07-09T00:00:00Z"},
            ],
            "records": [
                AUDIT.cache_record("newer-start", 0, "2026-07-10T01:00:00Z", 10),
                AUDIT.cache_record("later-activity", 0, "2026-07-10T02:00:00Z", 200),
            ],
        }

        log_windows = AUDIT.aggregate_claude_windows([newer_start, later_activity], now)
        cache_windows = AUDIT.aggregate_claude_cache_windows(usage_cache, now)

        self.assertEqual(log_windows["latest-session"]["total_tokens"], 200)
        self.assertEqual(cache_windows["latest-session"]["total_tokens"], 200)

    def test_oauth_tokens_take_precedence_over_api_key_without_exposing_values(self):
        auth = {
            "OPENAI_API_KEY": "api-key-secret",
            "tokens": {
                "access_token": "oauth-access-secret",
                "refresh_token": "oauth-refresh-secret",
                "account_id": "account-secret",
            },
        }

        selected = AUDIT.select_codex_credentials(auth)

        self.assertEqual(selected["source"], "oauth_tokens")
        self.assertEqual(selected["access_token"], "oauth-access-secret")
        self.assertTrue(selected["oauth_precedence_verified"])
        public = AUDIT.public_codex_credential_summary(auth, selected)
        self.assertNotIn("access_token", public)
        self.assertNotIn("api-key-secret", json.dumps(public))

    def test_build_claude_audit_compares_raw_logs_cache_and_provider_windows(self):
        now = datetime(2026, 7, 11, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            small_rows = [
                {
                    "type": "assistant",
                    "sessionId": "small",
                    "timestamp": "2026-07-10T00:00:00.000Z",
                    "message": {
                        "model": "claude-test",
                        "usage": {"input_tokens": 5},
                    },
                }
            ]
            cross_rows = [
                {
                    "type": "assistant",
                    "sessionId": "cross",
                    "timestamp": "2026-07-03T23:59:00.000Z",
                    "message": {
                        "model": "claude-test",
                        "usage": {"input_tokens": 60},
                    },
                },
                {
                    "type": "assistant",
                    "sessionId": "cross",
                    "timestamp": "2026-07-04T00:01:00.000Z",
                    "message": {
                        "model": "claude-test",
                        "usage": {"input_tokens": 40},
                    },
                },
            ]
            zero_rows = [
                {
                    "type": "assistant",
                    "sessionId": "zero",
                    "timestamp": "2026-07-10T00:00:00.000Z",
                    "message": {"model": "claude-test", "usage": {}},
                }
            ]
            for name, rows in (("small", small_rows), ("cross", cross_rows), ("zero", zero_rows)):
                (root / f"{name}.jsonl").write_text(
                    "\n".join(json.dumps(row) for row in rows), encoding="utf-8"
                )

            usage_cache = {
                "version": 2,
                "sessions": [
                    {"id": "small", "provider": "claude_code"},
                    {"id": "cross", "provider": "claude_code"},
                ],
                "records": [
                    AUDIT.cache_record("small", 0, "2026-07-10T00:00:00Z", 5),
                    AUDIT.cache_record("cross", 0, "2026-07-03T23:59:00Z", 60),
                    AUDIT.cache_record("cross", 1, "2026-07-04T00:01:00Z", 40),
                ],
            }
            provider_cache = {
                "version": 2,
                "snapshots": [
                    {
                        "provider": "claude_code",
                        "windows": [
                            AUDIT.cache_claude_window("all-time", 105),
                            AUDIT.cache_claude_window("last-7d", 45),
                            AUDIT.cache_claude_window("latest-session", 5),
                        ],
                    }
                ],
            }

            result = AUDIT.build_claude_audit(root, usage_cache, provider_cache, now)

        self.assertEqual(result["profile"]["jsonl_files"], 3)
        self.assertEqual(result["profile"]["valid_sessions"], 2)
        self.assertEqual(result["profile"]["excluded_empty_or_zero"], 1)
        self.assertTrue(result["sample_comparisons_passed"])
        self.assertTrue(result["provider_windows_passed"])
        self.assertTrue(result["full_reconciliation_passed"])
        self.assertEqual(result["samples"]["cross_boundary"]["raw_usage"]["total_tokens"], 100)

    def test_build_codex_audit_is_sanitized_and_compares_official_windows(self):
        auth = {
            "OPENAI_API_KEY": "api-key-secret",
            "tokens": {
                "access_token": "oauth-access-secret",
                "refresh_token": "oauth-refresh-secret",
                "id_token": self.synthetic_id_token("person@example.test"),
                "account_id": "account-secret",
            },
        }
        response = {
            "plan_type": "pro",
            "rate_limit": {
                "primary_window": {
                    "used_percent": 95,
                    "reset_at": 1_800_000_000,
                    "limit_window_seconds": 18_000,
                },
                "secondary_window": {
                    "used_percent": 16,
                    "reset_at": 1_800_500_000,
                    "limit_window_seconds": 604_800,
                },
            },
        }
        provider_cache = {
            "version": 2,
            "snapshots": [
                {
                    "provider": "codex",
                    "updatedAt": "2027-01-01T00:00:00Z",
                    "planName": "Pro",
                    "sourceLabel": "OAuth · System account",
                    "identitySummary": "person@example.test",
                    "accountDisplayName": "person@example.test",
                    "selectedAccountID": "live-system",
                    "providerAccountFingerprint": "df84dfe02bf0bde0717f6b9041ada0c23edceb89c2b02016675388157a029989",
                    "windows": [
                        {"id": "session", "usedPercent": 95, "resetsAt": "2027-01-15T08:00:00Z"},
                        {"id": "weekly", "usedPercent": 16, "resetsAt": "2027-01-21T02:53:20Z"},
                    ],
                    "costRows": [{"title": "Today", "amountText": "$1.00"}],
                }
            ],
        }

        result = AUDIT.build_codex_audit(
            auth,
            response,
            provider_cache,
            captured_at=datetime(2027, 1, 1, 0, 0, 30, tzinfo=timezone.utc),
        )
        serialized = json.dumps(result)

        self.assertTrue(result["comparison"]["passed"])
        self.assertTrue(result["verification"]["freshness_passed"])
        self.assertTrue(result["verification"]["account_provenance_passed"])
        self.assertTrue(result["passed"])
        self.assertEqual(result["official_windows"][0]["remaining_percent"], 5)
        self.assertTrue(result["cost_is_local_estimate"])
        self.assertNotIn("oauth-access-secret", serialized)
        self.assertNotIn("api-key-secret", serialized)
        self.assertNotIn("account-secret", serialized)

    def test_build_codex_audit_rejects_stale_cache(self):
        auth = {
            "tokens": {
                "access_token": "oauth-access-secret",
                "refresh_token": "oauth-refresh-secret",
                "id_token": self.synthetic_id_token("person@example.test"),
                "account_id": "account-secret",
            }
        }
        response = {
            "plan_type": "pro",
            "rate_limit": {
                "primary_window": {
                    "used_percent": 10,
                    "reset_at": 1_800_000_000,
                    "limit_window_seconds": 18_000,
                },
                "secondary_window": {
                    "used_percent": 20,
                    "reset_at": 1_800_500_000,
                    "limit_window_seconds": 604_800,
                },
            },
        }
        provider_cache = {
            "snapshots": [
                {
                    "provider": "codex",
                    "updatedAt": "2027-01-01T00:00:00Z",
                    "identitySummary": "person@example.test",
                    "accountDisplayName": "person@example.test",
                    "selectedAccountID": "live-system",
                    "providerAccountFingerprint": "df84dfe02bf0bde0717f6b9041ada0c23edceb89c2b02016675388157a029989",
                    "windows": [
                        {"id": "session", "usedPercent": 10, "resetsAt": "2027-01-15T08:00:00Z"},
                        {"id": "weekly", "usedPercent": 20, "resetsAt": "2027-01-21T02:53:20Z"},
                    ],
                }
            ]
        }

        result = AUDIT.build_codex_audit(
            auth,
            response,
            provider_cache,
            captured_at=datetime(2027, 1, 1, 0, 1, 1, tzinfo=timezone.utc),
        )

        self.assertTrue(result["comparison"]["passed"])
        self.assertFalse(result["verification"]["freshness_passed"])
        self.assertEqual(result["verification"]["cache_age_seconds"], 61)
        self.assertFalse(result["passed"])

    def test_codex_freshness_uses_unrounded_age_at_both_boundaries(self):
        updated_at = datetime(2027, 1, 1, tzinfo=timezone.utc)

        just_stale = AUDIT.compare_cache_freshness(
            updated_at,
            updated_at.replace(second=59, microsecond=999_999) + AUDIT.timedelta(seconds=1),
            tolerance_seconds=60,
        )
        slightly_future = AUDIT.compare_cache_freshness(
            updated_at,
            updated_at - AUDIT.timedelta(microseconds=1),
            tolerance_seconds=60,
        )

        self.assertFalse(just_stale["freshness_passed"])
        self.assertFalse(slightly_future["freshness_passed"])

    def test_codex_provenance_uses_account_fingerprint_and_reports_email_diagnostic(self):
        auth = {
            "tokens": {
                "access_token": "oauth-access-secret",
                "refresh_token": "oauth-refresh-secret",
                "id_token": self.synthetic_id_token_with_profile_email("Person@Example.Test"),
                "account_id": "account-secret",
            }
        }
        credentials = AUDIT.select_codex_credentials(auth)

        matched = AUDIT._codex_account_provenance(
            auth,
            credentials,
            {
                "selectedAccountID": "live-system",
                "identitySummary": " person@example.test ",
                "accountDisplayName": "unrelated@example.test",
                "providerAccountFingerprint": "df84dfe02bf0bde0717f6b9041ada0c23edceb89c2b02016675388157a029989",
            },
        )
        display_only = AUDIT._codex_account_provenance(
            auth,
            credentials,
            {
                "selectedAccountID": "live-system",
                "accountDisplayName": "person@example.test",
            },
        )

        self.assertTrue(matched["account_provenance_passed"])
        self.assertEqual(matched["provenance_strength"], "account_id")
        self.assertTrue(matched["email_diagnostic_matched"])
        self.assertFalse(display_only["account_provenance_passed"])
        self.assertEqual(display_only["provenance_strength"], "none")

    def test_codex_provenance_rejects_non_system_sources(self):
        oauth_auth = {
            "tokens": {
                "access_token": "oauth-access-secret",
                "refresh_token": "oauth-refresh-secret",
                "id_token": self.synthetic_id_token("person@example.test"),
            }
        }
        api_key_auth = {"OPENAI_API_KEY": "synthetic-api-key"}

        managed = AUDIT._codex_account_provenance(
            oauth_auth,
            AUDIT.select_codex_credentials(oauth_auth),
            {
                "selectedAccountID": "00000000-0000-0000-0000-000000000001",
                "identitySummary": "person@example.test",
            },
        )
        api_key = AUDIT._codex_account_provenance(
            api_key_auth,
            AUDIT.select_codex_credentials(api_key_auth),
            {"selectedAccountID": "live-system", "identitySummary": "person@example.test"},
        )

        self.assertFalse(managed["account_provenance_passed"])
        self.assertFalse(api_key["account_provenance_passed"])

    def test_build_codex_audit_rejects_different_cached_account(self):
        auth = {
            "tokens": {
                "access_token": "oauth-access-secret",
                "refresh_token": "oauth-refresh-secret",
                "id_token": self.synthetic_id_token("live@example.test"),
                "account_id": "account-secret",
            }
        }
        response = {
            "plan_type": "pro",
            "rate_limit": {
                "primary_window": {
                    "used_percent": 10,
                    "reset_at": 1_800_000_000,
                    "limit_window_seconds": 18_000,
                },
                "secondary_window": {
                    "used_percent": 20,
                    "reset_at": 1_800_500_000,
                    "limit_window_seconds": 604_800,
                },
            },
        }
        provider_cache = {
            "snapshots": [
                {
                    "provider": "codex",
                    "updatedAt": "2027-01-01T00:00:00Z",
                    "identitySummary": "other@example.test",
                    "accountDisplayName": "other@example.test",
                    "selectedAccountID": "live-system",
                    "providerAccountFingerprint": "different-fingerprint",
                    "windows": [
                        {"id": "session", "usedPercent": 10, "resetsAt": "2027-01-15T08:00:00Z"},
                        {"id": "weekly", "usedPercent": 20, "resetsAt": "2027-01-21T02:53:20Z"},
                    ],
                }
            ]
        }

        result = AUDIT.build_codex_audit(
            auth,
            response,
            provider_cache,
            captured_at=datetime(2027, 1, 1, 0, 0, 30, tzinfo=timezone.utc),
        )

        self.assertFalse(result["verification"]["account_provenance_passed"])
        self.assertFalse(result["verification"]["provider_account_fingerprint_matched"])
        self.assertTrue(result["verification"]["live_identity_available"])
        self.assertTrue(result["verification"]["cached_identity_available"])
        self.assertFalse(result["passed"])

    def test_codex_account_fingerprint_matches_swift_domain_and_trimming(self):
        fingerprint = AUDIT._account_id_fingerprint(" account-1 ")

        self.assertEqual(
            fingerprint,
            "e09b8d91b2532962cef5b852d9027cca6f0d2e7e4bfefc0452365774a1b0dd9d",
        )
        self.assertIsNone(AUDIT._account_id_fingerprint("   "))

    def test_codex_usage_url_ignores_untrusted_environment_override(self):
        url = AUDIT.resolve_codex_usage_url(
            {"CHATGPT_BASE_URL": "http://attacker.invalid/collect"}
        )

        self.assertEqual(url, "https://chatgpt.com/backend-api/wham/usage")

    def test_default_http_handler_rejects_redirects(self):
        handler = AUDIT.NoRedirectHandler()

        redirected = handler.redirect_request(
            None,
            None,
            302,
            "Found",
            {},
            "https://attacker.invalid/collect",
        )

        self.assertIsNone(redirected)

    def test_fetch_codex_usage_uses_oauth_header_and_returns_json(self):
        credentials = {
            "source": "oauth_tokens",
            "access_token": "oauth-access-secret",
            "account_id": "account-secret",
            "oauth_precedence_verified": True,
        }
        captured = {}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return b'{"plan_type":"pro","rate_limit":{}}'

        def fake_open(request, timeout):
            captured["url"] = request.full_url
            captured["authorization"] = request.get_header("Authorization")
            captured["account"] = request.get_header("Chatgpt-account-id")
            captured["timeout"] = timeout
            return FakeResponse()

        response = AUDIT.fetch_codex_usage(credentials, env={}, opener=fake_open)

        self.assertEqual(response["plan_type"], "pro")
        self.assertEqual(captured["url"], "https://chatgpt.com/backend-api/wham/usage")
        self.assertEqual(captured["authorization"], "Bearer oauth-access-secret")
        self.assertEqual(captured["account"], "account-secret")
        self.assertEqual(captured["timeout"], 30)

    def test_summarize_status_requires_claude_and_codex_checks(self):
        claude = {
            "sample_comparisons_passed": True,
            "provider_windows_passed": True,
            "full_reconciliation_passed": True,
        }
        codex = {"passed": True, "comparison": {"passed": True}}

        self.assertEqual(AUDIT.summarize_status(claude, codex), "passed")
        codex["passed"] = False
        codex["comparison"]["passed"] = False
        self.assertEqual(AUDIT.summarize_status(claude, codex), "attention")
        codex["passed"] = True
        codex["comparison"]["passed"] = True
        claude["full_reconciliation_passed"] = False
        self.assertEqual(AUDIT.summarize_status(claude, codex), "attention")

    def test_script_entrypoint_can_execute_before_codex_live_check(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            claude_root = root / "claude"
            claude_root.mkdir()
            row = {
                "type": "assistant",
                "sessionId": "entrypoint",
                "timestamp": "2026-07-10T00:00:00.000Z",
                "message": {"model": "claude-test", "usage": {"input_tokens": 5}},
            }
            (claude_root / "entrypoint.jsonl").write_text(json.dumps(row), encoding="utf-8")
            usage_cache_path = root / "usage.json"
            usage_cache_path.write_text(
                json.dumps(
                    {
                        "sessions": [{"id": "entrypoint", "provider": "claude_code"}],
                        "records": [
                            AUDIT.cache_record("entrypoint", 0, "2026-07-10T00:00:00Z", 5)
                        ],
                    }
                ),
                encoding="utf-8",
            )
            provider_cache_path = root / "provider.json"
            provider_cache_path.write_text(
                json.dumps(
                    {
                        "snapshots": [
                            {
                                "provider": "claude_code",
                                "windows": [
                                    AUDIT.cache_claude_window("all-time", 5),
                                    AUDIT.cache_claude_window("last-7d", 5),
                                    AUDIT.cache_claude_window("latest-session", 5),
                                ],
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--claude-root",
                    str(claude_root),
                    "--usage-cache",
                    str(usage_cache_path),
                    "--provider-cache",
                    str(provider_cache_path),
                    "--now",
                    "2026-07-11T00:00:00Z",
                ],
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 2)
        self.assertEqual(json.loads(completed.stdout)["status"], "attention")
        self.assertEqual(completed.stderr, "")

    def test_cli_error_output_does_not_expose_missing_input_path(self):
        sensitive_path = "/tmp/private-user-home/Library/Application Support/TokenScope/missing.json"
        completed = subprocess.run(
            [sys.executable, str(SCRIPT_PATH), "--usage-cache", sensitive_path],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 1)
        self.assertEqual(completed.stdout, "")
        error = json.loads(completed.stderr)
        self.assertEqual(error["status"], "error")
        self.assertEqual(error["error"]["code"], "required_input_unavailable")
        self.assertNotIn(sensitive_path, completed.stderr)
        self.assertNotIn("private-user-home", completed.stderr)

    def test_claude_all_time_reconciles_cached_history_and_duplicate_log_copy(self):
        now = datetime(2026, 7, 11, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("copy-a", "copy-b"):
                row = {
                    "type": "assistant",
                    "sessionId": "duplicated",
                    "timestamp": "2026-07-10T00:00:00.000Z",
                    "message": {"model": "claude-test", "usage": {"input_tokens": 5}},
                }
                (root / f"{name}.jsonl").write_text(json.dumps(row), encoding="utf-8")

            usage_cache = {
                "sessions": [
                    {"id": "duplicated", "provider": "claude_code", "startedAt": "2026-07-10T00:00:00Z"},
                    {"id": "history-only", "provider": "claude_code", "startedAt": "2026-06-01T00:00:00Z"},
                ],
                "records": [
                    AUDIT.cache_record("duplicated", 0, "2026-07-10T00:00:00Z", 5),
                    AUDIT.cache_record("history-only", 0, "2026-06-01T00:00:00Z", 7),
                ],
            }
            provider_cache = {
                "snapshots": [
                    {
                        "provider": "claude_code",
                        "windows": [
                            AUDIT.cache_claude_window("all-time", 12),
                            AUDIT.cache_claude_window("last-7d", 5),
                            AUDIT.cache_claude_window("latest-session", 5),
                        ],
                    }
                ]
            }

            result = AUDIT.build_claude_audit(root, usage_cache, provider_cache, now)

        self.assertTrue(result["provider_windows_passed"])
        self.assertTrue(result["full_reconciliation_passed"])
        self.assertEqual(result["current_log_windows"]["all-time"]["total_tokens"], 10)
        self.assertEqual(result["deduplicated_log_windows"]["all-time"]["total_tokens"], 5)
        self.assertEqual(result["history_cache_windows"]["all-time"]["total_tokens"], 12)
        self.assertEqual(result["history_reconciliation"]["cache_only_usage"]["total_tokens"], 7)
        self.assertEqual(result["history_reconciliation"]["duplicate_copy_usage"]["total_tokens"], 5)
        self.assertEqual(result["history_reconciliation"]["equation_delta"]["total_tokens"], 0)

    def test_full_reconciliation_flags_conflicting_duplicate_logs(self):
        now = datetime(2026, 7, 11, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, token_count in (("copy-a", 5), ("copy-b", 6)):
                row = {
                    "type": "assistant",
                    "sessionId": "duplicated",
                    "timestamp": "2026-07-10T00:00:00.000Z",
                    "message": {
                        "model": "claude-test",
                        "usage": {"input_tokens": token_count},
                    },
                }
                (root / f"{name}.jsonl").write_text(json.dumps(row), encoding="utf-8")
            usage_cache = {
                "sessions": [
                    {"id": "duplicated", "provider": "claude_code", "startedAt": "2026-07-10T00:00:00Z"}
                ],
                "records": [AUDIT.cache_record("duplicated", 0, "2026-07-10T00:00:00Z", 5)],
            }
            provider_cache = {
                "snapshots": [
                    {
                        "provider": "claude_code",
                        "windows": [
                            AUDIT.cache_claude_window("all-time", 5),
                            AUDIT.cache_claude_window("last-7d", 5),
                            AUDIT.cache_claude_window("latest-session", 5),
                        ],
                    }
                ]
            }

            result = AUDIT.build_claude_audit(root, usage_cache, provider_cache, now)

        self.assertEqual(result["history_reconciliation"]["duplicate_conflict_count"], 1)
        self.assertFalse(result["full_reconciliation_passed"])

    def test_full_reconciliation_flags_equal_total_but_different_duplicate_sequences(self):
        now = datetime(2026, 7, 11, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first_rows = [
                {
                    "type": "assistant",
                    "sessionId": "duplicated",
                    "timestamp": "2026-07-10T00:00:00.000Z",
                    "message": {"model": "claude-test", "usage": {"input_tokens": 2}},
                },
                {
                    "type": "assistant",
                    "sessionId": "duplicated",
                    "timestamp": "2026-07-10T00:01:00.000Z",
                    "message": {"model": "claude-test", "usage": {"input_tokens": 3}},
                },
            ]
            second_rows = [
                {
                    "type": "assistant",
                    "sessionId": "duplicated",
                    "timestamp": "2026-07-10T00:00:30.000Z",
                    "message": {"model": "claude-test", "usage": {"input_tokens": 5}},
                }
            ]
            for name, rows in (("copy-a", first_rows), ("copy-b", second_rows)):
                (root / f"{name}.jsonl").write_text(
                    "\n".join(json.dumps(row) for row in rows), encoding="utf-8"
                )
            usage_cache = {
                "sessions": [
                    {"id": "duplicated", "provider": "claude_code", "startedAt": "2026-07-10T00:00:00Z"}
                ],
                "records": [
                    AUDIT.cache_record("duplicated", 0, "2026-07-10T00:00:00Z", 2),
                    AUDIT.cache_record("duplicated", 1, "2026-07-10T00:01:00Z", 3),
                ],
            }
            provider_cache = {
                "snapshots": [
                    {
                        "provider": "claude_code",
                        "windows": [
                            AUDIT.cache_claude_window("all-time", 5),
                            AUDIT.cache_claude_window("last-7d", 5),
                            AUDIT.cache_claude_window("latest-session", 5),
                        ],
                    }
                ]
            }

            result = AUDIT.build_claude_audit(root, usage_cache, provider_cache, now)

        self.assertEqual(result["history_reconciliation"]["duplicate_conflict_count"], 1)
        self.assertFalse(result["full_reconciliation_passed"])


if __name__ == "__main__":
    unittest.main()
