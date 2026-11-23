# redis-upgrade-helper

查询当前账号/区域下指定 ElastiCache Redis 的集群类型，并生成升级到 Redis 7.1 的一行后台命令。

## 用法

```bash
# 直接传 ID
./redis-upgrade-plan.sh my-rg-1 my-rg-2

# 从文件读（每行一个，支持 # 注释、逗号分隔）
./redis-upgrade-plan.sh -f ids.txt

# 同时把升级命令写成可执行脚本
./redis-upgrade-plan.sh -f ids.txt -o upgrade.sh

# 指定 profile / region
AWS_PROFILE=geely-prod AWS_REGION=eu-central-1 ./redis-upgrade-plan.sh -f ids.txt
```

## 输出

1. 当前账号、调用身份、区域；
2. 每个 ID 的类型信息：Replication Group / 单节点 Cache Cluster、集群模式（Cluster Mode Enabled/Disabled）、Multi-AZ、自动故障转移、分片数、节点类型、引擎版本、当前参数组；
3. 每个 ID 一行升级命令，`nohup ... & disown` 后台运行 + 日志落盘，粘贴到终端不会被挂起/中断；
4. 查不到的 ID 显示「没找到」。

## 注意

- 脚本本身**只做只读查询**（`describe-*` / `sts get-caller-identity`），不执行任何变更。
- 生成的命令里 `<PARAMETER_GROUP_PLACEHOLDER>` 必须先替换为真实参数组名：
  - Cluster Mode Enabled → `default.redis7.cluster.on` 或自建同族参数组
  - Cluster Mode Disabled / 单节点 → `default.redis7`
- 命令带 `--apply-immediately`，会立即触发滚动升级（有短暂故障转移）。生产环境请去掉该参数改为维护窗口执行，或逐个确认后再跑。
