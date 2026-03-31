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
USAGE_EXPORT_PATH="${BASE_DIR}/usage-export.json"
COMPOSE_OVERRIDE_PATH="${BASE_DIR}/docker-compose.local.yml"
PACKAGE_DROP_DIR="${BASE_DIR}/packages"
PACKAGE_WORK_DIR="${BASE_DIR}/package-runtime"
PACKAGE_EXTRACT_DIR="${PACKAGE_WORK_DIR}/current"
PACKAGE_DOCKERFILE="${PACKAGE_WORK_DIR}/Dockerfile"

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
DEPLOY_MODE="${CLIPROXY_DEPLOY_MODE:-source}"
PACKAGE_ARCHIVE="${CLIPROXY_PACKAGE_ARCHIVE:-}"
PACKAGE_IMAGE="${CLIPROXY_PACKAGE_IMAGE:-}"
PACKAGE_VERSION="${CLIPROXY_PACKAGE_VERSION:-}"
PACKAGE_ASSET_NAME="${CLIPROXY_PACKAGE_ASSET_NAME:-}"
SYNC_ACTION="no_update"

say() {
  printf '[cliproxy-local] %s\n' "$*" >&2
}

shell_escape() {
  printf '%q' "$1"
}

abspath() {
  local target="$1"
  if [[ -d "${target}" ]]; then
    (
      cd "${target}" >/dev/null 2>&1
      pwd
    )
    return 0
  fi

  (
    cd "$(dirname "${target}")" >/dev/null 2>&1
    printf '%s/%s\n' "$(pwd)" "$(basename "${target}")"
  )
}

deployment_mode_label() {
  case "${DEPLOY_MODE}" in
    package)
      printf 'release 包部署\n'
      ;;
    *)
      printf '源码构建部署\n'
      ;;
  esac
}

activate_source_mode() {
  DEPLOY_MODE="source"
  PACKAGE_ARCHIVE=""
  PACKAGE_IMAGE=""
  PACKAGE_VERSION=""
  PACKAGE_ASSET_NAME=""
}

compose() {
  local env_args=("DEPLOY=${DEPLOY_MODE}")

  if [[ "${DEPLOY_MODE}" == "package" ]]; then
    if [[ -z "${PACKAGE_IMAGE}" ]]; then
      say "当前是 release 包模式，但还没记录可用镜像。先执行 deploy-package。"
      return 1
    fi
    env_args+=("CLI_PROXY_IMAGE=${PACKAGE_IMAGE}")
  fi

  env "${env_args[@]}" docker compose -f "${REPO_DIR}/docker-compose.yml" -f "${COMPOSE_OVERRIDE_PATH}" "$@"
}

management_key_plaintext() {
  if [[ -n "${CLIPROXY_MANAGEMENT_KEY:-}" ]]; then
    printf '%s\n' "${CLIPROXY_MANAGEMENT_KEY}"
    return 0
  fi

  if [[ -f "${CONFIG_PATH}" ]]; then
    python3 - "${CONFIG_PATH}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
if not path.exists():
    sys.exit(0)

text = path.read_text(encoding="utf-8")
match = re.search(r'^\s*secret-key\s*:\s*(.+?)\s*$', text, re.MULTILINE)
if not match:
    sys.exit(0)

value = match.group(1).strip()
if value.startswith('"') and value.endswith('"'):
    value = value[1:-1]
elif value.startswith("'") and value.endswith("'"):
    value = value[1:-1]

if value.startswith("$2"):
    sys.exit(0)

print(value)
PY
    return 0
  fi

  if [[ -n "${DEFAULT_MANAGEMENT_KEY:-}" ]]; then
    printf '%s\n' "${DEFAULT_MANAGEMENT_KEY}"
    return 0
  fi
}

export_usage_statistics() {
  [[ -f "${CONFIG_PATH}" ]] || return 0

  local management_key response tmp_file url
  management_key="$(management_key_plaintext)"
  if [[ -z "${management_key}" ]]; then
    say "跳过 usage 导出：当前 config.yaml 里的管理密钥已哈希，脚本拿不到明文。"
    return 0
  fi

  url="http://127.0.0.1:${PORT_8317}/v0/management/usage/export"
  tmp_file="${USAGE_EXPORT_PATH}.tmp"
  if ! response="$(curl -sS -w '%{http_code}' -H "X-Management-Key: ${management_key}" "${url}" -o "${tmp_file}" 2>/dev/null)"; then
    rm -f "${tmp_file}"
    say "跳过 usage 导出：当前服务还没起来或 management API 不可达。"
    return 0
  fi

  if [[ "${response}" != "200" ]]; then
    rm -f "${tmp_file}"
    say "跳过 usage 导出：management API 返回 HTTP ${response}。"
    return 0
  fi

  mv "${tmp_file}" "${USAGE_EXPORT_PATH}"
  say "已导出 usage 统计到 ${USAGE_EXPORT_PATH}"
}

