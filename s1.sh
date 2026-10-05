#!/bin/bash

# =========================
# 煜恒singbox四合一安装脚本
# vless-version-reality|vmess-ws-tls(tunnel)|hysteria2|tuic5|[可额外添加Anytls，socks5，ss2022等协议] 
# 最后更新时间: 2026.6.7[添加hy2证书, 添加ipv4和ipv6切换]
# =========================

export LANG=en_US.UTF-8
# 定义颜色
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }

# 定义常量
server_name="sing-box"
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
client_dir="${work_dir}/url.txt"
users_dir="${work_dir}/users"
cron_file="/etc/cron.d/sing-box-rotate"
rotate_log="${work_dir}/rotate.log"
cron_conf="${work_dir}/cron.conf"
export vless_port=${PORT:-$(shuf -i 1000-65000 -n 1)}
export CFIP=${CFIP:-'cdns.doon.eu.org'} 
export ARGO_PORT=${ARGO_PORT:-'8001'} 
export CFPORT=${CFPORT:-'443'} 

# 检查是否为root下运行
[[ $EUID -ne 0 ]] && red "请在root用户下运行脚本，可输入 sudo -i 回车切换到root用户" && exit 1

# 检查命令是否存在函数
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查服务状态通用函数
check_service() {
    local service_name=$1
    local service_file=$2
    
    [[ ! -f "${service_file}" ]] && { red "not installed"; return 2; }
        
    if command_exists apk; then
        rc-service "${service_name}" status | grep -q "started" && green "running" || yellow "not running"
    else
        systemctl is-active "${service_name}" | grep -q "^active$" && green "running" || yellow "not running"
    fi
    return $?
}

# 检查sing-box状态
check_singbox() {
    check_service "sing-box" "${work_dir}/${server_name}"
}

# 检查argo状态
check_argo() {
    check_service "argo" "${work_dir}/argo"
}

# 检查nginx状态
check_nginx() {
    command_exists nginx || { red "not installed"; return 2; }
    check_service "nginx" "$(command -v nginx)"
}

# 根据系统类型安装、卸载依赖
manage_packages() {
    if [ $# -lt 2 ]; then
        red "Unspecified package name or action"
        return 1
    fi

    action=$1
    shift

    # 首次安装更新系统
    if [ "$action" == "install" ] && [ ! -d "$work_dir" ]; then
        yellow "正在更新系统软件包...\n"
        if command_exists apt; then
            DEBIAN_FRONTEND=noninteractive apt update -y && DEBIAN_FRONTEND=noninteractive apt upgrade -y
        elif command_exists dnf; then
            dnf update -y
        elif command_exists yum; then
            yum update -y
        elif command_exists apk; then
            apk update && apk upgrade
        else
            yellow "Unknown system!\n"
        fi
        green "finished updated system\n"
    fi

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command_exists "$package"; then
                green "${package} already installed"
                continue
            fi
            yellow "正在安装 ${package}..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt install -y "$package"
            elif command_exists dnf; then
                dnf install -y "$package"
            elif command_exists yum; then
                yum install -y "$package"
            elif command_exists apk; then
                apk add "$package"
            else
                red "Unknown system!"
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if ! command_exists "$package"; then
                yellow "${package} is not installed"
                continue
            fi
            yellow "正在卸载 ${package}..."
            if command_exists apt; then
                apt remove -y "$package" && apt autoremove -y
            elif command_exists dnf; then
                dnf remove -y "$package" && dnf autoremove -y
            elif command_exists yum; then
                yum remove -y "$package" && yum autoremove -y
            elif command_exists apk; then
                apk del "$package"
            else
                red "Unknown system!"
                return 1
            fi
        else
            red "Unknown action: $action"
            return 1
        fi
    done

    return 0
}

# 获取ip
get_realip() {
    local cache_file="${work_dir}/ip.cache"
    # 如果缓存存在且不超过1小时，直接读取缓存，毫秒级响应
    if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
        local now_ts=$(date +%s)
        local f_ts=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
        if [ $((now_ts - f_ts)) -lt 3600 ]; then
            cat "$cache_file"
            return 0
        fi
    fi

    ip=$(curl -4 -sm 2 ip.sb 2>/dev/null)
    ipv6() { curl -6 -sm 2 ip.sb 2>/dev/null; }
    local res=""
    if [ -z "$ip" ]; then
        res="[$(ipv6)]"
    else 
        if curl -4 -sm 2 http://ipinfo.io/org 2>/dev/null | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
            res="[$(ipv6)]"
        else
            if grep -qE '^\s*precedence\s+::ffff:0:0/96\s+100' "/etc/gai.conf" 2>/dev/null; then
                res="$ip"
            else
                v6=$(ipv6)
                [ -n "$v6" ] && res="[$v6]" || res="$ip"
            fi
        fi
    fi
    [ -n "$res" ] && echo "$res" > "$cache_file" 2>/dev/null || true
    echo "$res"
}

# 处理防火墙
allow_port() {
    has_ufw=0
    has_firewalld=0
    has_iptables=0
    has_ip6tables=0

    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists iptables && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    [ "$has_ufw" -eq 1 ] && ufw --force default allow outgoing >/dev/null 2>&1
    [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --zone=public --set-target=ACCEPT >/dev/null 2>&1
    [ "$has_iptables" -eq 1 ] && {
        iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 3 -i lo -j ACCEPT
        iptables -C INPUT -p icmp -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p icmp -j ACCEPT
        iptables -P FORWARD DROP 2>/dev/null || true
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
    }
    [ "$has_ip6tables" -eq 1 ] && {
        ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null || ip6tables -I INPUT 3 -i lo -j ACCEPT
        ip6tables -C INPUT -p icmp -j ACCEPT 2>/dev/null || ip6tables -I INPUT 4 -p icmp -j ACCEPT
        ip6tables -P FORWARD DROP 2>/dev/null || true
        ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
    }

    for rule in "$@"; do
        port=${rule%/*}
        proto=${rule#*/}
        local ufw_port="$port"
        local fwd_port="$port"
        local ipt_port="$port"
        if [[ "$port" == *"-"* ]]; then
            ufw_port="${port/-/':'}"
            ipt_port="${port/-/':'}"
            fwd_port="$port"
        elif [[ "$port" == *":"* ]]; then
            ufw_port="$port"
            ipt_port="$port"
            fwd_port="${port/':'/'-'}"
        fi
        [ "$has_ufw" -eq 1 ] && ufw allow in ${ufw_port}/${proto} >/dev/null 2>&1
        [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --add-port=${fwd_port}/${proto} >/dev/null 2>&1
        [ "$has_iptables" -eq 1 ] && (iptables -C INPUT -p ${proto} --dport ${ipt_port} -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p ${proto} --dport ${ipt_port} -j ACCEPT)
        [ "$has_ip6tables" -eq 1 ] && (ip6tables -C INPUT -p ${proto} --dport ${ipt_port} -j ACCEPT 2>/dev/null || ip6tables -I INPUT 4 -p ${proto} --dport ${ipt_port} -j ACCEPT)
    done

    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1

    if command_exists rc-service 2>/dev/null; then
        [ "$has_iptables" -eq 1 ] && iptables-save > /etc/iptables/rules.v4 2>/dev/null
        [ "$has_ip6tables" -eq 1 ] && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    else
        if ! command_exists netfilter-persistent; then
            manage_packages install iptables-persistent || yellow "请手动安装netfilter-persistent或保存iptables规则"
            netfilter-persistent save >/dev/null 2>&1
        elif command_exists service; then
            service iptables save 2>/dev/null
            service ip6tables save 2>/dev/null
        fi
    fi
}

# 下载并安装 sing-box,cloudflared
install_singbox() {
    clear
    purple "正在安装sing-box中，请稍后..."
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64' | 'amd64')  ARCH='amd64' ;;
        'x86' | 'i686' | 'i386') ARCH='386' ;;
        'aarch64' | 'arm64') ARCH='arm64' ;;
        'armv7l')  ARCH='armv7' ;;
        's390x')   ARCH='s390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}" && chmod 777 "${work_dir}" && mkdir -p "${conf_dir}"
    # latest_version=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | jq -r '[.[] | select(.prerelease==false)][0].tag_name | sub("^v"; "")')
    # curl -sLo "${work_dir}/${server_name}.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/sing-box-${latest_version}-linux-${ARCH}.tar.gz"
    # curl -sLo "${work_dir}/qrencode" "https://github.com/eooce/test/releases/download/${ARCH}/qrencode-linux-${ARCH}"
    curl -sLo "${work_dir}/qrencode" "https://$ARCH.eooce.com/qrencode"
    curl -sLo "${work_dir}/sing-box" "https://$ARCH.eooce.com/sb"
    curl -sLo "${work_dir}/argo" "https://$ARCH.eooce.com/bot"
    # tar -xzvf "${work_dir}/${server_name}.tar.gz" -C "${work_dir}/" && \
    # mv "${work_dir}/sing-box-${latest_version}-linux-${ARCH}/sing-box" "${work_dir}/" && \
    # rm -rf "${work_dir}/${server_name}.tar.gz" "${work_dir}/sing-box-${latest_version}-linux-${ARCH}"
    chown root:root ${work_dir} && chmod +x ${work_dir}/${server_name} ${work_dir}/argo ${work_dir}/qrencode

    nginx_port=$(($vless_port + 1))
    tuic_port=$(($vless_port + 2))
    hy2_port=$(($vless_port + 3))
    uuid=$(cat /proc/sys/kernel/random/uuid)
    password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)
    output=$(/etc/sing-box/sing-box generate reality-keypair)
    private_key=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "${output}" | awk '/PublicKey:/ {print $2}')
    echo "$public_key" > "${work_dir}/reality.pub" 2>/dev/null || true
    echo "$private_key" > "${work_dir}/reality.key" 2>/dev/null || true

    allow_port $vless_port/tcp $nginx_port/tcp $tuic_port/udp $hy2_port/udp > /dev/null 2>&1

    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"
    
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')
    
    dns_strategy=$(ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "prefer_ipv4" || \
        (ping -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1 && echo "prefer_ipv6" || echo "prefer_ipv4"))
    
    cat > "${conf_dir}/log.json" << EOF
{
  "log": {
    "disabled": false,
    "level": "error",
    "output": "$work_dir/sb.log",
    "timestamp": true
  }
}
EOF

    cat > ${conf_dir}/ntp.json << EOF
{
    "ntp": {
        "enabled": true,
        "server": "time.apple.com",
        "server_port": 123,
        "interval": "60m"
    }
}
EOF

    cat > "${conf_dir}/dns.json" << EOF
{
  "dns": {
    "servers": [
      {
        "tag": "local",
        "type": "local"
      }
    ],
    "strategy": "$dns_strategy"
  }
}
EOF

    cat > "${conf_dir}/inbounds.json" << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": $vless_port,
      "users": [
        {
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.iij.ad.jp",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.iij.ad.jp",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": [""]
        }
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-ws",
      "listen": "::",
      "listen_port": ${ARGO_PORT},
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vmess-argo",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "::",
      "listen_port": $hy2_port,
      "users": [
        {
          "password": "$uuid"
        }
      ],
      "ignore_client_bandwidth": false,
      "masquerade": "https://bing.com",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "min_version": "1.3",
        "max_version": "1.3",
        "certificate_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/private.key"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "::",
      "listen_port": $tuic_port,
      "users": [
        {
          "uuid": "$uuid",
          "password": "$uuid"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/private.key"
      }
    }
  ]
}
EOF

    cat > "${conf_dir}/outbounds.json" << EOF
{
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    cat > "${conf_dir}/endpoints.json" << EOF
{
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "wireguard-out",
      "mtu": 1280,
      "address": [
        "172.16.0.2/32",
        "2606:4700:110:8dfe:d141:69bb:6b80:925/128"
      ],
      "private_key": "YFYOAdbw1bKTHlNNi+aEjBM3BO7unuFC5rOkMRAz9XY=",
      "peers": [
        {
          "address": "engage.cloudflareclient.com",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "reserved": [78, 135, 76]
        }
      ]
    }
  ]
}
EOF

    cat > "${conf_dir}/route.json" << EOF
{
  "route": {
    "rule_set": [
      {"tag":"gemini","type":"remote","format":"binary","url":"https://main.ssss.nyc.mn/gemini.srs","download_detour":"direct"},
      {"tag":"claude","type":"remote","format":"binary","url":"https://main.ssss.nyc.mn/claude.srs","download_detour":"direct"},
      {"tag":"openai","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/openai.srs","download_detour":"direct"},
      {"tag":"tiktok","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/tiktok.srs","download_detour":"direct"},
      {"tag":"twitter","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/twitter.srs","download_detour":"direct"},
      {"tag":"google","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/google.srs","download_detour":"direct"},
      {"tag":"telegram","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/telegram.srs","download_detour":"direct"},
      {"tag":"youtube","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/youtube.srs","download_detour":"direct"},
      {"tag":"netflix","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/netflix.srs","download_detour":"direct"}
    ],
    "rules": [{"rule_set": []}],
    "final": "direct"
  }
}
EOF
}

# debian/ubuntu/centos 守护进程
main_systemd_services() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/sing-box/sing-box run -C /etc/sing-box/conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --url http://localhost:8001 --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd
        systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    fi
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    systemctl enable argo
    systemctl start argo
}

# 适配alpine 守护进程
alpine_openrc_services() {
    cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run
description="sing-box service"
command="/etc/sing-box/sing-box"
command_args="run -C /etc/sing-box/conf"
command_background=true
pidfile="/var/run/sing-box.pid"
EOF

    cat > /etc/init.d/argo << 'EOF'
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '/etc/sing-box/argo tunnel --url http://localhost:8001 --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1'"
command_background=true
pidfile="/var/run/argo.pid"
EOF

    chmod +x /etc/init.d/sing-box
    chmod +x /etc/init.d/argo
    rc-update add sing-box default > /dev/null 2>&1
    rc-update add argo default     > /dev/null 2>&1
}

# 生成节点和订阅链接
get_info() {
    yellow "\nip检测中,请稍等...\n"
    server_ip=$(get_realip)
    clear
    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' | \
        awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | \
        sed 's/ /_/g' || \
        curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://ipapi.co/json" | tr -d '\n' | \
        awk -F\" '{c="";o="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="org")o=$(x+2)};if(c&&o)print c"-"o}' | \
        sed 's/ /_/g' || echo "$hostname")

    # 毫秒级主动嗅探代替死等 sleep，一旦探测到域名立即继续
    local domain_found=0
    for ((try_idx=1; try_idx<=15; try_idx++)); do
        if [ -f "${work_dir}/argo.log" ]; then
            argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1)
            if [ -n "$argodomain" ]; then
                domain_found=1
                break
            fi
        fi
        sleep 0.5
    done
    if [ $domain_found -eq 0 ]; then
        restart_argo >/dev/null 2>&1
        for ((try_idx=1; try_idx<=10; try_idx++)); do
            sleep 0.5
            argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" 2>/dev/null | tail -1)
            [ -n "$argodomain" ] && break
        done
    fi

    green "\nArgoDomain：${purple}$argodomain${re}\n"

    VMESS="{ \"v\": \"2\", \"ps\": \"${isp}\", \"add\": \"${CFIP}\", \"port\": \"${CFPORT}\", \"id\": \"${uuid}\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": \"false\"}"

    extra_lines=""
    if [ -f "${client_dir}" ]; then
        extra_lines=$(grep -vE '^(vless://|vmess://|hysteria2://|tuic://)' "${client_dir}" || true)
    fi

    cat > ${work_dir}/url.txt << EOF
vless://${uuid}@${server_ip}:${vless_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&type=tcp&headerType=none#${isp}

vmess://$(echo "$VMESS" | base64 -w0)

hysteria2://${uuid}@${server_ip}:${hy2_port}/?sni=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3&obfs=none#${isp}

tuic://${uuid}:${uuid}@${server_ip}:${tuic_port}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${isp}
EOF

    if [ -n "$extra_lines" ]; then
        echo "" >> "${work_dir}/url.txt"
        echo "$extra_lines" >> "${work_dir}/url.txt"
    fi

    echo ""
    while IFS= read -r line; do echo -e "${purple}$line"; done < ${work_dir}/url.txt
    base64 -w0 ${work_dir}/url.txt > ${work_dir}/sub.txt
    chmod 644 ${work_dir}/sub.txt
    yellow "\n温馨提醒:"
    yellow "如果节点里的ip是ipv6的，可在 修改节点配置 菜单切换ipv4后重新订阅节点\n"
    red "如果hysteria2或tuic不通，请尝试将节点里的 "跳过证书验证" 设置为 "true" 或切换内核\n"
    green "V2rayN,Shadowrocket,Nekobox,Loon,Karing,Sterisand订阅链接：${purple}http://${server_ip}:${nginx_port}/${password}${re}\n"
    $work_dir/qrencode "http://${server_ip}:${nginx_port}/${password}"
    yellow "\n=========================================================================================="
    green "\n\nClash,Mihomo系列订阅链接：${purple}https://sublink.eooce.com/clash?config=http://${server_ip}:${nginx_port}/${password}${re}\n"
    $work_dir/qrencode "https://sublink.eooce.com/clash?config=http://${server_ip}:${nginx_port}/${password}"
    yellow "\n=========================================================================================="
    green "\n\nSing-box订阅链接：${purple}https://sublink.eooce.com/singbox?config=http://${server_ip}:${nginx_port}/${password}${re}\n"
    $work_dir/qrencode "https://sublink.eooce.com/singbox?config=http://${server_ip}:${nginx_port}/${password}"
    yellow "\n=========================================================================================="
    green "\n\nSurge订阅链接：${purple}https://sublink.eooce.com/surge?config=http://${server_ip}:${nginx_port}/${password}${re}\n"
    $work_dir/qrencode "https://sublink.eooce.com/surge?config=http://${server_ip}:${nginx_port}/${password}"
    yellow "\n==========================================================================================\n"
}

