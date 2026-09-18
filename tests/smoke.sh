#!/usr/bin/env bash
# Smoke test for the pocketbase-starter image, run the way Dockhold runs it:
# user 1001, every capability dropped, no privilege escalation, 256 MB of
# memory and no swap, App storage mounted at /data owned root:1001 with mode
# 2770, a fixed PORT, generated secrets, and no outbound network. Every
# assertion goes through PocketBase's own API from a curl helper on the same
# isolated network. Nothing upstream is mocked.
#
# Usage: tests/smoke.sh <image>
# Needs: docker, jq, bash 4 or newer. Exits non-zero if any case fails.
# Prints one PASS or FAIL line per case, INFO lines for measurements, and the
# container log after a failure.
set -euo pipefail

IMAGE=${1:?usage: tests/smoke.sh <image>}
CURL_IMAGE=curlimages/curl:8.16.0
HELPER_IMAGE=alpine:3.24
RUN="pbsmoke-$$-$RANDOM"
NET="$RUN-net"
APP="$RUN-app"
CURL="$RUN-curl"
PORT=8090
URL="http://pb:$PORT"
BASE=$(mktemp -d "${TMPDIR:-/tmp}/pbsmoke.XXXXXX")
SEED_TITLE="Hello from Dockhold"
STORAGE_LINE="This app keeps its data on App storage. Turn on App storage in the Size tab and redeploy."

PASS_COUNT=0
FAIL_COUNT=0
HTTP_CODE=000
HTTP_BODY=""

