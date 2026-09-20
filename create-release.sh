#!/usr/bin/env bash
# shellcheck disable=SC1091
# 确保已安装 gh CLI 并已登录

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

TMP_FILES=()

cleanup() {
    if [[ "${#TMP_FILES[@]}" -gt 0 ]]; then
        rm -f "${TMP_FILES[@]}"
    fi
}

trap cleanup EXIT

make_tmp() {
    local file
    file="$(mktemp)"
    TMP_FILES+=("${file}")
    echo "${file}"
}

# 设置默认仓库（如果未设置）- 必须在加载 utils.sh 之前设置
ASSETS_REPOSITORY="${ASSETS_REPOSITORY:-${GITHUB_REPOSITORY:-}}" # zhanlu_change - default to the workflow repository
VSCODE_QUALITY="${VSCODE_QUALITY:-stable}"
KILO_VERSION="${KILO_VERSION:-1.2.0}"
# zhanlu_change start - the source-side release hook lives in the private source tree
# -g runs it after the GitHub release is created; ZHANLU_GITLAB_RELEASE_SCRIPT points at it.
ZHANLU_GITLAB_RELEASE_SCRIPT="${ZHANLU_GITLAB_RELEASE_SCRIPT:-}"
ZHANLU_WORKSPACE_ROOT="${ZHANLU_WORKSPACE_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
# zhanlu_change end
PRINT_VERSION_ONLY=false
DRY_RUN_VERSION=false
SYNC_GITLAB=
# zhanlu_change start - customer delivery profile selection
SOURCE_BRANCH="${SOURCE_BRANCH:-develop}"
ZHANLU_DELIVERY_PROFILE="${ZHANLU_DELIVERY_PROFILE:-default}"
# zhanlu_change end

while [[ $# -gt 0 ]]; do
    case "$1" in
        -g)
            SYNC_GITLAB=1
            shift
            ;;
        --print-version)
            PRINT_VERSION_ONLY=true
            shift
            ;;
        --dry-run-version)
            DRY_RUN_VERSION=true
            shift
            ;;
        --source-branch)
            SOURCE_BRANCH="$2"
            shift 2
            ;;
        --delivery-profile)
            ZHANLU_DELIVERY_PROFILE="$2"
            shift 2
            ;;
        --help|-h)
            cat << EOF
Usage: ./create-release.sh [-g] [--print-version|--dry-run-version]

Options:
  -g                  Run the source-side release hook (ZHANLU_GITLAB_RELEASE_SCRIPT) after the GitHub release
  --print-version     Print only the resolved release version and exit
  --dry-run-version   Print RELEASE_VERSION=<version> and exit
  --source-branch     zhanlu-code branch/ref, default develop
  --delivery-profile  Delivery profile id, default default
EOF
            exit 0
            ;;
        *)
            echo "错误: 未知选项: $1"
            exit 1
            ;;
    esac
done

log_version() {
    if [[ "${PRINT_VERSION_ONLY}" != "true" && "${DRY_RUN_VERSION}" != "true" ]]; then
        echo "$1"
    fi
}

# 加载工具函数和环境变量
. "${SCRIPT_DIR}/utils.sh"

# zhanlu_change start - GitLab tags/releases are created by the private hook, not here
sync_gitlab_releases() {
    if [[ -z "${ZHANLU_GITLAB_RELEASE_SCRIPT}" ]]; then
        echo "错误: -g 需要设置 ZHANLU_GITLAB_RELEASE_SCRIPT 指向源码侧发布脚本"
        exit 1
    fi
    if [[ ! -f "${ZHANLU_GITLAB_RELEASE_SCRIPT}" ]]; then
        echo "错误: ZHANLU_GITLAB_RELEASE_SCRIPT 不存在: ${ZHANLU_GITLAB_RELEASE_SCRIPT}"
        exit 1
    fi
    echo "运行源码侧发布脚本: ${GITLAB_TAG}"
    GITLAB_TAG="${GITLAB_TAG}" RELEASE_VERSION="${VERSION}" RELEASE_DATE="${RELEASE_DATE}" \
        ZHANLU_WORKSPACE_ROOT="${ZHANLU_WORKSPACE_ROOT}" \
        bash "${ZHANLU_GITLAB_RELEASE_SCRIPT}"
}
# zhanlu_change end

# 动态获取版本号
# 优先从环境变量 RELEASE_VERSION 获取
# 否则使用 KILO_VERSION + VSCodium 4 位时间构建号生成
# 显式 RELEASE_VERSION 可以是标准 SemVer（如 1.0.1）；构建脚本会单独派生内部 VS Code 兼容补丁号

if [[ -n "${RELEASE_VERSION}" ]]; then
    VERSION="${RELEASE_VERSION}"
    log_version "使用环境变量中的版本号: ${VERSION}"
