# 正确的 Windows MSI 构建修复方案

## 问题分析

在 commit `1263646d45300ac03fd4ac61cafc8fe432d58d68` 中，按照 `windows-msi-build-fix.md` 的建议修改了 `build/windows/msi/build.sh`，但使用了错误的路径格式：

```bash
LICENSE_DIR_TMP="..\\..\\..\\vscode"  # ❌ 错误：反斜杠在 bash 中与正斜杠混用导致转义问题
APPLICATION_NAME="$( node -p "require('${LICENSE_DIR_TMP}/product.json').applicationName" )"
```

导致 Node.js 解析路径为 `'......scode/product.json'`（`\v` 和 `\s` 被当作转义字符）。

## 修复方法

### 选项1：通过 Patch 文件修复（推荐）

如果使用 patch 文件修改 MSI 构建脚本，创建或修改 `patches/fix-msi-dynamic-name.patch`：

```diff
--- a/build/windows/msi/build.sh
+++ b/build/windows/msi/build.sh
@@ -9,6 +9,14 @@
 
 set -e
 
+# Read application name from product.json to get the actual product name
+LICENSE_DIR_TMP="../../../vscode"
+APPLICATION_NAME="$( node -p "require('${LICENSE_DIR_TMP}/product.json').applicationName" )"
+# Capitalize first letter to match Windows executable naming convention
+APPLICATION_NAME_CAPITALIZED="$(echo ${APPLICATION_NAME:0:1} | tr '[:lower:]' '[:upper:]')${APPLICATION_NAME:1}"
+
+echo "APPLICATION_NAME: ${APPLICATION_NAME}"
+echo "APPLICATION_NAME_CAPITALIZED: ${APPLICATION_NAME_CAPITALIZED}"
 
 WIN_SDK_MAJOR_VERSION="10"
 WIN_SDK_FULL_VERSION="10.0.17763.0"
@@ -16,8 +24,8 @@
 
 if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
-  PRODUCT_NAME="VSCodium - Insiders"
-  PRODUCT_CODE="VSCodiumInsiders"
+  PRODUCT_NAME="${APPLICATION_NAME_CAPITALIZED} - Insiders"
+  PRODUCT_CODE="${APPLICATION_NAME_CAPITALIZED}Insiders"
   PRODUCT_UPGRADE_CODE="752CCFCE-96F6-47BC-8C6E-E69A2FB56856"
   ICON_DIR="..\..\..\src\insider\resources\win32"
   SETUP_RESOURCES_DIR=".\resources\insider"
 else
-  PRODUCT_NAME="VSCodium"
-  PRODUCT_CODE="VSCodium"
+  PRODUCT_NAME="${APPLICATION_NAME_CAPITALIZED}"
+  PRODUCT_CODE="${APPLICATION_NAME_CAPITALIZED}"
   PRODUCT_UPGRADE_CODE="965370CD-253C-4720-82FC-2E6B02A53808"
   ICON_DIR="..\..\..\src\stable\resources\win32"
   SETUP_RESOURCES_DIR=".\resources\stable"
@@ -41,9 +49,9 @@
 
 if [[ -z "${1}" ]]; then
-  OUTPUT_BASE_FILENAME="VSCodium-${VSCODE_ARCH}-${RELEASE_VERSION}"
+  OUTPUT_BASE_FILENAME="${APPLICATION_NAME_CAPITALIZED}-${VSCODE_ARCH}-${RELEASE_VERSION}"
 else
-  OUTPUT_BASE_FILENAME="VSCodium-${VSCODE_ARCH}-${1}-${RELEASE_VERSION}"
+  OUTPUT_BASE_FILENAME="${APPLICATION_NAME_CAPITALIZED}-${VSCODE_ARCH}-${1}-${RELEASE_VERSION}"
 fi
 
 if [[ "${VSCODE_ARCH}" == "ia32" ]]; then
@@ -77,7 +85,7 @@
 
 "${WIX}bin\\candle.exe" \
   -arch "${PLATFORM}" \
   vscodium.wxs Files-"${OUTPUT_BASE_FILENAME}".wxs \
   -ext WixUIExtension -ext WixUtilExtension -ext WixNetFxExtension \
-  -dManufacturerName="VSCodium" \
+  -dManufacturerName="${APPLICATION_NAME_CAPITALIZED}" \
   -dAppCodeName="${PRODUCT_CODE}" \
   -dAppName="${PRODUCT_NAME}" \
```

### 选项2：在 prepare_vscode.sh 中动态修改

在 `prepare_vscode.sh` 中的 patch 应用完成后添加：

