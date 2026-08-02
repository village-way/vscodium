# 湛卢 IDE Release 构建与升级指南

本文说明湛卢 IDE 的发布构建入口、版本规则、标准发布流程，以及后续升级 upstream / 产品版本时需要修改和验证的内容。

## 目录与职责

日常发布入口在：

```bash
cd /Volumes/Files/vscodium
```

构建过程中会拉取私有化代码，相关仓库本地路径通常在：

```text
/Volumes/Files/zhanlu-ide
```

主要仓库职责：

| 仓库 | 作用 |
| --- | --- |
| `/Volumes/Files/vscodium` | 公共 CI/CD 入口，创建 GitHub Release，触发 stable workflow |
| `/Volumes/Files/zhanlu-ide/zhanlu-code` | 私有构建脚本、Release notes 模板、zhanlu 资产准备逻辑 |
| `/Volumes/Files/zhanlu-ide/zhanlu-core` | 湛卢 IDE 基于的 VS Code / VSCodium core |
| `/Volumes/Files/zhanlu-ide/zhanlu-vs` | 内置插件、opencode CLI、VSIX 构建产物 |
| `/Volumes/Files/zhanlu-ide/zhanlu-loc` | 语言包相关内容 |

GitHub Actions 会从 `vscodium` 入口开始，再根据 workflow 和脚本拉取这些私有仓库内容完成构建。

## 版本规则

湛卢产品版本统一由 `KILO_VERSION` 控制，当前默认是：

```bash
KILO_VERSION=1.0.0
```

公开 Release 版本使用：

```text
RELEASE_VERSION=${KILO_VERSION}${TIME_PATCH}
```

其中 `TIME_PATCH` 复用 VSCodium 的 4 位时间构建号算法：

```text
一年中的第几天 * 24 + 当前小时
```

示例：

```text
KILO_VERSION=1.0.0
TIME_PATCH=2734
RELEASE_VERSION=1.0.02734
```

需要注意版本语义拆分：

| 名称 | 示例 | 用途 |
| --- | --- | --- |
| `KILO_VERSION` | `1.0.0` | 湛卢产品版本，控制 CLI `--version`、插件 `package.json`、About 里的 Zhanlu version |
| `RELEASE_VERSION` | `1.0.02734` | GitHub Release tag/title 和公开 asset 文件名 |
| `MS_TAG` / `MS_COMMIT` | `1.110.1` / commit sha | 拉取 zhanlu-core / upstream VS Code 版本和生成 release notes |
| `VSCODE_VERSION` | `1.110.12734` | VS Code / VSCodium 内部兼容版本，不应改成 `1.0.02734` |

因此：

- GitHub Release tag/title 使用 `1.0.0####`。
- IDE、插件、CLI 对外显示的湛卢版本是 `1.0.0`。
- VS Code / VSCodium 内部版本仍保持 upstream 体系，例如 `1.110.12734`。
- 不要把 upstream VS Code 版本、VSCodium 内部版本直接改成 `1.0.0` 或 `1.0.0####`。

## 发布前检查

确认 `gh` 已安装并登录：

```bash
gh auth status
```

确认当前目录：

```bash
cd /Volumes/Files/vscodium
```

预览本次会生成的 Release 版本：

```bash
KILO_VERSION=1.0.0 bash ./create-release.sh --dry-run-version
```

期望输出类似：

```text
RELEASE_VERSION=1.0.02734
```

如果需要多个平台共用同一个版本号，先记下这个 `RELEASE_VERSION`，后续触发 workflow 时显式传入。

## 标准发布流程

### 1. 创建或更新 GitHub Release

```bash
cd /Volumes/Files/vscodium
KILO_VERSION=1.0.0 bash ./create-release.sh
```

该步骤会：

- 按 `KILO_VERSION + 4 位构建号` 生成 tag/title。
- 创建或更新 GitHub Release。
- 使用 `release_notes.md` 模板生成 Release notes。
- 在 Release 页面展示 IDE 和 Zhanlu CLI 下载表格。

### 2. 触发全平台构建

```bash
KILO_VERSION=1.0.0 ./scripts/trigger-stable-release.sh \
  --workflow \
  --zhanlu-core-ref develop \
  --platform all
```