elif [[ -f "upstream/${VSCODE_QUALITY}.json" ]]; then
    MS_TAG=$(jq -r '.tag' "upstream/${VSCODE_QUALITY}.json")
    # 生成补丁号：一年中的第几天 * 24 + 当前小时
    TIME_PATCH=$(printf "%04d" $(($(date +%-j) * 24 + $(date +%-H))))
    if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
        VERSION="${KILO_VERSION}${TIME_PATCH}-insider"
    else
        VERSION="${KILO_VERSION}${TIME_PATCH}"
    fi
    log_version "从 KILO_VERSION=${KILO_VERSION} 生成版本号: ${VERSION}"
else
    echo "错误: 无法确定版本号，请设置 RELEASE_VERSION 环境变量"
    exit 1
fi

# 验证版本号格式
if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
    if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-insider$ ]]; then
        echo "错误: Insider 版本号格式不正确: ${VERSION}"
        exit 1
    fi
else
    if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        echo "错误: 版本号格式不正确: ${VERSION}"
        exit 1
    fi
fi

# 获取 MS_TAG 和 MS_COMMIT（如果未设置）
if [[ -z "${MS_TAG}" ]] || [[ -z "${MS_COMMIT}" ]]; then
    if [[ -f "upstream/${VSCODE_QUALITY}.json" ]]; then
        MS_TAG="${MS_TAG:-$(jq -r '.tag' "upstream/${VSCODE_QUALITY}.json")}"
        MS_COMMIT="${MS_COMMIT:-$(jq -r '.commit' "upstream/${VSCODE_QUALITY}.json")}"
    fi
fi

if [[ "${PRINT_VERSION_ONLY}" == "true" ]]; then
    echo "${VERSION}"
    exit 0
elif [[ "${DRY_RUN_VERSION}" == "true" ]]; then
    echo "RELEASE_VERSION=${VERSION}"
    exit 0
fi

# zhanlu_change start - validate the profile, exact source commit and allowlisted target before touching a release
# Outside GitHub Actions GITHUB_REPOSITORY is unset; fall back to the checkout's repository instead of
# pinning an empty assetsRepository that every later trigger would reject.
if [[ -z "${ASSETS_REPOSITORY}" ]]; then
    ASSETS_REPOSITORY="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
if [[ -z "${ASSETS_REPOSITORY}" ]]; then
    echo "错误: 无法确定 Release 仓库，请设置 ASSETS_REPOSITORY（如 owner/repo）"
    exit 1
fi
source "${SCRIPT_DIR}/scripts/resolve-release-delivery-profile.sh"
prepare_release_delivery_profile "${SOURCE_BRANCH}" "${ZHANLU_DELIVERY_PROFILE}" "${ASSETS_REPOSITORY}"
ASSETS_REPOSITORY="${ZHANLU_DELIVERY_ASSETS_REPOSITORY}"

upload_delivery_metadata() {
    local metadata_dir
    local metadata
    metadata_dir="$(mktemp -d "${TMPDIR:-/tmp}/zhanlu-delivery-metadata.XXXXXX")"
    metadata="${metadata_dir}/zhanlu-delivery.json"
    write_release_delivery_metadata "${metadata}"
    mkdir -p "${SCRIPT_DIR}/.zhanlu"
    cp "${metadata}" "${SCRIPT_DIR}/.zhanlu/release-delivery.json"
    chmod 600 "${SCRIPT_DIR}/.zhanlu/release-delivery.json"
    gh release upload "${VERSION}" "${metadata}" --repo "${ASSETS_REPOSITORY}" --clobber
    rm -rf "${metadata_dir}"
}
# zhanlu_change end

RELEASE_DATE="${RELEASE_DATE:-$(date +%Y%m%d)}"
if [[ ! "${RELEASE_DATE}" =~ ^[0-9]{8}$ ]]; then
    echo "错误: RELEASE_DATE 格式不正确，请使用 YYYYMMDD: ${RELEASE_DATE}"
    exit 1
fi

GITLAB_TAG="${GITLAB_TAG:-release_zhanlu-code_v${VERSION}_${RELEASE_DATE}}" # zhanlu_change - source-side tag name, new prefix since the zhanlu-core entry repository

# zhanlu_change start - default GitHub releases to draft; set RELEASE_DRAFT=false to publish
RELEASE_DRAFT="${RELEASE_DRAFT:-true}"
case "${RELEASE_DRAFT}" in
    false|FALSE|0|no|NO)
        DRAFT_FLAG="--draft=false"
        echo "RELEASE_DRAFT=${RELEASE_DRAFT}: creating/updating as published release"
        ;;
    *)
        DRAFT_FLAG="--draft"
        echo "RELEASE_DRAFT=${RELEASE_DRAFT}: creating/updating as draft release"
        ;;
