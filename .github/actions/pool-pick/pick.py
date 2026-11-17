#!/usr/bin/env python3
"""pool-pick: choose where the jobs of a workflow run go, a self-hosted pool
host or GitHub-hosted. Run by action.yml on a GitHub-hosted runner; every
input comes from the environment (see README.md for the inputs).

Rules, in order:

1. An untrusted run is GitHub-hosted: a pull_request* run whose head repo is
   not this repository, an actor or triggering actor dependabot[bot], the
   events pull_request_target and workflow_run, a public repository (or one
   whose visibility is unknown).
2. Mode github: GitHub-hosted, no lookup. An unknown mode fails the step.
3. A status that cannot be read sends the run to GitHub-hosted, fixed modes
   included: no token, a failed request, JSON it cannot read, a `v` it does
   not know.
4. A runner of this repository (or of its runner group, when
   runner-group-id is given) with a pool-* label and a label containing
   "prod" sends the run to GitHub-hosted, and so does a runner list it
   cannot read in full.
5. Candidates: a fresh status (updated at most 120 seconds ago by the
   GitHub clock), state accepting, this repository in `repos`, a slot for
   every class the workflow uses.
6. auto: the candidate with the most free slots of the main class
   (heavy when used), a tie goes to `prefer`. When every candidate is full
   the run queues on the one with the smallest backlog, unless max-backlog
   is set and reached. No candidate: GitHub-hosted, with each host's reason.
7. pool, or a host id: fixed. A stale or not accepting host is still
   picked (the jobs wait) as long as its status is readable, it lists this
   repository and it has the slots; pool picks among the accepting hosts
   first, else `prefer`.

The token reaches curl on stdin only (`--header @-`); neither the token, the
responses nor their headers are printed. It is removed from the environment
of every process this script starts.
"""
import datetime
import email.utils
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

STALE_SECONDS = 120
CLASSES = ("heavy", "light")
HOST_RE = re.compile(r"^(pc|srv([2-9]|[1-9][0-9]+)?)$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
STATES = ("accepting", "paused", "held", "draining")
TRUSTED_VISIBILITY = ("private", "internal")
PER_PAGE = 100
MAX_PAGES = 5


class InputError(Exception):
    pass


class Unreadable(Exception):
    pass


def env(name, default=""):
    return os.environ.get(name, default).strip()


def one_line(text, limit=300):
    """Printable, single line, bounded: safe in outputs, annotations and logs."""
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text)).strip()
    return text if len(text) <= limit else text[: limit - 3] + "..."


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


# --- inputs --------------------------------------------------------------

def split_list(text):
    return [item.strip() for item in text.split(",") if item.strip()]


def runs_on_value(text, name):
    """A label (written as a JSON string) or a JSON array of labels."""
    if not text:
        raise InputError(f"{name} must not be empty")
    if text.startswith("["):
        try:
            labels = json.loads(text)
        except ValueError:
            raise InputError(f"{name} is not a JSON array of labels") from None
        if not labels or not all(isinstance(l, str) and l and one_line(l) == l for l in labels):
            raise InputError(f"{name} is not a JSON array of labels")
        return json.dumps(labels, separators=(",", ":"))
    if one_line(text) != text:
        raise InputError(f"{name} has control characters")
    return json.dumps(text)


