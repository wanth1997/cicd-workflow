#!/usr/bin/env bash
# pool-pick (pick.py): every rule of runner-pool §7.2 and the scenarios of the
# pick-runner test it replaces, against a stand-in curl that serves fixture
# files. The status fixtures are copies of the format's own examples (see
# README.md for their source). No network: the stand-in curl is first on PATH.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$here/fixtures"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "pool-pick test: $*" >&2; exit 1; }
cases=0

mkdir -p "$tmp/bin" "$tmp/runner"
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Stand-in curl: records its arguments and stdin, serves $FAKE_DIR/<route>.body
# with the HTTP status in $FAKE_DIR/<route>.status (default 200, "fail" exits 7);
# page N > 1 of a list is the route <route>.pN. A missing body is a 404.
printf '%s\n' "$@" >> "$FAKE_DIR/args"
cat >> "$FAKE_DIR/stdin"
out="" head="" url=""
while (($#)); do
  case "$1" in
    --output) out="$2"; shift ;;
    --dump-header) head="$2"; shift ;;
    *) url="$1" ;;
  esac
  shift
done
printf '%s\n' "$url" >> "$FAKE_DIR/urls"
case "$url" in
  */actions/variables/POOL_STATUS_*) route="var-$(printf '%s' "${url##*POOL_STATUS_}" | tr '[:upper:]' '[:lower:]')" ;;
  */actions/runner-groups/*/runners\?*) route=group-runners ;;
  */actions/runners\?*) route=repo-runners ;;
  *) route=unknown ;;
esac
page=1
if [[ "$url" == *'&page='* ]]; then page="${url##*&page=}"; fi
if [[ "$page" != 1 ]]; then route="$route.p$page"; fi
status=200
if [[ -f "$FAKE_DIR/$route.status" ]]; then status="$(cat "$FAKE_DIR/$route.status")"; fi
if [[ "$status" == fail ]]; then exit 7; fi
if [[ -f "$FAKE_DIR/$route.body" ]]; then cp "$FAKE_DIR/$route.body" "$out"; else
  printf '{"message":"Not Found"}' > "$out"; status=404; fi
printf 'HTTP/2 %s\r\ndate: %s\r\n\r\n' "$status" "$FAKE_DATE" > "$head"
printf '%s' "$status"
EOF
chmod +x "$tmp/bin/curl"
fake_date="Wed, 18 Nov 2026 03:00:00 GMT"

# var HOST FIXTURE AGE_SECONDS [PATH=JSON ...]: the variable response for
# POOL_STATUS_<HOST>, the fixture's value patched (classes.heavy.busy=2), its
# updated_at AGE_SECONDS before the stand-in's Date header.
var() {
  local host="$1" fixture="$2" age="$3"
  shift 3
  python3 -I - "$fixtures/$fixture" "$age" "$tmp/var-$host.body" "$@" <<'PY'
import datetime, json, sys
src, age, dst, patches = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:]
text = open(src, encoding="utf-8").read().strip()
if patches:
    doc = json.loads(text)
    for patch in patches:
        path, _, value = patch.partition("=")
        node, keys = doc, path.split(".")
        for key in keys[:-1]:
            node = node[key]
        if value == "DELETE":
            del node[keys[-1]]
        else:
            node[keys[-1]] = json.loads(value)
    text = json.dumps(doc)
now = datetime.datetime(2026, 11, 18, 3, 0, 0, tzinfo=datetime.timezone.utc)
updated = (now - datetime.timedelta(seconds=age)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"name": "POOL_STATUS_X", "value": text, "created_at": "2026-11-01T00:00:00Z",
           "updated_at": updated}, open(dst, "w", encoding="utf-8"))
PY
  rm -f "$tmp/var-$host.status"
}
# runners ROUTE TOTAL ["label label" ...]: a runner list (repo-runners or
# group-runners) with one runner per argument.
runners() {
  local route="$1" total="$2"
  shift 2
  python3 -I - "$tmp/$route.body" "$total" "$@" <<'PY'
import json, sys
dst, total, runners = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
json.dump({"total_count": total, "runners": [
    {"id": i, "name": f"runner-{i}", "status": "online",
     "labels": [{"id": j, "name": l, "type": "custom"} for j, l in enumerate(r.split())]}
    for i, r in enumerate(runners)]}, open(dst, "w", encoding="utf-8"))
PY
  rm -f "$tmp/$route.status"
}
http() { printf '%s' "$2" > "$tmp/$1.status"; } # ROUTE CODE|fail

# The default world: win accepting with no free heavy slot, ubuntu accepting with
# two free heavy slots, both list example-app, both fresh; no production runner.
reset() {
  var win status-valid-win-accepting.json 10
  var ubuntu status-valid-ubuntu-accepting.json 10 'repos=["pool-canary","example-app"]'
  runners repo-runners 2 "self-hosted Linux X64 pool-win-heavy" "self-hosted Linux X64 pool-ubuntu-light"
  runners group-runners 1 "self-hosted pool-ubuntu-heavy"
  rm -f "$tmp/unknown.body"
}

