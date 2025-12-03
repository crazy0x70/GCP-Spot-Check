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
### 安装
```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/crazy0x70/GCP-Spot-Check/refs/heads/main/gcp-spot-check.sh)" @ install
```
### 运行管理界面
```bash
sudo gcpsc
```
### 卸载
```bash
sudo gcpsc remove
```
或
```basg
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

## 权限与依赖
- GCP 角色：`roles/compute.instanceAdmin.v1`（或等价权限：list/get/start/reset + projects.list）。
- 自动安装依赖：`gcloud`、`jq`、`cron`、`curl`（脚本会检测并安装）。
- 支持系统：Debian/Ubuntu、CentOS/RHEL 7+、Rocky/Alma、Fedora。

## 常见问题
- **看不到实例**：确认服务账号有 `compute.instances.list`，Compute API 已启用，密钥路径正确。
- **令牌过期**：使用服务账号替代 OAuth。
- **Cron 不运行**：检查 `crontab -l`、`systemctl status cron/crond`，查看 `/var/log/gcpsc.log`。
- **实例启动失败**：检查配额、Spot 容量或换区尝试。

## 许可证
MIT

---
如果对你有帮助，欢迎 Star ⭐ 支持。跑狗一步到位，Spot 实例不掉线。