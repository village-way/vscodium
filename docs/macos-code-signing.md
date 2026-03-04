# macOS 代码签名与公证配置指南

本文档说明如何为 Zhanlu 的 macOS 构建流水线配置苹果代码签名（Code Signing）和公证（Notarization）。

完成配置后，构建产物（`.app`、`.dmg`、`.zip`）将通过苹果的安全验证，用户打开时不会看到「无法验证开发者」的警告。

---

## 前置条件

- 已加入 [Apple Developer Program](https://developer.apple.com/programs/)（年费 $99）
- macOS 电脑（用于导出证书）
- 已安装 Xcode 或 Xcode Command Line Tools

---

## 第一步：在 Apple Developer 后台创建证书

1. 打开 [developer.apple.com/account](https://developer.apple.com/account)，登录
2. 点击左侧 **Certificates, Identifiers & Profiles**
3. 点击 **Certificates** → 右上角 **+**
4. 选择 **Developer ID Application**（用于在 App Store 外分发的应用）
5. 按照向导生成 CSR（Certificate Signing Request）：
   - 打开 macOS 的「钥匙串访问」→ 菜单栏「证书颁发机构」→「从证书颁发机构请求证书」
   - 填写邮箱和常用名称，选择「存储到磁盘」，保存为 `.certSigningRequest` 文件
6. 将该文件上传到 Apple Developer 后台，下载生成的 `.cer` 证书文件
7. 双击 `.cer` 文件，将其安装到「钥匙串访问」的「登录」钥匙串中

---

## 第二步：导出 .p12 证书文件

1. 打开「钥匙串访问」（Keychain Access）
2. 在左侧选择「登录」钥匙串，类别选「我的证书」
3. 找到 **Developer ID Application: \<你的名字\> (\<Team ID\>)**
4. **右键** → **导出**，格式选 **个人信息交换（.p12）**
5. 设置一个强密码（此密码即 `CERTIFICATE_OSX_NEW_P12_PASSWORD`），保存文件
6. 在终端执行以下命令，将 .p12 转为 base64 字符串：

```bash
base64 -i /path/to/cert.p12 | pbcopy
```

> 执行后 base64 字符串已复制到剪贴板，直接粘贴到对应的 GitHub Secret 中。

---

## 第三步：获取签名身份字符串

在终端执行：

```bash
security find-identity -v -p codesigning
```

输出示例：

```
1) AABBCCDD...  "Developer ID Application: Zhang San (ABC1234567)"
```

引号内的完整字符串（包含括号和 Team ID）即 `CERTIFICATE_OSX_NEW_ID` 的值。

---

## 第四步：获取 Team ID

**方法一**：从上一步的输出中，括号内的字母数字串即为 Team ID（如 `ABC1234567`）。

**方法二**：登录 [developer.apple.com/account](https://developer.apple.com/account) → 右上角账户名 → **Membership details** → **Team ID**。

---

## 第五步：创建 App 专用密码（用于公证）

公证时需要通过 `notarytool` 向苹果服务器提交，这需要一个 App 专用密码（不是你的 Apple ID 登录密码）。

1. 打开 [appleid.apple.com](https://appleid.apple.com)，登录
2. 点击「登录和安全」→「App 专用密码」
3. 点击 **+** 生成一个新密码，备注填写如 `github-notarization`
4. 保存生成的密码（格式为 `xxxx-xxxx-xxxx-xxxx`），这是 `CERTIFICATE_OSX_NEW_APP_PASSWORD` 的值

> App 专用密码只显示一次，请立即保存。

---

## 第六步：在 GitHub 仓库配置 Secrets

进入 GitHub 仓库 → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**，依次添加以下 6 个 Secret：

| Secret 名称 | 说明 | 示例值 |
|---|---|---|
| `APPLE_ID` | 你的 Apple ID 邮箱 | `zhangsan@example.com` |
| `CERTIFICATE_OSX_NEW_P12_DATA` | .p12 文件的 base64 编码 | `MIIKxAIBAA...`（很长的字符串）|
| `CERTIFICATE_OSX_NEW_P12_PASSWORD` | 导出 .p12 时设置的密码 | `your-p12-password` |
| `CERTIFICATE_OSX_NEW_ID` | 完整签名身份字符串 | `Developer ID Application: Zhang San (ABC1234567)` |
| `CERTIFICATE_OSX_NEW_TEAM_ID` | Apple Developer Team ID | `ABC1234567` |
| `CERTIFICATE_OSX_NEW_APP_PASSWORD` | App 专用密码 | `abcd-efgh-ijkl-mnop` |

---

## 工作流中的使用方式

工作流文件 `.github/workflows/stable-macos.yml` 中的 **Prepare assets** 步骤会将上述 Secrets 作为环境变量注入 `prepare_assets.sh`：

```yaml
- name: Prepare assets
  env:
    APPLE_ID: ${{ secrets.APPLE_ID }}
    CERTIFICATE_OSX_APP_PASSWORD: ${{ secrets.CERTIFICATE_OSX_NEW_APP_PASSWORD }}
    CERTIFICATE_OSX_ID: ${{ secrets.CERTIFICATE_OSX_NEW_ID }}
    CERTIFICATE_OSX_P12_DATA: ${{ secrets.CERTIFICATE_OSX_NEW_P12_DATA }}
    CERTIFICATE_OSX_P12_PASSWORD: ${{ secrets.CERTIFICATE_OSX_NEW_P12_PASSWORD }}
    CERTIFICATE_OSX_TEAM_ID: ${{ secrets.CERTIFICATE_OSX_NEW_TEAM_ID }}
  run: ./prepare_assets.sh
```

`prepare_assets.sh` 内部会按以下顺序执行：

```
1. 将 P12_DATA base64 解码为临时文件
2. 创建临时 Keychain（隔离于系统 Keychain，避免污染）
3. 将证书导入临时 Keychain，授权 codesign 使用
4. codesign --deep --options runtime 对 .app 进行深度签名
5. 打包为 .zip（必须）和 .dmg（可选）
6. notarytool 向苹果服务器提交公证请求（约 2-10 分钟）
7. xcrun stapler 将公证票据附加到产物（用户离线也可运行）
8. 流水线结束时自动删除临时 Keychain（Clean up keychain 步骤）
```

---

## 验证签名是否成功

构建完成后可在本地验证下载的产物：

```bash
# 验证代码签名
codesign --verify --deep --strict --verbose=2 /Applications/Zhanlu.app

# 验证 Gatekeeper 通过（模拟用户首次打开）
spctl --assess --type execute --verbose /Applications/Zhanlu.app

# 验证公证票据已附加
xcrun stapler validate /Applications/Zhanlu.app
```

三条命令均无错误输出则配置成功。

---

## 常见问题

**Q：构建日志显示 `WARNING: Signing credentials not set, skipping code signing`**

Secrets 未正确配置或名称拼写有误。检查 GitHub 仓库的 Secrets 列表，确认 6 个 Secret 均已添加且名称完全匹配。

**Q：公证失败，错误 `The software asset has already been uploaded`**

同一构建内容已经提交过公证，属于正常情况，不影响使用。

**Q：公证失败，错误 `Package Invalid` 或 `The signature of the binary is invalid`**

签名时未使用 `--options runtime`（Hardened Runtime），或 entitlements 文件路径不正确。检查 `prepare_assets.sh` 中的 `codesign` 命令。

**Q：用户运行时仍然提示「无法验证开发者」**

公证成功但未执行 `xcrun stapler staple`，或 staple 后未重新打包 .zip。确认 `prepare_assets.sh` 在 staple 后重新压缩了 .zip 文件。

**Q：证书过期怎么办**

Developer ID Application 证书有效期为 5 年。过期后需在 Apple Developer 后台重新创建证书，重复本文档第一至六步，更新 GitHub Secrets 中的 `CERTIFICATE_OSX_NEW_P12_DATA`、`CERTIFICATE_OSX_NEW_P12_PASSWORD`、`CERTIFICATE_OSX_NEW_ID` 三个值。

---

## 安全注意事项

- `.p12` 文件包含私钥，**不要提交到 Git 仓库**，使用完毕后可从本地删除
- GitHub Secrets 是加密存储的，工作流日志中不会显示其内容
- App 专用密码与 Apple ID 登录密码相互独立，泄露后可在 [appleid.apple.com](https://appleid.apple.com) 单独撤销
- 建议定期轮换 App 专用密码