# nginx订阅配置
add_nginx_conf() {
    if ! command_exists nginx; then
        red "nginx未安装,无法配置订阅服务"
        return 1
    else
        manage_service "nginx" "stop" > /dev/null 2>&1
        pkill nginx > /dev/null 2>&1
    fi

    mkdir -p /etc/nginx/conf.d
    [[ -f "/etc/nginx/conf.d/sing-box.conf" ]] && cp /etc/nginx/conf.d/sing-box.conf /etc/nginx/conf.d/sing-box.conf.bak.sb

    cat > /etc/nginx/conf.d/sing-box.conf << EOF
server {
    listen $nginx_port;
    listen [::]:$nginx_port;
    server_name _;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location = /$password {
        alias /etc/sing-box/sub.txt;
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }

    location / { return 404; }

    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

    if [ -f "/etc/nginx/nginx.conf" ]; then
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.sb > /dev/null 2>&1
        sed -i -e '15{/include \/etc\/nginx\/modules\/\*\.conf/d;}' \
               -e '18{/include \/etc\/nginx\/conf\.d\/\*\.conf/d;}' /etc/nginx/nginx.conf > /dev/null 2>&1
        if ! grep -q "include.*conf.d" /etc/nginx/nginx.conf; then
            http_end_line=$(grep -n "^}" /etc/nginx/nginx.conf | tail -1 | cut -d: -f1)
            [ -n "$http_end_line" ] && sed -i "${http_end_line}i \    include /etc/nginx/conf.d/*.conf;" /etc/nginx/nginx.conf > /dev/null 2>&1
        fi
    else
        cat > /etc/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events { worker_connections 1024; }

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    include /etc/nginx/conf.d/*.conf;
}
EOF
    fi

    if nginx -t > /dev/null 2>&1; then
        nginx -s reload > /dev/null 2>&1 || start_nginx > /dev/null 2>&1
        green "nginx订阅配置已加载"
    else
        yellow "nginx配置检测失败，尝试重启..."
        restart_nginx > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            [[ -f "/etc/nginx/nginx.conf.bak.sb" ]] && cp "/etc/nginx/nginx.conf.bak.sb" /etc/nginx/nginx.conf > /dev/null 2>&1
            restart_nginx > /dev/null 2>&1
        fi
    fi
}

# 从已安装配置中获取UUID
get_current_uuid() {
    local inbounds_file="${conf_dir}/inbounds.json"
    if [ -f "$inbounds_file" ]; then
        local uuid
        uuid=$(jq -r '.inbounds[] | select(.type == "vless") | .users[0].uuid // empty' "$inbounds_file" 2>/dev/null | head -1)
        [ -z "$uuid" ] && uuid=$(jq -r '.inbounds[] | select(.type == "vmess") | .users[0].uuid // empty' "$inbounds_file" 2>/dev/null | head -1)
        [ -z "$uuid" ] && uuid=$(jq -r '.inbounds[] | select(.type == "hysteria2") | .users[0].password // empty' "$inbounds_file" 2>/dev/null | head -1)
        echo "$uuid"
    fi
}

# 通用服务管理函数
manage_service() {
    local service_name="$1"
    local action="$2"

    if [ -z "$service_name" ] || [ -z "$action" ]; then
        red "缺少服务名或操作参数\n"; return 1
    fi

    local status=$(check_service "$service_name" 2>/dev/null)

    case "$action" in
        "start")
            [ "$status" == "running" ] && { yellow "${service_name} 正在运行\n"; return 0; }
            [ "$status" == "not installed" ] && { yellow "${service_name} 尚未安装!\n"; return 1; }
            yellow "正在启动 ${service_name} 服务\n"
            if command_exists rc-service; then rc-service "$service_name" start
            elif command_exists systemctl; then systemctl daemon-reload && systemctl start "$service_name"; fi
            [ $? -eq 0 ] && green "${service_name} 服务已成功启动\n" || red "${service_name} 服务启动失败\n"
            ;;
        "stop")
            [ "$status" == "not installed" ] && { yellow "${service_name} 尚未安装！\n"; return 2; }
            [ "$status" == "not running" ]   && { yellow "${service_name} 未运行\n"; return 1; }
            yellow "正在停止 ${service_name} 服务\n"
            if command_exists rc-service; then rc-service "$service_name" stop
            elif command_exists systemctl; then systemctl stop "$service_name"; fi
            [ $? -eq 0 ] && green "${service_name} 服务已成功停止\n" || red "${service_name} 服务停止失败\n"
            ;;
        "restart")
            [ "$status" == "not installed" ] && { yellow "${service_name} 尚未安装！\n"; return 1; }
            yellow "正在重启 ${service_name} 服务\n"
            if command_exists rc-service; then rc-service "$service_name" restart
            elif command_exists systemctl; then systemctl daemon-reload && systemctl restart "$service_name"; fi
            [ $? -eq 0 ] && green "${service_name} 服务已成功重启\n" || red "${service_name} 服务重启失败\n"
            ;;
        *)
            red "无效的操作: $action\n"; return 1 ;;
    esac
}

start_singbox()  { manage_service "sing-box" "start"; }
stop_singbox()   { manage_service "sing-box" "stop"; }
restart_singbox(){ manage_service "sing-box" "restart"; }
start_argo()     { manage_service "argo" "start"; }
stop_argo()      { manage_service "argo" "stop"; }
restart_argo()   { manage_service "argo" "restart"; }
start_nginx()    { manage_service "nginx" "start"; }
restart_nginx()  { manage_service "nginx" "restart"; }

# 卸载 sing-box（交互式）
uninstall_singbox() {
    reading "确定要卸载 sing-box 吗? (y/n): " choice
    case "${choice}" in
        y|Y)
            yellow "正在卸载 sing-box"
            if command_exists rc-service; then
                rc-service sing-box stop; rc-service argo stop
                rm -f /etc/init.d/sing-box /etc/init.d/argo
                rc-update del sing-box default; rc-update del argo default
            else
                systemctl stop "${server_name}"; systemctl stop argo
                systemctl disable "${server_name}"; systemctl disable argo
                systemctl daemon-reload || true
            fi
            rm -rf "${work_dir}" || true
            rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
            rm -f /etc/nginx/conf.d/sing-box.conf
            rm -f /etc/cron.d/sing-box-rotate >/dev/null 2>&1 || true
            if command_exists crontab; then
                crontab -l 2>/dev/null | grep -v "sing-box.*-rotate" | crontab - 2>/dev/null || true
            fi

            reading "\n是否卸载 Nginx？${green}(卸载请输入 ${yellow}y${re} ${green}回车将跳过卸载Nginx) (y/n): ${re}" choice
            case "${choice}" in
                y|Y) manage_packages uninstall nginx ;;
                *)   yellow "取消卸载Nginx\n\n" ;;
            esac
            green "\nsing-box 卸载成功\n\n" && exit 0
            ;;
        *) purple "已取消卸载操作\n\n" ;;
    esac
}

# 创建快捷指令
# 同步自身脚本并配置全局 sb 快捷指令
init_shortcut_and_self() {
    mkdir -p "${work_dir}" 2>/dev/null || true
    local cur_script="${BASH_SOURCE[0]:-$0}"

    # 1. 若当前运行的是实体脚本文件，自动同步备份到 /etc/sing-box/sing-box.sh
    if [ -f "$cur_script" ] && [[ "$cur_script" != /dev/fd/* ]]; then
        if [ "$cur_script" != "${work_dir}/sing-box.sh" ]; then
            cp -f "$cur_script" "${work_dir}/sing-box.sh" 2>/dev/null || true
            chmod +x "${work_dir}/sing-box.sh" 2>/dev/null || true
        fi
    fi

    # 2. 若目标脚本不存在或为空(如通过管道直接运行)，则自动从仓库拉取最新版落地保存
    if [ ! -s "${work_dir}/sing-box.sh" ]; then
        curl -sLo "${work_dir}/sing-box.sh" "https://raw.githubusercontent.com/Simengers/Sing-box/main/s1.sh" 2>/dev/null || \
        curl -sLo "${work_dir}/sing-box.sh" "https://fastly.jsdelivr.net/gh/Simengers/Sing-box@main/s1.sh" 2>/dev/null || true
        chmod +x "${work_dir}/sing-box.sh" 2>/dev/null || true
    fi

    # 3. 彻底重写 sb.sh 与 /usr/bin/sb，确保绝不跳转回原作者旧脚本
    cat > "${work_dir}/sb.sh" << 'EOF'
#!/usr/bin/env bash
if [ -s "/etc/sing-box/sing-box.sh" ]; then
    exec /bin/bash /etc/sing-box/sing-box.sh "$@"
elif [ -s "/root/s1.sh" ]; then
    exec /bin/bash /root/s1.sh "$@"
elif [ -s "/root/sing-box.sh" ]; then
    exec /bin/bash /root/sing-box.sh "$@"
else
    echo "检测到管理脚本缺失，正在从仓库下载最新版本..."
    curl -sLo /etc/sing-box/sing-box.sh https://raw.githubusercontent.com/Simengers/Sing-box/main/s1.sh 2>/dev/null || \
    curl -sLo /etc/sing-box/sing-box.sh https://fastly.jsdelivr.net/gh/Simengers/Sing-box@main/s1.sh 2>/dev/null
    chmod +x /etc/sing-box/sing-box.sh 2>/dev/null
    if [ -s "/etc/sing-box/sing-box.sh" ]; then
        exec /bin/bash /etc/sing-box/sing-box.sh "$@"
    else
        echo "错误: 无法获取 /etc/sing-box/sing-box.sh，请检查网络！"
        exit 1
    fi
fi
EOF
    chmod +x "${work_dir}/sb.sh" 2>/dev/null || true
    ln -sf "${work_dir}/sb.sh" /usr/bin/sb 2>/dev/null || true
}

create_shortcut() {
    init_shortcut_and_self
    [ -s /usr/bin/sb ] && green "\n快捷指令 sb 创建/更新成功\n" || red "\n快捷指令创建失败\n"
}

# 适配alpine
change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

# 非交互静默安装（-i 参数）
auto_install() {
    check_singbox &>/dev/null
    if [ $? -eq 0 ]; then
        yellow "sing-box 已经安装，跳过安装流程。"
        exit 0
    fi

    green "开始无交互式安装 sing-box..."
    manage_packages install nginx jq tar openssl lsof coreutils
    install_singbox

    if command_exists systemctl; then
        main_systemd_services
    elif command_exists rc-update; then
        alpine_openrc_services
        change_hosts
        rc-service sing-box restart
        rc-service argo restart
    else
        red "不支持的 init 系统，安装中止。"
        exit 1
    fi

    sleep 5
    get_info
    add_nginx_conf
    init_multi_user
    setup_cron_job "enable" 4 0 >/dev/null 2>&1 || true
    update_nginx_sub_conf >/dev/null 2>&1 || true
    create_shortcut
    green "\nsing-box 安装完成 (已自动初始化多用户支持及每日04:00端口轮换)\n"
}

# 无交互静默卸载（-u 参数），含 nginx
auto_uninstall() {
    green "开始无交互式卸载sing-box..."

    if command_exists rc-service; then
        rc-service sing-box stop  > /dev/null 2>&1
        rc-service argo stop      > /dev/null 2>&1
        rc-update del sing-box default > /dev/null 2>&1
        rc-update del argo default     > /dev/null 2>&1
        rm -f /etc/init.d/sing-box /etc/init.d/argo
    elif command_exists systemctl; then
        systemctl stop    sing-box > /dev/null 2>&1
        systemctl stop    argo     > /dev/null 2>&1
        systemctl disable sing-box > /dev/null 2>&1
        systemctl disable argo     > /dev/null 2>&1
        systemctl daemon-reload    > /dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service \
              /etc/systemd/system/argo.service
    fi

    rm -rf "${work_dir}"
    rm -f /usr/bin/sb

    if command_exists nginx; then
        if command_exists rc-service; then
            rc-service nginx stop   > /dev/null 2>&1
            rc-update del nginx default > /dev/null 2>&1
        elif command_exists systemctl; then
            systemctl stop    nginx > /dev/null 2>&1
            systemctl disable nginx > /dev/null 2>&1
        fi
        rm -f /etc/nginx/conf.d/sing-box.conf
        rm -f /etc/cron.d/sing-box-rotate >/dev/null 2>&1 || true
        if command_exists crontab; then
            crontab -l 2>/dev/null | grep -v "sing-box.*-rotate" | crontab - 2>/dev/null || true
        fi
        manage_packages uninstall nginx
        [ -f /etc/nginx/nginx.conf.bak.sb ] && \
            mv /etc/nginx/nginx.conf.bak.sb /etc/nginx/nginx.conf > /dev/null 2>&1
    else
        yellow "nginx 未安装，跳过卸载 nginx。"
    fi

    green "\nsing-box 及 nginx 已完全卸载!\n"
}

# 变更配置
change_config() {
    local singbox_status=$(check_singbox 2>/dev/null)
    local singbox_installed=$?

    if [ $singbox_installed -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; menu; return
    fi

    clear; echo ""
    green "=== 修改节点配置 ===\n"
    green "sing-box当前状态: $singbox_status\n"
    green "1. 修改端口"
    skyblue "------------"
    green "2. 修改UUID"
    skyblue "------------"
    green "3. 修改Reality伪装域名"
    skyblue "------------"
    green "4. 添加hysteria2端口跳跃"
    skyblue "------------"
    green "5. 删除hysteria2端口跳跃"
    skyblue "------------"
    green "6. 修改vmess-argo优选域名"
    skyblue "------------"
    green "7. 修改节点ip为ipv4"
    skyblue "------------"
    green "8. 修改节点ip为ipv6"
    skyblue "------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)
            echo ""
            green "1. 修改vless-reality端口"
            skyblue "------------"
            green "2. 修改hysteria2端口"
            skyblue "------------"
            green "3. 修改tuic端口"
            skyblue "------------"
            green "4. 修改vmess-argo端口"
            skyblue "------------"
            purple "0. 返回上一级菜单"
            skyblue "------------"
            reading "请输入选择: " choice
            local inbounds_file="${conf_dir}/inbounds.json"
            case "${choice}" in
                1)
                    reading "\n请输入vless-reality端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    jq --arg port "$new_port" \
                       '(.inbounds[] | select(.type == "vless").listen_port) = ($port | tonumber)' \
                       "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
                    restart_singbox
                    allow_port $new_port/tcp > /dev/null 2>&1
                    sed -i 's/\(vless:\/\/[^@]*@[^:]*:\)[0-9]\{1,\}/\1'"$new_port"'/' $client_dir
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nvless-reality端口已修改成：${purple}$new_port${re}\n"
                    ;;
                2)
                    reading "\n请输入hysteria2端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    jq --arg port "$new_port" \
                       '(.inbounds[] | select(.type == "hysteria2").listen_port) = ($port | tonumber)' \
                       "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
                    restart_singbox
                    allow_port $new_port/udp > /dev/null 2>&1
                    sed -i 's/\(hysteria2:\/\/[^@]*@[^:]*:\)[0-9]\{1,\}/\1'"$new_port"'/' $client_dir
                    base64 -w0 $client_dir > /etc/sing-box/sub.txt
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nhysteria2端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                3)
                    reading "\n请输入tuic端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    jq --arg port "$new_port" \
                       '(.inbounds[] | select(.type == "tuic").listen_port) = ($port | tonumber)' \
                       "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
                    restart_singbox
                    allow_port $new_port/udp > /dev/null 2>&1
                    sed -i 's/\(tuic:\/\/[^@]*@[^:]*:\)[0-9]\{1,\}/\1'"$new_port"'/' $client_dir
                    base64 -w0 $client_dir > /etc/sing-box/sub.txt
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\ntuic端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                4)
                    reading "\n请输入vmess-argo端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    jq --arg port "$new_port" \
                       '(.inbounds[] | select(.type == "vmess").listen_port) = ($port | tonumber)' \
                       "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
                    allow_port $new_port/tcp > /dev/null 2>&1
                    if command_exists rc-service; then
                        grep -q "localhost:" /etc/init.d/argo && \
                            sed -i 's/localhost:[0-9]\{1,\}/localhost:'"$new_port"'/' /etc/init.d/argo && \
                            get_quick_tunnel && change_argo_domain
                    else
                        grep -q "localhost:" /etc/systemd/system/argo.service && \
                            sed -i 's/localhost:[0-9]\{1,\}/localhost:'"$new_port"'/' /etc/systemd/system/argo.service && \
                            get_quick_tunnel && change_argo_domain
                    fi
                    restart_singbox
                    green "\nvmess-argo端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                0) change_config ;;
                *) red "无效的选项，请输入 1 到 4" ;;
            esac
            ;;
        2)
            reading "\n请输入新的UUID(直接回车随机生成UUID): " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            jq --arg uuid "$new_uuid" \
               '(.inbounds[] | select(.users != null) | .users[] | select(.uuid != null).uuid) = $uuid |
                (.inbounds[] | select(.users != null) | .users[] | select(.password != null).password) = $uuid' \
               "${conf_dir}/inbounds.json" > "${conf_dir}/inbounds.json.tmp" && mv "${conf_dir}/inbounds.json.tmp" "${conf_dir}/inbounds.json"
            restart_singbox
            sed -i -E 's/(vless:\/\/|hysteria2:\/\/|anytls:\/\/)[^@]*(@.*)/\1'"$new_uuid"'\2/' $client_dir
            sed -i -E "s#tuic://[0-9a-f-]{36}:[0-9a-f-]{36}@#tuic://$new_uuid:$new_uuid@#g" $client_dir
            isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' | \
                awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | sed 's/ /_/g' || echo "$hostname")
            argodomain=$(grep -oE 'https://[[:alnum:]+\.-]+\.trycloudflare\.com' "${work_dir}/argo.log" | sed 's@https://@@')
            VMESS="{ \"v\": \"2\", \"ps\": \"${isp}\", \"add\": \"${CFIP}\", \"port\": \"443\", \"id\": \"${new_uuid}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"\", \"allowInsecure\": \"false\"}"
            encoded_vmess=$(echo "$VMESS" | base64 -w0)
            sed -i -E '/vmess:\/\//{s@vmess://.*@vmess://'"$encoded_vmess"'@}' $client_dir
            base64 -w0 $client_dir > /etc/sing-box/sub.txt
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nUUID已修改为：${purple}${new_uuid}${re}\n"
            ;;
        3)
            clear
            green "\n1. www.joom.com\n\n2. www.stengg.com\n\n3. www.wedgehr.com\n\n4. www.cerebrium.ai\n\n5. www.nazhumi.com\n"
            reading "\n请输入新的Reality伪装域名(可自定义输入,回车留空将使用默认1): " new_sni
            case "$new_sni" in
                ""|"1") new_sni="www.joom.com" ;;
                "2") new_sni="www.stengg.com" ;;
                "3") new_sni="www.wedgehr.com" ;;
                "4") new_sni="www.cerebrium.ai" ;;
                "5") new_sni="www.nazhumi.com" ;;
            esac
            jq --arg sni "$new_sni" \
               '(.inbounds[] | select(.type == "vless") | .tls.server_name) = $sni |
                (.inbounds[] | select(.type == "vless") | .tls.reality.handshake.server) = $sni' \
               "${conf_dir}/inbounds.json" > "${conf_dir}/inbounds.json.tmp" && mv "${conf_dir}/inbounds.json.tmp" "${conf_dir}/inbounds.json"
            restart_singbox
            sed -i "s/\(vless:\/\/[^\?]*\?\([^\&]*\&\)*sni=\)[^&]*/\1$new_sni/" $client_dir
            base64 -w0 $client_dir > /etc/sing-box/sub.txt
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nReality sni已修改为：${purple}${new_sni}${re}\n"
            ;;
        4)
            purple "端口跳跃需确保跳跃区间的端口没有被占用\n"
            reading "请输入跳跃起始端口 (回车跳过将使用随机端口): " min_port
            [ -z "$min_port" ] && min_port=$(shuf -i 50000-65000 -n 1)
            yellow "你的起始端口为：$min_port"
            reading "\n请输入跳跃结束端口 (需大于起始端口): " max_port
            [ -z "$max_port" ] && max_port=$(($min_port + 100))
            yellow "你的结束端口为：$max_port\n"
            listen_port=$(jq -r '.inbounds[] | select(.type == "hysteria2").listen_port' "${conf_dir}/inbounds.json")
            iptables -t nat -A PREROUTING -p udp --dport $min_port:$max_port -j DNAT --to-destination :$listen_port > /dev/null
            command -v ip6tables &> /dev/null && ip6tables -t nat -A PREROUTING -p udp --dport $min_port:$max_port -j DNAT --to-destination :$listen_port > /dev/null
            if command_exists rc-service 2>/dev/null; then
                iptables-save > /etc/iptables/rules.v4
                command -v ip6tables &> /dev/null && ip6tables-save > /etc/iptables/rules.v6
                cat << 'IEOF' > /etc/init.d/iptables
#!/sbin/openrc-run
depend() { need net; }
start() {
    [ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4
    command -v ip6tables &> /dev/null && [ -f /etc/iptables/rules.v6 ] && ip6tables-restore < /etc/iptables/rules.v6
}
IEOF
                chmod +x /etc/init.d/iptables && rc-update add iptables default && /etc/init.d/iptables start
            elif [ -f /etc/debian_version ]; then
                DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent > /dev/null 2>&1 && netfilter-persistent save > /dev/null 2>&1
                systemctl enable netfilter-persistent > /dev/null 2>&1 && systemctl start netfilter-persistent > /dev/null 2>&1
            elif [ -f /etc/redhat-release ]; then
                manage_packages install iptables-services > /dev/null 2>&1 && service iptables save > /dev/null 2>&1
                systemctl enable iptables > /dev/null 2>&1 && systemctl start iptables > /dev/null 2>&1
                command -v ip6tables &> /dev/null && service ip6tables save > /dev/null 2>&1
                systemctl enable ip6tables > /dev/null 2>&1 && systemctl start ip6tables > /dev/null 2>&1
            fi
            restart_singbox
            ip=$(get_realip)
            fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')
            uuid=$(sed -n 's/.*hysteria2:\/\/\([^@]*\)@.*/\1/p' $client_dir)
            line_number=$(grep -n 'hysteria2://' $client_dir | cut -d':' -f1)
            isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' | \
                awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | sed 's/ /_/g' || echo "$hostname")
            sed -i.bak "/hysteria2:/d" $client_dir
            sed -i "${line_number}i hysteria2://$uuid@$ip:$listen_port?peer=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3&obfs=none&mport=$listen_port,$min_port-$max_port#$isp" $client_dir
            base64 -w0 $client_dir > /etc/sing-box/sub.txt
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nhysteria2端口跳跃已开启：${purple}$min_port-$max_port${re}\n"
            ;;
        5)
            iptables -t nat -F PREROUTING > /dev/null 2>&1
            command -v ip6tables &> /dev/null && ip6tables -t nat -F PREROUTING > /dev/null 2>&1
            if command_exists rc-service 2>/dev/null; then
                rc-update del iptables default && rm -rf /etc/init.d/iptables
            elif [ -f /etc/debian_version ]; then
                netfilter-persistent save > /dev/null 2>&1
            elif [ -f /etc/redhat-release ]; then
                service iptables save > /dev/null 2>&1
                command -v ip6tables &> /dev/null && service ip6tables save > /dev/null 2>&1
            fi
            sed -i '/hysteria2/s/&mport=[^#&]*//g' /etc/sing-box/url.txt
            base64 -w0 $client_dir > /etc/sing-box/sub.txt
            green "\n端口跳跃已删除\n"
            ;;
        6) change_cfip ;;
        7)  
            local new_ipv4
            [ -f "$client_dir" ] || {
                red "\n错误: $client_dir 不存在\n"
                return 1
            }
            rm -f "${work_dir}/ip.cache" 2>/dev/null || true
            new_ipv4=$(curl -4 -sm 2 ip.sb)
            if ! printf '%s' "$new_ipv4" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
                red "\n错误: 获取 IPv4 失败: $new_ipv4\n"
                return 1
            fi
            if curl -4 -sm 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
                red "\n当前服务器的ipv4: $new_ipv4 为warp ip,无法作为直连节点使用\n"
                return 1
            fi
            if grep -Eq '^(vless|hysteria2|tuic|anytls|socks|ss)://[^@]+@\[[0-9a-fA-F:]+\]' "$client_dir"; then
                sed -i -E "/^(vless|hysteria2|tuic|anytls|socks|ss):\/\// s#@\[[0-9a-fA-F:]+\]#@${new_ipv4}#g" "$client_dir"
                green "\n已将 IPv6 修改为 IPv4: $new_ipv4 可复制以下节点或更新订阅\n"
                check_nodes
            else
                yellow "\n当前已是ipv4, 无需切换\n" && return 0
            fi
            base64 -w 0 "$client_dir" > "${work_dir}/sub.txt" 2>/dev/null || base64 "$client_dir" | tr -d '\n' > "${work_dir}/sub.txt"
           ;;
        8) 
            local new_ipv6
            [ -f "$client_dir" ] || {
                red "\n错误: $client_dir 不存在\n"
                return 1
            }
            rm -f "${work_dir}/ip.cache" 2>/dev/null || true
            new_ipv6=$(curl -6 -sm 3 ip.sb)
            if ! printf '%s' "$new_ipv6" | grep -Eq '^[0-9a-fA-F:]+$'; then
                red "\n当前服务器没有可用的ipv6\n"
                return 1
            fi
            if curl -6 -sm 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
                red "\n当前服务器的ipv6 $new_ipv6 为warp ip,无法作为直连节点使用\n"
                return 1
            fi
            if grep -Eq '^(vless|hysteria2|tuic|anytls|socks|ss)://[^@]+@([0-9]{1,3}\.){3}[0-9]{1,3}' "$client_dir"; then
                sed -i -E "/^(vless|hysteria2|tuic|anytls|socks|ss):\/\// s#@(([0-9]{1,3}\.){3}[0-9]{1,3})#@[${new_ipv6}]#g" "$client_dir"
                green "\n已将 IPv4 修改为 IPv6: [${new_ipv6}] 可复制以下节点或更新订阅\n"
                check_nodes
            else
                yellow "\n当前已是ipv6, 无需切换\n" && return 0
            fi
            base64 -w 0 "$client_dir" > "${work_dir}/sub.txt" 2>/dev/null || base64 "$client_dir" | tr -d '\n' > "${work_dir}/sub.txt"
           ;;
        0) menu ;;
        *) red "无效的选项！\n" ;;
    esac
}

