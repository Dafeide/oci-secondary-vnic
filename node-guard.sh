#!/usr/bin/env bash
#=====================================================================
# node-guard — 代理节点 BT/PT 与垃圾邮件 出站封禁管理脚本
#
# 适用系统 : Debian / Ubuntu / CentOS / Rocky / Alma（需 root）
# 依赖     : iptables（可选 ip6tables）、内核 xt_string / xt_multiport 模块
# 用法     : bash node-guard.sh              进入菜单
#            bash node-guard.sh banall       封禁 BT(标准) + SPAM
#            bash node-guard.sh banall strict  封禁 BT(严格) + SPAM
#            bash node-guard.sh help         查看全部命令
#
# 设计:
#   * 所有规则放在独立链 NG_BT / NG_SPAM / NG_CUSTOM / NG_INPUT 中，
#     只在 OUTPUT、FORWARD（及 DOCKER-USER）挂一个跳转，不碰你的其它规则。
#   * 封禁状态写入 /etc/node-guard，开机由 systemd 服务重新应用，
#     不依赖 iptables-persistent，也不会把 Docker 等规则一起存进去。
#   * 每次 apply 都是"清空自有链 → 按配置重建"，可重复执行，不会产生重复规则。
#=====================================================================
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

VER="2.1.3"
CONF_DIR="/etc/node-guard"
CONF="$CONF_DIR/config"
PORTS_FILE="$CONF_DIR/ports.list"
WORDS_FILE="$CONF_DIR/keywords.list"
BIN="/usr/local/sbin/node-guard"
UNIT="/etc/systemd/system/node-guard.service"

C_BT="NG_BT"
C_SPAM="NG_SPAM"
C_CUS="NG_CUSTOM"
C_IN="NG_INPUT"

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'
info() { echo -e "${G}[信息]${N} $*"; }
warn() { echo -e "${Y}[警告]${N} $*"; }
err()  { echo -e "${R}[错误]${N} $*" >&2; }

#---------------------------------------------------------------------
# 默认规则集
#---------------------------------------------------------------------
SMTP_PORTS="25,26,465,587"
POP3_PORTS="109,110,995"
IMAP_PORTS="143,218,220,993"
OTHER_PORTS="24,50,57,105,106,158,209,1109,24554,60177,60179"

# 标准：BT 握手 / DHT / tracker 特征，误杀极少
BT_STD=(
  "BitTorrent protocol"
  "info_hash"
  "get_peers"
  "find_node"
  "announce_peer"
  "announce.php?passkey="
  "peer_id="
  "d1:ad2:id20:"
  "d1:rd2:id20:"
)
# 严格：在标准基础上追加更宽泛的词（明文 HTTP 里含这些词的页面也会被丢包）
BT_STRICT_EXTRA=(
  "magnet:"
  "torrent"
  "announce"
  "xunlei"
  "sandai"
  "XLLiveUD"
  "bt_key"
)

#---------------------------------------------------------------------
# 环境检查
#---------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  err "请使用 root 权限运行"
  exit 1
fi
if ! command -v iptables >/dev/null 2>&1; then
  err "未安装 iptables。Debian/Ubuntu: apt install iptables ；CentOS: yum install iptables"
  exit 1
fi
IPTS=(iptables)
if command -v ip6tables >/dev/null 2>&1 && ip6tables -S >/dev/null 2>&1; then
  IPTS+=(ip6tables)
fi

#---------------------------------------------------------------------
# 配置读写
#---------------------------------------------------------------------
BT_MODE="off"    # off | standard | strict
SPAM="off"       # on | off
BASE="off"       # on | off

# shellcheck disable=SC1090
load_conf() { [ -f "$CONF" ] && . "$CONF"; return 0; }
save_conf() {
  mkdir -p "$CONF_DIR"
  cat >"$CONF" <<EOF
BT_MODE="$BT_MODE"
SPAM="$SPAM"
BASE="$BASE"
EOF
}