def read_inputs():
    raw_mode = env("POOL_MODE") or "auto"
    hosts = split_list(env("POOL_HOSTS") or "pc,srv")
    if not hosts or len(set(hosts)) != len(hosts) or not all(HOST_RE.match(h) for h in hosts):
        raise InputError("hosts must be a comma-separated list of distinct host ids (pc, srv, srv2, ...)")
    if raw_mode not in ("auto", "pool", "github") and raw_mode not in hosts:
        raise InputError(f"mode must be unset, auto, pool, github or one of {', '.join(hosts)} "
                         "(delete the variable for auto)")
    classes = split_list(env("POOL_CLASSES") or "heavy,light")
    if not classes or len(set(classes)) != len(classes) or not set(classes) <= set(CLASSES):
        raise InputError("classes must be heavy, light or heavy,light")
    prefer = env("POOL_PREFER") or ("srv" if "srv" in hosts else hosts[0])
    if prefer not in hosts:
        raise InputError(f"prefer must be one of {', '.join(hosts)}")
    max_backlog = env("POOL_MAX_BACKLOG")
    if max_backlog and not re.fullmatch(r"[0-9]{1,6}", max_backlog):
        raise InputError("max-backlog must be empty or a non-negative integer")
    group = env("POOL_RUNNER_GROUP_ID")
    if group and not re.fullmatch(r"[1-9][0-9]{0,12}", group):
        raise InputError("runner-group-id must be empty or a positive integer")
    status_repo = env("POOL_STATUS_REPO")
    if raw_mode != "github" and not REPO_RE.match(status_repo):
        raise InputError("status-repo must be owner/name")
    repository = env("GITHUB_REPOSITORY")
    if not REPO_RE.match(repository):
        raise InputError("GITHUB_REPOSITORY is not owner/name")
    return {
        "mode": raw_mode,
        "hosts": hosts,
        "classes": classes,
        "main": "heavy" if "heavy" in classes else classes[0],
        "prefer": prefer,
        "max_backlog": int(max_backlog) if max_backlog else None,
        "group": group,
        "status_repo": status_repo,
        "repository": repository,
        "github": {
            "heavy": runs_on_value(env("POOL_GITHUB_HEAVY") or "ubuntu-latest", "github-heavy"),
            "light": runs_on_value(env("POOL_GITHUB_LIGHT") or "ubuntu-latest", "github-light"),
        },
    }


# --- rule 1 --------------------------------------------------------------

def untrusted_reason(cfg):
    event = env("GITHUB_EVENT_NAME")
    if event in ("pull_request_target", "workflow_run"):
        return f"untrusted run: event {event}"
    if event.startswith("pull_request"):
        head = env("POOL_PR_HEAD_REPO")
        if head.lower() != cfg["repository"].lower():
            return f"untrusted run: the pull request head repo ({one_line(head, 100) or 'unknown'}) is another repository"
    for name in ("GITHUB_ACTOR", "GITHUB_TRIGGERING_ACTOR"):
        if env(name) == "dependabot[bot]":
            return "untrusted run: a Dependabot run"
    visibility = env("POOL_REPO_VISIBILITY").lower()
    if visibility not in TRUSTED_VISIBILITY:
        if visibility == "public":
            return "untrusted run: the repository is public"
        return "untrusted run: the repository visibility is unknown (treated as public)"
    return None


# --- GitHub reads ----------------------------------------------------------

class Client:
    def __init__(self, token):
        self.token = token
        self.base = (env("GITHUB_API_URL") or "https://api.github.com").rstrip("/")
        self.tmp = tempfile.mkdtemp(prefix="pool-pick.", dir=env("RUNNER_TEMP") or None)
        self.env = {k: v for k, v in os.environ.items() if k != "POOL_PICK_TOKEN"}

    def get(self, path):
        """GET path -> (parsed JSON, GitHub's Date or None). Raises Unreadable."""
        body = os.path.join(self.tmp, "body")
        head = os.path.join(self.tmp, "head")
        for name in (body, head):
            if os.path.exists(name):
                os.remove(name)
        argv = ["curl", "--silent", "--header", "@-",
                "--header", "Accept: application/vnd.github+json",
                "--header", "X-GitHub-Api-Version: 2022-11-28",
                "--connect-timeout", "5", "--max-time", "20",
                "--dump-header", head, "--output", body, "--write-out", "%{http_code}",
                self.base + path]
        try:
            proc = subprocess.run(argv, input=f"Authorization: Bearer {self.token}\n",
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  text=True, env=self.env, timeout=40)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise Unreadable(f"request failed ({type(exc).__name__})") from None
        if proc.returncode != 0:
            raise Unreadable(f"request failed (curl exit {proc.returncode})")
        status = proc.stdout.strip()
        if not re.fullmatch(r"2[0-9][0-9]", status):
            raise Unreadable(f"request failed (HTTP {one_line(status, 10) or 'no status'})")
        try:
            with open(body, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError, RecursionError):
            raise Unreadable("response is not json") from None
        return data, response_date(head)


