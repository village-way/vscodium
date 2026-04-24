#!/usr/bin/env bash
# shellcheck disable=SC1091
#
# 版本号生成脚本
# 用于生成和验证版本号，支持多种来源和自动生成逻辑
#
# 用法:
#   ./generate-version.sh                    # 生成版本号并输出到标准输出
#   ./generate-version.sh --export           # 生成版本号并导出为环境变量
#   ./generate-version.sh --quality=insider  # 指定版本类型
#   ./generate-version.sh --validate 1.107.10638  # 验证版本号格式
#

set -e

# 默认配置
VSCODE_QUALITY="${VSCODE_QUALITY:-stable}"
KILO_VERSION="${KILO_VERSION:-1.0.0}"
EXPORT_ENV=false
VALIDATE_ONLY=false
VERSION_TO_VALIDATE=""
VERBOSE=false

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --export)
            EXPORT_ENV=true
            shift
            ;;
        --quality=*)
            VSCODE_QUALITY="${1#*=}"
            shift
            ;;
        --validate)
            VALIDATE_ONLY=true
            VERSION_TO_VALIDATE="$2"
            shift 2
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            cat << EOF
版本号生成脚本

用法:
    $0 [选项]

选项:
    --export              导出版本号为环境变量 (RELEASE_VERSION, MS_TAG, MS_COMMIT)
    --quality=TYPE        指定版本类型: stable 或 insider (默认: stable)
    --validate VERSION    验证版本号格式
    --verbose, -v         显示详细输出
    --help, -h            显示此帮助信息

环境变量:
    RELEASE_VERSION       如果设置，将直接使用此版本号
    VSCODE_QUALITY        版本类型: stable 或 insider
    MS_TAG                上游 VS Code 标签（可选）
    MS_COMMIT             上游 VS Code commit（可选）

版本号生成优先级:
    1. 环境变量 RELEASE_VERSION
    2. KILO_VERSION + 4 位时间构建号自动生成

自动生成算法:
    TIME_PATCH = (一年中的第几天 * 24 + 当前小时) 格式化为4位数字
    版本号 = KILO_VERSION + TIME_PATCH [+ "-insider"]

示例:
    # 生成 stable 版本号
    $0

    # 生成 insider 版本号并导出
    $0 --quality=insider --export

    # 验证版本号
    $0 --validate 1.107.10638

EOF
            exit 0
            ;;
        *)
            echo "错误: 未知参数: $1" >&2
            echo "使用 --help 查看帮助信息" >&2
            exit 1
            ;;
    esac
done

# 日志函数
log_info() {
    if [[ "${VERBOSE}" == "true" ]] || [[ "${1}" != "DEBUG" ]]; then
        echo "$@"
    fi
}

log_debug() {
    if [[ "${VERBOSE}" == "true" ]]; then
        echo "[DEBUG] $@" >&2
    fi
}

log_error() {
    echo "错误: $@" >&2
}

# 验证版本号格式
validate_version() {
    local version="$1"
    local quality="${2:-stable}"
    
    if [[ -z "${version}" ]]; then
        log_error "版本号不能为空"
        return 1
    fi
    
    if [[ "${quality}" == "insider" ]]; then
        if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-insider$ ]]; then
            log_error "Insider 版本号格式不正确: ${version}"
            log_error "期望格式: X.Y.Z-insider (例如: 1.107.10638-insider)"
            return 1
        fi
    else
        if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            log_error "版本号格式不正确: ${version}"
            log_error "期望格式: X.Y.Z 或 X.Y.ZPATCH (例如: 1.107.1 或 1.107.10638)"
            return 1
        fi
    fi
    
    log_info "版本号格式验证通过: ${version}"
    return 0
}

# 如果只是验证模式
if [[ "${VALIDATE_ONLY}" == "true" ]]; then
    if validate_version "${VERSION_TO_VALIDATE}" "${VSCODE_QUALITY}"; then
        exit 0
    else
        exit 1
    fi
fi

# 计算时间补丁号
calculate_time_patch() {
    local day_of_year
    local current_hour
    local time_patch
    
    day_of_year=$(date +%-j)
    current_hour=$(date +%-H)
    time_patch=$((day_of_year * 24 + current_hour))
    
    printf "%04d" "${time_patch}"
}

# 从 upstream JSON 文件获取信息
get_upstream_info() {
    local quality="$1"
    local upstream_file="upstream/${quality}.json"
    
    if [[ ! -f "${upstream_file}" ]]; then
        log_debug "文件不存在: ${upstream_file}"
        return 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "需要 jq 命令来解析 JSON 文件"
        log_error "请安装: brew install jq 或 apt-get install jq"
        return 1
    fi
    
    MS_TAG=$(jq -r '.tag' "${upstream_file}" 2>/dev/null)
    MS_COMMIT=$(jq -r '.commit' "${upstream_file}" 2>/dev/null)
    
    if [[ -z "${MS_TAG}" ]] || [[ "${MS_TAG}" == "null" ]]; then
        log_debug "无法从 ${upstream_file} 读取 tag"
        return 1
    fi
    
    log_debug "从 ${upstream_file} 读取: MS_TAG=${MS_TAG}, MS_COMMIT=${MS_COMMIT}"
    return 0
}

