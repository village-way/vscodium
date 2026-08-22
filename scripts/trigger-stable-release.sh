#!/usr/bin/env bash
#
# VSCodium Stable 版本手动触发脚本
# 用于通过 gh CLI 触发完整的构建和发布流程
#
# 使用方法:
#   ./scripts/trigger-stable-release.sh [选项]
#
# 选项:
#   --dispatch      使用 repository_dispatch 触发（推荐，模拟 spearhead 行为）
#   --workflow      使用 workflow_dispatch 分别触发各平台
#   --generate      仅生成 assets，不发布到 Release
#   --force         强制更新版本信息
#   --platform      指定平台 (macos|linux|windows|all)，默认 all
#   --workflow-ref  VSCodium 工作流分支，默认当前分支
#   --source-branch    zhanlu-code 仓库分支，默认 develop（workflow_dispatch / repository_dispatch）
#   --zhanlu-core-ref zhanlu-core 仓库分支或 commit，默认使用 upstream/stable.json 中的 commit
#   --bundle-codex-runtime 是否打包 Codex CLI runtime，0 或 1，默认 0
#   --release-version  指定要发布的 release/tag；默认自动解析一次并传给所有 workflow
#   --dry-run       仅显示将要执行的命令，不实际执行
#   --help          显示帮助信息

set -e

# 默认值
TRIGGER_MODE="dispatch"
GENERATE_ONLY=false
FORCE_VERSION=false
PLATFORM="all"
DRY_RUN=false
# zhanlu-code 分支（与 workflow_dispatch input source_branch / repository_dispatch client_payload 一致）
SOURCE_BRANCH="develop"
# zhanlu_change start - delivery profile release pin shared by all platform workflows
DELIVERY_PROFILE="${ZHANLU_DELIVERY_PROFILE:-default}"
ZHANLU_DELIVERY_SOURCE_COMMIT="${ZHANLU_DELIVERY_SOURCE_COMMIT:-}"
ZHANLU_DELIVERY_PROFILE_DIGEST="${ZHANLU_DELIVERY_PROFILE_DIGEST:-}"
ZHANLU_DELIVERY_ASSETS_REPOSITORY="${ZHANLU_DELIVERY_ASSETS_REPOSITORY:-}"
# workflow_dispatch must read the workflow definition from the wrapper ref that
# contains the delivery-profile implementation. Defaults are resolved after the
# GitHub repository is known. # zhanlu_change
WORKFLOW_REF="${WORKFLOW_REF:-}"
# zhanlu_change end
# zhanlu-core 分支 / tag / commit（为空时回退到 upstream/stable.json commit）
ZHANLU_CORE_REF=""
# zhanlu_change start - allow release operators to pin the optional legacy zhanlu-vs source
ZHANLU_VS_REF=""
ZHANLU_BUNDLE_CODEX_RUNTIME="${ZHANLU_BUNDLE_CODEX_RUNTIME:-0}"
# zhanlu_change end
# Release 版本：为空时触发前只解析一次，随后传给所有 workflow
RELEASE_VERSION="${RELEASE_VERSION:-}"
# 内部 VS Code 兼容版本的 4 位补丁号；为空时 zhanlu-code 会从 RELEASE_VERSION 派生
VERSION_TIME_PATCH="${VERSION_TIME_PATCH:-${BUILD_PATCH:-}}"
REQUEST_ID=""
OUTPUT_FORMAT="text"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    cat << EOF
VSCodium Stable 版本手动触发脚本

使用方法:
  ./scripts/trigger-stable-release.sh [选项]

选项:
  --dispatch      使用 repository_dispatch 触发（推荐，模拟 spearhead 行为）
  --workflow      使用 workflow_dispatch 分别触发各平台
  --generate      仅生成 assets，不发布到 Release
  --force         强制更新版本信息
  --platform      指定平台 (macos|linux|windows|all)，默认 all
  --workflow-ref  VSCodium 工作流分支，默认当前分支
  --source-branch    zhanlu-code 分支，默认 develop
  --delivery-profile 定向交付 Profile，默认 default
  --zhanlu-core-ref zhanlu-core 分支或 commit，默认使用 upstream/stable.json 中的 commit
  --zhanlu-vs-ref   可选的旧 zhanlu-vs 分支、标签或 commit/ref；留空则不构建 VSIX
  --bundle-codex-runtime 是否打包 Codex CLI runtime，0 或 1，默认 0
  --release-version  指定要发布的 release/tag；默认自动解析一次并传给所有 workflow
  --version-time-patch 指定内部 VS Code 兼容版本的 4 位补丁号（可用 VERSION_TIME_PATCH 环境变量）
  --request-id     门户请求 UUID；写入 workflow run-name
  --output         text 或 json；json 输出固定 schema v1
  --dry-run       仅显示将要执行的命令，不实际执行
  --help          显示帮助信息

