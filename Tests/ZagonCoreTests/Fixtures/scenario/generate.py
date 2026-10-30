#!/usr/bin/env python3
"""Synthetic Claude Code transcripts + hook/status-line spool for Query tests and Mac app snapshots.

Everything here is made up (projects, titles, prompts), so the output is anonymous by construction. The scenario
follows the design mockups: "now" is 2026-10-30 11:42 UTC; Thursday 2026-10-29 is the detailed day.

  python3 -I generate.py            # rewrites projects/ and spool/ next to this file
"""
import json, os, random, shutil, uuid
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
UTC = timezone.utc
NOW = datetime(2026, 10, 30, 11, 42, tzinfo=UTC)
rng = random.Random(29)
OPUS, SONNET, HAIKU = "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5"
TOOLS = ["Bash", "Edit", "Read", "Read", "Bash", "Grep", "Write", "Agent"]


def at(day, hour):
    """2026-10-<day> at a fractional UTC hour."""
    return datetime(2026, 10, 1, tzinfo=UTC) + timedelta(days=day - 1, hours=hour)


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


def sid(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "zagon-fixture/" + name))


class Session:
    def __init__(self, name, project, title, model=OPUS, branch="main"):
        self.id, self.project, self.title, self.model, self.branch = sid(name), project, title, model, branch
        self.cwd = "/work/" + project
        self.lines, self.sub = [], []
        self.n = 0
        self.lines.append({"type": "custom-title", "customTitle": title, "sessionId": self.id})

    def base(self, t):
        return {"timestamp": iso(t), "cwd": self.cwd, "gitBranch": self.branch, "sessionId": self.id,
                "uuid": str(uuid.uuid5(uuid.NAMESPACE_URL, f"{self.id}/{self.n}")), "isSidechain": False}

    def assistant(self, t, model=None):
        self.n += 1
        content = [{"type": "text", "text": "done"}]
        if rng.random() < 0.7:
            content.append({"type": "tool_use", "id": f"toolu_{self.id[:8]}_{self.n}", "name": rng.choice(TOOLS),
                            "input": {}})
        usage = {"input_tokens": rng.randint(2, 9), "output_tokens": rng.randint(200, 900),
                 "cache_read_input_tokens": rng.randint(40_000, 90_000),
                 "cache_creation_input_tokens": rng.randint(800, 4_000)}
        return dict(self.base(t), type="assistant",
                    message={"id": f"msg_{self.id[:8]}_{self.n}", "model": model or self.model, "role": "assistant",
                             "content": content, "usage": usage})

    def work(self, day, a, b, prompt, step=9, chat=False):
        """A typed prompt at `a`, then the agent busy until `b` (records every ~`step` minutes). `chat`: the human
        answers short replies along the way, which is what makes "your time"."""
        self.n += 1
        self.lines.append(dict(self.base(at(day, a)), type="user", message={"role": "user", "content": prompt}))
        t = at(day, a) + timedelta(minutes=1)
        k = 0
        while t <= at(day, b):
            self.lines.append(self.assistant(t))
            k += 1
            if chat and k % 3 == 0 and t + timedelta(minutes=3) < at(day, b):
                self.n += 1
                self.lines.append(dict(self.base(t + timedelta(minutes=2)), type="user",
                                       message={"role": "user", "content": "ok, go on"}))
            t += timedelta(minutes=step + rng.randint(-2, 2))
        self.lines.append(self.assistant(at(day, b)))

    def subagent(self, day, a, b):
        t = at(day, a)
        while t <= at(day, b):
            self.sub.append(self.assistant(t, model=SONNET))
            t += timedelta(minutes=6)

    def write(self, root):
        d = os.path.join(root, "-work-" + self.project)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, self.id + ".jsonl"), "w") as f:
            f.writelines(json.dumps(l, separators=(",", ":")) + "\n" for l in self.lines)
        if self.sub:
            s = os.path.join(d, self.id, "subagents")
            os.makedirs(s, exist_ok=True)
            with open(os.path.join(s, "agent-a7f3.jsonl"), "w") as f:
                f.writelines(json.dumps(l, separators=(",", ":")) + "\n" for l in self.sub)


