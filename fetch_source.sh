#!/usr/bin/env bash
# shellcheck disable=SC2129
# Fetch Source Code from Private Repository
# 从私有仓库获取所有源代码和构建脚本

set -e

# 保存当前目录
_CURRENT_DIR="$(pwd)"
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_REPO_URL="${SOURCE_REPO_URL:-https://github.com/village-way/zhanlu-code.git}"
SOURCE_BRANCH="${SOURCE_BRANCH:-develop}"
SOURCE_DIR="${_SCRIPT_DIR}/.source-repo"

# 如果提供了 GitHub token，则将 token 嵌入到 URL 中
# 这对于访问私有仓库是必需的
if [[ -n "${ZHANLU_GITHUB_TOKEN}" ]]; then
    # 将 https://github.com/user/repo.git 转换为 https://token@github.com/user/repo.git
    SOURCE_REPO_URL="${SOURCE_REPO_URL/https:\/\//https://${ZHANLU_GITHUB_TOKEN}@}"
    echo "Using GitHub token for authentication (private repository)"
    
    # 配置 Git credential helper 以避免交互式密码提示
    git config --global credential.helper store
    # 禁用交互式提示
    export GIT_TERMINAL_PROMPT=0
    export GIT_ASKPASS=/bin/echo
fi

echo "=== Source Code Fetching Script ==="
# 安全地显示 URL（隐藏 token）
if [[ "${SOURCE_REPO_URL}" =~ ^https://.*@github\.com ]]; then
    # 如果 URL 包含 token，则隐藏它
    DISPLAY_URL="${SOURCE_REPO_URL/@*/@***}"
    echo "SOURCE_REPO_URL: ${DISPLAY_URL}"
else
    echo "SOURCE_REPO_URL: ${SOURCE_REPO_URL}"
fi
echo "SOURCE_BRANCH: ${SOURCE_BRANCH}"
echo "SOURCE_DIR: ${SOURCE_DIR}"

# git workaround for CI environments
if [[ "${CI_BUILD}" != "no" ]] || [[ -n "${GITHUB_ACTIONS}" ]]; then
  git config --global --add safe.directory "${SOURCE_DIR}"
  # 在 CI 环境中禁用交互式提示
  export GIT_TERMINAL_PROMPT=0
fi

# 清理旧目录（如果需要强制克隆）
if [[ "${SOURCE_FORCE_CLONE}" == "yes" ]] && [[ -d "${SOURCE_DIR}" ]]; then
    echo "Force clone enabled, removing existing directory..."
    rm -rf "${SOURCE_DIR}"
fi

# 克隆或更新仓库
if [[ -d "${SOURCE_DIR}/.git" ]]; then
    echo "Source repository already exists, updating..."
    cd "${SOURCE_DIR}"
    
    # 更新 remote URL（如果提供了 token，需要更新）
    if [[ -n "${ZHANLU_GITHUB_TOKEN}" ]]; then
        git remote set-url origin "${SOURCE_REPO_URL}"
    fi
    
    # 获取最新代码
    GIT_TERMINAL_PROMPT=0 git fetch origin "${SOURCE_BRANCH}" || {
        echo "Error: Failed to fetch from origin. Check your token permissions."
        exit 1
    }
    git checkout "${SOURCE_BRANCH}" 2>/dev/null || git checkout -b "${SOURCE_BRANCH}" "origin/${SOURCE_BRANCH}"
    git reset --hard "origin/${SOURCE_BRANCH}"
    
    SOURCE_COMMIT=$(git rev-parse HEAD)
    echo "Updated to commit: ${SOURCE_COMMIT}"
else
    echo "Cloning source repository..."
    mkdir -p "${SOURCE_DIR}"
    cd "${SOURCE_DIR}"
    
    git init -q
    git remote add origin "${SOURCE_REPO_URL}"
    
    # 获取指定分支
    echo "Fetching branch: ${SOURCE_BRANCH}"
    GIT_TERMINAL_PROMPT=0 git fetch --depth 1 origin "${SOURCE_BRANCH}" || {
        echo "Error: Failed to clone repository. Check your token permissions."
        exit 1
    }
    git checkout FETCH_HEAD
    
    SOURCE_COMMIT=$(git rev-parse HEAD)
    echo "Cloned at commit: ${SOURCE_COMMIT}"
fi

# 返回到工作目录
cd "${_SCRIPT_DIR}"

# 复制所有源代码文件到当前目录
echo ""
echo "=== Copying source files ==="

# 需要复制的目录列表
DIRS_TO_COPY=(
    "build"
    "dev"
    "docs"
    "icons"
    "patches"
    "scripts"
    "src"
    "stores"
    "upstream"
)

# 复制目录
for dir in "${DIRS_TO_COPY[@]}"; do
    if [[ -d "${SOURCE_DIR}/${dir}" ]]; then
        echo "Copying ${dir}/..."
        rm -rf "${_SCRIPT_DIR}/${dir}"
        cp -r "${SOURCE_DIR}/${dir}" "${_SCRIPT_DIR}/"
    else
        echo "Warning: ${dir}/ not found in source repository"
    fi
done

# 需要复制的文件列表
FILES_TO_COPY=(
    "build.sh"
    "build_cli.sh"
    "check_cron_or_pr.sh"
    "check_tags.sh"
    "create-release.sh"
    "get_pr.sh"
    "get_repo.sh"
    "get_zhanlu.sh"
    "get_zhanlu_loc.sh"
    "write_zhanlu_root_env.sh"
    "prepare_assets.sh"
    "prepare_checksums.sh"
    "prepare_src.sh"
    "prepare_zhanlu_cli_assets.sh" # zhanlu_change - copy standalone CLI compatibility asset builder
    "prepare_vscode.sh"
    "prepare_zhanlu.sh"
    "prepare_zhanlu_loc.sh"
    "product.json"
    "release.sh"
    "release_notes.md"
    "test_zhanlu_integration.sh"
    "test_zhanlu_loc_integration.sh"
    "undo_telemetry.sh"
    "update_upstream.sh"
    "update_version.sh"
    "upload_sourcemaps.sh"
    "utils.sh"
    "version.sh"
    "announcements-builtin.json"
    "announcements-extra.json"
    "npmrc"
    ".git-msg"
    "BRANDING_GUIDE.md"
    "FIX_BUILD_ERROR.md"
    "FUNDING.json"
    "VSCODE_TECH_ANALYSIS.md"
    "ZHANLU_INTEGRATION_README.md"
)

# 复制文件
echo ""
echo "Copying individual files..."
for file in "${FILES_TO_COPY[@]}"; do
    if [[ -f "${SOURCE_DIR}/${file}" ]]; then
        echo "Copying ${file}..."
        cp "${SOURCE_DIR}/${file}" "${_SCRIPT_DIR}/"
    else
        echo "Warning: ${file} not found in source repository"
    fi
done

# 设置脚本可执行权限
echo ""
echo "Setting executable permissions..."
find "${_SCRIPT_DIR}" -type f -name "*.sh" -exec chmod +x {} \;

# 显示摘要
echo ""
echo "=== Source Code Fetch Summary ==="
echo "SOURCE_COMMIT=\"${SOURCE_COMMIT}\""
echo "SOURCE_BRANCH=\"${SOURCE_BRANCH}\""
echo "All source files copied successfully!"

# 导出环境变量（供后续脚本使用）
export SOURCE_COMMIT
export SOURCE_BRANCH

# for GH actions / CI environments
if [[ "${GITHUB_ENV}" ]]; then
    echo "SOURCE_COMMIT=${SOURCE_COMMIT}" >> "${GITHUB_ENV}"
    echo "SOURCE_BRANCH=${SOURCE_BRANCH}" >> "${GITHUB_ENV}"
fi

echo ""
echo "=== Source Code Fetching Complete ==="
