#!/usr/bin/env python3
"""Accept only the exact NSWorkspace handler calls.

The receiver, the selector, and the arguments all have to match.
A mention in a // comment, a # comment, or a string is not a call.
/* is a shell glob in the harness, so it is not treated as a block comment.
"""

import sys

JXA_NAME = "setDefaultApplicationAtURLToOpenURLsWithSchemeCompletionHandler"
SWIFT_NAME = "setDefaultApplication"
GET_NAME = "URLForApplicationToOpenURL"
SEND_NAME = "sendWithOptionsTimeoutError"
TOKENS = ("setDefaultApplication", "LSSetDefaultHandler")
GOOD_SET = "jxa-set"
GOOD_GET = "jxa-get"
GOOD_SEND = "jxa-send"
GOOD_SWIFT = "swift-set"


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
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return src[start + 1:index], index + 1
        index += 1
    return src[start + 1:], limit


def watched(name):
    return (
        name.startswith("setDefaultApplication")
        or name.startswith("LSSetDefaultHandler")
        or name.startswith("URLForApplicationToOpenURL")
        or name.startswith("sendWithOptionsTimeout")
    )


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
                if watched(name):
                    found.append((index, after, ident, args))
                index = after
                continue
            index = end
            continue
        index += 1
    return found


def split_top_args(args):
    parts = []
    buf = []
    index = 0
    depth = 0
    limit = len(args)
    while index < limit:
        char = args[index]
        if char in ("'", '"'):
            end = skip_string(args, index)
            buf.append(args[index:end])
            index = end
            continue
        if char == "(":
            depth += 1
        elif char == ")" and depth:
            depth -= 1
        if char == "," and depth == 0:
            parts.append("".join(buf).strip())
            buf = []
            index += 1
            continue
        buf.append(char)
        index += 1
    tail = "".join(buf).strip()
    if tail:
        parts.append(tail)
    return parts


def jxa_set_ok(ident, args):
    if not ident.endswith(".sharedWorkspace." + JXA_NAME):
        return False
    parts = split_top_args(args)
    if len(parts) != 3:
        return False
    if parts[0] != "appURL" or parts[1] != '"umbilical"':
        return False
    return parts[2].startswith("function")


def lookup_ok(ident):
    return ident.endswith(".sharedWorkspace." + GET_NAME)


def send_ok(ident):
    return ident.split(".")[-1] == SEND_NAME


def swift_ok(ident, args):
    if not ident.endswith(".shared." + SWIFT_NAME):
        return False
    if "completionHandler:" in args:
        return False
    return "at:" in args and "toOpenURLsWithScheme:" in args and "completion:" in args


def classify(ident, args):
    name = ident.split(".")[-1]
    if name.startswith("setDefaultApplication") or name.startswith("LSSetDefaultHandler"):
        if name == JXA_NAME and jxa_set_ok(ident, args):
            return GOOD_SET
        if name == SWIFT_NAME and swift_ok(ident, args):
            return GOOD_SWIFT
        return "bad"
    if name.startswith("URLForApplicationToOpenURL"):
        if lookup_ok(ident):
            return GOOD_GET
        return "bad"
    if name.startswith("sendWithOptionsTimeout"):
        if send_ok(ident):
            return GOOD_SEND
        return "bad"
    return None


def analyze(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    good = []
    bad = []
    blank = list(text)
    for start, end, ident, args in interesting_calls(text):
        kind = classify(ident, args)
        if kind in (GOOD_SET, GOOD_GET, GOOD_SEND, GOOD_SWIFT):
            good.append(kind)
            for offset in range(start, end):
                blank[offset] = " "
        elif kind == "bad":
            bad.append("%s:%s" % (path, ident.split(".")[-1]))
    remaining = "".join(blank)
    leftover = [token for token in TOKENS if token in remaining]
    return good, bad, leftover


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: check-handler-call.py FILE [FILE...]\n")
        return 2
    counts = {GOOD_SET: 0, GOOD_GET: 0, GOOD_SEND: 0, GOOD_SWIFT: 0}
    bad = []
    leftover = []
    for path in argv[1:]:
        good, wrong, remains = analyze(path)
        for kind in good:
            counts[kind] += 1
        bad.extend(wrong)
        leftover.extend("%s:%s" % (path, token) for token in remains)
    expect_swift = 1 if any(path.endswith(".swift") for path in argv[1:]) else 0
    if (
        bad
        or leftover
        or counts[GOOD_SET] != 1
        or counts[GOOD_GET] != 1
        or counts[GOOD_SEND] != 1
        or counts[GOOD_SWIFT] != expect_swift
    ):
        sys.stdout.write(
            "handler call check failed: set=%s get=%s send=%s swift=%s bad=%s leftover=%s\n"
            % (
                counts[GOOD_SET],
                counts[GOOD_GET],
                counts[GOOD_SEND],
                counts[GOOD_SWIFT],
                ",".join(bad),
                ",".join(leftover),
            )
        )
        return 1
    sys.stdout.write("handler call check passed\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