示例:
  # 使用 repository_dispatch 触发所有平台构建和发布
  ./scripts/trigger-stable-release.sh --dispatch

  # 仅触发 macOS 构建
  ./scripts/trigger-stable-release.sh --workflow --platform macos

  # 生成 assets 但不发布（用于测试）
  ./scripts/trigger-stable-release.sh --workflow --generate --platform all

  # 预览命令但不执行
  ./scripts/trigger-stable-release.sh --dispatch --dry-run

  # 使用 zhanlu-code 的 master 分支构建
  ./scripts/trigger-stable-release.sh --workflow --source-branch master --platform all

  # 使用 zhanlu-core 的 master 分支构建（不使用 upstream/stable.json 中的 commit）
  ./scripts/trigger-stable-release.sh --workflow --zhanlu-core-ref develop --platform all

  # 使用指定 zhanlu-vs 分支、标签或 commit/ref 构建
  ./scripts/trigger-stable-release.sh --workflow --zhanlu-vs-ref v7.2.40 --platform all

  # 使用指定 zhanlu-core 分支和版本构建
  ./scripts/trigger-stable-release.sh --workflow --zhanlu-core-ref develop --platform all  --release-version 1.0.1

  # 使用公开版本 1.0.1，同时指定内部 VS Code 兼容版本补丁号 2827
  VERSION_TIME_PATCH=2827 ./scripts/trigger-stable-release.sh --workflow --zhanlu-core-ref develop --platform all --release-version 1.0.1


  # 使用指定 zhanlu-code 分支和 zhanlu-core commit 构建
  ./scripts/trigger-stable-release.sh --workflow --source-branch master --zhanlu-core-ref 7abce138e9579e9d48415342b721c916c55ef4d4 --platform all

  # 使用已创建的 release/tag 构建并上传到同一个 Release
  ./scripts/trigger-stable-release.sh --workflow --release-version 1.126.05564 --platform all

注意事项:
  1. 需要先安装并登录 gh CLI: gh auth login
  2. repository_dispatch 模式会同时触发所有平台，无法指定单个平台
  3. --generate 模式下 assets 会上传为 workflow artifacts，不会发布到 Release
EOF
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --dispatch)
            TRIGGER_MODE="dispatch"
            shift
            ;;
        --workflow)
            TRIGGER_MODE="workflow"
            shift
            ;;
        --generate)
            GENERATE_ONLY=true
            shift
            ;;
        --force)
            FORCE_VERSION=true
            shift
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --source-branch)
            SOURCE_BRANCH="$2"
            shift 2
            ;;
        # zhanlu_change start - select the branch that owns the workflow definition
        --workflow-ref)
            WORKFLOW_REF="$2"
            shift 2
            ;;
        # zhanlu_change end
        --delivery-profile)
            DELIVERY_PROFILE="$2"
            shift 2
            ;;
        --zhanlu-core-ref)
            ZHANLU_CORE_REF="$2"
            shift 2
            ;;
        # zhanlu_change start - pass a zhanlu-vs ref through manual release triggers
        --zhanlu-vs-ref)
            ZHANLU_VS_REF="$2"
            shift 2
            ;;
        --bundle-codex-runtime)
            ZHANLU_BUNDLE_CODEX_RUNTIME="$2"
            shift 2
            ;;
        # zhanlu_change end
        --release-version)
            RELEASE_VERSION="$2"
            shift 2
            ;;
        --version-time-patch)
            VERSION_TIME_PATCH="$2"
            shift 2
            ;;
        --request-id)
            REQUEST_ID="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            print_error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

if [[ "${ZHANLU_BUNDLE_CODEX_RUNTIME}" != "0" && "${ZHANLU_BUNDLE_CODEX_RUNTIME}" != "1" ]]; then
    print_error "--bundle-codex-runtime 必须是 0 或 1"
    exit 1
