#!/usr/bin/env python3
"""Validate a captured sendmail message for the alert e-mail tests."""
from __future__ import annotations

import argparse
import sys
from email import policy
from email.parser import BytesParser
from pathlib import Path


def load(path: Path):
    return BytesParser(policy=policy.default).parsebytes(path.read_bytes())


def part_text(p) -> str:
    body = p.get_content()
    return body if isinstance(body, str) else body.decode("utf-8", "replace")


def check_mixed(msg_path: Path, reports_dir: Path | None, expect_status: str, expect_nc: int) -> None:
    msg = load(msg_path)
    if msg.get_content_type() != "multipart/mixed":
        raise SystemExit(f"expected multipart/mixed, got {msg.get_content_type()}")
    parts = list(msg.iter_parts())
    if len(parts) != 3:
        raise SystemExit(f"expected 3 mixed parts, got {[p.get_content_type() for p in parts]}")
    alt, hatt, catt = parts
    if alt.get_content_type() != "multipart/alternative":
        raise SystemExit(f"expected alternative, got {alt.get_content_type()}")
    bodies = list(alt.iter_parts())
    types = [b.get_content_type() for b in bodies]
    if types != ["text/plain", "text/html"]:
        raise SystemExit(f"expected text then html, got {types}")
    text, html = part_text(bodies[0]), part_text(bodies[1])
    if not text.startswith(f"RDS backup compliance: {expect_status}"):
        raise SystemExit(f"text start: {text.splitlines()[:1]}")
    if "RDS backup compliance report from" in text:
        raise SystemExit("hostname lead line still present in the text body")
    if expect_nc > 0:
        if f"NON-COMPLIANT servers ({expect_nc}):" not in text:
            raise SystemExit("missing NON-COMPLIANT table in text")
        if "background:#b3261e" not in html or "<table" not in html or ("What's missing" not in html and "What&apos;s missing" not in html):
            raise SystemExit("HTML body missing red banner or failures table")
        if "No NON-COMPLIANT servers." in html:
            raise SystemExit("unexpected empty-failures sentence")
    else:
        if "background:#137333" not in html:
            raise SystemExit("HTML body missing green banner")
        if "No NON-COMPLIANT servers." not in html and "No NON-COMPLIANT servers." not in text:
            raise SystemExit("missing 'No NON-COMPLIANT servers.'")
        if "NON-COMPLIANT servers (" in html or "NON-COMPLIANT servers (" in text:
            raise SystemExit("failures table present on a compliant run")
    import re
    short = re.compile(r"^[A-Za-z0-9._-]+_[0-9]{4}-[0-9]{2}-[0-9]{2}\.(html|csv)$")
    hf, cf = hatt.get_filename() or "", catt.get_filename() or ""
    if hatt.get_content_type() != "text/html" or not short.fullmatch(hf) or not hf.endswith(".html"):
        raise SystemExit(f"bad html attachment {hatt.get_content_type()} {hf}")
    if catt.get_content_type() != "text/csv" or not short.fullmatch(cf) or not cf.endswith(".csv"):
        raise SystemExit(f"bad csv attachment {catt.get_content_type()} {cf}")
    for body in (text, html):
        if "is attached" in body.lower() or "Attachment (sendmail" in body:
            raise SystemExit("attachment list still present in the e-mail body")
    if reports_dir is not None:
        html_file = next(reports_dir.glob("*.html"))
        csv_file = next(
            p
            for p in reports_dir.glob("*.csv")
            if not any(s in p.name for s in ("_backups", "_orphaned", "_manual_older"))
        )
        if hatt.get_payload(decode=True) != html_file.read_bytes():
            raise SystemExit("HTML attachment does not match the written report")
        if catt.get_payload(decode=True) != csv_file.read_bytes():
            raise SystemExit("CSV attachment does not match the written compliance CSV")
    print("mime ok")


def check_escape(jq_file: Path) -> None:
    import json
    import subprocess

    doc = {
        "totals": {
            "resources": 1,
            "compliant": 0,
            "non_compliant": 1,
            "not_yet_due": 0,
            "unknown": 0,
            "compliance": {"pct": 0, "compliant": 0, "of": 1},
        },
        "accounts": [{"account": "111111111111", "name": "prod-payments"}],
        "regions": [],
        "rows": [
            {
                "status": "NON-COMPLIANT",
                "account_id": "111111111111",
                "account_name": "prod-payments",
                "region": "us-east-1",
                "identifier": "<img src=x onerror=alert(1)>",
                "engine": "postgres",
                "gaps": "weekly 0/1 missing <Sat>",
            }
        ],
    }
    html = subprocess.check_output(
        [
            "jq",
            "-r",
            "-f",
            str(jq_file),
            "--arg",
            "mode",
            "html",
            "--arg",
            "host",
            "jumpbox-01",
            "--arg",
            "tool",
            "rds_backup_compliance_report.sh v1.7.2",
            "--arg",
            "when",
            "now",
            "--argjson",
            "files",
            "[]",
        ],
        input=json.dumps(doc),
        text=True,
    )
    if "<img" in html:
        raise SystemExit("raw <img tag leaked into the e-mail body")
    if "&lt;img src=x onerror=alert(1)&gt;" not in html or "&lt;Sat&gt;" not in html:
        raise SystemExit("expected escaped identifier / gaps not found")
    print("escape ok")


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("mixed")
    m.add_argument("message")
    m.add_argument("reports", nargs="?")
    m.add_argument("--status", default="NON-COMPLIANT")
    m.add_argument("--nc", type=int, default=3)
    e = sub.add_parser("escape")
    e.add_argument("jqfile")
    args = ap.parse_args()
    if args.cmd == "mixed":
        check_mixed(
            Path(args.message),
            Path(args.reports) if args.reports else None,
            args.status,
            args.nc,
        )
    else:
        check_escape(Path(args.jqfile))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
