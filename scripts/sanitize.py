#!/usr/bin/env python3
"""Sanitize a Claude Code transcript (JSONL) into a test fixture.

  python3 -I scripts/sanitize.py <in.jsonl> <out.jsonl> [max_lines] [--drop-type TYPE]...

`max_lines` caps the records written; `--drop-type` leaves out records of that `type` (bulky ones the parser
ignores, e.g. api-request-blob), so a small fixture still covers many turns.

Kept: keys that look like identifiers, `type`-like enum values, model names, ids (uuids, msg_/toolu_/req_ ids,
session ids), timestamps, tool names, numbers, booleans, null, and the block structure. Every other string
(text, paths, cwd, branch, titles, tool inputs and outputs) becomes a neutral placeholder of similar shape:
cwd -> /home/user/project-N, other paths -> /home/user/path-N, branch -> branch-N, titles -> title-N,
text -> 'x' repeated (capped), keeping a known system tag at the start (`<task-notification>` etc.) because
the parser classifies records by it. Keys that are not identifiers (file paths as keys) become kN.
Output is compact JSON (the parser prefilters on `"type":"..."` without spaces).

Exits with status 1 if any replaced string of 5+ characters still appears in the output outside kept tokens.
"""
import json, re, sys

ENUM_KEYS = {"type", "subtype", "role", "model", "stop_reason", "service_tier", "userType", "turnOrigin", "version",
             "permissionMode", "level", "operation", "entrypoint", "media_type"}
ID_KEY = re.compile(r"^(id|uuid|.*(Id|_id|Uuid|UUID|ID))$")
ID_VALUE = re.compile(r"^((msg_|toolu_|req_|srvtoolu_)[A-Za-z0-9_-]{8,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
                      r"|[A-Za-z0-9]{16,64})$")
ISO = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:\d\d)?$")
ENUM_VALUE = re.compile(r"^[A-Za-z0-9_.:<>-]{1,40}$")
TOOL_NAME = re.compile(r"^[A-Za-z0-9_]{1,64}$")
KEY_OK = re.compile(r"^[A-Za-z0-9_]+$")
TAGS = ("<task-notification>", "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>",
        "<system-reminder>", "<command-name>", "<command-message>", "<command-args>", "<channel", "<ide_opened_file>",
        "<ide_selection>", "<bash-input>", "<bash-stdout>", "<bash-stderr>", "<user-prompt-submit-hook>")
TEXT_CAP = 80


class Sanitizer:
    def __init__(self):
        self.maps = {}  # (kind, original) -> placeholder
        self.replaced, self.kept = set(), set()

    def mapped(self, kind, v, fmt):
        m = self.maps.setdefault(kind, {})
        return m.setdefault(v, fmt % (len(m) + 1))

    def key(self, k):
        if KEY_OK.match(k):
            self.kept.add(k)
            return k
        self.replaced.add(k)
        return self.mapped("key", k, "k%d")

    def string(self, v, key, parent):
        keep = (
            (key in ENUM_KEYS and ENUM_VALUE.match(v))
            or (key is not None and ID_KEY.match(key) and ID_VALUE.match(v) and re.search(r"\d", v))
            or ISO.match(v)
            or (key == "name" and parent.get("type") in ("tool_use", "server_tool_use") and TOOL_NAME.match(v))
        )
        if keep:
            self.kept.add(v)
            return v
        self.replaced.add(v)
        if v == "":
            return v
        if key == "cwd":
            return self.mapped("cwd", v, "/home/user/project-%d")
        if key == "gitBranch":
            return v if v == "HEAD" else self.mapped("branch", v, "branch-%d")
        if key in ("customTitle", "aiTitle", "agentName", "title", "slug"):
            return self.mapped("title", v, "title-%d")
        if v.startswith("/"):
            return self.mapped("path", v, "/home/user/path-%d")
        tag = next((t for t in TAGS if v.startswith(t)), "")
        return tag + "x" * max(1, min(len(v) - len(tag), TEXT_CAP))

    def value(self, v, key=None, parent=None):
        if isinstance(v, dict):
            return {self.key(k): self.value(x, k, v) for k, x in v.items()}
        if isinstance(v, list):
            return [self.value(x, key, parent) for x in v]
        if isinstance(v, str):
            return self.string(v, key, parent or {})
        return v  # numbers, booleans, null


def main(src, dst, max_lines=None, drop=()):
    s = Sanitizer()
    out = []
    with open(src, encoding="utf-8", errors="replace") as f:
        for line in f:
            if max_lines is not None and len(out) >= max_lines:
                break
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue  # unparsable lines are dropped (they carry raw text)
            if isinstance(rec, dict) and rec.get("type") in drop:
                continue
            out.append(json.dumps(s.value(rec), separators=(",", ":"), ensure_ascii=False))
    text = "\n".join(out) + "\n"
    # Everything that is kept on purpose (keys, kept values, placeholders, tags) is blanked out; what is left must
    # not contain any replaced string.
    allowed = s.kept | {p for m in s.maps.values() for p in m.values()}
    def residue(v):
        if isinstance(v, dict):
            return [["" if k in allowed else k, residue(x)] for k, x in v.items()]
        if isinstance(v, list):
            return [residue(x) for x in v]
        if isinstance(v, str):
            return "" if v in allowed else v[len(next((t for t in TAGS if v.startswith(t)), "")):]
        return v
    rest = json.dumps([residue(json.loads(l)) for l in out], ensure_ascii=False)
    leaks = [r for r in s.replaced - allowed if len(r) >= 5 and (r in rest or json.dumps(r, ensure_ascii=False)[1:-1] in rest)]
    if leaks:
        safe = re.compile(r"^[a-z0-9._:-]{1,16}$")  # enum-like values are shown, anything else only by length
        print("LEAK: %d replaced strings still present: %s" % (len(leaks), sorted(r if safe.match(r) else "<%d chars>" % len(r) for r in leaks)))
        sys.exit(1)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(text)
    print("ok: %s: %d lines, %d bytes, %d strings replaced, 0 leaks" % (dst, len(out), len(text.encode()), len(s.replaced)))


if __name__ == "__main__":
    args, drop = [], []
    it = iter(sys.argv[1:])
    for a in it:
        if a == "--drop-type":
            drop.append(next(it, ""))
        else:
            args.append(a)
    if len(args) not in (2, 3):
        sys.exit(__doc__)
    main(args[0], args[1], int(args[2]) if len(args) == 3 else None, set(drop))
