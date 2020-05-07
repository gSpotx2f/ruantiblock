#!/bin/sh

########################################################################
#
#   ruantiblock
#
#   URL:    https://github.com/gSpotx2f/ruantiblock
#
########################################################################

############################## Settings ################################

### Режим обработки пакетов в правилах iptables (1 - Tor, 2 - VPN)
PROXY_MODE=1
### Применять правила проксификации для трафика локальных сервисов роутера (0 - off, 1 - on)
PROXY_LOCAL_CLIENTS=1
### Порт транспарентного proxy tor (параметр TransPort в torrc)
TOR_TRANS_PORT=9040
### DNS-сервер для резолвинга в домене .onion (tor)
export ONION_DNS_ADDR="127.0.0.1#9053"
### Html-страница с инфо о текущем статусе (0 - off, 1 - on)
HTML_INFO=1
### Запись событий в syslog (0 - off, 1 - on)
export USE_LOGGER=1
### Режим полного прокси при старте скрипта (0 - off, 1 - on). Если 1, то весь трафик всегда идёт через прокси. Все пакеты попадающие в цепочку $IPT_CHAIN попадают в tor или VPN, за исключением сетей из $TOTAL_PROXY_EXCLUDE_NETS. Списки блокировок не используются для фильтрации. Работает только при PROXY_LOCAL_CLIENTS=0
DEF_TOTAL_PROXY=0
### Трафик в заданные сети идет напрямую, не попадая в tor или VPN, в режиме total-proxy
TOTAL_PROXY_EXCLUDE_NETS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
### Добавление в список блокировок пользовательских записей из файла $USER_ENTRIES_FILE (0 - off, 1 - on)
###  В $DATA_DIR можно создать текстовый файл user_entries с записями ip, CIDR или FQDN (одна на строку). Эти записи будут добавлены в список блокировок
###  В записях FQDN можно задать DNS-сервер для разрешения данного домена, через пробел (прим.: domain.com 8.8.8.8)
###  Можно комментировать строки (#)
ADD_USER_ENTRIES=1
### DNS-сервер для пользовательских записей (пустая строка - без DNS-сервера). Можно с портом: 8.8.8.8#53. Если в записи указан свой DNS-сервер - он имеет приоритет
export USER_ENTRIES_DNS=""
### Входящий сетевой интерфейс для правил iptables
IF_IN="br0"
### WAN интерфейс
IF_WAN="ppp0"
### VPN интерфейс для правил iptables
IF_VPN="tun0"
### --set-mark для отбора пакетов в VPN туннель
VPN_PKTS_MARK=1
### Максимальное кол-во элементов списка ipset (по умол.: 65536, на данный момент уже не хватает для полного списка ip...)
IPSET_MAXELEM=1000000
### Удаление записей из основных сетов перед началом заполнения временных сетов при обновлении (для освобождения оперативной памяти перед заполнением сетов) (0 - off, 1 - on)
IPSET_CLEAR_SETS=1
### Таймаут для записей в сете $IPSET_DNSMASQ
IPSET_DNSMASQ_TIMEOUT=3600
### Кол-во попыток обновления блэклиста (в случае неудачи)
MODULE_RUN_ATTEMPTS=3
### Таймаут между попытками обновления
MODULE_RUN_TIMEOUT=60

############################ Configuration #############################

export PATH="/opt/bin:/opt/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export NAME="ruantiblock"
export LANG="en_US.UTF-8"
export LANGUAGE="en"

DATA_DIR="/opt/var/${NAME}"

### Модули для получения и обработки блэклиста
MODULES_DIR="/opt/usr/bin"
BLLIST_MODULE_CMD="lua ${MODULES_DIR}/ruab_parser.lua"
#BLLIST_MODULE_CMD="python3 ${MODULES_DIR}/ruab_parser.py"
#BLLIST_MODULE_CMD="${MODULES_DIR}/ruab_parser.sh"
#BLLIST_MODULE_CMD=""

CONFIG_FILE="/opt/etc/${NAME}/${NAME}.conf"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

AWK_CMD="awk"
IPT_CMD="iptables"
IP_CMD="ip"
IPSET_CMD=`which ipset`
if [ $? -ne 0 ]; then
    echo " Error! Ipset doesn't exists" >&2
    exit 1
