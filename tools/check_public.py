#!/usr/bin/env python3
"""Reject private data in this public repository.

Usage:
  python3 tools/check_public.py [path ...]     (default: every git-tracked file)

Fails on private IPv4 addresses (except the RFC 5737 documentation ranges and loopback), personal home
paths and credential-looking strings. Binary files are skipped. The exit status is 1 on any finding.
"""
import argparse
import os
import re
import subprocess
import sys

BINARY_SUFFIXES = (
    ".c4z", ".zip", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".webp", ".pdf", ".gz", ".tgz", ".pyc", ".woff",
    ".woff2", ".ttf", ".otf", ".mp3", ".mp4",
)
PRIVATE_IP = re.compile(
    r"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|"
    r"172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b"
)
DOC_IP_PREFIXES = ("192.0.2.", "198.51.100.", "203.0.113.", "127.", "0.0.0.0")
WINDOWS_HOME = re.compile(r"C:\\Users\\([A-Za-z0-9._-]+)")
UNIX_HOME = re.compile(r"/home/([a-z_][a-z0-9_-]*)")
ALLOWED_USERS = {"user", "users", "example", "runner", "public"}
TOKEN = re.compile(
    r"\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|pcp_board_[A-Za-z0-9]{20,}|"
    r"sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16})\b|-----BEGIN [A-Z ]*PRIVATE KEY-----"
)


def is_text(path, data):
    if path.lower().endswith(BINARY_SUFFIXES):
        return False
    return b"\x00" not in data[:8192]


def scan_text(text):
    """Yield (line number, kind, matched text) for private data in one file's text."""
    for lineno, line in enumerate(text.splitlines(), 1):
        for m in PRIVATE_IP.finditer(line):
            ip = m.group(0)
            if ip.startswith(DOC_IP_PREFIXES):
                continue
            if line[m.end():m.end() + 1] == "/":       # a CIDR range, not one host
                continue
            yield lineno, "private IPv4 address", ip
        for m in WINDOWS_HOME.finditer(line):
            if m.group(1).lower() not in ALLOWED_USERS:
                yield lineno, "personal Windows home path", m.group(0)
        for m in UNIX_HOME.finditer(line):
            if m.group(1).lower() not in ALLOWED_USERS:
                yield lineno, "personal home path", m.group(0)
        for m in TOKEN.finditer(line):
            yield lineno, "credential-like token", m.group(0)[:8] + "..."


def git_files():
    r = subprocess.run(["git", "ls-files", "-z"], capture_output=True)
    if r.returncode != 0:
        return []
    return [f for f in r.stdout.decode("utf-8", "replace").split("\0") if f]


def scan_paths(paths):
    findings = []
    for path in paths:
        if not os.path.isfile(path):
            continue
        with open(path, "rb") as fh:
            data = fh.read()
        if not is_text(path, data):
            continue
        for lineno, kind, text in scan_text(data.decode("utf-8", "replace")):
            findings.append((path, lineno, kind, text))
    return findings


def main(argv=None):
    ap = argparse.ArgumentParser(description="Reject private data in this public repository.")
    ap.add_argument("paths", nargs="*", help="files to scan (default: every git-tracked file)")
    args = ap.parse_args(argv)
    paths = args.paths or git_files()
    findings = scan_paths(paths)
    for path, lineno, kind, text in findings:
        print(f"FAIL {path}:{lineno} [S001] {kind}: {text}")
    print(f"{len(findings)} finding(s) in {len(paths)} file(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
