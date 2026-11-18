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

# The default world: pc accepting with no free heavy slot, srv accepting with
# two free heavy slots, both list example-app, both fresh; no production runner.
reset() {
  var pc status-valid-pc-accepting.json 10
  var srv status-valid-srv-accepting.json 10 'repos=["pool-canary","example-app"]'
  runners repo-runners 2 "self-hosted Linux X64 pool-pc-heavy" "self-hosted Linux X64 pool-srv-light"
  runners group-runners 1 "self-hosted pool-srv-heavy"
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
want "auto, srv has room" srv
[[ "$heavy" == '"pool-srv-heavy"' && "$light" == '"pool-srv-light"' ]] || fail "runs_on for srv: $(cat "$tmp/out")"
[[ "$reason" == "srv has 2 free heavy slot(s)" ]] || fail "reason output: '$reason'"
says "auto, srv has room" notice "pool-pick: auto picks srv: srv has 2 free heavy slot(s)"
grep -qxF "    pool-pick: auto picks srv: srv has 2 free heavy slot(s)" "$tmp/summary" || fail "job summary: $(cat "$tmp/summary")"
# S6's pool_report.py reads the line from the annotation with this pattern.
python3 -I - "$(grep '^::notice title=pool-pick::' <<<"$out" | sed 's/^::notice title=pool-pick:://')" <<'PY' || fail "the annotation does not match pool_report's PICK_RE"
import re, sys
m = re.search(r"pool-pick: (?P<mode>[A-Za-z0-9_-]+) picks (?P<runner>[a-z0-9]+): (?P<reason>.*)", sys.argv[1])
assert m and m["mode"] == "auto" and m["runner"] == "srv", sys.argv[1]
PY
grep -q sekrit "$tmp/args" && fail "the token reached curl's arguments"
grep -qx 'Authorization: Bearer sekrit-token-value' "$tmp/stdin" || fail "the token did not reach curl's stdin"
grep -q sekrit <<<"$out" && fail "the token was printed"
grep -q sekrit "$tmp/out" "$tmp/summary" && fail "the token reached the outputs or the summary"
[[ "$(sort -u "$tmp/stdin" | wc -l | tr -d ' ')" == 1 ]] || fail "curl's stdin holds more than the header"
grep -A1 -xF -- '--header' "$tmp/args" | grep -qxF -- '@-' || fail "curl does not read a header from stdin (--header @-)"
diff <(cat "$tmp/urls") <(printf '%s\n' \
  https://api.github.com/repos/example-org/pool-status/actions/variables/POOL_STATUS_PC \
  https://api.github.com/repos/example-org/pool-status/actions/variables/POOL_STATUS_SRV \
  'https://api.github.com/repos/example-org/example-app/actions/runners?per_page=100&page=1' \
  'https://api.github.com/orgs/example-org/actions/runner-groups/42/runners?per_page=100&page=1') ||
  fail "wrong requests"
pick GITHUB_API_URL=https://ghe.example.invalid/api/v3
want "GITHUB_API_URL is used" srv
grep -q '^https://ghe.example.invalid/api/v3/repos/' "$tmp/urls" || fail "GITHUB_API_URL ignored: $(cat "$tmp/urls")"
pick POOL_MODE=auto
want "auto set explicitly" srv
says "auto set explicitly" notice "pool-pick: auto picks srv:"
pick POOL_MODE=auto POOL_GITHUB_HEAVY='["self-hosted-not-used"]'
want "github-heavy does not matter for a pool pick" srv

### Rule 1: untrusted runs, whatever the mode, with no lookup.
for event in pull_request_target workflow_run; do
  pick GITHUB_EVENT_NAME=$event POOL_MODE=srv
  want "event $event, pinned srv" github
  says "event $event" warning "untrusted run: event $event"
  no_lookup "event $event"
done
pick GITHUB_EVENT_NAME=pull_request POOL_PR_HEAD_REPO=someone/example-app
want "a pull request from a fork" github
says "a pull request from a fork" warning "untrusted run: the pull request head repo (someone/example-app) is another repository"
[[ "$heavy" == '"ubuntu-latest"' && "$light" == '"ubuntu-latest"' ]] || fail "runs_on for GitHub: $(cat "$tmp/out")"
no_lookup "a pull request from a fork"
pick GITHUB_EVENT_NAME=pull_request POOL_PR_HEAD_REPO=someone/example-app POOL_MODE=pc
want "a pull request from a fork, pinned pc" github
pick GITHUB_EVENT_NAME=pull_request_review POOL_PR_HEAD_REPO=someone/example-app
want "a pull_request_review from a fork" github
pick GITHUB_EVENT_NAME=pull_request
want "a pull request without its head repository" github
says "a pull request without its head repository" warning "head repo (unknown)"
pick GITHUB_EVENT_NAME=pull_request POOL_PR_HEAD_REPO=example-org/example-app
want "a pull request from this repository" srv
pick GITHUB_EVENT_NAME=pull_request POOL_PR_HEAD_REPO=Example-Org/Example-App
want "a pull request from this repository, other case" srv
pick GITHUB_ACTOR='dependabot[bot]'
want "a Dependabot run" github
says "a Dependabot run" warning "untrusted run: a Dependabot run"
no_lookup "a Dependabot run"
pick GITHUB_TRIGGERING_ACTOR='dependabot[bot]' POOL_MODE=pool
want "a re-run triggered by Dependabot, mode pool" github
pick POOL_REPO_VISIBILITY=public POOL_MODE=srv
want "a public repository, pinned srv" github
says "a public repository" warning "untrusted run: the repository is public"
no_lookup "a public repository"
pick POOL_REPO_VISIBILITY=
want "visibility unknown" github
says "visibility unknown" warning "visibility is unknown (treated as public)"
pick POOL_REPO_VISIBILITY=internal
want "an internal repository" srv
pick GITHUB_ACTOR=someone GITHUB_EVENT_NAME=push
want "a push by a person" srv

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
for bad in macos-latest ubuntu-latest wsl mac srv2 PC; do
  pick POOL_MODE="$bad"
  cases=$((cases + 1))
  [[ "$code" == 1 && -z "$got" ]] || fail "mode $bad was accepted: exit $code, runner '$got'"
  grep -q '^::error title=pool-pick::mode must be' <<<"$out" || fail "mode $bad: no error"$'\n'"$out"
  no_lookup "mode $bad"
done
# Other inputs are checked before anything is read.
for bad in POOL_HOSTS=pc,mac POOL_HOSTS=pc,pc POOL_CLASSES=heavy,gpu POOL_PREFER=srv2 POOL_MAX_BACKLOG=-1 \
  POOL_MAX_BACKLOG=two POOL_STATUS_REPO=pool-status \
  'POOL_GITHUB_HEAVY=[]' 'POOL_GITHUB_LIGHT=[1]' 'POOL_GITHUB_HEAVY=[not json'; do
  pick "$bad"
  cases=$((cases + 1))
  [[ "$code" == 1 && -z "$got" ]] || fail "$bad was accepted: exit $code, runner '$got'"
  grep -q '^::error title=pool-pick::' <<<"$out" || fail "$bad: no error"$'\n'"$out"
  no_lookup "$bad"
done
pick POOL_HOSTS=pc,srv,srv2 POOL_MODE=srv2
want "a third host, pinned, not published yet" github
says "a third host" warning "status unreadable: srv2 request failed (HTTP 404)"

### Rule 3: a status that cannot be read is GitHub-hosted, fixed modes too.
pick POOL_PICK_TOKEN=
want "no token" github
says "no token" warning "status unreadable: the token is empty"
no_lookup "no token"
pick POOL_PICK_TOKEN= POOL_MODE=srv
want "no token, pinned srv" github
pick POOL_PICK_TOKEN=$'two\nlines'
want "a token with a line break" github
no_lookup "a token with a line break"
http var-srv 401
pick
want "HTTP 401" github
says "HTTP 401" warning "status unreadable: srv request failed (HTTP 401)"
pick POOL_MODE=srv
want "HTTP 401, pinned srv" github
pick POOL_MODE=pc
want "HTTP 401 on srv, pinned pc reads only pc" pc
reset
http var-pc fail
pick
want "curl fails" github
says "curl fails" warning "status unreadable: pc request failed (curl exit 7)"
pick POOL_MODE=pool
want "curl fails, mode pool" github
reset
rm "$tmp/var-srv.body"
pick
want "srv has no status variable" github
says "srv has no status variable" warning "srv request failed (HTTP 404)"
pick POOL_HOSTS=pc
want "hosts pc only" pc
reset
printf 'not json' > "$tmp/var-pc.body"
pick
want "a response that is not JSON" github
says "a response that is not JSON" warning "status unreadable: pc response is not json"
printf '{"name":"POOL_STATUS_PC","updated_at":"2026-11-18T02:59:50Z"}' > "$tmp/var-pc.body"
pick
want "a variable without a value" github
var pc status-valid-pc-accepting.json 10
python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["updated_at"]="yesterday"; json.dump(d,open(p,"w"))' "$tmp/var-pc.body"
pick
want "a variable without a readable updated_at" github
says "updated_at" warning "pc variable has no updated_at"
# The format's own examples: every invalid one is unreadable, except an unknown
# field (readers ignore fields they do not know, pool/docs/status.md).
for fixture in status-invalid-not-json status-invalid-unknown-version status-invalid-bool-seq \
  status-invalid-state status-invalid-missing-classes; do
  reset
  var pc "$fixture.json" 10
  pick
  want "$fixture" github
  says "$fixture" warning "status unreadable: pc "
  pick POOL_MODE=pc
  want "$fixture, pinned pc" github
done
reset
var pc status-invalid-unknown-version.json 10
pick
says "unknown version" warning "pc status has unknown version 2"
reset
var pc status-invalid-extra-field.json 10
pick POOL_MODE=pc
want "an unknown field is ignored" pc
for fixture in status-valid-pc-accepting status-valid-pc-held status-valid-pc-paused; do
  reset
  var pc "$fixture.json" 10
  pick POOL_MODE=pc
  want "$fixture is readable" pc
done
for fixture in status-valid-srv-accepting status-valid-srv-draining; do
  reset
  var srv "$fixture.json" 10 'repos=["example-app"]'
  pick POOL_MODE=srv
  want "$fixture is readable" srv
done
reset
var pc status-valid-pc-accepting.json 10 'v=true'
pick
want "v true is not 1" github
var pc status-valid-pc-accepting.json 10 'host="srv"'
pick
want "a status naming another host" github
says "a status naming another host" warning "pc status names another host"
var pc status-valid-pc-accepting.json 10 'classes.light.busy=-1'
pick
want "a negative count" github
var pc status-valid-pc-accepting.json 10 'classes.heavy=DELETE'
pick
want "no heavy class" github
var pc status-valid-pc-accepting.json 10 'repos="example-app"'
pick
want "repos not a list" github
var pc status-valid-pc-accepting.json 10 'guard=DELETE' 'image=DELETE' 'refused_24h=DELETE'
pick POOL_MODE=pc
want "fields pick does not use may be missing" pc

### Rule 4: a pool runner with a production label; a runner list that cannot be read.
reset
runners repo-runners 3 "self-hosted pool-pc-heavy" "self-hosted pool-srv-light" "self-hosted pool-srv-heavy production"
pick
want "a pool runner with a production label" github
says "a pool runner with a production label" warning "1 runner(s) in the repository runner list carry a pool label and a prod label"
pick POOL_MODE=srv
want "a production pool runner, pinned srv" github
pick POOL_MODE=pool
want "a production pool runner, mode pool" github
runners repo-runners 2 "self-hosted Linux X64 pool-srv-heavy" "self-hosted Linux X64 Prod-Deploy"
pick
want "a production runner without a pool label" srv
runners repo-runners 1 "self-hosted POOL-PC-LIGHT myprodbox"
pick
want "labels compare without case, prod anywhere in a label" github
reset
runners repo-runners 0
pick
want "no repository runner at all" srv
runners repo-runners 5 "self-hosted pool-pc-heavy"
pick
want "an incomplete runner list" github
says "an incomplete runner list" warning "the repository runner list unreadable: incomplete (1 of 5 runners)"
pick POOL_MODE=srv
want "an incomplete runner list, pinned srv" github
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
pick POOL_MODE=pc
want "the runner list request fails, pinned pc" github
# The runner group of the repository (org): always read; without a valid
# runner-group-id the run is GitHub-hosted (fail closed), with no lookup.
reset
pick POOL_RUNNER_GROUP_ID=42
want "group runners read and clean" srv
grep -qxF 'https://api.github.com/orgs/example-org/actions/runner-groups/42/runners?per_page=100&page=1' "$tmp/urls" ||
  fail "no group lookup: $(cat "$tmp/urls")"
runners group-runners 2 "self-hosted pool-srv-heavy" "self-hosted pool-srv-light prod"
pick POOL_RUNNER_GROUP_ID=42
want "a production pool runner in the group" github
says "group prod" warning "1 runner(s) in the runner group 42 list carry a pool label and a prod label"
pick --no-group
want "runner-group-id left out" github
says "runner-group-id left out" warning "pool-pick: auto picks github: runner-group-id is empty: the runner group cannot be checked"
[[ "$reason" == "runner-group-id is empty: the runner group cannot be checked" ]] || fail "left out: reason output '$reason'"
grep -qF "auto picks github: runner-group-id is empty" "$tmp/summary" || fail "left out: not in the summary"
no_lookup "runner-group-id left out"
runners group-runners 1 "self-hosted pool-srv-heavy"
for mode in auto pool srv pc; do
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
pick POOL_RUNNER_GROUP_ID=42 POOL_MODE=srv
want "the group list cannot be read" github
says "the group list cannot be read" warning "the runner group 42 list unreadable: request failed (HTTP 404)"
reset
runners group-runners 3 "self-hosted pool-srv-heavy"
pick POOL_RUNNER_GROUP_ID=42
want "an incomplete group list" github
# Pages: 150 runners, 100 per page.
reset
args=()
for _ in $(seq 100); do args+=("self-hosted pool-pc-heavy"); done
runners repo-runners 150 "${args[@]}"
runners repo-runners.p2 150 "${args[@]:0:50}"
pick
want "150 runners on two pages" srv
grep -qxF 'https://api.github.com/repos/example-org/example-app/actions/runners?per_page=100&page=2' "$tmp/urls" ||
  fail "page 2 not read: $(cat "$tmp/urls")"
runners repo-runners.p2 150 "${args[@]:0:49}" "self-hosted pool-srv-heavy prod"
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
var srv status-valid-srv-accepting.json 120 'repos=["example-app"]'
var pc status-valid-pc-accepting.json 121
pick
want "120 s old is fresh, 121 s is offline" srv
var srv status-valid-srv-accepting.json 121 'repos=["example-app"]'
pick
want "both offline" github
says "both offline" warning "no pool host can take the run: pc: offline (status 121s old); srv: offline (status 121s old)"
reset
var srv status-valid-srv-draining.json 10 'repos=["example-app"]'
var pc status-valid-pc-held.json 10
pick
want "held and draining" github
says "held and draining" warning "pc: held; srv: draining"
var pc status-valid-pc-paused.json 500
pick
want "paused and offline" github
says "paused and offline" warning "pc: offline (status 500s old), paused"
grep -q '^pool-pick detail: pc state=paused age=500s listed=yes .* reason=guard layer 1: avail 3920 MB < 4000 MB$' <<<"$out" ||
  fail "the host's own reason is not in the log"$'\n'"$out"
grep -qF 'reason=guard layer 1' "$tmp/summary" || fail "the host's own reason is not in the summary"
reset
var srv status-valid-srv-accepting.json 10
pick
want "srv does not list the repository, pc is full" pc
says "srv does not list the repository" notice "pool full, queued on pc"
var pc status-valid-pc-accepting.json 10 'repos=["pool-canary","EXAMPLE-APP"]'
pick
want "repos compare without case" pc
var pc status-valid-pc-accepting.json 10 'repos=["pool-canary"]'
pick
want "no host lists the repository (no runner registered)" github
says "no host lists the repository" warning "pc: repo not in repos; srv: repo not in repos"
reset
var srv status-valid-srv-accepting.json 10 'repos=["example-app"]' 'classes.light.slots=0' 'classes.light.busy=0'
pick
want "srv has no light slot, pc is full" pc
pick POOL_CLASSES=heavy
want "a heavy-only workflow does not need a light slot" srv
var pc status-valid-pc-accepting.json 10 'classes.heavy.slots=0' 'classes.heavy.busy=0'
pick
want "no heavy slot on pc, no light slot on srv" github
says "no heavy slot on pc" warning "pc: no heavy slot; srv: no light slot"
pick POOL_CLASSES=light
want "a light-only workflow" pc
says "a light-only workflow" notice "pc has 1 free light slot(s)"

### Rule 6: auto chooses the most free heavy slots; a tie goes to prefer (srv).
reset
var pc status-valid-pc-accepting.json 10 'classes.heavy.slots=3'
pick
want "srv 2 free, pc 2 free: tie to srv" srv
pick POOL_PREFER=pc
want "tie to prefer pc" pc
var pc status-valid-pc-accepting.json 10 'classes.heavy.slots=4'
pick
want "pc has more free heavy slots" pc
says "pc has more" notice "pc has 3 free heavy slot(s)"
# Full: queue on the smallest backlog (D19 A), unless max-backlog is reached.
reset
var pc status-valid-pc-accepting.json 10 'classes.heavy.queued=2'
var srv status-valid-srv-accepting.json 10 'repos=["example-app"]' 'classes.heavy.busy=2' 'classes.heavy.queued=1'
pick
want "full: srv has 1 waiting, pc 2" srv
says "full" notice "pool full, queued on srv (2 job(s) waiting, this run included)"
pick POOL_MAX_BACKLOG=2
want "max-backlog 2, 2 would wait" srv
pick POOL_MAX_BACKLOG=1
want "max-backlog 1, 2 would wait" github
says "max-backlog 1" warning "pool full: 2 job(s) would wait on srv, over max-backlog 1"
pick POOL_MAX_BACKLOG=0
want "max-backlog 0 never queues" github
var srv status-valid-srv-accepting.json 10 'repos=["example-app"]' 'classes.heavy.busy=2' 'classes.heavy.queued=2'
pick
want "full: tie in backlog goes to srv" srv
pick POOL_PREFER=pc
want "full: tie in backlog goes to prefer pc" pc
var pc status-valid-pc-accepting.json 10
var srv status-valid-srv-accepting.json 10 'repos=["example-app"]' 'classes.heavy.busy=2'
pick
want "full, nobody waiting yet: tie to srv" srv
pick POOL_MODE=pool POOL_MAX_BACKLOG=0
want "mode pool ignores max-backlog" srv

### Rule 6, fill prefer: prefer takes the run while it has a free main-class slot.
reset
var pc status-valid-pc-accepting.json 10 'classes.heavy.slots=2'
pick POOL_FILL=prefer POOL_PREFER=pc
want "fill prefer: pc 1 free, srv 2 free" pc
says "fill prefer pc free" notice "pool-pick: auto picks pc: pc has 1 free heavy slot(s) (fill prefer)"
[[ "$reason" == "pc has 1 free heavy slot(s) (fill prefer)" ]] || fail "fill prefer: reason output '$reason'"
pick POOL_FILL=prefer POOL_PREFER=pc POOL_MODE=pool
want "fill prefer, mode pool: pc 1 free, srv 2 free" pc
says "fill prefer mode pool" notice "pool-pick: pool picks pc: pc has 1 free heavy slot(s) (fill prefer)"
pick POOL_PREFER=pc
want "fill unset: pc 1 free, srv 2 free spreads to srv" srv
says "fill unset" notice "pool-pick: auto picks srv: srv has 2 free heavy slot(s)"
pick POOL_FILL=spread POOL_PREFER=pc
want "fill spread: pc 1 free, srv 2 free spreads to srv" srv
[[ "$reason" == "srv has 2 free heavy slot(s)" ]] || fail "fill spread: reason output '$reason'"
pick POOL_FILL=prefer
want "fill prefer with the default prefer srv" srv
says "fill prefer default" notice "srv has 2 free heavy slot(s) (fill prefer)"
pick POOL_FILL=prefer POOL_PREFER=pc POOL_MODE=srv
want "fill prefer does not move a pinned host" srv
says "fill prefer pinned" notice "pinned to srv (2 free heavy slot(s))"
pick POOL_FILL=prefer POOL_PREFER=pc POOL_CLASSES=light
want "fill prefer, light only: pc 1 free light" pc
says "fill prefer light" notice "pc has 1 free light slot(s) (fill prefer)"
# pc full, srv free: the most free slots, as with spread.
reset
pick POOL_FILL=prefer POOL_PREFER=pc
want "fill prefer: pc full, srv free" srv
[[ "$reason" == "srv has 2 free heavy slot(s)" ]] || fail "fill prefer, pc full: reason output '$reason'"
# Both full: the smallest backlog, max-backlog as before.
var pc status-valid-pc-accepting.json 10 'classes.heavy.queued=1'
var srv status-valid-srv-accepting.json 10 'repos=["example-app"]' 'classes.heavy.busy=2'
pick POOL_FILL=prefer POOL_PREFER=pc
want "fill prefer, full: srv 0 waiting, pc 1" srv
says "fill prefer full" notice "pool full, queued on srv (1 job(s) waiting, this run included)"
pick POOL_FILL=prefer POOL_PREFER=pc POOL_MAX_BACKLOG=0
want "fill prefer, full, max-backlog 0" github
says "fill prefer max-backlog 0" warning "pool full: 1 job(s) would wait on srv, over max-backlog 0"
# A backlog tie goes to prefer.
var pc status-valid-pc-accepting.json 10
pick POOL_FILL=prefer POOL_PREFER=pc
want "fill prefer, full, backlog tie" pc
says "fill prefer backlog tie" notice "pool full, queued on pc (1 job(s) waiting, this run included)"
# pc not a candidate: not accepting, stale or not listing the repository.
reset
var pc status-valid-pc-accepting.json 10 'classes.heavy.slots=3' 'state="held"'
pick POOL_FILL=prefer POOL_PREFER=pc
want "fill prefer: pc held with room" srv
says "fill prefer pc held" notice "srv has 2 free heavy slot(s)"
var pc status-valid-pc-accepting.json 10 'classes.heavy.slots=3' 'state="paused"'
pick POOL_FILL=prefer POOL_PREFER=pc
want "fill prefer: pc paused with room" srv
var pc status-valid-pc-accepting.json 121 'classes.heavy.slots=3'
pick POOL_FILL=prefer POOL_PREFER=pc
want "fill prefer: pc stale with room" srv
var pc status-valid-pc-accepting.json 10 'classes.heavy.slots=3' 'repos=["pool-canary"]'
pick POOL_FILL=prefer POOL_PREFER=pc
want "fill prefer: pc does not list the repository" srv
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
pick POOL_MODE=pc
want "pinned pc, fresh and accepting" pc
says "pinned pc" notice "pool-pick: pc picks pc: pinned to pc (0 free heavy slot(s))"
[[ "$heavy" == '"pool-pc-heavy"' && "$light" == '"pool-pc-light"' ]] || fail "runs_on for pc: $(cat "$tmp/out")"
grep -c POOL_STATUS_ "$tmp/urls" | grep -qx 1 || fail "pinned pc read more than its own status"
var pc status-valid-pc-held.json 4000
pick POOL_MODE=pc
want "pinned pc, held and offline: waits" pc
says "pinned pc held" warning "pinned to pc, offline (status 4000s old), held: the jobs wait for it"
[[ "$light" == '"pool-pc-light"' ]] || fail "pinned pc offline: runs_on_light $light"
var pc status-valid-pc-accepting.json 10 'repos=["pool-canary"]'
pick POOL_MODE=pc
want "pinned pc, repository not listed" github
says "pinned pc not listed" warning "pinned host pc: repo not in repos"
var pc status-valid-pc-accepting.json 10 'classes.light.slots=0'
pick POOL_MODE=pc
want "pinned pc, no light slot (the light jobs would never start)" github
pick POOL_MODE=pc POOL_CLASSES=heavy
want "pinned pc, heavy only" pc
# pool: the accepting hosts first, else prefer, else the first that can.
reset
pick POOL_MODE=pool
want "mode pool, both accepting" srv
var srv status-valid-srv-accepting.json 600 'repos=["example-app"]'
pick POOL_MODE=pool
want "mode pool, srv offline, pc accepting" pc
var pc status-valid-pc-accepting.json 600
pick POOL_MODE=pool
want "mode pool, both offline: prefer srv" srv
says "mode pool both offline" warning "pool-pick: pool picks srv: no pool host is accepting (pc: offline (status 600s old); srv: offline (status 600s old)): waits on srv"
pick POOL_MODE=pool POOL_PREFER=pc
want "mode pool, both offline: prefer pc" pc
var srv status-valid-srv-accepting.json 600
pick POOL_MODE=pool
want "mode pool, both offline, srv does not list the repository" pc
var pc status-valid-pc-held.json 10 'repos=["pool-canary"]'
pick POOL_MODE=pool
want "mode pool, no host lists the repository" github
says "mode pool no host" warning "no pool host serves the run: pc: repo not in repos, held; srv: repo not in repos, offline (status 600s old)"

### Annotation data is escaped; outputs stay on one line.
reset
var pc status-valid-pc-paused.json 10 'reason="100%\nwarning ::error::x"'
pick POOL_MODE=pc
want "a host reason with a newline and %" pc
grep -q '^::error' <<<"$out" && fail "a host reason injected a workflow command"
grep -qF 'reason=100% warning ::error::x' <<<"$out" || fail "the host reason is not on one line"$'\n'"$out"
pick GITHUB_EVENT_NAME=pull_request POOL_PR_HEAD_REPO=$'evil/r\n::error::x%'
want "a head repo with a newline and %" github
grep -q '^::error' <<<"$out" && fail "a head repo injected a workflow command"
says "escaped" warning "(evil/r ::error::x%25)"
[[ "$(grep -c '' "$tmp/out")" == 4 ]] || fail "GITHUB_OUTPUT is not four lines: $(cat "$tmp/out")"

echo "pool-pick: $cases cases passed (rules 1-7, fixtures, token handling, outputs)"
