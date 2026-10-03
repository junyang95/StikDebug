#!/usr/bin/env python3
"""Validate Chinese catalogs and source/build coverage using only the standard library.

Run from any directory. After an Xcode build, add --stringsdata-root PATH to
check compiler-extracted SwiftUI and App Intents strings as well.
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys
from typing import Iterator

LANGUAGES = ("zh-Hans", "zh-Hant")
PRINTF = re.compile(
    r"%(?:(?P<position>[1-9]\d*)\$)?[-+ #0']*"
    r"(?P<width>\*(?:[1-9]\d*\$)?|\d+)?"
    r"(?:\.(?P<precision>\*(?:[1-9]\d*\$)?|\d*))?"
    r"(?P<length>hh|ll|[hljztLq])?(?P<conversion>[diouxXfFeEgGaAcCsSpn@DUO%])"
)
TEMPLATE = re.compile(r"\$\{([^{}]+)\}")


def argument_type(length: str, conversion: str) -> str:
    """Treat different renderings of the same C argument type as compatible."""
    if conversion in "di":
        return "signed:" + (length or "int")
    if conversion in "ouxX":
        return "unsigned:" + (length or "int")
    if conversion in "DUO":
        return ("signed:" if conversion == "D" else "unsigned:") + "l"
    if conversion in "fFeEgGaA":
        return "long-double" if length == "L" else "double"
    if conversion in "cC":
        return "wide-char" if length == "l" or conversion == "C" else "char"
    if conversion in "sS":
        return "wide-string" if length == "l" or conversion == "S" else "c-string"
    if conversion == "n":
        return "count-pointer:" + (length or "int")
    return {"@": "object", "p": "pointer"}[conversion]


def printf_arguments(text: str) -> Counter[tuple[int, str]]:
    """Track both argument positions and occurrences; accept positional reordering."""
    result: Counter[tuple[int, str]] = Counter()
    next_position = 1

    def add(kind: str, position: str | None = None) -> None:
        nonlocal next_position
        index = int(position) if position else next_position
        if not position:
            next_position += 1
        result[(index, kind)] += 1

    for match in PRINTF.finditer(text):
        conversion = match["conversion"]
        if conversion == "%":
            continue
        for field in ("width", "precision"):
            value = match[field]
            if value and value.startswith("*"):
                add("signed:int", value[1:-1] if value.endswith("$") else None)
        add(argument_type(match["length"] or "", conversion), match["position"])
    return result


def string_units(value: object, path: tuple[str, ...] = ()) -> Iterator[tuple[tuple[str, ...], dict]]:
    if not isinstance(value, dict):
        return
    unit = value.get("stringUnit")
    if isinstance(unit, dict):
        yield path, unit
    for key, child in value.items():
        if key != "stringUnit" and isinstance(child, dict):
            yield from string_units(child, path + (key,))


def validate_catalog(path: Path, document: object, errors: list[str]) -> dict:
    if not isinstance(document, dict) or not isinstance(document.get("strings"), dict):
        errors.append(f"{path.name}: expected a catalog object with a strings dictionary")
        return {}
    source_language = document.get("sourceLanguage", "en")
    entries = document["strings"]
    for key, entry in entries.items():
        label = f"{path.name}: {key!r}"
        if not isinstance(entry, dict):
            errors.append(f"{label}: entry must be an object")
            continue
        if entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        if not isinstance(localizations, dict):
            errors.append(f"{label}: localizations must be an object")
            continue
        source_units = dict(string_units(localizations.get(source_language, {})))
        source_default = source_units.get((), {}).get("value", key)
        for language in LANGUAGES:
            units = list(string_units(localizations.get(language, {})))
            if not units:
                errors.append(f"{label}: missing {language} translation")
                continue
            for unit_path, unit in units:
                context = f"{label} [{language}{'/' + '/'.join(unit_path) if unit_path else ''}]"
                text = unit.get("value")
                if unit.get("state") != "translated" or not isinstance(text, str) or not text.strip():
                    errors.append(f"{context}: must contain a nonempty translated stringUnit")
                    continue
                source = source_units.get(unit_path, {}).get("value", source_default)
                if not isinstance(source, str):
                    errors.append(f"{context}: source string must be text")
                    continue
                expected, actual = printf_arguments(source), printf_arguments(text)
                if expected != actual:
                    errors.append(f"{context}: printf arguments differ: expected {dict(expected)}, got {dict(actual)}")
                expected_templates, actual_templates = set(TEMPLATE.findall(source)), set(TEMPLATE.findall(text))
                if expected_templates != actual_templates:
                    errors.append(f"{context}: template names differ: expected {sorted(expected_templates)}, got {sorted(actual_templates)}")
    return entries


def skip_comment(text: str, index: int) -> int | None:
    if text.startswith("//", index):
        end = text.find("\n", index + 2)
        return len(text) if end < 0 else end
    if text.startswith("/*", index):
        level, index = 1, index + 2
        while index < len(text) and level:
            if text.startswith("/*", index):
                level, index = level + 1, index + 2
            elif text.startswith("*/", index):
                level, index = level - 1, index + 2
            else:
                index += 1
        return index
    return None


def skip_interpolation(text: str, index: int) -> int:
    level = 1
    while index < len(text) and level:
        comment_end = skip_comment(text, index)
        if comment_end is not None:
            index = comment_end
            continue
        string = read_swift_string(text, index)
        if string is not None:
            index = string[0]
            continue
        if text[index] == "(":
            level += 1
        elif text[index] == ")":
            level -= 1
        index += 1
    return index


def read_swift_string(
    text: str, index: int, interpolations: list[tuple[int, int]] | None = None
) -> tuple[int, str, bool] | None:
    """Read a Swift string, including raw/multiline literals and interpolations."""
    start = index
    while index < len(text) and text[index] == "#":
        index += 1
    hashes = text[start:index]
    if index >= len(text) or text[index] != '"':
        return None
    multiline = text.startswith('"""', index)
    quote = '"""' if multiline else '"'
    closing = quote + hashes
    index += len(quote)
    pieces: list[str] = []
    interpolated = False
    escape = "\\" + hashes
    while index < len(text):
        if text.startswith(closing, index):
            result = "".join(pieces)
            if multiline:
                # Swift strips the opening newline and the closing delimiter's indent.
                lines = result.split("\n")
                if lines and not lines[0]:
                    lines = lines[1:]
                indent = lines.pop() if lines and not lines[-1].strip() else ""
                if indent:
                    lines = [line[len(indent):] if line.startswith(indent) else line for line in lines]
                result = "\n".join(lines)
            return index + len(closing), result, interpolated
        if text.startswith(escape, index):
            index += len(escape)
            if index >= len(text):
                break
            character = text[index]
            if character == "(":
                interpolated = True
                expression_start = index + 1
                index = skip_interpolation(text, expression_start)
                if interpolations is not None:
                    interpolations.append((expression_start, index - 1))
                continue
            if character == "u" and text.startswith("u{", index):
                end = text.find("}", index + 2)
                if end >= 0:
                    try:
                        pieces.append(chr(int(text[index + 2:end], 16)))
                        index = end + 1
                        continue
                    except (ValueError, OverflowError):
                        pass
            if character == "\n":
                index += 1
                while index < len(text) and text[index] in " \t":
                    index += 1
                continue
            pieces.append({"n": "\n", "r": "\r", "t": "\t", "0": "\0"}.get(character, character))
            index += 1
        else:
            pieces.append(text[index])
            index += 1
    return index, "".join(pieces), interpolated