#---------------------------------------------------------------------
# iptables 构件
#---------------------------------------------------------------------
ensure_chain() { "$1" -N "$2" 2>/dev/null; "$1" -F "$2"; }
ensure_jump()  { "$1" -C "$2" -j "$3" 2>/dev/null || "$1" -I "$2" 1 -j "$3"; }
drop_jumps() {
  local p
  for p in OUTPUT FORWARD DOCKER-USER INPUT; do
    while "$1" -D "$p" -j "$2" 2>/dev/null; do :; done
  done
}
parents_for() {
  echo OUTPUT
  echo FORWARD
  "$1" -S DOCKER-USER >/dev/null 2>&1 && echo DOCKER-USER
  return 0
}

# 把 "25,26,465:500" 切成每行最多 7 项（multiport 每条规则最多 15 个端口，范围算 2 个）
ports_to_chunks() {
  local -a a
  IFS=',' read -ra a <<<"$1"
  local item line="" i=0
  for item in "${a[@]}"; do
    line+="${line:+,}$item"
    i=$((i + 1))
    if [ "$i" -ge 7 ]; then echo "$line"; line=""; i=0; fi
  done
  [ -n "$line" ] && echo "$line"
  return 0
}

block_ports() { # ipt chain ports
  local ipt=$1 chain=$2 chunk
  while IFS= read -r chunk; do
    [ -n "$chunk" ] || continue
    "$ipt" -A "$chain" -p tcp -m multiport --dports "$chunk" -j REJECT --reject-with tcp-reset \
      || warn "$ipt: 添加 TCP 端口规则失败: $chunk"
    "$ipt" -A "$chain" -p udp -m multiport --dports "$chunk" -j DROP \
      || warn "$ipt: 添加 UDP 端口规则失败: $chunk"
  done < <(ports_to_chunks "$3")
}

block_words() { # ipt chain word...
  local ipt=$1 chain=$2 w
  shift 2
  for w in "$@"; do
    [ -n "$w" ] || continue
    if ! "$ipt" -A "$chain" -m string --string "$w" --algo bm -j DROP 2>/dev/null; then
      warn "$ipt: 添加关键词规则失败: \"$w\"（内核可能缺少 xt_string 模块，OpenVZ/LXC 上常见）"
      return 1
    fi
  done
  return 0
}

#---------------------------------------------------------------------
# 核心：按配置重建全部规则
#---------------------------------------------------------------------
apply() {
  load_conf
  local ipt p c
  local -a custom_words=()
  [ -f "$WORDS_FILE" ] && mapfile -t custom_words <"$WORDS_FILE"

  for ipt in "${IPTS[@]}"; do
    for c in "$C_BT" "$C_SPAM" "$C_CUS" "$C_IN"; do ensure_chain "$ipt" "$c"; done

    case "$BT_MODE" in
      standard) block_words "$ipt" "$C_BT" "${BT_STD[@]}" ;;
      strict)   block_words "$ipt" "$C_BT" "${BT_STD[@]}" "${BT_STRICT_EXTRA[@]}" ;;
    esac

    if [ "$SPAM" = "on" ]; then
      for p in "$SMTP_PORTS" "$POP3_PORTS" "$IMAP_PORTS" "$OTHER_PORTS"; do
        block_ports "$ipt" "$C_SPAM" "$p"
      done
    fi

    if [ -s "$PORTS_FILE" ]; then
      while IFS= read -r p; do
        [ -n "$p" ] && block_ports "$ipt" "$C_CUS" "$p"
      done <"$PORTS_FILE"
    fi
    [ "${#custom_words[@]}" -gt 0 ] && block_words "$ipt" "$C_CUS" "${custom_words[@]}"

    if [ "$BASE" = "on" ]; then
      "$ipt" -A "$C_IN" -p tcp --tcp-flags ALL FIN,URG,PSH -j DROP
      "$ipt" -A "$C_IN" -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
      "$ipt" -A "$C_IN" -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
      "$ipt" -A "$C_IN" -p tcp --dport 25 -j DROP
    fi

    for c in "$C_BT" "$C_SPAM" "$C_CUS"; do
      for p in $(parents_for "$ipt"); do ensure_jump "$ipt" "$p" "$c"; done
    done
    ensure_jump "$ipt" INPUT "$C_IN"

    # 回环放行必须排在最前，否则端口封禁会误伤本机内部连接
    while "$ipt" -D OUTPUT -o lo -j ACCEPT 2>/dev/null; do :; done
    "$ipt" -I OUTPUT 1 -o lo -j ACCEPT
  done
}