disable_open_sub() {
    local singbox_installed=$?
    check_singbox &>/dev/null; singbox_installed=$?
    if [ $singbox_installed -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; menu; return
    fi

    clear; echo ""
    green "=== 管理节点订阅 ===\n"
    skyblue "------------"
    green "1. 关闭节点订阅"
    skyblue "------------"
    green "2. 开启节点订阅"
    skyblue "------------"
    green "3. 更换订阅端口"
    skyblue "------------"
    green "4. 重启订阅服务"
    skyblue "------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)
            if command -v nginx &>/dev/null; then
                if command_exists rc-service 2>/dev/null; then
                    rc-service nginx status | grep -q "started" && rc-service nginx stop || red "nginx not running"
                else
                    [ "$(systemctl is-active nginx)" = "active" ] && systemctl stop nginx || red "nginx not running"
                fi
            else
                yellow "Nginx is not installed"
            fi
            green "\n已关闭节点订阅\n"
            ;;
        2)
            server_ip=$(get_realip)
            password=$(tr -dc A-Za-z < /dev/urandom | head -c 32)
            sed -i "s|\(location = /\)[^ ]*|\1$password|" /etc/nginx/conf.d/sing-box.conf
            sub_port=$(grep -E 'listen [0-9]+;' "/etc/nginx/conf.d/sing-box.conf" | awk '{print $2}' | sed 's/;//' | head -1)
            start_nginx
            local link
            [ "$sub_port" -eq 80 ] 2>/dev/null && link="http://$server_ip/$password" || link="http://$server_ip:$sub_port/$password"
            green "\n已开启节点订阅\n新的节点订阅链接：$link\n"
            ;;
        3)
            reading "请输入新的订阅端口(1-65535,直接回车随机生成):" sub_port
            [ -z "$sub_port" ] && sub_port=$(shuf -i 2000-65000 -n 1)
            until [[ -z $(lsof -iTCP:"$sub_port" -sTCP:LISTEN -t) ]]; do
                echo -e "${red}端口 $sub_port 已被占用${re}"
                reading "请输入新的订阅端口(1-65535):" sub_port
                [[ -z $sub_port ]] && sub_port=$(shuf -i 2000-65000 -n 1)
            done
            green "新的订阅端口为：${purple}${sub_port}${re}"
            [ -f "/etc/nginx/conf.d/sing-box.conf" ] && \
                cp "/etc/nginx/conf.d/sing-box.conf" "/etc/nginx/conf.d/sing-box.conf.bak.$(date +%Y%m%d)"
            sed -i 's/listen [0-9]\+;/listen '$sub_port';/g' "/etc/nginx/conf.d/sing-box.conf"
            sed -i 's/listen \[::\]:[0-9]\+;/listen [::]:'$sub_port';/g' "/etc/nginx/conf.d/sing-box.conf"
            path=$(sed -n 's|.*location = /\([^ ]*\).*|\1|p' "/etc/nginx/conf.d/sing-box.conf")
            server_ip=$(get_realip)
            allow_port $sub_port/tcp > /dev/null 2>&1
            update_nginx_sub_conf >/dev/null 2>&1 || true
            if nginx -t > /dev/null 2>&1; then
                nginx -s reload > /dev/null 2>&1 || restart_nginx
                green "\n订阅端口更换成功\n新的订阅链接为：${purple}http://${server_ip}:${sub_port}/${path}${re}\n"
            else
                red "nginx配置测试失败，正在恢复..."
                latest_backup=$(ls -t /etc/nginx/conf.d/sing-box.conf.bak.* 2>/dev/null | head -1)
                [ -n "$latest_backup" ] && cp "$latest_backup" "/etc/nginx/conf.d/sing-box.conf"
                return 1
            fi
            ;;
        4) restart_nginx ;;
        0) menu ;;
        *) red "无效的选项！" ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回...\033[0m\n'
}

# singbox 管理
manage_singbox() {
    local singbox_status=$(check_singbox 2>/dev/null)
    clear; echo ""
    green "=== sing-box 管理 ===\n"
    green "sing-box当前状态: $singbox_status\n"
    green "1. 启动sing-box服务"
    skyblue "-------------------"
    green "2. 停止sing-box服务"
    skyblue "-------------------"
    green "3. 重启sing-box服务"
    skyblue "-------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1) start_singbox ;;
        2) stop_singbox ;;
        3) restart_singbox ;;
        0) menu ;;
        *) red "无效的选项！" && sleep 1 && manage_singbox ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回...\033[0m\n'
}

# Argo 管理
manage_argo() {
    local argo_status=$(check_argo 2>/dev/null)
    clear; echo ""
    green "=== Argo 隧道管理 ===\n"
    green "Argo当前状态: $argo_status\n"
    green "1. 启动Argo服务"
    skyblue "------------"
    green "2. 停止Argo服务"
    skyblue "------------"
    green "3. 重启Argo服务"
    skyblue "------------"
    green "4. 添加Argo固定隧道"
    skyblue "----------------"
    green "5. 切换回Argo临时隧道"
    skyblue "------------------"
    green "6. 重新获取Argo临时域名"
    skyblue "-------------------"
    purple "0. 返回主菜单"
    skyblue "-----------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1) start_argo ;;
        2) stop_argo ;;
        3)
            clear
            if command_exists rc-service 2>/dev/null; then
                grep -Fq -- '--url http://localhost' /etc/init.d/argo && get_quick_tunnel && change_argo_domain || \
                    { green "\n当前使用固定隧道,无需获取临时域名"; sleep 2; menu; }
            else
                grep -q 'ExecStart=.*--url http://localhost' /etc/systemd/system/argo.service && get_quick_tunnel && change_argo_domain || \
                    { green "\n当前使用固定隧道,无需获取临时域名"; sleep 2; menu; }
            fi
            ;;
        4)
            clear
            yellow "\n固定隧道可为json或token，固定隧道端口为8001, 使用token请在cloudflare里设置一致\njson获取地址：${purple}https://fscarmen.cloudflare.now.cc${re}\n"
            reading "\n请输入你的argo域名: " argo_domain
            ArgoDomain=$argo_domain
            reading "\n请输入你的argo密钥(token或json): " argo_auth
            if [[ $argo_auth =~ TunnelSecret ]]; then
                echo $argo_auth > ${work_dir}/tunnel.json
                cat > ${work_dir}/tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< "$argo_auth")
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: $ArgoDomain
    service: http://localhost:8001
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
                if command_exists rc-service 2>/dev/null; then
                    sed -i '/^command_args=/c\command_args="-c '\''/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run 2>&1'\''"' /etc/init.d/argo
                else
                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run 2>&1"' /etc/systemd/system/argo.service
                fi
                restart_argo; sleep 1; change_argo_domain
            elif [[ $argo_auth =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
                if command_exists rc-service 2>/dev/null; then
                    sed -i "/^command_args=/c\command_args=\"-c '/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $argo_auth 2>&1'\"" /etc/init.d/argo
                else
                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token '$argo_auth' 2>&1"' /etc/systemd/system/argo.service
                fi
                restart_argo; sleep 1; change_argo_domain
            else
                yellow "输入不匹配，请重新输入"; manage_argo
            fi
            ;;
        5)
            clear
            if command_exists rc-service 2>/dev/null; then alpine_openrc_services
            else main_systemd_services; fi
            get_quick_tunnel; change_argo_domain
            ;;
        6)
            if command_exists rc-service 2>/dev/null; then
                grep -Fq -- '--url http://localhost' "/etc/init.d/argo" && get_quick_tunnel && change_argo_domain || \
                    { yellow "当前使用固定隧道，无法获取临时隧道"; sleep 2; menu; }
            else
                grep -q 'ExecStart=.*--url http://localhost' "/etc/systemd/system/argo.service" && get_quick_tunnel && change_argo_domain || \
                    { yellow "当前使用固定隧道，无法获取临时隧道"; sleep 2; menu; }
            fi
            ;;
        0) menu ;;
        *) red "无效的选项！" ;;
    esac
}

# 获取argo临时隧道
get_quick_tunnel() {
    restart_argo
    yellow "获取临时argo域名中，请稍等...\n"
    sleep 3
    if [ -f /etc/sing-box/argo.log ]; then
        for i in {1..5}; do
            purple "第 $i 次尝试获取ArgoDoamin中..."
            get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "/etc/sing-box/argo.log")
            [ -n "$get_argodomain" ] && break
            sleep 2
        done
    else
        restart_argo; sleep 6
        get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "/etc/sing-box/argo.log")
    fi
    green "ArgoDomain：${purple}$get_argodomain${re}\n"
    ArgoDomain=$get_argodomain
}

