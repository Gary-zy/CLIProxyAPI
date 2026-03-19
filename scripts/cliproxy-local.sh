#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASE_DIR="${CLIPROXY_LOCAL_HOME:-${XDG_CONFIG_HOME:-${HOME}/.config}/cliproxyapi-local}"
LEGACY_BASE_DIR="${CLIPROXY_LEGACY_HOME:-${HOME}/.cli-proxy-api}"
RUNTIME_ENV_FILE="${BASE_DIR}/runtime.env"
if [[ -f "${RUNTIME_ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${RUNTIME_ENV_FILE}"
  set +a
fi
CONFIG_PATH="${BASE_DIR}/config.yaml"
AUTH_PATH="${BASE_DIR}/auths"
LOG_PATH="${BASE_DIR}/logs"
COMPOSE_OVERRIDE_PATH="${BASE_DIR}/docker-compose.local.yml"
SERVICE_NAME="cli-proxy-api"
DEFAULT_BRANCH="main"
ORIGIN_REMOTE_NAME="origin"
ORIGIN_REMOTE_URL="https://github.com/Gary-zy/CLIProxyAPI.git"
UPSTREAM_REMOTE_NAME="upstream"
UPSTREAM_REMOTE_URL="https://github.com/router-for-me/CLIProxyAPI.git"
DEFAULT_MANAGEMENT_KEY="${CLIPROXY_MANAGEMENT_KEY:-Niubao123}"
BIND_IP="${CLIPROXY_BIND_IP:-127.0.0.1}"
PORT_8317="${CLIPROXY_PORT_8317:-8317}"
PORT_8085="${CLIPROXY_PORT_8085:-8085}"
PORT_1455="${CLIPROXY_PORT_1455:-1455}"
PORT_54545="${CLIPROXY_PORT_54545:-54545}"
PORT_51121="${CLIPROXY_PORT_51121:-51121}"
PORT_11451="${CLIPROXY_PORT_11451:-11451}"
SYNC_ACTION="no_update"

say() {
  printf '[cliproxy-local] %s\n' "$*"
}

usage() {
  cat <<'EOF'
用法：
  ./scripts/cliproxy-local.sh start    启动前检查 upstream 更新，必要时同步并重建
  ./scripts/cliproxy-local.sh update   显式同步 upstream 更新并重建服务
  ./scripts/cliproxy-local.sh stop     停止服务
  ./scripts/cliproxy-local.sh restart  重启服务
  ./scripts/cliproxy-local.sh logs     查看服务日志
  ./scripts/cliproxy-local.sh status   查看服务状态、本地路径和 Git 同步状态
  ./scripts/cliproxy-local.sh init     只初始化本地目录和配置
EOF
}

compose() {
  docker compose -f "${REPO_DIR}/docker-compose.yml" -f "${COMPOSE_OVERRIDE_PATH}" "$@"
}

wait_for_docker() {
  local i
  for i in {1..60}; do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  say "Docker daemon 还没起来，自己在那装深沉。先把 Docker Desktop 启好再来。"
  exit 1
}

ensure_docker() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    say "检测到 Docker 没启动，尝试自动拉起 Docker Desktop。"
    open -a Docker >/dev/null 2>&1 || true
  fi
  wait_for_docker
}

ensure_dirs() {
  mkdir -p "${BASE_DIR}" "${AUTH_PATH}" "${LOG_PATH}"
}

git_current_branch() {
  git -C "${REPO_DIR}" branch --show-current 2>/dev/null || true
}

git_remote_url() {
  local name="$1"
  git -C "${REPO_DIR}" remote get-url "${name}" 2>/dev/null || true
}

ensure_git_repo() {
  if ! git -C "${REPO_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
    say "当前目录不是 Git 仓库，没法走 fork 同步流程。"
    return 1
  fi
}

ensure_expected_remotes() {
  ensure_git_repo || return 1
  local origin_url upstream_url
  origin_url="$(git_remote_url "${ORIGIN_REMOTE_NAME}")"
  upstream_url="$(git_remote_url "${UPSTREAM_REMOTE_NAME}")"

  if [[ "${origin_url}" != "${ORIGIN_REMOTE_URL}" ]]; then
    say "origin remote 不对，当前是：${origin_url:-<missing>}"
    say "期望是：${ORIGIN_REMOTE_URL}"
    return 1
  fi

  if [[ "${upstream_url}" != "${UPSTREAM_REMOTE_URL}" ]]; then
    say "upstream remote 不对，当前是：${upstream_url:-<missing>}"
    say "期望是：${UPSTREAM_REMOTE_URL}"
    return 1
  fi
}

git_has_tracked_changes() {
  if ! git -C "${REPO_DIR}" diff --quiet --exit-code; then
    return 0
  fi
  if ! git -C "${REPO_DIR}" diff --cached --quiet --exit-code; then
    return 0
  fi
  return 1
}

sync_upstream_if_needed() {
  SYNC_ACTION="no_update"
  ensure_expected_remotes || return 1

  local branch
  branch="$(git_current_branch)"
  if [[ "${branch}" != "${DEFAULT_BRANCH}" ]]; then
    say "当前分支是 ${branch:-<detached>}，自动同步仅在 ${DEFAULT_BRANCH} 启用，本次跳过同步。"
    SYNC_ACTION="skipped"
    return 0
  fi

  say "检查 ${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH} 是否有更新。"
  git -C "${REPO_DIR}" fetch "${UPSTREAM_REMOTE_NAME}"

  local local_head upstream_head
  local_head="$(git -C "${REPO_DIR}" rev-parse "${DEFAULT_BRANCH}")"
  upstream_head="$(git -C "${REPO_DIR}" rev-parse "${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH}")"
  if [[ "${local_head}" == "${upstream_head}" ]]; then
    say "${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH} 无更新。"
    return 0
  fi

  if git -C "${REPO_DIR}" merge-base --is-ancestor "${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH}" "${DEFAULT_BRANCH}"; then
    say "本地 ${DEFAULT_BRANCH} 已包含 ${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH}，本次无需同步。"
    return 0
  fi

  if git_has_tracked_changes; then
    say "仓库里还有已跟踪文件改动，先处理掉再同步上游，别硬拽。"
    git -C "${REPO_DIR}" status --short
    return 1
  fi

  say "检测到 ${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH} 有更新，开始同步。"
  if git -C "${REPO_DIR}" merge --ff-only "${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH}"; then
    say "已 fast-forward 到 ${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH}。"
    SYNC_ACTION="updated"
    return 0
  fi

  say "无法 fast-forward，尝试普通 merge。"
  if git -C "${REPO_DIR}" merge --no-edit "${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH}"; then
    say "已合并 ${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH}。"
    SYNC_ACTION="updated"
    return 0
  fi

  if git -C "${REPO_DIR}" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    git -C "${REPO_DIR}" merge --abort >/dev/null 2>&1 || true
  fi
  say "同步 ${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH} 时发生冲突，已停止并回滚未完成 merge。"
  return 1
}

write_runtime_env() {
  cat > "${RUNTIME_ENV_FILE}" <<EOF
CLIPROXY_BIND_IP=${BIND_IP}
CLIPROXY_PORT_8317=${PORT_8317}
CLIPROXY_PORT_8085=${PORT_8085}
CLIPROXY_PORT_1455=${PORT_1455}
CLIPROXY_PORT_54545=${PORT_54545}
CLIPROXY_PORT_51121=${PORT_51121}
CLIPROXY_PORT_11451=${PORT_11451}
EOF
}

dir_has_files() {
  local target="$1"
  [[ -d "${target}" ]] || return 1
  find "${target}" -mindepth 1 -maxdepth 1 -type f ! -name '.DS_Store' | read -r _
}

normalize_config() {
  local mode="$1"
  python3 - "${CONFIG_PATH}" "${DEFAULT_MANAGEMENT_KEY}" "${mode}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
default_key = sys.argv[2]
mode = sys.argv[3]
text = path.read_text(encoding="utf-8")
newline = "\r\n" if "\r\n" in text else "\n"
lines = text.splitlines()
out = []

found_auth = False
found_host = False
found_remote = False
in_remote = False
found_allow = False
found_secret = False


def finalize_remote():
    global out, found_allow, found_secret
    if not found_allow:
        out.append("  allow-remote: true")
    if not found_secret:
        out.append(f'  secret-key: "{default_key}"')


for line in lines:
    stripped = line.lstrip(" ")
    indent = len(line) - len(stripped)
    top_level = indent == 0 and stripped != "" and not stripped.startswith("#")

    if in_remote and top_level and not stripped.startswith("remote-management:"):
        finalize_remote()
        in_remote = False

    if top_level and stripped.startswith("remote-management:"):
        found_remote = True
        in_remote = True
        found_allow = False
        found_secret = False
        out.append(line)
        continue

    if in_remote:
        if re.match(r"^\s*allow-remote\s*:", line):
            leading = line[: len(line) - len(line.lstrip())]
            out.append(f"{leading}allow-remote: true")
            found_allow = True
            continue
        if re.match(r"^\s*secret-key\s*:", line):
            leading = line[: len(line) - len(line.lstrip())]
            value = line.split(":", 1)[1].strip()
            if mode == "init" or value in {"", '""', "''"}:
                out.append(f'{leading}secret-key: "{default_key}"')
            else:
                out.append(line)
            found_secret = True
            continue

    if top_level and re.match(r"^host\s*:", line):
        out.append('host: ""')
        found_host = True
        continue

    if top_level and re.match(r"^auth-dir\s*:", line):
        out.append('auth-dir: "/root/.cli-proxy-api"')
        found_auth = True
        continue

    out.append(line)

if in_remote:
    finalize_remote()

if not found_remote:
    out.extend([
        "remote-management:",
        "  allow-remote: true",
        f'  secret-key: "{default_key}"',
    ])

if not found_auth:
    out.append('auth-dir: "/root/.cli-proxy-api"')

if not found_host:
    out.insert(0, 'host: ""')

normalized = newline.join(out)
if text.endswith(("\n", "\r\n")):
    normalized += newline
path.write_text(normalized, encoding="utf-8", newline="")
PY
}

init_config_if_missing() {
  local source_path
  if [[ -f "${CONFIG_PATH}" ]]; then
    normalize_config "refresh"
    return 0
  fi

  if [[ -f "${LEGACY_BASE_DIR}/config.yaml" ]]; then
    source_path="${LEGACY_BASE_DIR}/config.yaml"
  elif [[ -f "${REPO_DIR}/config.yaml" ]]; then
    source_path="${REPO_DIR}/config.yaml"
  else
    source_path="${REPO_DIR}/config.example.yaml"
  fi

  cp "${source_path}" "${CONFIG_PATH}"
  normalize_config "init"
  say "本地配置已初始化：${CONFIG_PATH}"
}

migrate_legacy_auths_if_needed() {
  local copied=0
  [[ -d "${LEGACY_BASE_DIR}" ]] || return 0
  if dir_has_files "${AUTH_PATH}"; then
    return 0
  fi

  while IFS= read -r legacy_file; do
    cp "${legacy_file}" "${AUTH_PATH}/"
    copied=1
  done < <(find "${LEGACY_BASE_DIR}" -mindepth 1 -maxdepth 1 -type f \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) ! -name 'config.yaml' ! -name '.DS_Store' | sort)

  if [[ -d "${LEGACY_BASE_DIR}/logs" ]] && ! dir_has_files "${LOG_PATH}"; then
    find "${LEGACY_BASE_DIR}/logs" -mindepth 1 -maxdepth 1 -type f ! -name '.DS_Store' -exec cp {} "${LOG_PATH}/" \;
  fi

  if [[ "${copied}" -eq 1 ]]; then
    say "已从旧目录迁移认证文件：${LEGACY_BASE_DIR} -> ${AUTH_PATH}"
  fi
}