# pick [--no-group] [VAR=VALUE ...]: runs pick.py with runner-group-id 42
# (--no-group: without the variable); sets out, code, got, heavy, light,
# reason, calls.
pick() {
  local group=(POOL_RUNNER_GROUP_ID=42)
  if [[ "${1:-}" == --no-group ]]; then group=(); shift; fi
  code=0
  : > "$tmp/out"
  : > "$tmp/summary"
  rm -f "$tmp/args" "$tmp/stdin" "$tmp/urls"
  out="$(cd "$tmp" && env -i PATH="$tmp/bin:$PATH" HOME="$HOME" FAKE_DIR="$tmp" FAKE_DATE="$fake_date" \
    RUNNER_TEMP="$tmp/runner" GITHUB_REPOSITORY=example-org/example-app GITHUB_EVENT_NAME=push \
    GITHUB_ACTOR=someone GITHUB_TRIGGERING_ACTOR=someone GITHUB_OUTPUT="$tmp/out" \
    GITHUB_STEP_SUMMARY="$tmp/summary" POOL_PICK_TOKEN=sekrit-token-value \
    POOL_STATUS_REPO=example-org/pool-status POOL_REPO_VISIBILITY=private ${group[@]+"${group[@]}"} "$@" \
    python3 -I "$here/pick.py" 2>&1)" || code=$?
  got="$(sed -n 's/^runner=//p' "$tmp/out")"
  heavy="$(sed -n 's/^runs_on_heavy=//p' "$tmp/out")"
  light="$(sed -n 's/^runs_on_light=//p' "$tmp/out")"
  reason="$(sed -n 's/^reason=//p' "$tmp/out")"
  calls=0
  if [[ -f "$tmp/urls" ]]; then calls="$(wc -l < "$tmp/urls" | tr -d ' ')"; fi
}
# want CASE RUNNER: the step passed and picked RUNNER.
want() {
  cases=$((cases + 1))
  [[ "$code" == 0 && "$got" == "$2" ]] || fail "$1: want $2, got '${got}' (exit $code)"$'\n'"$out"
  [[ -z "$(ls -A "$tmp/runner")" ]] || fail "$1: pick.py left files in RUNNER_TEMP"
}
# says CASE KIND TEXT: a KIND (notice|warning) annotation holds the whole pick
# line and the line contains TEXT.
says() {
  local note
  note="$(grep "^::$2 title=pool-pick::pool-pick: " <<<"$out" || true)"
  [[ -n "$note" ]] || fail "$1: no $2 annotation with the pick line"$'\n'"$out"
  grep -qF -- "$3" <<<"$note" || fail "$1: the $2 does not say '$3'"$'\n'"$out"
}
# no_lookup CASE: nothing was asked of GitHub.
no_lookup() { [[ "$calls" == 0 ]] || fail "$1: $calls request(s) made"$'\n'"$(cat "$tmp/urls")"; }

### Outputs, the pick line and the token (pick-runner: "one runner of each kind online").
reset
pick
want "auto, ubuntu has room" ubuntu
[[ "$heavy" == '"pool-ubuntu-heavy"' && "$light" == '"pool-ubuntu-light"' ]] || fail "runs_on for ubuntu: $(cat "$tmp/out")"
[[ "$reason" == "ubuntu has 2 free heavy slot(s)" ]] || fail "reason output: '$reason'"
says "auto, ubuntu has room" notice "pool-pick: auto picks ubuntu: ubuntu has 2 free heavy slot(s)"
grep -qxF "    pool-pick: auto picks ubuntu: ubuntu has 2 free heavy slot(s)" "$tmp/summary" || fail "job summary: $(cat "$tmp/summary")"
# S6's pool_report.py reads the line from the annotation with this pattern.
python3 -I - "$(grep '^::notice title=pool-pick::' <<<"$out" | sed 's/^::notice title=pool-pick:://')" <<'PY' || fail "the annotation does not match pool_report's PICK_RE"
import re, sys
m = re.search(r"pool-pick: (?P<mode>[A-Za-z0-9_-]+) picks (?P<runner>[a-z0-9]+): (?P<reason>.*)", sys.argv[1])
assert m and m["mode"] == "auto" and m["runner"] == "ubuntu", sys.argv[1]
PY
grep -q sekrit "$tmp/args" && fail "the token reached curl's arguments"
grep -qx 'Authorization: Bearer sekrit-token-value' "$tmp/stdin" || fail "the token did not reach curl's stdin"
grep -q sekrit <<<"$out" && fail "the token was printed"
grep -q sekrit "$tmp/out" "$tmp/summary" && fail "the token reached the outputs or the summary"
[[ "$(sort -u "$tmp/stdin" | wc -l | tr -d ' ')" == 1 ]] || fail "curl's stdin holds more than the header"
grep -A1 -xF -- '--header' "$tmp/args" | grep -qxF -- '@-' || fail "curl does not read a header from stdin (--header @-)"
diff <(cat "$tmp/urls") <(printf '%s\n' \
  https://api.github.com/repos/example-org/pool-status/actions/variables/POOL_STATUS_WIN \
  https://api.github.com/repos/example-org/pool-status/actions/variables/POOL_STATUS_UBUNTU \
  'https://api.github.com/repos/example-org/example-app/actions/runners?per_page=100&page=1' \
  'https://api.github.com/orgs/example-org/actions/runner-groups/42/runners?per_page=100&page=1') ||
  fail "wrong requests"
pick GITHUB_API_URL=https://ghe.example.invalid/api/v3
want "GITHUB_API_URL is used" ubuntu
grep -q '^https://ghe.example.invalid/api/v3/repos/' "$tmp/urls" || fail "GITHUB_API_URL ignored: $(cat "$tmp/urls")"
pick POOL_MODE=auto
want "auto set explicitly" ubuntu
says "auto set explicitly" notice "pool-pick: auto picks ubuntu:"
pick POOL_MODE=auto POOL_GITHUB_HEAVY='["self-hosted-not-used"]'
want "github-heavy does not matter for a pool pick" ubuntu

