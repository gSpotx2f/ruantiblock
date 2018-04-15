#!/bin/sh

########################################################################
#
# ruantiblock v0.8 (c) 2018
#
# Author:       gSpot <https://github.com/gSpotx2f/ruantiblock>
# License:      GPLv3
# Depends:
# Recommends:   idn, lua, tor, tor-geoip
#
########################################################################

############################## Settings ################################

### Входящий сетевой интерфейс для правил iptables
IF_IN="br0"
### Максимальное кол-во элементов списка ipset (по умол.: 65536, на данный момент уже не хватает для полного списка ip...)
IPSET_MAXELEM=100000
### Таймаут для записей в сете $IPSET_DNSMASQ
IPSET_DNSMASQ_TIMEOUT=900
### Порт транспарентного proxy tor (параметр TransPort в torrc)
TOR_TRANS_PORT=9040
### DNS-сервер для резолвинга в домене .onion (tor)
export ONION_DNS_ADDR="127.0.0.1#9053"
### Запись событий в syslog (0 - off, 1 - on)
export USE_LOGGER=1
### Режим обработки пакетов в правилах iptables (1 - Tor, 2 - VPN)
PROXY_MODE=1
### --set-mark для отбора пакетов в VPN туннель
VPN_PKTS_MARK=1
### Режим полного прокси при старте скрипта (0 - off, 1 - on). Если 1, то весь трафик всегда идёт через прокси. Все пакеты попадающие в цепочку $IPT_CHAIN попадают в tor или VPN, за исключением сетей из $TOTAL_PROXY_EXCLUDE_NETS. Списки блокировок не используются для фильтрации
DEF_TOTAL_PROXY=0
### Трафик в заданные сети идет напрямую, не попадая в tor или VPN, в режиме total-proxy
TOTAL_PROXY_EXCLUDE_NETS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
### Html-страница с инфо о текущем статусе (0 - off, 1 - on)
USE_HTML_STATUS=1
### Добавление в список блокировок пользовательских записей из файла $USER_ENTRIES_FILE (0 - off, 1 - on)
###  В $DATA_DIR можно создать текстовый файл user_entries с записями ip, CIDR или FQDN (одна на строку). Эти записи будут добавлены в список блокировок
###  В записях FQDN можно задать DNS-сервер для разрешения данного домена, через пробел (прим.: domain.com 8.8.8.8)
###  Можно комментировать строки (#)
ADD_USER_ENTRIES=1

############################ Configuration #############################

export PATH="${PATH}:/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin"
export NAME="ruantiblock"
export LANG="en_US.UTF-8"
AWKCMD="awk"
IPTCMD="iptables"
IPSETCMD=`which ipset`
if [ $? -ne 0 ]; then
    echo " Error! Ipset doesn't exists" >&2
    exit 1
fi
LOGGERCMD=`which logger`
if [ $USE_LOGGER = "1" -a $? -ne 0 ]; then
    echo " Logger doesn't exists" >&2
    USE_LOGGER=0
fi
LOGGER_PARAMS="-t `basename $0`[${$}] -p user.notice"
DNSMASQ_RESTART_CMD="/sbin/restart_dhcpd; /sbin/restart_dns"
DATA_DIR="/opt/var/${NAME}"
export DNSMASQ_DATA="${DATA_DIR}/${NAME}.dnsmasq"
export IP_DATA="${DATA_DIR}/${NAME}.ip"
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
USER_ENTRIES_FILE="${DATA_DIR}/user_entries"
### Модули для получения и обработки блэклиста
MODULES_DIR="/opt/usr/bin"
BLLIST_MODULE_CMD="lua ${MODULES_DIR}/ruab.az-rbl.all.lua"
#BLLIST_MODULE_CMD="${MODULES_DIR}/ruab.az.fqdn.sh"
#BLLIST_MODULE_CMD="${MODULES_DIR}/ruab.az-rbl.all.sh"

########################### Iptables config ############################

IPT_FIRST_CHAIN="PREROUTING"
IPT_QUEUE_CHAIN="$IPT_CHAIN"
IPT_IPSET_MSET="-m set --match-set"

