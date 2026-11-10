# actions-work-box

用 GitHub Actions 干活的盒子。

代码同步在 [shoguncao/actions-work-box](https://github.com/shoguncao/actions-work-box) 与 [mutedtowel/actions-work-box](https://github.com/mutedtowel/actions-work-box)。

- `shoguncao/actions-work-box`：主仓库。本文的 `cloudflare-ssh` workflow 与「串行跑任务」两个脚本都以它为触发目标（触发前确认该仓库 Actions 已启用）。
- `mutedtowel/actions-work-box`：仅作代码备份。下方「循环触发」里的旧脚本默认仍指向它，属于历史配置；新脚本不用它。

本地推送时，`origin` 指向 shoguncao，并同时 push 到 mutedtowel。

## 循环触发

`scripts/repeat-report-egress-ip.sh` 用来一次次启动 `report-egress-ip`：每次等我们自己的记录页出现新记录后再启动下一次，不靠 GitHub 运行列表来判断结束。接口请求带短超时，后台启动后超过 15 秒仍未结束就强制结束该请求；强杀后既不再等待它退出，也不在外层用会等待后台任务的方式去接结果，避免仍卡住几分钟。

需要环境变量 `GH_TOKEN`（对 mutedtowel 仓库有 Actions 权限的 token）。不要把 token 写进仓库。

```bash
export GH_TOKEN=...
COUNT=2000 ./scripts/repeat-report-egress-ip.sh
```

国内直连 GitHub 有时会不通（尤其晚上）。不用改脚本，启动前给 curl 加上代理环境变量即可。2019 机器上 Articles 代理已经在跑，可用：

```bash
export ALL_PROXY=socks5h://127.0.0.1:18080
# 或者：export HTTPS_PROXY=http://127.0.0.1:9174
export GH_TOKEN=...
COUNT=5000 ./scripts/repeat-report-egress-ip.sh
```

记录页：https://xmrig_statistic.keyso.uk/actions-work-box/

## 手动临时 SSH

`.github/workflows/cloudflare-ssh.yml` 只能手动触发（`workflow_dispatch`），自己开 sshd 和 cloudflared Quick Tunnel，把 runner 的 2222 端口通过 `*.trycloudflare.com` 暴露出来。最长 360 分钟。在 shoguncao 仓库点 Run workflow，需要填 `ssh_pubkey`（登录用的 SSH 公钥整行），`correlation_id` 留空即可；脚本触发时才会填关联标识。

日志里会打印隧道地址和一条完整连接命令。本机需要先装好 `cloudflared`（`ProxyCommand` 是在你自己的电脑上执行的），把命令里的 `/path/to/action-sshd-cloudflared` 换成对应私钥（不是 `.pub`）。命令已带 `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`，不需要手工维护 `known_hosts`。

结束有两种方式：

- 正常完成（绿色）：在 SSH 会话里执行 `pkill -x cloudflared`，连接会立即断开，job 随之结束。
- 取消（灰色）：在 Actions 页面 Cancel workflow。

隧道地址生成、SSH 连通、以及串行多轮任务均已实测通过。

## 串行跑任务

`scripts/run-on-runner.sh` 跑单轮：触发一次 workflow → 用关联标识精确锁定本轮 run → 从本轮写下的 commit status 读到隧道地址 → SSH 上传任务目录 → 前台执行 `entry.sh` → 取回 `output/` → 关掉隧道并确认本轮 run 完成。

`scripts/repeat-run-on-runner.sh` 是薄壳，按 `--count` 逐轮调用上面的单轮脚本，每轮返回后才可能开始下一轮，任一轮失败即停止。手动临时 SSH 的用法完全不受影响。

### 依赖与凭据

- Bash 3.2 及以上；`curl`、`ssh`、`tar`、`python3`、本机 `cloudflared`。缺依赖会给中文提示，脚本不擅自安装。
- PAT：对 shoguncao 仓库有 Actions 读写、以及 commit status 读取权限。放到**仓库外**的本机私有文件，例如 `~/.config/actions-work-box/pat.txt`（`chmod 600`），用 `--pat-file` 指定。不要把 PAT 写进仓库、命令行或日志。
- workflow 用自带的 `GITHUB_TOKEN` 把隧道地址写成一条 commit status（`statuses: write` 已在 yml 里声明），不需要额外配置 secret。
- SSH 私钥：单轮脚本用 `--ssh-key` 指定，公钥由它推导后作为 workflow 的 `ssh_pubkey` 输入传入；循环脚本在开头自动生成一对临时密钥，退出时删除，不需要传 `--ssh-key`。控制用 PAT 不会传给任务脚本。

### 任务目录

```text
my-task/
├── entry.sh
├── 其他业务脚本和输入文件
└── output/
```

- `entry.sh` 前台执行任务，需要取回的文件写入 `output/`；依赖安装由它自己负责；若自行启动后台任务，必须自己 `wait`，不能让入口提前退出。
- 上传时排除输入目录里已有的 `output/`，避免旧结果被误认为本轮产物。
- `output/` 不存在或为空属于正常情况，本轮结果目录会是空的，不算执行失败。
- 每轮远端任务目录与本地结果目录都带本轮唯一关联标识，互不覆盖；本地结果在 `--output-dir/<关联标识>/`。

### 用法

```bash
./scripts/run-on-runner.sh \
  --repo shoguncao/actions-work-box --ref main \
  --pat-file ~/.config/actions-work-box/pat.txt \
  --ssh-key /path/to/action-sshd-cloudflared \
  --task-dir /path/to/my-task \
  --output-dir /path/to/results \
  --close-tunnel auto
```

```bash
./scripts/repeat-run-on-runner.sh --count 10 \
  --repo shoguncao/actions-work-box --ref main \
  --pat-file ~/.config/actions-work-box/pat.txt \
  --task-dir /path/to/my-task \
  --output-dir /path/to/results \
  --close-tunnel auto
```

- `--close-tunnel`（**必填**）：`auto` 由脚本执行 `pkill -x cloudflared` 关闭隧道并确认 run 变为 completed；`manual` 保留隧道，脚本不关闭、不取消本轮 run，需自行连接后执行 `pkill -x cloudflared`，或在 Actions 页面 Cancel。
- `--startup-timeout`（默认 600 秒）：等本轮 run 与隧道地址就绪的上限。
- `--cleanup-timeout`（默认 180 秒）：仅 `auto` 模式使用，等本轮 run 变为 completed 的上限。
- `--help` 查看两个脚本的完整参数说明。

### 行为约定

- 严格顺序：触发 → 等就绪 → 上传 → 执行并等待真实退出 → 下载输出 → 收尾 → 单轮返回 → 下一轮。正常路径不会在业务仍运行时提前收尾。
- `--close-tunnel auto`：关隧道、等 completed 后才返回；收到中断会取消本轮 run，退出时删除循环脚本生成的临时密钥。
- `--close-tunnel manual`：下载结果后立即返回，run 保持 in_progress，隧道继续存活（直到 workflow 的 360 分钟上限）；日志会打印完整连接命令，循环脚本**不会删除临时密钥**以便你连上去手动关闭，用完请自行删除该目录。此模式下收到中断也不会取消 run。若 `--count` 大于 1，会依次留下多个存活的 run，需要逐个关闭。
- 退出码：业务成功且上传、下载、收尾都成功返回 0；`entry.sh` 非零退出时仍尝试取回 `output/`，业务退出码如实返回；SSH 断连、下载失败、未在期限内完成都会让整体非零，日志分别记录业务结果与基础设施结果。
- 异常与信号：只对已识别的本轮 run 尽力收尾，不会取消其它运行；dispatch 结果不确定时先按关联标识查状态，不盲目重发。
- 隧道地址拿到后，先用 Cloudflare 的 DoH 接口等权威 DNS 登记好这个新域名（最多 60 秒），本机才第一次去解析它。这样内网 DNS 不会记下 NXDOMAIN 负缓存——那份负缓存会让后续每次解析都白等约 60 秒。登记完成后再用一次空 SSH 命令探活（最多 90 秒），通过才上传任务目录。任一环节失败都会取消本轮 run 并整体非零退出。
- 连接地址由 workflow 在隧道就绪后写成一条 commit status（`context` 带本轮关联标识），本地脚本按关联标识精确匹配读取；运行中即可读到，不依赖 job 日志归档。若迟迟读不到，脚本会在 `--startup-timeout` 后报错退出。
- 本轮 workflow 仍受 360 分钟上限约束，业务等待没有额外短超时。