### Rule 1: untrusted runs, whatever the mode, with no lookup.
for event in pull_request_target workflow_run; do
  pick GITHUB_EVENT_NAME=$event POOL_MODE=ubuntu
  want "event $event, pinned ubuntu" github
  says "event $event" warning "untrusted run: event $event"
  no_lookup "event $event"
done
pick GITHUB_EVENT_NAME=pull_request POOL_PR_HEAD_REPO=someone/example-app
want "a pull request from a fork" github
says "a pull request from a fork" warning "untrusted run: the pull request head repo (someone/example-app) is another repository"
[[ "$heavy" == '"ubuntu-latest"' && "$light" == '"ubuntu-latest"' ]] || fail "runs_on for GitHub: $(cat "$tmp/out")"
no_lookup "a pull request from a fork"
pick GITHUB_EVENT_NAME=pull_request POOL_PR_HEAD_REPO=someone/example-app POOL_MODE=win
want "a pull request from a fork, pinned win" github
pick GITHUB_EVENT_NAME=pull_request_review POOL_PR_HEAD_REPO=someone/example-app
want "a pull_request_review from a fork" github
pick GITHUB_EVENT_NAME=pull_request
want "a pull request without its head repository" github
says "a pull request without its head repository" warning "head repo (unknown)"
pick GITHUB_EVENT_NAME=pull_request POOL_PR_HEAD_REPO=example-org/example-app
want "a pull request from this repository" ubuntu
pick GITHUB_EVENT_NAME=pull_request POOL_PR_HEAD_REPO=Example-Org/Example-App
want "a pull request from this repository, other case" ubuntu
pick GITHUB_ACTOR='dependabot[bot]'
want "a Dependabot run" github
says "a Dependabot run" warning "untrusted run: a Dependabot run"
no_lookup "a Dependabot run"
pick GITHUB_TRIGGERING_ACTOR='dependabot[bot]' POOL_MODE=pool
want "a re-run triggered by Dependabot, mode pool" github
pick POOL_REPO_VISIBILITY=public POOL_MODE=ubuntu
want "a public repository, pinned ubuntu" github
says "a public repository" warning "untrusted run: the repository is public"
no_lookup "a public repository"
pick POOL_REPO_VISIBILITY=
want "visibility unknown" github
says "visibility unknown" warning "visibility is unknown (treated as public)"
pick POOL_REPO_VISIBILITY=internal
want "an internal repository" ubuntu
pick GITHUB_ACTOR=someone GITHUB_EVENT_NAME=push
want "a push by a person" ubuntu

### Rule 2: mode github; unknown modes fail.
pick POOL_MODE=github
want "mode github" github
says "mode github" notice "pool-pick: github picks github: mode github, no lookup"
no_lookup "mode github"
pick POOL_MODE=github POOL_STATUS_REPO=
want "mode github needs no status-repo" github
pick POOL_MODE=github POOL_GITHUB_HEAVY=ubuntu-24.04-arm POOL_GITHUB_LIGHT='["ubuntu-24.04", "x"]'
want "mode github, own GitHub-hosted runs-on" github
[[ "$heavy" == '"ubuntu-24.04-arm"' && "$light" == '["ubuntu-24.04","x"]' ]] || fail "github runs-on: $(cat "$tmp/out")"
# pc and srv are the hosts' old ids: not in the default hosts, so not a mode.
for bad in macos-latest ubuntu-latest wsl mac ubuntu2 PC WIN pc srv; do
  pick POOL_MODE="$bad"
  cases=$((cases + 1))
  [[ "$code" == 1 && -z "$got" ]] || fail "mode $bad was accepted: exit $code, runner '$got'"
  grep -q '^::error title=pool-pick::mode must be' <<<"$out" || fail "mode $bad: no error"$'\n'"$out"
  no_lookup "mode $bad"
done
# Other inputs are checked before anything is read.
for bad in POOL_HOSTS=win,win POOL_CLASSES=heavy,gpu POOL_PREFER=ubuntu2 POOL_PREFER=pc POOL_MAX_BACKLOG=-1 \
  POOL_MAX_BACKLOG=two POOL_STATUS_REPO=pool-status \
  'POOL_GITHUB_HEAVY=[]' 'POOL_GITHUB_LIGHT=[1]' 'POOL_GITHUB_HEAVY=[not json'; do
  pick "$bad"
  cases=$((cases + 1))
  [[ "$code" == 1 && -z "$got" ]] || fail "$bad was accepted: exit $code, runner '$got'"
  grep -q '^::error title=pool-pick::' <<<"$out" || fail "$bad: no error"$'\n'"$out"
  no_lookup "$bad"
done
# A host id is checked by format only (lowercase letters and digits, starting
# with a letter); hosts lists the ids, so none is built in.
for bad in PC win,PC Win,ubuntu UBUNTU 2win win,pool-x win_2 'win ubuntu' win.2; do
  pick POOL_HOSTS="$bad"
  cases=$((cases + 1))
  [[ "$code" == 1 && -z "$got" ]] || fail "hosts $bad was accepted: exit $code, runner '$got'"
  grep -qF '::error title=pool-pick::hosts must be a comma-separated list of distinct host ids, each lowercase letters and digits starting with a letter (win, ubuntu, ubuntu2, ...)' <<<"$out" ||
    fail "hosts $bad: no hosts error"$'\n'"$out"
  no_lookup "hosts $bad"
