#!/bin/sh

########################################################################
#
# ruantiblock v0.7 (c) 2018
#
# Author:       gSpot <https://github.com/gSpotx2f/ruantiblock>
# License:      GPLv3
# Depends:      tor, tor-geoip
# Recommends:   idn
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
### Альтернативный DNS-сервер ($ONION_DNS_ADDR (tor), 8.8.8.8 и др.). Если провайдер не блокирует сторонние DNS-запросы, то оптимальнее будет использовать для заблокированных сайтов, например, 8.8.8.8, а не резолвить через tor...
export ALT_DNS_ADDR="8.8.8.8"
### Перенаправлять DNS-запросы на альтернативный DNS-сервер для заблокированных FQDN (или в tor если провайдер блокирует сторонние DNS-серверы) (0 - off, 1 - on)
export ALT_NSLOOKUP=1
### В случае если из источника получено менее указанного кол-ва записей, то обновления списков не происходит
export BLLIST_MIN_ENTRS=1000
### Обрезка www. в FQDN
export STRIP_WWW=1
### Записи (ip, CIDR, FQDN) исключаемые из списка блокировки (через пробел)
export EXCLUDE_ENTRIES="youtube.com"
### Пользовательские записи (ip, CIDR, FQDN) добавляемые к списку блокировки (через пробел). FQDN - только ASCII или punycode, без кириллицы
export INCLUDE_ENTRIES=""
### SLD не подлежащие оптимизации (через пробел)
export OPT_EXCLUDE_SLD="livejournal.com facebook.com vk.com blog.jp msk.ru net.ru org.ru net.ua com.ua org.ua co.uk"
### Не оптимизировать домены 3-го ур-ня вида: subdomain.xx(x).xx (.msk.ru .net.ru .org.ru .net.ua .com.ua .org.ua .co.uk и т.п.) (0 - off, 1 - on)
export OPT_EXCLUDE_3LD_REGEXP=0
### Лимит для субдоменов. При превышении, в список ${NAME}.dnsmasq будет добавлен весь домен 2-го ур-ня, вместо множества субдоменов нижних уровней (прим.: graniru.info - более 600! доменов 3-го уровня заменяются одной записью 2-го уровня)
export SD_LIMIT=16
### Преобразование кириллических доменов в punycode
export USE_IDN=1
### Запись событий в syslog (0 - off, 1 - on)
export USE_LOGGER=1
### Тип обновления списка блокировок: 1 - antizapret.info, 2 - rublacklist.net
export BL_UPDATE_MODE=1
### Режим обхода блокировок: 1 - ip (если провайдер блокирует по ip), 2 - FQDN (если провайдер использует DPI, подмену DNS и пр.)
export BLOCK_MODE=2
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

############################ Configuration #############################

export PATH="${PATH}:/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin"
export NAME="ruantiblock"
export LANG="en_US.UTF-8"
### Необходим gawk. Ибо "облегчённый" mawk, похоже, не справляется с огромным кол-вом обрабатываемых записей и крашится с ошибками...
AWKCMD="awk"
IPTCMD="iptables"
WGETCMD=`which wget`
if [ $? -ne 0 ]; then
    echo " Error! Wget doesn't exists" >&2
    exit 1
fi
WGET_PARAMS="-T 60 -q -O -"
IPSETCMD=`which ipset`
if [ $? -ne 0 ]; then
    echo " Error! Ipset doesn't exists" >&2
    exit 1
fi
LOGGERCMD=`which logger`
if [ $USE_LOGGER = "1" -a $? -ne 0 ]; then
    echo " Error! Logger doesn't exists" >&2
    USE_LOGGER=0
fi
LOGGER_PARAMS="-t `basename $0`[${$}] -p user.notice"
IDNCMD=`which idn`
if [ $USE_IDN = "1" -a $? -ne 0 ]; then
    echo " Error! Idn doesn't exists" >&2
    USE_IDN=0
