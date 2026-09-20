#!/usr/bin/env bash
# Offline integration tests: fake gh/ssh/scp/notifications, real Bash + GNU timeout.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/release-ubuntu.sh
source "$root/scripts/release-ubuntu.sh"
[[ $(urlencode 'feature/中文') == 'feature%2F%E4%B8%AD%E6%96%87' ]]
[[ $(urlencode 'main') == main ]]
[[ $(debian_version_from_tag v0.1.4) == 0.1.4-1 ]]
[[ $(debian_version_from_tag v0.1.0-lite.1) == 0.1.0+lite.1-1 ]]
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
  'run download')
    dir=''
    while (( $# )); do
      case $1 in --dir) dir=$2; shift 2 ;; *) shift ;; esac
    done
    mkdir -p "$dir"
    cp "$MOCK_STATE/payload.deb" "$dir/$PKG_NAME"
    if [[ $SCENARIO == deploytwopkgs ]]; then
      cp "$MOCK_STATE/payload.deb" "$dir/code-server_0.1.0+lite.2-1_amd64.deb"
    fi
    case "$SCENARIO" in
      deploybadsum) printf '%064d  %s\n' 0 "$PKG_NAME" > "$dir/SHA256SUMS" ;;
      deploynoentry) printf '%s  other-0.1.0.tar.gz\n' "$(sha256sum "$MOCK_STATE/payload.deb" | cut -d' ' -f1)" > "$dir/SHA256SUMS" ;;
      *) cp "$MOCK_STATE/SHA256SUMS" "$dir/SHA256SUMS" ;;
    esac ;;
  'workflow run')
    echo yes >> "$MOCK_STATE/dispatched"
    if [[ $SCENARIO == ambiguous ]]; then echo 'lost response' >&2; exit 1; fi ;;
  'api --paginate')
    case "$SCENARIO" in
      deployexpired) : ;;
      deployamb) printf '%s\n%s\n' 'ubuntu-18.10-amd64-v0.1.0-lite.1' 'ubuntu-18.10-amd64-v0.2.0-lite.1' ;;
      deployplain) echo 'ubuntu-18.10-amd64-v0.1.4' ;;
      *) echo 'ubuntu-18.10-amd64-v0.1.0-lite.1' ;;
    esac ;;
  'api repos/demo/reader/commits/main') printf '%040d\n' 1 ;;
  'api repos/demo/reader/actions/workflows/release-ubuntu.yml') echo active ;;
  'api repos/demo/reader/actions/runs/987')
    n=0; [[ ! -f $MOCK_STATE/polls ]] || n=$(cat "$MOCK_STATE/polls")
    n=$((n+1)); echo "$n" > "$MOCK_STATE/polls"
    status=completed; result=success; path=.github/workflows/release-ubuntu.yml
    case "$SCENARIO" in
      failure|failuredeploy) result=failure ;;
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
cat > "$tmp/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$MOCK_STATE/ssh-calls"
args=()
while (( $# )); do
  case $1 in -o) shift 2 ;; *) args+=("$1"); shift ;; esac
done
host=${args[0]:-}
rest=''
for candidate in "${args[@]:1}"; do
  case $candidate in bash|mktemp) rest=$candidate; break ;; esac
done
[[ $host == vultr ]] || { echo "Unexpected ssh host: $host" >&2; exit 98; }
case "$SCENARIO $rest" in
  'deploysshfail mktemp') echo 'ssh: connect to host vultr port 22: Connection refused' >&2; exit 255 ;;
  'deployinstallfail bash') cat >/dev/null; echo 'dpkg: error processing package code-server' >&2; exit 1 ;;
esac
case $rest in
  mktemp) echo '/tmp/code-server-deploy.AbC123' ;;
  bash)
    cat >/dev/null
    if [[ $SCENARIO == dryrun ]]; then
      echo 'Dry run: code-server_0.1.0-lite.1-1_amd64.deb (0.1.0-lite.1-1) verified; backup, install and restart skipped'
    else
      echo 'Deployed code-server 0.1.0-lite.1-1'
      echo 'Backup directory: /root/code-server-backup.tEsT01'
    fi ;;
  *) echo "Unexpected ssh command: $*" >&2; exit 99 ;;