done
# auto, pool and github are modes (github is also a pick): never a host id.
for bad in win,github github auto pool pool,ubuntu ubuntu,auto; do
  pick POOL_HOSTS="$bad"
  cases=$((cases + 1))
  [[ "$code" == 1 && -z "$got" ]] || fail "hosts $bad (a reserved id) was accepted: exit $code, runner '$got'"
  grep -qF '::error title=pool-pick::hosts must not use auto, pool or github as a host id (they are modes; github is also a pick)' <<<"$out" ||
    fail "hosts $bad: no reserved-id error"$'\n'"$out"
  no_lookup "hosts $bad"
done
# An id with no status variable (a typo, a host not published yet) is unreadable: GitHub-hosted.
pick POOL_HOSTS=win,wim
want "hosts with an id that has no status" github
says "hosts with an id that has no status" warning "status unreadable: wim request failed (HTTP 404)"
grep -qxF https://api.github.com/repos/example-org/pool-status/actions/variables/POOL_STATUS_WIM "$tmp/urls" ||
  fail "wim: wrong requests: $(cat "$tmp/urls")"
pick POOL_HOSTS=win,ubuntu,ubuntu2 POOL_MODE=ubuntu2
want "a third host, pinned, not published yet" github
says "a third host" warning "status unreadable: ubuntu2 request failed (HTTP 404)"

### Rule 3: a status that cannot be read is GitHub-hosted, fixed modes too.
pick POOL_PICK_TOKEN=
want "no token" github
says "no token" warning "status unreadable: the token is empty"
no_lookup "no token"
pick POOL_PICK_TOKEN= POOL_MODE=ubuntu
want "no token, pinned ubuntu" github
pick POOL_PICK_TOKEN=$'two\nlines'
want "a token with a line break" github
no_lookup "a token with a line break"
http var-ubuntu 401
pick
want "HTTP 401" github
says "HTTP 401" warning "status unreadable: ubuntu request failed (HTTP 401)"
pick POOL_MODE=ubuntu
want "HTTP 401, pinned ubuntu" github
pick POOL_MODE=win
want "HTTP 401 on ubuntu, pinned win reads only win" win
reset
http var-win fail
pick
want "curl fails" github
says "curl fails" warning "status unreadable: win request failed (curl exit 7)"
pick POOL_MODE=pool
want "curl fails, mode pool" github
reset
rm "$tmp/var-ubuntu.body"
pick
want "ubuntu has no status variable" github
says "ubuntu has no status variable" warning "ubuntu request failed (HTTP 404)"
pick POOL_HOSTS=win
want "hosts win only" win
reset
printf 'not json' > "$tmp/var-win.body"
pick
want "a response that is not JSON" github
says "a response that is not JSON" warning "status unreadable: win response is not json"
printf '{"name":"POOL_STATUS_WIN","updated_at":"2026-11-18T02:59:50Z"}' > "$tmp/var-win.body"
pick
want "a variable without a value" github
var win status-valid-win-accepting.json 10
python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["updated_at"]="yesterday"; json.dump(d,open(p,"w"))' "$tmp/var-win.body"
pick
want "a variable without a readable updated_at" github
says "updated_at" warning "win variable has no updated_at"
# The format's own examples: every invalid one is unreadable, except an unknown
# field (readers ignore fields they do not know, pool/docs/status.md).
for fixture in status-invalid-not-json status-invalid-unknown-version status-invalid-bool-seq \
  status-invalid-state status-invalid-missing-classes; do
  reset
  var win "$fixture.json" 10
  pick
  want "$fixture" github
  says "$fixture" warning "status unreadable: win "
  pick POOL_MODE=win
  want "$fixture, pinned win" github
done
reset
var win status-invalid-unknown-version.json 10
pick
says "unknown version" warning "win status has unknown version 2"
reset
var win status-invalid-extra-field.json 10
pick POOL_MODE=win
want "an unknown field is ignored" win
for fixture in status-valid-win-accepting status-valid-win-held status-valid-win-paused; do
  reset
  var win "$fixture.json" 10
  pick POOL_MODE=win
  want "$fixture is readable" win
done
for fixture in status-valid-ubuntu-accepting status-valid-ubuntu-draining; do
  reset
  var ubuntu "$fixture.json" 10 'repos=["example-app"]'
  pick POOL_MODE=ubuntu
  want "$fixture is readable" ubuntu
done
reset
var win status-valid-win-accepting.json 10 'v=true'
pick
want "v true is not 1" github
var win status-valid-win-accepting.json 10 'host="ubuntu"'
pick
want "a status naming another host" github
says "a status naming another host" warning "win status names another host"
var win status-valid-win-accepting.json 10 'classes.light.busy=-1'
pick
want "a negative count" github
var win status-valid-win-accepting.json 10 'classes.heavy=DELETE'
pick
want "no heavy class" github
var win status-valid-win-accepting.json 10 'repos="example-app"'
pick
want "repos not a list" github
var win status-valid-win-accepting.json 10 'guard=DELETE' 'image=DELETE' 'refused_24h=DELETE'
pick POOL_MODE=win
want "fields pick does not use may be missing" win

