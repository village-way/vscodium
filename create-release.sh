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
ASSETS_REPOSITORY="${ASSETS_REPOSITORY:-village-way/vscodium}"
VSCODE_QUALITY="${VSCODE_QUALITY:-stable}"
KILO_VERSION="${KILO_VERSION:-1.2.0}"
GITLAB_HOST="${GITLAB_HOST:-http://gitlab.cmss.com}"
GITLAB_GROUP="${GITLAB_GROUP:-AI_engine/zhanlu}"
GITLAB_RELEASE_REPOS="${GITLAB_RELEASE_REPOS:-zhanlu-cloud zhanlu-code zhanlu-core zhanlu-loc zhanlu-vs}"
ZHANLU_IDE_ROOT="${ZHANLU_IDE_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
GITLAB_FORCE_TAG_UPDATE="${GITLAB_FORCE_TAG_UPDATE:-false}"
PRINT_VERSION_ONLY=false
DRY_RUN_VERSION=false
SYNC_GITLAB=

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
        --help|-h)
            cat << EOF
Usage: ./create-release.sh [-g] [--print-version|--dry-run-version]

Options:
  -g                  同步 GitLab tag 与 Release（默认仅 GitHub）
  --print-version     Print only the resolved release version and exit
  --dry-run-version   Print RELEASE_VERSION=<version> and exit
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

remote_tag_sha() {
    local dir="$1"
    local tag="$2"
    local refs
    local peeled
    local direct

    refs="$(git -C "${dir}" ls-remote origin "refs/tags/${tag}" "refs/tags/${tag}^{}")"
    peeled="$(printf "%s\n" "${refs}" | awk '/\^\{\}$/ {print $1; exit}')"
    if [[ -n "${peeled}" ]]; then
        echo "${peeled}"
        return
    fi

    direct="$(printf "%s\n" "${refs}" | awk '{print $1; exit}')"
    if [[ -n "${direct}" ]]; then
        echo "${direct}"
    fi
}

ensure_gitlab_tag() {
    local dir="$1"
    local tag="$2"
    local sha="$3"
    local remote
    local local_sha
    local push_nv=()

    if [[ "$(basename "${dir}")" == "zhanlu-core" ]]; then
        push_nv=(--no-verify)
    fi

    remote="$(remote_tag_sha "${dir}" "${tag}")"
    if [[ -z "${remote}" ]]; then
        if git -C "${dir}" rev-parse -q --verify "refs/tags/${tag}" &>/dev/null; then
            local_sha="$(git -C "${dir}" rev-list -n 1 "refs/tags/${tag}")"
            if [[ "${local_sha}" != "${sha}" ]]; then
                git -C "${dir}" tag -f "${tag}" "${sha}"
            fi
        else
            git -C "${dir}" tag "${tag}" "${sha}"
        fi

        git -C "${dir}" push "${push_nv[@]}" origin "refs/tags/${tag}"
        echo "GitLab tag ${tag} 已推送"
        return
    fi

    if [[ "${remote}" == "${sha}" ]]; then
        echo "GitLab tag ${tag} 已存在且指向当前提交"
        return
    fi

    if [[ "${GITLAB_FORCE_TAG_UPDATE}" != "true" ]]; then
        echo "错误: GitLab tag ${tag} 已存在但指向不同提交"
        echo "  remote: ${remote}"
        echo "  target: ${sha}"
        echo "如需强制移动 tag，请设置 GITLAB_FORCE_TAG_UPDATE=true"
        exit 1
    fi

    git -C "${dir}" tag -f "${tag}" "${sha}"
    git -C "${dir}" push "${push_nv[@]}" -f origin "refs/tags/${tag}"
    echo "GitLab tag ${tag} 已强制更新"
}

write_gitlab_notes() {
    local repo="$1"
    local dir="$2"
    local tag="$3"
    local sha="$4"
    local file="$5"
    local short
    local prev
    local range
    local commits

    short="$(git -C "${dir}" rev-parse --short "${sha}")"
    prev="$(git -C "${dir}" describe --tags --abbrev=0 --exclude "${tag}" "${sha}" 2>/dev/null || true)"

    if [[ -n "${prev}" ]]; then
        range="${prev}..${short}"
        commits="$(git -C "${dir}" log --no-merges --oneline "${prev}..${sha}")"
    else
        range="initial history through ${short}"
        commits="$(git -C "${dir}" log --no-merges --oneline -20 "${sha}")"
    fi

    {
        echo "# ${tag}"
        echo
        echo "- Repository: ${repo}"
        echo "- Commit: ${short}"
        echo "- Range: ${range}"
        echo
        echo "## Commits"
        echo
        if [[ -n "${commits}" ]]; then
            printf "%s\n" "${commits}" | sed "s/^/- /"
        else
            echo "- No commit changes since previous tag."
        fi
    } > "${file}"
}

sync_gitlab_releases() {
    if ! command -v glab &>/dev/null; then
        echo "错误: 未找到 glab，请先安装 GitLab CLI"
        exit 1
    fi

    if [[ -z "${GITLAB_TOKEN:-}" && -z "${GITLAB_ACCESS_TOKEN:-}" ]]; then
        echo "错误: 请通过 GITLAB_TOKEN 或 GITLAB_ACCESS_TOKEN 提供 GitLab token"
        exit 1
    fi

    echo "同步 GitLab Release: ${GITLAB_TAG}"

    local repo
    for repo in ${GITLAB_RELEASE_REPOS}; do
        local dir="${ZHANLU_IDE_ROOT}/${repo}"
        local project="${GITLAB_HOST%/}/${GITLAB_GROUP}/${repo}"
        local sha
        local notes

        if [[ ! -d "${dir}/.git" && ! -f "${dir}/.git" ]]; then
            echo "错误: ${dir} 不是 git 仓库"
            exit 1
        fi

        sha="$(git -C "${dir}" rev-parse HEAD)"
        echo "处理 ${repo}: ${sha}"

        ensure_gitlab_tag "${dir}" "${GITLAB_TAG}" "${sha}"

        notes="$(make_tmp)"
        write_gitlab_notes "${repo}" "${dir}" "${GITLAB_TAG}" "${sha}" "${notes}"

        glab release create "${GITLAB_TAG}" \
            --repo "${project}" \
            --ref "${sha}" \
            --name "${GITLAB_TAG}" \
            --notes-file "${notes}"
    done
}

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

RELEASE_DATE="${RELEASE_DATE:-$(date +%Y%m%d)}"
if [[ ! "${RELEASE_DATE}" =~ ^[0-9]{8}$ ]]; then
    echo "错误: RELEASE_DATE 格式不正确，请使用 YYYYMMDD: ${RELEASE_DATE}"
    exit 1
fi

GITLAB_TAG="release_zhanlu-ide_v${VERSION}_${RELEASE_DATE}"

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
if ! git ls-remote --tags origin | grep -q "refs/tags/${VERSION}$"; then
    echo "远程仓库不存在 tag: ${VERSION}，正在创建..."
    # 如果本地也没有这个 tag，先创建本地 tag
    if ! git rev-parse "${VERSION}" &>/dev/null; then
        git tag "${VERSION}"
    fi
    git push origin "${VERSION}"
    echo "Tag ${VERSION} 已推送到远程仓库"
fi

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

echo "更新 Release notes..."
gh release edit "${VERSION}" --repo "${ASSETS_REPOSITORY}" --notes-file "${RELEASE_NOTES_FILE}" "${DRAFT_FLAG}"
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
