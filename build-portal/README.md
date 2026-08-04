# 湛卢构建门户

`build-portal` 是 vscodium 仓库内的 Stable 发布编排模块。它把预览确认、GitLab→GitHub 同步、Release/Profile 固定、三平台 GitHub Actions 触发、运行监控、失败平台重试和定时 development 构建集中到一个内网 HTTPS 门户；桌面制品仍由原生 workflow 构建。

## 组件

- `apps/web`：Next.js 管理界面和 API。
- `apps/scheduler`：每 30 秒扫描规则，使用 PostgreSQL advisory lock 和 occurrence 唯一约束。
- `apps/worker`：独立 NAS 工作区、发布准备锁、GitHub App credential broker、精确 run ID 监控和恢复。
- `packages/contracts|db|auth|github-app|release-runner`：共享约束与基础能力。
- `deploy`：本地 mock Compose、两个生产镜像、Kustomize 清单、部署/管理员 bootstrap/恢复脚本。

## 本地验证

需要 Node.js 22 和 pnpm 10：

```bash
pnpm install --frozen-lockfile
pnpm test
pnpm typecheck
pnpm build
```

本地 Compose 固定使用 `EXECUTOR_MODE=mock`，不会同步远端、创建 Release 或 dispatch workflow：

```bash
docker compose -f deploy/compose.yaml up --build
```

首次登录前，在 Web 镜像中运行 `/tools/auth/dist/bootstrap.js` 创建唯一管理员。生产环境使用 `deploy/scripts/bootstrap-admin.sh`，成功后脚本会删除 bootstrap Secret。

## 生产交付

1. 创建 GitHub App，权限仅为 Metadata read、Contents read/write、Actions read/write，并安装到 vscodium、五个组件仓库及 Delivery Profile 引用的资产仓库。
2. 创建 GitLab 专用服务 Token（API、write_repository），把私钥、Token、数据库密码、CSRF_HMAC_SECRET 和 TLS 证书保存在仓库外。
3. 复制 `deploy/k8s/secrets.example.env` 到仓库外并替换占位值。`REPOSITORIES_JSON` 中的 URL 不得嵌入凭据。
4. 用 MacMini 构建并推送两个 `linux/amd64` SHA 镜像：

```bash
docker buildx build --platform linux/amd64 -f deploy/docker/Dockerfile.web -t 192.168.22.100:30002/zhanlu/build-portal-web:<git-sha> --push .
docker buildx build --platform linux/amd64 -f deploy/docker/Dockerfile.worker -t 192.168.22.100:30002/zhanlu/build-portal-worker:<git-sha> --push .
```

5. 调用 `deploy/scripts/deploy.sh <git-sha> <secrets.env> <tls.crt> <tls.key> <github-app.pem>`。脚本先校验证书 SAN，再按 Secret/PVC、PostgreSQL、migration、应用和 readiness 的顺序部署。
6. 调用 `deploy/scripts/bootstrap-admin.sh` 创建管理员。入口为 `https://192.168.22.100:30443`。

每日 02:30（Asia/Tokyo）生成 custom-format `pg_dump`，保留 14 天。上线验收必须把一个备份恢复到隔离数据库，并使用 `deploy/scripts/restore-backup.sh` 验证。正式发布仍需要页面中的 `FORMAL <version>` 二次确认；定时规则只接受 development draft。

## 安全边界

Worker 是唯一持有 GitHub App 私钥和 GitLab Token 的组件。Git/GH/Octokit 使用一小时安装令牌，broker 提前五分钟刷新；远端 URL、数据库事件和日志不得含 Token。门户构建只预检并同步页面选择的 zhanlu-code、zhanlu-core、zhanlu-vs 引用，以 GitLab 为准并使用预检 SHA 的精确 `--force-with-lease`，绝不调用 `--all-refs`。预览不执行远端写入。同步失败、force-with-lease 冲突、Release 冲突或 run 归属不唯一时任务失败关闭或进入 `needs_attention`。