fi
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
### Источники списка блокировок
BLLIST_URL1_BASE="http://api.antizapret.info"
BLLIST_URL1_IP="${BLLIST_URL1_BASE}/group.php?data=ip"
BLLIST_URL1_FQDN="${BLLIST_URL1_BASE}/group.php?data=domain"
BLLIST_URL1_ALL="${BLLIST_URL1_BASE}/all.php?type=csv"
BLLIST_URL2="http://reestr.rublacklist.net/api/current"

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

DlRun () {

    local _return_code

    $WGETCMD $WGET_PARAMS "$1"
    _return_code=$?
    [ $_return_code -ne 0 ] && MakeLogRecord "Download error! Wget returns error code: ${_return_code}"

}

GetAntizapret () {

    local _url

    case $BLOCK_MODE in
        2)
            _url="$BLLIST_URL1_FQDN"
        ;;
        *)
            _url="$BLLIST_URL1_IP"
        ;;
    esac

    DlRun "$_url"

}

GetRublacklist () {

    DlRun "$BLLIST_URL2"

}

MakeDataFiles () {

    local _return_code

    ### Создание $IP_DATA и $DNSMASQ_DATA

    $AWKCMD -F "[;,|]" -v IDNCMD="$IDNCMD" -v LOGGERCMD="$LOGGERCMD" -v LOGGER_PARAMS="$LOGGER_PARAMS" '
        BEGIN {
            ### Добавление пользовательских записей из $INCLUDE_ENTRIES
            if(length(ENVIRON["INCLUDE_ENTRIES"]) > 0) {
                split(ENVIRON["INCLUDE_ENTRIES"], in_entrs_array, " ");
                for(m in in_entrs_array) {
                    if(in_entrs_array[m] ~ /^[0-9]{1,3}([.][0-9]{1,3}){3}$/)
                        total_ip_array[in_entrs_array[m]]="";
                    else if(in_entrs_array[m] ~ /^[0-9]{1,3}([.][0-9]{1,3}){3}[\057][0-9]{1,2}$/)
                        total_cidr_array[in_entrs_array[m]]="";
                    else if(in_entrs_array[m] ~ /^[a-z0-9.\052-]+[.]([a-z]{2,}|xn--[a-z0-9]+)$/)
                        total_fqdn_array[in_entrs_array[m]]="";
                };
            };
            ### Массивы из констант с исключениями
            makeConstArray(ENVIRON["EXCLUDE_ENTRIES"], ex_entrs_array, " ");
            makeConstArray(ENVIRON["OPT_EXCLUDE_SLD"], ex_sld_array, " ");
            total_ip=0; total_cidr=0; total_fqdn=0;
            ### Определение разделителя записей (строк)
            if(ENVIRON["BL_UPDATE_MODE"] == "2")
                RS="\134";
            else
                RS="[ \n]";
        }
        ### Массивы из констант
        function makeConstArray(string, array, separator,  _split_array, _i) {
            split(string, _split_array, separator);
            for(_i in _split_array)
                array[_split_array[_i]]="";
        };
        ### Проверка на повторы и добавление элемента в массив
        function checkDuplicates(array, val) {
            if(val in array) return 1;
            else {
                array[val]="";
                return 0;
            };
        };
        ### Получение SLD из доменов низших уровней
        function getSld(val) {
            return substr(val, match(val, /[a-z0-9-]+[.][a-z0-9-]+$/));
        };
        ### Запись в $DNSMASQ_DATA
        function writeDNSData(val) {
            if(ENVIRON["ALT_NSLOOKUP"] == 1)
                printf "server=/%s/%s\n", val, ENVIRON["ALT_DNS_ADDR"] > ENVIRON["DNSMASQ_DATA"];
            printf "ipset=/%s/%s\n", val, ENVIRON["IPSET_DNSMASQ"] > ENVIRON["DNSMASQ_DATA"];
        };
        ### Обработка ip и CIDR
        function checkIp(array1, array2, fqdn,  _i) {
            for(_i in array1) {
                if(_i in ex_entrs_array) continue;
                ### Если запись реестра содержит FQDN и $BLOCK_MODE=2, то все ip-адреса соответствующие этому FQDN удаляются из дальнейшей обработки (для исключения дублирующих элементов ipset в дальнейшем)
                if(ENVIRON["BLOCK_MODE"] == "2" && fqdn > 0) {
                    checkDuplicates(ex_ip_array, _i);
                    if(_i in array2) delete array2[_i];
                }
                else if(!(_i in ex_ip_array))
                    checkDuplicates(array2, _i);
            };
        };
        ### Обработка FQDN
        function checkFQDN(array1, array2, cyr,  _i, _sld, _call_idn) {
             for(_i in array1) {
                sub(/^[\052][.]/, "", _i);
                if(ENVIRON["STRIP_WWW"] == "1") sub(/^www[.]/, "", _i);
                if(_i in ex_entrs_array) continue;
                if(cyr == 1) {
                    ### Кириллические FQDN кодируются $IDNCMD в punycode ($AWKCMD вызывает $IDNCMD с параметром _i, в отдельном экземпляре /bin/sh, далее STDOUT $IDNCMD функцей getline помещается в _i)
                    _call_idn=IDNCMD" "_i;
                    _call_idn | getline _i;
                    close(_call_idn);
                }
                ### Проверка на отсутствие лишних символов и повторы
                if(_i ~ /^[a-z0-9.-]+$/ && checkDuplicates(array2, _i) == 0) {
                    ### Выбор записей SLD
                    if(_i ~ /^[a-z0-9-]+[.][a-z0-9-]+$/)
                        ### Каждому SLD задается предельный лимит, чтобы далее исключить из очистки при сравнении с $SD_LIMIT
                        sld_array[_i]=ENVIRON["SD_LIMIT"];
                    else {
                    ### Обработка остальных записей низших ур-ней
                        ### Пропуск доменов 3-го ур-ня вида: subdomain.xx(x).xx
                        if(ENVIRON["OPT_EXCLUDE_3LD_REGEXP"] == "1" && _i ~ /[.][a-z]{2,3}[.][a-z]{2}$/)
                            next;
                        _sld=getSld(_i);
                        ### Исключение доменов не подлежащих оптимизации
                        if(_sld in ex_sld_array) next;
                        ### Если SLD (полученный из записи низшего ур-ня) уже обрабатывался ранее, то счетчик++, если нет, то добавляется элемент sld_array[SLD] и счетчик=1 (далее, если после обработки всех записей, счетчик >= $SD_LIMIT, то в итоговом выводе остается только запись SLD, а все записи низших ур-ней будут удалены)
                        if(_sld in sld_array) sld_array[_sld]++;
                        else sld_array[_sld]=1;
                    };
                };
            };
        };
        ### Запись в $IP_DATA
        function writeIpsetEntries(array, set, counter,  _i) {
            for(_i in array) {
                printf "add %s %s\n", set, _i > ENVIRON["IP_DATA"];
                counter++;
            };
            return counter;
        };
        (ENVIRON["BL_UPDATE_MODE"] != "2") || ($0 ~ /^n/) {
            ip=0; cidr=0; fqdn=0; fqdn_cyr=0;
            ### Удаление массивов с элементами предыдущей записи (строки)
            delete ip_array; delete cidr_array; delete fqdn_array; delete fqdn_cyr_array;
            ### Перебор полей в текущей записи (строке)
            for(i = 1; i <= NF; i++) {
                ### Отбор ip в ip_array ([ n]? и [ ]? в выражении - костыль для разбора полей с rublacklist.net, gsub удаляет этот мусор)
                if($i ~ /^[ n]?[0-9]{1,3}([.][0-9]{1,3}){3}[ ]?$/) {
                    gsub(/[ n]/, "", $i);
                    ip_array[$i]="";
                    ip++;
                }
                ### Отбор CIDR в cidr_array
                else if($i ~ /^[ n]?[0-9]{1,3}([.][0-9]{1,3}){3}[\057][0-9]{1,2}[ ]?$/) {
                    gsub(/[ n]/, "", $i);
                    cidr_array[$i]="";
                    cidr++;
                }
                ### Отбор FQDN в fqdn_array
                else if($i ~ /^[a-z0-9.\052-]+[.]([a-z]{2,}|xn--[a-z0-9]+)$/) {
                    fqdn_array[$i]="";
                    fqdn++;
                }
                ### Отбор кириллических FQDN в fqdn_cyr_array
                else if(ENVIRON["USE_IDN"] == "1" && $i ~ /^[^a-zA-Z.]+[.]([a-z]|[^a-z]){2,}$/) {
                    fqdn_cyr_array[$i]="";
                    fqdn_cyr++;
                };
            };
            ### В случае, если запись реестра не содержит FQDN, то, не смотря на $BLOCK_MODE=2, в $IP_DATA добавляются найденные в записи ip и CIDR-подсети (после проверки на повторы)
            if(ENVIRON["BLOCK_MODE"] == "2") {
                if(fqdn > 0)
                    checkFQDN(fqdn_array, total_fqdn_array, 0);
                if(fqdn_cyr > 0) {
                    checkFQDN(fqdn_cyr_array, total_fqdn_array, 1);
                };
            };
            if(ip > 0)
                checkIp(ip_array, total_ip_array, fqdn);
            if(cidr > 0)
                checkIp(cidr_array, total_cidr_array, fqdn);
        }
        END {
            ### Удаление $IP_DATA
            system("rm -f \"" ENVIRON["IP_DATA"] "\"");
            ### Запись в $IP_DATA ip-адресов и подсетей CIDR
            total_ip=writeIpsetEntries(total_ip_array, ENVIRON["IPSET_IP_TMP"], total_ip);
            total_cidr=writeIpsetEntries(total_cidr_array, ENVIRON["IPSET_CIDR_TMP"], total_cidr);
            ### Удаление $DNSMASQ_DATA
            system("rm -f \"" ENVIRON["DNSMASQ_DATA"] "\"");
            ### Оптимизация отобранных FQDN и запись в $DNSMASQ_DATA
            if(ENVIRON["BLOCK_MODE"] == "2") {
                ### Чистка sld_array[] от тех SLD, которые встречались при обработке менее $SD_LIMIT (остаются только достигнувшие $SD_LIMIT)
                if(ENVIRON["SD_LIMIT"] > 1) {
                    for(j in sld_array) {
                        if(sld_array[j] < ENVIRON["SD_LIMIT"])
                           delete sld_array[j];
                    };
                    ### Добавление SLD из sld_array[] в $DNSMASQ_DATA (вместо исключаемых далее субдоменов достигнувших $SD_LIMIT)
                    for(l in sld_array) {
                        total_fqdn++;
                        writeDNSData(l);
                    };
                };
                #### Запись из total_fqdn_array[] в $DNSMASQ_DATA с исключением всех SLD присутствующих в sld_array[] и их субдоменов (если ENVIRON["SD_LIMIT"] > 1)
                for(k in total_fqdn_array) {
                    if(ENVIRON["SD_LIMIT"] > 1 && getSld(k) in sld_array)
                        continue;
                    else {
                        total_fqdn++;
                        writeDNSData(k);
                    };
                };
            };
            ### STDOUT
            printf " %s ip, %s CIDR and %s FQDN entries added\n", total_ip, total_cidr, total_fqdn;
            ### Запись в $UPDATE_STATUS_FILE
            printf "%s %s %s", total_ip, total_cidr, total_fqdn > ENVIRON["UPDATE_STATUS_FILE"];
            ### Запись в лог
            if(ENVIRON["USE_LOGGER"] == 1)
                system(LOGGERCMD " " LOGGER_PARAMS " \"" total_ip " ip, " total_cidr " CIDR and " total_fqdn " FQDN entries added\"");
            ### Если кол-во обработанных записей менее $BLLIST_MIN_ENTRS, то код завершения 2
            if((total_ip + total_cidr + total_fqdn) < ENVIRON["BLLIST_MIN_ENTRS"]) exit 2;
            exit 0;
    }'

    _return_code=$?

    if [ $_return_code -eq 0 ]; then

        if [ "$PROXY_MODE" = "2" ]; then
            printf "\n" >> "$DNSMASQ_DATA"
        else
            ### Запись для .onion в $DNSMASQ_DATA
            printf "server=/onion/%s\nipset=/onion/%s\n" "${ONION_DNS_ADDR}" "${IPSET_ONION}" >> "$DNSMASQ_DATA"
        fi

    else
        return $_return_code
    fi

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

RunDataFiles () {

    local _return_code

    [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
    echo "$$" > "$UPDATE_PID_FILE"

    case $BL_UPDATE_MODE in
        2)
            GetRublacklist | MakeDataFiles
        ;;
        *)
            GetAntizapret | MakeDataFiles
        ;;
    esac

    _return_code=$?

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
        RunDataFiles

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
                echo " Error! Something going wrong" >&2
                MakeLogRecord "Error! Something going wrong"
                _return_code=1
            ;;
        esac

        printf " `date +%d.%m.%Y-%H:%M`\n" >> "$UPDATE_STATUS_FILE"

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

    if [ "$BLOCK_MODE" = "2" -a ! -f "$DNSMASQ_DATA" ] || [ "$BLOCK_MODE" != "2" -a ! -f "$IP_DATA" ]; then
        Update "update on start"
    else
        FillIpsets
    fi

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
                    <tr class=\"list\"><td align=\"left\">BL_UPDATE_MODE:</td><td align=\"left\">${BL_UPDATE_MODE}</td></tr>\n\
                    <tr class=\"list\"><td align=\"left\">BLOCK_MODE:</td><td align=\"left\">${BLOCK_MODE}</td></tr>\n\
                    <tr class=\"list\"><td align=\"left\">PROXY_MODE:</td><td align=\"left\">${PROXY_MODE}</td></tr>\n\
                    <tr class=\"list\"><td align=\"left\">DEF_TOTAL_PROXY:</td><td align=\"left\">${DEF_TOTAL_PROXY}</td></tr>\n" >> "$HTML_OUTPUT"
        else
            printf "\n \033[1m${NAME} status\033[m: \033[1;32mActive\033[m\n\n  BL_UPDATE_MODE: ${BL_UPDATE_MODE}\n  BLOCK_MODE: ${BLOCK_MODE}\n  PROXY_MODE: ${PROXY_MODE}\n  DEF_TOTAL_PROXY: ${DEF_TOTAL_PROXY}\n"
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
                    printf "%s", "<table class=\"info_table\"><tr class=\"infoarea\"><td align=\"left\">Match-set</td><td align=\"left\">Bytes</td></tr>" >> ENVIRON["HTML_OUTPUT"];
            }
            {
                if(NR > 2) {
                    match_set=(NR == 3 && $0 ~ ENVIRON["IPSET_TOTAL_PROXY"]) ? "\033[1;31m"ENVIRON["IPSET_TOTAL_PROXY"]" (Enabled!)\033[m" : $11;
                    match_set_html=(NR == 3 && $0 ~ ENVIRON["IPSET_TOTAL_PROXY"]) ? ENVIRON["IPSET_TOTAL_PROXY"]" (Enabled!)" : $11;
                    match_set_html_class=(NR == 3 && $0 ~ ENVIRON["IPSET_TOTAL_PROXY"]) ? " red" : "";
                    if(TYPE == "html")
                        printf "<tr class=\"infoarea%s\"><td align=\"left\">%s</td><td align=\"left\">%s</td></tr>\n", match_set_html_class, match_set_html, $2 >> ENVIRON["HTML_OUTPUT"];
                    else
                        printf "   Match-set:  %s\n   Bytes:  %s\n\n", match_set, $2;
                };
            }
            END {
                if(TYPE == "html")
                    printf "%s", "</table></div>" >> ENVIRON["HTML_OUTPUT"];
            }'

        if [ "$1" = "html" ]; then
            printf "<div class=\"main\"><span class=\"info_label\">Ip sets:</span>\
                    <table class=\"info_table\">\
                    <tr class=\"infoarea\"><td align=\"left\">Name</td><td align=\"left\">Size in memory</td><td align=\"left\">Number of entries</td></tr>" >> "$HTML_OUTPUT"
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
                        if(TYPE == "html")
                            printf "<td align=\"left\">%s</td>\n", $2 >> ENVIRON["HTML_OUTPUT"];
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
            RunDataFiles
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