esac
MOCK
cat > "$tmp/bin/scp" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$MOCK_STATE/scp-calls"
[[ $SCENARIO != deployscpfail ]] || { echo 'scp: connection closed' >&2; exit 1; }
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
chmod +x "$tmp/bin/git" "$tmp/bin/gh" "$tmp/bin/ssh" "$tmp/bin/scp" "$tmp/bin/powershell.exe"

# Every scenario gets a payload whose checksum matches its expected SHA256SUMS line.
make_payload() {
  local state=$1 name=${PKG_NAME:-code-server_0.1.0+lite.1-1_amd64.deb}
  printf 'fake deb payload for %s\n' "$(basename "$state")" > "$state/payload.deb"
  # Git for Windows prints "hash *file" in binary mode, GNU prints "hash  file".
  (cd "$state" && sha256sum payload.deb | sed -E "s/[ *]payload\.deb$/  $name/" > SHA256SUMS)
}

run_case() {
  local scenario=$1 expected_rc=$2 expected_notifications=$3 rc count; shift 3
  mkdir -p "$tmp/$scenario"
  make_payload "$tmp/$scenario"
  if env PATH="$tmp/bin:$PATH" MOCK_STATE="$tmp/$scenario" SCENARIO="$scenario" \
    RETRY_ATTEMPTS=3 RETRY_DELAY_SECONDS=1 POLL_INTERVAL_SECONDS=1 \
    REQUEST_TIMEOUT_SECONDS=5 DISCOVERY_TIMEOUT_SECONDS=5 MONITOR_TIMEOUT_SECONDS=10 \
    DEPLOY_TIMEOUT_SECONDS=10 DEPLOY_DRY_RUN=${DRY_RUN:-0} \
    PKG_NAME=${PKG_NAME:-code-server_0.1.0+lite.1-1_amd64.deb} \
    bash "$root/scripts/release-ubuntu.sh" --repo demo/reader "$@" >"$tmp/$scenario/log" 2>&1; then rc=0; else rc=$?; fi
  if [[ $rc != "$expected_rc" ]]; then cat "$tmp/$scenario/log"; echo "FAIL $scenario: $rc != $expected_rc"; exit 1; fi
  count=0
  [[ ! -f $tmp/$scenario/notifications ]] || count=$(wc -l < "$tmp/$scenario/notifications")
  if [[ $count != "$expected_notifications" ]]; then
    cat "$tmp/$scenario/log"
    echo "FAIL $scenario: $count notifications, expected $expected_notifications"
    exit 1
  fi
  echo "PASS $scenario (exit $rc, $count notification(s))"
}

expect_upload() {
  local scenario=$1
  [[ -s $tmp/$scenario/scp-calls ]] || { echo "FAIL $scenario: no scp upload"; exit 1; }
  grep -q 'bash -s' "$tmp/$scenario/ssh-calls" || { echo "FAIL $scenario: no remote install"; exit 1; }
}

expect_no_upload() {
  local scenario=$1
  if [[ -f $tmp/$scenario/scp-calls ]]; then echo "FAIL $scenario: unexpected scp upload"; exit 1; fi
  if [[ -f $tmp/$scenario/ssh-calls ]] && grep -q 'bash -s' "$tmp/$scenario/ssh-calls"; then
    echo "FAIL $scenario: unexpected remote install"; exit 1
  fi
}

