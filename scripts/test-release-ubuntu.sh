#!/usr/bin/env bash
# Offline integration tests: fake gh/notifications, real Bash + GNU timeout.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/release-ubuntu.sh
source "$root/scripts/release-ubuntu.sh"
[[ $(urlencode 'feature/中文') == 'feature%2F%E4%B8%AD%E6%96%87' ]]
[[ $(urlencode 'main') == main ]]
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/powershell.exe" <<'MOCK'
#!/usr/bin/env bash
printf '%s | %s\n' "$RELEASE_UBUNTU_NOTIFY_TITLE" "$RELEASE_UBUNTU_NOTIFY_BODY" >> "$MOCK_STATE/notifications"
MOCK
cat > "$tmp/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$MOCK_STATE/calls"
case "$1 $2" in
  'run list')
    if [[ -f $MOCK_STATE/dispatched ]]; then echo 987; fi ;;
  'workflow run')
    echo yes >> "$MOCK_STATE/dispatched"
    if [[ $SCENARIO == ambiguous ]]; then echo 'lost response' >&2; exit 1; fi ;;
  'api repos/demo/reader/commits/main') printf '%040d\n' 1 ;;
  'api repos/demo/reader/actions/workflows/release-ubuntu.yml') echo active ;;
  'api repos/demo/reader/actions/runs/987')
    n=0; [[ ! -f $MOCK_STATE/polls ]] || n=$(cat "$MOCK_STATE/polls")
    n=$((n+1)); echo "$n" > "$MOCK_STATE/polls"
    status=completed; result=success; path=.github/workflows/release-ubuntu.yml
    case "$SCENARIO" in
      failure) result=failure ;;
      cancelled) result=cancelled ;;
      wrong) path=.github/workflows/other.yml ;;
      timeout) status=in_progress; result=pending ;;
      queued) if ((n == 1)); then status=queued; result=pending; elif ((n == 2)); then status=in_progress; result=pending; fi ;;
      retry) if ((n <= 2)); then echo 'PARTIAL INVALID JSON'; echo '503 temporary failure' >&2; exit 1; fi ;;
    esac
    printf '%s\t%s\thttps://github.com/demo/reader/actions/runs/987\t%s\tworkflow_dispatch\n' "$status" "$result" "$path" ;;
  *) echo "Unexpected mock command: $*" >&2; exit 1 ;;
esac
MOCK
cat > "$tmp/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$MOCK_STATE/git-calls"
case "$1" in
  status) if [[ $SCENARIO == dirty ]]; then echo ' M src/App.vue'; fi ;;
  symbolic-ref) echo main ;;
  rev-parse) printf '%040d\n' 1 ;;
  remote)
    case "$SCENARIO" in
      wrongrepo) echo https://github.com/other/reader.git ;;
      multiurl) printf '%s\n' https://github.com/demo/reader.git https://github.com/other/reader.git ;;
      *) echo https://github.com/demo/reader.git ;;
    esac ;;
  -c)
    [[ $* == '-c push.followTags=false -c push.recurseSubmodules=no push --porcelain -- https://github.com/demo/reader.git 0000000000000000000000000000000000000001:refs/heads/main' ]] || exit 99
    n=0; [[ ! -f $MOCK_STATE/push-count ]] || n=$(cat "$MOCK_STATE/push-count")
    n=$((n+1)); echo "$n" > "$MOCK_STATE/push-count"
    if [[ $SCENARIO == pushretry && $n == 1 ]]; then echo 'PARTIAL PUSH'; exit 1; fi
    if [[ $SCENARIO == pushreject ]]; then echo 'non-fast-forward' >&2; exit 1; fi
    echo 'push OK' ;;
  *) echo "Unexpected git command: $*" >&2; exit 99 ;;
esac
MOCK
chmod +x "$tmp/bin/git" "$tmp/bin/gh" "$tmp/bin/powershell.exe"
run_case() {
  local scenario=$1 expected=$2 rc count; shift 2
  mkdir -p "$tmp/$scenario"
  if env PATH="$tmp/bin:$PATH" MOCK_STATE="$tmp/$scenario" SCENARIO="$scenario" \
    RETRY_ATTEMPTS=3 RETRY_DELAY_SECONDS=1 POLL_INTERVAL_SECONDS=1 \
    REQUEST_TIMEOUT_SECONDS=5 DISCOVERY_TIMEOUT_SECONDS=5 MONITOR_TIMEOUT_SECONDS=10 \
    bash "$root/scripts/release-ubuntu.sh" --repo demo/reader "$@" >"$tmp/$scenario/log" 2>&1; then rc=0; else rc=$?; fi
  if [[ $rc != "$expected" ]]; then cat "$tmp/$scenario/log"; echo "FAIL $scenario: $rc != $expected"; exit 1; fi
  count=$(wc -l < "$tmp/$scenario/notifications")
  [[ $count -eq 1 ]] || { echo "FAIL $scenario: expected one notification"; exit 1; }
  echo "PASS $scenario (exit $rc, one notification)"
}
run_case success 0 --run-id 987
run_case queued 0 --run-id 987
run_case retry 0 --run-id 987
grep -q '打包成功' "$tmp/retry/notifications"
! grep -q 'PARTIAL INVALID JSON' "$tmp/retry/log"
run_case failure 1 --run-id 987
run_case cancelled 2 --run-id 987
run_case wrong 1 --run-id 987
run_case dispatch 0 --tag v0.1.0-lite.1 --ref main --allow-remote
run_case ambiguous 0 --tag v0.1.0-lite.1 --ref main --allow-remote
[[ $(wc -l < "$tmp/ambiguous/dispatched") -eq 1 ]]
[[ $(wc -l < "$tmp/dispatch/dispatched") -eq 1 ]]
mkdir -p "$tmp/resume"; touch "$tmp/resume/dispatched"
run_case resume 0 --request-id existing-request
! grep -q '^workflow run' "$tmp/resume/calls"
run_case timeout 124 --run-id 987
grep -q '超时' "$tmp/timeout/notifications"
! grep -q 'run cancel' "$tmp/timeout/calls"
run_case push 0 --ref main --tag v0.1.0-lite.1
[[ $(cat "$tmp/push/push-count") -eq 1 ]]
run_case pushretry 0 --ref main --tag v0.1.0-lite.1
[[ $(cat "$tmp/pushretry/push-count") -eq 2 ]]
! grep -q 'PARTIAL PUSH' "$tmp/pushretry/log"
run_case dirty 1 --ref main --tag v0.1.0-lite.1
run_case wrongrepo 1 --ref main --tag v0.1.0-lite.1
run_case multiurl 1 --ref main --tag v0.1.0-lite.1
run_case otherbranch 1 --ref other --tag v0.1.0-lite.1
run_case pushreject 1 --ref main --tag v0.1.0-lite.1
for scenario in dirty wrongrepo multiurl otherbranch; do
  [[ ! -f $tmp/$scenario/push-count && ! -f $tmp/$scenario/dispatched ]]
done
[[ ! -f $tmp/pushreject/dispatched ]]
for scenario in dispatch resume success; do [[ ! -f $tmp/$scenario/git-calls ]]; done
echo 'All 17 offline release-ubuntu tests passed. No real push, GitHub request or popup was made.'
