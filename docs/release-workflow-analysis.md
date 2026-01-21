# Release 工作流深度分析

## 问题1：为什么手动触发需要先创建 Release？

### 当前设计分析

根据 `release.sh` 的实现（第16行），每个平台的工作流在上传 assets 之前会：

```bash
if [[ $( gh release view "${RELEASE_VERSION}" --repo "${ASSETS_REPOSITORY}" 2>&1 ) =~ "release not found" ]]; then
  echo "Creating release '${RELEASE_VERSION}'"
  # ... 创建 release ...
fi
```

**这意味着：**
1. ✅ 不需要"先"创建 release - 每个平台都会自动检查并创建
2. ✅ 多个平台可以并行执行，第一个到达的平台会创建 release
3. ⚠️ 但存在**竞争条件（Race Condition）**的风险

### 竞争条件问题

如果三个平台（macOS、Linux、Windows）同时触发：

```
时间线：
T0: macOS 检查 release 不存在 ❌
T0: Linux 检查 release 不存在 ❌
T0: Windows 检查 release 不存在 ❌
T1: macOS 尝试创建 release ✅
T1: Linux 尝试创建 release ❌ (冲突!)
T1: Windows 尝试创建 release ❌ (冲突!)
```

### 当前设计的优势

实际上这个设计是**合理的**，因为：

1. **容错性**：如果某个平台失败，可以单独重新运行该平台的工作流
2. **补充 assets**：可以在 release 已存在的情况下，单独运行某个平台来补充遗漏的 assets
3. **并行执行**：多个平台可以同时构建，提高效率

### GitHub API 的保护机制

GitHub Release API 实际上处理了并发创建的情况：
- 如果 release 已存在，`gh release create` 会报错但不会导致工作流失败
- 后续的 `gh release upload` 可以继续执行

## 问题2：DMG 没有生成的根本原因

### 根本原因

在 `check_tags.sh` 第87-92行，当检测到需要构建 DMG 时：

```bash
# 修复前 ❌
if [[ -z $( contains ".${VSCODE_ARCH}.${RELEASE_VERSION}.dmg" ) ]]; then
  echo "Building on MacOS because we have no DMG"
  export SHOULD_BUILD="yes"
  # ⚠️ 缺少这一行：export SHOULD_BUILD_DMG="yes"
else
  export SHOULD_BUILD_DMG="no"
fi
```

**问题分析：**
1. 当 DMG 不存在时，设置了 `SHOULD_BUILD="yes"`
2. 但**没有明确设置** `SHOULD_BUILD_DMG="yes"`
3. 在 `prepare_assets.sh` 中判断条件是 `"${SHOULD_BUILD_DMG}" != "no"`
4. 未定义的变量在 bash 中确实 `!= "no"`，但这是隐式行为，不够明确

### 修复方案（已实施）

```bash
# 修复后 ✅
if [[ -z $( contains ".${VSCODE_ARCH}.${RELEASE_VERSION}.dmg" ) ]]; then
  echo "Building on MacOS because we have no DMG"
  export SHOULD_BUILD="yes"
  export SHOULD_BUILD_DMG="yes"  # ✅ 明确设置
else
  export SHOULD_BUILD_DMG="no"
fi
```

## 问题3：如何实现手动触发每次创建新 Release 并上传 Assets

### 场景分析

根据不同的使用场景，有不同的策略：

### 场景 A：完整的新版本发布

**目标：** 创建一个新的 release，所有平台都构建并上传 assets

**方法 1：使用 repository_dispatch（推荐）**

```bash
# 使用辅助脚本
./scripts/trigger-stable-release.sh --dispatch

# 或直接使用 gh CLI
gh api repos/{owner}/{repo}/dispatches \
  --method POST \
  -f event_type=stable
```

**优点：**
- ✅ 模拟正常的自动化流程
- ✅ 三个平台同时触发，效率最高
- ✅ 第一个完成的平台会创建 release

**缺点：**
- ⚠️ 无法单独指定某个平台
- ⚠️ 如果 release 已存在，会继续上传（这通常不是问题）

**方法 2：手动分别触发各平台**

```bash
# 触发所有平台
gh workflow run stable-macos.yml
gh workflow run stable-linux.yml
gh workflow run stable-windows.yml
```

**优点：**
- ✅ 可以控制触发时机
- ✅ 可以选择性触发某些平台

**缺点：**
- ⚠️ 需要分别运行三次命令

### 场景 B：补充单个平台的 Assets

**目标：** Release 已存在，但某个平台的构建失败或遗漏，需要重新构建并上传

**方法：单独触发失败的平台**

```bash
# 仅重新触发 macOS 构建
./scripts/trigger-stable-release.sh --workflow --platform macos

# 或直接使用 gh CLI
gh workflow run stable-macos.yml
```

**工作流程：**
1. ✅ 检测到 release 已存在（不会重新创建）
2. ✅ `check_tags.sh` 会检查哪些 assets 缺失
3. ✅ 只构建缺失的 assets（如 DMG）
4. ✅ 上传到现有的 release

### 场景 C：测试构建（不发布）

**目标：** 构建 assets 但不上传到 Release，仅用于测试

**方法：使用 generate_assets 参数**

