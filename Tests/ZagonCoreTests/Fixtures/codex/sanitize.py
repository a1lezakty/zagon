#!/usr/bin/env python3
"""Sanitize Codex rollouts into test fixtures: structure, keys, types, ids, timestamps, model names and numbers
stay; every other string becomes "x" (cwd -> /work/pN, path-like keys -> kN). Then checks that no replaced
string of 5+ characters (other than bare numbers and dates) survives in the output.

  python3 -I sanitize.py <codex_home> <out_home> <rollout-name-substring>...
"""
import json, os, re, sys

KEEP = {"type", "timestamp", "model", "id", "call_id", "turn_id", "session_id", "thread_id", "forked_from_id",
        "parent_thread_id", "cli_version", "originator", "model_provider", "effort", "role", "status",
        "thread_source", "history_mode", "limit_id", "phase", "reason", "collaboration_mode_kind", "plan_type"}
TOOL_ITEMS = {"function_call", "custom_tool_call"}
KEY_OK = re.compile(r"^[A-Za-z0-9_]+$")

def run(src_home, out_home, wanted):
    cwds, keys, replaced, kept = {}, {}, set(), set()

    def s(v, key, parent):
        if isinstance(v, dict):
            out = {}
            for k, x in v.items():
                nk = k if KEY_OK.match(k) else keys.setdefault(k, "k%d" % len(keys))
                if nk != k: replaced.add(k)
                else: kept.add(k)  # a value equal to a kept key name (schema words) is not a leak
                out[nk] = s(x, k, v)
            return out
        if isinstance(v, list):
            return [s(x, key, parent) for x in v]
        if not isinstance(v, str):
            return v
        if key == "source" or key in KEEP or (key == "name" and parent.get("type") in TOOL_ITEMS):
            kept.add(v); return v
        replaced.add(v)
        if key == "cwd":
            return cwds.setdefault(v, "/work/p%d" % (len(cwds) + 1))
        return "x"

    outs = []
    for root, _, files in os.walk(src_home):
        for f in sorted(files):
            if not (f.startswith("rollout-") and f.endswith(".jsonl") and any(w in f for w in wanted)): continue
            rel = os.path.relpath(os.path.join(root, f), src_home)
            dst = os.path.join(out_home, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(os.path.join(root, f)) as i, open(dst, "w") as o:
                for line in i:
                    o.write(json.dumps(s(json.loads(line), None, {}), separators=(",", ":"), ensure_ascii=False) + "\n")
            outs.append(dst)
    text = "".join(open(p).read() for p in outs)
    leaks = [r for r in replaced - kept if len(r) >= 5 and not re.match(r"^[0-9-]+$", r) and (r in text or json.dumps(r)[1:-1] in text)
             and r not in cwds.values()]
    for p in outs: print(p, os.path.getsize(p))
    if leaks:
        safe = re.compile(r"^[a-z0-9._:-]{1,16}$")  # enum-like values are shown, anything else only by length
        print("LEAK: %d replaced strings still present: %s" % (len(leaks), sorted(r if safe.match(r) else "<%d chars>" % len(r) for r in leaks)))
        sys.exit(1)
    print("ok: %d files, %d strings replaced, 0 leaks" % (len(outs), len(replaced)))

if __name__ == "__main__":
    run(sys.argv[1], sys.argv[2], sys.argv[3:])