pass() { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() {
  echo "FAIL  $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "----- container log ($APP) -----"
  docker logs "$APP" 2>&1 | tail -n 40 || true
  echo "-------------------------------"
}
report() { if [ "$2" = true ]; then pass "$1"; else fail "$1"; fi; }
info() { echo "INFO  $1"; }

cleanup() {
  docker rm -f "$APP" "$CURL" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  # Data dirs are root-owned after the platform-shaped chown, so a root
  # container removes their contents; the base dir itself is ours.
  docker run --rm -v "$BASE:/b" "$HELPER_IMAGE" sh -c 'rm -rf /b/* /b/.[!.]* 2>/dev/null; true' >/dev/null 2>&1 || true
  rmdir "$BASE" 2>/dev/null || true
}
trap cleanup EXIT

rand_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

# A fresh host dir shaped like the platform's App storage mount.
new_datadir() {
  local d
  d=$(mktemp -d "$BASE/data.XXXXXX")
  docker run --rm -v "$d:/data" "$HELPER_IMAGE" sh -c 'chown 0:1001 /data && chmod 2770 /data' >/dev/null
  echo "$d"
}

# start_app [docker run args...]: the fixed runtime shape plus whatever the
# case adds (mounts, DATA_DIR, secrets).
start_app() {
  docker rm -f "$APP" >/dev/null 2>&1 || true
  docker run -d --name "$APP" --network "$NET" --network-alias pb \
    --user 1001:1001 --cap-drop ALL --security-opt no-new-privileges \
    --memory 256m --memory-swap 256m \
    -e "PORT=$PORT" "$@" "$IMAGE" >/dev/null 2>"$BASE/run.err" || { cat "$BASE/run.err"; return 1; }
}

stop_app() { docker stop -t 15 "$APP" >/dev/null 2>&1 || true; docker rm -f "$APP" >/dev/null 2>&1 || true; }

app_running() { [ "$(docker inspect -f '{{.State.Running}}' "$APP" 2>/dev/null)" = true ]; }
app_logs() { docker logs "$APP" 2>&1 || true; }

# Waits until /api/health answers or the container exits. Returns 1 on either
# failure so a case cannot pass by accident on a dead container.
wait_health() {
  local i
  for i in $(seq 1 120); do
    app_running || return 1
    if docker exec "$CURL" curl -sf -m 3 -o /dev/null "$URL/api/health" 2>/dev/null; then return 0; fi
    sleep 0.5
  done
  return 1
}

# Prints the exit code once the container has exited, or "running".
wait_exit() {
  local i
  for i in $(seq 1 60); do
    if ! app_running; then docker inspect -f '{{.State.ExitCode}}' "$APP"; return 0; fi
    sleep 0.25
  done
  echo running
}

# http METHOD PATH BODY TOKEN [extra curl args...]; sets HTTP_CODE, HTTP_BODY.
http() {
  local method=$1 path=$2 body=$3 token=$4
  shift 4
  local args=(-s -m 20 -X "$method" -w $'\n%{http_code}' -H 'Content-Type: application/json')
  if [ -n "$token" ]; then args+=(-H "Authorization: $token"); fi
  if [ -n "$body" ]; then args+=(--data-binary "$body"); fi
  local out
  if out=$(docker exec "$CURL" curl "${args[@]}" "$@" "$URL$path" 2>/dev/null); then
    HTTP_CODE=${out##*$'\n'}
    HTTP_BODY=${out%$'\n'*}
  else
    HTTP_CODE=000
    HTTP_BODY=""
  fi
}

# login EMAIL PASSWORD: prints a token, or nothing when login is refused.
login() {
  http POST /api/collections/_superusers/auth-with-password \
    "$(jq -cn --arg e "$1" --arg p "$2" '{identity:$e,password:$p}')" ""
  if [ "$HTTP_CODE" = 200 ]; then printf '%s' "$HTTP_BODY" | jq -r '.token // empty'; fi
}

superuser_count() { # TOKEN
  http GET "/api/collections/_superusers/records?perPage=1" "" "$1"
  printf '%s' "$HTTP_BODY" | jq -r '.totalItems // -1'
}

notes_total() {
  http GET "/api/collections/notes/records?perPage=1" "" ""
  printf '%s' "$HTTP_BODY" | jq -r '.totalItems // -1'
}

seed_count() {
  http GET "/api/collections/notes/records?perPage=500" "" ""
  printf '%s' "$HTTP_BODY" | jq -r --arg t "$SEED_TITLE" '[.items[]? | select(.title == $t)] | length'
}

token_works() { # TOKEN -> prints the status of a protected listing
  http GET "/api/collections/_superusers/records?perPage=1" "" "$1"
  printf '%s' "$HTTP_CODE"
}

# A refused-start case: the container must exit 1 with exactly one log line.
expect_one_line_refusal() { # NAME EXPECTED_LINE [docker run args...]
  local name=$1 expected=$2
  shift 2
  start_app "$@"
  local code lines ok=true
  code=$(wait_exit)
  lines=$(app_logs | wc -l | tr -d ' ')
  [ "$code" = 1 ] || { ok=false; echo "  exit code: $code (want 1)"; }
  [ "$lines" = 1 ] || { ok=false; echo "  log lines: $lines (want 1)"; }
  [ "$(app_logs)" = "$expected" ] || { ok=false; echo "  log line differs from the expected refusal"; }
  report "$name" $ok
}

# ---------------------------------------------------------------------------
echo "==== pocketbase-starter smoke test: $IMAGE"
docker network create --internal "$NET" >/dev/null
docker run -d --name "$CURL" --network "$NET" --entrypoint sh "$CURL_IMAGE" -c 'sleep 100000' >/dev/null
PB_VERSION=$(docker run --rm --entrypoint /app/pocketbase "$IMAGE" --version)
PB_VERSION=${PB_VERSION##* }
info "pinned PocketBase version: $PB_VERSION"

EMAIL_A="owner-$(rand_hex 4)@example.com"
EMAIL_B="second-$(rand_hex 4)@example.com"
PASS_1="pw1-$(rand_hex 8)"
PASS_2="pw2-$(rand_hex 8)"
PASS_3="pw3-$(rand_hex 8)"
SECRETS_A=(-e "PB_ADMIN_EMAIL=$EMAIL_A" -e "PB_ADMIN_PASSWORD=$PASS_1")

# ---------------------------------------------------------------------------
echo "==== Storage refusals"
D_RO=$(new_datadir)
expect_one_line_refusal "DATA_DIR unset: one line, exit 1" "$STORAGE_LINE" "${SECRETS_A[@]}"
expect_one_line_refusal "DATA_DIR empty: one line, exit 1" "$STORAGE_LINE" -e DATA_DIR= "${SECRETS_A[@]}"
expect_one_line_refusal "DATA_DIR missing path: one line, exit 1" "$STORAGE_LINE" -e DATA_DIR=/nowhere "${SECRETS_A[@]}"
expect_one_line_refusal "DATA_DIR relative path: one line, exit 1" "$STORAGE_LINE" -e DATA_DIR=data "${SECRETS_A[@]}"
expect_one_line_refusal "DATA_DIR read-only mount: one line, exit 1" "$STORAGE_LINE" -e DATA_DIR=/data -v "$D_RO:/data:ro" "${SECRETS_A[@]}"

# ---------------------------------------------------------------------------
echo "==== Secret refusals"
D_SEC=$(new_datadir)
secret_refusal() { # NAME MUST_CONTAIN MUST_NOT_CONTAIN [docker run args...]
  local name=$1 must=$2 mustnot=$3
  shift 3
  start_app -e DATA_DIR=/data -v "$D_SEC:/data" "$@"
  local code ok=true log
  code=$(wait_exit)
  log=$(app_logs)
  [ "$code" = 1 ] || { ok=false; echo "  exit code: $code (want 1)"; }
  [ "$(printf '%s\n' "$log" | wc -l | tr -d ' ')" = 1 ] || { ok=false; echo "  more than one log line"; }
  printf '%s' "$log" | grep -qF "$must" || { ok=false; echo "  log does not name $must"; }
  printf '%s' "$log" | grep -qF "Secrets tab" || { ok=false; echo "  log does not say where to fix it"; }
  if [ -n "$mustnot" ] && printf '%s' "$log" | grep -qF "$mustnot"; then ok=false; echo "  log contains a secret value"; fi
  if printf '%s' "$log" | grep -q "Server started"; then ok=false; echo "  listener opened"; fi
  report "$name" $ok
}
secret_refusal "PB_ADMIN_EMAIL missing: names it, exit 1, no value, no listener" PB_ADMIN_EMAIL "$PASS_1" -e "PB_ADMIN_PASSWORD=$PASS_1"
secret_refusal "PB_ADMIN_PASSWORD empty: names it, exit 1, no value, no listener" PB_ADMIN_PASSWORD "$EMAIL_A" -e "PB_ADMIN_EMAIL=$EMAIL_A" -e PB_ADMIN_PASSWORD=
secret_refusal "both secrets missing: names both, exit 1, no listener" "PB_ADMIN_EMAIL and PB_ADMIN_PASSWORD" ""

# ---------------------------------------------------------------------------
echo "==== First start"
D_MAIN=$(new_datadir)
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" "${SECRETS_A[@]}"
report "first start: /api/health answers 200" "$(wait_health && echo true || echo false)"

http GET /_/ "" ""
ok=true
[ "$HTTP_CODE" = 200 ] || ok=false
printf '%s' "$HTTP_BODY" | grep -qi '<html' || ok=false
report "first start: /_/ returns HTML" $ok

TOK_A1=$(login "$EMAIL_A" "$PASS_1")
report "first start: auth-with-password returns a token" "$([ -n "$TOK_A1" ] && echo true || echo false)"

http POST /api/collections/_superusers/records \
  '{"email":"stranger@example.com","password":"stranger12345","passwordConfirm":"stranger12345"}' ""
report "first start: unauthenticated superuser creation refused ($HTTP_CODE)" "$([[ "$HTTP_CODE" =~ ^4 ]] && echo true || echo false)"

report "first start: exactly one superuser" "$([ "$(superuser_count "$TOK_A1")" = 1 ] && echo true || echo false)"

http GET /api/collections/notes/records "" ""
ok=true
[ "$HTTP_CODE" = 200 ] || ok=false
[ "$(printf '%s' "$HTTP_BODY" | jq -r '.totalItems')" = 1 ] || ok=false
[ "$(printf '%s' "$HTTP_BODY" | jq -r '.items[0].title')" = "$SEED_TITLE" ] || ok=false
report "first start: notes seed record readable without a token" $ok

http POST /api/collections/notes/records '{"title":"stranger"}' ""
report "first start: unauthenticated note creation refused ($HTTP_CODE)" "$([[ "$HTTP_CODE" =~ ^4 ]] && echo true || echo false)"

ok=true
[ "$(docker exec "$APP" stat -c %a /data/.dockhold 2>/dev/null)" = 700 ] || { ok=false; echo "  marker dir mode: $(docker exec "$APP" stat -c %a /data/.dockhold 2>&1)"; }
[ "$(docker exec "$APP" cat /data/.dockhold/template 2>/dev/null)" = "pocketbase-starter $PB_VERSION" ] || { ok=false; echo "  marker content: $(docker exec "$APP" cat /data/.dockhold/template 2>&1)"; }
report "first start: .dockhold/template marker, directory mode 700" $ok

ok=true
if app_logs | grep -qF "$EMAIL_A"; then ok=false; echo "  log echoes the admin email"; fi
if app_logs | grep -qF "$PASS_1"; then ok=false; echo "  log echoes the admin password"; fi
report "first start: log never echoes the bound values" $ok

# ---------------------------------------------------------------------------
echo "==== Second start on the same storage"
stop_app
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" "${SECRETS_A[@]}"
ok=true
wait_health || ok=false
TOK_A2=$(login "$EMAIL_A" "$PASS_1")
[ -n "$TOK_A2" ] || ok=false
report "second start: same admin logs in" $ok
report "second start: still exactly one superuser" "$([ "$(superuser_count "$TOK_A2")" = 1 ] && echo true || echo false)"
ok=true
[ "$(notes_total)" = 1 ] || ok=false
[ "$(seed_count)" = 1 ] || ok=false
report "second start: migration did not re-run, exactly one seed record" $ok
info "session after a plain restart with unchanged secrets: token from before the restart now gets $(token_works "$TOK_A1") (403 = signed out)"

# ---------------------------------------------------------------------------
echo "==== Password rotated on the Secrets tab"
stop_app
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" -e "PB_ADMIN_EMAIL=$EMAIL_A" -e "PB_ADMIN_PASSWORD=$PASS_2"
ok=true
wait_health || ok=false
TOK_A3=$(login "$EMAIL_A" "$PASS_2")
[ -n "$TOK_A3" ] || { ok=false; echo "  new password refused"; }
[ -z "$(login "$EMAIL_A" "$PASS_1")" ] || { ok=false; echo "  old password still accepted"; }
report "password rotated: new password logs in, old does not" $ok
info "session after a password rotation: token from before now gets $(token_works "$TOK_A2") (403 = signed out)"

# ---------------------------------------------------------------------------
echo "==== Password changed inside PocketBase"
http GET "/api/collections/_superusers/records?perPage=50" "" "$TOK_A3"
ID_A=$(printf '%s' "$HTTP_BODY" | jq -r --arg e "$EMAIL_A" '.items[] | select(.email == $e) | .id')
http PATCH "/api/collections/_superusers/records/$ID_A" \
  "$(jq -cn --arg p "$PASS_3" '{password:$p,passwordConfirm:$p}')" "$TOK_A3"
ok=true
[ "$HTTP_CODE" = 200 ] || { ok=false; echo "  PATCH returned $HTTP_CODE"; }
[ -n "$(login "$EMAIL_A" "$PASS_3")" ] || { ok=false; echo "  control failed: changed password does not log in"; }
info "session after a password change inside PocketBase: the token used for the change now gets $(token_works "$TOK_A3") (403 = signed out)"
stop_app
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" -e "PB_ADMIN_EMAIL=$EMAIL_A" -e "PB_ADMIN_PASSWORD=$PASS_2"
wait_health || ok=false
[ -n "$(login "$EMAIL_A" "$PASS_2")" ] || { ok=false; echo "  Secrets tab password does not log in after restart"; }
[ -z "$(login "$EMAIL_A" "$PASS_3")" ] || { ok=false; echo "  password changed inside PocketBase survived the restart"; }
report "password changed inside PocketBase: reverted to the Secrets tab value on restart" $ok

# ---------------------------------------------------------------------------
echo "==== PB_ADMIN_EMAIL changed"
stop_app
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" -e "PB_ADMIN_EMAIL=$EMAIL_B" -e "PB_ADMIN_PASSWORD=$PASS_2"
ok=true
wait_health || ok=false
TOK_B=$(login "$EMAIL_B" "$PASS_2")
[ -n "$TOK_B" ] || { ok=false; echo "  new email does not log in"; }
[ "$(superuser_count "$TOK_B")" = 2 ] || { ok=false; echo "  superuser count: $(superuser_count "$TOK_B") (want 2)"; }
[ -n "$(login "$EMAIL_A" "$PASS_2")" ] || { ok=false; echo "  previous admin no longer logs in"; }
report "email changed: two superusers, the previous one still logs in" $ok

# ---------------------------------------------------------------------------
echo "==== Managed superuser deleted inside PocketBase"
TOK_A4=$(login "$EMAIL_A" "$PASS_2")
http GET "/api/collections/_superusers/records?perPage=50" "" "$TOK_A4"
ID_B=$(printf '%s' "$HTTP_BODY" | jq -r --arg e "$EMAIL_B" '.items[] | select(.email == $e) | .id')
http DELETE "/api/collections/_superusers/records/$ID_B" "" "$TOK_A4"
ok=true
[ "$HTTP_CODE" = 204 ] || { ok=false; echo "  DELETE returned $HTTP_CODE"; }
[ -z "$(login "$EMAIL_B" "$PASS_2")" ] || { ok=false; echo "  control failed: deleted admin still logs in"; }
stop_app
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" -e "PB_ADMIN_EMAIL=$EMAIL_B" -e "PB_ADMIN_PASSWORD=$PASS_2"
wait_health || ok=false
TOK_B=$(login "$EMAIL_B" "$PASS_2")
[ -n "$TOK_B" ] || { ok=false; echo "  managed admin not recreated"; }
[ "$(superuser_count "$TOK_B")" = 2 ] || { ok=false; echo "  superuser count after recreate: $(superuser_count "$TOK_B") (want 2)"; }
report "managed superuser deleted: recreated on restart, logs in" $ok

# ---------------------------------------------------------------------------
echo "==== Invalid replacement credentials"
stop_app
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" -e "PB_ADMIN_EMAIL=notanemail" -e "PB_ADMIN_PASSWORD=$PASS_2"
ok=true
code=$(wait_exit)
log=$(app_logs)
[ "$code" = 1 ] || { ok=false; echo "  exit code: $code (want 1)"; }
printf '%s' "$log" | grep -qi "invalid email" || { ok=false; echo "  upstream reason missing"; }
if printf '%s' "$log" | grep -qF "$PASS_2"; then ok=false; echo "  password echoed"; fi
if printf '%s' "$log" | grep -q "Server started"; then ok=false; echo "  listener opened"; fi
report "invalid email: exit 1 with upstream's reason, no value printed" $ok

start_app -e DATA_DIR=/data -v "$D_MAIN:/data" -e "PB_ADMIN_EMAIL=$EMAIL_B" -e "PB_ADMIN_PASSWORD=q7z"
ok=true
code=$(wait_exit)
log=$(app_logs)
[ "$code" = 1 ] || { ok=false; echo "  exit code: $code (want 1)"; }
printf '%s' "$log" | grep -qi "at least 8" || { ok=false; echo "  upstream reason missing"; }
if printf '%s' "$log" | grep -qF "q7z"; then ok=false; echo "  password echoed"; fi
if printf '%s' "$log" | grep -qF "$EMAIL_B"; then ok=false; echo "  email echoed"; fi
if printf '%s' "$log" | grep -q "Server started"; then ok=false; echo "  listener opened"; fi
report "3-character password: exit 1 with upstream's reason, no value printed" $ok

start_app -e DATA_DIR=/data -v "$D_MAIN:/data" -e "PB_ADMIN_EMAIL=$EMAIL_B" -e "PB_ADMIN_PASSWORD=$PASS_2"
ok=true
wait_health || ok=false
TOK_B=$(login "$EMAIL_B" "$PASS_2")
[ -n "$TOK_B" ] || ok=false
report "previous valid values restored: logs in again" $ok

# ---------------------------------------------------------------------------
echo "==== Forged proxy headers"
FORGED=(-H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-Host: attacker.example' -H 'Host: attacker.example')
http GET "/api/collections/_superusers/records" "" "" "${FORGED[@]}"
ok=true
[[ "$HTTP_CODE" =~ ^4 ]] || { ok=false; echo "  listing superusers with forged headers returned $HTTP_CODE"; }
http POST /api/collections/_superusers/records \
  '{"email":"forged@example.com","password":"forged1234567","passwordConfirm":"forged1234567"}' "" "${FORGED[@]}"
[[ "$HTTP_CODE" =~ ^4 ]] || { ok=false; echo "  creating a superuser with forged headers returned $HTTP_CODE"; }
http POST /api/collections/notes/records '{"title":"forged"}' "" "${FORGED[@]}"
[[ "$HTTP_CODE" =~ ^4 ]] || { ok=false; echo "  creating a note with forged headers returned $HTTP_CODE"; }
report "forged X-Forwarded-* and Host headers confer nothing" $ok

# ---------------------------------------------------------------------------
echo "==== 50 records with memory measurement"
MEM_FILE="$BASE/mem.txt"
CUR_FILE="$BASE/mem-current.txt"
( while docker stats --no-stream --format '{{.MemUsage}}' "$APP" 2>/dev/null; do sleep 0.2; done ) >"$MEM_FILE" 2>/dev/null &
MEM_PID=$!
( while docker exec "$APP" cat /sys/fs/cgroup/memory.current 2>/dev/null; do sleep 0.1; done ) >"$CUR_FILE" 2>/dev/null &
CUR_PID=$!
BEFORE=$(notes_total)
created=0
for i in $(seq 1 50); do
  http POST /api/collections/notes/records "{\"title\":\"load $i\",\"body\":\"record $i of 50\"}" "$TOK_B"
  [ "$HTTP_CODE" = 200 ] && created=$((created + 1))
done
kill "$MEM_PID" "$CUR_PID" 2>/dev/null || true
wait "$MEM_PID" "$CUR_PID" 2>/dev/null || true
ok=true
[ "$created" = 50 ] || { ok=false; echo "  created $created of 50"; }
[ "$(notes_total)" = $((BEFORE + 50)) ] || { ok=false; echo "  total $(notes_total), want $((BEFORE + 50))"; }
report "50 records created and counted" $ok
PEAK_STATS=$(awk '{v=$1; u=v; gsub(/[0-9.]/,"",u); sub(/[A-Za-z]+$/,"",v); m=(u=="GiB")?v*1024:(u=="MiB")?v:(u=="KiB")?v/1024:(u=="B")?v/1048576:v; if(m>max)max=m} END{printf "%.1f", max+0}' "$MEM_FILE")
PEAK_CURRENT=$(sort -n "$CUR_FILE" 2>/dev/null | tail -1)
PEAK_CGROUP=$(docker exec "$APP" cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo "")
info "peak memory during the 50-record case at --memory 256m: ${PEAK_STATS} MiB (docker stats, $(wc -l <"$MEM_FILE" | tr -d ' ') samples)${PEAK_CURRENT:+; cgroup memory.current sampled at 10 Hz: $((PEAK_CURRENT / 1048576)) MiB over $(wc -l <"$CUR_FILE" | tr -d ' ') samples}${PEAK_CGROUP:+; cgroup memory.peak since this start: $((PEAK_CGROUP / 1048576)) MiB}"

# ---------------------------------------------------------------------------
echo "==== SIGKILL mid-write"
ACK_FILE="$BASE/ack.txt"
: >"$ACK_FILE"
BEFORE=$(notes_total)
(
  for i in $(seq 1 50); do
    http POST /api/collections/notes/records "{\"title\":\"kill $i\"}" "$TOK_B"
    if [ "$HTTP_CODE" = 200 ]; then printf '%s' "$HTTP_BODY" | jq -r '.id' >>"$ACK_FILE"; else break; fi
  done
) &
LOOP_PID=$!
for i in $(seq 1 300); do
  [ "$(wc -l <"$ACK_FILE" | tr -d ' ')" -ge 20 ] && break
  sleep 0.1
done
docker kill -s KILL "$APP" >/dev/null
wait "$LOOP_PID" 2>/dev/null || true
ACKED=$(wc -l <"$ACK_FILE" | tr -d ' ')
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" -e "PB_ADMIN_EMAIL=$EMAIL_B" -e "PB_ADMIN_PASSWORD=$PASS_2"
ok=true
wait_health || { ok=false; echo "  not healthy after SIGKILL"; }
http GET "/api/collections/notes/records?perPage=500" "" ""
[ "$HTTP_CODE" = 200 ] || { ok=false; echo "  listing returned $HTTP_CODE"; }
PRESENT=0
while read -r id; do
  [ -n "$id" ] || continue
  if printf '%s' "$HTTP_BODY" | jq -e --arg id "$id" '.items[] | select(.id == $id)' >/dev/null; then PRESENT=$((PRESENT + 1)); fi
done <"$ACK_FILE"
[ "$PRESENT" = "$ACKED" ] || { ok=false; echo "  $PRESENT of $ACKED acknowledged records present"; }
TOTAL=$(printf '%s' "$HTTP_BODY" | jq -r '.totalItems')
[ "$TOTAL" -ge $((BEFORE + ACKED)) ] || { ok=false; echo "  total $TOTAL below $((BEFORE + ACKED))"; }
report "SIGKILL mid-write: healthy, all $ACKED acknowledged records present (total $TOTAL)" $ok
TOK_B=$(login "$EMAIL_B" "$PASS_2")
report "SIGKILL mid-write: admin still logs in" "$([ -n "$TOK_B" ] && echo true || echo false)"

# ---------------------------------------------------------------------------
echo "==== Interrupted first start"
for delay in 0.15 0.5 1.0; do
  D_INT=$(new_datadir)
  start_app -e DATA_DIR=/data -v "$D_INT:/data" "${SECRETS_A[@]}"
  sleep "$delay"
  docker kill -s KILL "$APP" >/dev/null 2>&1 || true
  if app_logs | grep -q "Server started"; then phase="after the listener opened"; else phase="before the listener opened"; fi
  start_app -e DATA_DIR=/data -v "$D_INT:/data" "${SECRETS_A[@]}"
  ok=true
  wait_health || { ok=false; echo "  not healthy after interrupted first start"; }
  TOK_I=$(login "$EMAIL_A" "$PASS_1")
  [ -n "$TOK_I" ] || { ok=false; echo "  admin does not log in"; }
  [ "$(superuser_count "$TOK_I")" = 1 ] || { ok=false; echo "  superuser count $(superuser_count "$TOK_I") (want 1)"; }
  [ "$(seed_count)" = 1 ] || { ok=false; echo "  seed count $(seed_count) (want 1)"; }
  report "interrupted first start (KILL at ${delay}s, $phase): healthy, one superuser, one seed" $ok
  stop_app
done

# ---------------------------------------------------------------------------
echo "==== Disk full (3 MB tmpfs as App storage, owned root:1001 mode 2770)"
start_app --tmpfs /data:rw,size=3m,mode=2770,uid=0,gid=1001 -e DATA_DIR=/data -e "PB_ADMIN_EMAIL=$EMAIL_B" -e "PB_ADMIN_PASSWORD=$PASS_2"
ok=true
wait_health || { ok=false; echo "  not healthy on tmpfs"; }
TOK_F=$(login "$EMAIL_B" "$PASS_2")
[ -n "$TOK_F" ] || { ok=false; echo "  login failed on tmpfs"; }
# Text fields accept at most 5000 characters by default, so each record is
# about 5 KB; the loop runs inside the helper to avoid one docker exec per
# record and stops at the first refused create.
FILL_FILE="$BASE/fill.txt"
FILL_RAW="$BASE/fill-raw.txt"
BIG=$(head -c 5000 /dev/zero | tr '\0' 'a')
docker exec -e "TOK=$TOK_F" -e "BIG=$BIG" -e "URL=$URL" "$CURL" sh -c '
  i=0
  while [ $i -lt 3000 ]; do
    i=$((i + 1))
    out=$(curl -s -m 20 -X POST -w "\n%{http_code}" -H "Authorization: $TOK" -H "Content-Type: application/json" \
      --data-binary "{\"title\":\"fill $i\",\"body\":\"$BIG\"}" "$URL/api/collections/notes/records")
    code=${out##*
}
    body=${out%
*}
    if [ "$code" = 200 ]; then
      echo "OK $(printf "%s" "$body" | sed -n "s/.*\"id\":\"\([^\"]*\)\".*/\1/p")"
    else
      echo "FAIL $code $body"
      exit 0
    fi
  done
  echo "FAIL 000 never-full"
' >"$FILL_RAW" 2>/dev/null || true
grep '^OK ' "$FILL_RAW" | cut -d' ' -f2 >"$FILL_FILE" || true
FULL_LINE=$(grep '^FAIL ' "$FILL_RAW" | head -1 || true)
FULL_CODE=$(printf '%s' "$FULL_LINE" | cut -d' ' -f2)
FULL_BODY=$(printf '%s' "$FULL_LINE" | cut -d' ' -f3-)
FILLED=$(wc -l <"$FILL_FILE" | tr -d ' ')
[ "$FULL_CODE" != 000 ] || FULL_CODE=""
[ -n "$FULL_CODE" ] || { ok=false; echo "  never hit disk full after $FILLED records"; }
[[ "$FULL_CODE" =~ ^[45] ]] || { ok=false; echo "  first failure code $FULL_CODE"; }
printf '%s' "$FULL_BODY" | jq -e '.message' >/dev/null 2>&1 || { ok=false; echo "  failure body is not a JSON error"; }
app_running || { ok=false; echo "  container died on disk full"; }
http GET /api/health "" ""
[ "$HTTP_CODE" = 200 ] || { ok=false; echo "  health $HTTP_CODE after disk full"; }
report "disk full: clean API error ($FULL_CODE, $(printf '%s' "$FULL_BODY" | jq -r '.message' 2>/dev/null)) after $FILLED records, app still up" $ok
info "disk full: usage $(docker exec "$APP" df -h /data 2>/dev/null | tail -1 | awk '{print $3 " of " $2}'); server log says: $(app_logs | grep -i 'full' | tail -1 | cut -c1-160)"

# Recovery path 1: remove records over the API while the disk is full.
DEL_OK=0
DEL_TRIED=0
for id in $(head -n 3 "$FILL_FILE"); do
  DEL_TRIED=$((DEL_TRIED + 1))
  http DELETE "/api/collections/notes/records/$id" "" "$TOK_F"
  [ "$HTTP_CODE" = 204 ] && DEL_OK=$((DEL_OK + 1))
done
http POST /api/collections/notes/records '{"title":"after cleanup"}' "$TOK_F"
info "disk full: deleting records over the API while full: $DEL_OK of $DEL_TRIED succeeded; a small create afterwards returned $HTTP_CODE"
AFTER_CLEANUP_CODE=$HTTP_CODE
http GET /api/health "" ""
report "disk full: app still healthy after the cleanup attempt" "$([ "$HTTP_CODE" = 200 ] && echo true || echo false)"
EXPECT_REMAINING=$((1 + FILLED - DEL_OK))
[ "$AFTER_CLEANUP_CODE" = 200 ] && EXPECT_REMAINING=$((EXPECT_REMAINING + 1))

# Recovery path 2: the same files on a bigger mount. tmpfs cannot be copied
# with docker cp, so tar them out of the running container while it is idle.
D_BIG=$(new_datadir)
sleep 2
docker exec "$APP" tar -C /data -cf - . | docker run --rm -i -v "$D_BIG:/data" "$HELPER_IMAGE" tar -xf - -C /data
stop_app
start_app -e DATA_DIR=/data -v "$D_BIG:/data" -e "PB_ADMIN_EMAIL=$EMAIL_B" -e "PB_ADMIN_PASSWORD=$PASS_2"
ok=true
wait_health || { ok=false; echo "  not healthy on the bigger mount"; }
[ -n "$(login "$EMAIL_B" "$PASS_2")" ] || { ok=false; echo "  admin does not log in on the bigger mount"; }
GOT=$(notes_total)
[ "$GOT" = "$EXPECT_REMAINING" ] || { ok=false; echo "  notes total $GOT, want $EXPECT_REMAINING"; }
http POST /api/collections/notes/records '{"title":"after move"}' "$(login "$EMAIL_B" "$PASS_2")"
[ "$HTTP_CODE" = 200 ] || { ok=false; echo "  create after move returned $HTTP_CODE"; }
report "disk full: same files on a bigger mount, healthy, $GOT records intact, writes work" $ok
stop_app

# ---------------------------------------------------------------------------
echo "==== Summary: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