# 更新Argo域名到订阅
change_argo_domain() {
    content=$(cat "$client_dir")
    vmess_url=$(grep -o 'vmess://[^ ]*' "$client_dir")
    vmess_prefix="vmess://"
    encoded_vmess="${vmess_url#"$vmess_prefix"}"
    decoded_vmess=$(echo "$encoded_vmess" | base64 --decode)
    updated_vmess=$(echo "$decoded_vmess" | jq --arg new_domain "$ArgoDomain" '.host = $new_domain | .sni = $new_domain')
    encoded_updated_vmess=$(echo "$updated_vmess" | base64 | tr -d '\n')
    new_vmess_url="${vmess_prefix}${encoded_updated_vmess}"
    new_content=$(echo "$content" | sed "s|$vmess_url|$new_vmess_url|")
    echo "$new_content" > "$client_dir"
    base64 -w0 ${work_dir}/url.txt > ${work_dir}/sub.txt
    if [ -d "${users_dir}" ]; then
        for udir in "${users_dir}"/*; do
            [ -f "${udir}/url.txt" ] || continue
            local u_vmess=$(grep -o 'vmess://[^ ]*' "${udir}/url.txt" 2>/dev/null | head -1)
            if [ -n "$u_vmess" ]; then
                local u_dec=$(echo "${u_vmess#vmess://}" | base64 --decode 2>/dev/null)
                local u_upd=$(echo "$u_dec" | jq --arg new_domain "$ArgoDomain" '.host = $new_domain | .sni = $new_domain' 2>/dev/null)
                local u_enc=$(echo "$u_upd" | base64 | tr -d '\n')
                sed -i "s|$u_vmess|vmess://${u_enc}|" "${udir}/url.txt"
                base64 -w0 "${udir}/url.txt" > "${udir}/sub.txt" 2>/dev/null || base64 "${udir}/url.txt" | tr -d '\n' > "${udir}/sub.txt"
            fi
        done
    fi
    green "vmess节点已更新\n"
    purple "$new_vmess_url\n"
}

# 查看节点信息和订阅链接
check_nodes() {
    init_multi_user
    if [ ! -f "${work_dir}/url.txt" ] && [ ! -d "${users_dir}" ]; then
        red "节点信息文件不存在，请先安装 sing-box"; return 1
    fi

    # 多用户检测
    local user_list=()
    if [ -d "${users_dir}" ]; then
        for uconf in "${users_dir}"/*/user.conf; do
            [ -f "$uconf" ] || continue
            local un=$(grep '^USERNAME=' "$uconf" | cut -d'"' -f2)
            [ -n "$un" ] && user_list+=("$un")
        done
    fi

    if [ ${#user_list[@]} -gt 1 ]; then
        show_all_users_table
        green "当前存在多个用户，请选择要查看的用户节点:"
        for i in "${!user_list[@]}"; do
            echo -e "  ${green}$((i+1)). ${skyblue}${user_list[$i]}${re}"
        done
        echo -e "  ${green}a. ${purple}查看全部用户专属订阅汇总${re}"
        echo -e "  ${green}0. ${yellow}返回${re}"
        reading "
请输入序号或用户名 (直接回车默认1): " u_idx
        [ -z "$u_idx" ] && u_idx=1
        if [ "$u_idx" == "0" ]; then
            return 0
        elif [ "$u_idx" == "a" ] || [ "$u_idx" == "A" ]; then
            export_all_users_sub
            return 0
        elif [[ "$u_idx" =~ ^[0-9]+$ ]] && [ "$u_idx" -ge 1 ] && [ "$u_idx" -le "${#user_list[@]}" ]; then
            show_user_sub_info "${user_list[$((u_idx-1))]}"
            return 0
        elif [ -d "${users_dir}/${u_idx}" ]; then
            show_user_sub_info "$u_idx"
            return 0
        fi
    elif [ ${#user_list[@]} -eq 1 ]; then
        show_user_sub_info "${user_list[0]}"
        return 0
    fi

    server_ip=$(get_realip)
    local lujing sub_port base64_url

    if [ -f "/etc/nginx/conf.d/sing-box.conf" ]; then
        lujing=$(sed -n 's|.*location = /\([^ ]*\).*|\1|p' "/etc/nginx/conf.d/sing-box.conf")
        sub_port=$(sed -n 's/^\s*listen \([0-9]\+\);/\1/p' "/etc/nginx/conf.d/sing-box.conf" | head -1)
    fi
    base64_url="http://${server_ip}:${sub_port}/${lujing}"

    clear; echo ""
    green "=== 当前节点信息 ===\n"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo -e "${purple}${line}${re}\n"
    done < "${work_dir}/url.txt"

    yellow "\n温馨提醒: 如果hysteria2或tuic不通，请尝试将节点里的 "跳过证书验证" 设置为 "true" 或切换内核\n"
    green "\n=== 订阅链接 ===\n"

    green "V2rayN/Shadowrocket/Nekobox/Karing 订阅链接:\n${purple}${base64_url}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "${base64_url}"
    yellow "\n=========================================================================================="

    green "\nClash/Mihomo 订阅链接:\n${purple}https://sublink.eooce.com/clash?config=${base64_url}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "https://sublink.eooce.com/clash?config=${base64_url}"
    yellow "\n=========================================================================================="

    green "\nSing-box 订阅链接:\n${purple}https://sublink.eooce.com/singbox?config=${base64_url}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "https://sublink.eooce.com/singbox?config=${base64_url}"
    yellow "\n=========================================================================================="

    green "\nSurge 订阅链接:\n${purple}https://sublink.eooce.com/surge?config=${base64_url}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "https://sublink.eooce.com/surge?config=${base64_url}"
    yellow "\n==========================================================================================\n"
}

change_cfip() {
    clear
    yellow "修改vmess-argo优选域名\n"
    green "1: cf.090227.xyz  2: cf.877774.xyz  3: cf.877771.xyz  4: cdns.doon.eu.org  5: cf.zhetengsha.eu.org  6: time.is\n"
    reading "请输入你的优选域名或优选IP\n(请输入1至6选项,可输入域名:端口 或 IP:端口,直接回车默认使用1): " cfip_input

    case "$cfip_input" in
        ""|"1") cfip="cf.090227.xyz";          cfport="443" ;;
        "2")    cfip="cf.877774.xyz";           cfport="443" ;;
        "3")    cfip="cf.877771.xyz";           cfport="443" ;;
        "4")    cfip="cdns.doon.eu.org";        cfport="443" ;;
        "5")    cfip="cf.zhetengsha.eu.org";    cfport="443" ;;
        "6")    cfip="time.is";                 cfport="443" ;;
        *)
            if [[ "$cfip_input" =~ : ]]; then
                cfip=$(echo "$cfip_input" | cut -d':' -f1)
                cfport=$(echo "$cfip_input" | cut -d':' -f2)
            else
                cfip="$cfip_input"; cfport="443"
            fi
            ;;
    esac

    content=$(cat "$client_dir")
    vmess_url=$(grep -o 'vmess://[^ ]*' "$client_dir")
    encoded_part="${vmess_url#vmess://}"
    decoded_json=$(echo "$encoded_part" | base64 --decode 2>/dev/null)
    updated_json=$(echo "$decoded_json" | jq --arg cfip "$cfip" --argjson cfport "$cfport" '.add = $cfip | .port = $cfport')
    new_encoded_part=$(echo "$updated_json" | base64 -w0)
    new_vmess_url="vmess://$new_encoded_part"
    new_content=$(echo "$content" | sed "s|$vmess_url|$new_vmess_url|")
    echo "$new_content" > "$client_dir"
    base64 -w0 "${work_dir}/url.txt" > "${work_dir}/sub.txt"
    if [ -d "${users_dir}" ]; then
        for udir in "${users_dir}"/*; do
            [ -f "${udir}/url.txt" ] || continue
            local u_vmess=$(grep -o 'vmess://[^ ]*' "${udir}/url.txt" 2>/dev/null | head -1)
            if [ -n "$u_vmess" ]; then
                local u_dec=$(echo "${u_vmess#vmess://}" | base64 --decode 2>/dev/null)
                local u_upd=$(echo "$u_dec" | jq --arg cfip "$cfip" --argjson cfport "$cfport" '.add = $cfip | .port = $cfport' 2>/dev/null)
                local u_enc=$(echo "$u_upd" | base64 -w0 2>/dev/null || echo "$u_upd" | base64 | tr -d '\n')
                sed -i "s|$u_vmess|vmess://${u_enc}|" "${udir}/url.txt"
                base64 -w0 "${udir}/url.txt" > "${udir}/sub.txt" 2>/dev/null || base64 "${udir}/url.txt" | tr -d '\n' > "${udir}/sub.txt"
            fi
        done
    fi
    green "\nvmess节点优选域名已更新为：${purple}${cfip}:${cfport}${re}\n"
    purple "$new_vmess_url\n"
}

# WARP 分流管理
warp_manage() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; menu; return
    fi

    clear
    route_file="${conf_dir}/route.json"
    outbound_file="${conf_dir}/outbounds.json"

    echo ""
    green "=== WARP 分流管理 ===\n"
    green "当前已启用的分流规则集:"
    jq -r '.route.rules[] | select(.rule_set != null) | .rule_set[]?' "$route_file" 2>/dev/null | sort -u | while read tag; do
        echo -e " - ${skyblue}$tag${re}"
    done || echo "  无"
    green "\n已添加的socks/http代理出站:"
    jq -r '.outbounds[] | select(.tag != "direct") | " - \(.tag) [\(.type)]"' "$outbound_file" 2>/dev/null || echo "  无"

    echo ""
    green "1. 设置分流服务 (未添加socks/http直接设置则使用WARP)"
    skyblue "----------------------"
    red "2. 删除分流服务"
    skyblue "--------------"
    green "3. 添加 Socks5/HTTP 出站"
    skyblue "----------------------"
    red "4. 删除 Socks5/HTTP 出站"
    skyblue "----------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    purple "00. 退出脚本"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)  add_rule_menu ;;
        2)  delete_rule_menu ;;
        3)  add_socks5_proxy ;;
        4)  delete_socks5_proxy ;;
        0)  menu ;;
        00) exit 0 ;;
        *)  red "无效选项"; sleep 1; warp_manage ;;
    esac
}

add_rule_menu() {
    clear
    green "选择要分流的服务:\n"
    green "1.  OpenAI"
    green "2.  Claude"
    green "3.  Gemini"
    green "4.  Google"
    green "5.  Tiktok"
    green "6.  Twitter"
    green "7.  YouTube"
    green "8.  Netflix"
    green "9.  Telegram"
    skyblue "-----------------------------"
    green "10. 设置全局代理出站 (所有流量走指定代理)"
    green "11. 恢复服务器原IP出站 (所有流量走服务器ip)"
    skyblue "-----------------------------"
    purple "0.  返回上级菜单"
    skyblue "-----------------------------"
    reading "请输入选择: " add_choice
    case "$add_choice" in
        1)  rule_tag="openai"   ;;
        2)  rule_tag="claude"   ;;
        3)  rule_tag="gemini"   ;;
        4)  rule_tag="google"   ;;
        5)  rule_tag="tiktok"   ;;
        6)  rule_tag="twitter"  ;;
        7)  rule_tag="youtube"  ;;
        8)  rule_tag="netflix"  ;;
        9)  rule_tag="telegram" ;;
        10) set_global_outbound; return ;;
        11) restore_direct_outbound; return ;;
        0)  warp_manage; return ;;
        *)  red "无效选项"; sleep 1; add_rule_menu; return ;;
    esac

    if jq -e --arg tag "$rule_tag" \
        '.route.rules[] | select(.rule_set != null) | .rule_set[]? | select(. == $tag)' \
        "$route_file" > /dev/null 2>&1; then
        yellow "规则集 '${rule_tag}' 已启用。"; sleep 1; warp_manage; return
    fi

    jq 'if (.route.rules | length) == 1 and (.route.rules[0].rule_set | length) == 0
        then .route.rules = []
        else . end' \
        "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"

    local out_tags=($(jq -r '.outbounds[] | select(.tag != "direct") | .tag' "$outbound_file" 2>/dev/null))
    if [ ${#out_tags[@]} -eq 0 ]; then
        selected_out="wireguard-out"
        yellow "未找到其他出站，将自动使用 wireguard-out。"
    else
        echo ""
        green "请选择分流流量要走的出站:"
        for i in "${!out_tags[@]}"; do
            echo -e "  ${green}$((i+1)). ${skyblue}${out_tags[$i]}${re}"
        done
        reading "请输入编号: " out_choice
        if [[ ! "$out_choice" =~ ^[0-9]+$ ]] || \
           [ "$out_choice" -lt 1 ] || \
           [ "$out_choice" -gt "${#out_tags[@]}" ]; then
            red "无效选择"; sleep 1; warp_manage; return
        fi
        selected_out="${out_tags[$((out_choice-1))]}"
    fi

    jq --arg tag "$rule_tag" --arg out "$selected_out" '
        if (.route.rules | length) == 0 then
            .route.rules = [{"rule_set": [$tag], "outbound": $out}]
        else
            (first(.route.rules[] | select(.outbound == $out)) | .rule_set) as $existing
            | if $existing then
                .route.rules = [.route.rules[] | select(.outbound == $out).rule_set += [$tag]]
              else
                .route.rules += [{"rule_set": [$tag], "outbound": $out}]
              end
        end
    ' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"

    restart_singbox
    green "'${rule_tag}' 已分流至出站 '${selected_out}'"
    sleep 1; warp_manage
}

# 设置全局代理出站
set_global_outbound() {
    # 检查是否存在 socks5/http 代理出站（排除 direct 和 wireguard-out）
    local proxy_tags
    proxy_tags=($(jq -r '.outbounds[] | select(.tag != "direct" and .tag != "wireguard-out") | .tag' \
        "$outbound_file" 2>/dev/null))

    if [ ${#proxy_tags[@]} -eq 0 ]; then
        yellow "\n当前没有可用的 socks5/http 代理出站。"
        yellow "请先返回 → 设置分流服务 → 添加 Socks5/HTTP 出站，再设置全局代理。\n"
        sleep 3; add_rule_menu; return
    fi

    echo ""
    green "请选择全局代理出站:"
    for i in "${!proxy_tags[@]}"; do
        echo -e "  ${green}$((i+1)). ${skyblue}${proxy_tags[$i]}${re}"
    done
    echo ""
    reading "请输入编号: " out_choice
    if [[ ! "$out_choice" =~ ^[0-9]+$ ]] || \
       [ "$out_choice" -lt 1 ] || \
       [ "$out_choice" -gt "${#proxy_tags[@]}" ]; then
        red "无效选择"; sleep 1; add_rule_menu; return
    fi
    local selected_out="${proxy_tags[$((out_choice-1))]}"

    # 从 outbounds.json 中删除 direct 出站，防止流量绕过代理
    jq 'del(.outbounds[] | select(.tag == "direct"))' \
        "$outbound_file" > "${outbound_file}.tmp" && mv "${outbound_file}.tmp" "$outbound_file"
    rm -rf ${route_file} ${conf_dir}/endpoints.json
    restart_singbox
    green "\n已设置全局代理出站：${purple}${selected_out}${re}"
    yellow "所有流量将通过 ${selected_out} 转发，如需恢复请选择「恢复服务器原IP出站」\n"
    sleep 2; warp_manage
}

# 恢复服务器原IP出站（恢复默认 route.json）
restore_direct_outbound() {
    yellow "\n正在恢复默认路由配置...\n"

    # 恢复 outbounds.json 中的 direct 出站（不存在则插入到数组最前面）
    if ! jq -e '.outbounds[] | select(.tag == "direct")' "$outbound_file" > /dev/null 2>&1; then
        jq '.outbounds = [{"type": "direct", "tag": "direct"}] + .outbounds' \
            "$outbound_file" > "${outbound_file}.tmp" && mv "${outbound_file}.tmp" "$outbound_file"
    fi

    # 恢复默认 route.json
    cat > "${route_file}" << 'EOF'
{
  "route": {
    "rule_set": [
      {"tag":"gemini","type":"remote","format":"binary","url":"https://main.ssss.nyc.mn/gemini.srs","download_detour":"direct"},
      {"tag":"claude","type":"remote","format":"binary","url":"https://main.ssss.nyc.mn/claude.srs","download_detour":"direct"},
      {"tag":"openai","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/openai.srs","download_detour":"direct"},
      {"tag":"tiktok","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/tiktok.srs","download_detour":"direct"},
      {"tag":"twitter","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/twitter.srs","download_detour":"direct"},
      {"tag":"google","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/google.srs","download_detour":"direct"},
      {"tag":"telegram","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/telegram.srs","download_detour":"direct"},
      {"tag":"youtube","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/youtube.srs","download_detour":"direct"},
      {"tag":"netflix","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/netflix.srs","download_detour":"direct"}
    ],
    "rules": [{"rule_set": []}],
    "final": "direct"
  }
}
EOF

    # 恢复默认 endpoints.json
    cat > "${conf_dir}/endpoints.json" << EOF
{
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "wireguard-out",
      "mtu": 1280,
      "address": [
        "172.16.0.2/32",
        "2606:4700:110:8dfe:d141:69bb:6b80:925/128"
      ],
      "private_key": "YFYOAdbw1bKTHlNNi+aEjBM3BO7unuFC5rOkMRAz9XY=",
      "peers": [
        {
          "address": "engage.cloudflareclient.com",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "reserved": [78, 135, 76]
        }
      ]
    }
  ]
}
EOF
    restart_singbox
    green "\n已恢复服务器原IP出站，所有流量走 direct。\n"
    sleep 2; warp_manage
}

delete_rule_menu() {
    clear
    green "当前已启用的分流规则集:"
    jq -r '.route.rules[] | select(.rule_set != null) | .rule_set[]?' "$route_file" | nl -w2 -s'. '
    reading "\n输入要删除的规则名称或序号: " del_input
    if [[ "$del_input" =~ ^[0-9]+$ ]]; then
        tag=$(jq -r --arg idx "$del_input" '[.route.rules[] | select(.rule_set != null) | .rule_set[]] | .[(($idx | tonumber) - 1)]' "$route_file")
    else
        tag="$del_input"
    fi
    if [ -z "$tag" ] || [ "$tag" == "null" ]; then
        red "无效的选择"; sleep 1; warp_manage; return
    fi
    jq --arg tag "$tag" \
       'del(.route.rules[] | select(.rule_set != null) | .rule_set[] | select(. == $tag)) |
        .route.rules = [.route.rules[] | select(.rule_set != null and (.rule_set | length) > 0)]' \
       "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"
    restart_singbox
    green "规则集 '${tag}' 已禁用。"
    sleep 1; warp_manage
}

add_socks5_proxy() {
    clear
    reading "请输入代理URL (支持socks://,socks5://,http:// 支持v2rayN导出的节点链接): " proxy_url
    [ -z "$proxy_url" ] && { red "输入为空！"; sleep 1; return; }

    proto=$(echo "$proxy_url" | grep -oP '^[a-zA-Z0-9]+(?=://)')
    [[ ! "$proto" =~ ^(socks5|socks|http)$ ]] && { red "不支持的协议"; sleep 2; return; }
    case "$proto" in
        socks|socks5) outbound_type="socks" ;;
        http)         outbound_type="http" ;;
    esac

    after_proto="${proxy_url#*://}"
    if [[ "$after_proto" == *"#"* ]]; then
        tag_from_url="${after_proto##*#}"; after_proto="${after_proto%%#*}"
    else
        tag_from_url=""
    fi

    if [[ "$after_proto" == *"@"* ]]; then
        user_pass="${after_proto%%@*}"; host_port="${after_proto##*@}"
    else
        user_pass=""; host_port="$after_proto"
    fi

    user=""; password=""
    if [ -n "$user_pass" ]; then
        decoded=$(echo "$user_pass" | base64 -d 2>/dev/null)
        if [ -n "$decoded" ] && [[ "$decoded" != "$user_pass" ]] && [[ "$decoded" == *":"* ]]; then
            user="${decoded%%:*}"; password="${decoded#*:}"
        elif [[ "$user_pass" == *":"* ]]; then
            user="${user_pass%%:*}"; password="${user_pass#*:}"
        else
            user="$user_pass"
        fi
    fi

    server="${host_port%%:*}"; port="${host_port##*:}"
    [ -z "$server" ] || [ -z "$port" ] && { red "格式错误：缺少ip或端口"; sleep 2; return; }

    [[ "$proto" == "socks" || "$proto" == "socks5" ]] && check_proto="socks5" || check_proto="$proto"

    # 判断是否为本地地址，本地地址跳过外部 API 检测，直接用 curl 测试
    local is_local=false
    if [[ "$server" == "127.0.0.1" || "$server" == "::1" || "$server" == "localhost" ]]; then
        is_local=true
    fi

    local proxy_auth=""
    [ -n "$user" ] && [ -n "$password" ] && proxy_auth="${user}:${password}@" || \
        { [ -n "$user" ] && proxy_auth="${user}@"; }

    if [ "$is_local" = true ]; then
        # 本地代理：直接用 curl 通过代理访问外网测试连通性
        yellow "检测到本地代理 ${check_proto}://${server}:${port}，跳过外部API检测，正在用curl测试连通性..."
        local curl_proxy_url="${check_proto}://${proxy_auth}${server}:${port}"
        local test_result
        test_result=$(curl -s --max-time 8 --proxy "$curl_proxy_url" "https://api.ip.sb/ip" 2>/dev/null)
        if [ -z "$test_result" ]; then
            yellow "警告：通过本地代理访问外网失败，请确认代理服务正在运行。"
            reading "是否仍然添加此代理？(y/n): " force_add
            [[ ! "$force_add" =~ ^[yY]$ ]] && { yellow "已取消"; sleep 1; return; }
        else
            green "本地代理可用，出口IP: $test_result"
        fi
    else
        # 远程代理：优先使用本地 curl 直连代理测试外网连通性，防止节点账号密码外泄给第三方 API
        yellow "正在测试代理 ${check_proto}://${server}:${port} 连通性..."
        local curl_proxy_url="${check_proto}://${proxy_auth}${server}:${port}"
        local test_result
        test_result=$(curl -s --max-time 8 --proxy "$curl_proxy_url" "https://api.ip.sb/ip" 2>/dev/null)
        if [ -n "$test_result" ]; then
            green "代理可用，出口 IP: $test_result"
        else
            yellow "本地直连测试无响应，尝试备用检测通道..."
            local api_response
            api_response=$(curl -s --max-time 8 -G \
                --data-urlencode "proxy=${check_proto}://${proxy_auth}${server}:${port}" \
                "https://check.socks5.cmliussss.net/check" 2>/dev/null)
            local success=$(echo "$api_response" | jq -r '.success' 2>/dev/null)
            if [ "$success" == "true" ]; then
                local exit_ip=$(echo "$api_response" | jq -r '.exit.ip // empty')
                green "代理可用"
                [ -n "$exit_ip" ] && green "出口 IP: $exit_ip"
            else
                local error_msg=$(echo "$api_response" | jq -r '.error // "连接超时或认证失败"' 2>/dev/null)
                red "代理不可用: $error_msg"; sleep 2; return
            fi
        fi
    fi

    [ -n "$tag_from_url" ] && tag="$tag_from_url" || tag="${outbound_type}-${server}-${port}"
    jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$outbound_file" >/dev/null 2>&1 \
        && { red "出站标签 '${tag}' 已存在"; sleep 2; return; }

    # 根据是否有账号密码，决定写入字段，避免空字符串导致 sing-box 报错
    if [ -n "$user" ] && [ -n "$password" ]; then
        jq --arg type "$outbound_type" --arg tag "$tag" --arg server "$server" \
           --arg port "$port" --arg user "$user" --arg password "$password" \
           '.outbounds += [{"type":$type,"tag":$tag,"server":$server,"server_port":($port|tonumber),"username":$user,"password":$password}]' \
           "$outbound_file" > "${outbound_file}.tmp" && mv "${outbound_file}.tmp" "$outbound_file"
    else
        # 无账号密码：不写 username/password 字段
        jq --arg type "$outbound_type" --arg tag "$tag" --arg server "$server" \
           --arg port "$port" \
           '.outbounds += [{"type":$type,"tag":$tag,"server":$server,"server_port":($port|tonumber)}]' \
           "$outbound_file" > "${outbound_file}.tmp" && mv "${outbound_file}.tmp" "$outbound_file"
    fi

    if jq -e '.route.rules | length > 0' "$route_file" >/dev/null 2>&1; then
        jq --arg tag "$tag" '.route.rules[].outbound = $tag' "$route_file" > "${route_file}.tmp" \
            && mv "${route_file}.tmp" "$route_file"
        yellow "已将现有分流规则出站切换为 '${tag}'。"
    fi

    restart_singbox
    green "\n${tag} 代理出站已添加\n"
    sleep 2; warp_manage
}

delete_socks5_proxy() {
    clear
    green "当前可用出站列表:"
    local out_list=$(jq -r '[.outbounds[] | select(.tag != "direct")] | to_entries | .[] | "\(.key+1). \(.value.tag) [\(.value.type)]"' "$outbound_file" 2>/dev/null)
    [ -z "$out_list" ] && { yellow "没有可删除的出站。"; sleep 2; return; }
    echo "$out_list"

    reading "输入要删除的出站编号或标签: " del_input
    if [[ "$del_input" =~ ^[0-9]+$ ]]; then
        tag=$(jq -r --arg idx "$del_input" '.outbounds | map(select(.tag != "direct")) | .[($idx | tonumber)-1].tag // empty' "$outbound_file")
        [ -z "$tag" ] && { red "编号无效！"; sleep 1; return; }
    else
        tag="$del_input"
        jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$outbound_file" > /dev/null 2>&1 || { red "标签 '${tag}' 不存在！"; sleep 1; return; }
    fi
    [ "$tag" == "wireguard-out" ] && { red "wireguard-out 为系统内置，不可删除！"; sleep 2; return; }

    jq --arg tag "$tag" 'del(.outbounds[] | select(.tag == $tag))' "$outbound_file" > "${outbound_file}.tmp" && mv "${outbound_file}.tmp" "$outbound_file"
    jq --arg tag "$tag" '.route.rules = [.route.rules[] | select(.outbound != $tag)]' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"

    restart_singbox
    green "${tag} 代理出站已删除。"
    sleep 1
}

# ============================================================
# 协议管理模块 - 增加/删除 socks5 / anytls / shadowsocks-2022
# ============================================================

# 检查指定 tag 是否已在 inbounds 中存在
proto_exists() {
    local tag="$1"
    jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "${conf_dir}/inbounds.json" > /dev/null 2>&1
}

# 更新订阅文件
remove_url_by_tag() {
    local tag="$1"
    sed -i '/'^${tag}':\/\//d' "$client_dir"
    sed -i '/^$/{N; /\n$/D}' "$client_dir"
}

update_sub() {
    local sub_file="${work_dir}/sub.txt"
    base64_content=$(cat "$client_dir" | base64 | tr -d '\n\r')
    echo "$base64_content" > "$sub_file"
}

# ---- Socks5 入站 ----
add_socks5_inbound() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="socks5-in"

    if proto_exists "$tag"; then
        yellow "Socks5 协议已存在，无需重复添加。"; sleep 1; return
    fi

    # 获取当前UUID用于自动填充
    local current_uuid
    current_uuid=$(get_current_uuid | tr -d '\n\r')

    # 端口输入验证循环
    while true; do
        reading "请输入 Socks5 监听端口 (回车随机生成): " sk_port
        if [ -z "$sk_port" ]; then
            sk_port=$(shuf -i 10000-65000 -n 1)
            green "socks5监听端口：${purple}${sk_port}${re}"
            break
        fi
        
        # 统一验证端口格式和范围
        if [[ ! "$sk_port" =~ ^[0-9]+$ ]] || [ "$sk_port" -gt 65535 ] || [ "$sk_port" -lt 1 ]; then
            yellow "错误：端口必须是1-65535之间的数字！"
            continue
        fi
        
        green "socks5监听端口：${purple}${sk_port}${re}"
        break
    done

    reading "请输入 Socks5 用户名 (回车自动使用UUID前8位): " sk_user
    if [ -n "$sk_user" ]; then
        green "socks5用户名：${purple}${sk_user}${re}"
    else
        if [ -n "$current_uuid" ]; then
            sk_user=$(printf '%s' "${current_uuid:0:8}" | tr -d '\n\r')
            green "自动设置用户名: ${purple}${sk_user}${re}"
        else
            red "无法获取UUID，请手动输入用户名"
            reading "请输入 Socks5 用户名: " sk_user
            [ -z "$sk_user" ] && { red "用户名不能为空"; sleep 1; return; }
        fi
    fi

    reading "请输入 Socks5 密码 (回车自动使用UUID后12位): " sk_pass
    if [ -n "$sk_pass" ]; then
        green "socks5密码：${purple}${sk_pass}${re}"
    else
        if [ -n "$current_uuid" ]; then
            sk_pass=$(printf '%s' "${current_uuid: -12}" | tr -d '\n\r')
            green "自动设置密码: ${purple}${sk_pass}${re}"
        else
            red "无法获取UUID，请手动输入密码"
            reading "请输入 Socks5 密码: " sk_pass
            [ -z "$sk_pass" ] && { red "密码不能为空"; sleep 1; return; }
        fi
    fi

    jq --arg tag "$tag" \
       --argjson port "$sk_port" \
       --arg user "$sk_user" \
       --arg pass "$sk_pass" \
       '.inbounds += [{
           "type": "socks",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "users": [{"username": $user, "password": $pass}]
       }]' "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"

    allow_port ${sk_port}/tcp ${sk_port}/udp > /dev/null 2>&1

    local server_ip
    server_ip=$(get_realip)
    local isp
    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' \
        | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' \
        | sed 's/ /_/g' || echo "Socks5")

    local url_line="socks://$(printf '%s' "${sk_user}:${sk_pass}" | base64 -w0)@${server_ip}:${sk_port}#${isp}"

    echo "" >> "${client_dir}"
    echo "${url_line}" >> "${client_dir}"
    update_sub

    restart_singbox

    green "\nSocks5 协议已添加！"
    green "端口: ${purple}${sk_port}${re}"
    green "用户名: ${purple}${sk_user}${re}  ${green}密码:${re} ${purple}${sk_pass}${re}"
    green "节点链接: ${purple}${url_line}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "$url_line"
}

remove_socks5_inbound() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="socks5-in"

    if ! proto_exists "$tag"; then
        yellow "Socks5 协议未添加，无需删除。"; sleep 1; return
    fi

    jq --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))' \
        "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"

    remove_url_by_tag "socks"
    update_sub
    restart_singbox
    green "\nSocks5 协议已删除\n"
}

# ---- AnyTLS ----
add_anytls() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="anytls"

    if proto_exists "$tag"; then
        yellow "AnyTLS 协议已存在，无需重复添加。"; sleep 1; return
    fi

    # 使用已安装协议的UUID作为密码
    local current_uuid
    current_uuid=$(get_current_uuid)
    if [ -z "$current_uuid" ]; then
        red "无法获取当前UUID，请确认 sing-box 已正确安装并配置。"; sleep 2; return
    fi

    # 端口输入验证循环
    while true; do
        reading "请输入 AnyTLS 监听端口 (回车随机生成): " at_port
        
        if [ -z "$at_port" ]; then
            at_port=$(shuf -i 10000-65000 -n 1)
            green "Anytls监听端口：${purple}${at_port}${re}"
            break
        fi
        
        if [[ ! "$at_port" =~ ^[0-9]+$ ]] || [ "$at_port" -gt 65535 ] || [ "$at_port" -lt 1 ]; then
            yellow "错误：端口必须是1-65535之间的数字！"
            continue
        fi
        
        green "Anytls监听端口：${purple}${at_port}${re}"
        break
    done

    jq --arg tag "$tag" \
       --argjson port "$at_port" \
       --arg pass "$current_uuid" \
       --arg cert "${work_dir}/cert.pem" \
       --arg key "${work_dir}/private.key" \
       '.inbounds += [{
           "type": "anytls",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "users": [{"password": $pass}],
           "tls": {
               "enabled": true,
               "certificate_path": $cert,
               "key_path": $key
           }
       }]' "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"

    allow_port ${at_port}/tcp > /dev/null 2>&1

    local server_ip
    server_ip=$(get_realip)
    local isp
    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' \
        | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' \
        | sed 's/ /_/g' || echo "AnyTLS")

    local url_line="anytls://${current_uuid}@${server_ip}:${at_port}?insecure=1&sni=bing.com#${isp}"

    echo "" >> "${client_dir}"
    echo "${url_line}" >> "${client_dir}"
    update_sub

    restart_singbox

    green "\nAnyTLS 协议已添加！"
    green "密码(UUID): ${purple}${current_uuid}${re}"
    green "端口: ${purple}${at_port}${re}"
    green "节点链接:\n${purple}${url_line}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "$url_line"
}

remove_anytls() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="anytls"

    if ! proto_exists "$tag"; then
        yellow "AnyTLS 协议未添加，无需删除。"; sleep 1; return
    fi

    jq --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))' \
        "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"

    remove_url_by_tag "anytls"
    update_sub
    restart_singbox
    green "\nAnyTLS 协议已删除\n"
}

# ---- Shadowsocks-2022 ----
add_ss2022() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="shadowsocks-2022"

    if proto_exists "$tag"; then
        yellow "Shadowsocks-2022 协议已存在，无需重复添加。"; sleep 1; return
    fi

    # 端口输入验证循环
    while true; do
        reading "请输入 Shadowsocks-2022 监听端口 (回车随机生成): " ss_port
        
        if [ -z "$ss_port" ]; then
            ss_port=$(shuf -i 10000-65000 -n 1)
            green "Shadowsocks-2022监听端口：${purple}${ss_port}${re}"
            break
        fi
        
        if [[ ! "$ss_port" =~ ^[0-9]+$ ]] || [ "$ss_port" -gt 65535 ] || [ "$ss_port" -lt 1 ]; then
            yellow "错误：端口必须是1-65535之间的数字！"
            continue
        fi
        
        green "Shadowsocks-2022监听端口：${purple}${ss_port}${re}"
        break
    done

    echo ""
    green "请选择加密方式:"
    green "1. 2022-blake3-aes-128-gcm       (推荐，密钥16字节)"
    green "2. 2022-blake3-aes-256-gcm       (密钥32字节)"
    green "3. 2022-blake3-chacha20-poly1305 (密钥32字节)"
    reading "请输入选择 (默认1): " ss_method_choice
    local ss_method key_len
    case "${ss_method_choice}" in
        2) ss_method="2022-blake3-aes-256-gcm";        key_len=32 ;;
        3) ss_method="2022-blake3-chacha20-poly1305";   key_len=32 ;;
        *) ss_method="2022-blake3-aes-128-gcm";         key_len=16 ;;
    esac
    green "加密方式为：${purple}${ss_method}${re}"
    local ss_key
    ss_key=$(dd if=/dev/urandom bs=1 count=${key_len} 2>/dev/null | base64 -w0)
    
    jq --arg tag "$tag" \
       --argjson port "$ss_port" \
       --arg method "$ss_method" \
       --arg key "$ss_key" \
       '.inbounds += [{
           "type": "shadowsocks",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "method": $method,
           "password": $key,
           "multiplex": {"enabled": true}
       }]' "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"

    allow_port ${ss_port}/tcp ${ss_port}/udp > /dev/null 2>&1

    local server_ip
    server_ip=$(get_realip)
    local isp
    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' \
        | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' \
        | sed 's/ /_/g' || echo "SS2022")

    local ss_userinfo
    ss_userinfo=$(printf '%s:%s' "${ss_method}" "${ss_key}" | base64 -w0)
    local url_line="ss://${ss_userinfo}@${server_ip}:${ss_port}#${isp}"

    echo "" >> "${client_dir}"
    echo "${url_line}" >> "${client_dir}"
    update_sub

    restart_singbox

    green "\nShadowsocks-2022 协议已添加！"
    green "加密方式: ${purple}${ss_method}${re}"
    green "密钥(base64): ${purple}${ss_key}${re}"
    green "端口: ${purple}${ss_port}${re}"
    green "节点链接:\n${purple}${url_line}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "$url_line"
}

remove_ss2022() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="shadowsocks-2022"

    if ! proto_exists "$tag"; then
        yellow "Shadowsocks-2022 协议未添加，无需删除。"; sleep 1; return
    fi

    jq --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))' \
        "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"

    remove_url_by_tag "ss"
    update_sub
    restart_singbox
    green "\nShadowsocks-2022 协议已删除\n"
}

# 显示当前已启用的额外协议状态
show_extra_proto_status() {
    local inbounds_file="${conf_dir}/inbounds.json"
    echo ""
    green "--- 额外协议状态 ---"

    # Socks5
    if jq -e '.inbounds[] | select(.tag == "socks5-in")' "$inbounds_file" > /dev/null 2>&1; then
        local sk_port sk_user
        sk_port=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .listen_port' "$inbounds_file")
        sk_user=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .users[0].username // "N/A"' "$inbounds_file")
        sk_pass=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .users[0].password // "N/A"' "$inbounds_file")
        echo -e " Socks5:           ${green}已启用${re} (端口: ${skyblue}${sk_port}${re}, 用户名: ${skyblue}${sk_user}${re}，密码：${skyblue}${sk_pass}${re})"
    else
        echo -e " Socks5:           ${yellow}未启用${re}"
    fi

    # AnyTLS
    if jq -e '.inbounds[] | select(.tag == "anytls")' "$inbounds_file" > /dev/null 2>&1; then
        local at_port at_pass
        at_port=$(jq -r '.inbounds[] | select(.tag == "anytls") | .listen_port' "$inbounds_file")
        at_pass=$(jq -r '.inbounds[] | select(.tag == "anytls") | .users[0].password // "N/A"' "$inbounds_file")
        echo -e " AnyTLS:           ${green}已启用${re} (端口: ${skyblue}${at_port}${re}, 密码: ${skyblue}${at_pass}${re})"
    else
        echo -e " AnyTLS:           ${yellow}未启用${re}"
    fi

    # Shadowsocks-2022
    if jq -e '.inbounds[] | select(.tag == "shadowsocks-2022")' "$inbounds_file" > /dev/null 2>&1; then
        local ss_port ss_method
        ss_port=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-2022") | .listen_port' "$inbounds_file")
        ss_method=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-2022") | .method' "$inbounds_file")
        echo -e " Shadowsocks-2022: ${green}已启用${re} (端口: ${skyblue}${ss_port}${re}, 加密: ${skyblue}${ss_method}${re})"
    else
        echo -e " Shadowsocks-2022: ${yellow}未启用${re}"
    fi
    echo ""
}

# 协议管理主菜单
manage_protocols() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！请先安装 sing-box。"; sleep 2; menu; return
    fi

    clear; echo ""
    green "=== 协议管理 (增加/删除) ===\n"
    show_extra_proto_status

    green "--- Socks5 协议 ---"
    green "1. 添加 Socks5 协议"
    red   "2. 删除 Socks5 协议"
    skyblue "-----------------------------"
    green "--- AnyTLS 协议 ---"
    green "3. 添加 AnyTLS 协议"
    red   "4. 删除 AnyTLS 协议"
    skyblue "-----------------------------"
    green "--- Shadowsocks-2022 协议 ---"
    green "5. 添加 Shadowsocks-2022 协议"
    red   "6. 删除 Shadowsocks-2022 协议"
    skyblue "-----------------------------"
    purple "0. 返回主菜单"
    skyblue "-----------------------------"
    reading "请输入选择: " proto_choice
    echo ""
    case "${proto_choice}" in
        1) add_socks5_inbound ;;
        2) remove_socks5_inbound ;;
        3) add_anytls ;;
        4) remove_anytls ;;
        5) add_ss2022 ;;
        6) remove_ss2022 ;;
        0) menu; return ;;
        *) red "无效的选项！" ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回协议管理菜单...\033[0m\n'
    manage_protocols
}


# ============================================================
# 多用户系统与每日端口定时轮换管理模块
# ============================================================

# 获取服务器当前出站IP (检测 IPv4/IPv6 偏好)
get_server_ip() {
    local ip=""
    if [ -f "${work_dir}/url.txt" ]; then
        if grep -Eq '^(vless|hysteria2|tuic|anytls|socks|ss)://[^@]+@\[[0-9a-fA-F:]+\]' "${work_dir}/url.txt" 2>/dev/null; then
            ip=$(curl -6 -sm 2 ip.sb 2>/dev/null)
            [ -n "$ip" ] && { echo "[$ip]"; return 0; }
        elif grep -Eq '^(vless|hysteria2|tuic|anytls|socks|ss)://[^@]+@([0-9]{1,3}\.){3}[0-9]{1,3}' "${work_dir}/url.txt" 2>/dev/null; then
            ip=$(curl -4 -sm 2 ip.sb 2>/dev/null)
            [ -n "$ip" ] && { echo "$ip"; return 0; }
        fi
    fi
    get_realip
}

# 获取ISP标识（带本地缓存以加快生成速度）
get_isp_info() {
    local isp=""
    if [ -f "${work_dir}/isp.cache" ] && [ $(($(date +%s) - $(stat -c %Y "${work_dir}/isp.cache" 2>/dev/null || echo 0))) -lt 86400 ]; then
        isp=$(cat "${work_dir}/isp.cache" 2>/dev/null)
    fi
    if [ -z "$isp" ]; then
        isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" 2>/dev/null | tr -d '\n' | \
            awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | \
            sed 's/ /_/g')
        [ -z "$isp" ] && isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://ipapi.co/json" 2>/dev/null | tr -d '\n' | \
            awk -F\" '{c="";o="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="org")o=$(x+2)};if(c&&o)print c"-"o}' | \
            sed 's/ /_/g')
        [ -z "$isp" ] && isp="Singbox"
        echo "$isp" > "${work_dir}/isp.cache" 2>/dev/null || true
    fi
    echo "$isp"
}

# 获取Reality公私钥对
get_reality_keys() {
    local pub="" priv=""
    [ -f "${work_dir}/reality.pub" ] && pub=$(cat "${work_dir}/reality.pub" | tr -d '\n\r ')
    [ -f "${work_dir}/reality.key" ] && priv=$(cat "${work_dir}/reality.key" | tr -d '\n\r ')

    if [ -z "$priv" ] && [ -f "${conf_dir}/inbounds.json" ]; then
        priv=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.private_key // empty' "${conf_dir}/inbounds.json" 2>/dev/null | head -1)
        [ -n "$priv" ] && echo "$priv" > "${work_dir}/reality.key"
    fi

    if [ -z "$pub" ] && [ -f "${work_dir}/url.txt" ]; then
        pub=$(grep -o 'pbk=[^&]*' "${work_dir}/url.txt" 2>/dev/null | cut -d'=' -f2 | head -1 | tr -d '\n\r ')
        [ -n "$pub" ] && echo "$pub" > "${work_dir}/reality.pub"
    fi

    if [ -z "$pub" ] || [ -z "$priv" ]; then
        if [ -x "${work_dir}/sing-box" ]; then
            local output=$("${work_dir}/sing-box" generate reality-keypair 2>/dev/null)
            priv=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
            pub=$(echo "${output}" | awk '/PublicKey:/ {print $2}')
            [ -n "$pub" ] && echo "$pub" > "${work_dir}/reality.pub"
            [ -n "$priv" ] && echo "$priv" > "${work_dir}/reality.key"
        fi
    fi
    echo "$pub $priv"
}

# 获取Reality SNI
get_reality_sni() {
    local sni=""
    if [ -f "${conf_dir}/inbounds.json" ]; then
        sni=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.server_name // empty' "${conf_dir}/inbounds.json" 2>/dev/null | head -1)
    fi
    [ -z "$sni" ] && sni="www.iij.ad.jp"
    echo "$sni"
}

# 获取证书指纹
get_cert_fingerprint() {
    local fp=""
    if [ -f "${work_dir}/cert.pem" ]; then
        fp=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" 2>/dev/null | cut -d'=' -f2 | sed 's/:/%3A/g' | tr -d '\n\r ')
    fi
    echo "$fp"
}

# 获取Argo域名
get_argo_domain() {
    local domain=""
    if [ -f "${work_dir}/argo.log" ]; then
        domain=$(grep -oE 'https://[[:alnum:]+\.-]+\.trycloudflare\.com' "${work_dir}/argo.log" 2>/dev/null | sed 's@https://@@' | tail -1)
    fi
    if [ -z "$domain" ] && [ -f "${work_dir}/tunnel.yml" ]; then
        domain=$(grep 'hostname:' "${work_dir}/tunnel.yml" 2>/dev/null | awk '{print $2}' | tr -d '\n\r ' | head -1)
    fi
    echo "$domain"
}

# 获取Nginx订阅端口
get_nginx_port() {
    local p=""
    if [ -f "/etc/nginx/conf.d/sing-box.conf" ]; then
        p=$(grep -E '^\s*listen [0-9]+;' "/etc/nginx/conf.d/sing-box.conf" 2>/dev/null | awk '{print $2}' | sed 's/;//' | head -1)
    fi
    [ -z "$p" ] && p=$((vless_port + 1))
    [[ ! "$p" =~ ^[0-9]+$ ]] && p=8080
    echo "$p"
}

# 检测端口是否被系统其他程序占用
is_port_in_use() {
    local p=$1
    if command_exists lsof; then
        lsof -i :$p >/dev/null 2>&1 && return 0
    fi
    if command_exists ss; then
        ss -lntu 2>/dev/null | grep -q ":$p\b" && return 0
    fi
    if command_exists netstat; then
        netstat -lntu 2>/dev/null | grep -q ":$p\b" && return 0
    fi
    return 1
}

# 初始化多用户系统目录并迁移现有单用户
init_multi_user() {
    mkdir -p "${users_dir}"
    
    # 若存在 sing-box 配置但无多用户，自动将现有配置导入为 default 用户
    if [ -f "${conf_dir}/inbounds.json" ] && [ -z "$(ls -A "${users_dir}" 2>/dev/null)" ]; then
        local cur_uuid=$(get_current_uuid)
        [ -z "$cur_uuid" ] && cur_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32)
        
        local vp=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port // empty' "${conf_dir}/inbounds.json" 2>/dev/null | head -1)
        local hp=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port // empty' "${conf_dir}/inbounds.json" 2>/dev/null | head -1)
        local tp=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port // empty' "${conf_dir}/inbounds.json" 2>/dev/null | head -1)
        
        [ -z "$vp" ] || [ "$vp" == "null" ] && vp=$vless_port
        [ -z "$hp" ] || [ "$hp" == "null" ] && hp=$((vp + 3))
        [ -z "$tp" ] || [ "$tp" == "null" ] && tp=$((vp + 2))
        
        local p_min=$((vp > 1050 ? vp - 30 : 10000))
        local p_max=$((p_min + 100))
        [ "$p_max" -gt 65535 ] && { p_max=65535; p_min=$((65535 - 100)); }
        
        local token=""
        if [ -f "/etc/nginx/conf.d/sing-box.conf" ]; then
            token=$(sed -n 's|.*location = /\([^ ]*\).*|\1|p' "/etc/nginx/conf.d/sing-box.conf" 2>/dev/null | head -1)
        fi
        [ -z "$token" ] && token=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
        
        mkdir -p "${users_dir}/default"
        cat > "${users_dir}/default/user.conf" << EOF
USERNAME="default"
UUID="${cur_uuid}"
PORT_MIN="${p_min}"
PORT_MAX="${p_max}"
VLESS_PORT="${vp}"
HY2_PORT="${hp}"
TUIC_PORT="${tp}"
SUB_TOKEN="${token}"
ENABLED="1"
CREATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
LAST_ROTATED="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
        if [ -f "${work_dir}/url.txt" ]; then
            cp -f "${work_dir}/url.txt" "${users_dir}/default/url.txt"
        else
            generate_user_nodes "default"
        fi
        if [ -f "${work_dir}/sub.txt" ]; then
            cp -f "${work_dir}/sub.txt" "${users_dir}/default/sub.txt"
        else
            base64 -w0 "${users_dir}/default/url.txt" > "${users_dir}/default/sub.txt" 2>/dev/null || true
        fi
        chmod 644 "${users_dir}/default/sub.txt" 2>/dev/null || true
    fi
}

# 验证端口范围合法性及与其他用户是否重叠
validate_port_range() {
    local p_min=$1
    local p_max=$2
    local cur_user=$3

    if [[ ! "$p_min" =~ ^[0-9]+$ ]] || [[ ! "$p_max" =~ ^[0-9]+$ ]]; then
        red "错误：端口必须为纯数字！"
        return 1
    fi
    if [ "$p_min" -lt 1024 ] || [ "$p_max" -gt 65535 ]; then
        red "错误：端口范围必须在 1024 - 65535 之间！"
        return 1
    fi
    if [ "$p_min" -ge "$p_max" ]; then
        red "错误：起始端口必须严格小于结束端口！"
        return 1
    fi
    local range_size=$((p_max - p_min + 1))
    if [ "$range_size" -lt 6 ]; then
        red "错误：端口范围至少需要包含 6 个端口（推荐 20 个以上以保证轮换灵活性），当前仅 $range_size 个！"
        return 1
    fi

    # 检查是否与系统保留端口冲突 (Argo, Nginx)
    local ng_p=$(get_nginx_port)
    if [ "$ng_p" -ge "$p_min" ] && [ "$ng_p" -le "$p_max" ]; then
        red "错误：端口范围包含了订阅服务端口 ($ng_p)，请调整范围！"
        return 1
    fi
    if [ "${ARGO_PORT:-8001}" -ge "$p_min" ] && [ "${ARGO_PORT:-8001}" -le "$p_max" ]; then
        red "错误：端口范围包含了 Argo 隧道端口 (${ARGO_PORT:-8001})，请调整范围！"
        return 1
    fi

    # 检查与其他用户端口范围是否重叠
    if [ -d "${users_dir}" ]; then
        for uconf in "${users_dir}"/*/user.conf; do
            [ -f "$uconf" ] || continue
            local uname="" u_min=0 u_max=0
            uname=$(grep '^USERNAME=' "$uconf" | cut -d'"' -f2)
            u_min=$(grep '^PORT_MIN=' "$uconf" | cut -d'"' -f2)
            u_max=$(grep '^PORT_MAX=' "$uconf" | cut -d'"' -f2)
            [ "$uname" == "$cur_user" ] && continue

            # 重叠判定公式：max(p_min, u_min) <= min(p_max, u_max)
            local start_max=$p_min
            [ "$u_min" -gt "$start_max" ] && start_max=$u_min
            local end_min=$p_max
            [ "$u_max" -lt "$end_min" ] && end_min=$u_max

            if [ "$start_max" -le "$end_min" ]; then
                red "错误：端口范围 [${p_min}-${p_max}] 与用户 [${uname}] 的端口范围 [${u_min}-${u_max}] 冲突重叠！"
                return 1
            fi
        done
    fi
    return 0
}