def localized_literals(text: str) -> Iterator[tuple[int, str, bool]]:
    index = 0
    while index < len(text):
        comment_end = skip_comment(text, index)
        if comment_end is not None:
            index = comment_end
            continue
        interpolations: list[tuple[int, int]] = []
        string = read_swift_string(text, index, interpolations)
        if string is None:
            index += 1
            continue
        end, value, interpolated = string
        member_start = end
        while member_start < len(text):
            if text[member_start].isspace():
                member_start += 1
                continue
            comment_end = skip_comment(text, member_start)
            if comment_end is None:
                break
            member_start = comment_end
        if re.match(r"\.\s*localized\b", text[member_start:]):
            yield text.count("\n", 0, index) + 1, value, interpolated
        for expression_start, expression_end in interpolations:
            offset = text.count("\n", 0, expression_start)
            for line, nested_value, nested_interpolated in localized_literals(text[expression_start:expression_end]):
                yield offset + line, nested_value, nested_interpolated
        index = end


def has_words(key: str) -> bool:
    remainder = TEMPLATE.sub("", PRINTF.sub("", key))
    return any(character.isalpha() for character in remainder)


def read_json(path: Path, errors: list[str]) -> object | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        errors.append(f"{path}: cannot read JSON: {error}")
        return None


def validate_extracted(root: Path, project: Path, entries: dict, errors: list[str]) -> tuple[int, int]:
    if not root.is_dir():
        errors.append(f"stringsdata root is not a directory: {root}")
        return 0, 0
    source_root = (project / "StikDebug").resolve()
    project_files, checked = 0, set()
    for path in sorted(root.rglob("*.stringsdata")):
        document = read_json(path, errors)
        if not isinstance(document, dict):
            continue
        source = document.get("source")
        if not isinstance(source, str):
            continue
        source_path = Path(source)
        if not source_path.is_absolute():
            source_path = project / source_path
        try:
            source_path.resolve().relative_to(source_root)
        except ValueError:
            continue
        tables = document.get("tables", {})
        if not isinstance(tables, dict):
            errors.append(f"{path}: expected a tables dictionary")
            continue
        project_files += 1
        table = tables.get("Localizable", [])
        if not isinstance(table, list):
            errors.append(f"{path}: Localizable table must be a list")
            continue
        for entry in table:
            if not isinstance(entry, dict) or not isinstance(entry.get("key"), str):
                errors.append(f"{path}: extracted entry must contain a string key")
                continue
            key = entry["key"]
            if key in checked or not has_words(key):
                continue
            checked.add(key)
            if key not in entries:
                line = entry.get("location", {}).get("startingLine", "?")
                errors.append(f"{source_path.relative_to(project)}:{line}: compiler-extracted key missing from Localizable: {key!r}")
    if not project_files:
        errors.append(f"no stringsdata for this project's StikDebug source directory found under {root}")
    return project_files, len(checked)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stringsdata-root", type=Path, help="Xcode build output directory to scan for *.stringsdata")
    arguments = parser.parse_args()
    project = Path(__file__).resolve().parent.parent
    source_root = project / "StikDebug"
    errors: list[str] = []
    catalogs = sorted(source_root.rglob("*.xcstrings"))
    localizable: dict = {}
    total_entries = 0
    for path in catalogs:
        document = read_json(path, errors)
        if document is not None:
            entries = validate_catalog(path, document, errors)
            total_entries += len(entries)
            if path == source_root / "Localizable.xcstrings":
                localizable = entries
    if not (source_root / "Localizable.xcstrings").is_file():
        errors.append("StikDebug/Localizable.xcstrings is missing")
    literal_count = 0
    for path in sorted(source_root.rglob("*.swift")):
        for line, key, interpolated in localized_literals(path.read_text(encoding="utf-8")):
            literal_count += 1
            location = f"{path.relative_to(project)}:{line}"
            if interpolated:
                errors.append(f"{location}: interpolated .localized cannot use a stable catalog key; use a format string")
            elif key not in localizable:
                errors.append(f"{location}: literal key missing from Localizable: {key!r}")
    extracted_summary = ""
    if arguments.stringsdata_root is not None:
        files, keys = validate_extracted(arguments.stringsdata_root, project, localizable, errors)
        extracted_summary = f", {keys} compiler-extracted keys from {files} project files"
    if errors:
        print(f"Localization verification failed ({len(errors)} errors):", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"Localization verification passed: {len(catalogs)} catalogs, {total_entries} entries, {literal_count} .localized literals{extracted_summary}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