fi
LOGGER_CMD=`which logger`
if [ $USE_LOGGER = "1" -a $? -ne 0 ]; then
    echo " Logger doesn't exists" >&2
    USE_LOGGER=0
fi
LOGGER_PARAMS="-t `basename $0`[${$}] -p user.notice"
DNSMASQ_RESTART_CMD="/sbin/restart_dhcpd; /sbin/restart_dns"
export DNSMASQ_DATA_FILE="${DATA_DIR}/${NAME}.dnsmasq"
export IP_DATA_FILE="${DATA_DIR}/${NAME}.ip"
export IPSET_IP="${NAME}-ip"
export IPSET_IP_TMP="${IPSET_IP}-tmp"
export IPSET_CIDR="${NAME}-cidr"
export IPSET_CIDR_TMP="${IPSET_CIDR}-tmp"
export IPSET_DNSMASQ="${NAME}-dnsmasq"
export IPSET_ONION="onion"
export IPSET_TOTAL_PROXY="total-proxy"
export IPT_CHAIN="$NAME"
export UPDATE_STATUS_FILE="${DATA_DIR}/update_status"
UPDATE_PID_FILE="${DATA_DIR}/update.pid"
INIT_SCRIPT="/opt/etc/init.d/S40${NAME}"
HTML_DIR="/opt/share/www/custom"
export HTML_OUTPUT="${HTML_DIR}/${NAME}.html"
HTML_MAIN_BGCOLOR="#DDDDDD"
HTML_THEADER_FONTCOLOR="#4C4C4C"
HTML_BORDER_COLOR="#B5B5B5"
HTML_MAIN_FONT_COLOR="#333333"
### Пользовательские записи
USER_ENTRIES_FILE="/opt/etc/${NAME}/ruab_user_entries"

########################### Iptables config ############################

IPT_FIRST_CHAIN="PREROUTING"
IPT_QUEUE_CHAIN="$IPT_CHAIN"
IPT_IPSET_MSET="-m set --match-set"

### Проксификация трафика локальных клиентов
IPT_OUTPUT_FIRST_RULE="-j ${IPT_CHAIN}"
WAN_IP=`$IP_CMD addr list dev $IF_WAN | $AWK_CMD '/inet/{sub("/[0-9]{1,2}$", "", $2); print $2}'`
VPN_NAT_RULE="-m mark --mark ${VPN_PKTS_MARK} -s ${WAN_IP} -o ${IF_VPN} -j MASQUERADE"

### Tor конфигурация
IPT_TABLE="nat"
IPT_FIRST_CHAIN_RULE="-i ${IF_IN} -j ${IPT_CHAIN}"
IPT_IPSET_TARGET="dst -p tcp -j REDIRECT --to-ports ${TOR_TRANS_PORT}"
#IPT_IPSET_TARGET="dst -j REDIRECT --to-ports ${TOR_TRANS_PORT}"    # весь трафик (не только TCP)
IPT_IPSETS="${IPSET_ONION} ${IPSET_CIDR} ${IPSET_IP} ${IPSET_DNSMASQ}"

if [ "$PROXY_MODE" = "2" ]; then
    ### VPN конфигурация
    IPT_TABLE="mangle"
    IPT_FIRST_CHAIN_RULE="-j ${IPT_CHAIN}"
    IPT_IPSET_TARGET="dst,src -j MARK --set-mark ${VPN_PKTS_MARK}"
    IPT_IPSETS="${IPSET_CIDR} ${IPSET_IP} ${IPSET_DNSMASQ}"
fi

IPT_TP_RULE="-m set ! --match-set ${IPSET_TOTAL_PROXY} ${IPT_IPSET_TARGET}"

############################## Functions ###############################

