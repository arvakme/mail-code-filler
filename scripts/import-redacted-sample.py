#!/usr/bin/env python3
"""Import a manually reviewed, already redacted JSON sample into the synthetic corpus."""

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


EMAIL = re.compile(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", re.I)
URL = re.compile(r"https?://[^\s<>\"']+", re.I)
TOKEN = re.compile(r"(?<![A-Za-z0-9])[A-Za-z0-9]{4,10}(?![A-Za-z0-9])")


def check(sample: dict) -> dict:
    required = {"subject", "from-domain", "mime", "body", "expected", "notes"}
    if not required <= sample.keys():
        raise ValueError("missing corpus fields")
    if set(sample) - required - {"source", "id", "redacted-at"}:
        raise ValueError("unexpected fields")
    if sample["mime"] not in {"text/plain", "text/html", "multipart/alternative"}:
        raise ValueError("invalid MIME")
    body = sample["body"]
    if isinstance(body, dict):
        if set(body) != {"plain", "html"} or not all(isinstance(v, str) for v in body.values()):
            raise ValueError("invalid MIME parts")
        text = [body["plain"], body["html"]]
    elif isinstance(body, str):
        text = [body]
    else:
        raise ValueError("invalid body")
    if not all(isinstance(v, str) for v in (sample["subject"], sample["notes"], sample["from-domain"])):
        raise ValueError("invalid text field")
    if not re.fullmatch(r"[a-z0-9.-]+", sample["from-domain"], re.I):
        raise ValueError("invalid sender domain")
    expected = sample["expected"]
    if set(expected) != {"codes", "links"}:
        raise ValueError("invalid expected fields")
    if not isinstance(expected["codes"], list) or not isinstance(expected["links"], list):
        raise ValueError("invalid expected values")
    fields = [sample["subject"], sample["notes"], *text]
    for field in fields:
        if EMAIL.search(field):
            raise ValueError("unredacted email address")
        for match in URL.finditer(field):
            parsed = urlsplit(match.group())
            if parsed.hostname != "example.invalid" or parsed.query or parsed.fragment:
                raise ValueError("unsafe URL")
        for match in TOKEN.finditer(field):
            token = match.group()
            if any(ch.isdigit() for ch in token) and any(ch not in "0Xx" for ch in token):
                raise ValueError("unredacted code-like token")
    for code in expected["codes"]:
        if not isinstance(code, str) or not code or any(ch not in "0Xx" for ch in code):
            raise ValueError("expected code must be a shaped placeholder")
        if not any(code in value for value in text):
            raise ValueError("expected code absent from redacted body")
    for link in expected["links"]:
        if set(link) != {"url", "purpose"} or link["purpose"] not in {"signIn", "activation", "verification"}:
            raise ValueError("invalid expected link")
        parsed = urlsplit(link["url"])
        if parsed.scheme != "https" or parsed.hostname != "example.invalid" or parsed.query or parsed.fragment:
            raise ValueError("unsafe expected link")
    return {
        "subject": sample["subject"],
        "from-domain": sample["from-domain"],
        "mime": sample["mime"],
        "body": sample["body"],
        "expected": sample["expected"],
        "notes": sample["notes"],
        "source": "redacted-real",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Already redacted JSON export")
    parser.add_argument("name", help="Corpus filename stem")
    parser.add_argument("--reviewed", action="store_true", help="Confirm manual privacy review")
    args = parser.parse_args()
    if not args.reviewed:
        parser.error("manual privacy review required: pass --reviewed")
    if not re.fullmatch(r"[a-z0-9-]+", args.name):
        parser.error("name must contain only lowercase letters, digits and hyphens")
    destination = Path(__file__).resolve().parents[1] / "Tests/Fixtures/mail-corpus" / f"{args.name}.json"
    if destination.exists():
        parser.error("destination already exists")
    try:
        sample = check(json.loads(args.input.read_text()))
        destination.write_text(json.dumps(sample, ensure_ascii=False, indent=2) + "\n")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Rejected: {error}", file=sys.stderr)
        return 1
    print(destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