esac
# zhanlu_change end

# 检查 release 是否已存在
if gh release view "${VERSION}" --repo "${ASSETS_REPOSITORY}" &>/dev/null; then
    echo "Release ${VERSION} 已存在，将更新 release notes"
    UPDATE_EXISTING=true
else
    echo "创建新 Release: ${VERSION}"
    UPDATE_EXISTING=false
fi

# 准备变量
APP_NAME_LC="$( echo "${APP_NAME}" | awk '{print tolower($0)}' )"
VERSION_CLEAN="${VERSION%-insider}"

# 确保 tag 存在（如果不存在则创建）
# zhanlu_change start - unique empty commit per new tag so GitHub Release created_at advances
if ! git ls-remote --tags origin | grep -q "refs/tags/${VERSION}$"; then
    echo "远程仓库不存在 tag: ${VERSION}，正在创建..."
    if git rev-parse "${VERSION}" &>/dev/null; then
        echo "本地已存在 tag: ${VERSION}，将直接推送到远程"
    else
        # GitHub sets release created_at from the tagged commit date, not draft/upload time.
        echo "创建 empty commit，使 Release created_at 对应该发版时刻..."
        git commit --allow-empty -m "release: ${VERSION}"
        git push origin HEAD
        git tag "${VERSION}"
    fi
    git push origin "${VERSION}"
    echo "Tag ${VERSION} 已推送到远程仓库"
fi
# zhanlu_change end

# 如果是 stable 版本，先使用 --generate-notes 生成自动的 release notes
if [[ "${VSCODE_QUALITY}" == "stable" ]] && [[ "${UPDATE_EXISTING}" == "false" ]]; then
    echo "生成自动 release notes..."
    gh release create "${VERSION}" \
        --repo "${ASSETS_REPOSITORY}" \
        --title "${VERSION}" \
        --generate-notes \
        "${DRAFT_FLAG}" # zhanlu_change - honor RELEASE_DRAFT

    # 获取自动生成的 release notes
    RELEASE_NOTES=$( gh release view "${VERSION}" --repo "${ASSETS_REPOSITORY}" --json "body" --jq ".body" )
else
    # Insider 版本或更新现有 release
    RELEASE_NOTES=""
fi

# zhanlu_change start - create new Insider releases before rendering their notes
if [[ "${VSCODE_QUALITY}" == "insider" ]] && [[ "${UPDATE_EXISTING}" == "false" ]]; then
    gh release create "${VERSION}" \
        --repo "${ASSETS_REPOSITORY}" \
        --title "${VERSION}" \
        --notes "Preparing ${VERSION} release assets." \
        "${DRAFT_FLAG}"
fi
# zhanlu_change end

# 检查 release_notes.md 模板是否存在
if [[ ! -f "release_notes.md" ]]; then
    echo "警告: release_notes.md 模板文件不存在，将使用简单的 release notes"
    if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
        NOTES="update vscode to [${MS_COMMIT:-${MS_TAG}}](https://github.com/microsoft/vscode/tree/${MS_COMMIT:-${MS_TAG}})"
    else
        NOTES="${RELEASE_NOTES:-Release ${VERSION}}"
    fi

    gh release edit "${VERSION}" --repo "${ASSETS_REPOSITORY}" --notes "${NOTES}" "${DRAFT_FLAG}" # zhanlu_change - update notes and visibility together
    upload_delivery_metadata # zhanlu_change
    [[ -n "${SYNC_GITLAB}" ]] && sync_gitlab_releases
    exit 0
fi

# 复制模板文件用于处理
RELEASE_NOTES_FILE="$(make_tmp)"
cp release_notes.md "${RELEASE_NOTES_FILE}"

# 替换模板中的占位符
if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
    replace "s|@@APP_NAME@@|${APP_NAME}|g" "${RELEASE_NOTES_FILE}"
    replace "s|@@APP_NAME_LC@@|${APP_NAME_LC}|g" "${RELEASE_NOTES_FILE}"
    replace "s|@@APP_NAME_QUALITY@@|${APP_NAME}-Insiders|g" "${RELEASE_NOTES_FILE}"
    replace "s|@@ASSETS_REPOSITORY@@|${ASSETS_REPOSITORY}|g" "${RELEASE_NOTES_FILE}"
    replace "s|@@BINARY_NAME@@|${BINARY_NAME}|g" "${RELEASE_NOTES_FILE}"
    replace "s|@@MS_TAG@@|${MS_COMMIT:-${MS_TAG}}|g" "${RELEASE_NOTES_FILE}"
    replace "s|@@MS_URL@@|https://github.com/microsoft/vscode/tree/${MS_COMMIT:-${MS_TAG}}|g" "${RELEASE_NOTES_FILE}"
    replace "s|@@QUALITY@@|-insider|g" "${RELEASE_NOTES_FILE}"
    replace "s|@@RELEASE_NOTES@@||g" "${RELEASE_NOTES_FILE}"
    replace "s|@@VERSION@@|${VERSION_CLEAN}|g" "${RELEASE_NOTES_FILE}"