# 在用户限定的端口范围内随机挑选 3 个互不相同且未被占用的端口（高性能内存比对）
pick_user_ports() {
    local p_min=$1
    local p_max=$2
    local old_v=${3:-0}
    local old_h=${4:-0}
    local old_t=${5:-0}

    # 一次性获取系统所有处于 LISTEN 状态的端口（避免循环执行系统命令导致高延迟）
    local active_ports_str=" "
    if command_exists ss; then
        active_ports_str=" $(ss -lntuH 2>/dev/null | awk '{print $5}' | sed -E 's/.*:([0-9]+)$/\1/' | tr '\n' ' ') "
    elif command_exists netstat; then
        active_ports_str=" $(netstat -lntu 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | tr '\n' ' ') "
    elif command_exists lsof; then
        active_ports_str=" $(lsof -i -P -n 2>/dev/null | grep LISTEN | awk '{print $9}' | sed -E 's/.*:([0-9]+)$/\1/' | tr '\n' ' ') "
    fi

    local avail=()
    for ((p=p_min; p<=p_max; p++)); do
        # 排除当前旧端口，确保更换有效性
        if [ "$p" -ne "$old_v" ] && [ "$p" -ne "$old_h" ] && [ "$p" -ne "$old_t" ]; then
            # 纯 Bash 字符串内存匹配，执行速度比反复 fork 子进程快上百倍
            if [[ "$active_ports_str" != *" $p "* ]]; then
                avail+=("$p")
            fi
        fi
    done

    # 若排除旧端口后可用端口不足3个，允许放宽选择范围
    if [ "${#avail[@]}" -lt 3 ]; then
        avail=()
        for ((p=p_min; p<=p_max; p++)); do
            if [[ "$active_ports_str" != *" $p "* ]]; then
                avail+=("$p")
            fi
        done
    fi

    # 兜底机制
    if [ "${#avail[@]}" -lt 3 ]; then
        avail=()
        for ((p=p_min; p<=p_max; p++)); do
            avail+=("$p")
        done
    fi

    local shuffled=($(shuf -e "${avail[@]}"))
    local new_v=${shuffled[0]}
    local new_h=${shuffled[1]}
    local new_t=${shuffled[2]}
    echo "$new_v $new_h $new_t"
}

