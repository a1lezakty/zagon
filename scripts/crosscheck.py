#!/usr/bin/env python3
"""Independent token count of one local day straight from Claude Code transcripts, compared with `zagon day --json`.

Full JSON parse of every assistant record (no byte scanner, no database). Records of one API request share
`message.id`; each field takes its maximum over the copies. Days follow TZ like zagon.

    TZ=UTC python3 -I scripts/crosscheck.py --claude-dir ~/.claude/projects --day 2026-10-29 --zagon-json day.json
"""
import argparse, datetime, json, os, sys, time

FIELDS = [("input", "input_tokens"), ("output", "output_tokens"), ("cache_read", "cache_read_input_tokens"),
          ("cache_write", "cache_creation_input_tokens")]


def transcripts(root):
    """Main-thread files <project>/<session>.jsonl and sub-agent files <project>/<session>/subagents/**/agent-*.jsonl."""
    for dirpath, _, files in os.walk(root):
        rel = os.path.relpath(dirpath, root).split(os.sep)
        for f in files:
            if not f.endswith(".jsonl"):
                continue
            if len(rel) == 1 and rel != ["."]:
                yield os.path.join(dirpath, f)
            elif len(rel) >= 3 and rel[2] == "subagents" and f.startswith("agent-"):
                yield os.path.join(dirpath, f)


def local_day(ts):
    t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    return time.strftime("%Y-%m-%d", time.localtime(t))


def count(root, day):
    best = {}  # key -> (model, [fields])
    anon = 0
    for path in transcripts(root):
        with open(path, "rb") as fh:
            for line in fh:
                if b'"assistant"' not in line:
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(r, dict) or r.get("type") != "assistant":
                    continue
                m = r.get("message")
                if not isinstance(m, dict) or not isinstance(m.get("usage"), dict):
                    continue
                try:
                    if local_day(r["timestamp"]) != day:
                        continue
                except (KeyError, ValueError, AttributeError):
                    continue
                u = m["usage"]
                v = [int(u.get(k) or 0) for _, k in FIELDS]
                key = m.get("id")
                if key is None:
                    anon += 1
                    key = ("no-id", anon)
                model = m.get("model") or "?"
                old = best.get(key)
                best[key] = (model, v if old is None else [max(a, b) for a, b in zip(old[1], v)])
    per_model = {}
    for model, v in best.values():
        t = per_model.setdefault(model, [0, 0, 0, 0, 0])
        for i in range(4):
            t[i] += v[i]
        t[4] += 1
    return per_model


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--claude-dir", required=True)
    ap.add_argument("--day", required=True)
    ap.add_argument("--zagon-json", required=True)
    a = ap.parse_args()
    py = count(a.claude_dir, a.day)
    with open(a.zagon_json) as f:
        z = json.load(f)
    zm = {m["model"]: [m["tokens"][k] for k, _ in FIELDS] + [m["tokens"]["requests"]] for m in z["models"]}
    names = [k for k, _ in FIELDS] + ["requests"]
    ok = True
    for model in sorted(set(py) | set(zm)):
        p, q = py.get(model, [0] * 5), zm.get(model, [0] * 5)
        if p != q:
            ok = False
            print(f"{a.day} MISMATCH {model}: " + ", ".join(f"{n} py={x} zagon={y}" for n, x, y in zip(names, p, q) if x != y))
    tp = [sum(v[i] for v in py.values()) for i in range(5)]
    tz = [z["tokens"][k] for k, _ in FIELDS] + [z["tokens"]["requests"]]
    if tp != tz:
        ok = False
    print(f"{a.day} {'OK' if ok else 'FAIL'}  python " + " ".join(f"{n}={x}" for n, x in zip(names, tp))
          + ("" if tp == tz else "  zagon " + " ".join(f"{n}={x}" for n, x in zip(names, tz))))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