import_usage_statistics() {
  [[ -f "${USAGE_EXPORT_PATH}" ]] || return 0
  [[ -f "${CONFIG_PATH}" ]] || return 0

  local management_key response url body
  management_key="$(management_key_plaintext)"
  if [[ -z "${management_key}" ]]; then
    say "跳过 usage 导入：当前 config.yaml 里的管理密钥已哈希，脚本拿不到明文。"
    return 0
  fi

  url="http://127.0.0.1:${PORT_8317}/v0/management/usage/import"
  if ! response="$(curl -sS -w $'\n%{http_code}' -X POST \
      -H "X-Management-Key: ${management_key}" \
      -H 'Content-Type: application/json' \
      --data @"${USAGE_EXPORT_PATH}" \
      "${url}" 2>/dev/null)"; then
    say "跳过 usage 导入：management API 不可达。"
    return 0
  fi

  body="${response%$'\n'*}"
  response="${response##*$'\n'}"
  if [[ "${response}" != "200" ]]; then
    say "跳过 usage 导入：management API 返回 HTTP ${response}。"
    return 0
  fi

  say "已导入 usage 统计：${body}"
}

usage() {
  cat <<EOF
用法：
  ./scripts/cliproxy-local.sh start                    启动当前部署模式；源码模式会先检查 upstream
  ./scripts/cliproxy-local.sh update                   同步 upstream，强制重建源码镜像并重新部署
  ./scripts/cliproxy-local.sh rebuild                  不拉上游，直接用当前本地源码强制重建部署
  ./scripts/cliproxy-local.sh deploy-package [PATH]    用本地 release 包构建镜像并部署
  ./scripts/cliproxy-local.sh stop                     停止服务
  ./scripts/cliproxy-local.sh restart                  重启服务
  ./scripts/cliproxy-local.sh logs                     查看服务日志
  ./scripts/cliproxy-local.sh status                   查看服务状态、本地路径、部署模式和 Git 同步状态
  ./scripts/cliproxy-local.sh init                     只初始化本地目录和配置

release 包目录：
  ${PACKAGE_DROP_DIR}

当前 Docker 模式推荐下载：
  $(recommended_package_name 2>/dev/null || printf 'CLIProxyAPI_<版本>_linux_amd64.tar.gz')
EOF
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
  mkdir -p "${BASE_DIR}" "${AUTH_PATH}" "${LOG_PATH}" "${PACKAGE_DROP_DIR}" "${PACKAGE_WORK_DIR}"
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
  {
    printf 'CLIPROXY_BIND_IP=%s\n' "$(shell_escape "${BIND_IP}")"
    printf 'CLIPROXY_PORT_8317=%s\n' "$(shell_escape "${PORT_8317}")"
    printf 'CLIPROXY_PORT_8085=%s\n' "$(shell_escape "${PORT_8085}")"
    printf 'CLIPROXY_PORT_1455=%s\n' "$(shell_escape "${PORT_1455}")"
    printf 'CLIPROXY_PORT_54545=%s\n' "$(shell_escape "${PORT_54545}")"
    printf 'CLIPROXY_PORT_51121=%s\n' "$(shell_escape "${PORT_51121}")"
    printf 'CLIPROXY_PORT_11451=%s\n' "$(shell_escape "${PORT_11451}")"
    printf 'CLIPROXY_DEPLOY_MODE=%s\n' "$(shell_escape "${DEPLOY_MODE}")"
    printf 'CLIPROXY_PACKAGE_ARCHIVE=%s\n' "$(shell_escape "${PACKAGE_ARCHIVE}")"
    printf 'CLIPROXY_PACKAGE_IMAGE=%s\n' "$(shell_escape "${PACKAGE_IMAGE}")"
    printf 'CLIPROXY_PACKAGE_VERSION=%s\n' "$(shell_escape "${PACKAGE_VERSION}")"
    printf 'CLIPROXY_PACKAGE_ASSET_NAME=%s\n' "$(shell_escape "${PACKAGE_ASSET_NAME}")"
  } > "${RUNTIME_ENV_FILE}"
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

platform_package_suffix() {
  case "$(uname -m)" in
    arm64|aarch64)
      printf 'linux_arm64\n'
      ;;
    x86_64|amd64)
      printf 'linux_amd64\n'
      ;;
    *)
      say "当前机器架构 $(uname -m) 还没在脚本里登记，先手工挑对应的 linux release 包。"
      return 1
      ;;
  esac
}