如果已经在第一步创建了 release，建议显式指定同一个版本，避免跨小时后 4 位构建号变化：

```bash
KILO_VERSION=1.0.0 ./scripts/trigger-stable-release.sh \
  --workflow \
  --zhanlu-core-ref develop \
  --platform all \
  --release-version 1.0.02734
```

### 3. 观察 GitHub Actions

重点检查：

- macOS、Linux、Windows workflow 是否全部成功。
- Release 页面是否上传了对应平台 IDE assets。
- Release notes 是否包含 “Zhanlu CLI” 表格。
- `zhanlu-cli-*-${RELEASE_VERSION}.tar.gz` 是否存在。

## 常用触发命令

只预览命令，不实际触发：

```bash
./scripts/trigger-stable-release.sh \
  --workflow \
  --zhanlu-core-ref develop \
  --platform all \
  --dry-run
```

只生成 assets，不发布到 GitHub Release：

```bash
./scripts/trigger-stable-release.sh \
  --workflow \
  --generate \
  --zhanlu-core-ref develop \
  --platform all
```

只重跑单个平台：

```bash
./scripts/trigger-stable-release.sh \
  --workflow \
  --zhanlu-core-ref develop \
  --platform macos \
  --release-version 1.0.02734
```

可用平台值：

```text
macos
linux
windows
all
```

指定 zhanlu-code 分支：

```bash
./scripts/trigger-stable-release.sh \
  --workflow \
  --source-branch develop \
  --zhanlu-core-ref develop \
  --platform all
```

指定 zhanlu-core commit：

```bash
./scripts/trigger-stable-release.sh \
  --workflow \
  --zhanlu-core-ref <commit-sha> \
  --platform all
```

## CLI Asset 规则

opencode CLI 独立 asset 命名为：

```text
zhanlu-cli-darwin-x64-${RELEASE_VERSION}.tar.gz
zhanlu-cli-darwin-arm64-${RELEASE_VERSION}.tar.gz
zhanlu-cli-linux-x64-${RELEASE_VERSION}.tar.gz
zhanlu-cli-linux-arm64-${RELEASE_VERSION}.tar.gz
zhanlu-cli-win32-x64-${RELEASE_VERSION}.tar.gz
zhanlu-cli-win32-arm64-${RELEASE_VERSION}.tar.gz
```

CLI asset 只打包二进制文件：

| 平台 | 归档内文件 |
| --- | --- |
| macOS / Linux | `zhanlu` |
| Windows | `zhanlu.exe` |

不要把 opencode `dist` 目录整体归档。归档里不应包含 `.env`、`package.json`、token、私有配置或其他构建中间产物。

本地检查示例：

```bash
tar -tzf zhanlu-cli-darwin-arm64-1.0.02734.tar.gz
```

期望只看到：

```text
zhanlu
```

## 发布后验证

Release 页面检查：

- tag/title 是 `1.0.0####`，例如 `1.0.02734`。
- Release notes 有 “Zhanlu CLI” 下载表格。
- CLI assets 使用 `zhanlu-cli-*-${RELEASE_VERSION}.tar.gz` 命名。
- IDE assets 使用同一个 `RELEASE_VERSION`。

CLI 检查：

```bash
./zhanlu --version
```

期望输出：

```text
1.0.0
```

VSIX 检查：

```bash
cat extension/package.json | jq .version
```

期望输出：

```text
"1.0.0"
```

IDE About 检查：

- Zhanlu version 显示 `1.0.0`。
- VSCode Version 仍显示 upstream / zhanlu-core 对应版本，例如 `1.110.12734`。

## 升级 upstream / zhanlu-core

当需要升级 VS Code / zhanlu-core 基础版本时：

1. 更新 `/Volumes/Files/zhanlu-ide/zhanlu-code/upstream/stable.json` 中的 upstream tag / commit。
2. 确认 `/Volumes/Files/zhanlu-ide/zhanlu-core` 中存在对应分支、tag 或 commit。
3. 如果发布时使用 `--zhanlu-core-ref develop`，需要先把 develop 更新到目标版本并推送。
4. 检查 zhanlu-code 中的构建脚本是否仍兼容新的 upstream 结构。
5. 先运行 dry-run 和单平台 generate 构建，再触发全平台发布。