# 从 VS Code API 获取最新版本信息
get_latest_from_api() {
    local quality="$1"
    local update_info
    
    log_debug "从 VS Code 更新 API 获取最新版本信息..."
    
    if ! update_info=$(curl --silent --fail "https://update.code.visualstudio.com/api/update/darwin/${quality}/0000000000000000000000000000000000000000" 2>/dev/null); then
        log_debug "无法从 API 获取版本信息"
        return 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "需要 jq 命令来解析 API 响应"
        return 1
    fi
    
    MS_COMMIT=$(echo "${update_info}" | jq -r '.version' 2>/dev/null)
    MS_TAG=$(echo "${update_info}" | jq -r '.name' 2>/dev/null)
    
    if [[ "${quality}" == "insider" ]]; then
        MS_TAG="${MS_TAG/-insider/}"
    fi
    
    if [[ -z "${MS_TAG}" ]] || [[ "${MS_TAG}" == "null" ]]; then
        log_debug "无法从 API 解析版本信息"
        return 1
    fi
    
    log_debug "从 API 获取: MS_TAG=${MS_TAG}, MS_COMMIT=${MS_COMMIT}"
    return 0
}

# 生成版本号
generate_version() {
    local quality="$1"
    local version=""
    local time_patch
    local source=""
    
    # 优先级 1: 环境变量 RELEASE_VERSION
    if [[ -n "${RELEASE_VERSION}" ]]; then
        version="${RELEASE_VERSION}"
        source="环境变量 RELEASE_VERSION"
        log_info "使用环境变量中的版本号: ${version}"
    
    fi
    
    # 优先级 2: 自动生成
    if [[ -z "${version}" ]]; then
        # 尝试从 upstream JSON 文件获取 MS_TAG
        if ! get_upstream_info "${quality}"; then
            # 如果文件不存在，尝试从 API 获取
            if ! get_latest_from_api "${quality}"; then
                log_error "无法确定版本号"
                log_error "请设置 RELEASE_VERSION 环境变量，或确保 upstream/${quality}.json 文件存在"
                return 1
            fi
        fi
        
        # 计算时间补丁号
        time_patch=$(calculate_time_patch)
        log_debug "计算时间补丁号: ${time_patch} (第$(date +%-j)天 * 24 + 当前$(date +%-H)时)"
        
        # 生成版本号
        if [[ "${quality}" == "insider" ]]; then
            version="${KILO_VERSION}${time_patch}-insider"
        else
            version="${KILO_VERSION}${time_patch}"
        fi
        
        source="自动生成 (KILO_VERSION=${KILO_VERSION}, TIME_PATCH=${time_patch})"
        log_info "从 KILO_VERSION=${KILO_VERSION} 生成版本号: ${version}"
    fi
    
    # 验证版本号格式
    if ! validate_version "${version}" "${quality}"; then
        return 1
    fi
    
    # 输出结果
    if [[ "${EXPORT_ENV}" == "true" ]]; then
        # 导出环境变量
        export RELEASE_VERSION="${version}"
        export MS_TAG="${MS_TAG:-}"
        export MS_COMMIT="${MS_COMMIT:-}"
        export VSCODE_QUALITY="${quality}"
        
        # 如果是 GitHub Actions，写入 GITHUB_ENV
        if [[ -n "${GITHUB_ENV}" ]]; then
            echo "RELEASE_VERSION=${version}" >> "${GITHUB_ENV}"
            [[ -n "${MS_TAG}" ]] && echo "MS_TAG=${MS_TAG}" >> "${GITHUB_ENV}"
            [[ -n "${MS_COMMIT}" ]] && echo "MS_COMMIT=${MS_COMMIT}" >> "${GITHUB_ENV}"
            echo "VSCODE_QUALITY=${quality}" >> "${GITHUB_ENV}"
            log_info "版本信息已写入 ${GITHUB_ENV}"
        fi
        
        log_info "版本信息已导出为环境变量:"
        log_info "  RELEASE_VERSION=${version}"
        [[ -n "${MS_TAG}" ]] && log_info "  MS_TAG=${MS_TAG}"
        [[ -n "${MS_COMMIT}" ]] && log_info "  MS_COMMIT=${MS_COMMIT}"
    else
        # 只输出版本号
        echo "${version}"
    fi
    
    log_debug "版本号来源: ${source}"
    return 0
}

# 主函数
main() {
    log_debug "版本类型: ${VSCODE_QUALITY}"
    log_debug "工作目录: $(pwd)"
    
    # 验证版本类型
    if [[ "${VSCODE_QUALITY}" != "stable" ]] && [[ "${VSCODE_QUALITY}" != "insider" ]]; then
        log_error "无效的版本类型: ${VSCODE_QUALITY}"
        log_error "必须是 'stable' 或 'insider'"
        exit 1
    fi
    
    # 生成版本号
    if ! generate_version "${VSCODE_QUALITY}"; then
        exit 1
    fi
}

# 执行主函数
main "$@"