```bash
# Fix MSI build script to use dynamic application name
if [[ -f "vscode/build/windows/msi/build.sh" ]]; then
  echo "Updating MSI build script to use dynamic application name..."
  
  # 使用正斜杠路径（关键！）
  cat > /tmp/msi_fix.sh << 'EOF'

# Read application name from product.json to get the actual product name
LICENSE_DIR_TMP="../../../vscode"
APPLICATION_NAME="$( node -p "require('${LICENSE_DIR_TMP}/product.json').applicationName" )"
# Capitalize first letter to match Windows executable naming convention
APPLICATION_NAME_CAPITALIZED="$(echo ${APPLICATION_NAME:0:1} | tr '[:lower:]' '[:upper:]')${APPLICATION_NAME:1}"

echo "APPLICATION_NAME: ${APPLICATION_NAME}"
echo "APPLICATION_NAME_CAPITALIZED: ${APPLICATION_NAME_CAPITALIZED}"

EOF

  # 在 'set -e' 后面插入读取 applicationName 的代码
  sed -i '/^set -e$/r /tmp/msi_fix.sh' vscode/build/windows/msi/build.sh
  
  # 替换硬编码的 VSCodium 为动态变量
  sed -i 's|PRODUCT_NAME="VSCodium - Insiders"|PRODUCT_NAME="${APPLICATION_NAME_CAPITALIZED} - Insiders"|g' vscode/build/windows/msi/build.sh
  sed -i 's|PRODUCT_CODE="VSCodiumInsiders"|PRODUCT_CODE="${APPLICATION_NAME_CAPITALIZED}Insiders"|g' vscode/build/windows/msi/build.sh
  sed -i 's|PRODUCT_NAME="VSCodium"|PRODUCT_NAME="${APPLICATION_NAME_CAPITALIZED}"|g' vscode/build/windows/msi/build.sh
  sed -i 's|PRODUCT_CODE="VSCodium"|PRODUCT_CODE="${APPLICATION_NAME_CAPITALIZED}"|g' vscode/build/windows/msi/build.sh
  sed -i 's|OUTPUT_BASE_FILENAME="VSCodium-|OUTPUT_BASE_FILENAME="${APPLICATION_NAME_CAPITALIZED}-|g' vscode/build/windows/msi/build.sh
  sed -i 's|-dManufacturerName="VSCodium"|-dManufacturerName="${APPLICATION_NAME_CAPITALIZED}"|g' vscode/build/windows/msi/build.sh
  
  rm -f /tmp/msi_fix.sh
  echo "MSI build script updated successfully."
fi
```

### 选项3：最简单的修复（如果已经修改过）

如果 `build/windows/msi/build.sh` 已经被修改（添加了 LICENSE_DIR_TMP），只需要修复路径：

在 `prepare_vscode.sh` 中添加：

```bash
# Fix backslash path issue in MSI build script
if [[ -f "vscode/build/windows/msi/build.sh" ]]; then
  echo "Fixing MSI build script path..."
  # 将反斜杠路径替换为正斜杠路径
  sed -i 's|LICENSE_DIR_TMP="\\.\\.\\.\\.\\.\\.\\vscode"|LICENSE_DIR_TMP="../../../vscode"|g' vscode/build/windows/msi/build.sh
  sed -i "s|LICENSE_DIR_TMP='\\.\\.\\.\\.\\.\\.\\vscode'|LICENSE_DIR_TMP='../../../vscode'|g" vscode/build/windows/msi/build.sh
  echo "MSI build script path fixed."
fi
```

## 关键点

1. **必须使用正斜杠**：`LICENSE_DIR_TMP="../../../vscode"` ✅
2. **不能使用反斜杠**：`LICENSE_DIR_TMP="..\\..\\..\\vscode"` ❌
3. **原因**：在 bash 中，当字符串包含反斜杠并在后续与正斜杠拼接时，反斜杠会被 Node.js 的 require() 当作转义字符

## 验证

修改后，在本地测试或查看 CI 日志，应该看到：

```
APPLICATION_NAME: zhanlu
APPLICATION_NAME_CAPITALIZED: Zhanlu
++ PRODUCT_NAME=Zhanlu
++ OUTPUT_BASE_FILENAME=Zhanlu-x64-1.107.10514
```

而不是错误：
```
Error: Cannot find module '......scode/product.json'
```

## 更新 windows-msi-build-fix.md

原文档第 62 行的错误代码应该修正为：

```bash
# Read application name from product.json to get the actual product name
LICENSE_DIR_TMP="../../../vscode"  # ✅ 使用正斜杠
APPLICATION_NAME="$( node -p "require('${LICENSE_DIR_TMP}/product.json').applicationName" )"
```