Help () {
cat << EOF
 Usage: `basename $0` start|stop|destroy|restart|update|force-update|data-files|total-proxy-on|total-proxy-off|renew-ipt|status|status-html|--help
        start : Start
        stop : Stop
        destroy : Stop + destroy ipsets and clear all data files
        restart : Restart
        update : Update blacklist
        force-update : Force update blacklist
        data-files : Create ${IP_DATA_FILE} & ${DNSMASQ_DATA_FILE} (without network functions)
        total-proxy-on : Turn on total-proxy mode
        total-proxy-off : Turn off total-proxy mode
        renew-ipt : Renew iptables configuration
        status : Status & some info
        html-info : Update html info page (if HTML_INFO=1)
        -h|--help : This message
 Examples:
        `basename $0` start
        `basename $0` stop
        `basename $0` destroy
        `basename $0` restart
        `basename $0` update
        `basename $0` force-update
        `basename $0` data-files
        `basename $0` total-proxy-on
        `basename $0` total-proxy-off
        `basename $0` status
        `basename $0` html-info
EOF
}

MakeLogRecord () {
    [ $USE_LOGGER = "1" ] && $LOGGER_CMD $LOGGER_PARAMS $1
}

DnsmasqRestart () {
    eval `echo "$DNSMASQ_RESTART_CMD"`
}

IsIpsetExists () {
    $IPSET_CMD list "$1" -terse &> /dev/null
    return $?
}

FlushIpSets () {
    local _set
    for _set in "$@"
    do
        IsIpsetExists "$_set" && $IPSET_CMD flush "$_set"
    done
}

DestroyIpsets () {
    local _set
    for _set in "$@"
    do
        IsIpsetExists "$_set" && $IPSET_CMD destroy "$_set"
    done
}

FillTotalProxySet () {
    local _entry
    for _entry in $TOTAL_PROXY_EXCLUDE_NETS
    do
        $IPSET_CMD add "$IPSET_TOTAL_PROXY" "$_entry"
    done
}

TotalProxyOn () {
    if [ "$PROXY_LOCAL_CLIENTS" != "1" ]; then
        $IPT_CMD -t "$IPT_TABLE" -I "$IPT_CHAIN" 1 $IPT_TP_RULE
        if [ $? -eq 0 ]; then
            echo " ${IPSET_TOTAL_PROXY} enabled"
            MakeLogRecord "${IPSET_TOTAL_PROXY} enabled"
        fi
    fi
}

TotalProxyOff () {
    if [ "$PROXY_LOCAL_CLIENTS" != "1" ]; then
        $IPT_CMD -t "$IPT_TABLE" -D "$IPT_CHAIN" $IPT_TP_RULE
        if [ $? -ne 0 ]; then
            echo " ${IPSET_TOTAL_PROXY} is already disabled" >&2
        else
            echo " ${IPSET_TOTAL_PROXY} disabled"
            MakeLogRecord "${IPSET_TOTAL_PROXY} disabled"
        fi
    fi
}

AddIptRules () {
    local _set
    $IPT_CMD -t "$IPT_TABLE" -N "$IPT_CHAIN"
    $IPT_CMD -t "$IPT_TABLE" -I "$IPT_FIRST_CHAIN" 1 $IPT_FIRST_CHAIN_RULE
    if [ "$PROXY_LOCAL_CLIENTS" = "1" ]; then
        $IPT_CMD -t "$IPT_TABLE" -I OUTPUT 1 $IPT_OUTPUT_FIRST_RULE
        if [ "$PROXY_MODE" = "2" -a -n "$WAN_IP" ]; then
            $IPT_CMD -t nat -A POSTROUTING $VPN_NAT_RULE
        fi
    fi
    for _set in $IPT_IPSETS
    do
        $IPT_CMD -t "$IPT_TABLE" -A "$IPT_CHAIN" $IPT_IPSET_MSET "$_set" $IPT_IPSET_TARGET
    done
    if [ "$DEF_TOTAL_PROXY" = "1" ]; then
        TotalProxyOff &> /dev/null
        TotalProxyOn
    fi
}

RemIptRules () {
    $IPT_CMD -t "$IPT_TABLE" -F "$IPT_CHAIN"
    $IPT_CMD -t "$IPT_TABLE" -D "$IPT_FIRST_CHAIN" $IPT_FIRST_CHAIN_RULE
    if [ "$PROXY_LOCAL_CLIENTS" = "1" ]; then
        $IPT_CMD -t "$IPT_TABLE" -D OUTPUT $IPT_OUTPUT_FIRST_RULE
        if [ "$PROXY_MODE" = "2" -a -n "$WAN_IP" ]; then
            $IPT_CMD -t nat -D POSTROUTING $VPN_NAT_RULE
        fi
    fi
    $IPT_CMD -t "$IPT_TABLE" -X "$IPT_CHAIN"
}