# --- monitoring scenarios keep working with deployment disabled ----
run_case success 0 1 --run-id 987 --no-deploy
run_case queued 0 1 --run-id 987 --no-deploy
run_case retry 0 1 --run-id 987 --no-deploy
grep -q '打包成功' "$tmp/retry/notifications"
! grep -q 'PARTIAL INVALID JSON' "$tmp/retry/log"
run_case failure 1 1 --run-id 987
run_case cancelled 2 1 --run-id 987
run_case wrong 1 1 --run-id 987
run_case dispatch 0 1 --tag v0.1.0-lite.1 --ref main --allow-remote --no-deploy
run_case ambiguous 0 1 --tag v0.1.0-lite.1 --ref main --allow-remote --no-deploy
[[ $(wc -l < "$tmp/ambiguous/dispatched") -eq 1 ]]
[[ $(wc -l < "$tmp/dispatch/dispatched") -eq 1 ]]
mkdir -p "$tmp/resume"; touch "$tmp/resume/dispatched"
run_case resume 0 1 --request-id existing-request --no-deploy
! grep -q '^workflow run' "$tmp/resume/calls"
run_case timeout 124 1 --run-id 987
grep -q '超时' "$tmp/timeout/notifications"
! grep -q 'run cancel' "$tmp/timeout/calls"
run_case push 0 1 --ref main --tag v0.1.0-lite.1 --no-deploy
[[ $(cat "$tmp/push/push-count") -eq 1 ]]
run_case pushretry 0 1 --ref main --tag v0.1.0-lite.1 --no-deploy
[[ $(cat "$tmp/pushretry/push-count") -eq 2 ]]
! grep -q 'PARTIAL PUSH' "$tmp/pushretry/log"
run_case dirty 1 1 --ref main --tag v0.1.0-lite.1
run_case wrongrepo 1 1 --ref main --tag v0.1.0-lite.1
run_case multiurl 1 1 --ref main --tag v0.1.0-lite.1
run_case otherbranch 1 1 --ref other --tag v0.1.0-lite.1
run_case pushreject 1 1 --ref main --tag v0.1.0-lite.1
for scenario in dirty wrongrepo multiurl otherbranch; do
  [[ ! -f $tmp/$scenario/push-count && ! -f $tmp/$scenario/dispatched ]]
done
[[ ! -f $tmp/pushreject/dispatched ]]
for scenario in dispatch resume success; do [[ ! -f $tmp/$scenario/git-calls ]]; done