def response_date(path):
    try:
        with open(path, encoding="latin-1") as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        name, _, value = line.partition(":")
        if name.strip().lower() == "date":
            try:
                when = email.utils.parsedate_to_datetime(value.strip())
            except (TypeError, ValueError):
                return None
            return when if when.tzinfo else when.replace(tzinfo=datetime.timezone.utc)
    return None


def parse_time(text):
    if not isinstance(text, str):
        raise ValueError(text)
    when = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    if when.tzinfo is None:
        raise ValueError(text)
    return when


# --- rule 3: status --------------------------------------------------------

def check_status(doc, host):
    """The fields pool-pick uses, per status-v1; unknown fields are ignored."""
    if not isinstance(doc, dict):
        raise Unreadable(f"{host} status is not a JSON object")
    if not is_int(doc.get("v")) or doc["v"] != 1:
        raise Unreadable(f"{host} status has unknown version {one_line(json.dumps(doc.get('v')), 20)}")
    if doc.get("host") != host:
        raise Unreadable(f"{host} status names another host")
    if not is_int(doc.get("seq")) or doc["seq"] < 0:
        raise Unreadable(f"{host} status field seq is invalid")
    if doc.get("state") not in STATES:
        raise Unreadable(f"{host} status field state is invalid")
    repos = doc.get("repos")
    if not isinstance(repos, list) or not all(isinstance(r, str) for r in repos):
        raise Unreadable(f"{host} status field repos is invalid")
    classes = doc.get("classes")
    if not isinstance(classes, dict):
        raise Unreadable(f"{host} status field classes is invalid")
    for name in CLASSES:
        entry = classes.get(name)
        if not isinstance(entry, dict) or not all(
                is_int(entry.get(k)) and entry[k] >= 0 for k in ("slots", "busy", "queued")):
            raise Unreadable(f"{host} status field classes.{name} is invalid")
    if "reason" in doc and not isinstance(doc["reason"], str):
        raise Unreadable(f"{host} status field reason is invalid")


def read_host(client, cfg, host):
    path = f"/repos/{cfg['status_repo']}/actions/variables/POOL_STATUS_{host.upper()}"
    try:
        var, date = client.get(path)
    except Unreadable as exc:
        raise Unreadable(f"{host} {exc}") from None
    if not isinstance(var, dict) or not isinstance(var.get("value"), str):
        raise Unreadable(f"{host} variable has no value")
    try:
        updated = parse_time(var.get("updated_at"))
    except ValueError:
        raise Unreadable(f"{host} variable has no updated_at") from None
    try:
        doc = json.loads(var["value"])
    except (ValueError, RecursionError):
        raise Unreadable(f"{host} status is not json") from None
    check_status(doc, host)
    now = date or datetime.datetime.now(datetime.timezone.utc)
    age = max(0, int((now - updated).total_seconds()))
    name = cfg["repository"].split("/", 1)[1].lower()
    free = {c: doc["classes"][c]["slots"] - doc["classes"][c]["busy"] - doc["classes"][c]["queued"]
            for c in CLASSES}
    return {
        "host": host,
        "state": doc["state"],
        "age": age,
        "fresh": age <= STALE_SECONDS,
        "listed": name in (r.lower() for r in doc["repos"]),
        "slots": {c: doc["classes"][c]["slots"] for c in CLASSES},
        "free": free,
        "note": one_line(doc.get("reason", ""), 200),
    }


# --- rule 4: production labels ---------------------------------------------

