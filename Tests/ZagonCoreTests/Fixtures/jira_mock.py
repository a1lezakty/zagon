"""Local stand-in for the Jira Cloud REST endpoints Zagon uses. Test-only: writes go to memory.

usage: jira_mock.py <state.json> <port-file> <email> <token>
state.json: {"me": "acc-me", "issues": {"KEY": {"summary", "status", "category", "assignee", "worklogs": [...]}}}
Faults (optional): "lose_post_replies": N — the next N worklog POSTs are stored but get no answer (connection closed);
"post_status": [500, 400] — the next POSTs get these codes and store nothing; "bad_post_bodies": N — the next N POSTs
are stored but answered 201 with a body that is not JSON; "search_lag": true — worklogs added by POST do not show in
the worklogAuthor search (its index lags).
"""
import base64, json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from datetime import datetime

state = json.load(open(sys.argv[1]))
AUTH = "Basic " + base64.b64encode(f"{sys.argv[3]}:{sys.argv[4]}".encode()).decode()
lock = threading.Lock()
next_id = [1000]


def started_ms(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%f%z").timestamp() * 1000


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def route(self, method):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        parts = u.path.strip("/").split("/")
        if u.path == "/_state":
            with lock:
                return self.send(200, state)
        if self.headers.get("Authorization") != AUTH:
            return self.send(401, {"errorMessages": ["unauthorized"]})
        if self.headers.get("Accept") != "application/json":
            return self.send(406, {"errorMessages": ["accept"]})
        me = state["me"]
        issues = state["issues"]
        if method == "GET" and u.path == "/rest/api/2/myself":
            return self.send(200, {"accountId": me})
        if method == "POST" and u.path == "/rest/api/3/search/jql":
            b = self.body()
            jql = b.get("jql", "")
            if "worklogAuthor" in jql:
                keys = [k for k, i in issues.items() if any(w["author"] == me and not w.get("_new") for w in i.get("worklogs", []))]
            elif jql.startswith("key in ("):
                keys = [k.strip() for k in jql[len("key in ("):jql.index(")")].split(",") if k.strip() in issues]
            else:
                keys = [k for k, i in issues.items() if i.get("assignee") == me and i.get("category") != "done"]
            keys.sort()
            at = int(b.get("nextPageToken") or 0)
            page = keys[at:at + 1]  # one per page: exercises nextPageToken
            last = at + 1 >= len(keys)
            out = {"issues": [{"key": k, "fields": {"summary": issues[k]["summary"],
                                                    "status": {"name": issues[k]["status"],
                                                               "statusCategory": {"key": issues[k]["category"]}}}}
                              for k in page], "isLast": last}
            if not last:
                out["nextPageToken"] = str(at + 1)
            return self.send(200, out)
        if len(parts) >= 5 and parts[:4] == ["rest", "api", "2", "issue"]:
            key = parts[4]
            if key not in issues:
                return self.send(404, {"errorMessages": ["Issue does not exist"]})
            i = issues[key]
            if len(parts) == 5 and method == "GET":
                return self.send(200, {"key": key, "fields": {"summary": i["summary"], "status": {
                    "name": i["status"], "statusCategory": {"key": i["category"]}}}})
            if len(parts) == 6 and parts[5] == "worklog" and method == "GET":
                after = float(q.get("startedAfter", 0))
                ws = [w for w in i.get("worklogs", []) if started_ms(w["started"]) >= after]
                at = int(q.get("startAt", 0))
                page = ws[at:at + 2]  # two per page: exercises paging
                return self.send(200, {"startAt": at, "maxResults": 2, "total": len(ws), "worklogs": [
                    {"id": w["id"], "author": {"accountId": w["author"]}, "started": w["started"],
                     "timeSpentSeconds": w["seconds"], "comment": w.get("comment", "")} for w in page]})
            if len(parts) == 6 and parts[5] == "worklog" and method == "POST":
                if self.headers.get("Content-Type") != "application/json":
                    return self.send(415, {"errorMessages": ["content type"]})
                b = self.body()
                with lock:
                    if state.get("post_status"):
                        return self.send(state["post_status"].pop(0), {"errorMessages": ["fault"]})
                    next_id[0] += 1
                    w = {"id": str(next_id[0]), "author": me, "started": b["started"],
                         "seconds": b["timeSpentSeconds"], "comment": b.get("comment", "")}
                    if state.get("search_lag"):
                        w["_new"] = True
                    i.setdefault("worklogs", []).append(w)
                    if state.get("bad_post_bodies", 0) > 0:
                        state["bad_post_bodies"] -= 1
                        b = b"<html>proxy</html>"
                        self.send_response(201)
                        self.send_header("Content-Length", str(len(b)))
                        self.end_headers()
                        self.wfile.write(b)
                        return
                    if state.get("lose_post_replies", 0) > 0:
                        state["lose_post_replies"] -= 1
                        self.close_connection = True
                        return
                return self.send(201, {"id": w["id"], "started": w["started"], "timeSpentSeconds": w["seconds"]})
        return self.send(404, {"errorMessages": ["no route " + u.path]})

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[2] + ".tmp", "w") as f:
    f.write(str(srv.server_address[1]))
import os
os.rename(sys.argv[2] + ".tmp", sys.argv[2])
srv.serve_forever()
