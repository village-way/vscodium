#!/usr/bin/env bash
# shellcheck disable=SC1091
# 确保已安装 gh CLI 并已登录

set -e

# 设置默认仓库（如果未设置）- 必须在加载 utils.sh 之前设置
ASSETS_REPOSITORY="${ASSETS_REPOSITORY:-village-way/vscodium}"
VSCODE_QUALITY="${VSCODE_QUALITY:-stable}"

# 加载工具函数和环境变量
. ./utils.sh

# 动态获取版本号
# 优先从环境变量 RELEASE_VERSION 获取
# 其次从 vscode/package.json 读取
# 最后从 upstream/stable.json 读取并生成

if [[ -n "${RELEASE_VERSION}" ]]; then
    VERSION="${RELEASE_VERSION}"
    echo "使用环境变量中的版本号: ${VERSION}"
elif [[ -f "vscode/package.json" ]]; then
    VERSION=$(jq -r '.version' vscode/package.json)
    echo "从 vscode/package.json 读取版本号: ${VERSION}"
elif [[ -f "upstream/${VSCODE_QUALITY}.json" ]]; then
    MS_TAG=$(jq -r '.tag' "upstream/${VSCODE_QUALITY}.json")
    # 生成补丁号：一年中的第几天 * 24 + 当前小时
    TIME_PATCH=$(printf "%04d" $(($(date +%-j) * 24 + $(date +%-H))))
    if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
        VERSION="${MS_TAG}${TIME_PATCH}-insider"
    else
        VERSION="${MS_TAG}${TIME_PATCH}"
    fi
    echo "从 upstream/${VSCODE_QUALITY}.json 生成版本号: ${VERSION}"
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

# 如果是 stable 版本，先使用 --generate-notes 生成自动的 release notes
if [[ "${VSCODE_QUALITY}" == "stable" ]] && [[ "${UPDATE_EXISTING}" == "false" ]]; then
    echo "生成自动 release notes..."
    gh release create "${VERSION}" \
        --repo "${ASSETS_REPOSITORY}" \
        --title "${VERSION}" \
        --generate-notes \
        --draft=false
    
    # 获取自动生成的 release notes
    RELEASE_NOTES=$( gh release view "${VERSION}" --repo "${ASSETS_REPOSITORY}" --json "body" --jq ".body" )
else
    # Insider 版本或更新现有 release
    RELEASE_NOTES=""
fi

# 检查 release_notes.md 模板是否存在
if [[ ! -f "release_notes.md" ]]; then
    echo "警告: release_notes.md 模板文件不存在，将使用简单的 release notes"
    if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
        NOTES="update vscode to [${MS_COMMIT:-${MS_TAG}}](https://github.com/microsoft/vscode/tree/${MS_COMMIT:-${MS_TAG}})"
    else
        NOTES="${RELEASE_NOTES:-Release ${VERSION}}"
    fi
    
    if [[ "${UPDATE_EXISTING}" == "true" ]]; then
        gh release edit "${VERSION}" --repo "${ASSETS_REPOSITORY}" --notes "${NOTES}"
    else
        # 如果已经创建了，就更新
        if [[ "${VSCODE_QUALITY}" == "stable" ]]; then
            gh release edit "${VERSION}" --repo "${ASSETS_REPOSITORY}" --notes "${NOTES}"
        fi
    fi
    exit 0
fi

# 复制模板文件用于处理
cp release_notes.md release_notes.tmp.md

# 替换模板中的占位符
if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
    replace "s|@@APP_NAME@@|${APP_NAME}|g" release_notes.tmp.md
    replace "s|@@APP_NAME_LC@@|${APP_NAME_LC}|g" release_notes.tmp.md
    replace "s|@@APP_NAME_QUALITY@@|${APP_NAME}-Insiders|g" release_notes.tmp.md
    replace "s|@@ASSETS_REPOSITORY@@|${ASSETS_REPOSITORY}|g" release_notes.tmp.md
    replace "s|@@BINARY_NAME@@|${BINARY_NAME}|g" release_notes.tmp.md
    replace "s|@@MS_TAG@@|${MS_COMMIT:-${MS_TAG}}|g" release_notes.tmp.md
    replace "s|@@MS_URL@@|https://github.com/microsoft/vscode/tree/${MS_COMMIT:-${MS_TAG}}|g" release_notes.tmp.md
    replace "s|@@QUALITY@@|-insider|g" release_notes.tmp.md
    replace "s|@@RELEASE_NOTES@@||g" release_notes.tmp.md
    replace "s|@@VERSION@@|${VERSION_CLEAN}|g" release_notes.tmp.md
else
    replace "s|@@APP_NAME@@|${APP_NAME}|g" release_notes.tmp.md
    replace "s|@@APP_NAME_LC@@|${APP_NAME_LC}|g" release_notes.tmp.md
    replace "s|@@APP_NAME_QUALITY@@|${APP_NAME}|g" release_notes.tmp.md
    replace "s|@@ASSETS_REPOSITORY@@|${ASSETS_REPOSITORY}|g" release_notes.tmp.md
    replace "s|@@BINARY_NAME@@|${BINARY_NAME}|g" release_notes.tmp.md
    replace "s|@@MS_TAG@@|${MS_TAG}|g" release_notes.tmp.md
    
    # 生成 VS Code 更新日志链接
    MS_VERSION_PARTS=$(echo "${MS_TAG}" | tr '.' '_')
    MS_VERSION_MAJOR_MINOR=$(echo "${MS_VERSION_PARTS}" | cut -d'_' -f 1,2)
    MS_URL="https://code.visualstudio.com/updates/v${MS_VERSION_MAJOR_MINOR}"
    replace "s|@@MS_URL@@|${MS_URL}|g" release_notes.tmp.md
    
    replace "s|@@QUALITY@@||g" release_notes.tmp.md
    # 转义换行符：将实际的换行符替换为 \n（与 release.sh 一致）
    if [[ -n "${RELEASE_NOTES}" ]]; then
        ESCAPED_NOTES="${RELEASE_NOTES//$'\n'/\\n}"
        replace "s|@@RELEASE_NOTES@@|${ESCAPED_NOTES}|g" release_notes.tmp.md
    else
        replace "s|@@RELEASE_NOTES@@||g" release_notes.tmp.md
    fi
    replace "s|@@VERSION@@|${VERSION_CLEAN}|g" release_notes.tmp.md
fi

# 创建或更新 release
if [[ "${UPDATE_EXISTING}" == "true" ]]; then
    echo "更新 Release notes..."
    gh release edit "${VERSION}" --repo "${ASSETS_REPOSITORY}" --notes-file release_notes.tmp.md
else
    if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
        # Insider 版本直接创建
        gh release create "${VERSION}" \
            --repo "${ASSETS_REPOSITORY}" \
            --title "${VERSION}" \
            --notes-file release_notes.tmp.md \
            --draft=false
    else
        # Stable 版本更新已创建的 release
        gh release edit "${VERSION}" --repo "${ASSETS_REPOSITORY}" --notes-file release_notes.tmp.md
    fi
fi

# 清理临时文件
rm -f release_notes.tmp.md

echo "Release ${VERSION} 创建/更新完成！"