def read_runners(client, path, what):
    runners, total, page = [], None, 1
    while True:
        try:
            data, _ = client.get(f"{path}?per_page={PER_PAGE}&page={page}")
        except Unreadable as exc:
            raise Unreadable(f"{what} unreadable: {exc}") from None
        if not isinstance(data, dict) or not is_int(data.get("total_count")) \
                or not isinstance(data.get("runners"), list):
            raise Unreadable(f"{what} unreadable: unexpected response")
        total = data["total_count"]
        runners += data["runners"]
        if len(data["runners"]) < PER_PAGE or len(runners) >= total or page >= MAX_PAGES:
            break
        page += 1
    if len(runners) != total:
        raise Unreadable(f"{what} unreadable: incomplete ({len(runners)} of {total} runners)")
    labelled = []
    for runner in runners:
        labels = runner.get("labels") if isinstance(runner, dict) else None
        if not isinstance(labels, list) or not all(
                isinstance(l, dict) and isinstance(l.get("name"), str) for l in labels):
            raise Unreadable(f"{what} unreadable: a runner without labels")
        labelled.append({l["name"].lower() for l in labels})
    return labelled


def production_reason(client, cfg):
    lists = [(f"/repos/{cfg['repository']}/actions/runners", "the repository runner list")]
    if cfg["group"]:
        org = cfg["repository"].split("/", 1)[0]
        lists.append((f"/orgs/{org}/actions/runner-groups/{cfg['group']}/runners",
                      f"the runner group {cfg['group']} list"))
    for path, what in lists:
        hits = sum(1 for labels in read_runners(client, path, what)
                   if any(l.startswith("pool-") for l in labels) and any("prod" in l for l in labels))
        if hits:
            return f"{hits} runner(s) in {what} carry a pool label and a prod label"
    return None


# --- rules 5-7 -------------------------------------------------------------

def host_problems(h, cfg):
    problems = []
    if not h["listed"]:
        problems.append("repo not in repos")
    for c in cfg["classes"]:
        if h["slots"][c] <= 0:
            problems.append(f"no {c} slot")
    if not h["fresh"]:
        problems.append(f"offline (status {h['age']}s old)")
    if h["state"] != "accepting":
        problems.append(h["state"])
    return problems


def eligible(h, cfg):
    """Can ever run this repository's jobs: listed, with every class."""
    return h["listed"] and all(h["slots"][c] > 0 for c in cfg["classes"])


def describe(hosts, cfg):
    return "; ".join(f"{h['host']}: {', '.join(host_problems(h, cfg)) or 'ok'}" for h in hosts)


def order(hosts, key, cfg):
    """Best first by key (smaller is better); a tie goes to prefer, then to the hosts order."""
    rank = {name: i for i, name in enumerate(cfg["hosts"])}
    return sorted(hosts, key=lambda h: (key(h), h["host"] != cfg["prefer"], rank[h["host"]]))


def choose(cands, cfg, honour_backlog):
    """-> (host, reason) or (None, reason) for a backlog fallback."""
    main = cfg["main"]
    roomy = [h for h in cands if h["free"][main] > 0]
    if roomy:
        best = order(roomy, lambda h: -h["free"][main], cfg)[0]
        return best, f"{best['host']} has {best['free'][main]} free {main} slot(s)"
    best = order(cands, lambda h: -h["free"][main], cfg)[0]
    waiting = -best["free"][main] + 1   # jobs waiting for a slot there, this run included
    if honour_backlog and cfg["max_backlog"] is not None and waiting > cfg["max_backlog"]:
        return None, (f"pool full: {waiting} job(s) would wait on {best['host']}, "
                      f"over max-backlog {cfg['max_backlog']}")
    return best, f"pool full, queued on {best['host']} ({waiting} job(s) waiting, this run included)"