### Rule 4: a pool runner with a production label; a runner list that cannot be read.
reset
runners repo-runners 3 "self-hosted pool-win-heavy" "self-hosted pool-ubuntu-light" "self-hosted pool-ubuntu-heavy production"
pick
want "a pool runner with a production label" github
says "a pool runner with a production label" warning "1 runner(s) in the repository runner list carry a pool label and a prod label"
pick POOL_MODE=ubuntu
want "a production pool runner, pinned ubuntu" github
pick POOL_MODE=pool
want "a production pool runner, mode pool" github
runners repo-runners 2 "self-hosted Linux X64 pool-ubuntu-heavy" "self-hosted Linux X64 Prod-Deploy"
pick
want "a production runner without a pool label" ubuntu
runners repo-runners 1 "self-hosted POOL-WIN-LIGHT myprodbox"
pick
want "labels compare without case, prod anywhere in a label" github
reset
runners repo-runners 0
pick
want "no repository runner at all" ubuntu
runners repo-runners 5 "self-hosted pool-win-heavy"
pick
want "an incomplete runner list" github
says "an incomplete runner list" warning "the repository runner list unreadable: incomplete (1 of 5 runners)"
pick POOL_MODE=ubuntu
want "an incomplete runner list, pinned ubuntu" github
printf 'not json' > "$tmp/repo-runners.body"
pick
want "an unreadable runner list" github
says "an unreadable runner list" warning "the repository runner list unreadable: response is not json"
printf '{"total_count":1,"runners":[{"name":"x"}]}' > "$tmp/repo-runners.body"
pick
want "a runner without labels" github
reset
http repo-runners 403
pick
want "the runner list returns 403" github
says "the runner list returns 403" warning "the repository runner list unreadable: request failed (HTTP 403)"
http repo-runners fail
pick POOL_MODE=win
want "the runner list request fails, pinned win" github
# The runner group of the repository (org): always read; without a valid
# runner-group-id the run is GitHub-hosted (fail closed), with no lookup.
reset
pick POOL_RUNNER_GROUP_ID=42
want "group runners read and clean" ubuntu
grep -qxF 'https://api.github.com/orgs/example-org/actions/runner-groups/42/runners?per_page=100&page=1' "$tmp/urls" ||
  fail "no group lookup: $(cat "$tmp/urls")"
runners group-runners 2 "self-hosted pool-ubuntu-heavy" "self-hosted pool-ubuntu-light prod"
pick POOL_RUNNER_GROUP_ID=42
want "a production pool runner in the group" github
says "group prod" warning "1 runner(s) in the runner group 42 list carry a pool label and a prod label"
pick --no-group
want "runner-group-id left out" github
says "runner-group-id left out" warning "pool-pick: auto picks github: runner-group-id is empty: the runner group cannot be checked"
[[ "$reason" == "runner-group-id is empty: the runner group cannot be checked" ]] || fail "left out: reason output '$reason'"
grep -qF "auto picks github: runner-group-id is empty" "$tmp/summary" || fail "left out: not in the summary"
no_lookup "runner-group-id left out"
runners group-runners 1 "self-hosted pool-ubuntu-heavy"
for mode in auto pool ubuntu win; do
  pick POOL_RUNNER_GROUP_ID= POOL_MODE=$mode
  want "runner-group-id empty, mode $mode" github
  says "runner-group-id empty, mode $mode" warning "picks github: runner-group-id is empty"
  no_lookup "runner-group-id empty, mode $mode"
done
for bad in 12a 0 -1 4.2 ' 42x' "$(printf '42\n::error::x')"; do
  pick POOL_RUNNER_GROUP_ID="$bad"
  want "runner-group-id '$bad'" github
  says "runner-group-id '$bad'" warning "is not a positive integer: the runner group cannot be checked"
  grep -q '^::error' <<<"$out" && fail "runner-group-id '$bad' injected a workflow command"
  no_lookup "runner-group-id '$bad'"
done
grep -qF "$reason" "$tmp/summary" || fail "bad id: the reason is not in the summary"
pick --no-group GITHUB_EVENT_NAME=pull_request POOL_PR_HEAD_REPO=someone/example-app
want "untrusted without runner-group-id" github
says "untrusted without runner-group-id" warning "untrusted run: the pull request head repo"
no_lookup "untrusted without runner-group-id"
pick --no-group POOL_MODE=github
want "mode github without runner-group-id" github
says "mode github without runner-group-id" notice "mode github, no lookup"
no_lookup "mode github without runner-group-id"
reset
http group-runners 404
pick POOL_RUNNER_GROUP_ID=42 POOL_MODE=ubuntu
want "the group list cannot be read" github
says "the group list cannot be read" warning "the runner group 42 list unreadable: request failed (HTTP 404)"
reset
runners group-runners 3 "self-hosted pool-ubuntu-heavy"
pick POOL_RUNNER_GROUP_ID=42
want "an incomplete group list" github
# Pages: 150 runners, 100 per page.
reset
args=()
for _ in $(seq 100); do args+=("self-hosted pool-win-heavy"); done
runners repo-runners 150 "${args[@]}"
runners repo-runners.p2 150 "${args[@]:0:50}"
pick
want "150 runners on two pages" ubuntu
grep -qxF 'https://api.github.com/repos/example-org/example-app/actions/runners?per_page=100&page=2' "$tmp/urls" ||
  fail "page 2 not read: $(cat "$tmp/urls")"
runners repo-runners.p2 150 "${args[@]:0:49}" "self-hosted pool-ubuntu-heavy prod"
pick
want "a production pool runner on page 2" github
runners repo-runners.p2 150
pick
want "page 2 comes back empty" github
says "pages" warning "incomplete (100 of 150 runners)"
rm "$tmp/repo-runners.p2.body"
pick
want "page 2 cannot be read" github
says "page 2" warning "the repository runner list unreadable: request failed (HTTP 404)"
rm -f "$tmp/repo-runners.p2.status"