# --- automatic deployment after a successful package run ----
run_case deploy 0 2 --run-id 987
expect_upload deploy
grep -q '已部署 v0.1.0-lite.1' "$tmp/deploy/log"
grep -q 'code-server_0.1.0+lite.1-1_amd64.deb v0.1.0-lite.1 0.1.0+lite.1-1 http://127.0.0.1:8444/vscode/ https://meamoe.top/vscode/' "$tmp/deploy/ssh-calls"
grep -q '已安装并重启服务' "$tmp/deploy/notifications"
grep -q 'Deployed code-server 0.1.0-lite.1-1' "$tmp/deploy/log"
grep -q 'Backup directory: /root/code-server-backup.tEsT01' "$tmp/deploy/log"
# The uploaded file name must be exactly the name the remote script validates.
scp_leaf=$(awk '{print $NF}' "$tmp/deploy/scp-calls" | sed -E 's#^.*/##')
install_leaf=$(grep ' bash -s ' "$tmp/deploy/ssh-calls" | head -n1 | tr ' ' '\n' | grep '^code-server_' | head -n1)
[[ -n $scp_leaf && $scp_leaf == "$install_leaf" ]] || { echo "FAIL deploy: upload $scp_leaf != install $install_leaf"; exit 1; }
PKG_NAME=code-server_0.1.4-1_amd64.deb run_case deployplain 0 2 --run-id 987 --tag v0.1.4
expect_upload deployplain
grep -q 'code-server_0.1.4-1_amd64.deb v0.1.4 0.1.4-1 http://127.0.0.1:8444/vscode/ https://meamoe.top/vscode/' "$tmp/deployplain/ssh-calls"
unset PKG_NAME
run_case deploynone 0 1 --run-id 987 --no-deploy
expect_no_upload deploynone
grep -q '跳过自动部署' "$tmp/deploynone/log"
run_case failuredeploy 1 1 --run-id 987
expect_no_upload failuredeploy
run_case deployexpired 3 2 --run-id 987
expect_no_upload deployexpired
grep -q '部署失败' "$tmp/deployexpired/notifications"
grep -q '没有未过期的 Ubuntu 产物' "$tmp/deployexpired/log"
run_case deployamb 3 2 --run-id 987
expect_no_upload deployamb
run_case deploytag 3 2 --run-id 987 --tag v9.9.9
expect_no_upload deploytag
grep -q '拒绝部署不匹配的构建' "$tmp/deploytag/log"
run_case deploytwopkgs 3 2 --run-id 987
expect_no_upload deploytwopkgs
grep -q '期望恰好一个' "$tmp/deploytwopkgs/log"
run_case deploybadsum 3 2 --run-id 987
expect_no_upload deploybadsum
grep -q '安装包校验失败' "$tmp/deploybadsum/log"
run_case deploynoentry 3 2 --run-id 987
expect_no_upload deploynoentry
run_case deployscpfail 3 2 --run-id 987
[[ -s $tmp/deployscpfail/scp-calls ]]
! grep -q 'bash -s' "$tmp/deployscpfail/ssh-calls"
grep -q '上传安装包到 vultr' "$tmp/deployscpfail/log"
run_case deploysshfail 3 2 --run-id 987
expect_no_upload deploysshfail
grep -q '无法通过 ssh vultr 创建远端暂存目录' "$tmp/deploysshfail/log"
run_case deployinstallfail 3 2 --run-id 987
expect_upload deployinstallfail
grep -q '远端部署失败' "$tmp/deployinstallfail/log"
grep -q '部署失败' "$tmp/deployinstallfail/notifications"
DRY_RUN=1 run_case dryrun 0 2 --run-id 987
expect_upload dryrun
grep -q 'env DEPLOY_DRY_RUN=1 bash -s' "$tmp/dryrun/ssh-calls"
grep -q 'Dry run' "$tmp/dryrun/log"
grep -q '演练通过' "$tmp/dryrun/log"
grep -q '部署演练完成' "$tmp/dryrun/notifications"
unset DRY_RUN
mkdir -p "$tmp/deploydrybad"
if env PATH="$tmp/bin:$PATH" MOCK_STATE="$tmp/deploydrybad" SCENARIO=deploydrybad \
  RETRY_ATTEMPTS=3 RETRY_DELAY_SECONDS=1 POLL_INTERVAL_SECONDS=1 REQUEST_TIMEOUT_SECONDS=5 \
  DISCOVERY_TIMEOUT_SECONDS=5 MONITOR_TIMEOUT_SECONDS=10 DEPLOY_TIMEOUT_SECONDS=10 DEPLOY_DRY_RUN=maybe \
  bash "$root/scripts/release-ubuntu.sh" --repo demo/reader --run-id 987 >"$tmp/deploydrybad/log" 2>&1; then rc=0; else rc=$?; fi
[[ $rc == 1 ]] || { echo "FAIL deploydrybad: $rc != 1"; exit 1; }
grep -q 'DEPLOY_DRY_RUN 只能是 0 或 1' "$tmp/deploydrybad/log"
[[ ! -f $tmp/deploydrybad/notifications && ! -f $tmp/deploydrybad/calls ]]
run_case deployhost 1 0 --run-id 987 --deploy-host 'bad host'
grep -q '必须是合法的 SSH 别名' "$tmp/deployhost/log"
[[ ! -f $tmp/deployhost/calls ]]

# --- the embedded remote script must stay valid Bash and never retry the install ----
awk '/^# DEPLOY_REMOTE_BEGIN$/{f=1;next}/^# DEPLOY_REMOTE_END$/{f=0}f' \
  "$root/scripts/release-ubuntu.sh" > "$tmp/remote-script.sh"
[[ -s $tmp/remote-script.sh ]]
bash -n "$tmp/remote-script.sh"
grep -q 'dpkg --force-confold -i' "$tmp/remote-script.sh"
grep -q 'trap cleanup_remote EXIT' "$tmp/remote-script.sh"
grep -q 'flock -n 9' "$tmp/remote-script.sh"
bash "$root/scripts/release-ubuntu.sh" --help | grep -q '自动部署'

echo 'All 31 offline release-ubuntu tests passed. No real push, deployment, GitHub request or popup was made.'