建议验证命令：

```bash
cd /Volumes/Files/vscodium
KILO_VERSION=1.0.0 bash ./create-release.sh --dry-run-version
./scripts/trigger-stable-release.sh \
  --workflow \
  --generate \
  --zhanlu-core-ref develop \
  --platform macos
```

如果只是补构建同一个 Release，务必带上原来的 `--release-version`。

## 升级插件或 CLI

当只升级插件或 opencode CLI，而不升级 VS Code core：

1. 更新 `/Volumes/Files/zhanlu-ide/zhanlu-vs` 中对应分支内容。
2. 保持 `KILO_VERSION=1.0.0`，除非这是一次产品版本升级。
3. 确认 `packages/kilo-vscode/package.json` 的 `version` 是 `1.0.0`。
4. 构建 opencode CLI 并检查 `--version`。

本地 CLI 构建检查示例：

```bash
cd /Volumes/Files/zhanlu-ide/zhanlu-vs
KILO_VERSION=1.0.0 VSCODE_ARCH=arm64 bun run packages/opencode/script/build.ts \
  --single \
  --skip-install \
  --skip-embed-web-ui
```

检查版本：

```bash
./packages/opencode/dist/bin/zhanlu --version
```

期望输出：

```text
1.0.0
```

## 升级湛卢产品版本

例如从 `1.0.0` 升级到 `1.0.1`：

1. 修改相关脚本中的默认 `KILO_VERSION`。
2. 修改 `/Volumes/Files/zhanlu-ide/zhanlu-vs/packages/kilo-vscode/package.json` 的 `version`。
3. 修改 `/Volumes/Files/zhanlu-ide/zhanlu-core/package.json` 中的 `zhanlu-version`。
4. 本地验证 CLI、VSIX、About 显示的新版本。
5. 重新创建 Release，tag/title 会变成 `1.0.1####`。

需要同步检查的脚本通常包括：

```text
/Volumes/Files/vscodium/create-release.sh
/Volumes/Files/vscodium/generate-version.sh
/Volumes/Files/zhanlu-ide/zhanlu-code/create-release.sh
/Volumes/Files/zhanlu-ide/zhanlu-code/generate-version.sh
/Volumes/Files/zhanlu-ide/zhanlu-code/get_zhanlu.sh
```

不要为了升级湛卢产品版本去手动修改 VSCodium / VS Code 内部版本。内部版本仍由 `MS_TAG + TIME_PATCH` 生成。

## 故障排查

`gh CLI 未登录`：

```bash
gh auth login
gh auth status
```

不同平台生成了不同 Release 版本：

- 原因通常是跨小时后 `TIME_PATCH` 变化。
- 解决方式是触发 workflow 时显式传 `--release-version 1.0.0####`。

Release 页面没有 CLI 表格：

- 检查 `release_notes.md` 是否包含 Zhanlu CLI 表格。
- 重新运行 `create-release.sh` 更新 release notes。

CLI asset 缺失：

- 检查对应平台 workflow 是否完成。
- 检查 opencode CLI 构建是否成功。
- 用同一个 `--release-version` 重跑失败平台。

CLI `--version` 不是 `1.0.0`：

- 检查构建 opencode CLI 时是否传入 `KILO_VERSION=1.0.0`。
- 检查 `/Volumes/Files/zhanlu-ide/zhanlu-vs/packages/opencode/build.sh` 和构建脚本是否读取同一个版本变量。

插件 `package.json` 版本不是 `1.0.0`：

- 检查 `/Volumes/Files/zhanlu-ide/zhanlu-vs/packages/kilo-vscode/package.json`。
- 重新打包 VSIX。

IDE About 中 Zhanlu version 不正确：

- 检查 `/Volumes/Files/zhanlu-ide/zhanlu-core/package.json` 中的 `zhanlu-version`。
- 检查构建流程是否执行了同步 zhanlu version 到 VS Code 的脚本。

VSCode Version 被错误显示成 `1.0.0####`：

- 检查 `RELEASE_VERSION` 是否被误用于 VS Code 内部版本。
- VS Code 内部版本应使用 `VSCODE_VERSION=${MS_TAG}${TIME_PATCH}`。