def decide(cfg, hosts):
    """-> (runner, reason, warn) from readable host states."""
    mode = cfg["mode"]
    if mode in cfg["hosts"]:
        h = hosts[0]
        if not eligible(h, cfg):
            return "github", f"pinned host {describe([h], cfg)}", True
        problems = host_problems(h, cfg)
        if problems:
            return h["host"], f"pinned to {h['host']}, {', '.join(problems)}: the jobs wait for it", True
        return h["host"], f"pinned to {h['host']} ({h['free'][cfg['main']]} free {cfg['main']} slot(s))", False
    cands = [h for h in hosts if eligible(h, cfg) and h["fresh"] and h["state"] == "accepting"]
    if cands:
        best, reason = choose(cands, cfg, honour_backlog=(mode == "auto"))
        if best is None:
            return "github", reason, True
        return best["host"], reason, False
    if mode == "auto":
        return "github", f"no pool host can take the run: {describe(hosts, cfg)}", True
    # mode pool, nothing accepting: prefer when it can run the jobs, else the first that can.
    usable = [h for h in hosts if eligible(h, cfg)]
    if not usable:
        return "github", f"no pool host serves the run: {describe(hosts, cfg)}", True
    best = order(usable, lambda h: 0, cfg)[0]
    return best["host"], (f"no pool host is accepting ({describe(hosts, cfg)}): "
                          f"waits on {best['host']}"), True


def pick(cfg):
    """-> (runner, reason, warn, details)."""
    why = untrusted_reason(cfg)
    if why:
        return "github", why, True, []
    if cfg["mode"] == "github":
        return "github", "mode github, no lookup", False, []
    token = os.environ.get("POOL_PICK_TOKEN", "")
    if not token.strip():
        return "github", "status unreadable: the token is empty (the secret is not set or not shared with this run)", True, []
    if re.search(r"[\r\n]", token):
        return "github", "status unreadable: the token has a line break", True, []
    client = Client(token.strip())
    try:
        return read_and_decide(client, cfg)
    finally:
        shutil.rmtree(client.tmp, ignore_errors=True)


def read_and_decide(client, cfg):
    names = [cfg["mode"]] if cfg["mode"] in cfg["hosts"] else cfg["hosts"]
    hosts = []
    for name in names:
        try:
            hosts.append(read_host(client, cfg, name))
        except Unreadable as exc:
            return "github", f"status unreadable: {exc}", True, hosts
    try:
        prod = production_reason(client, cfg)
    except Unreadable as exc:
        return "github", str(exc), True, hosts
    if prod:
        return "github", prod, True, hosts
    runner, reason, warn = decide(cfg, hosts)
    return runner, reason, warn, hosts


# --- output ----------------------------------------------------------------

def escape_data(text):
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def append(name, text):
    path = env(name)
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text)


def detail_line(h):
    classes = " ".join(f"{c}={h['slots'][c]} slots/{h['free'][c]} free" for c in CLASSES)
    note = f" reason={h['note']}" if h["note"] else ""
    return (f"pool-pick detail: {h['host']} state={h['state']} age={h['age']}s "
            f"listed={'yes' if h['listed'] else 'no'} {classes}{note}")


def main():
    try:
        cfg = read_inputs()
    except InputError as exc:
        print(f"::error title=pool-pick::{escape_data(one_line(exc))}")
        return 1
    runner, reason, warn, hosts = pick(cfg)
    reason = one_line(reason, 900)
    if runner == "github":
        heavy, light = cfg["github"]["heavy"], cfg["github"]["light"]
    else:
        heavy, light = json.dumps(f"pool-{runner}-heavy"), json.dumps(f"pool-{runner}-light")
    line = f"pool-pick: {cfg['mode']} picks {runner}: {reason}"
    for h in hosts:
        print(detail_line(h))
    print(f"::{'warning' if warn else 'notice'} title=pool-pick::{escape_data(line)}")
    append("GITHUB_OUTPUT", f"runner={runner}\nruns_on_heavy={heavy}\nruns_on_light={light}\n"
                            f"reason={reason}\n")
    summary = [line] + [detail_line(h) for h in hosts]
    append("GITHUB_STEP_SUMMARY", "".join(f"    {s}\n" for s in summary) + "\n")
    print(f"runner={runner}\nruns_on_heavy={heavy}\nruns_on_light={light}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
