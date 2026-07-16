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
#   --source-branch    zhanlu-code 仓库分支，默认 develop（workflow_dispatch / repository_dispatch）
#   --zhanlu-core-ref zhanlu-core 仓库分支或 commit，默认使用 upstream/stable.json 中的 commit
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
# zhanlu-core 分支 / tag / commit（为空时回退到 upstream/stable.json commit）
ZHANLU_CORE_REF=""
# zhanlu_change start - allow release operators to pin the bundled zhanlu-vs source
ZHANLU_VS_REF=""
# zhanlu_change end
# Release 版本：为空时触发前只解析一次，随后传给所有 workflow
RELEASE_VERSION="${RELEASE_VERSION:-}"
# 内部 VS Code 兼容版本的 4 位补丁号；为空时 zhanlu-code 会从 RELEASE_VERSION 派生
VERSION_TIME_PATCH="${VERSION_TIME_PATCH:-${BUILD_PATCH:-}}"

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
  --source-branch    zhanlu-code 分支，默认 develop
  --zhanlu-core-ref zhanlu-core 分支或 commit，默认使用 upstream/stable.json 中的 commit
  --zhanlu-vs-ref   zhanlu-vs 分支、标签或 commit/ref，默认使用 develop
  --release-version  指定要发布的 release/tag；默认自动解析一次并传给所有 workflow
  --version-time-patch 指定内部 VS Code 兼容版本的 4 位补丁号（可用 VERSION_TIME_PATCH 环境变量）
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
  ./scripts/trigger-stable-release.sh --workflow --source-branch master --zhanlu-core-ref aee58b29843260c3b9c7daea2dc3beefba03930b --platform all

  # 使用已创建的 release/tag 构建并上传到同一个 Release
  ./scripts/trigger-stable-release.sh --workflow --release-version 1.110.12670 --platform all

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
        --zhanlu-core-ref)
            ZHANLU_CORE_REF="$2"
            shift 2
            ;;
        # zhanlu_change start - pass a zhanlu-vs ref through manual release triggers
        --zhanlu-vs-ref)
            ZHANLU_VS_REF="$2"
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
}

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
    if existing_is_draft=$(gh release view "${RELEASE_VERSION}" --repo "${REPO}" --json isDraft --jq '.isDraft' 2>/dev/null); then
        if [[ "${wants_draft}" == true && "${existing_is_draft}" != true ]]; then
            print_error "Release ${RELEASE_VERSION} 已正式发布，拒绝在触发构建时自动改回 draft"
            print_error "请指定新的 --release-version，或先显式执行 gh release edit ${RELEASE_VERSION} --repo ${REPO} --draft"
            exit 1
        fi
    else
        print_info "预创建 Release ${RELEASE_VERSION}（draft=${wants_draft}）..."
    fi

    RELEASE_VERSION="${RELEASE_VERSION}" RELEASE_DRAFT="${release_draft}" ./create-release.sh
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
print(json.dumps(payload))" "${SOURCE_BRANCH}" "${ZHANLU_CORE_REF}" "${RELEASE_VERSION}" "${VERSION_TIME_PATCH}" "${ZHANLU_VS_REF}" \
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
    wf_fields+=(-f "release_version=${RELEASE_VERSION}")
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
    # zhanlu_change start - pass zhanlu-vs refs to platform workflows
    if [[ -n "${ZHANLU_VS_REF}" ]]; then
        wf_fields+=(-f "zhanlu_vs_ref=${ZHANLU_VS_REF}")
        print_info "zhanlu-vs Ref: ${ZHANLU_VS_REF}"
    else
        print_info "zhanlu-vs Ref: 默认引擎分支"
    fi
    # zhanlu_change end

    for workflow in "${workflows[@]}"; do
        print_info "触发工作流: $workflow"
        if [[ "$DRY_RUN" == true ]]; then
            echo -e "${YELLOW}[DRY-RUN]${NC} gh workflow run ${workflow} ${wf_fields[*]}"
        else
            print_info "执行: gh workflow run ${workflow} …"
            gh workflow run "${workflow}" "${wf_fields[@]}"
        fi

        if [[ "$DRY_RUN" != true ]]; then
            print_success "已触发 $workflow"
        fi
    done

    if [[ "$DRY_RUN" != true ]]; then
        print_info "查看进度: https://github.com/${REPO}/actions"
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
    ensure_release_target # zhanlu_change - pin visibility and download ref before dispatch

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
        print_info "zhanlu-vs Ref: 默认引擎分支"
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
