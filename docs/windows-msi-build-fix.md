# Windows MSI Build Error Fix

## 问题描述

在 Windows x64 架构编译的 workflow 中，prepare assets 步骤出现以下 WiX Toolset 链接错误:

```
error LGHT0094 : Unresolved reference to symbol 'File:VSCODIUM.EXE' in section 'Product:{5F801725-7E36-4EE7-AA2F-FC6AF64E9EBF}'.
```

这个错误在 `vscodium.wxs` 文件的多个位置重复出现(第708-1044行)。

## 根本原因分析

### 问题链

1. **Workflow 配置** (`.github/workflows/stable-windows.yml`):
   - `APP_NAME: Zhanlu`
   - `BINARY_NAME: zhanlu`

2. **应用程序名称设置** (`prepare_vscode.sh` 第97行):
   ```bash
   setpath "product" "applicationName" "${BINARY_NAME}"
   ```
   - 这会将 `product.json` 中的 `applicationName` 设置为 `zhanlu`

3. **实际生成的可执行文件**:
   - Windows 可执行文件命名规范: 首字母大写
   - 实际文件名: `Zhanlu.exe`

4. **WiX XSL 转换文件** (`build/windows/msi/vscodium.xsl` 第14行):
   ```xml
   <xsl:key name="vId1ToReplace" match="wi:Component[wi:File[contains(@Source,'@@PRODUCT_NAME@@.exe')]]" use="@Id"/>
   ```
   - XSL 转换查找包含 `@@PRODUCT_NAME@@.exe` 的文件

5. **MSI 构建脚本** (`build/windows/msi/build.sh` 第50行,修复前):
   ```bash
   sed -i "s|@@PRODUCT_NAME@@|${PRODUCT_NAME}|g" .\\vscodium.xsl
   ```
   - `PRODUCT_NAME` 的值是 `VSCodium`(产品显示名称)
   - 替换后 XSL 查找: `VSCodium.exe`

6. **错误结果**:
   - Heat.exe 工具扫描二进制目录时找到: `Zhanlu.exe`
   - Heat.exe 生成的 File ID: `ZHANLU.EXE`
   - XSL 转换后应生成的 ID: `VSCODIUM.EXE`
   - `vscodium.wxs` 中引用的 ID: `VSCODIUM.EXE`
   - **实际存在的 ID**: `ZHANLU.EXE` (来自 Heat.exe,未被 XSL 匹配转换)
   - **结果**: WiX Linker 无法找到 `VSCODIUM.EXE` → LGHT0094 错误

## 解决方案

从源头修改 `build/windows/msi/build.sh` 文件,在定义 `PRODUCT_NAME` 时就使用实际的应用程序名称(从 `product.json` 读取):

### 修改内容

**1. 在文件开头读取应用程序名称 (第12-16行):**

```bash
# Read application name from product.json to get the actual product name
LICENSE_DIR_TMP="../../../vscode"  # ✅ 必须使用正斜杠，不能用反斜杠！
APPLICATION_NAME="$( node -p "require('${LICENSE_DIR_TMP}/product.json').applicationName" )"
# Capitalize first letter to match Windows executable naming convention
APPLICATION_NAME_CAPITALIZED="$(echo ${APPLICATION_NAME:0:1} | tr '[:lower:]' '[:upper:]')${APPLICATION_NAME:1}"
```

**⚠️ 重要：路径必须使用正斜杠 `/`，不能使用反斜杠 `\`！**
- ✅ 正确：`LICENSE_DIR_TMP="../../../vscode"`
- ❌ 错误：`LICENSE_DIR_TMP="..\\..\\..\\vscode"` 

在 bash 中，反斜杠会被 Node.js 的 `require()` 当作转义字符，导致路径解析错误。

**2. 修改 PRODUCT_NAME 定义 (第18-30行):**

```bash
if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
  PRODUCT_NAME="${APPLICATION_NAME_CAPITALIZED} - Insiders"
  PRODUCT_CODE="${APPLICATION_NAME_CAPITALIZED}Insiders"
  # ... 其他设置
else
  PRODUCT_NAME="${APPLICATION_NAME_CAPITALIZED}"
  PRODUCT_CODE="${APPLICATION_NAME_CAPITALIZED}"
  # ... 其他设置
fi
```

**3. 修改输出文件名 (第43-47行):**

```bash
if [[ -z "${1}" ]]; then
  OUTPUT_BASE_FILENAME="${APPLICATION_NAME_CAPITALIZED}-${VSCODE_ARCH}-${RELEASE_VERSION}"
else
  OUTPUT_BASE_FILENAME="${APPLICATION_NAME_CAPITALIZED}-${VSCODE_ARCH}-${1}-${RELEASE_VERSION}"
fi
```

**4. 修改 ManufacturerName 参数 (第83行):**

```bash
"${WIX}bin\\candle.exe" ... -dManufacturerName="${APPLICATION_NAME_CAPITALIZED}" ...
```

### 工作原理

1. 从 `product.json` 读取实际的 `applicationName` (例如: `zhanlu`)
2. 将首字母大写以匹配 Windows 可执行文件命名规范 (例如: `Zhanlu`)
3. 使用这个名称作为 `PRODUCT_NAME`、`PRODUCT_CODE` 和输出文件名的基础
4. `PRODUCT_NAME` 通过 sed 替换到 XSL 模板中的 `@@PRODUCT_NAME@@`
5. XSL 转换会正确查找 `Zhanlu.exe` 并将其 ID 设置为 `VSCODIUM.EXE`
6. WiX Linker 可以成功解析 `vscodium.wxs` 中对 `VSCODIUM.EXE` 的所有引用
7. 生成的 MSI 文件名为 `Zhanlu-x64-{version}.msi` (而不是 `VSCodium-x64-{version}.msi`)

### 优势

- **从源头修复**: 不是在后面打补丁,而是从变量定义就使用正确的值
- **一致性**: `PRODUCT_NAME`、`PRODUCT_CODE`、`ManufacturerName` 和文件名都保持一致
- **可维护性**: 所有硬编码的 "VSCodium" 都被替换为动态读取的实际产品名称
- **灵活性**: 适用于任何 fork,只要正确设置了 `product.json` 中的 `applicationName`

## 测试建议

1. 触发 Windows workflow 构建
2. 确认 prepare assets 步骤不再出现 LGHT0094 错误
3. 验证生成的 MSI 安装包可以正常安装和卸载
4. 确认安装后的应用程序可以正常启动

## 相关文件

- `.github/workflows/stable-windows.yml` - Workflow 配置
- `prepare_vscode.sh` - 设置 applicationName
- `build/windows/msi/build.sh` - MSI 构建脚本(已修复)
- `build/windows/msi/vscodium.xsl` - XSL 转换模板
- `build/windows/msi/vscodium.wxs` - WiX 源文件(引用 VSCODIUM.EXE)

## 注意事项

- 这个修复适用于任何自定义 `BINARY_NAME` 的场景
- 保持了向后兼容性:如果 `applicationName` 是 `vscodium`,大写后变为 `Vscodium`,XSL 仍会正常工作
- 第58行的 i18n 文件替换仍然使用 `${PRODUCT_NAME}`,这是正确的,因为 i18n 文件用于显示名称,不是文件 ID