SetNetConfig () {
    local _set
    for _set in "$IPSET_TOTAL_PROXY" "$IPSET_CIDR_TMP" "$IPSET_CIDR"
    do
        IsIpsetExists "$_set" || $IPSET_CMD create "$_set" hash:net maxelem $IPSET_MAXELEM
    done
    for _set in "$IPSET_IP_TMP" "$IPSET_IP" "$IPSET_ONION"
    do
        IsIpsetExists "$_set" || $IPSET_CMD create "$_set" hash:ip maxelem $IPSET_MAXELEM
    done
    IsIpsetExists "$IPSET_DNSMASQ" || $IPSET_CMD create "$IPSET_DNSMASQ" hash:ip maxelem $IPSET_MAXELEM timeout $IPSET_DNSMASQ_TIMEOUT
    FillTotalProxySet
    AddIptRules
}

DropNetConfig () {
    RemIptRules
    FlushIpSets "$IPSET_CIDR_TMP" "$IPSET_CIDR" "$IPSET_IP_TMP" "$IPSET_IP" "$IPSET_DNSMASQ" "$IPSET_ONION" "$IPSET_TOTAL_PROXY"
}

FillIpsets () {
    local _set
    if [ -f "$IP_DATA_FILE" ]; then
        echo " Filling ipsets..."
        FlushIpSets "$IPSET_IP_TMP" "$IPSET_CIDR_TMP"
        if [ "$IPSET_CLEAR_SETS" = "1" ]; then
            FlushIpSets "$IPSET_IP" "$IPSET_CIDR"
        fi
        IsIpsetExists "$IPSET_IP_TMP" && IsIpsetExists "$IPSET_CIDR_TMP" && IsIpsetExists "$IPSET_IP" && IsIpsetExists "$IPSET_CIDR" &&\
        cat "$IP_DATA_FILE" | $IPSET_CMD restore && { $IPSET_CMD swap "$IPSET_IP_TMP" "$IPSET_IP"; $IPSET_CMD swap "$IPSET_CIDR_TMP" "$IPSET_CIDR"; }
        if [ $? -eq 0 ]; then
            echo " Ok"
            FlushIpSets "$IPSET_IP_TMP" "$IPSET_CIDR_TMP"
        else
            echo " Error! Ipset wasn't updated" >&2
            MakeLogRecord "Error! Ipset wasn't updated"
        fi
    fi
}

ClearDataFiles () {
    printf "" > "$DNSMASQ_DATA_FILE"
    printf "" > "$IP_DATA_FILE"
    printf "0 0 0" > "$UPDATE_STATUS_FILE"
}

CheckStatus () {
    local _set _ipt_return=0 _ipset_return=0 _return_code=1
    $IPT_CMD -t "$IPT_TABLE" -L "$IPT_CHAIN" &> /dev/null
    _ipt_return=$?
    if [ "$1" = "ipsets" ]; then
        for _set in "$IPSET_TOTAL_PROXY" "$IPSET_CIDR_TMP" "$IPSET_CIDR" "$IPSET_IP_TMP" "$IPSET_IP" "$IPSET_DNSMASQ" "$IPSET_ONION"
        do
            IsIpsetExists "$_set"
            _ipset_return=$?
            [ $_ipset_return -ne 0 ] && break
        done
    fi
    [ $_ipt_return -eq 0 -a $_ipset_return -eq 0 ] && _return_code=0
    return $_return_code
}