fi
if [[ "${OUTPUT_FORMAT}" != "text" && "${OUTPUT_FORMAT}" != "json" ]]; then
    print_error "--output 必须是 text 或 json"
    exit 1
fi
if [[ -n "${REQUEST_ID}" && ! "${REQUEST_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    print_error "--request-id 格式不正确"
    exit 1
fi

# 检查 gh CLI
check_gh_cli() {
    if ! command -v gh &> /dev/null; then
        print_error "gh CLI 未安装，请先安装: https://cli.github.com/"
        exit 1
    fi

    if ! gh auth status &> /dev/null; then
        print_error "gh CLI 未登录，请先执行: gh auth login"
        exit 1
    fi

    print_success "gh CLI 已就绪"
}

# 获取仓库信息
get_repo_info() {
    REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
    if [[ -z "$REPO" ]]; then
        print_error "无法获取仓库信息，请确保在正确的仓库目录中"
        exit 1
    fi
    print_info "目标仓库: $REPO"

    # zhanlu_change start - dispatch the workflow definition from the active wrapper branch
    if [[ -z "${WORKFLOW_REF}" ]]; then
        WORKFLOW_REF="$(git branch --show-current 2>/dev/null || true)"
    fi
    if [[ -z "${WORKFLOW_REF}" ]]; then
        WORKFLOW_REF="$(gh repo view "${REPO}" --json defaultBranchRef -q '.defaultBranchRef.name')"
    fi
    print_info "工作流定义 Ref: ${WORKFLOW_REF}"
    # zhanlu_change end
}

# zhanlu_change start - resolve once, then reuse release metadata instead of following a moving branch
resolve_delivery_pin() {
    source "./scripts/resolve-release-delivery-profile.sh"
    local metadata_dir
    local metadata=""
    local local_metadata="./.zhanlu/release-delivery.json"
    local local_metadata_matches=false
    local repository_hint="${ZHANLU_DELIVERY_ASSETS_REPOSITORY:-}"
    metadata_dir="$(mktemp -d "${TMPDIR:-/tmp}/zhanlu-release-metadata.XXXXXX")"

    # Workflow-artifact builds do not use a GitHub Release. Resolve and validate
    # the requested Profile directly so stale release metadata in the persistent
    # worker checkout can never affect generate-only dispatches.
    if [[ "${GENERATE_ONLY}" == true ]]; then
        prepare_release_delivery_profile "${SOURCE_BRANCH}" "${DELIVERY_PROFILE}" "${REPO}"
        rm -rf "${metadata_dir}"
        print_info "定向交付 Profile: ${DELIVERY_PROFILE}"
        print_info "zhanlu-code 固定提交: ${ZHANLU_DELIVERY_SOURCE_COMMIT}"
        print_info "Profile 摘要: ${ZHANLU_DELIVERY_PROFILE_DIGEST}"
        print_info "Release 制品仓库: ${ZHANLU_DELIVERY_ASSETS_REPOSITORY}"
        return
    fi

    if [[ -f "${local_metadata}" ]] && \
        [[ "$(jq -r '.releaseVersion // empty' "${local_metadata}")" == "${RELEASE_VERSION}" ]] && \
        [[ "$(jq -r '.deliveryProfile // empty' "${local_metadata}")" == "${DELIVERY_PROFILE}" ]] && \
        [[ "$(jq -r '.sourceRef // empty' "${local_metadata}")" == "${SOURCE_BRANCH}" ]]; then
        local_metadata_matches=true
        repository_hint="$(jq -r '.assetsRepository' "${local_metadata}")"
    fi
    if [[ -z "${repository_hint}" && "${DELIVERY_PROFILE}" == "default" ]]; then
        repository_hint="${REPO}"
    fi

    if [[ -n "${repository_hint}" ]] && gh release download "${RELEASE_VERSION}" \
        --repo "${repository_hint}" \
        --pattern zhanlu-delivery.json \
        --dir "${metadata_dir}" >/dev/null 2>&1; then
        metadata="${metadata_dir}/zhanlu-delivery.json"
    elif [[ "${local_metadata_matches}" == true ]] && \
        [[ "${repository_hint}" == "$(jq -r '.assetsRepository // empty' "${local_metadata}")" ]]; then
        metadata="${local_metadata}"
    fi

    if [[ -n "${metadata}" ]]; then
        local pinned_version pinned_profile pinned_ref pinned_repository
        pinned_version="$(jq -r '.releaseVersion // empty' "${metadata}")"
        pinned_profile="$(jq -r '.deliveryProfile' "${metadata}")"
        pinned_ref="$(jq -r '.sourceRef' "${metadata}")"
        pinned_repository="$(jq -r '.assetsRepository' "${metadata}")"
        if [[ -n "${pinned_version}" && "${pinned_version}" != "${RELEASE_VERSION}" ]] || \
            [[ "${pinned_profile}" != "${DELIVERY_PROFILE}" || "${pinned_ref}" != "${SOURCE_BRANCH}" || -z "${pinned_repository}" ]]; then
            print_error "Release ${RELEASE_VERSION} 已固定为 profile=${pinned_profile}, sourceRef=${pinned_ref}, repo=${pinned_repository}"
            rm -rf "${metadata_dir}"
            exit 1
        fi
        ZHANLU_DELIVERY_SOURCE_COMMIT="$(jq -r '.sourceCommit' "${metadata}")"
        ZHANLU_DELIVERY_PROFILE_DIGEST="$(jq -r '.profileDigest' "${metadata}")"
        ZHANLU_DELIVERY_ASSETS_REPOSITORY="${pinned_repository}"
        prepare_release_delivery_profile "${SOURCE_BRANCH}" "${DELIVERY_PROFILE}" "${REPO}"
        print_info "复用 Release 中固定的 zhanlu-code commit: ${ZHANLU_DELIVERY_SOURCE_COMMIT}"
    else
        resolve_release_delivery_profile "${SOURCE_BRANCH}" "${DELIVERY_PROFILE}" "${REPO}"
        if gh release download "${RELEASE_VERSION}" \
            --repo "${ZHANLU_DELIVERY_ASSETS_REPOSITORY}" \
            --pattern zhanlu-delivery.json \
            --dir "${metadata_dir}" >/dev/null 2>&1; then
            metadata="${metadata_dir}/zhanlu-delivery.json"
            if [[ "$(jq -r '.deliveryProfile' "${metadata}")" != "${DELIVERY_PROFILE}" || \
                "$(jq -r '.sourceRef' "${metadata}")" != "${SOURCE_BRANCH}" || \
                "$(jq -r '.assetsRepository' "${metadata}")" != "${ZHANLU_DELIVERY_ASSETS_REPOSITORY}" ]]; then
                print_error "Release ${RELEASE_VERSION} 的固定 Profile、source ref 或制品仓库与本次请求不一致"
                rm -rf "${metadata_dir}"
                exit 1
            fi
            ZHANLU_DELIVERY_SOURCE_COMMIT="$(jq -r '.sourceCommit' "${metadata}")"
            ZHANLU_DELIVERY_PROFILE_DIGEST="$(jq -r '.profileDigest' "${metadata}")"
            prepare_release_delivery_profile "${SOURCE_BRANCH}" "${DELIVERY_PROFILE}" "${REPO}"
        fi
    fi
    rm -rf "${metadata_dir}"
    export ZHANLU_DELIVERY_PROFILE="${DELIVERY_PROFILE}"
    export ZHANLU_DELIVERY_SOURCE_COMMIT ZHANLU_DELIVERY_PROFILE_DIGEST ZHANLU_DELIVERY_ASSETS_REPOSITORY
    print_info "定向交付 Profile: ${DELIVERY_PROFILE}"
    print_info "zhanlu-code 固定提交: ${ZHANLU_DELIVERY_SOURCE_COMMIT}"
    print_info "Profile 摘要: ${ZHANLU_DELIVERY_PROFILE_DIGEST}"
    print_info "Release 制品仓库: ${ZHANLU_DELIVERY_ASSETS_REPOSITORY}"
}
# zhanlu_change end

# 执行或显示命令
run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        print_info "执行: $*"
        eval "$@"
    fi
}

resolve_release_version() {
    if [[ -z "${RELEASE_VERSION}" ]]; then
        print_info "解析 Release 版本..."
        if [[ -x "./create-release.sh" ]]; then
            RELEASE_VERSION=$(./create-release.sh --print-version)
        else
            RELEASE_VERSION=$(bash ./create-release.sh --print-version)
        fi
    fi

    if [[ ! "${RELEASE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-insider)?$ ]]; then
        print_error "Release 版本格式不正确: ${RELEASE_VERSION}"
        exit 1
    fi

    if [[ -n "${VERSION_TIME_PATCH}" && ! "${VERSION_TIME_PATCH}" =~ ^[0-9]{1,4}$ ]]; then
        print_error "内部版本补丁号格式不正确: ${VERSION_TIME_PATCH}"
        exit 1
    fi

    print_info "Release 版本: ${RELEASE_VERSION}"
    if [[ -n "${VERSION_TIME_PATCH}" ]]; then
        print_info "内部版本补丁号: ${VERSION_TIME_PATCH}"
    fi
}

# zhanlu_change start - pre-create the exact draft before concurrent platform uploads
ensure_release_target() {
    if [[ "${GENERATE_ONLY}" == true ]]; then
        return
    fi

    local release_draft="${RELEASE_DRAFT:-true}"
    local wants_draft=true
    case "${release_draft}" in
        false|FALSE|0|no|NO)
            wants_draft=false
            ;;
    esac

    if [[ "${DRY_RUN}" == true ]]; then
        print_info "将确保 Release ${RELEASE_VERSION} 存在且 draft=${wants_draft}"
        return
    fi

    local existing_is_draft
    if existing_is_draft=$(gh release view "${RELEASE_VERSION}" --repo "${ZHANLU_DELIVERY_ASSETS_REPOSITORY}" --json isDraft --jq '.isDraft' 2>/dev/null); then
        if [[ "${wants_draft}" == true && "${existing_is_draft}" != true ]]; then
            print_error "Release ${RELEASE_VERSION} 已正式发布，拒绝在触发构建时自动改回 draft"
            print_error "请指定新的 --release-version，或先显式执行 gh release edit ${RELEASE_VERSION} --repo ${ZHANLU_DELIVERY_ASSETS_REPOSITORY} --draft"
            exit 1
        fi
    else
        print_info "预创建 Release ${RELEASE_VERSION}（draft=${wants_draft}）..."
    fi

    RELEASE_VERSION="${RELEASE_VERSION}" RELEASE_DRAFT="${release_draft}" \
        ZHANLU_DELIVERY_PROFILE="${DELIVERY_PROFILE}" SOURCE_BRANCH="${SOURCE_BRANCH}" \
        ZHANLU_DELIVERY_SOURCE_COMMIT="${ZHANLU_DELIVERY_SOURCE_COMMIT}" \
        ZHANLU_DELIVERY_PROFILE_DIGEST="${ZHANLU_DELIVERY_PROFILE_DIGEST}" \
        ASSETS_REPOSITORY="${ZHANLU_DELIVERY_ASSETS_REPOSITORY}" ./create-release.sh
}
# zhanlu_change end

# 使用 repository_dispatch 触发
trigger_dispatch() {
    print_info "使用 repository_dispatch 触发 stable 构建..."
    
    if [[ "$PLATFORM" != "all" ]]; then
        print_warning "repository_dispatch 模式会触发所有平台，--platform 参数将被忽略"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_info "将 POST repos/${REPO}/dispatches：event_type=stable，client_payload.source_branch=${SOURCE_BRANCH}，client_payload.zhanlu_core_ref=${ZHANLU_CORE_REF}，client_payload.zhanlu_vs_ref=${ZHANLU_VS_REF}，client_payload.release_version=${RELEASE_VERSION}，client_payload.version_time_patch=${VERSION_TIME_PATCH}" # zhanlu_change
    else
        print_info "执行: gh api repos/${REPO}/dispatches（含 client_payload.source_branch=${SOURCE_BRANCH}, client_payload.zhanlu_core_ref=${ZHANLU_CORE_REF}, client_payload.zhanlu_vs_ref=${ZHANLU_VS_REF}, client_payload.release_version=${RELEASE_VERSION}, client_payload.version_time_patch=${VERSION_TIME_PATCH}）" # zhanlu_change
        python3 -c "import json,sys; payload={'event_type':'stable','client_payload':{'source_branch':sys.argv[1],'release_version':sys.argv[3]}}; \
if len(sys.argv) > 2 and sys.argv[2]: payload['client_payload']['zhanlu_core_ref']=sys.argv[2]; \
if len(sys.argv) > 5 and sys.argv[5]: payload['client_payload']['zhanlu_vs_ref']=sys.argv[5]; \
if len(sys.argv) > 4 and sys.argv[4]: payload['client_payload']['version_time_patch']=sys.argv[4]; \
payload['client_payload'].update({'delivery_profile':sys.argv[6],'source_ref':sys.argv[1],'source_commit':sys.argv[7],'profile_digest':sys.argv[8],'assets_repository':sys.argv[9],'bundle_codex_runtime':sys.argv[10]}); \
print(json.dumps(payload))" "${SOURCE_BRANCH}" "${ZHANLU_CORE_REF}" "${RELEASE_VERSION}" "${VERSION_TIME_PATCH}" "${ZHANLU_VS_REF}" \
            "${DELIVERY_PROFILE}" "${ZHANLU_DELIVERY_SOURCE_COMMIT}" "${ZHANLU_DELIVERY_PROFILE_DIGEST}" "${ZHANLU_DELIVERY_ASSETS_REPOSITORY}" "${ZHANLU_BUNDLE_CODEX_RUNTIME}" \
            | gh api "repos/${REPO}/dispatches" --method POST --input -
    fi

    if [[ "$DRY_RUN" != true ]]; then
        print_success "已触发 repository_dispatch 事件"
        print_info "所有平台的 stable 工作流将开始执行"
        print_info "查看进度: https://github.com/${REPO}/actions"
    fi
}

# 使用 workflow_dispatch 触发
trigger_workflow() {
    local workflows=()
    
    case $PLATFORM in
        macos)
            workflows=("stable-macos.yml")
            ;;
        linux)
            workflows=("stable-linux.yml")
            ;;
        windows)
            workflows=("stable-windows.yml")
            ;;
        all)
            workflows=("stable-macos.yml" "stable-linux.yml" "stable-windows.yml")
            ;;
        *)
            print_error "未知平台: $PLATFORM"
            exit 1
            ;;
    esac

    print_info "使用 workflow_dispatch 触发构建..."

    local -a wf_fields=()
    if [[ "$GENERATE_ONLY" == true ]]; then
        wf_fields+=(-f "generate_assets=true")
        print_info "模式: 仅生成 assets（不发布）"
    else
        print_info "模式: 构建并发布"
    fi

    if [[ "$FORCE_VERSION" == true ]]; then
        wf_fields+=(-f "force_version=true")
        print_info "强制更新版本: 是"
    fi

    wf_fields+=(-f "source_branch=${SOURCE_BRANCH}")
    wf_fields+=(-f "source_ref=${SOURCE_BRANCH}")
    wf_fields+=(-f "source_commit=${ZHANLU_DELIVERY_SOURCE_COMMIT}")
    wf_fields+=(-f "delivery_profile=${DELIVERY_PROFILE}")
    wf_fields+=(-f "profile_digest=${ZHANLU_DELIVERY_PROFILE_DIGEST}")
    wf_fields+=(-f "assets_repository=${ZHANLU_DELIVERY_ASSETS_REPOSITORY}")
    wf_fields+=(-f "release_version=${RELEASE_VERSION}")
    wf_fields+=(-f "bundle_codex_runtime=${ZHANLU_BUNDLE_CODEX_RUNTIME}")
    if [[ -n "${REQUEST_ID}" ]]; then
        wf_fields+=(-f "portal_request_id=${REQUEST_ID}")
    fi
    print_info "Codex runtime bundle: ${ZHANLU_BUNDLE_CODEX_RUNTIME}"
    if [[ -n "${VERSION_TIME_PATCH}" ]]; then
        wf_fields+=(-f "version_time_patch=${VERSION_TIME_PATCH}")
        print_info "内部版本补丁号: ${VERSION_TIME_PATCH}"
    fi
    print_info "zhanlu-code 分支: ${SOURCE_BRANCH}"
    if [[ -n "${ZHANLU_CORE_REF}" ]]; then
        wf_fields+=(-f "zhanlu_core_ref=${ZHANLU_CORE_REF}")
        print_info "zhanlu-core Ref: ${ZHANLU_CORE_REF}"
    else
        print_info "zhanlu-core Ref: 使用 upstream/stable.json 中的 commit"
    fi
    # zhanlu_change start - pass the optional legacy zhanlu-vs ref to platform workflows
    if [[ -n "${ZHANLU_VS_REF}" ]]; then
        wf_fields+=(-f "zhanlu_vs_ref=${ZHANLU_VS_REF}")
        print_info "zhanlu-vs Ref: ${ZHANLU_VS_REF}"
    else
        print_info "zhanlu-vs Ref: 未选择（原生 Agent 架构）"
    fi
    # zhanlu_change end

    local runs_json="[]"
    for workflow in "${workflows[@]}"; do
        print_info "触发工作流: $workflow"
        if [[ "$DRY_RUN" == true ]]; then
            echo -e "${YELLOW}[DRY-RUN]${NC} gh workflow run ${workflow} --ref ${WORKFLOW_REF} ${wf_fields[*]}"
        else
            print_info "执行: GitHub workflow dispatch API ${workflow} --ref ${WORKFLOW_REF} …"
            local payload response
            payload="$(python3 - "${WORKFLOW_REF}" "${wf_fields[@]}" <<'PY'