### Tor конфигурация
IPT_TABLE="nat"
IPT_FIRST_CHAIN_RULE="-i ${IF_IN} -j ${IPT_CHAIN}"
IPT_IPSET_TARGET="dst -p tcp -j REDIRECT --to-ports ${TOR_TRANS_PORT}"
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
        destroy : Stop and destroy ipsets
        restart : Restart
        update : Update blacklist
        force-update : Force update blacklist
        data-files : Create ${IP_DATA} & ${DNSMASQ_DATA} (without network functions)
        total-proxy-on : Total-proxy mode on
        total-proxy-off : Total-proxy mode off
        renew-ipt : Renew iptables configuration
        status : Status & some info
        status-html : Update html-status (if USE_HTML_STATUS=1)
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
        `basename $0` status-html
EOF

}

MakeLogRecord () {

    [ $USE_LOGGER = "1" ] && $LOGGERCMD $LOGGER_PARAMS $1

}

DnsmasqRestart () {

    eval `echo "$DNSMASQ_RESTART_CMD"`

}

IsIpsetExists () {

    $IPSETCMD list "$1" &> /dev/null
    return $?

}

FlushIpSets () {

    local _set

    for _set in "$@"
    do
        IsIpsetExists "$_set" && $IPSETCMD flush "$_set"
    done

}

DestroyIpsets () {

    local _set

    for _set in "$@"
    do
        IsIpsetExists "$_set" && $IPSETCMD destroy "$_set"
    done

}

FillTotalProxySet () {

    local _entry

    for _entry in $TOTAL_PROXY_EXCLUDE_NETS
    do
        $IPSETCMD add "$IPSET_TOTAL_PROXY" "$_entry"
    done

}

TotalProxyOn () {

    $IPTCMD -t "$IPT_TABLE" -I "$IPT_CHAIN" 1 $IPT_TP_RULE

}

TotalProxyOff () {

    $IPTCMD -t "$IPT_TABLE" -D "$IPT_CHAIN" $IPT_TP_RULE

}

AddIptRules () {

    local _set

    $IPTCMD -t "$IPT_TABLE" -N "$IPT_CHAIN"
    $IPTCMD -t "$IPT_TABLE" -I "$IPT_FIRST_CHAIN" 1 $IPT_FIRST_CHAIN_RULE

    for _set in $IPT_IPSETS
    do
        $IPTCMD -t "$IPT_TABLE" -A "$IPT_CHAIN" $IPT_IPSET_MSET "$_set" $IPT_IPSET_TARGET
    done

    if [ "$DEF_TOTAL_PROXY" = "1" ]; then
        TotalProxyOff &> /dev/null
        TotalProxyOn
    fi

}

RemIptRules () {

    $IPTCMD -t "$IPT_TABLE" -F "$IPT_CHAIN"
    $IPTCMD -t "$IPT_TABLE" -D "$IPT_FIRST_CHAIN" $IPT_FIRST_CHAIN_RULE
    $IPTCMD -t "$IPT_TABLE" -X "$IPT_CHAIN"

}

SetNetConfig () {

    local _set

    ### Создание списков ipset. Проверка на наличие списка с таким же именем, если нет, то создается новый

    for _set in "$IPSET_TOTAL_PROXY" "$IPSET_CIDR_TMP" "$IPSET_CIDR"
    do
        IsIpsetExists "$_set" || $IPSETCMD create "$_set" hash:net maxelem $IPSET_MAXELEM
    done

    for _set in "$IPSET_IP_TMP" "$IPSET_IP" "$IPSET_ONION"
    do
        IsIpsetExists "$_set" || $IPSETCMD create "$_set" hash:ip maxelem $IPSET_MAXELEM
    done

    IsIpsetExists "$IPSET_DNSMASQ" || $IPSETCMD create "$IPSET_DNSMASQ" hash:ip maxelem $IPSET_MAXELEM timeout $IPSET_DNSMASQ_TIMEOUT

    FillTotalProxySet
    AddIptRules

}

DropNetConfig () {

    RemIptRules
    FlushIpSets "$IPSET_CIDR_TMP" "$IPSET_CIDR" "$IPSET_IP_TMP" "$IPSET_IP" "$IPSET_DNSMASQ" "$IPSET_ONION" "$IPSET_TOTAL_PROXY"

}