#---------------------------------------------------------------------
# 状态 / 测试
#---------------------------------------------------------------------
chain_hits() { "$1" -L "$2" -v -n -x 2>/dev/null | awk 'NR>2{s+=$1} END{print s+0}'; }

show_status() {
  load_conf
  local ipt c
  echo "================ node-guard v$VER ================"
  echo " BT/PT 封禁 : $BT_MODE"
  echo " SPAM 端口  : $SPAM"
  echo " 基础入站防护: $BASE"
  echo " IPv6 支持  : $([ "${#IPTS[@]}" -gt 1 ] && echo 是 || echo 否)"
  if command -v systemctl >/dev/null 2>&1; then
    echo " 开机自启   : $(systemctl is-enabled node-guard.service 2>/dev/null || echo 未安装)"
  fi
  echo "=================================================="
  for ipt in "${IPTS[@]}"; do
    echo; echo "------ $ipt ------"
    for c in "$C_BT" "$C_SPAM" "$C_CUS" "$C_IN"; do
      if "$ipt" -S "$c" >/dev/null 2>&1 && [ "$("$ipt" -S "$c" | grep -c '^-A')" -gt 0 ]; then
        echo "[$c]"
        "$ipt" -L "$c" -v -n --line-numbers
      fi
    done
    if "$ipt" -S OUTPUT | grep -qE '^-A OUTPUT .*(-m string|-m multiport)'; then
      warn "$ipt: OUTPUT 链里存在旧的手工规则，建议用菜单 15 迁移"
    fi
  done
}

test_bt() {
  load_conf
  if [ "$BT_MODE" = "off" ]; then
    warn "当前未启用 BT 封禁，请先封禁后再测试"
    return 1
  fi
  local ipt target b a
  for ipt in "${IPTS[@]}"; do
    if [ "$ipt" = "iptables" ]; then target="1.1.1.1"; else target="2606:4700:4700::1111"; fi
    b=$(chain_hits "$ipt" "$C_BT")
    timeout 4 bash -c "exec 3<>/dev/tcp/$target/80 && printf 'xxBitTorrent protocolxx' >&3" 2>/dev/null
    sleep 1
    a=$(chain_hits "$ipt" "$C_BT")
    if [ "$a" -gt "$b" ]; then
      info "$ipt: 规则命中，计数 +$((a - b)) ✓"
    else
      warn "$ipt: 计数没有增长（IPv6 无外网连通时属正常；IPv4 出现此提示请检查 xt_string 模块）"
    fi
  done
  echo "说明：这是本机发起的测试流量。代理转发的流量同样经过 OUTPUT 链，"
  echo "      想验证用户流量，可用测试账号跑 BT 客户端，再看菜单 13 的命中计数是否增长。"
}

#---------------------------------------------------------------------
# 迁移旧的手工规则
#---------------------------------------------------------------------
migrate_legacy() {
  local ipt chain rule ans assume_yes="${1:-}"
  local -a cands=()
  for ipt in "${IPTS[@]}"; do
    for chain in OUTPUT INPUT; do
      while IFS= read -r rule; do
        case "$rule" in *\;*|*\&*|*\|*|*\`*|*\$*|*\(*|*\)*) continue ;; esac
        case "$chain:$rule" in
          OUTPUT:*"-m string"*|OUTPUT:*"-m multiport --dports"*|OUTPUT:*"--dport 25 -j DROP"*|INPUT:*"--dport 25 -j DROP"*)
            cands+=("$ipt|$rule") ;;
        esac
      done < <("$ipt" -S "$chain" | grep -E '^-A ')
    done
  done
  if [ "${#cands[@]}" -eq 0 ]; then
    info "没有发现旧的手工规则"
    return 0
  fi
  echo "将要删除以下 ${#cands[@]} 条旧规则（只涉及 OUTPUT/INPUT 顶层的 string / multiport / 25 端口规则）:"
  printf '  %s\n' "${cands[@]}"
  if [ "$assume_yes" = "-y" ] || [ "$assume_yes" = "--yes" ]; then
    echo "已指定 -y，跳过确认"
  else
    read -r -p "确认删除？删除后请先确保已封禁 BT/SPAM 再继续 [y/N]: " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "已取消"; return 0; }
  fi
  local item n=0
  for item in "${cands[@]}"; do
    ipt=${item%%|*}; rule=${item#*|}
    eval "$ipt ${rule/#-A/-D}" 2>/dev/null && n=$((n + 1))
  done
  info "已删除 $n 条旧规则"
}

#---------------------------------------------------------------------
# 安装 / 卸载
#---------------------------------------------------------------------
install_self() {
  local src
  src=$(readlink -f "$0" 2>/dev/null || echo "$0")
  if [ "$src" != "$BIN" ]; then
    if [ ! -f "$src" ]; then
      err "请先把脚本保存成文件再安装：curl -fsSL <脚本URL> -o node-guard.sh && bash node-guard.sh"
      return 1
    fi
    install -m 755 "$src" "$BIN" || { err "复制到 $BIN 失败"; return 1; }
  fi
  load_conf; save_conf
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "未检测到 systemd，已安装命令 node-guard，但需自行配置开机执行 'node-guard apply'"
    return 0
  fi
  cat >"$UNIT" <<EOF
[Unit]
Description=node-guard firewall rules (BT/SPAM block)
# 必须排在网络启动之后：部分模板会在 ifup 时执行 iptables-restore 覆盖 IPv4 规则
After=network-pre.target networking.service network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN apply
ExecReload=$BIN apply

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable node-guard.service >/dev/null 2>&1
  info "已安装命令 node-guard，并设置开机自动应用规则（systemd: node-guard.service）"
}

uninstall_all() {
  local ans ipt c
  read -r -p "将删除所有 node-guard 规则、配置、开机服务和命令，确认？[y/N]: " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "已取消"; return 0; }
  for ipt in "${IPTS[@]}"; do
    for c in "$C_BT" "$C_SPAM" "$C_CUS" "$C_IN"; do
      drop_jumps "$ipt" "$c"
      "$ipt" -F "$c" 2>/dev/null
      "$ipt" -X "$c" 2>/dev/null
    done
  done
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable node-guard.service >/dev/null 2>&1
    rm -f "$UNIT"
    systemctl daemon-reload
  fi
  rm -rf "$CONF_DIR"
  [ "$(readlink -f "$0" 2>/dev/null)" != "$BIN" ] && rm -f "$BIN"
  info "已卸载。注意：本脚本加的回环放行规则（-o lo）仍保留，它是无害的"
}

#---------------------------------------------------------------------
# 封禁 / 解封 操作
#---------------------------------------------------------------------
set_bt()   { load_conf; BT_MODE="$1"; save_conf; apply; }
set_spam() { load_conf; SPAM="$1";    save_conf; apply; }

ban_bt() {
  local mode="${1:-standard}"
  case "$mode" in standard|strict) ;; *) err "模式只能是 standard 或 strict"; return 1 ;; esac
  set_bt "$mode"
  info "已封禁 BT/PT（$mode）"
}
unban_bt()   { set_bt off;  info "已解封 BT/PT"; }
ban_spam()   { set_spam on; info "已封禁 SPAM 端口（$SMTP_PORTS | $POP3_PORTS | $IMAP_PORTS | $OTHER_PORTS）"; }
unban_spam() { set_spam off; info "已解封 SPAM 端口"; }
ban_all() {
  local mode="${1:-standard}"
  case "$mode" in standard|strict) ;; *) err "模式只能是 standard 或 strict"; return 1 ;; esac
  load_conf; BT_MODE="$mode"; SPAM="on"; save_conf; apply
  info "已封禁 BT/PT（$mode）+ SPAM 端口"
}
unban_all() {
  load_conf; BT_MODE="off"; SPAM="off"; BASE="off"; save_conf
  : >"$PORTS_FILE" 2>/dev/null; : >"$WORDS_FILE" 2>/dev/null
  apply; info "已解封全部（规则链已清空，配置文件与开机服务保留）"
}
toggle_base() {
  load_conf
  if [ "$BASE" = "on" ]; then BASE="off"; else BASE="on"; fi
  save_conf; apply
  info "基础入站防护已$([ "$BASE" = "on" ] && echo 开启 || echo 关闭)"
}

valid_ports() { [[ "$1" =~ ^[0-9]+(:[0-9]+)?(,[0-9]+(:[0-9]+)?)*$ ]]; }

add_custom_ports() {
  local p
  echo "格式：单端口 6881 | 多端口 6881,6882 | 范围 6881:6999（也可写 6881-6999）"
  read -r -p "要封禁的端口（回车取消）: " p
  [ -z "$p" ] && return 0
  p=${p// /}; p=${p//-/:}
  valid_ports "$p" || { err "格式不正确"; return 1; }
  mkdir -p "$CONF_DIR"; touch "$PORTS_FILE"
  grep -qxF -- "$p" "$PORTS_FILE" || echo "$p" >>"$PORTS_FILE"
  apply && info "已封禁端口 [$p]（TCP 拒绝 + UDP 丢弃）"
}

del_custom_ports() {
  local p
  [ -s "$PORTS_FILE" ] || { warn "没有自定义封禁端口"; return 0; }
  echo "当前自定义封禁端口:"; nl -ba "$PORTS_FILE"
  read -r -p "要解封的条目（与上面完全一致，回车取消）: " p
  [ -z "$p" ] && return 0
  p=${p// /}; p=${p//-/:}
  grep -vxF -- "$p" "$PORTS_FILE" >"$PORTS_FILE.tmp"; mv "$PORTS_FILE.tmp" "$PORTS_FILE"
  apply && info "已解封端口 [$p]"
}

add_custom_words() {
  local w
  echo "输入关键词（域名片段或任意明文特征），每行一个，空行结束。"
  echo "例：youtube.com 会丢弃含该字串的明文请求；HTTPS 流量内容看不到，对其无效。"
  mkdir -p "$CONF_DIR"; touch "$WORDS_FILE"
  while true; do
    read -r -p "关键词: " w
    [ -z "$w" ] && break
    grep -qxF -- "$w" "$WORDS_FILE" || echo "$w" >>"$WORDS_FILE"
  done
  apply && info "自定义关键词已更新"
}

del_custom_words() {
  local w
  [ -s "$WORDS_FILE" ] || { warn "没有自定义关键词"; return 0; }
  echo "当前自定义关键词:"; nl -ba "$WORDS_FILE"
  read -r -p "要解封的关键词（与上面完全一致，回车取消）: " w
  [ -z "$w" ] && return 0
  grep -vxF -- "$w" "$WORDS_FILE" >"$WORDS_FILE.tmp"; mv "$WORDS_FILE.tmp" "$WORDS_FILE"
  apply && info "已解封关键词 [$w]"
}

#---------------------------------------------------------------------
# 菜单
#---------------------------------------------------------------------
usage() {
  cat <<EOF
node-guard v$VER

用法: $(basename "$0") [命令]
  (无参数)          进入菜单
  banbt [standard|strict]   封禁 BT/PT（默认 standard）
  unbanbt           解封 BT/PT
  banspam           封禁 SPAM 邮件端口
  unbanspam         解封 SPAM 邮件端口
  banall [standard|strict]  封禁 BT + SPAM（默认 standard）
  unbanall          解封全部
  status            查看规则与命中计数
  test              测试 BT 规则是否生效
  migrate [-y]      清理旧的手工规则（默认先列出并确认，-y 跳过确认）
  apply             按配置重建规则（开机服务使用）
  install           安装为系统命令并开机自启
  uninstall         卸载
EOF
}

show_menu() {
  cat <<EOF

 node-guard ${R}[v$VER]${N}  代理节点 BT/PT + 垃圾邮件 封禁管理
 ──────────────────────────────────────────
  ${G}1.${N} 封禁 BT/PT（标准：特征串，误杀极少，推荐）
  ${G}2.${N} 封禁 BT/PT（严格：追加 magnet/torrent/迅雷等，误杀较多）
  ${G}3.${N} 封禁 SPAM 邮件端口
  ${G}4.${N} 一键封禁 BT(标准) + SPAM
  ${G}5.${N} 一键封禁 BT(严格) + SPAM
  ${G}6.${N} 封禁 自定义端口
  ${G}7.${N} 封禁 自定义关键词
 ──────────────────────────────────────────
  ${G}8.${N} 解封 BT/PT
  ${G}9.${N} 解封 SPAM
 ${G}10.${N} 解封 自定义端口
 ${G}11.${N} 解封 自定义关键词
 ${G}12.${N} 解封 全部
 ──────────────────────────────────────────
 ${G}13.${N} 开启/关闭 基础入站防护（TCP 异常标志位 + 入站 25 端口）
 ${G}14.${N} 查看规则与命中计数
 ${G}15.${N} 测试 BT 规则是否生效
 ${G}16.${N} 清理旧的手工规则（迁移到本脚本管理）
 ${G}17.${N} 安装为系统命令 + 开机自启
 ${G}18.${N} 卸载
  ${G}0.${N} 退出
EOF
}

menu() {
  local num ans
  while true; do
    show_menu
    read -r -p " 请输入数字 [0-18]: " num
    case "$num" in
      1)  ban_bt standard ;;
      2)  ban_bt strict ;;
      3)  ban_spam ;;
      4)  ban_all standard ;;
      5)  ban_all strict ;;
      6)  add_custom_ports ;;
      7)  add_custom_words ;;
      8)  unban_bt ;;
      9)  unban_spam ;;
      10) del_custom_ports ;;
      11) del_custom_words ;;
      12) read -r -p "确认解封全部（含自定义端口/关键词）？[y/N]: " ans
          if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then unban_all; fi ;;
      13) toggle_base ;;
      14) show_status ;;
      15) test_bt ;;
      16) migrate_legacy ;;
      17) install_self ;;
      18) uninstall_all ;;
      0)  exit 0 ;;
      *)  warn "请输入 0-18 之间的数字" ;;
    esac
    echo
    read -r -p "回车返回菜单..." _
  done
}

#---------------------------------------------------------------------
# 入口
#---------------------------------------------------------------------
case "${1:-menu}" in
  menu)      menu ;;
  banbt)     ban_bt "${2:-standard}" ;;
  unbanbt)   unban_bt ;;
  banspam)   ban_spam ;;
  unbanspam) unban_spam ;;
  banall)    ban_all "${2:-standard}" ;;
  unbanall)  unban_all ;;
  status)    show_status ;;
  test)      test_bt ;;
  migrate)   migrate_legacy "${2:-}" ;;
  apply)     apply ;;
  install)   install_self ;;
  uninstall) uninstall_all ;;
  help|-h|--help) usage ;;
  *)         usage; exit 1 ;;
esac
