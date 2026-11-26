#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Checks that every on-screen text in SaveKey is translated.

Finds the localization keys the way iOS looks them up: SwiftUI views given a string literal
(Text("…"), Button("…"), Label("…", …) and so on), String(localized: "…"), and the engine's
localized("…"). Interpolations become format specifiers like Swift builds the key: Int → %lld,
everything else → %@ (list Int expressions in INT_EXPRS below).

Then compares the keys with the tables in strings_*.py:

    python3 Tools/Localization/check_translations.py           # report, exit 1 if anything is missing
    python3 Tools/Localization/check_translations.py --where   # also show where each missing key is used
    python3 Tools/Localization/check_translations.py --interp  # list interpolations and their specifiers

After adding translations, run make_strings.py to write the .strings files.
"""
import re
import sys
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

FILES = sorted([*ROOT.glob("App/**/*.swift"), *ROOT.glob("Shared/*.swift"), *ROOT.glob("AutoFill/*.swift"),
                *ROOT.glob("Packages/KeePassCore/Sources/KeePassCore/**/*.swift")])

# Literals made only of punctuation, numbers or format specifiers need no translation.
UNTRANSLATABLE = re.compile(r"^[\s\-–—/·•:|%@lld0-9.,()+]*$")


def scan(src):
    """Yield (start, end, raw_content) for each single-line or multi-line string literal, skipping comments."""
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if c == '#' and i + 1 < n and src[i + 1] == '"':
            # raw string #"..."#
            j = src.find('"#', i + 2)
            yield (i, j + 2, src[i + 2:j], True)
            i = j + 2
            continue
        if c == '"':
            if src.startswith('"""', i):
                j = src.find('"""', i + 3)
                yield (i, j + 3, src[i + 3:j], False)
                i = j + 3
                continue
            j = i + 1
            depth = 0
            while j < n:
                ch = src[j]
                if ch == '\\' and j + 1 < n and src[j + 1] == '(':
                    # interpolation: skip balanced parens, allowing nested strings
                    j += 2
                    depth = 1
                    while j < n and depth:
                        if src[j] == '"':
                            # nested string inside interpolation
                            k = j + 1
                            while k < n and src[k] != '"':
                                if src[k] == '\\':
                                    k += 1
                                k += 1
                            j = k + 1
                            continue
                        if src[j] == '(':
                            depth += 1
                        elif src[j] == ')':
                            depth -= 1
                        j += 1
                    continue
                if ch == '\\':
                    j += 2
                    continue
                if ch == '"':
                    break
                j += 1
            yield (i, j + 1, src[i + 1:j], False)
            i = j + 1
            continue
        i += 1

SWIFTUI = {"Text", "Button", "Label", "Section", "Toggle", "Picker", "TextField", "SecureField", "DatePicker",
           "Stepper", "Menu", "Link", "ProgressView", "navigationTitle", "alert", "confirmationDialog",
           "accessibilityLabel", "accessibilityHint", "help", "LabeledContent"}
LABELLED = {("InfoRow", "label"), ("searchable", "prompt")}
# Interpolated expressions that are Int (key gets %lld); everything else is %@.
INT_EXPRS = {
    "results.count", "historyMaxItems", "historyMaxSizeMiB", "draft.iterations", "draft.memoryMiB",
    "draft.parallelism", "settings.passwordOptions.length", "settings.passphraseOptions.wordCount",
    "counter", "period", "otp.digits", "otp.period", "Int(bits)", "Int(s)", "remaining",
    "entry.history.count", "group.allEntries.count", "$0",
}

def interp_to_spec(content, ints_seen):
    out, i = "", 0
    while i < len(content):
        if content.startswith("\\(", i):
            depth, j = 1, i + 2
            while depth:
                if content[j] == "(": depth += 1
                elif content[j] == ")": depth -= 1
                j += 1
            expr = content[i + 2:j - 1].strip()
            spec = "%lld" if expr in INT_EXPRS else "%@"
            ints_seen.append((expr, spec))
            out += spec
            i = j
        elif content.startswith("\\", i):
            nxt = content[i + 1]
            out += {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'"}.get(nxt, nxt)
            i += 2
        else:
            out += content[i]; i += 1
    return out

def call_before(src, start):
    """Return (callee, label) for the innermost unclosed '(' before `start`, and the text in between."""
    depth, i = 0, start - 1
    while i >= 0:
        ch = src[i]
        if ch == ")": depth += 1
        elif ch == "(":
            if depth == 0: break
            depth -= 1
        elif ch == "{" and depth == 0: return None, None, None
        i -= 1
    if i < 0: return None, None, None
    m = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*$", src[:i])
    callee = m.group(1) if m else None
    between = src[i + 1:start]
    return callee, between, i

def classify(src, start):
    callee, between, pos = call_before(src, start)
    # Grouping parentheses, e.g. Text(a ? "x" : (b ? "y" : "z")): look at the enclosing call instead.
    while callee is None and pos is not None:
        if not re.search(r"[?:]\s*$", src[:pos]):
            break
        callee, between2, pos = call_before(src, pos)
        if callee is not None:
            between = between2 + "(" + between
    if callee is None: return "other"
    # strip nested string literals/parens from `between` to test for top-level commas
    flat = re.sub(r'"(?:\\.|[^"\\])*"', '""', between)
    if callee == "localized" and flat.strip().startswith("localized:"):  # String(localized:)
        pass
    if callee == "String" and re.match(r"\s*localized:\s*$", between): return "string-localized"
    if callee in ("localized", "NSLocalizedString") and between.strip() == "": return "verbatim"
    top = re.sub(r"\([^()]*\)", "()", flat)
    while re.search(r"\([^()]*\)", top) and top != re.sub(r"\([^()]*\)", "", top):
        top = re.sub(r"\([^()]*\)", "", top)
    if callee in SWIFTUI and "," not in top:
        return "swiftui"
    for c, label in LABELLED:
        if callee == c and re.search(label + r":\s*$", between): return "swiftui"
    return "other"

def extract():
    keys, others, ints = {}, [], []
    for f in FILES:
        src = f.read_text()
        rel = str(f.relative_to(ROOT))
        for start, end, content, raw in scan(src):
            kind = classify(src, start)
            line = src.count("\n", 0, start) + 1
            if kind in ("swiftui", "string-localized"):
                key = interp_to_spec(content, ints)
            elif kind == "verbatim":
                key = interp_to_spec(content, ints)
            else:
                others.append((f"{rel}:{line}", content)); continue
            keys.setdefault(key, []).append(f"{rel}:{line}")
    return keys, others, ints


def main():
    import make_strings
    keys, _others, ints = extract()
    make_strings.load()
    tables = make_strings.STRINGS
    missing = sorted(k for k in keys if k not in tables and not UNTRANSLATABLE.match(k))
    unused = sorted(k for k in tables if k not in keys)
    print(f"{len(keys)} keys in the code, {len(tables)} in the translation tables.")
    if "--interp" in sys.argv:
        for expr, spec in sorted(set(ints)):
            print(f"  {spec}\t{expr}")
    if unused:
        print(f"\n{len(unused)} translated key(s) no longer used (can be removed from strings_*.py):")
        for k in unused:
            print("  " + repr(k))
    if missing:
        print(f"\n{len(missing)} key(s) without translations (add them to a strings_*.py table):")
        for k in missing:
            where = ", ".join(keys[k][:3]) if "--where" in sys.argv else ""
            print("  " + repr(k) + (f"   ({where})" if where else ""))
        return 1
    print("Every key is translated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