sessions, spool = [], []


def S(*a, **k):
    s = Session(*a, **k)
    sessions.append(s)
    return s


def hook(s, day, hour, event, **extra):
    spool.append(dict(kind="hook", tool="claude", event=event, ts=round(at(day, hour).timestamp(), 3),
                      session_id=s.id, cwd=s.cwd, hook_event_name=event, **extra))


# Earlier October: one session a day, hours as in the calendar mockup (0 = no work).
october = [6.5, 5.0, 1.2, 0, 7.4, 8.1, 6.9, 9.2, 4.4, 0.8, 2.1, 8.8, 9.5, 10.2, 7.7, 6.1, 3.0, 0, 7.9, 8.6, 9.9, 8.3,
           5.2, 4.0, 1.5]
for d, h in enumerate(october, start=1):
    if h:
        S(f"oct-{d}", "api-server", f"routine {d}").work(d, 8, 8 + h, "continue with the backlog", step=20)

# Monday 26 – Wednesday 28.
for d, spans in {26: [("api-server", 9, 11.4), ("ml-train", 12, 14.8), ("dotfiles", 16, 17)],
                 27: [("api-server", 8.5, 12.1), ("web-app", 13, 14.8), ("ml-train", 15, 17.5),
                      ("dotfiles", 18, 19.2)],
                 28: [("api-server", 9, 11.9), ("web-app", 12.5, 15.1), ("ml-train", 16, 17.9),
                      ("dotfiles", 19, 20)]}.items():
    for p, a, b in spans:
        S(f"{p}-{d}", p, "week work").work(d, a, b, "next step of the plan")

# Thursday 29: the Day mockup.
tracker = S("tracker", "tracker", "worklogs", model=HAIKU)
tracker.work(29, 8, 9, "prepare the worklog list")
hook(tracker, 29, 9.01, "Stop")
api = S("api", "api-server", "PROJ-12", branch="PROJ-12-check")
api.work(29, 9, 11.5, "check the state machine on dev", chat=True)
hook(api, 29, 11.5, "PermissionRequest")
api.work(29, 12 + 10 / 60, 13 + 40 / 60, "approved, go on")
hook(api, 29, 12 + 10 / 60, "UserPromptSubmit")
hook(api, 29, 16, "PermissionRequest")
hook(api, 29, 16.5, "UserPromptSubmit")
api.work(29, 16.5, 18.5, "fix the third defect and write the summary", chat=True)
api.subagent(29, 9.5, 10.5)
hook(api, 29, 18.51, "SessionEnd")
leader = S("leader", "web-app", "main")
leader.work(29, 9, 13, "settings page and form validation")
hook(leader, 29, 13, "PermissionRequest")
hook(leader, 29, 13 + 20 / 60, "UserPromptSubmit")
leader.work(29, 22.5, 23.99, "record the demo video v1")
worker = S("worker", "web-app", "worker")
worker.work(29, 13 + 20 / 60, 19.5, "dark theme and chart tooltips")
worker.work(29, 21, 23.99, "sign-in with a link by email")
train = S("train", "ml-train", "run 300")
train.work(29, 10, 17.5, "train run 300 on the gpu box and compare quality")
parser = S("parser", "cli-tool", "parser", model=SONNET)
parser.work(29, 14, 15 + 10 / 60, "parse nested config sections", chat=True)
hook(parser, 29, 15 + 10 / 60, "Stop")
hook(parser, 29, 17, "UserPromptSubmit")
hook(parser, 29, 17.02, "SessionEnd")
costs = S("costs", "docs-site", "PROJ-14")
costs.work(29, 18.5, 20, "API reference pages")
costs.work(29, 21, 22.5, "search index and a getting-started guide", chat=True)
hook(costs, 29, 22.51, "SessionEnd")