recommended_package_name() {
  local suffix
  suffix="$(platform_package_suffix)" || return 1
  printf 'CLIProxyAPI_<版本>_%s.tar.gz\n' "${suffix}"
}

find_latest_package_archive() {
  local suffix latest=""
  local -a matches=()

  suffix="$(platform_package_suffix)" || return 1
  shopt -s nullglob
  matches=("${PACKAGE_DROP_DIR}"/CLIProxyAPI_*_"${suffix}".tar.gz)
  shopt -u nullglob

  if (( ${#matches[@]} == 0 )); then
    say "没在 ${PACKAGE_DROP_DIR} 找到匹配的 release 包。"
    say "你先下载 ${PACKAGE_DROP_DIR}/$(recommended_package_name)"
    return 1
  fi

  latest="${matches[0]}"
  for archive in "${matches[@]}"; do
    if [[ "${archive}" -nt "${latest}" ]]; then
      latest="${archive}"
    fi
  done

  printf '%s\n' "${latest}"
}

resolve_package_archive() {
  local input="${1:-}"
  local archive_path

  if [[ -n "${input}" ]]; then
    if [[ ! -f "${input}" ]]; then
      say "指定的 release 包不存在：${input}"
      return 1
    fi
    archive_path="$(abspath "${input}")"
  else
    archive_path="$(find_latest_package_archive)"
  fi

  printf '%s\n' "${archive_path}"
}

build_package_image_from_archive() {
  local archive_path="$1"
  local asset_name version asset_suffix expected_suffix safe_version image_tag tmpdir

  asset_name="$(basename "${archive_path}")"
  expected_suffix="$(platform_package_suffix)" || return 1

  if [[ ! "${asset_name}" =~ ^CLIProxyAPI_(.+)_(linux_(amd64|arm64))\.tar\.gz$ ]]; then
    say "release 包文件名不对：${asset_name}"
    say "应该长这样：$(recommended_package_name)"
    return 1
  fi

  version="${BASH_REMATCH[1]}"
  asset_suffix="${BASH_REMATCH[2]}"
  if [[ "${asset_suffix}" != "${expected_suffix}" ]]; then
    say "你这个包是 ${asset_suffix}，跟当前 Docker 运行架构 ${expected_suffix} 对不上。"
    say "重新下载：$(recommended_package_name)"
    return 1
  fi

  tmpdir="$(mktemp -d "${BASE_DIR}/package-extract.XXXXXX")"
  tar -xzf "${archive_path}" -C "${tmpdir}"

  if [[ ! -f "${tmpdir}/cli-proxy-api" ]]; then
    rm -rf "${tmpdir}"
    say "release 包里没找到 cli-proxy-api 可执行文件，先别往下硬整。"
    return 1
  fi
  chmod +x "${tmpdir}/cli-proxy-api"

  if [[ ! -f "${tmpdir}/config.example.yaml" ]]; then
    cp "${REPO_DIR}/config.example.yaml" "${tmpdir}/config.example.yaml"
  fi

  rm -rf "${PACKAGE_EXTRACT_DIR}"
  mkdir -p "${PACKAGE_WORK_DIR}"
  mv "${tmpdir}" "${PACKAGE_EXTRACT_DIR}"

  cat > "${PACKAGE_DOCKERFILE}" <<'EOF'
FROM docker.io/library/alpine:3.22.0

RUN apk add --no-cache tzdata

RUN mkdir /CLIProxyAPI

COPY cli-proxy-api /CLIProxyAPI/CLIProxyAPI
COPY config.example.yaml /CLIProxyAPI/config.example.yaml

WORKDIR /CLIProxyAPI

EXPOSE 8317 8085 1455 54545 51121 11451

ENV TZ=Asia/Shanghai

RUN cp /usr/share/zoneinfo/${TZ} /etc/localtime && \
    echo "${TZ}" > /etc/timezone && \
    chmod +x /CLIProxyAPI/CLIProxyAPI

CMD ["./CLIProxyAPI"]
EOF

  safe_version="$(printf '%s' "${version}" | tr -cs 'A-Za-z0-9_.-' '-')"
  image_tag="cliproxy-local-package:${safe_version}-${asset_suffix}"

  say "开始用 release 包构建本地镜像：${image_tag}"
  docker build -t "${image_tag}" -f "${PACKAGE_DOCKERFILE}" "${PACKAGE_EXTRACT_DIR}"

  DEPLOY_MODE="package"
  PACKAGE_ARCHIVE="${archive_path}"
  PACKAGE_IMAGE="${image_tag}"
  PACKAGE_VERSION="${version}"
  PACKAGE_ASSET_NAME="${asset_name}"
}

ensure_package_mode_ready() {
  if [[ "${DEPLOY_MODE}" != "package" ]]; then
    return 0
  fi

  if [[ -z "${PACKAGE_IMAGE}" ]]; then
    say "当前记录的是 release 包模式，但没找到镜像信息。你先跑一把 deploy-package。"
    return 1
  fi
}

ensure_package_image_available() {
  ensure_package_mode_ready || return 1

  if ! docker image inspect "${PACKAGE_IMAGE}" >/dev/null 2>&1; then
    say "本地镜像 ${PACKAGE_IMAGE} 不在了。你重新执行 deploy-package 就行。"
    return 1
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

print_deploy_status_summary() {
  cat <<EOF
部署状态：
  当前模式：$(deployment_mode_label)
  release 包目录：${PACKAGE_DROP_DIR}
  推荐下载包：$(recommended_package_name 2>/dev/null || printf 'CLIProxyAPI_<版本>_linux_amd64.tar.gz')
  当前 release 包：${PACKAGE_ARCHIVE:-<none>}
  当前 release 版本：${PACKAGE_VERSION:-<none>}
  当前镜像：${PACKAGE_IMAGE:-<源码模式由 docker compose 本地 build>}
EOF
}

show_status() {
  prepare_local_runtime
  if docker info >/dev/null 2>&1; then
    if [[ "${DEPLOY_MODE}" != "package" ]] || ensure_package_mode_ready; then
      compose ps || true
    fi
  else
    say "Docker 还没启动，先看本地路径信息。"
  fi
  cat <<EOF

本地数据目录：
  配置文件：${CONFIG_PATH}
  认证目录：${AUTH_PATH}
  日志目录：${LOG_PATH}
  Usage 备份：${USAGE_EXPORT_PATH}
  override 文件：${COMPOSE_OVERRIDE_PATH}
  运行态环境：${RUNTIME_ENV_FILE}

$(print_deploy_status_summary)

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

  if [[ "${DEPLOY_MODE}" == "package" ]]; then
    ensure_package_image_available || exit 1
    compose up -d --no-build --remove-orphans
  else
    sync_upstream_if_needed
    if [[ "${SYNC_ACTION}" == "updated" ]]; then
      compose up -d --build --remove-orphans
    else
      compose up -d --remove-orphans
    fi
  fi

  import_usage_statistics
  show_status
}

stop_service() {
  ensure_docker
  prepare_local_runtime
  export_usage_statistics
  if [[ "${DEPLOY_MODE}" != "package" ]] || ensure_package_mode_ready; then
    compose down
  fi
}

restart_service() {
  stop_service
  start_service
}

logs_service() {
  ensure_docker
  prepare_local_runtime
  if [[ "${DEPLOY_MODE}" == "package" ]]; then
    ensure_package_mode_ready || exit 1
  fi
  compose logs -f --tail=200 "${SERVICE_NAME}"
}

update_service() {
  if [[ "${DEPLOY_MODE}" == "package" ]]; then
    say "这次 `update` 会切回源码模式，走 upstream 同步 + 本地重建。"
  fi
  activate_source_mode
  ensure_clean_repo_for_update
  ensure_docker
  prepare_local_runtime
  export_usage_statistics
  sync_upstream_if_needed
  compose up -d --build --remove-orphans
  import_usage_statistics
  show_status
}

rebuild_service() {
  if [[ "${DEPLOY_MODE}" == "package" ]]; then
    say "这次 `rebuild` 会切回源码模式，直接拿你当前本地代码重建。"
  fi
  activate_source_mode
  ensure_docker
  prepare_local_runtime
  export_usage_statistics
  compose up -d --build --remove-orphans
  import_usage_statistics
  show_status
}

deploy_package_service() {
  local archive_path

  ensure_docker
  prepare_local_runtime
  archive_path="$(resolve_package_archive "${1:-}")"
  export_usage_statistics
  build_package_image_from_archive "${archive_path}"
  write_runtime_env
  write_override
  compose up -d --no-build --remove-orphans
  import_usage_statistics
  show_status
}

main() {
  local cmd="${1:-start}"
  case "${cmd}" in
    start)
      start_service
      ;;
    update|update-source)
      update_service
      ;;
    rebuild|rebuild-source)
      rebuild_service
      ;;
    deploy-package|package)
      deploy_package_service "${2:-}"
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
