#!/usr/bin/env python3
"""Accept only the exact NSWorkspace handler calls.

The receiver, the selector, and the arguments all have to match.
A mention in a // comment, a # comment, or a string is not a call.
/* is a shell glob in the harness, so it is not treated as a block comment.
"""

import ast
import os
import pathlib
import re
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
    return name.startswith((
        "setDefaultApplication",
        "LSSetDefaultHandler",
        "URLForApplicationToOpenURL",
        "sendWithOptionsTimeout",
    ))


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


def lookup_ok(ident, args):
    return ident.endswith(".sharedWorkspace." + GET_NAME) and split_top_args(args) == ["url"]


def send_ok(ident, args):
    return ident == "event." + SEND_NAME and split_top_args(args) == ["1", "30", "error"]


def swift_ok(ident, args):
    if ident != "NSWorkspace.shared." + SWIFT_NAME:
        return False
    if "completionHandler:" in args:
        return False
    parts = split_top_args(args)
    if len(parts) != 3:
        return False
    if parts[0] != "at: appURL":
        return False
    if parts[1] != 'toOpenURLsWithScheme: "umbilical"':
        return False
    return parts[2].startswith("completion:")


def classify(ident, args):
    name = ident.split(".")[-1]
    if name.startswith(("setDefaultApplication", "LSSetDefaultHandler")):
        if name == JXA_NAME and jxa_set_ok(ident, args):
            return GOOD_SET
        if name == SWIFT_NAME and swift_ok(ident, args):
            return GOOD_SWIFT
        return "bad"
    if name.startswith("URLForApplicationToOpenURL"):
        if lookup_ok(ident, args):
            return GOOD_GET
        return "bad"
    if name.startswith("sendWithOptionsTimeout"):
        if send_ok(ident, args):
            return GOOD_SEND
        return "bad"
    return None


def required_snippets(path, text):
    if path.endswith(".swift"):
        needed = (
            "NSWorkspace.shared.setDefaultApplication",
            'toOpenURLsWithScheme: "umbilical"',
        )
    else:
        needed = (
            'URLWithString("umbilical://download")',
            'setDefaultApplicationAtURLToOpenURLsWithSchemeCompletionHandler(appURL, "umbilical", function',
            "sendWithOptionsTimeoutError(1, 30, error)",
        )
    return ["%s:%s" % (path, token) for token in needed if token not in text]


def analyze(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    good = []
    bad = []
    bad.extend(required_snippets(path, text))
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


WATCHED_PREFIXES = (
    "setDefaultApplication",
    "LSSetDefaultHandler",
    "URLForApplicationToOpenURL",
    "sendWithOptionsTimeout",
)


def watched_shape(tree):
    fn = None
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == "watched":
            fn = node
            break
    if fn is None or len(fn.body) != 1 or not isinstance(fn.body[0], ast.Return):
        return None
    value = fn.body[0].value
    if not isinstance(value, ast.Call) or len(value.args) != 1:
        return None
    func = value.func
    if not isinstance(func, ast.Attribute) or func.attr != "startswith":
        return None
    arg = value.args[0]
    if not isinstance(arg, ast.Tuple):
        return None
    prefixes = []
    for elt in arg.elts:
        if not isinstance(elt, ast.Constant) or not isinstance(elt.value, str):
            return None
        prefixes.append(elt.value)
    return tuple(prefixes)


def self_check(path):
    # A chain of startswith calls is PIE810 and used to hide a new prefix in
    # the noise. The bad sample must fail, and this file must stay a tuple.
    bad = ast.parse(
        "def watched(name):\n"
        "    return (\n"
        "        name.startswith('setDefaultApplication')\n"
        "        or name.startswith('LSSetDefaultHandler')\n"
        "        or name.startswith('URLForApplicationToOpenURL')\n"
        "        or name.startswith('sendWithOptionsTimeout')\n"
        "    )\n"
    )
    if watched_shape(bad) is not None:
        sys.stdout.write("a chained startswith was accepted\n")
        return 1
    source = pathlib.Path(path).read_text(encoding="utf-8")
    good = watched_shape(ast.parse(source))
    if good != WATCHED_PREFIXES:
        sys.stdout.write("watched() is not the startswith tuple\n")
        return 1
    if re.search(r"startswith\([^)\n]*\)\s+or\s+\w+\.startswith\(", source):
        sys.stdout.write("a startswith chain is back\n")
        return 1
    sys.stdout.write("watched() startswith tuple check passed\n")
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-check":
        return self_check(os.path.abspath(__file__))
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