# Friday 30 up to 11:42: two waiting, three working, two idle.
video = S("video", "web-app", "demo video")
video.work(30, 4 + 10 / 60, 7 + 59 / 60, "re-record the demo video with the settings page", chat=True)
video.work(30, 10 + 50 / 60, 11.5, "upload the demo video")
hook(video, 30, 11.5, "PermissionRequest")
api30 = S("api30", "api-server", "PROJ-12", branch="PROJ-12-check")
api30.work(30, 11, 11 + 38 / 60, "answer about rate limits")
hook(api30, 30, 11 + 38 / 60, "Stop")
mock = S("zagon", "zagon", "mockups")
mock.work(30, 9, 11.69, "menu bar mockups", chat=True)
hook(mock, 30, 11 + 1 / 60, "UserPromptSubmit")
train.work(30, 10.6, 11.69, "second run 300 run")
hook(train, 30, 10 + 37 / 60, "UserPromptSubmit")
parser30 = S("parser30", "cli-tool", "parser", model=SONNET)
parser30.work(30, 11.4, 11.69, "parser review fixes")
hook(parser30, 30, 11.4, "UserPromptSubmit")
worker30 = S("worker30", "web-app", "worker")
worker30.work(30, 8, 9 + 20 / 60, "captions and restart script")
hook(worker30, 30, 9 + 20 / 60, "Stop")
dots = S("dots30", "dotfiles", "shell aliases", model=HAIKU)
dots.work(30, 7, 7.5, "tidy the shell aliases")
hook(dots, 30, 7.5, "Stop")

# Status line readings every 15 minutes while a 5-hour window is open, plus 13:40 (limit hit) and "now".
# The week window resets on Monday Nov 2 09:00.
windows = [(at(29, 4 + 20 / 60), at(29, 9 + 20 / 60)), (at(29, 9 + 20 / 60), at(29, 14 + 20 / 60)),
           (at(29, 14 + 20 / 60), at(29, 19 + 20 / 60)), (at(29, 19 + 20 / 60), at(30, 20 / 60)),
           (at(30, 4 + 10 / 60), at(30, 9 + 10 / 60)), (at(30, 9 + 20 / 60), at(30, 14 + 20 / 60))]
week_reset = at(33, 9).timestamp()
times = sorted({at(29, 7) + timedelta(minutes=15 * k) for k in range(200)} | {at(29, 13 + 40 / 60), NOW})
for t in (t for t in times if t <= NOW):
    win = next(((a, b) for a, b in windows if a <= t < b), None)
    if win is None:
        continue
    h = (t - at(29, 0)).total_seconds() / 3600
    into = (t - win[0]).total_seconds() / 3600
    if 13 + 40 / 60 <= h < 14 + 20 / 60:
        five = 100.0
    elif h >= 24 + 9 + 20 / 60:
        five = round(19 + 18 * into, 1)  # 62 % at 11:42, +18 %/h
    else:
        five = round(min(99.0, 21 * into), 1)
    week = round(24 + 13 * max(0.0, min(1.0, (h - 8) / 15)) + 4 * max(0.0, min(1.0, (h - 28) / 7.7)), 1)
    spool.append(dict(kind="limits", tool="claude", ts=round(t.timestamp(), 3), five_hour_pct=five,
                      five_hour_resets_at=round(win[1].timestamp()), seven_day_pct=week,
                      seven_day_resets_at=round(week_reset)))

for name in ("projects", "spool"):
    shutil.rmtree(os.path.join(HERE, name), ignore_errors=True)
for s in sessions:
    s.write(os.path.join(HERE, "projects"))
os.makedirs(os.path.join(HERE, "spool"))
spool.sort(key=lambda x: x["ts"])
for line in spool:
    day = datetime.fromtimestamp(line["ts"], UTC).strftime("%Y-%m-%d")
    with open(os.path.join(HERE, "spool", day + ".ndjson"), "a") as f:
        f.write(json.dumps(line, separators=(",", ":")) + "\n")
print(len(sessions), "sessions,", sum(len(s.lines) + len(s.sub) for s in sessions), "records,", len(spool), "spool lines")