### Rule 5: candidates.
reset
var ubuntu status-valid-ubuntu-accepting.json 120 'repos=["example-app"]'
var win status-valid-win-accepting.json 121
pick
want "120 s old is fresh, 121 s is offline" ubuntu
var ubuntu status-valid-ubuntu-accepting.json 121 'repos=["example-app"]'
pick
want "both offline" github
says "both offline" warning "no pool host can take the run: win: offline (status 121s old); ubuntu: offline (status 121s old)"
reset
var ubuntu status-valid-ubuntu-draining.json 10 'repos=["example-app"]'
var win status-valid-win-held.json 10
pick
want "held and draining" github
says "held and draining" warning "win: held; ubuntu: draining"
var win status-valid-win-paused.json 500
pick
want "paused and offline" github
says "paused and offline" warning "win: offline (status 500s old), paused"
grep -q '^pool-pick detail: win state=paused age=500s listed=yes .* reason=guard layer 1: avail 3920 MB < 4000 MB$' <<<"$out" ||
  fail "the host's own reason is not in the log"$'\n'"$out"
grep -qF 'reason=guard layer 1' "$tmp/summary" || fail "the host's own reason is not in the summary"
reset
var ubuntu status-valid-ubuntu-accepting.json 10
pick
want "ubuntu does not list the repository, win is full" win
says "ubuntu does not list the repository" notice "pool full, queued on win"
var win status-valid-win-accepting.json 10 'repos=["pool-canary","EXAMPLE-APP"]'
pick
want "repos compare without case" win
var win status-valid-win-accepting.json 10 'repos=["pool-canary"]'
pick
want "no host lists the repository (no runner registered)" github
says "no host lists the repository" warning "win: repo not in repos; ubuntu: repo not in repos"
reset
var ubuntu status-valid-ubuntu-accepting.json 10 'repos=["example-app"]' 'classes.light.slots=0' 'classes.light.busy=0'
pick
want "ubuntu has no light slot, win is full" win
pick POOL_CLASSES=heavy
want "a heavy-only workflow does not need a light slot" ubuntu
var win status-valid-win-accepting.json 10 'classes.heavy.slots=0' 'classes.heavy.busy=0'
pick
want "no heavy slot on win, no light slot on ubuntu" github
says "no heavy slot on win" warning "win: no heavy slot; ubuntu: no light slot"
pick POOL_CLASSES=light
want "a light-only workflow" win
says "a light-only workflow" notice "win has 1 free light slot(s)"

### Rule 6: auto chooses the most free heavy slots; a tie goes to prefer (ubuntu).
reset
var win status-valid-win-accepting.json 10 'classes.heavy.slots=3'
pick
want "ubuntu 2 free, win 2 free: tie to ubuntu" ubuntu
pick POOL_PREFER=win
want "tie to prefer win" win
var win status-valid-win-accepting.json 10 'classes.heavy.slots=4'
pick
want "win has more free heavy slots" win
says "win has more" notice "win has 3 free heavy slot(s)"
# Full: queue on the smallest backlog (D19 A), unless max-backlog is reached.
reset
var win status-valid-win-accepting.json 10 'classes.heavy.queued=2'
var ubuntu status-valid-ubuntu-accepting.json 10 'repos=["example-app"]' 'classes.heavy.busy=2' 'classes.heavy.queued=1'
pick
want "full: ubuntu has 1 waiting, win 2" ubuntu
says "full" notice "pool full, queued on ubuntu (2 job(s) waiting, this run included)"
pick POOL_MAX_BACKLOG=2
want "max-backlog 2, 2 would wait" ubuntu
pick POOL_MAX_BACKLOG=1
want "max-backlog 1, 2 would wait" github
says "max-backlog 1" warning "pool full: 2 job(s) would wait on ubuntu, over max-backlog 1"
pick POOL_MAX_BACKLOG=0
want "max-backlog 0 never queues" github
var ubuntu status-valid-ubuntu-accepting.json 10 'repos=["example-app"]' 'classes.heavy.busy=2' 'classes.heavy.queued=2'
pick
want "full: tie in backlog goes to ubuntu" ubuntu
pick POOL_PREFER=win
want "full: tie in backlog goes to prefer win" win
var win status-valid-win-accepting.json 10
var ubuntu status-valid-ubuntu-accepting.json 10 'repos=["example-app"]' 'classes.heavy.busy=2'
pick
want "full, nobody waiting yet: tie to ubuntu" ubuntu
pick POOL_MODE=pool POOL_MAX_BACKLOG=0
want "mode pool ignores max-backlog" ubuntu

