# 湛卢构建门户

这是一个单用户、手动发版门户。页面负责生成并确认 GitLab→GitHub 源码同步计划，然后触发 vscodium 的 macOS、Linux、Windows GitHub Actions；门户只保存精确 run ID/URL，构建状态和日志以 GitHub 为准。

## 运行结构

- 一个 pnpm/TypeScript 包，同时产出 Next.js Web、Worker、管理员 bootstrap、SQLite backup 和 Git credential helper。
- 一个固定运行在 `pve-nas` 的 Kubernetes Pod，包含 Web、Worker、Caddy 三个容器。
- SQLite 使用 WAL、外键和事务式任务 lease，存放于 `/vol1/1000/k8s-build/build-portal/state`。
- 六个裸 Git 缓存存放于 `git-cache`；请求只创建位于 `emptyDir` 的临时 worktree。
- 每日 02:30（Asia/Shanghai）在线备份 SQLite 到 `backups`，每份备份在原子改名前执行 `integrity_check`，保留 14 天。

门户可选择承载构建脚本和 Actions 定义的 VSCodium 分支。每次预览固定包含原生 Agent 架构所需四个组件的 `develop`，并追加选定的 zhanlu-code、zhanlu-core Ref；只有明确填写 zhanlu-vs 时，才把旧 VSIX 仓库加入同步和构建。确认后应用计划时重新验证 GitLab SHA 和 GitHub lease，且只使用精确 `--force-with-lease`；不会调用 all-refs。 <!-- zhanlu_change -->

## 本地验证

需要 Node.js 22.22 和 pnpm 10.17：

```bash
pnpm install --frozen-lockfile
pnpm test
pnpm typecheck
pnpm build
```

## 生产发布

构建并推送唯一镜像，取得 registry digest：

```bash
docker buildx build --platform linux/amd64 \
  -f deploy/docker/Dockerfile \
  -t 192.168.22.100:30002/zhanlu/build-portal:<git-sha> \
  --push .
```

然后依次执行：

```bash
deploy/scripts/migrate-cache.sh <image@sha256:digest>
deploy/scripts/deploy.sh <image@sha256:digest> <deployment.env> <workspace.env> <tls.crt> <tls.key> <github-app.pem>
```

`deploy.sh` 只读取所需键，不使用 PostgreSQL 配置或 CA 私钥。GitHub API 使用 App installation token，Git push 则强制使用具备 `repo` 和 `workflow` 权限的 `GITHUB_GIT_TOKEN`；缺失时 Worker 拒绝启动。bootstrap Secret 在管理员创建或确认已存在后立即删除。完成线上 `1.4.2` 三平台派发和 SQLite 备份验证后，运行：

```bash
deploy/scripts/cleanup-legacy.sh <image@sha256:digest>
```

清理脚本会先验证三个 PVC/PV 的 claimRef、NFS 服务器和精确目录，再删除旧 PostgreSQL、旧应用、三个 PVC/PV、对应 NAS 目录以及门户专用 NFS provisioner。该操作不可恢复。