PreStartCheck () {
    [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
    [ "$HTML_INFO" = "1" -a ! -d "$HTML_DIR" ] && mkdir -p "$HTML_DIR"
    [ -e "$DNSMASQ_DATA_FILE" ] || printf "\n" > "$DNSMASQ_DATA_FILE"
}

AddUserEntries () {
    if [ "$ADD_USER_ENTRIES" = "1" ]; then
        if [ -f "$USER_ENTRIES_FILE" -a -s "$USER_ENTRIES_FILE" ]; then
            $AWK_CMD 'BEGIN {
                        null="";
                        while((getline ip_string <ENVIRON["IP_DATA_FILE"]) > 0) {
                            split(ip_string, ip_string_arr, " ");
                            ip_data_array[ip_string_arr[3]]=null;
                        };
                        close(ENVIRON["IP_DATA_FILE"]);
                        while((getline fqdn_string <ENVIRON["DNSMASQ_DATA_FILE"]) > 0) {
                            split(fqdn_string, fqdn_string_arr, "/");
                            fqdn_data_array[fqdn_string_arr[2]]=null;
                        };
                        close(ENVIRON["DNSMASQ_DATA_FILE"]);
                    }
                    function writeIpsetEntries(val, set) {
                        printf "add %s %s\n", set, val >> ENVIRON["IP_DATA_FILE"];
                    };
                    function writeDNSData(val, dns) {
                        if(length(dns) == 0 && length(ENVIRON["USER_ENTRIES_DNS"]) > 0)
                            dns = ENVIRON["USER_ENTRIES_DNS"];
                        if(length(dns) > 0)
                            printf "server=/%s/%s\n", val, dns >> ENVIRON["DNSMASQ_DATA_FILE"];
                        printf "ipset=/%s/%s\n", val, ENVIRON["IPSET_DNSMASQ"] >> ENVIRON["DNSMASQ_DATA_FILE"];
                    };
                    ($0 !~ /^([\040\011]*$|#)/) {
                        if($0 ~ /^[0-9]{1,3}([.][0-9]{1,3}){3}$/ && !($0 in ip_data_array))
                            writeIpsetEntries($0, ENVIRON["IPSET_IP_TMP"]);
                        else if($0 ~ /^[0-9]{1,3}([.][0-9]{1,3}){3}[\057][0-9]{1,2}$/ && !($0 in ip_data_array))
                            writeIpsetEntries($0, ENVIRON["IPSET_CIDR_TMP"]);
                        else if($0 ~ /^[a-z0-9.\052-]+[.]([a-z]{2,}|xn--[a-z0-9]+)([ ][0-9]{1,3}([.][0-9]{1,3}){3}([#][0-9]{2,5})?)?$/ && !($1 in fqdn_data_array))
                            writeDNSData($1, $2);
                    }' "$USER_ENTRIES_FILE"
        fi
    fi
}

GetDataFiles () {
    local _return_code=1 _attempt=1 _update_string
    PreStartCheck
    echo "$$" > "$UPDATE_PID_FILE"
    if [ -n "$BLLIST_MODULE_CMD" ]; then
        while :
        do
            eval `echo "$BLLIST_MODULE_CMD"`
            _return_code=$?
            [ $_return_code -eq 0 ] && break
            ### STDOUT
            echo " Module run attempt ${_attempt}: failed [${BLLIST_MODULE_CMD}]"
            MakeLogRecord "Module run attempt ${_attempt}: failed [${BLLIST_MODULE_CMD}]"
            _attempt=`expr $_attempt + 1`
            [ $_attempt -gt $MODULE_RUN_ATTEMPTS ] && break
            sleep $MODULE_RUN_TIMEOUT
        done
        AddUserEntries
        if [ $_return_code -eq 0 ]; then
            _update_string=`$AWK_CMD '{
                printf "Received entries: %s\n", (NF < 3) ? "No data" : "IP: "$1", CIDR: "$2", FQDN: "$3;
                exit;
            }' "$UPDATE_STATUS_FILE"`
            ### STDOUT
            echo " ${_update_string}"
            MakeLogRecord "${_update_string}"
            printf " `date +%d.%m.%Y-%H:%M`\n" >> "$UPDATE_STATUS_FILE"
        fi
    else
        ClearDataFiles
        AddUserEntries
        _return_code=0
    fi
    if [ "$PROXY_MODE" = "2" ]; then
        printf "\n" >> "$DNSMASQ_DATA_FILE"
    else
        printf "server=/onion/%s\nipset=/onion/%s\n" "${ONION_DNS_ADDR}" "${IPSET_ONION}" >> "$DNSMASQ_DATA_FILE"
    fi
    rm -f "$UPDATE_PID_FILE"
    return $_return_code
}

Update () {
    local _return_code=0
    if CheckStatus ipsets; then
        :
    else
        echo " ${NAME} ${1} - Error! ${NAME} does not running or another error has occurred" >&2
        return 1
    fi
    if [ -e "$UPDATE_PID_FILE" ] && [ "$1" != "force-update" ]; then
        echo " ${NAME} ${1} - Error! Another instance of update is already running" >&2
        MakeLogRecord "${1} - Error! Another instance of update is already running"
        _return_code=2
    else
        echo " ${NAME} ${1}..."
        MakeLogRecord "${1}..."
        GetDataFiles
        case $? in
            0)
                echo " Blacklist updated"
                MakeLogRecord "Blacklist updated"
                FlushIpSets "$IPSET_DNSMASQ"
                FillIpsets
                DnsmasqRestart
            ;;
            2)
                echo " Error! Blacklist update error" >&2
                MakeLogRecord "Error! Blacklist update error"
                _return_code=1
            ;;
            *)
                echo " Module error! [${BLLIST_MODULE_CMD}]" >&2
                MakeLogRecord "Module error! [${BLLIST_MODULE_CMD}]"
                _return_code=1
            ;;
        esac
    fi
    return $_return_code
}

Start () {
    echo " ${NAME} ${1}..."
    MakeLogRecord "${1}..."
    DropNetConfig &> /dev/null
    SetNetConfig
    PreStartCheck
    FillIpsets
}

Stop () {
    echo " ${NAME} ${1}..."
    MakeLogRecord "${1}..."
    DropNetConfig &> /dev/null
}

RenewIpt () {
    if [ -x "$INIT_SCRIPT" ]; then
        RemIptRules &> /dev/null
        AddIptRules &> /dev/null
    fi
}

Status () {
    local _set
    local _call_iptables="${IPT_CMD} -t ${IPT_TABLE} -v -L ${IPT_CHAIN}"
    if CheckStatus; then
        printf "\n \033[1m${NAME} status\033[m: \033[1;32mActive\033[m\n\n  PROXY_MODE: ${PROXY_MODE}\n  DEF_TOTAL_PROXY: ${DEF_TOTAL_PROXY}\n  PROXY_LOCAL_CLIENTS: ${PROXY_LOCAL_CLIENTS}\n  BLLIST_MODULE_CMD: ${BLLIST_MODULE_CMD}\n"
        if [ -f "$UPDATE_STATUS_FILE" ]; then
            $AWK_CMD '{
                update_string=(NF < 4) ? "No data" : $4" (ip: "$1" | CIDR: "$2" | FQDN: "$3")";
                printf "\n  Last blacklist update:  %s\n", update_string;
            }' "$UPDATE_STATUS_FILE"
        else
            printf "\n  Last blacklist update:  No data\n"
        fi
        printf "\n  \033[4mIptables rules\033[m:\n\n"
        $_call_iptables | $AWK_CMD '
            {
                if(NR > 2) {
                    match_set=(NR == 3 && $0 ~ ENVIRON["IPSET_TOTAL_PROXY"]) ? "\033[1;31m"ENVIRON["IPSET_TOTAL_PROXY"]" (Enabled!)\033[m" : $11;
                    match_set_html=(NR == 3 && $0 ~ ENVIRON["IPSET_TOTAL_PROXY"]) ? ENVIRON["IPSET_TOTAL_PROXY"]" (Enabled!)" : $11;
                    match_set_html_class=(NR == 3 && $0 ~ ENVIRON["IPSET_TOTAL_PROXY"]) ? " red" : "";
                    printf "   Match-set:  %s\n   Bytes:  %s\n\n", match_set, $2;
                };
            }'
        printf "  \033[4mIp sets\033[m:\n\n"
        for _set in "$IPSET_TOTAL_PROXY" "$IPSET_CIDR_TMP" "$IPSET_CIDR" "$IPSET_IP_TMP" "$IPSET_IP" "$IPSET_DNSMASQ" "$IPSET_ONION"
        do
            $IPSET_CMD list "$_set" -terse | $AWK_CMD -F ":" '
                {
                    if($1 ~ /^(Name|Size in memory|Number of entries)/) {
                        printf "   %s: %s\n", $1, $2;
                        if($1 ~ /^Number of entries/) printf "\n";
                    };
                }'
        done
    else
        printf "\n \033[1m${NAME} status\033[m: \033[1mOff\033[m\n\n"
        exit 2
    fi
}

HtmlInfo () {
    local _set
    local _call_iptables="${IPT_CMD} -t ${IPT_TABLE} -v -L ${IPT_CHAIN}"
    if [ "$HTML_INFO" = "1" -a -d "$HTML_DIR" ]; then
cat << EOF > $HTML_OUTPUT
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml"><head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
<title>${NAME} status</title>
<style type="text/css">
body { margin: 0px; padding: 0px; background-color: ${HTML_MAIN_BGCOLOR}; font-family: sans-serif; font-size: 11pt; font-weight: 400; color: ${HTML_MAIN_FONT_COLOR} }
#main_layout { width: 100%; min-width: 760px }
div.main { position: relative; width: 100%; text-align: center; padding: 10px 0px 10px 0px; font-size: 10pt; color: ${HTML_THEADER_FONTCOLOR}; border: 0px; }
table.info_table { width: 700px; border-collapse: collapse; margin: auto }
tr.infoarea > td { padding: 5px; font-size: 10pt; color: ${HTML_THEADER_FONTCOLOR}; border-top: 0px; border-bottom: 1px solid ${HTML_BORDER_COLOR}; border-left: 0px; border-right: 0px }
tr.list > td { width: 50%; padding: 5px 2px 5px 2px; border-top: 1px solid ${HTML_BORDER_COLOR}; border-bottom: 1px solid ${HTML_BORDER_COLOR}; border-left: 0px; border-right: 0px }
span.info_label { display: block; padding: 0px 0px 10px 0px }
.green { background-color: #E4FFE4 }
.red { background-color: #FFD6D6 }
</style>
</head><body>
<div id="main_layout">
EOF
        if CheckStatus; then
            printf "<div class=\"main\"><table class=\"info_table\">\n\
            <tr class=\"list\"><td align=\"left\">Last status update at:</td><td align=\"left\">`date`</td></tr>\n\
            <tr class=\"list green\"><td align=\"left\">${NAME} status:</td><td align=\"left\">Active</td></tr>\n\
            <tr class=\"list\"><td align=\"left\">PROXY_MODE:</td><td align=\"left\">${PROXY_MODE}</td></tr>\n\
            <tr class=\"list\"><td align=\"left\">DEF_TOTAL_PROXY:</td><td align=\"left\">${DEF_TOTAL_PROXY}</td></tr>\n\
            <tr class=\"list\"><td align=\"left\">PROXY_LOCAL_CLIENTS:</td><td align=\"left\">${PROXY_LOCAL_CLIENTS}</td></tr>\n\
            <tr class=\"list\"><td align=\"left\">BLLIST_MODULE_CMD:</td><td align=\"left\">${BLLIST_MODULE_CMD}</td></tr>\n" >> "$HTML_OUTPUT"
            if [ -f "$UPDATE_STATUS_FILE" ]; then
                $AWK_CMD '{
                    update_string=(NF < 4) ? "No data" : $4" (ip: "$1" | CIDR: "$2" | FQDN: "$3")";
                    printf "<tr class=\"list\"><td align=\"left\">Last blacklist update:</td><td align=\"left\">%s</td></tr>\n", update_string;
                }' "$UPDATE_STATUS_FILE" >> "$HTML_OUTPUT"
            else
                printf "<tr class=\"list\"><td align=\"left\">Last blacklist update:</td><td align=\"left\">No data</td></tr>\n" >> "$HTML_OUTPUT"
            fi
            printf "</table></div><div class=\"main\"><span class=\"info_label\">Iptables rules:</span>" >> "$HTML_OUTPUT"
            $_call_iptables | $AWK_CMD '
                BEGIN {
                    printf "%s", "<table class=\"info_table\"><tr class=\"infoarea\"><td align=\"left\" width=\"50%\">Match-set</td><td align=\"center\">Bytes</td></tr>";
                }
                {
                    if(NR > 2) {
                        match_set=(NR == 3 && $0 ~ ENVIRON["IPSET_TOTAL_PROXY"]) ? "\033[1;31m"ENVIRON["IPSET_TOTAL_PROXY"]" (Enabled!)\033[m" : $11;
                        match_set_html=(NR == 3 && $0 ~ ENVIRON["IPSET_TOTAL_PROXY"]) ? ENVIRON["IPSET_TOTAL_PROXY"]" (Enabled!)" : $11;
                        match_set_html_class=(NR == 3 && $0 ~ ENVIRON["IPSET_TOTAL_PROXY"]) ? " red" : "";
                        printf "<tr class=\"infoarea%s\"><td align=\"left\">%s</td><td align=\"center\">%s</td></tr>\n", match_set_html_class, match_set_html, $2;
                    };
                }
                END {
                    printf "%s", "</table></div>";
                }' >> "$HTML_OUTPUT"
            printf "%s" "<div class=\"main\"><span class=\"info_label\">Ip sets:</span>\
            <table class=\"info_table\">\
            <tr class=\"infoarea\"><td align=\"left\" width=\"33%\">Name</td><td align=\"center\" width=\"33%\">Size in memory</td><td align=\"center\">Number of entries</td></tr>" >> "$HTML_OUTPUT"
            for _set in "$IPSET_TOTAL_PROXY" "$IPSET_CIDR_TMP" "$IPSET_CIDR" "$IPSET_IP_TMP" "$IPSET_IP" "$IPSET_DNSMASQ" "$IPSET_ONION"
            do
                $IPSET_CMD list "$_set" -terse | $AWK_CMD -F ":" '
                    BEGIN {
                        printf "%s", "<tr class=\"infoarea\">";
                    }
                    {
                        if($1 ~ /^(Name|Size in memory|Number of entries)/) {
                            align=($1 ~ /^Name/) ? "left" : "center";
                            printf "<td align=\"%s\">%s</td>\n", align, $2;
                        };
                    }
                    END {
                        printf "%s", "</tr>";
                    }' >> "$HTML_OUTPUT"
            done
            printf "</table></div>" >> "$HTML_OUTPUT"
        else
            printf "<div class=\"main\"><table class=\"info_table\"><tr class=\"list\"><td align=\"left\">${NAME} status:</td><td align=\"left\">Off</td></tr></table></div>\n" >> "$HTML_OUTPUT"
        fi
        printf "</div></body></html>\n" >> "$HTML_OUTPUT"
    fi
}

############################# Run section ##############################

case "$1" in
    start|restart)
        Start "$1"
        HtmlInfo
    ;;
    stop)
        Stop "$1"
        HtmlInfo
    ;;
    destroy)
        Stop "$1"
        DestroyIpsets "$IPSET_TOTAL_PROXY" "$IPSET_CIDR_TMP" "$IPSET_CIDR" "$IPSET_IP_TMP" "$IPSET_IP" "$IPSET_DNSMASQ" "$IPSET_ONION"
        ClearDataFiles
        rm -f "$UPDATE_PID_FILE"
        DnsmasqRestart
        HtmlInfo
    ;;
    renew-ipt)
        RenewIpt
        HtmlInfo
    ;;
    update|force-update)
        Update "$1"
        HtmlInfo
    ;;
    data-files)
        if [ -e "$UPDATE_PID_FILE" ] && [ "$1" != "force-update" ]; then
            echo " ${NAME} - Error! Another instance of update is already running" >&2
            exit 2
        else
            GetDataFiles
        fi
    ;;
    total-proxy-on)
        TotalProxyOff &> /dev/null
        TotalProxyOn
        HtmlInfo
    ;;
    total-proxy-off)
        TotalProxyOff
        HtmlInfo
    ;;
    status)
        Status
    ;;
    html-info)
        HtmlInfo
    ;;
    -h|--help|help)
        Help
    ;;
    *)
        Help
        exit 1
    ;;
esac

exit 0;