### Rule 6, fill prefer: prefer takes the run while it has a free main-class slot.
reset
var win status-valid-win-accepting.json 10 'classes.heavy.slots=2'
pick POOL_FILL=prefer POOL_PREFER=win
want "fill prefer: win 1 free, ubuntu 2 free" win
says "fill prefer win free" notice "pool-pick: auto picks win: win has 1 free heavy slot(s) (fill prefer)"
[[ "$reason" == "win has 1 free heavy slot(s) (fill prefer)" ]] || fail "fill prefer: reason output '$reason'"
pick POOL_FILL=prefer POOL_PREFER=win POOL_MODE=pool
want "fill prefer, mode pool: win 1 free, ubuntu 2 free" win
says "fill prefer mode pool" notice "pool-pick: pool picks win: win has 1 free heavy slot(s) (fill prefer)"
pick POOL_PREFER=win
want "fill unset: win 1 free, ubuntu 2 free spreads to ubuntu" ubuntu
says "fill unset" notice "pool-pick: auto picks ubuntu: ubuntu has 2 free heavy slot(s)"
pick POOL_FILL=spread POOL_PREFER=win
want "fill spread: win 1 free, ubuntu 2 free spreads to ubuntu" ubuntu
[[ "$reason" == "ubuntu has 2 free heavy slot(s)" ]] || fail "fill spread: reason output '$reason'"
pick POOL_FILL=prefer
want "fill prefer with the default prefer ubuntu" ubuntu
says "fill prefer default" notice "ubuntu has 2 free heavy slot(s) (fill prefer)"
pick POOL_FILL=prefer POOL_PREFER=win POOL_MODE=ubuntu
want "fill prefer does not move a pinned host" ubuntu
says "fill prefer pinned" notice "pinned to ubuntu (2 free heavy slot(s))"
pick POOL_FILL=prefer POOL_PREFER=win POOL_CLASSES=light
want "fill prefer, light only: win 1 free light" win
says "fill prefer light" notice "win has 1 free light slot(s) (fill prefer)"
# win full, ubuntu free: the most free slots, as with spread.
reset
pick POOL_FILL=prefer POOL_PREFER=win
want "fill prefer: win full, ubuntu free" ubuntu
[[ "$reason" == "ubuntu has 2 free heavy slot(s)" ]] || fail "fill prefer, win full: reason output '$reason'"
# Both full: the smallest backlog, max-backlog as before.
var win status-valid-win-accepting.json 10 'classes.heavy.queued=1'
var ubuntu status-valid-ubuntu-accepting.json 10 'repos=["example-app"]' 'classes.heavy.busy=2'
pick POOL_FILL=prefer POOL_PREFER=win
want "fill prefer, full: ubuntu 0 waiting, win 1" ubuntu
says "fill prefer full" notice "pool full, queued on ubuntu (1 job(s) waiting, this run included)"
pick POOL_FILL=prefer POOL_PREFER=win POOL_MAX_BACKLOG=0
want "fill prefer, full, max-backlog 0" github
says "fill prefer max-backlog 0" warning "pool full: 1 job(s) would wait on ubuntu, over max-backlog 0"
# A backlog tie goes to prefer.
var win status-valid-win-accepting.json 10
pick POOL_FILL=prefer POOL_PREFER=win
want "fill prefer, full, backlog tie" win
says "fill prefer backlog tie" notice "pool full, queued on win (1 job(s) waiting, this run included)"
# win not a candidate: not accepting, stale or not listing the repository.
reset
var win status-valid-win-accepting.json 10 'classes.heavy.slots=3' 'state="held"'
pick POOL_FILL=prefer POOL_PREFER=win
want "fill prefer: win held with room" ubuntu
says "fill prefer win held" notice "ubuntu has 2 free heavy slot(s)"
var win status-valid-win-accepting.json 10 'classes.heavy.slots=3' 'state="paused"'
pick POOL_FILL=prefer POOL_PREFER=win
want "fill prefer: win paused with room" ubuntu
var win status-valid-win-accepting.json 121 'classes.heavy.slots=3'
pick POOL_FILL=prefer POOL_PREFER=win
want "fill prefer: win stale with room" ubuntu
var win status-valid-win-accepting.json 10 'classes.heavy.slots=3' 'repos=["pool-canary"]'
pick POOL_FILL=prefer POOL_PREFER=win
want "fill prefer: win does not list the repository" ubuntu
# An unknown fill fails before anything is read.
for bad in Prefer most spread,prefer fill; do
  pick POOL_FILL="$bad"
  cases=$((cases + 1))
  [[ "$code" == 1 && -z "$got" ]] || fail "fill $bad was accepted: exit $code, runner '$got'"
  grep -q '^::error title=pool-pick::fill must be unset, spread or prefer' <<<"$out" || fail "fill $bad: no error"$'\n'"$out"
  no_lookup "fill $bad"
done

### Rule 7: fixed modes.
reset
pick POOL_MODE=win
want "pinned win, fresh and accepting" win
says "pinned win" notice "pool-pick: win picks win: pinned to win (0 free heavy slot(s))"
[[ "$heavy" == '"pool-win-heavy"' && "$light" == '"pool-win-light"' ]] || fail "runs_on for win: $(cat "$tmp/out")"
grep -c POOL_STATUS_ "$tmp/urls" | grep -qx 1 || fail "pinned win read more than its own status"
var win status-valid-win-held.json 4000
pick POOL_MODE=win
want "pinned win, held and offline: waits" win
says "pinned win held" warning "pinned to win, offline (status 4000s old), held: the jobs wait for it"
[[ "$light" == '"pool-win-light"' ]] || fail "pinned win offline: runs_on_light $light"
var win status-valid-win-accepting.json 10 'repos=["pool-canary"]'
pick POOL_MODE=win
want "pinned win, repository not listed" github
says "pinned win not listed" warning "pinned host win: repo not in repos"
var win status-valid-win-accepting.json 10 'classes.light.slots=0'
pick POOL_MODE=win
want "pinned win, no light slot (the light jobs would never start)" github
pick POOL_MODE=win POOL_CLASSES=heavy
want "pinned win, heavy only" win
# pool: the accepting hosts first, else prefer, else the first that can.
reset
pick POOL_MODE=pool
want "mode pool, both accepting" ubuntu
var ubuntu status-valid-ubuntu-accepting.json 600 'repos=["example-app"]'
pick POOL_MODE=pool
want "mode pool, ubuntu offline, win accepting" win
var win status-valid-win-accepting.json 600
pick POOL_MODE=pool
want "mode pool, both offline: prefer ubuntu" ubuntu
says "mode pool both offline" warning "pool-pick: pool picks ubuntu: no pool host is accepting (win: offline (status 600s old); ubuntu: offline (status 600s old)): waits on ubuntu"
pick POOL_MODE=pool POOL_PREFER=win
want "mode pool, both offline: prefer win" win
var ubuntu status-valid-ubuntu-accepting.json 600
pick POOL_MODE=pool
want "mode pool, both offline, ubuntu does not list the repository" win
var win status-valid-win-held.json 10 'repos=["pool-canary"]'
pick POOL_MODE=pool
want "mode pool, no host lists the repository" github
says "mode pool no host" warning "no pool host serves the run: win: repo not in repos, held; ubuntu: repo not in repos, offline (status 600s old)"