yaml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_override() {
  local cfg auth logs
  cfg="$(yaml_escape "${CONFIG_PATH}")"
  auth="$(yaml_escape "${AUTH_PATH}")"
  logs="$(yaml_escape "${LOG_PATH}")"

  cat > "${COMPOSE_OVERRIDE_PATH}" <<EOF
services:
  cli-proxy-api:
    pull_policy: never
    ports: !override
      - "${BIND_IP}:${PORT_8317}:8317"
      - "${BIND_IP}:${PORT_8085}:8085"
      - "${BIND_IP}:${PORT_1455}:1455"
      - "${BIND_IP}:${PORT_54545}:54545"
      - "${BIND_IP}:${PORT_51121}:51121"
      - "${BIND_IP}:${PORT_11451}:11451"
    volumes: !override
      - "${cfg}:/CLIProxyAPI/config.yaml"
      - "${auth}:/root/.cli-proxy-api"
      - "${logs}:/CLIProxyAPI/logs"
EOF
}

prepare_local_runtime() {
  ensure_dirs
  init_config_if_missing
  migrate_legacy_auths_if_needed
  write_runtime_env
  write_override
}

ensure_clean_repo_for_update() {
  if git_has_tracked_changes; then
    say "仓库里还有已跟踪文件改动，先处理掉再 update，别硬拽。"
    git -C "${REPO_DIR}" status --short
    exit 1
  fi
}

