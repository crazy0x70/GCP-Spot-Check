# GCP Spot Check（gcpsc）

> Google Cloud Spot 实例保活脚本 · 交互式 TUI · 支持多账号/多项目/多区域

## 亮点
- 自动发现：新增账号后自动扫描所有项目与实例。
- 可控监控：实例级开关、可设置巡检间隔（分钟），按配置节流检查。
- 自动修复：检测 TERMINATED/STOPPED 自动启动，ERROR 先 reset 再启动。
- 多账号：服务账号（推荐）/OAuth 用户账号均可，支持并行检查。
- 定时任务：安装即写入 crontab 每分钟检查一次，带锁防并发。
- 容错日志：详细日志 `/var/log/gcpsc.log`，实例列举失败会打印原因。
- 一键安装/卸载：通过 curl | bash 完成安装，找不到自身脚本时自动回退下载。

## 一键安装 / 卸载
```bash
# 安装
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/crazy0x70/GCP-Spot-Check/refs/heads/main/gcp-spot-check.sh)" @ install

# 运行管理界面
sudo gcpsc

# 卸载
sudo gcpsc remove
# 或
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/crazy0x70/GCP-Spot-Check/refs/heads/main/gcp-spot-check.sh)" @ remove
```
> 如需自定义下载地址，可设置环境变量 `SCRIPT_URL=...` 再执行安装命令。

## 菜单速览
- 账号管理：添加/删除账号，刷新资源（自动发现项目与实例）。
- 实例管理：列表、切换监控开关、手动检查、设置巡检间隔（分钟）。
- 统计/日志：显示账号/实例数量 + 最近 30 行日志。
- 立即检查：立刻按配置执行一次检查（尊重监控开关与间隔）。

## 使用服务账号（推荐）
1. 在 GCP 控制台创建服务账号，授予 `roles/compute.instanceAdmin.v1`（或 Compute Admin）。
2. 生成 JSON 密钥，下载到本地。
3. 进入菜单：`sudo gcpsc` → 账号管理 → 添加服务账号 → 输入密钥路径。
4. 脚本会自动验证密钥、保存到 `/etc/gcpsc/keys/`，并扫描项目/实例。

## OAuth 用户账号
仅用于测试或短期：`sudo gcpsc` → 账号管理 → 添加用户账号 → 按提示浏览器授权。令牌过期可能导致检查失败，生产环境请改用服务账号。

## 配置与路径
- 主程序：`/usr/local/bin/gcpsc`
- 配置：`/etc/gcpsc/config.json`
- 密钥：`/etc/gcpsc/keys/`
- 上次检查时间：`/etc/gcpsc/lastcheck/`
- 日志：`/var/log/gcpsc.log`

## 定时任务
安装时自动写入（每分钟检查一次）：
```
* * * * * /usr/local/bin/gcpsc check >/dev/null 2>&1
```

## 命令行用法
```bash
sudo gcpsc                 # 交互式菜单
sudo gcpsc check           # 全量检查
sudo gcpsc check --account <account>   # 仅检查指定账号
sudo gcpsc check --no-refresh          # 跳过资源发现，按现有配置检查
sudo gcpsc version         # 查看版本
sudo gcpsc remove          # 卸载
```

## Docker 运行（解决 Alpine 不兼容问题）
> 镜像基于 `google/cloud-sdk:slim`（Debian），内置 gcloud 与 jq，避免 Alpine 上的 libc/gcloud 兼容问题。容器默认常驻（`tail -f /dev/null`），方便随时 `docker exec` 进入巡检/管理。

### 构建镜像
```bash
docker build -t gcpsc .
```

### 启动常驻容器并挂载密钥
```bash
# /path/to/key.json 请替换为本地密钥绝对路径
docker run -d --name gcpsc \
  -v $PWD/gcpsc-data:/etc/gcpsc \        # 配置/密钥持久化
  -v $PWD/gcpsc-log:/var/log \           # 日志持久化（可选）
  -v /path/to/key.json:/keys/key.json:ro \
  gcpsc
```
容器保持运行，后续直接 `docker exec` 进入。

### 进入容器添加服务账号/交互菜单
```bash
docker exec -it gcpsc gcpsc          # 进入菜单
# 菜单路径：账号管理 -> 添加服务账号 -> 输入 /keys/key.json
```
> 首次导入后，密钥会被复制到 `/etc/gcpsc/keys/`；复用同一 `gcpsc-data` 挂载目录时，可移除对原始 key.json 的绑定（或继续保持挂载以便更新）。

### 无交互巡检（容器内执行）
```bash
docker exec gcpsc gcpsc check --no-refresh
```
> 如需调度，推荐在宿主机使用 cron/systemd timer 调用上述 `docker exec`。

### 退出与清理
- 停止容器：`docker stop gcpsc`
- 删除容器（保留数据卷目录）：`docker rm gcpsc`

## 权限与依赖
- GCP 角色：`roles/compute.instanceAdmin.v1`（或等价权限：list/get/start/reset + projects.list）。
- 自动安装依赖：`gcloud`、`jq`、`cron`、`curl`（脚本会检测并安装）。
- 支持系统：Debian/Ubuntu、CentOS/RHEL 7+、Rocky/Alma、Fedora。

## 常见问题
- **看不到实例**：确认服务账号有 `compute.instances.list`，Compute API 已启用，密钥路径正确。
- **令牌过期**：使用服务账号替代 OAuth。
- **Cron 不运行**：检查 `crontab -l`、`systemctl status cron/crond`，查看 `/var/log/gcpsc.log`。
- **实例启动失败**：检查配额、Spot 容量或换区尝试。

## 版本记录
- **v3.0.2**
  - 修复安装回退下载逻辑，支持管道安装找不到自身脚本时自动下载。
  - 保留实例监控开关与间隔；支持实例级检查间隔节流；监控开关生效。
  - 菜单合并统计/日志，实例管理可设置间隔。
- **v3.0.0**：服务账号支持、性能优化、日志改进。

## 许可证
MIT

---
如果对你有帮助，欢迎 Star ⭐ 支持。跑狗一步到位，Spot 实例不掉线。***