### Host ids: the defaults (hosts win,ubuntu, prefer ubuntu) and the switch from pc,srv.
reset
pick
want "default hosts" ubuntu
grep -c POOL_STATUS_ "$tmp/urls" | grep -qx 2 || fail "default hosts: not two status reads: $(cat "$tmp/urls")"
grep -qE 'POOL_STATUS_(PC|SRV)$' "$tmp/urls" && fail "default hosts read an old id: $(cat "$tmp/urls")"
pick POOL_HOSTS=win,ubuntu
want "hosts win,ubuntu set explicitly" ubuntu
[[ "$heavy" == '"pool-ubuntu-heavy"' && "$light" == '"pool-ubuntu-light"' ]] || fail "runs_on for ubuntu: $(cat "$tmp/out")"
var win status-valid-win-accepting.json 10 'classes.heavy.slots=3'
pick
want "default prefer ubuntu wins a tie" ubuntu
pick POOL_HOSTS=ubuntu,win
want "default prefer ubuntu, whatever the hosts order" ubuntu
pick POOL_HOSTS=win,ubuntu POOL_PREFER=win
want "prefer win set explicitly wins a tie" win
pick POOL_HOSTS=win
want "hosts win alone: prefer is win" win
var ubuntu2 status-valid-ubuntu-accepting.json 10 'host="ubuntu2"' 'repos=["example-app"]'
pick POOL_HOSTS=win,ubuntu2
want "hosts without ubuntu: a tie goes to the first host" win
# Halfway through the rename one host still publishes its old id: hosts pc,ubuntu.
reset
var pc status-valid-win-accepting.json 10 'host="pc"'
pick POOL_HOSTS=pc,ubuntu
want "hosts pc,ubuntu: auto" ubuntu
diff <(grep POOL_STATUS_ "$tmp/urls") <(printf '%s\n' \
  https://api.github.com/repos/example-org/pool-status/actions/variables/POOL_STATUS_PC \
  https://api.github.com/repos/example-org/pool-status/actions/variables/POOL_STATUS_UBUNTU) ||
  fail "hosts pc,ubuntu: wrong status reads"
pick POOL_HOSTS=pc,ubuntu POOL_MODE=pc
want "hosts pc,ubuntu: pinned pc" pc
[[ "$heavy" == '"pool-pc-heavy"' && "$light" == '"pool-pc-light"' ]] || fail "runs_on for pc: $(cat "$tmp/out")"
var pc status-valid-win-accepting.json 10 'host="pc"' 'classes.heavy.slots=2'
pick POOL_HOSTS=pc,ubuntu POOL_PREFER=pc POOL_FILL=prefer
want "hosts pc,ubuntu: fill prefer pc" pc
says "hosts pc,ubuntu fill prefer" notice "pool-pick: auto picks pc: pc has 1 free heavy slot(s) (fill prefer)"
pick POOL_HOSTS=pc,ubuntu POOL_MODE=win
cases=$((cases + 1))
[[ "$code" == 1 && -z "$got" ]] || fail "hosts pc,ubuntu: mode win was accepted: exit $code, runner '$got'"
grep -qF '::error title=pool-pick::mode must be unset, auto, pool, github or one of pc, ubuntu' <<<"$out" ||
  fail "hosts pc,ubuntu, mode win: no error"$'\n'"$out"
var pc status-valid-win-accepting.json 10
pick POOL_HOSTS=pc,ubuntu
want "hosts pc,ubuntu: a pc variable that still says win" github
says "pc variable says win" warning "pc status names another host"
rm -f "$tmp/var-pc.body" "$tmp/var-ubuntu2.body"

### Annotation data is escaped; outputs stay on one line.
reset
var win status-valid-win-paused.json 10 'reason="100%\nwarning ::error::x"'
pick POOL_MODE=win
want "a host reason with a newline and %" win
grep -q '^::error' <<<"$out" && fail "a host reason injected a workflow command"
grep -qF 'reason=100% warning ::error::x' <<<"$out" || fail "the host reason is not on one line"$'\n'"$out"
pick GITHUB_EVENT_NAME=pull_request POOL_PR_HEAD_REPO=$'evil/r\n::error::x%'
want "a head repo with a newline and %" github
grep -q '^::error' <<<"$out" && fail "a head repo injected a workflow command"
says "escaped" warning "(evil/r ::error::x%25)"
[[ "$(grep -c '' "$tmp/out")" == 4 ]] || fail "GITHUB_OUTPUT is not four lines: $(cat "$tmp/out")"

echo "pool-pick: $cases cases passed (rules 1-7, fixtures, token handling, outputs)"