else
    replace "s|@@APP_NAME@@|${APP_NAME}|g" "${RELEASE_NOTES_FILE}"
    replace "s|@@APP_NAME_LC@@|${APP_NAME_LC}|g" "${RELEASE_NOTES_FILE}"
    replace "s|@@APP_NAME_QUALITY@@|${APP_NAME}|g" "${RELEASE_NOTES_FILE}"
    replace "s|@@ASSETS_REPOSITORY@@|${ASSETS_REPOSITORY}|g" "${RELEASE_NOTES_FILE}"
    replace "s|@@BINARY_NAME@@|${BINARY_NAME}|g" "${RELEASE_NOTES_FILE}"
    replace "s|@@MS_TAG@@|${MS_TAG}|g" "${RELEASE_NOTES_FILE}"

    # 生成 VS Code 更新日志链接
    MS_VERSION_PARTS=$(echo "${MS_TAG}" | tr '.' '_')
    MS_VERSION_MAJOR_MINOR=$(echo "${MS_VERSION_PARTS}" | cut -d'_' -f 1,2)
    MS_URL="https://code.visualstudio.com/updates/v${MS_VERSION_MAJOR_MINOR}"
    replace "s|@@MS_URL@@|${MS_URL}|g" "${RELEASE_NOTES_FILE}"

    replace "s|@@QUALITY@@||g" "${RELEASE_NOTES_FILE}"
    # 转义换行符：将实际的换行符替换为 \n（与 release.sh 一致）
    if [[ -n "${RELEASE_NOTES}" ]]; then
        ESCAPED_NOTES="${RELEASE_NOTES//$'\n'/\\n}"
        replace "s|@@RELEASE_NOTES@@|${ESCAPED_NOTES}|g" "${RELEASE_NOTES_FILE}"
    else
        replace "s|@@RELEASE_NOTES@@||g" "${RELEASE_NOTES_FILE}"
    fi
    replace "s|@@VERSION@@|${VERSION_CLEAN}|g" "${RELEASE_NOTES_FILE}"
fi

# zhanlu_change start - draft URLs rotate; rely on GitHub's native Assets list instead
if [[ "${DRAFT_FLAG}" == "--draft" ]]; then
    replace "s|href=\"https://github.com/${ASSETS_REPOSITORY}/releases/download/[^\"]+\"|href=\"#user-content-assets\"|g" "${RELEASE_NOTES_FILE}"
    printf '\n<a id="assets"></a>\n## Assets\n\nDraft release: download artifacts from the GitHub Assets section below.\n' >> "${RELEASE_NOTES_FILE}"
fi

# zhanlu_change start - retain human-readable and machine-readable delivery provenance
DELIVERY_METADATA_JSON="$(jq -cn \
    --arg profile "${ZHANLU_DELIVERY_PROFILE}" \
    --arg sourceRef "${SOURCE_BRANCH}" \
    --arg sourceCommit "${ZHANLU_DELIVERY_SOURCE_COMMIT}" \
    --arg profileDigest "${ZHANLU_DELIVERY_PROFILE_DIGEST}" \
    --arg assetsRepository "${ASSETS_REPOSITORY}" \
    '{deliveryProfile:$profile,sourceRef:$sourceRef,sourceCommit:$sourceCommit,profileDigest:$profileDigest,assetsRepository:$assetsRepository}')"
printf '\n<!-- zhanlu-delivery %s -->\n' "${DELIVERY_METADATA_JSON}" >> "${RELEASE_NOTES_FILE}"
# zhanlu_change end

echo "更新 Release notes..."
gh release edit "${VERSION}" --repo "${ASSETS_REPOSITORY}" --notes-file "${RELEASE_NOTES_FILE}" "${DRAFT_FLAG}"
upload_delivery_metadata # zhanlu_change - platform triggers reuse this exact pin
# zhanlu_change end

if [[ -n "${SYNC_GITLAB}" ]]; then
    sync_gitlab_releases
fi

echo "Release ${VERSION} 创建/更新完成！"
echo "RELEASE_VERSION=${VERSION}"
if [[ -n "${SYNC_GITLAB}" ]]; then
    echo "GITLAB_RELEASE_TAG=${GITLAB_TAG}"
fi

exit 0