# 为指定用户生成节点文件和专属订阅文件
generate_user_nodes() {
    local uname="$1"
    local udir="${users_dir}/${uname}"
    local uconf="${udir}/user.conf"
    [ -f "$uconf" ] || return 1

    local USERNAME UUID PORT_MIN PORT_MAX VLESS_PORT HY2_PORT TUIC_PORT SUB_TOKEN ENABLED CREATED_AT LAST_ROTATED
    source "$uconf"

    local server_ip=$(get_server_ip)
    local isp=$(get_isp_info)
    local keys=($(get_reality_keys))
    local public_key="${keys[0]}"
    local sni=$(get_reality_sni)
    local fingerprint=$(get_cert_fingerprint)
    local argodomain=$(get_argo_domain)

    # 1. VLESS Reality 节点
    local vless_url="vless://${UUID}@${server_ip}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=firefox&pbk=${public_key}&type=tcp&headerType=none#${isp}-${uname}-VLESS"

    # 2. VMess-WS 节点 (通过 Argo 隧道)
    local vmess_url=""
    if [ -n "$argodomain" ]; then
        local VMESS="{ \"v\": \"2\", \"ps\": \"${isp}-${uname}-VMess\", \"add\": \"${CFIP}\", \"port\": \"${CFPORT}\", \"id\": \"${UUID}\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": \"false\"}"
        vmess_url="vmess://$(echo "$VMESS" | base64 -w0)"
    fi

    # 3. Hysteria2 节点
    local hy2_url="hysteria2://${UUID}@${server_ip}:${HY2_PORT}/?sni=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3&obfs=none#${isp}-${uname}-Hy2"

    # 4. TUIC5 节点
    local tuic_url="tuic://${UUID}:${UUID}@${server_ip}:${TUIC_PORT}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${isp}-${uname}-TUIC"

    cat > "${udir}/url.txt" << UEOF
${vless_url}

${vmess_url}

${hy2_url}

${tuic_url}
UEOF
    # 清理多余空行
    sed -i '/^$/{N; /\n$/D}' "${udir}/url.txt"
    base64 -w0 "${udir}/url.txt" > "${udir}/sub.txt" 2>/dev/null || base64 "${udir}/url.txt" | tr -d '\n\r' > "${udir}/sub.txt"
    chmod 644 "${udir}/sub.txt"

    # 若为 default 用户，保持同步 /etc/sing-box/url.txt 和 sub.txt
    if [ "$uname" == "default" ]; then
        cp -f "${udir}/url.txt" "${work_dir}/url.txt" 2>/dev/null || true
        cp -f "${udir}/sub.txt" "${work_dir}/sub.txt" 2>/dev/null || true
        chmod 644 "${work_dir}/sub.txt" 2>/dev/null || true
    fi
}