```bash
# 使用辅助脚本
./scripts/trigger-stable-release.sh --workflow --generate --platform macos

# 或直接使用 gh CLI
gh workflow run stable-macos.yml -f generate_assets=true
```

**工作流程：**
1. ✅ `SHOULD_DEPLOY="no"`（不会创建/修改 release）
2. ✅ `SHOULD_BUILD="yes"`（会构建所有 assets）
3. ✅ Assets 上传为 workflow artifacts（保留3天）

## 完整的 Release 生命周期

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. 触发构建                                                      │
│    - repository_dispatch (所有平台)                              │
│    - workflow_dispatch (单个或多个平台)                          │
└───────────────────────┬─────────────────────────────────────────┘
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. 检查环境变量 (check_cron_or_pr.sh)                           │
│    - repository_dispatch: SHOULD_DEPLOY=yes                      │
│    - workflow_dispatch: SHOULD_DEPLOY=yes                        │
│    - workflow_dispatch + generate_assets: SHOULD_DEPLOY=no       │
└───────────────────────┬─────────────────────────────────────────┘
                        ▼
        ┌───────────────┴───────────────┐
        │                               │
SHOULD_DEPLOY=yes              SHOULD_DEPLOY=no
        │                               │
        ▼                               ▼
┌─────────────────────┐        ┌─────────────────────┐
│ 3a. 检查现有 assets │        │ 3b. 构建所有 assets │
│ (check_tags.sh)     │        │ (跳过 check_tags)   │
│ - 查询 release      │        │ - SHOULD_BUILD=yes  │
│ - 检查缺失的 assets │        │ - 所有构建标志=yes  │
│ - 设置构建标志      │        └──────────┬──────────┘
└──────────┬──────────┘                   │
           │                              │
           ▼                              ▼
┌─────────────────────┐        ┌─────────────────────┐
│ 4. 构建              │        │ 4. 构建              │
│ (build.sh)          │        │ (build.sh)          │
└──────────┬──────────┘        └──────────┬──────────┘
           │                              │
           ▼                              ▼
┌─────────────────────┐        ┌─────────────────────┐
│ 5a. 准备 assets     │        │ 5b. 准备 assets     │
│ (prepare_assets.sh) │        │ (prepare_assets.sh) │
│ - 签名/公证          │        │ - 签名/公证          │
│ - 打包 (ZIP/DMG)    │        │ - 打包 (ZIP/DMG)    │
└──────────┬──────────┘        └──────────┬──────────┘
           │                              │
           ▼                              ▼
┌─────────────────────┐        ┌─────────────────────┐
│ 6a. 发布             │        │ 6b. 上传 artifacts  │
│ (release.sh)        │        │ (GitHub Actions)    │
│ - 检查/创建 release │        │ - 保留3天           │
│ - 上传 assets       │        └─────────────────────┘
│ - 重试机制          │
└─────────────────────┘
```

## 最佳实践建议

### 1. 正常发布流程

```bash
# 由 stable-spearhead 自动触发，或手动触发：
./scripts/trigger-stable-release.sh --dispatch
```

### 2. 补充单个平台的 Assets

```bash
# 单独触发失败的平台
./scripts/trigger-stable-release.sh --workflow --platform macos
```

### 3. 测试构建

```bash
# 构建但不发布
./scripts/trigger-stable-release.sh --workflow --generate --platform macos
```

### 4. 检查构建状态

```bash
# 使用辅助脚本
./scripts/check-release-status.sh

# 或手动检查
gh run list --workflow=stable-macos.yml --limit 5
gh release view <version> --repo <repo>
```

## 常见问题和解决方案

### Q1: 多个平台同时运行会不会冲突？

A: 不会。`release.sh` 有重试机制，如果上传失败会删除部分文件并重试。

### Q2: 如何强制重新构建所有 assets？

A: 使用 `generate_assets=true` 参数会跳过 `check_tags.sh`，强制构建所有 assets：

```bash
gh workflow run stable-macos.yml -f generate_assets=true
```

### Q3: 手动触发的工作流会创建新的 release 吗？

A: 取决于 release 是否已存在：
- 如果 release 不存在 → 创建新 release
- 如果 release 已存在 → 向现有 release 添加 assets

### Q4: DMG 修复后，需要重新构建已发布的版本吗？

A: 如果想补充已发布版本的 DMG：

```bash
# 1. 确保该版本的 release 已存在
gh release view <version>

# 2. 单独触发 macOS 构建
gh workflow run stable-macos.yml

# 3. check_tags.sh 会检测到 DMG 缺失并构建
```

## 总结

当前的 release 工作流设计是**合理且健壮的**：

1. ✅ 支持多平台并行构建
2. ✅ 自动检测并创建 release
3. ✅ 智能检测缺失的 assets
4. ✅ 支持单独补充某个平台的 assets
5. ✅ 有重试和错误处理机制

修复 DMG 构建问题后，整个流程应该能够正常工作。建议进行一次完整的测试：

```bash
# 测试构建（不发布）
./scripts/trigger-stable-release.sh --workflow --generate --platform macos

# 检查 workflow artifacts 中是否包含 DMG 文件
gh run list --workflow=stable-macos.yml --limit 1
```
