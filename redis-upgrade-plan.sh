#!/usr/bin/env bash
# redis-upgrade-plan.sh
# 用途：对给定的 ElastiCache Redis ID 列表，查询当前账号/区域下的集群类型信息，
#       并为每个集群生成一行“后台运行”的升级到 Redis 7.1 的命令（参数组为占位符）。
# 只读查询，不会执行任何变更。
#
# 用法：
#   ./redis-upgrade-plan.sh id1 id2 id3
#   ./redis-upgrade-plan.sh -f ids.txt
#   AWS_PROFILE=xxx AWS_REGION=cn-north-1 ./redis-upgrade-plan.sh id1
#
# 选项：
#   -f FILE     从文件读取 ID（每行一个，支持 # 注释与逗号/空格分隔）
#   -o FILE     把生成的升级命令另存为可执行脚本
#   -h          帮助

set -uo pipefail

TARGET_ENGINE_VERSION="7.1"
PG_PLACEHOLDER="<PARAMETER_GROUP_PLACEHOLDER>"
LOG_DIR_PLACEHOLDER="./upgrade-logs"
OUT_FILE=""
IDS=()

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# 选项与位置参数可混用（选项写在 ID 后面也能正确解析）
while [[ $# -gt 0 ]]; do
  OPTIND=1
  while getopts ":f:o:h" opt; do
    case "$opt" in
      f) [[ -r "$OPTARG" ]] || { echo "无法读取文件: $OPTARG" >&2; exit 1; }
         while read -r line || [[ -n "$line" ]]; do
           line="${line%%#*}"
           for tok in ${line//,/ }; do IDS+=("$tok"); done
         done < "$OPTARG" ;;
      o) OUT_FILE="$OPTARG" ;;
      h) usage ;;
      :) echo "选项 -$OPTARG 缺少参数" >&2; exit 1 ;;
      *) echo "未知选项: -$OPTARG" >&2; exit 1 ;;
    esac
  done
  shift $((OPTIND - 1))
  if [[ $# -gt 0 ]]; then
    IDS+=("$1")
    shift
  fi
done

if [[ ${#IDS[@]} -eq 0 ]]; then
  echo "用法: $0 [-f ids.txt] [-o upgrade.sh] <redis-id> [redis-id ...]" >&2
  exit 1
fi

command -v aws >/dev/null || { echo "未找到 aws CLI" >&2; exit 1; }

# 去重（保持原顺序）
UNIQ_IDS=()
for i in "${IDS[@]}"; do
  [[ -z "$i" ]] && continue
  dup=0
  for u in ${UNIQ_IDS[@]+"${UNIQ_IDS[@]}"}; do [[ "$u" == "$i" ]] && { dup=1; break; }; done
  [[ $dup -eq 0 ]] && UNIQ_IDS+=("$i")
done
IDS=("${UNIQ_IDS[@]}")

# ---------- 当前身份与区域 ----------
CALLER_JSON="$(aws sts get-caller-identity --output json 2>/dev/null)" || {
  echo "无法获取调用者身份，请检查 AWS 凭证（AWS_PROFILE / aws configure）。" >&2; exit 1; }
ACCOUNT_ID="$(printf '%s' "$CALLER_JSON" | sed -n 's/.*"Account": *"\([^"]*\)".*/\1/p')"
CALLER_ARN="$(printf '%s' "$CALLER_JSON" | sed -n 's/.*"Arn": *"\([^"]*\)".*/\1/p')"
REGION="$(aws configure get region 2>/dev/null)"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$REGION}}"
[[ -n "$REGION" ]] || { echo "未设置区域，请设置 AWS_REGION 或 aws configure。" >&2; exit 1; }

echo "=============================================================="
echo " 账号 (Account) : $ACCOUNT_ID"
echo " 身份 (Caller)  : $CALLER_ARN"
echo " 区域 (Region)  : $REGION"
echo " 目标版本       : Redis $TARGET_ENGINE_VERSION"
echo " 查询对象数量   : ${#IDS[@]}"
echo "=============================================================="
echo

# 统一的只读 aws 调用封装（兼容 bash 3.2 下 set -u 的空数组展开问题）
awsq() {
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    aws --profile "$AWS_PROFILE" --region "$REGION" "$@"
  else
    aws --region "$REGION" "$@"
  fi
}

# jq 可选；没有 jq 时退化为 --query text 输出
HAS_JQ=0
command -v jq >/dev/null && HAS_JQ=1

CMDS=()
NOT_FOUND=()

for ID in "${IDS[@]}"; do
  [[ -z "$ID" ]] && continue

  RG_TEXT="$(awsq elasticache describe-replication-groups \
      --replication-group-id "$ID" \
      --query 'ReplicationGroups[0].[Status,ClusterEnabled,MultiAZ,AutomaticFailover,CacheNodeType,Engine,NodeGroups[0].NodeGroupMembers[0].CacheClusterId,length(NodeGroups),ARN,Description]' \
      --output text 2>/dev/null)"

  if [[ -n "$RG_TEXT" && "$RG_TEXT" != "None" ]]; then
    IFS=$'\t' read -r STATUS CLUSTER_ENABLED MULTI_AZ AUTO_FAILOVER NODE_TYPE ENGINE MEMBER_ID SHARDS ARN DESC <<<"$RG_TEXT"

    # 引擎版本从成员节点取（replication group 本身不直接返回 EngineVersion）
    ENGINE_VERSION="$(awsq elasticache describe-cache-clusters \
        --cache-cluster-id "$MEMBER_ID" \
        --query 'CacheClusters[0].EngineVersion' --output text 2>/dev/null)"
    CUR_PG="$(awsq elasticache describe-cache-clusters \
        --cache-cluster-id "$MEMBER_ID" \
        --query 'CacheClusters[0].CacheParameterGroup.CacheParameterGroupName' --output text 2>/dev/null)"

    if [[ "$CLUSTER_ENABLED" == "True" ]]; then
      MODE="Cluster Mode Enabled (分片集群)"
      SUGGEST_PG="default.redis7.cluster.on"
    else
      MODE="Cluster Mode Disabled (主从)"
      SUGGEST_PG="default.redis7"
    fi

    echo "--------------------------------------------------------------"
    echo "[$ID]  类型: Replication Group"
    echo "  状态            : $STATUS"
    echo "  集群模式        : $MODE"
    echo "  Multi-AZ        : $MULTI_AZ"
    echo "  自动故障转移    : $AUTO_FAILOVER"
    echo "  分片数(Shards)  : $SHARDS"
    echo "  节点类型        : $NODE_TYPE"
    echo "  引擎/版本       : $ENGINE $ENGINE_VERSION"
    echo "  当前参数组      : $CUR_PG"
    echo "  建议参数组族    : $SUGGEST_PG  (请确认后替换占位符)"
    echo "  ARN             : $ARN"

    CMDS+=("# [$ID] $MODE | 当前 $ENGINE_VERSION -> $TARGET_ENGINE_VERSION | 当前参数组 $CUR_PG | 建议 $SUGGEST_PG
mkdir -p $LOG_DIR_PLACEHOLDER && nohup aws elasticache modify-replication-group --region $REGION${AWS_PROFILE:+ --profile $AWS_PROFILE} --replication-group-id $ID --engine-version $TARGET_ENGINE_VERSION --cache-parameter-group-name $PG_PLACEHOLDER --apply-immediately > $LOG_DIR_PLACEHOLDER/upgrade-$ID.log 2>&1 & disown")
    continue
  fi

  # 回退：单节点 cache cluster（无复制组）
  CC_TEXT="$(awsq elasticache describe-cache-clusters \
      --cache-cluster-id "$ID" \
      --query 'CacheClusters[0].[CacheClusterStatus,Engine,EngineVersion,CacheNodeType,PreferredAvailabilityZone,CacheParameterGroup.CacheParameterGroupName,ARN,ReplicationGroupId]' \
      --output text 2>/dev/null)"

  if [[ -n "$CC_TEXT" && "$CC_TEXT" != "None" ]]; then
    IFS=$'\t' read -r CSTATUS CENGINE CVER CNODE CAZ CPG CARN CRG <<<"$CC_TEXT"
    echo "--------------------------------------------------------------"
    echo "[$ID]  类型: 单节点 Cache Cluster"
    echo "  状态            : $CSTATUS"
    echo "  引擎/版本       : $CENGINE $CVER"
    echo "  节点类型        : $CNODE"
    echo "  可用区          : $CAZ   (单 AZ，无 Multi-AZ)"
    echo "  当前参数组      : $CPG"
    echo "  ARN             : $CARN"
    [[ "$CRG" != "None" && -n "$CRG" ]] && echo "  所属复制组      : $CRG （建议改用该复制组 ID 升级）"

    CMDS+=("# [$ID] 单节点 Cache Cluster | 当前 $CVER -> $TARGET_ENGINE_VERSION | 当前参数组 $CPG | 建议 default.redis7
mkdir -p $LOG_DIR_PLACEHOLDER && nohup aws elasticache modify-cache-cluster --region $REGION${AWS_PROFILE:+ --profile $AWS_PROFILE} --cache-cluster-id $ID --engine-version $TARGET_ENGINE_VERSION --cache-parameter-group-name $PG_PLACEHOLDER --apply-immediately > $LOG_DIR_PLACEHOLDER/upgrade-$ID.log 2>&1 & disown")
    continue
  fi

  echo "--------------------------------------------------------------"
  echo "[$ID]  没找到"
  NOT_FOUND+=("$ID")
done

echo
echo "=============================================================="
echo " 升级命令（后台运行模式，可直接粘贴到终端；参数组请先替换占位符）"
echo " 占位符: $PG_PLACEHOLDER"
echo "=============================================================="
if [[ ${#CMDS[@]} -eq 0 ]]; then
  echo "（无可升级对象）"
else
  for c in "${CMDS[@]}"; do echo; echo "$c"; done
fi
echo

if [[ ${#NOT_FOUND[@]} -gt 0 ]]; then
  echo "没找到的 ID (账号 $ACCOUNT_ID / 区域 $REGION)："
  for n in "${NOT_FOUND[@]}"; do echo "  - $n"; done
  echo
fi

if [[ -n "$OUT_FILE" && ${#CMDS[@]} -eq 0 ]]; then
  echo "没有可升级对象，跳过写出 $OUT_FILE"
elif [[ -n "$OUT_FILE" ]]; then
  {
    echo "#!/usr/bin/env bash"
    echo "# 自动生成：$(date '+%F %T')  账号 $ACCOUNT_ID  区域 $REGION"
    echo "# 执行前请把所有 $PG_PLACEHOLDER 替换为实际参数组名"
    echo "set -u"
    for c in "${CMDS[@]}"; do echo; echo "$c"; done
    echo
    echo 'wait'
  } > "$OUT_FILE"
  chmod +x "$OUT_FILE"
  echo "已写出升级脚本: $OUT_FILE"
fi