import json, sys
inputs = {}
args = sys.argv[2:]
for index in range(0, len(args), 2):
    value = args[index + 1]
    if value.startswith("="):
        value = value[1:]
    inputs[value.split("=", 1)[0] if "=" in value else value] = value.split("=", 1)[1] if "=" in value else ""
print(json.dumps({"ref": sys.argv[1], "inputs": inputs}))
PY
)"
            response="$(gh api "repos/${REPO}/actions/workflows/${workflow}/dispatches" \
                --method POST \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2026-03-10" \
                --input - <<<"${payload}")"
            local run_id run_url
            run_id="$(jq -r '.workflow_run_id // .workflow_run.id // empty' <<<"${response}")"
            run_url="$(jq -r '.html_url // .workflow_run.html_url // .url // empty' <<<"${response}")"
            if [[ -z "${run_id}" || -z "${run_url}" ]]; then
                print_error "GitHub dispatch 未返回 ${workflow} 的 run ID/URL；拒绝猜测归属"
                exit 1
            fi
            runs_json="$(jq -c --arg workflow "${workflow}" --argjson runId "${run_id}" --arg url "${run_url}" '. + [{workflow: $workflow, runId: $runId, url: $url}]' <<<"${runs_json}")"
        fi

        if [[ "$DRY_RUN" != true ]]; then
            print_success "已触发 $workflow"
        fi
    done

    if [[ "$DRY_RUN" != true ]]; then
        print_info "查看进度: https://github.com/${REPO}/actions"
        if [[ "${OUTPUT_FORMAT}" == "json" ]]; then
            jq -cn --arg requestId "${REQUEST_ID}" --argjson runs "${runs_json}" \
                '{schemaVersion:"v1",requestId:($requestId|select(length>0)),runs:$runs}'
        fi
    fi
}

