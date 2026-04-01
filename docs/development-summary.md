# 开发总结

## 目标

本次开发最初的目标，是把 Remnanode 在极低资源 Alpine LXC VPS 上的部署链路，收敛成可长期维护的最小方案；当前仓库已经在此基础上扩展到同时支持 Alpine/OpenRC 与 Debian/systemd。

核心要求：

- 不在目标 VPS 上跑 Docker
- 不让 GitHub Actions 直接连接 VPS
- 只保留 VPS 自主拉取 GitHub Release 的发布模型
- 首次安装和后续升级都走统一入口
- 兼容极低内存、无 swap 的实际环境，并覆盖 Alpine/OpenRC 与 Debian/systemd

## 最终架构

最终落地的架构是：

1. GitHub Actions Runner 拉取官方 `remnawave/node` 镜像
2. Runner 导出 runtime bundle
3. Runner 发布 `remnanode-runtime-latest.tar.gz` 到 GitHub Releases
4. VPS 通过 `one-click-panel.sh` 选择 `install` 或 `update`
5. dispatcher 识别 Alpine 或 Debian，并转发到对应实现
6. VPS 自己下载 runtime bundle
7. VPS 本地写入 service、supervisord、env 配置
8. VPS 本地启动 `remnanode-start`
9. Remnanode 以 Node.js 原生进程运行，并通过最小 `supervisord` 兼容层管理 Xray

这意味着：

- GitHub 负责发布
- VPS 负责安装和运行
- CI 与运行时彻底解耦

## 本次完成的主要工作

### 1. 收敛发布模型

- 删除了 GitHub Actions 到 VPS 的 SSH/远程部署逻辑
- 保留 GitHub Actions 的 runtime 导出与 GitHub Release 发布能力
- 增加按上游镜像 digest 的每日检查，只在上游变化时重新发布 runtime

### 2. 收敛脚本入口

脚本链路统一为：

- `scripts/one-click-panel.sh`
- `scripts/one-click-deploy.sh`
- `scripts/one-click-upgrade.sh`
- `scripts/export-runtime-bundle.sh`

其中：

- `one-click-panel.sh` 负责交互入口
- `one-click-deploy.sh` 负责首次安装
- `one-click-upgrade.sh` 负责后续升级与宿主机侧收敛
- `export-runtime-bundle.sh` 负责从官方镜像导出 runtime

历史兼容脚本和旧 bootstrap 流程已移除，避免后续维护时再次混入旧架构。

### 3. 固化主机侧真实可运行状态

安装脚本已内联写入：

- Alpine 上的 OpenRC service
- Debian 上的 systemd unit
- `supervisord.conf`
- `/etc/remnanode/remnanode.env`
- `/etc/remnanode/github-release.env`
- `/usr/local/bin/remnanode-start`

这意味着 release 资产只包含官方 runtime，不再夹带 host-tools。

### 4. 统一运行时变量

当前运行时对面板仍统一为：

- `NODE_PORT`
- `SECRET_KEY`

并修正了早期模板中的问题：

- 去掉重复或错误变量
- 修复 env quoting 问题
- 修复权限问题
- 修复 `SECRET_KEY` 粘贴兼容性

### 5. 处理低内存与宿主机兼容问题

本次开发中已经处理并固化了以下问题：

- Alpine 上 Xray 依赖 `gcompat`
- Debian 路径增加 systemd service，并补齐 Node.js `24.x` 自动安装
- Node 版本必须与当前官方 runtime 匹配，最终以 `24.x` 为准
- `NODE_OPTIONS` 需要正确 quoting，避免 shell 误解析
- `/etc/remnanode` 及 env 文件权限需要允许服务进程读取
- 由于上游 runtime 仍硬依赖 supervisor 控制面，当前改回最小 `supervisord` 兼容模式
- 启动前需要清理 stale unix socket、旧 Node 进程和旧 `supervisord`/`xray` 进程
- `128 MB` 当前只应视为实验性下限，`256 MB` 仍是更稳妥的基线

## 当前仓库状态

README 与文档已经更新，当前仓库对外表达与实际实现一致：

- README 只描述当前新架构
- GitHub Actions 文档只描述 release 发布，不再描述远程部署
- Alpine / Debian 部署文档分别收口到各自当前真实可用链路
- runtime workflow 文档与现有脚本保持一致

## 已验证结果

当前已完成：

- Alpine 路径已在真实 VPS 上验证
- Debian 路径已完成脚本实现与静态校验
- `one-click-panel.sh` 可作为统一入口
- GitHub Release 拉取模型可正常工作

本地仓库验证也已完成：

- shell 语法检查通过
- workflow YAML 解析通过
- `git diff --check` 通过

## 当前边界

当前方案的边界很明确：

- GitHub Actions 不负责连入 VPS
- VPS 不负责构建 runtime
- Release 不包含宿主机工具包
- 宿主机只安装运行所需的最小本地配置

## 结论

本次开发已经把项目从“多链路、混合部署、旧脚本残留”的状态，收敛为“单一发布路径、单一安装入口、单一升级入口”的稳定形态。

当前仓库已经可以作为该项目后续维护的基线版本继续演进。
