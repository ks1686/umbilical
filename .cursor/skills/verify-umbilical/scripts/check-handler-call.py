#!/usr/bin/env python3
"""Accept only the exact NSWorkspace handler calls.

A mention in a comment or a string is not a call. Any other
setDefaultApplication or LSSetDefaultHandler call is a failure.
"""

import sys

JXA_NAME = "setDefaultApplicationAtURLToOpenURLsWithSchemeCompletionHandler"
SWIFT_NAME = "setDefaultApplication"
TOKENS = ("setDefaultApplication", "LSSetDefaultHandler")


def skip_string(src, index):
    quote = src[index]
    index += 1
    limit = len(src)
    while index < limit:
        if src[index] == "\\":
            index += 2
            continue
        if src[index] == quote:
            return index + 1
        if quote == '"' and src[index] == "\n":
            return index
        index += 1
    return index


def skip_line(src, index):
    newline = src.find("\n", index)
    if newline < 0:
        return len(src)
    return newline + 1


def skip_block(src, index):
    end = src.find("*/", index + 2)
    if end < 0:
        return len(src)
    return end + 2


def read_balanced(src, index):
    depth = 0
    start = index
    limit = len(src)
    while index < limit:
        char = src[index]
        if char in ("'", '"'):
            index = skip_string(src, index)
            continue
        if src.startswith("//", index) or (char == "#" and (index == 0 or src[index - 1] == "\n")):
            index = skip_line(src, index)
            continue
        if src.startswith("/*", index):
            index = skip_block(src, index)
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return src[start + 1:index], index + 1
        index += 1
    return src[start + 1:], limit


def interesting_calls(src):
    found = []
    index = 0
    limit = len(src)
    while index < limit:
        char = src[index]
        if char in ("'", '"'):
            index = skip_string(src, index)
            continue
        if src.startswith("//", index):
            index = skip_line(src, index)
            continue
        if src.startswith("/*", index):
            index = skip_block(src, index)
            continue
        if char == "#" and (index == 0 or src[index - 1] == "\n"):
            index = skip_line(src, index)
            continue
        if char.isalpha() or char in ("_", "$"):
            end = index + 1
            while end < limit and (src[end].isalnum() or src[end] in "_.$"):
                end += 1
            ident = src[index:end]
            cursor = end
            while cursor < limit and src[cursor] in " \t\r\n":
                cursor += 1
            if cursor < limit and src[cursor] == "(":
                args, after = read_balanced(src, cursor)
                name = ident.split(".")[-1]
                if name.startswith("setDefaultApplication") or name.startswith("LSSetDefaultHandler"):
                    found.append((index, after, name, args))
                index = after
                continue
            index = end
            continue
        index += 1
    return found


def jxa_ok(args):
    compact = " ".join(args.split())
    return compact.startswith("appURL,") and '"umbilical"' in compact and "function" in compact


def swift_ok(args):
    return "at:" in args and "toOpenURLsWithScheme:" in args and "completion:" in args


def analyze(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    good = []
    bad = []
    blank = list(text)
    for start, end, name, args in interesting_calls(text):
        if name == JXA_NAME and jxa_ok(args):
            good.append(JXA_NAME)
        elif name == SWIFT_NAME and swift_ok(args):
            good.append(SWIFT_NAME)
        else:
            bad.append("%s:%s" % (path, name))
        for offset in range(start, end):
            blank[offset] = " "
    remaining = "".join(blank)
    leftover = [token for token in TOKENS if token in remaining]
    return good, bad, leftover


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: check-handler-call.py FILE [FILE...]\n")
        return 2
    jxa = 0
    swift = 0
    bad = []
    leftover = []
    for path in argv[1:]:
        good, wrong, remains = analyze(path)
        jxa += good.count(JXA_NAME)
        swift += good.count(SWIFT_NAME)
        bad.extend(wrong)
        leftover.extend("%s:%s" % (path, token) for token in remains)
    expect_swift = 1 if any(path.endswith(".swift") for path in argv[1:]) else 0
    if bad or leftover or jxa != 1 or swift != expect_swift:
        sys.stdout.write(
            "handler call check failed: jxa=%s swift=%s bad=%s leftover=%s\n"
            % (jxa, swift, ",".join(bad), ",".join(leftover))
        )
        return 1
    sys.stdout.write("handler call check passed\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
