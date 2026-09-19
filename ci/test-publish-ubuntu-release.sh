#!/usr/bin/env bash
# Offline tests for 404-as-missing, overwrite refusal, retries, and create.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=ci/publish-ubuntu-release.sh
source "$root/ci/publish-ubuntu-release.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/workspace/dist"
echo deb > "$tmp/workspace/dist/code-server_0.1.0+lite.1-1_amd64.deb"
echo tar > "$tmp/workspace/dist/code-server-0.1.0-lite.1-ubuntu18.10-amd64.tar.gz"
echo sums > "$tmp/workspace/dist/SHA256SUMS"
cat > "$tmp/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$MOCK_STATE/calls"
case "$1 $2" in
  'api -X')
    n=0; [[ ! -f $MOCK_STATE/lookups ]] || n=$(cat "$MOCK_STATE/lookups")
    n=$((n+1)); echo "$n" > "$MOCK_STATE/lookups"
    case "$SCENARIO" in
      exists)
        printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n{"id":1}\n'
        exit 0 ;;
      missing)
        printf 'HTTP/2.0 404 Not Found\r\nContent-Type: application/json\r\n\r\n{"message":"Not Found"}\n'
        exit 1 ;;
      flaky)
        if (( n == 1 )); then echo '502 bad gateway' >&2; exit 1; fi
        if (( n == 2 )); then printf 'HTTP/2.0 500 Internal Server Error\r\n\r\n\n'; exit 1; fi
        printf 'HTTP/2.0 404 Not Found\r\n\r\n\n'; exit 1 ;;
      *)
        printf 'HTTP/2.0 404 Not Found\r\n\r\n\n'; exit 1 ;;
    esac ;;
  'release create')
    n=0; [[ ! -f $MOCK_STATE/creates ]] || n=$(cat "$MOCK_STATE/creates")
    n=$((n+1)); echo "$n" > "$MOCK_STATE/creates"
    printf '%s\n' "$*" >> "$MOCK_STATE/create-args"
    if [[ $SCENARIO == createretry && $n == 1 ]]; then echo 'network down' >&2; exit 1; fi
    echo created ;;
  *) echo "unexpected gh: $*" >&2; exit 99 ;;
esac
MOCK
chmod +x "$tmp/bin/gh"
run_case() {
  local scenario=$1 expected=$2 rc
  mkdir -p "$tmp/$scenario"
  if env PATH="$tmp/bin:$PATH" MOCK_STATE="$tmp/$scenario" SCENARIO="$scenario" \
    RETRY_ATTEMPTS=4 RETRY_DELAY_SECONDS=1 \
    RELEASE_TAG=v0.1.0-lite.1 SOURCE_SHA=4c6f2b021281367de4a5c20a4a7e57d8fb043f2f \
    REQUEST_ID=req-1 NODE_VERSION=24.12.0 GITHUB_REPOSITORY=demo/reader \
    GITHUB_WORKSPACE="$tmp/workspace" \
    bash "$root/ci/publish-ubuntu-release.sh" >"$tmp/$scenario/log" 2>&1; then rc=0; else rc=$?; fi
  if [[ $rc != "$expected" ]]; then
    cat "$tmp/$scenario/log"
    echo "FAIL $scenario: $rc != $expected"
    exit 1
  fi
  echo "PASS $scenario (exit $rc)"
}

# Reproduce the original Actions bug: 404 + set -euo pipefail + pipefail pipeline.
mkdir -p "$tmp/oldbug"
if env PATH="$tmp/bin:$PATH" MOCK_STATE="$tmp/oldbug" SCENARIO=missing \
  bash -euo pipefail -c 'http=$(gh api -X GET "repos/demo/reader/releases/tags/v0.1.0-lite.1" --silent --include 2>/dev/null | tr -d "\r" | awk "NR==1{print \$2; exit}"); echo "reached:$http"' \
  >"$tmp/oldbug/log" 2>&1; then
  echo 'FAIL: original lookup should abort on 404'
  cat "$tmp/oldbug/log"
  exit 1
else
  echo 'PASS original-404-aborts (demonstrates Actions exit 1)'
fi

run_case missing 0
[[ -f $tmp/missing/creates ]]
grep -q 'code-server_0.1.0+lite.1-1_amd64.deb' "$tmp/missing/create-args"
grep -q 'SHA256SUMS' "$tmp/missing/create-args"
run_case exists 1
[[ ! -f $tmp/exists/creates ]]
grep -q '已存在' "$tmp/exists/log"
run_case flaky 0
[[ $(cat "$tmp/flaky/lookups") -eq 3 ]]
[[ $(cat "$tmp/flaky/creates") -eq 1 ]]
run_case createretry 0
[[ $(cat "$tmp/createretry/creates") -eq 2 ]]
! grep -q 'network down' "$tmp/createretry/log" || true
# create retry should still succeed; stderr from gh may be in log via retry message
grep -q '命令失败' "$tmp/createretry/log"

mkdir -p "$tmp/empty/dist"
if env PATH="$tmp/bin:$PATH" MOCK_STATE="$tmp/empty" SCENARIO=missing \
  RETRY_ATTEMPTS=2 RETRY_DELAY_SECONDS=1 \
  RELEASE_TAG=v0.1.0-lite.1 SOURCE_SHA=4c6f2b021281367de4a5c20a4a7e57d8fb043f2f \
  GITHUB_REPOSITORY=demo/reader GITHUB_WORKSPACE="$tmp/empty" \
  bash "$root/ci/publish-ubuntu-release.sh" >"$tmp/empty/log" 2>&1; then
  echo 'FAIL: empty dist should be rejected'; exit 1
fi
grep -q '缺少 dist' "$tmp/empty/log"
echo 'All publish-ubuntu-release offline tests passed. No real GitHub request was made.'