FillIpsets () {

    local _set

    ### Заполнение списков ipset $IPSET_IP и $IPSET_CIDR. Сначала restore загружает во временные списки, а затем swap из временных добавляет в основные

    if [ -f "$IP_DATA" ]; then

        echo " Filling ipsets..."
        FlushIpSets "$IPSET_IP_TMP" "$IPSET_CIDR_TMP"
        IsIpsetExists "$IPSET_IP_TMP" && IsIpsetExists "$IPSET_CIDR_TMP" && IsIpsetExists "$IPSET_IP" && IsIpsetExists "$IPSET_CIDR" &&\
        cat "$IP_DATA" | $IPSETCMD restore && { $IPSETCMD swap "$IPSET_IP_TMP" "$IPSET_IP"; $IPSETCMD swap "$IPSET_CIDR_TMP" "$IPSET_CIDR"; }

        if [ $? -eq 0 ]; then
            echo " Ok"
        else
            echo " Error! Ipset wasn't updated" >&2
            MakeLogRecord "Error! Ipset wasn't updated"
        fi

    fi

}

PreStartCheck () {

    [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
    ### Костыль для старта dnsmasq
    [ -e "$DNSMASQ_DATA" ] || printf "\n" > "$DNSMASQ_DATA"

}

AddUserEntries () {

    if [ "$ADD_USER_ENTRIES" = "1" ]; then

        if [ -f "$USER_ENTRIES_FILE" -a -s "$USER_ENTRIES_FILE" ]; then

            $AWKCMD '
                    function writeIpsetEntries(val, set) {
                        printf "add %s %s\n", set, val >> ENVIRON["IP_DATA"];
                    };
                    function writeDNSData(val, dns) {
                        if(length(dns) > 0)
                            printf "server=/%s/%s\n", val, dns >> ENVIRON["DNSMASQ_DATA"];
                        printf "ipset=/%s/%s\n", val, ENVIRON["IPSET_DNSMASQ"] >> ENVIRON["DNSMASQ_DATA"];
                    };
                    ($0 !~ /^($|#)/) {
                        if($0 ~ /^[0-9]{1,3}([.][0-9]{1,3}){3}$/)
                            writeIpsetEntries($0, ENVIRON["IPSET_IP_TMP"]);
                        else if($0 ~ /^[0-9]{1,3}([.][0-9]{1,3}){3}[\057][0-9]{1,2}$/)
                            writeIpsetEntries($0, ENVIRON["IPSET_CIDR_TMP"]);
                        else if($0 ~ /^[a-z0-9.\052-]+[.]([a-z]{2,}|xn--[a-z0-9]+)([ ][0-9]{1,3}([.][0-9]{1,3}){3}([#][0-9]{2,5})?)?$/)
                            writeDNSData($1, $2);
                    }' "$USER_ENTRIES_FILE"

        fi

    fi

}

GetDataFiles () {

    local _return_code _update_string

    PreStartCheck
    echo "$$" > "$UPDATE_PID_FILE"

    eval `echo "$BLLIST_MODULE_CMD"`
    _return_code=$?

    AddUserEntries

    if [ $_return_code -eq 0 ]; then

        _update_string=`$AWKCMD '{printf "%s ip, %s CIDR and %s FQDN entries added\n", $1, $2, $3; exit}' "$UPDATE_STATUS_FILE"`
        ### STDOUT
        echo " ${_update_string}"
        MakeLogRecord "${_update_string}"

        if [ "$PROXY_MODE" = "2" ]; then
            printf "\n" >> "$DNSMASQ_DATA"
        else
            ### Запись для .onion в $DNSMASQ_DATA
            printf "server=/onion/%s\nipset=/onion/%s\n" "${ONION_DNS_ADDR}" "${IPSET_ONION}" >> "$DNSMASQ_DATA"
        fi

    fi

    printf " `date +%d.%m.%Y-%H:%M`\n" >> "$UPDATE_STATUS_FILE"
    rm -f "$UPDATE_PID_FILE"

    return $_return_code

}

Update () {

    local _return_code=0

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

    local _total_proxy="disabled"

    if [ "$DEF_TOTAL_PROXY" = "1" ]; then
        _total_proxy="enabled"
    fi

    echo " ${NAME} ${1} (${IPSET_TOTAL_PROXY}: ${_total_proxy})..."
    MakeLogRecord "${1} (${IPSET_TOTAL_PROXY}: ${_total_proxy})..."
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

    if [ -f "$INIT_SCRIPT" ]; then
        RemIptRules &> /dev/null
        AddIptRules &> /dev/null
    fi

}

Status () {

    local _set
    local _call_iptables="${IPTCMD} -t ${IPT_TABLE} -v -L ${IPT_CHAIN}"

    [ "$1" = "html" -a "$USE_HTML_STATUS" != "1" ] && return 0

    if [ "$1" = "html" ]; then

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

    fi

    $_call_iptables &> /dev/null

    if [ $? -eq 0 ]; then

        if [ "$1" = "html" ]; then
            printf "<div class=\"main\"><table class=\"info_table\">\n\
                    <tr class=\"list\"><td align=\"left\">Last status update at:</td><td align=\"left\">`date`</td></tr>\n\
                    <tr class=\"list green\"><td align=\"left\">${NAME} status:</td><td align=\"left\">Active</td></tr>\n\
                    <tr class=\"list\"><td align=\"left\">PROXY_MODE:</td><td align=\"left\">${PROXY_MODE}</td></tr>\n\
                    <tr class=\"list\"><td align=\"left\">DEF_TOTAL_PROXY:</td><td align=\"left\">${DEF_TOTAL_PROXY}</td></tr>\n\
                    <tr class=\"list\"><td align=\"left\">BLLIST_MODULE_CMD:</td><td align=\"left\">${BLLIST_MODULE_CMD}</td></tr>\n" >> "$HTML_OUTPUT"
        else
            printf "\n \033[1m${NAME} status\033[m: \033[1;32mActive\033[m\n\n  PROXY_MODE: ${PROXY_MODE}\n  DEF_TOTAL_PROXY: ${DEF_TOTAL_PROXY}\n  BLLIST_MODULE_CMD: ${BLLIST_MODULE_CMD}\n"
        fi

        [ -f "$UPDATE_STATUS_FILE" ] && $AWKCMD -v TYPE="$1" '{
                        update_string=(NF < 4) ? "No data" : $4" (ip: "$1" | CIDR: "$2" | FQDN: "$3")";
                        if(TYPE == "html")
                            printf "<tr class=\"list\"><td align=\"left\">Last blacklist update:</td><td align=\"left\">%s</td></tr>\n", update_string >> ENVIRON["HTML_OUTPUT"];
                        else
                            printf "\n  Last blacklist update:  %s\n", update_string;
                    }' "$UPDATE_STATUS_FILE"

        if [ "$1" = "html" ]; then
            printf "</table></div><div class=\"main\"><span class=\"info_label\">Iptables rules:</span>" >> "$HTML_OUTPUT"
        else
            printf "\n  \033[4mIptables rules\033[m:\n\n"
        fi

        $_call_iptables | $AWKCMD -v TYPE="$1" '
            BEGIN {
                if(TYPE == "html")
                    printf "%s", "<table class=\"info_table\"><tr class=\"infoarea\"><td align=\"left\" width=\"50%\">Match-set</td><td align=\"center\">Bytes</td></tr>" >> ENVIRON["HTML_OUTPUT"];
            }
            {
                if(NR > 2) {
                    match_set=(NR == 3 && $0 ~ ENVIRON["IPSET_TOTAL_PROXY"]) ? "\033[1;31m"ENVIRON["IPSET_TOTAL_PROXY"]" (Enabled!)\033[m" : $11;
                    match_set_html=(NR == 3 && $0 ~ ENVIRON["IPSET_TOTAL_PROXY"]) ? ENVIRON["IPSET_TOTAL_PROXY"]" (Enabled!)" : $11;
                    match_set_html_class=(NR == 3 && $0 ~ ENVIRON["IPSET_TOTAL_PROXY"]) ? " red" : "";
                    if(TYPE == "html")
                        printf "<tr class=\"infoarea%s\"><td align=\"left\">%s</td><td align=\"center\">%s</td></tr>\n", match_set_html_class, match_set_html, $2 >> ENVIRON["HTML_OUTPUT"];
                    else
                        printf "   Match-set:  %s\n   Bytes:  %s\n\n", match_set, $2;
                };
            }
            END {
                if(TYPE == "html")
                    printf "%s", "</table></div>" >> ENVIRON["HTML_OUTPUT"];
            }'

        if [ "$1" = "html" ]; then
            printf "%s" "<div class=\"main\"><span class=\"info_label\">Ip sets:</span>\
                    <table class=\"info_table\">\
                    <tr class=\"infoarea\"><td align=\"left\" width=\"33%\">Name</td><td align=\"center\" width=\"33%\">Size in memory</td><td align=\"center\">Number of entries</td></tr>" >> "$HTML_OUTPUT"
        else
            printf "  \033[4mIp sets\033[m:\n\n"
        fi

        for _set in "$IPSET_TOTAL_PROXY" "$IPSET_CIDR_TMP" "$IPSET_CIDR" "$IPSET_IP_TMP" "$IPSET_IP" "$IPSET_DNSMASQ" "$IPSET_ONION"
        do
            $IPSETCMD list "$_set" -terse | $AWKCMD -F ":" -v TYPE="$1" '
                BEGIN {
                    if(TYPE == "html")
                        printf "%s", "<tr class=\"infoarea\">" >> ENVIRON["HTML_OUTPUT"];
                }
                {
                    if($1 ~ /^(Name|Size in memory|Number of entries)/) {
                        if(TYPE == "html") {
                            align=($1 ~ /^Name/) ? "left" : "center";
                            printf "<td align=\"%s\">%s</td>\n", align, $2 >> ENVIRON["HTML_OUTPUT"];
                        }
                        else {
                            printf "   %s: %s\n", $1, $2;
                            if($1 ~ /^Number of entries/) printf "\n";
                        };
                    };
                }
                END {
                    if(TYPE == "html")
                        printf "%s", "</tr>" >> ENVIRON["HTML_OUTPUT"];
                }'
        done

        [ "$1" = "html" ] && printf "</table></div>" >> "$HTML_OUTPUT"

    else

        if [ "$1" = "html" ]; then
            printf "<div class=\"main\"><table class=\"info_table\"><tr class=\"list\"><td align=\"left\">${NAME}status:</td><td align=\"left\">Off</td></tr></table></div>\n" >> "$HTML_OUTPUT"
        else
            printf "\n \033[1m${NAME} status\033[m: \033[1mOff\033[m\n\n"
        fi

        exit 2

    fi

    [ "$1" = "html" ] && printf "</div></body></html>\n" >> "$HTML_OUTPUT"

}

############################# Run section ##############################

case "$1" in
    start|restart)
        Start "$1"
        Status html
    ;;
    stop)
        Stop "$1"
        Status html
    ;;
    destroy)
        Stop "$1"
        DestroyIpsets "$IPSET_TOTAL_PROXY" "$IPSET_CIDR_TMP" "$IPSET_CIDR" "$IPSET_IP_TMP" "$IPSET_IP" "$IPSET_DNSMASQ" "$IPSET_ONION"
        Status html
    ;;
    renew-ipt)
        ### Костыль для post_iptables_script.sh
        RenewIpt
    ;;
    update|force-update)
        Update "$1"
        Status html
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
        TotalProxyOn &> /dev/null

        if [ $? -eq 0 ]; then
            echo " ${IPSET_TOTAL_PROXY} enabled"
            MakeLogRecord "${IPSET_TOTAL_PROXY} enabled"
        else
            echo " ${NAME} is off..." >&2
        fi

        Status html
    ;;
    total-proxy-off)
        TotalProxyOff &> /dev/null

        if [ $? -ne 0 ]; then
            echo " ${IPSET_TOTAL_PROXY} is already disabled" >&2
        else
            echo " ${IPSET_TOTAL_PROXY} disabled"
            MakeLogRecord "${IPSET_TOTAL_PROXY} disabled"
        fi

        Status html
    ;;
    status)
        Status
    ;;
    status-html)
        Status html
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