# 重新组装并应用所有用户的 sing-box inbounds.json 配置
rebuild_all_inbounds() {
    init_multi_user
    local inbounds_file="${conf_dir}/inbounds.json"
    [ ! -f "$inbounds_file" ] && return 1

    # 备份当前配置
    cp -f "$inbounds_file" "${inbounds_file}.bak" 2>/dev/null || true

    local user_items=()
    local firewall_ports=()

    for udir in "${users_dir}"/*; do
        [ -d "$udir" ] || continue
        local uconf="${udir}/user.conf"
        [ -f "$uconf" ] || continue

        local USERNAME UUID PORT_MIN PORT_MAX VLESS_PORT HY2_PORT TUIC_PORT SUB_TOKEN ENABLED CREATED_AT LAST_ROTATED
        source "$uconf"
        [ "$ENABLED" != "1" ] && continue

        # 直接在内存拼接单项 JSON，避免在循环体内重复 fork 启动 jq 进程
        user_items+=("{\"username\":\"${USERNAME}\",\"uuid\":\"${UUID}\",\"vless_port\":${VLESS_PORT},\"hy2_port\":${HY2_PORT},\"tuic_port\":${TUIC_PORT}}")
        firewall_ports+=("${VLESS_PORT}/tcp" "${HY2_PORT}/udp" "${TUIC_PORT}/udp" "${PORT_MIN}-${PORT_MAX}/tcp" "${PORT_MIN}-${PORT_MAX}/udp")
    done

    local users_json="[]"
    if [ ${#user_items[@]} -gt 0 ]; then
        local joined_items
        joined_items=$(IFS=,; echo "${user_items[*]}")
        users_json="[${joined_items}]"
    fi

    local user_count=$(echo "$users_json" | jq '. | length')
    if [ "$user_count" -eq 0 ]; then
        yellow "警告：当前没有启用的用户！"
        return 1
    fi

    local sni=$(get_reality_sni)
    local keys=($(get_reality_keys))
    local privkey="${keys[1]}"
    local argo_port=${ARGO_PORT:-8001}

    # 提取现有配置中的其它自定义协议出站（如 socks5, anytls, ss2022）以便无缝保留
    local extra_inbounds=$(jq '[.inbounds[]? | select(.tag != "vmess-ws" and (.tag | test("^vless-reality(-.*)?$") | not) and (.tag | test("^hysteria2(-.*)?$") | not) and (.tag | test("^tuic(-.*)?$") | not))]' "$inbounds_file" 2>/dev/null || echo '[]')

    jq -n \
      --argjson users "$users_json" \
      --argjson argo_port "$argo_port" \
      --arg sni "$sni" \
      --arg privkey "$privkey" \
      --arg work_dir "$work_dir" \
      --argjson extras "$extra_inbounds" \
      '{
        inbounds: (
          ($users | map({
            type: "vless",
            tag: ("vless-reality-" + .username),
            listen: "::",
            listen_port: .vless_port,
            users: [{ uuid: .uuid, flow: "xtls-rprx-vision" }],
            tls: {
              enabled: true,
              server_name: $sni,
              reality: {
                enabled: true,
                handshake: { server: $sni, server_port: 443 },
                private_key: $privkey,
                short_id: [""]
              }
            }
          }))
          +
          [{
            type: "vmess",
            tag: "vmess-ws",
            listen: "::",
            listen_port: $argo_port,
            users: ($users | map({ uuid: .uuid })),
            transport: {
              type: "ws",
              path: "/vmess-argo",
              early_data_header_name: "Sec-WebSocket-Protocol"
            }
          }]
          +
          ($users | map({
            type: "hysteria2",
            tag: ("hysteria2-" + .username),
            listen: "::",
            listen_port: .hy2_port,
            users: [{ password: .uuid }],
            ignore_client_bandwidth: false,
            masquerade: "https://bing.com",
            tls: {
              enabled: true,
              alpn: ["h3"],
              min_version: "1.3",
              max_version: "1.3",
              certificate_path: ($work_dir + "/cert.pem"),
              key_path: ($work_dir + "/private.key")
            }
          }))
          +
          ($users | map({
            type: "tuic",
            tag: ("tuic-" + .username),
            listen: "::",
            listen_port: .tuic_port,
            users: [{ uuid: .uuid, password: .uuid }],
            congestion_control: "bbr",
            tls: {
              enabled: true,
              alpn: ["h3"],
              certificate_path: ($work_dir + "/cert.pem"),
              key_path: ($work_dir + "/private.key")
            }
          }))
          +
          $extras
        )
      }' > "${inbounds_file}.tmp"

    if jq . "${inbounds_file}.tmp" >/dev/null 2>&1; then
        mv "${inbounds_file}.tmp" "$inbounds_file"
        restart_singbox >/dev/null 2>&1
        [ ${#firewall_ports[@]} -gt 0 ] && allow_port "${firewall_ports[@]}" >/dev/null 2>&1
        return 0
    else
        red "错误：生成的 inbounds.json 配置无效，已恢复备份！"
        [ -f "${inbounds_file}.bak" ] && mv "${inbounds_file}.bak" "$inbounds_file"
        return 1
    fi
}

# 重新生成并加载 Nginx 专属订阅配置
update_nginx_sub_conf() {
    init_multi_user
    if ! command_exists nginx; then
        return 1
    fi

    local sub_port=$(get_nginx_port)
    local nginx_conf="/etc/nginx/conf.d/sing-box.conf"
    mkdir -p /etc/nginx/conf.d

    [ -f "$nginx_conf" ] && cp -f "$nginx_conf" "${nginx_conf}.bak.sub" 2>/dev/null || true

    local default_token=""
    if [ -f "${users_dir}/default/user.conf" ]; then
        default_token=$(grep '^SUB_TOKEN=' "${users_dir}/default/user.conf" | cut -d'"' -f2)
    fi

    cat > "${nginx_conf}.tmp" << NEOF
server {
    listen ${sub_port};
    listen [::]:${sub_port};
    server_name _;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
NEOF

    if [ -n "$default_token" ]; then
        cat >> "${nginx_conf}.tmp" << NEOF

    # Default Subscription
    location = /${default_token} {
        alias /etc/sing-box/sub.txt;
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }

    location = /sub/${default_token} {
        alias /etc/sing-box/sub.txt;
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }
NEOF
    fi

    for udir in "${users_dir}"/*; do
        [ -d "$udir" ] || continue
        local uconf="${udir}/user.conf"
        [ -f "$uconf" ] || continue

        local USERNAME UUID PORT_MIN PORT_MAX VLESS_PORT HY2_PORT TUIC_PORT SUB_TOKEN ENABLED CREATED_AT LAST_ROTATED
        source "$uconf"
        [ "$ENABLED" != "1" ] && continue
        [ -z "$SUB_TOKEN" ] && continue
        [ "$USERNAME" == "default" ] && continue

        cat >> "${nginx_conf}.tmp" << NEOF

    # User: ${USERNAME}
    location = /${SUB_TOKEN} {
        alias /etc/sing-box/users/${USERNAME}/sub.txt;
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }

    location = /sub/${SUB_TOKEN} {
        alias /etc/sing-box/users/${USERNAME}/sub.txt;
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }
NEOF
    done

    cat >> "${nginx_conf}.tmp" << 'NEOF'

    location / { return 404; }

    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
NEOF

    if nginx -t -c /etc/nginx/nginx.conf >/dev/null 2>&1 || nginx -t >/dev/null 2>&1; then
        mv "${nginx_conf}.tmp" "$nginx_conf"
        nginx -s reload >/dev/null 2>&1 || restart_nginx >/dev/null 2>&1
        return 0
    else
        red "错误：Nginx 配置语法测试失败，已还原旧配置！"
        [ -f "${nginx_conf}.bak.sub" ] && cp -f "${nginx_conf}.bak.sub" "$nginx_conf"
        rm -f "${nginx_conf}.tmp"
        return 1
    fi
}

# 执行单用户端口轮换
rotate_user_ports() {
    local uname="$1"
    local udir="${users_dir}/${uname}"
    local uconf="${udir}/user.conf"
    [ -f "$uconf" ] || { red "用户 [${uname}] 不存在！"; return 1; }

    local USERNAME UUID PORT_MIN PORT_MAX VLESS_PORT HY2_PORT TUIC_PORT SUB_TOKEN ENABLED CREATED_AT LAST_ROTATED
    source "$uconf"
    [ "$ENABLED" != "1" ] && { yellow "用户 [${uname}] 当前处于禁用状态，跳过轮换。"; return 0; }

    local old_v=$VLESS_PORT old_h=$HY2_PORT old_t=$TUIC_PORT
    local ports=($(pick_user_ports "$PORT_MIN" "$PORT_MAX" "$old_v" "$old_h" "$old_t"))
    local new_v=${ports[0]}
    local new_h=${ports[1]}
    local new_t=${ports[2]}

    cat > "$uconf" << EOF
USERNAME="${USERNAME}"
UUID="${UUID}"
PORT_MIN="${PORT_MIN}"
PORT_MAX="${PORT_MAX}"
VLESS_PORT="${new_v}"
HY2_PORT="${new_h}"
TUIC_PORT="${new_t}"
SUB_TOKEN="${SUB_TOKEN}"
ENABLED="${ENABLED}"
CREATED_AT="${CREATED_AT}"
LAST_ROTATED="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

    generate_user_nodes "$uname"

    local log_msg="[$(date '+%Y-%m-%d %H:%M:%S')] 用户 [${uname}] 端口已轮换: VLESS(${old_v}->${new_v}), Hy2(${old_h}->${new_h}), TUIC(${old_t}->${new_t})"
    echo "$log_msg" >> "${rotate_log}"
    green "$log_msg"
    return 0
}

# 执行所有启用用户的端口定时/即时轮换
rotate_all_users_ports() {
    init_multi_user
    echo ""
    purple "========================================================"
    purple "           正在执行多用户节点端口自动轮换..."
    purple "========================================================"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] === 开始执行端口轮换任务 ===" >> "${rotate_log}"

    local count=0
    for udir in "${users_dir}"/*; do
        [ -d "$udir" ] || continue
        local uconf="${udir}/user.conf"
        [ -f "$uconf" ] || continue
        local USERNAME ENABLED
        source "$uconf"
        if [ "$ENABLED" == "1" ]; then
            rotate_user_ports "$USERNAME"
            count=$((count + 1))
        fi
    done

    if [ "$count" -gt 0 ]; then
        rebuild_all_inbounds
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] === 共完成 ${count} 个用户的端口轮换与 sing-box 重新加载 ===" >> "${rotate_log}"
        green "
[√] 成功为 ${count} 个用户更换新端口，专属订阅已同步更新！
"
    else
        yellow "没有找到需要轮换的启用用户。"
    fi
}

# 设置/管理每日定时端口轮换任务
setup_cron_job() {
    local action=$1
    local hour=${2:-4}
    local min=${3:-0}

    case "$action" in
        "enable")
            cat > "${cron_file}" << EOF
# sing-box multi-user daily port rotation
SHELL=/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin
${min} ${hour} * * * root /bin/bash ${work_dir}/sing-box.sh -rotate-all >> ${rotate_log} 2>&1
EOF
            chmod 644 "${cron_file}" 2>/dev/null || true

            if command_exists crontab; then
                (crontab -l 2>/dev/null | grep -v "sing-box.*-rotate-all"; echo "${min} ${hour} * * * /bin/bash ${work_dir}/sing-box.sh -rotate-all >> ${rotate_log} 2>&1") | crontab - 2>/dev/null || true
            fi

            if command_exists systemctl; then
                systemctl enable cron >/dev/null 2>&1 || systemctl enable crond >/dev/null 2>&1 || true
                systemctl restart cron >/dev/null 2>&1 || systemctl restart crond >/dev/null 2>&1 || true
            elif command_exists rc-service; then
                rc-update add crond default >/dev/null 2>&1 || true
                rc-service crond restart >/dev/null 2>&1 || true
            fi

            cat > "${cron_conf}" << EOF
CRON_ENABLED="1"
CRON_HOUR="${hour}"
CRON_MIN="${min}"
EOF
            green "
[√] 每日定时端口轮换已开启！执行时间: 每天 $(printf "%02d:%02d" $hour $min)
"
            ;;
        "disable")
            rm -f "${cron_file}" >/dev/null 2>&1 || true
            if command_exists crontab; then
                crontab -l 2>/dev/null | grep -v "sing-box.*-rotate-all" | crontab - 2>/dev/null || true
            fi
            cat > "${cron_conf}" << EOF
CRON_ENABLED="0"
CRON_HOUR="${hour}"
CRON_MIN="${min}"
EOF
            yellow "
[!] 每日定时端口轮换已关闭。
"
            ;;
        "status")
            if [ -f "${cron_conf}" ]; then
                source "${cron_conf}"
            fi
            if [ "${CRON_ENABLED}" == "1" ]; then
                echo -e "${green}已开启${re} (每天 $(printf "%02d:%02d" ${CRON_HOUR:-4} ${CRON_MIN:-0}))"
            else
                echo -e "${yellow}未开启${re}"
            fi
            ;;
    esac
}

# 显示所有用户表格及摘要
show_all_users_table() {
    init_multi_user
    echo ""
    purple "===================================================================================================="
    purple "                                        多用户列表及状态概览                                        "
    purple "===================================================================================================="
    printf "%-5s %-16s %-22s %-16s %-24s %-8s\n" "序号" "用户名" "UUID (缩略)" "端口范围" "当前端口 (V/H/T)" "状态"
    echo "----------------------------------------------------------------------------------------------------"

    local idx=1
    for udir in "${users_dir}"/*; do
        [ -d "$udir" ] || continue
        local uconf="${udir}/user.conf"
        [ -f "$uconf" ] || continue
        local USERNAME UUID PORT_MIN PORT_MAX VLESS_PORT HY2_PORT TUIC_PORT SUB_TOKEN ENABLED CREATED_AT LAST_ROTATED
        source "$uconf"

        local status_str="${green}启用${re}"
        [ "$ENABLED" != "1" ] && status_str="${red}已禁用${re}"

        local short_uuid="${UUID:0:8}...${UUID: -4}"
        local ports_str="${VLESS_PORT} / ${HY2_PORT} / ${TUIC_PORT}"
        local range_str="${PORT_MIN}-${PORT_MAX}"

        printf "%-5s %-16s %-22s %-16s %-24s %b\n" "$idx" "$USERNAME" "$short_uuid" "$range_str" "$ports_str" "$status_str"
        idx=$((idx + 1))
    done
    echo "----------------------------------------------------------------------------------------------------"
    local cron_st=$(setup_cron_job status)
    green "每日定时端口轮换状态: $cron_st"
    echo ""
}

# 查看指定用户节点和专属订阅详情
show_user_sub_info() {
    local uname="$1"
    local udir="${users_dir}/${uname}"
    local uconf="${udir}/user.conf"
    [ -f "$uconf" ] || { red "用户 [${uname}] 不存在！"; return 1; }

    local USERNAME UUID PORT_MIN PORT_MAX VLESS_PORT HY2_PORT TUIC_PORT SUB_TOKEN ENABLED CREATED_AT LAST_ROTATED
    source "$uconf"

    local server_ip=$(get_server_ip)
    local sub_port=$(get_nginx_port)
    local base_sub_url="http://${server_ip}:${sub_port}/sub/${SUB_TOKEN}"

    clear; echo ""
    purple "===================================================================================================="
    purple "                                  用户 [${USERNAME}] 节点与专属订阅                                   "
    purple "===================================================================================================="
    green "用户名:       ${skyblue}${USERNAME}${re} [$( [ "$ENABLED" == "1" ] && echo -e "${green}正常运行${re}" || echo -e "${red}已禁用${re}" )]"
    green "UUID:         ${purple}${UUID}${re}"
    green "限制端口范围: ${yellow}${PORT_MIN} - ${PORT_MAX}${re}"
    green "当前活跃端口: VLESS: ${purple}${VLESS_PORT}${re} | Hysteria2: ${purple}${HY2_PORT}${re} | TUIC: ${purple}${TUIC_PORT}${re}"
    green "上次更换时间: ${skyblue}${LAST_ROTATED:-未轮换}${re}"
    echo "===================================================================================================="
    green "\n--- 专属节点明细 (支持复制直连导入) ---"

    if [ -f "${udir}/url.txt" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && echo -e "${purple}${line}${re}\n"
        done < "${udir}/url.txt"
    else
        generate_user_nodes "$uname"
        while IFS= read -r line; do
            [ -n "$line" ] && echo -e "${purple}${line}${re}\n"
        done < "${udir}/url.txt"
    fi

    yellow "温馨提示: 每日端口轮换后，客户端只需点击【更新订阅】即可自动无缝获取最新端口节点！\n"
    purple "===================================================================================================="
    green "--- 该用户专属订阅链接 ---"
    echo ""
    green "1. V2rayN / Shadowrocket / Nekobox / Karing 专属订阅链接:\n${purple}${base_sub_url}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "${base_sub_url}"
    echo "----------------------------------------------------------------------------------------------------"

    green "\n2. Clash / Mihomo 系列专属订阅链接:\n${purple}https://sublink.eooce.com/clash?config=${base_sub_url}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "https://sublink.eooce.com/clash?config=${base_sub_url}"
    echo "----------------------------------------------------------------------------------------------------"

    green "\n3. Sing-box 系列专属订阅链接:\n${purple}https://sublink.eooce.com/singbox?config=${base_sub_url}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "https://sublink.eooce.com/singbox?config=${base_sub_url}"
    echo "----------------------------------------------------------------------------------------------------"

    green "\n4. Surge 系列专属订阅链接:\n${purple}https://sublink.eooce.com/surge?config=${base_sub_url}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "https://sublink.eooce.com/surge?config=${base_sub_url}"
    purple "====================================================================================================\n"
}

# 交互式添加新用户
add_new_user() {
    clear; echo ""
    purple "=== 添加新用户 ==="
    echo ""

    local uname=""
    while true; do
        reading "请输入用户名 (仅限字母/数字/下划线, 2-20位): " uname
        if [[ ! "$uname" =~ ^[a-zA-Z0-9_-]{2,20}$ ]]; then
            red "用户名格式不合法，请重新输入！"
            continue
        fi
        if [ -d "${users_dir}/${uname}" ]; then
            red "用户 [${uname}] 已存在，请换一个用户名！"
            continue
        fi
        break
    done

    echo ""
    local p_min="" p_max=""
    while true; do
        yellow "说明：为确保每日端口自动更换有充足的备用端口，建议范围至少包含 20 个端口。"
        reading "请输入该用户的起始端口 (例如 21000): " p_min
        reading "请输入该用户的结束端口 (例如 21050): " p_max
        if validate_port_range "$p_min" "$p_max" "$uname"; then
            green "端口范围设定成功: ${p_min} - ${p_max}"
            break
        fi
        yellow "请重新输入符合要求的端口范围。\n"
    done

    echo ""
    local u_uuid=""
    reading "请输入该用户的UUID (直接回车将随机自动生成): " u_uuid
    [ -z "$u_uuid" ] && u_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32)
    green "用户UUID: ${purple}${u_uuid}${re}"

    local u_token=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)

    local ports=($(pick_user_ports "$p_min" "$p_max" 0 0 0))
    local v_port=${ports[0]}
    local h_port=${ports[1]}
    local t_port=${ports[2]}

    mkdir -p "${users_dir}/${uname}"
    cat > "${users_dir}/${uname}/user.conf" << EOF
USERNAME="${uname}"
UUID="${u_uuid}"
PORT_MIN="${p_min}"
PORT_MAX="${p_max}"
VLESS_PORT="${v_port}"
HY2_PORT="${h_port}"
TUIC_PORT="${t_port}"
SUB_TOKEN="${u_token}"
ENABLED="1"
CREATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
LAST_ROTATED="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

    generate_user_nodes "$uname"
    rebuild_all_inbounds
    update_nginx_sub_conf

    green "\n[√] 用户 [${uname}] 添加成功！"
    sleep 1
    show_user_sub_info "$uname"
}

# 交互式修改用户配置
modify_user() {
    clear; echo ""
    show_all_users_table
    reading "请输入要修改的用户名或序号: " uname_input
    [ -z "$uname_input" ] && return

    local uname="$uname_input"
    if [[ "$uname_input" =~ ^[0-9]+$ ]]; then
        local user_list=()
        for uconf in "${users_dir}"/*/user.conf; do
            [ -f "$uconf" ] || continue
            local un=$(grep '^USERNAME=' "$uconf" | cut -d'"' -f2)
            [ -n "$un" ] && user_list+=("$un")
        done
        if [ "$uname_input" -ge 1 ] && [ "$uname_input" -le "${#user_list[@]}" ]; then
            uname="${user_list[$((uname_input-1))]}"
        fi
    fi

    local udir="${users_dir}/${uname}"
    local uconf="${udir}/user.conf"
    if [ ! -f "$uconf" ]; then
        red "未找到用户 [${uname}]！"; sleep 1; return
    fi

    local USERNAME UUID PORT_MIN PORT_MAX VLESS_PORT HY2_PORT TUIC_PORT SUB_TOKEN ENABLED CREATED_AT LAST_ROTATED
    source "$uconf"

    echo ""
    green "=== 修改用户 [${uname}] ==="
    green "1. 修改端口范围 (当前: ${PORT_MIN}-${PORT_MAX})"
    green "2. 重新随机生成 UUID (当前: ${UUID})"
    green "3. 重置专属订阅 Token (防泄露)"
    green "4. 切换启用/禁用状态 (当前: $( [ "$ENABLED" == "1" ] && echo "已启用" || echo "已禁用" ))"
    purple "0. 返回上级"
    reading "请输入选择: " m_choice

    case "$m_choice" in
        1)
            local new_min="" new_max=""
            reading "请输入新的起始端口: " new_min
            reading "请输入新的结束端口: " new_max
            if validate_port_range "$new_min" "$new_max" "$uname"; then
                PORT_MIN=$new_min
                PORT_MAX=$new_max
                if [ "$VLESS_PORT" -lt "$new_min" ] || [ "$VLESS_PORT" -gt "$new_max" ] || \
                   [ "$HY2_PORT" -lt "$new_min" ] || [ "$HY2_PORT" -gt "$new_max" ] || \
                   [ "$TUIC_PORT" -lt "$new_min" ] || [ "$TUIC_PORT" -gt "$new_max" ]; then
                    local new_ports=($(pick_user_ports "$new_min" "$new_max" 0 0 0))
                    VLESS_PORT=${new_ports[0]}
                    HY2_PORT=${new_ports[1]}
                    TUIC_PORT=${new_ports[2]}
                    yellow "检测到原端口超出新范围，已自动为您分配新范围端口：VLESS($VLESS_PORT), Hy2($HY2_PORT), TUIC($TUIC_PORT)"
                fi
            else
                red "端口范围无效，未做修改。"; sleep 2; return
            fi
            ;;
        2)
            UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32)
            green "新 UUID 已生成: ${purple}${UUID}${re}"
            ;;
        3)
            SUB_TOKEN=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
            green "专属订阅 Token 已重置！"
            ;;
        4)
            if [ "$ENABLED" == "1" ]; then
                ENABLED="0"
                yellow "用户 [${uname}] 已禁用！"
            else
                ENABLED="1"
                green "用户 [${uname}] 已重新启用！"
            fi
            ;;
        0) return ;;
        *) red "无效选择"; return ;;
    esac

    cat > "$uconf" << EOF
