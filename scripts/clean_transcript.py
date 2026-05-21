#!/usr/bin/env python3
"""Deterministic ASR transcript cleanup inspired by HushType.

Pipeline:
  raw ASR -> OpenCC s2twp (if available) -> filler cleanup -> self-correction
  cleanup -> non-cascading dictionary corrections.

This script intentionally keeps program/source terms outside the generic qwen3-asr
repo. Pass a folder-specific dictionary/corrections file with --corrections.
Supported dictionary formats:
  wrong<TAB>correct
  wrong -> correct
  wrong → correct
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

CJK_RE = re.compile(r"[\u4e00-\u9fff]")
FILLER_ONLY_RE = re.compile(r"^[呃嗯啊哦哎欸ㄜ]+[，,。.]?\s*$")
EN_FILLER_ONLY_RE = re.compile(r"^(um|uh|ah|mm|hm|er)[,.]?\s*$", re.I)
LEADING_FILLER_RE = re.compile(r"(^|(?<=[。！？!?\n]))\s*(?:嗯|啊|呃|欸|那個|就是|um|uh|hmm|er|ah|like|you know)[，,、\s]*", re.I)

# Keep emphatic repetitions such as 對對對 / 好好好 intact.
ZH_DUP_RE = re.compile(r"([\u4e00-\u9fff]{1,4})\1+")
EN_DUP_RE = re.compile(r"\b(?!yes\b|no\b)([A-Za-z][A-Za-z'-]*)\s+\1\b", re.I)

SELF_CORRECTION_MARKERS = ["不對", "我是說", "應該是", "更正", "no actually", "no wait", "I mean", "I meant", "scratch that", "correction"]


@dataclass(frozen=True)
class Entry:
    source: str
    target: str


def read_input(path: str | None) -> str:
    if path:
        return Path(path).read_text(encoding="utf-8")
    return sys.stdin.read()


def contains_cjk(text: str) -> bool:
    return bool(CJK_RE.search(text))


def opencc_s2twp(text: str, *, required: bool = False) -> str:
    """Convert to Taiwan Traditional Chinese using OpenCC if available."""
    if not contains_cjk(text):
        return text

    # Python package path: opencc-python-reimplemented exposes OpenCC.
    try:
        from opencc import OpenCC  # type: ignore

        return OpenCC("s2twp").convert(text)
    except Exception:
        pass

    exe = shutil.which("opencc")
    if exe:
        for config in ("s2twp", "s2twp.json"):
            try:
                proc = subprocess.run(
                    [exe, "-c", config],
                    input=text,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=True,
                )
                return proc.stdout
            except subprocess.CalledProcessError:
                continue

    if required:
        raise RuntimeError("OpenCC unavailable; install opencc or opencc-python-reimplemented for zh-TW conversion")
    return text


def drop_filler_only_lines(text: str) -> str:
    kept: list[str] = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            kept.append(line)
            continue
        if FILLER_ONLY_RE.match(stripped) or EN_FILLER_ONLY_RE.match(stripped):
            continue
        # HushType rule 3: <=2 chars and no letter/CJK content => drop.
        if len(stripped) <= 2 and not re.search(r"[A-Za-z\u4e00-\u9fff]", stripped):
            continue
        kept.append(line)
    return "\n".join(kept)


def remove_leading_fillers(text: str) -> str:
    previous = None
    current = text
    # Repeat to handle sequences like "嗯那個就是..." at a sentence start.
    while current != previous:
        previous = current
        current = LEADING_FILLER_RE.sub(lambda m: m.group(1), current)
    return current


def collapse_immediate_duplicates(text: str) -> str:
    def zh_repl(match: re.Match[str]) -> str:
        token = match.group(1)
        whole = match.group(0)
        if len(set(whole)) == 1 and whole[0] in "對好是嗯啊呃":
            return whole
        return token

    previous = None
    current = text
    while current != previous:
        previous = current
        current = EN_DUP_RE.sub(r"\1", current)
        current = ZH_DUP_RE.sub(zh_repl, current)
    return current


def resolve_simple_self_corrections(text: str) -> str:
    """Resolve very local X<marker>Y corrections without broad rewriting.

    This is deliberately conservative. It only removes the span immediately
    before a marker when the marker is followed by a short corrected value before
    punctuation/newline. Anything complex is left for LLM cleanup.
    """
    # Common Chinese case: 禮拜三不對禮拜五 -> 禮拜五, but preserve stem before X.
    pattern = re.compile(r"([，,。！？!?\n]|^)([^，,。！？!?\n]{1,16}?)(不對|我是說|應該是|更正)([^，,。！？!?\n]{1,24})")

    def repl(match: re.Match[str]) -> str:
        prefix, _wrong, _marker, correct = match.groups()
        return f"{prefix}{correct}"

    return pattern.sub(repl, text)


def parse_entries(path: Path) -> list[Entry]:
    entries: list[Entry] = []
    if not path.exists():
        return entries
    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "\t" in line:
            source, target = line.split("\t", 1)
        elif "->" in line:
            source, target = line.split("->", 1)
        elif "→" in line:
            source, target = line.split("→", 1)
        else:
            print(f"clean_transcript: skip malformed dictionary line {line_no}: {raw}", file=sys.stderr)
            continue
        source = source.strip()
        target = target.strip()
        if not source:
            print(f"clean_transcript: skip empty-source dictionary line {line_no}", file=sys.stderr)
            continue
        entries.append(Entry(source, target))
    return sorted(entries, key=lambda e: len(e.source), reverse=True)


def apply_dictionary(text: str, entries: list[Entry]) -> str:
    """HushType-style longest-first, single-pass, non-cascading replacement.

    Walks the string left-to-right consuming characters. When a dict entry matches
    at the current position, appends the target and advances by len(source) —
    NOT len(target) — which preserves non-cascading semantics: each source character
    is output at most once even when source and target differ in length.

    Word-boundary lookbehind (?<![A-Za-z]) prevents a short pattern (e.g. "Xperia")
    from matching as the tail of a longer one (e.g. "Nexperia"). [A-Za-z] is used
    instead of \\w to avoid Python's Unicode \\w issue in IGNORECASE mode where
    CJK chars count as \\w and break matches before CJK characters.
    """
    if not entries:
        return text
    result = ""
    i = 0
    n = len(text)
    while i < n:
        matched_entry: Entry | None = None
        for entry in entries:
            end = i + len(entry.source)
            if end <= n:
                segment = text[i:end]
                # (?<![A-Za-z]) word-boundary lookbehind: reject if preceded by a letter.
                # This stops "xperia" matching inside "Nexperia" (preceded by "e").
                # Prepending (?<!...) to segment and checking the lookbehind position
                # in the original text is equivalent to the pattern-level assertion.
                preceded_by_letter = (i > 0 and text[i - 1].casefold() in "abcdefghijklmnopqrstuvwxyz")
                if segment.casefold() == entry.source.casefold() and not preceded_by_letter:
                    matched_entry = entry
                    break
        if matched_entry:
            result += matched_entry.target
            i += len(matched_entry.source)
        else:
            result += text[i]
            i += 1
    return result


def clean(text: str, args: argparse.Namespace) -> str:
    if args.opencc:
        text = opencc_s2twp(text, required=args.require_opencc)
    if args.drop_filler_only:
        text = drop_filler_only_lines(text)
    if args.remove_leading_fillers:
        text = remove_leading_fillers(text)
    if args.collapse_duplicates:
        text = collapse_immediate_duplicates(text)
    if args.resolve_self_corrections:
        text = resolve_simple_self_corrections(text)
    for corrections in args.corrections:
        entries = parse_entries(Path(corrections))
        text = apply_dictionary(text, entries)
    return text


def main() -> int:
    parser = argparse.ArgumentParser(description="Deterministic qwen3-asr transcript cleanup")
    parser.add_argument("input", nargs="?", help="Input transcript file; stdin if omitted")
    parser.add_argument("--corrections", action="append", default=[], help="Dictionary/corrections file (repeatable)")
    parser.add_argument("--no-opencc", dest="opencc", action="store_false", help="Disable OpenCC s2twp conversion")
    parser.add_argument("--require-opencc", action="store_true", help="Fail if OpenCC is unavailable")
    parser.add_argument("--no-drop-filler-only", dest="drop_filler_only", action="store_false")
    parser.add_argument("--no-remove-leading-fillers", dest="remove_leading_fillers", action="store_false")
    parser.add_argument("--no-collapse-duplicates", dest="collapse_duplicates", action="store_false")
    parser.add_argument("--resolve-self-corrections", action="store_true", help="Conservatively resolve explicit self-corrections")
    parser.add_argument("-o", "--output", help="Output file; stdout if omitted")
    parser.set_defaults(opencc=True, drop_filler_only=True, remove_leading_fillers=True, collapse_duplicates=True)
    args = parser.parse_args()

    try:
        result = clean(read_input(args.input), args)
    except RuntimeError as exc:
        print(f"clean_transcript: {exc}", file=sys.stderr)
        return 1

    if args.output:
        Path(args.output).write_text(result, encoding="utf-8")
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