print_git_status_summary() {
  if ! ensure_git_repo >/dev/null 2>&1; then
    return 0
  fi

  local branch origin_url upstream_url behind ahead
  branch="$(git_current_branch)"
  origin_url="$(git_remote_url "${ORIGIN_REMOTE_NAME}")"
  upstream_url="$(git_remote_url "${UPSTREAM_REMOTE_NAME}")"
  behind="-"
  ahead="-"

  if [[ -n "${upstream_url}" ]] && git -C "${REPO_DIR}" rev-parse --verify "${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH}" >/dev/null 2>&1; then
    behind="$(git -C "${REPO_DIR}" rev-list --count "${DEFAULT_BRANCH}..${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH}" 2>/dev/null || printf '0')"
    ahead="$(git -C "${REPO_DIR}" rev-list --count "${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH}..${DEFAULT_BRANCH}" 2>/dev/null || printf '0')"
  fi

  cat <<EOF
Git 状态：
  当前分支：${branch:-<detached>}
  origin：${origin_url:-<missing>}
  upstream：${upstream_url:-<missing>}
  相对 ${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH} 落后：${behind}
  相对 ${UPSTREAM_REMOTE_NAME}/${DEFAULT_BRANCH} 超前：${ahead}
EOF
}

show_status() {
  prepare_local_runtime
  if docker info >/dev/null 2>&1; then
    compose ps
  else
    say "Docker 还没启动，先看本地路径信息。"
  fi
  cat <<EOF

本地数据目录：
  配置文件：${CONFIG_PATH}
  认证目录：${AUTH_PATH}
  日志目录：${LOG_PATH}
  override 文件：${COMPOSE_OVERRIDE_PATH}
  运行态环境：${RUNTIME_ENV_FILE}

$(print_git_status_summary)

访问地址：
  管理面板：http://${BIND_IP}:${PORT_8317}/management.html
  API 根地址：http://${BIND_IP}:${PORT_8317}
  管理密钥：看 ${CONFIG_PATH} 里的 remote-management.secret-key
EOF
}

start_service() {
  ensure_docker
  prepare_local_runtime
  sync_upstream_if_needed
  if [[ "${SYNC_ACTION}" == "updated" ]]; then
    compose up -d --build --remove-orphans
  else
    compose up -d --remove-orphans
  fi
  show_status
}

stop_service() {
  ensure_docker
  prepare_local_runtime
  compose down
}

restart_service() {
  stop_service
  start_service
}

logs_service() {
  ensure_docker
  prepare_local_runtime
  compose logs -f --tail=200 "${SERVICE_NAME}"
}

update_service() {
  ensure_clean_repo_for_update
  ensure_docker
  prepare_local_runtime
  sync_upstream_if_needed
  if [[ "${SYNC_ACTION}" == "updated" ]]; then
    compose up -d --build --remove-orphans
  else
    compose up -d --remove-orphans
  fi
  show_status
}

main() {
  local cmd="${1:-start}"
  case "${cmd}" in
    start)
      start_service
      ;;
    update)
      update_service
      ;;
    stop)
      stop_service
      ;;
    restart)
      restart_service
      ;;
    logs)
      logs_service
      ;;
    status)
      show_status
      ;;
    init)
      prepare_local_runtime
      show_status
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