USERNAME="${USERNAME}"
UUID="${UUID}"
PORT_MIN="${PORT_MIN}"
PORT_MAX="${PORT_MAX}"
VLESS_PORT="${VLESS_PORT}"
HY2_PORT="${HY2_PORT}"
TUIC_PORT="${TUIC_PORT}"
SUB_TOKEN="${SUB_TOKEN}"
ENABLED="${ENABLED}"
CREATED_AT="${CREATED_AT}"
LAST_ROTATED="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

    generate_user_nodes "$uname"
    rebuild_all_inbounds
    update_nginx_sub_conf
    green "\n[√] 用户 [${uname}] 配置更新成功！"
    sleep 1
}

# 交互式删除用户
delete_user() {
    clear; echo ""
    show_all_users_table
    reading "请输入要删除的用户名或序号: " uname_input
    [ -z "$uname_input" ] && return

    # 支持输入序号或用户名
    local target_user="$uname_input"
    if [[ "$uname_input" =~ ^[0-9]+$ ]]; then
        local user_list=()
        for uconf in "${users_dir}"/*/user.conf; do
            [ -f "$uconf" ] || continue
            local un=$(grep '^USERNAME=' "$uconf" | cut -d'"' -f2)
            [ -n "$un" ] && user_list+=("$un")
        done
        if [ "$uname_input" -ge 1 ] && [ "$uname_input" -le "${#user_list[@]}" ]; then
            target_user="${user_list[$((uname_input-1))]}"
        fi
    fi

    local udir="${users_dir}/${target_user}"
    if [ ! -d "$udir" ] || [ ! -f "${udir}/user.conf" ]; then
        red "未找到用户 [${target_user}]！"; sleep 1; return
    fi

    # 检查当前用户总数，保护最后一个用户不被误删
    local total_users=0
    for uconf in "${users_dir}"/*/user.conf; do
        [ -f "$uconf" ] && total_users=$((total_users + 1))
    done
    if [ "$total_users" -le 1 ]; then
        red "\n[!] 错误：当前仅剩最后 1 个用户 [${target_user}]，不能删除！服务器必须至少保留一个有效用户以维持节点服务。\n"
        sleep 2
        return
    fi

    local confirm=""
    if [ "$target_user" == "default" ]; then
        reading "警告：[default] 为系统初始用户，删除后原默认订阅链接将失效，确认删除吗? (y/n): " confirm
    else
        reading "确定要彻底删除用户 [${target_user}] 及其所有配置和专属订阅吗? (y/n): " confirm
    fi

    if [[ "$confirm" =~ ^[yY]$ ]]; then
        rm -rf "$udir"
        rebuild_all_inbounds
        update_nginx_sub_conf
        green "\n[√] 用户 [${target_user}] 已成功删除！\n"
    else
        purple "已取消删除操作。"
    fi
    sleep 1
}

# 汇总导出所有用户的专属订阅链接
export_all_users_sub() {
    init_multi_user
    local server_ip=$(get_server_ip)
    local sub_port=$(get_nginx_port)

    clear; echo ""
    purple "===================================================================================================="
    purple "                                     全部用户专属订阅链接总览                                       "
    purple "===================================================================================================="

    for udir in "${users_dir}"/*; do
        [ -d "$udir" ] || continue
        local uconf="${udir}/user.conf"
        [ -f "$uconf" ] || continue
        local USERNAME UUID PORT_MIN PORT_MAX VLESS_PORT HY2_PORT TUIC_PORT SUB_TOKEN ENABLED CREATED_AT LAST_ROTATED
        source "$uconf"

        local base_sub="http://${server_ip}:${sub_port}/sub/${SUB_TOKEN}"
        green "【用户: ${skyblue}${USERNAME}${re}】 状态: $( [ "$ENABLED" == "1" ] && echo -e "${green}启用${re}" || echo -e "${red}禁用${re}" ) | 端口范围: ${PORT_MIN}-${PORT_MAX}"
        echo -e "  - 通用订阅 (V2rayN/Shadowrocket/Karing): ${purple}${base_sub}${re}"
        echo -e "  - Clash/Mihomo 订阅: ${purple}https://sublink.eooce.com/clash?config=${base_sub}${re}"
        echo -e "  - Sing-box 订阅:     ${purple}https://sublink.eooce.com/singbox?config=${base_sub}${re}"
        echo -e "  - Surge 订阅:        ${purple}https://sublink.eooce.com/surge?config=${base_sub}${re}"
        echo "----------------------------------------------------------------------------------------------------"
    done
    purple "====================================================================================================\n"
}

# 端口定时轮换管理菜单
manage_port_rotation() {
    init_multi_user
    while true; do
        clear; echo ""
        purple "========================================================"
        purple "                  端口定时更换管理                      "
        purple "========================================================"
        local cron_st=$(setup_cron_job status)
        green "当前定时轮换状态: $cron_st"
        green "机制说明: 每天定时在各用户各自独立的端口范围内随机更换端口，"
        green "          避免长时间占用单端口被防火墙精准识别与阻断。"
        green "          用户客户端只需配置自动更新订阅即可无感续连。"
        echo "--------------------------------------------------------"
        green "1. 开启每日定时端口更换 (默认每天 04:00)"
        green "2. 关闭每日定时端口更换"
        skyblue "--------------------------------------------------------"
        green "3. 自定义每日更换时间"
        skyblue "--------------------------------------------------------"
        green "4. 立即为全部用户更换端口 (即时测试/批量轮换)"
        green "5. 立即为指定用户更换端口"
        skyblue "--------------------------------------------------------"
        green "6. 查看端口更换历史日志"
        skyblue "--------------------------------------------------------"
        purple "0. 返回主菜单"
        echo "========================================================"
        reading "请输入选择: " r_choice

        case "$r_choice" in
            1)
                setup_cron_job "enable" 4 0
                ;;
            2)
                setup_cron_job "disable"
                ;;
            3)
                reading "请输入每日轮换时间 (格式: HH:MM，如 03:30 或 05:00): " t_input
                if [[ "$t_input" =~ ^([0-1]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
                    local thour=${BASH_REMATCH[1]}
                    local tmin=${BASH_REMATCH[2]}
                    setup_cron_job "enable" "$thour" "$tmin"
                else
                    red "时间格式错误，必须为 24小时制 HH:MM (如 04:00)！"
                fi
                ;;
            4)
                rotate_all_users_ports
                ;;
            5)
                show_all_users_table
                reading "请输入要更换端口的用户名: " target_user
                if [ -n "$target_user" ] && [ -d "${users_dir}/${target_user}" ]; then
                    rotate_user_ports "$target_user"
                    rebuild_all_inbounds
                    green "\n用户 [${target_user}] 端口更换完成！"
                else
                    red "用户不存在！"
                fi
                ;;
            6)
                clear; echo ""
                purple "=== 最近 30 条端口轮换日志 ==="
                if [ -f "${rotate_log}" ]; then
                    tail -n 30 "${rotate_log}"
                else
                    yellow "暂无轮换日志。"
                fi
                echo ""
                ;;
            0) return ;;
            *) red "无效的选择！" ;;
        esac
        read -n 1 -s -r -p $'\n\033[1;91m按任意键继续...\033[0m\n'
    done
}

# 多用户管理系统主菜单
manage_multi_user() {
    init_multi_user
    while true; do
        clear; echo ""
        show_all_users_table
        purple "========================================================"
        purple "                  多用户系统管理菜单                    "
        purple "========================================================"
        green "1. 查看指定用户节点及专属订阅 (含二维码)"
        green "2. 添加新用户 (设置用户名/独立端口范围/专属订阅)"
        green "3. 修改用户信息 (端口范围/UUID/Token/启用禁用)"
        red   "4. 删除用户"
        skyblue "--------------------------------------------------------"
        green "5. 立即为指定用户更换端口"
        green "6. 立即为全部用户更换端口"
        skyblue "--------------------------------------------------------"
        green "7. 端口定时轮换设置 (开启/时间/日志)"
        green "8. 一键查看/导出全部用户专属订阅汇总"
        skyblue "--------------------------------------------------------"
        purple "0. 返回主菜单"
        echo "========================================================"
        reading "请输入选择: " mu_choice

        case "$mu_choice" in
            1)
                reading "请输入要查看的用户名: " v_user
                if [ -n "$v_user" ] && [ -d "${users_dir}/${v_user}" ]; then
                    show_user_sub_info "$v_user"
                else
                    red "用户不存在！"
                fi
                ;;
            2)
                add_new_user
                ;;
            3)
                modify_user
                ;;
            4)
                delete_user
                ;;
            5)
                reading "请输入要更换端口的用户名: " r_user
                if [ -n "$r_user" ] && [ -d "${users_dir}/${r_user}" ]; then
                    rotate_user_ports "$r_user"
                    rebuild_all_inbounds
                    green "\n用户 [${r_user}] 端口更换完成！"
                else
                    red "用户不存在！"
                fi
                ;;
            6)
                rotate_all_users_ports
                ;;
            7)
                manage_port_rotation
                ;;
            8)
                export_all_users_sub
                ;;
            0) return ;;
            *) red "无效的选择！" ;;
        esac
        read -n 1 -s -r -p $'\n\033[1;91m按任意键继续...\033[0m\n'
    done
}

rotate_single_user_cli() {
    init_multi_user
    local uname="$1"
    if [ -z "$uname" ]; then
        red "错误：请指定要轮换端口的用户名，例如: sb -rotate alice"
        exit 1
    fi
    if [ ! -d "${users_dir}/${uname}" ]; then
        red "错误：用户 [${uname}] 不存在！"
        exit 1
    fi
    rotate_user_ports "$uname"
    rebuild_all_inbounds
    green "[√] 用户 [${uname}] 端口轮换完成并更新配置！"
}

# 主菜单
menu() {
    singbox_status=$(check_singbox 2>/dev/null)
    nginx_status=$(check_nginx 2>/dev/null)
    argo_status=$(check_argo 2>/dev/null)

    clear; echo ""
    purple "=== 煜恒singbox四合一安装脚本 ===\n"
    purple "---Argo 状态: ${argo_status}"
    purple "--Nginx 状态: ${nginx_status}"
    purple "singbox 状态: ${singbox_status}\n"
    green "1. 安装sing-box"
    red   "2. 卸载sing-box"
    echo "==============="
    green "3. sing-box管理"
    green "4. Argo隧道管理"
    echo "==============="
    green "5. 查看节点信息"
    green "6. 修改节点配置"
    green "7. 管理节点订阅"
    green "8. WARP分流管理"
    echo "==============="
    green "9. 增加/删除协议"
    echo "==============="
    green "10. 多用户管理系统"
    green "11. 端口定时轮换管理"
    echo "==============="
    red "0. 退出脚本"
    echo "==========="
    # ← 去掉 reading，只负责显示
}

# 捕获 Ctrl+C
trap 'red "\n强制退出"; exit' INT

# 启动时自动同步并修复快捷指令与持久化脚本
init_shortcut_and_self

# ---- 参数解析入口 ----
case "$1" in
    -i | --install)
        auto_install
        exit 0
        ;;
    -u | --uninstall)
        auto_uninstall
        exit 0
        ;;
    -c | --check)
        check_nodes
        exit 0
        ;;
    -r | --restart)
        get_quick_tunnel
        change_argo_domain
        exit 0
        ;;
    -rotate-all | --rotate-all)
        rotate_all_users_ports
        exit 0
        ;;
    -rotate | --rotate)
        shift
        rotate_single_user_cli "$@"
        exit 0
        ;;
    -users | --users | -user-list | --user-list)
        show_all_users_table
        exit 0
        ;;
    -h | --help)
        echo ""
        green "用法: [sb或脚本] [参数], 示例: sb -c(查看节点信息)"
        echo ""
        green "  -i, --install     无交互安装sing-box"
        green "  -c, --check       查看节点信息和订阅链接"
        green "  -r, --restart     重新获取argo临时隧道并更新到订阅"
        green "  -rotate-all       立即执行全部用户端口轮换并更新配置"
        green "  -rotate <用户名>   立即执行指定用户端口轮换并更新配置"
        green "  -users            查看所有用户及其端口范围与状态概览"
        green "  -u, --uninstall   无交互卸载sing-box（含 nginx)"
        green "  -h, --help        显示此帮助信息"
        echo ""
        green "  不带参数          进入交互式主菜单"
        echo ""
        exit 0
        ;;
    "")
        # 无参数：进入交互式主菜单
        while true; do
            menu
            reading "请输入选择(0-11): " choice 
            echo ""
            need_pause=true  
            case "${choice}" in
                1)
                    check_singbox &>/dev/null; singbox_check=$?
                    if [ ${singbox_check} -eq 0 ]; then
                        yellow "sing-box 已经安装！\n"
                    else
                        manage_packages install nginx jq tar openssl lsof coreutils
                        install_singbox
                        if command_exists systemctl; then
                            main_systemd_services
                        elif command_exists rc-update; then
                            alpine_openrc_services
                            change_hosts
                            rc-service sing-box restart
                            rc-service argo restart
                        else
                            echo "Unsupported init system"; exit 1
                        fi
                        sleep 5
                        get_info
                        add_nginx_conf
                        init_multi_user
                        setup_cron_job "enable" 4 0 >/dev/null 2>&1 || true
                        update_nginx_sub_conf >/dev/null 2>&1 || true
                        create_shortcut
                    fi
                    ;;
                2)  uninstall_singbox;  need_pause=false ;;
                3)  manage_singbox;     need_pause=false ;;
                4)  manage_argo;        need_pause=true ;;
                5)  check_nodes;        need_pause=true ;;
                6)  change_config;      need_pause=true ;;
                7)  disable_open_sub;   need_pause=true ;;
                8)  warp_manage;        need_pause=false ;;
                9)  manage_protocols;   need_pause=false ;;
                10)
                    manage_multi_user
                    need_pause=false
                    ;;
                11)
                    manage_port_rotation
                    need_pause=false
                    ;;
                0)  exit 0 ;;       
                *)
                    red "无效的选项，请输入 0-11"
                    need_pause=true
                    ;;
            esac
            [ "$need_pause" = true ] && read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'
        done
        ;;
    *)
        red "未知参数: $1"
        echo ""
        green "用法: sb [参数],相关参数:[-i|-u|-c|-r|-h], 首次安装：bash脚本 -i(前面可带环境变量)"
        exit 1
        ;;
esac