# 主流程
main() {
    echo "========================================"
    echo "  VSCodium Stable 构建触发脚本"
    echo "========================================"
    echo ""

    check_gh_cli
    get_repo_info
    resolve_release_version
    resolve_delivery_pin # zhanlu_change - pin profile source before creating/fanning out release jobs
    ensure_release_target # zhanlu_change - pre-create the exact release before dispatch

    echo ""
    print_info "触发模式: $TRIGGER_MODE"
    print_info "目标平台: $PLATFORM"
    print_info "Release 版本: $RELEASE_VERSION"
    if [[ -n "${VERSION_TIME_PATCH}" ]]; then
        print_info "内部版本补丁号: $VERSION_TIME_PATCH"
    fi
    print_info "zhanlu-code 分支: $SOURCE_BRANCH"
    if [[ -n "${ZHANLU_CORE_REF}" ]]; then
        print_info "zhanlu-core Ref: $ZHANLU_CORE_REF"
    else
        print_info "zhanlu-core Ref: upstream/stable.json commit"
    fi
    # zhanlu_change start - surface zhanlu-vs ref choice in trigger summary
    if [[ -n "${ZHANLU_VS_REF}" ]]; then
        print_info "zhanlu-vs Ref: $ZHANLU_VS_REF"
    else
        print_info "zhanlu-vs Ref: 未选择（原生 Agent 架构）"
    fi
    # zhanlu_change end
    print_info "仅生成 assets: $GENERATE_ONLY"
    print_info "强制更新版本: $FORCE_VERSION"
    print_info "预览模式: $DRY_RUN"
    echo ""

    case $TRIGGER_MODE in
        dispatch)
            trigger_dispatch
            ;;
        workflow)
            trigger_workflow
            ;;
    esac

    echo ""
    print_success "完成！"
}

main
