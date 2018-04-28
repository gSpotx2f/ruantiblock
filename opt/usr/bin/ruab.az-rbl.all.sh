#!/bin/sh

########################################################################
#
# IP, FQDN, CIDR
#
# Модуль поддерживает следующие источники:
#  http://api.antizapret.info/group.php?data=ip
#  http://api.antizapret.info/all.php?type=csv
#  http://reestr.rublacklist.net/api/current
#
########################################################################

############################## Settings ################################

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
### SLD не подлежащие оптимизации (через пробел)
export OPT_EXCLUDE_SLD="livejournal.com facebook.com vk.com blog.jp msk.ru net.ru org.ru net.ua com.ua org.ua co.uk"
### Не оптимизировать домены 3-го ур-ня вида: subdomain.xx(x).xx (.msk.ru .net.ru .org.ru .net.ua .com.ua .org.ua .co.uk и т.п.) (0 - off, 1 - on)
export OPT_EXCLUDE_3LD_REGEXP=0
### Лимит для субдоменов. При превышении, в список ${NAME}.dnsmasq будет добавлен весь домен 2-го ур-ня, вместо множества субдоменов
export SD_LIMIT=16
### Преобразование кириллических доменов в punycode
export USE_IDN=0
### Тип обновления списка блокировок: 1 - antizapret.info, 2 - rublacklist.net
export BL_UPDATE_MODE=1
### Режим обхода блокировок: 1 - ip (если провайдер блокирует по ip), 2 - hybrid (если провайдер использует DPI, подмену DNS и пр.)
export BLOCK_MODE=2

############################ Configuration #############################

export PATH="${PATH}:/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin"
export NAME="ruantiblock"
export LANG="en_US.UTF-8"
### Необходим gawk. Ибо "облегчённый" mawk, похоже, не справляется с огромным кол-вом обрабатываемых записей и крашится с ошибками...
AWKCMD="awk"
WGETCMD=`which wget`
if [ $? -ne 0 ]; then
    echo " Error! Wget doesn't exists" >&2
    exit 1
fi
WGET_PARAMS="-T 60 -q -O -"
IDNCMD=`which idn`
if [ $USE_IDN = "1" -a $? -ne 0 ]; then
    echo " Idn doesn't exists" >&2
    USE_IDN=0
fi
DATA_DIR="/opt/var/${NAME}"
export DNSMASQ_DATA="${DATA_DIR}/${NAME}.dnsmasq"
export DNSMASQ_DATA_TMP="${DNSMASQ_DATA}.tmp"
export IP_DATA="${DATA_DIR}/${NAME}.ip"
export IP_DATA_TMP="${IP_DATA}.tmp"
export IPSET_IP="${NAME}-ip"
export IPSET_IP_TMP="${IPSET_IP}-tmp"
export IPSET_CIDR="${NAME}-cidr"
export IPSET_CIDR_TMP="${IPSET_CIDR}-tmp"
export IPSET_DNSMASQ="${NAME}-dnsmasq"
export UPDATE_STATUS_FILE="${DATA_DIR}/update_status"
### Источники списка блокировок
BLLIST_URL1_BASE="http://api.antizapret.info"
BLLIST_URL1_IP="${BLLIST_URL1_BASE}/group.php?data=ip"
BLLIST_URL1_ALL="${BLLIST_URL1_BASE}/all.php?type=csv"
BLLIST_URL2="http://reestr.rublacklist.net/api/current"
#BLLIST_URL2="http://api.reserve-rbl.ru/api/current"

############################## Functions ###############################

DlRun () {

    $WGETCMD $WGET_PARAMS "$1"

}

GetAntizapret () {

    local _url

    case $BLOCK_MODE in
        2)
            _url="$BLLIST_URL1_ALL"
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

    $AWKCMD -F ";" -v IDNCMD="$IDNCMD" '
        BEGIN {
            ### Массивы из констант с исключениями
            makeConstArray(ENVIRON["EXCLUDE_ENTRIES"], ex_entrs_array, " ");
            makeConstArray(ENVIRON["OPT_EXCLUDE_SLD"], ex_sld_array, " ");
            total_ip=0; total_cidr=0; total_fqdn=0;
            ### Определение разделителя записей (строк)
            if(ENVIRON["BL_UPDATE_MODE"] == "2")
                RS="\134";
            else
                RS="\n";
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
            return substr(val, match(val, /[a-z0-9_-]+[.][a-z0-9-]+$/));
        };
        ### Запись в $DNSMASQ_DATA
        function writeDNSData(val) {
            if(ENVIRON["ALT_NSLOOKUP"] == 1)
                printf "server=/%s/%s\n", val, ENVIRON["ALT_DNS_ADDR"] > ENVIRON["DNSMASQ_DATA"];
            printf "ipset=/%s/%s\n", val, ENVIRON["IPSET_DNSMASQ"] > ENVIRON["DNSMASQ_DATA"];
        };
        ### Обработка ip и CIDR
        function checkIp(val,  _val_array, _i) {
            split(val, _val_array, /[|,]/);
            for(_i in _val_array) {
                if(_val_array[_i] in ex_entrs_array) continue;
                if(_val_array[_i] ~ /^[0-9]{1,3}([.][0-9]{1,3}){3}[\057][0-9]{1,2}$/) {
                    if(checkDuplicates(total_cidr_array, _val_array[_i]) == 0)
                        total_cidr++;
                }
                else if(_val_array[_i] ~ /^[0-9]{1,3}([.][0-9]{1,3}){3}$/) {
                    if(checkDuplicates(total_ip_array, _val_array[_i]) == 0)
                        total_ip++;
                };
            };
            return counter;
        };
        ### Обработка FQDN
        function checkFQDN(val,  _sld, _call_idn) {
            sub(/^[\052][.]/, "", val);
            if(ENVIRON["STRIP_WWW"] == "1") sub(/^www[.]/, "", val);
            if(val in ex_entrs_array) next;
            if(ENVIRON["USE_IDN"] == "1" && val !~ /^[a-z0-9._-]+[.]([a-z]{2,}|xn--[a-z0-9]+)$/ && val ~ /^([a-z0-9.-])*[^a-zA-Z.]+[.]([a-z]|[^a-z]){2,}$/) {
                ### Кириллические FQDN кодируются $IDNCMD в punycode ($AWKCMD вызывает $IDNCMD с параметром val, в отдельном экземпляре /bin/sh, далее STDOUT $IDNCMD функцей getline помещается в val)
                _call_idn=IDNCMD" "val;
                _call_idn | getline val;
                close(_call_idn);
            }
            ### Проверка на отсутствие лишних символов
            if(val ~ /^[a-z0-9._-]+[.]([a-z]{2,}|xn--[a-z0-9]+)$/) {
                total_fqdn++;
                ### SLD из FQDN
                _sld=getSld(val);
                ### Каждому SLD задается предельный лимит, чтобы далее исключить из очистки при сравнении с $SD_LIMIT
                if(val == _sld)
                    sld_array[val]=ENVIRON["SD_LIMIT"];
                else {
                ### Обработка остальных записей низших ур-ней
                    ### Пропуск доменов 3-го ур-ня вида: subdomain.xx(x).xx
                    if(ENVIRON["OPT_EXCLUDE_3LD_REGEXP"] == "1" && val ~ /[.][a-z]{2,3}[.][a-z]{2}$/)
                        next;
                    total_fqdn_array[val]=_sld;
                    ### Исключение доменов не подлежащих оптимизации
                    if(_sld in ex_sld_array) next;
                    ### Если SLD (полученный из записи низшего ур-ня) уже обрабатывался ранее, то счетчик++, если нет, то добавляется элемент sld_array[SLD] и счетчик=1 (далее, если после обработки всех записей, счетчик >= $SD_LIMIT, то в итоговом выводе остается только запись SLD, а все записи низших ур-ней будут удалены)
                    if(_sld in sld_array) sld_array[_sld]++;
                    else sld_array[_sld]=1;
                };
            };
        };
        ### Запись в $IP_DATA
        function writeIpsetEntries(array, set,  _i) {
            for(_i in array)
                printf "add %s %s\n", set, _i > ENVIRON["IP_DATA"];
        };
        (ENVIRON["BL_UPDATE_MODE"] != "2") || ($0 ~ /^n/) {
            ip_string=""; fqdn_string="";
            gsub("&amp;", "", $0)
            split($0, string_array, ";")
            if(ENVIRON["BL_UPDATE_MODE"] == 2) {
                ip_string=string_array[1];
                fqdn_string=string_array[2];
                gsub(/[ n]/, "", ip_string);
            }
            else {
                if(ENVIRON["BLOCK_MODE"] == "2") {
                    ip_string=string_array[4];
                    fqdn_string=string_array[3];
                }
                else
                    ip_string=string_array[1];
            };
            ### В случае, если запись реестра не содержит FQDN, то, не смотря на $BLOCK_MODE=2, в $IP_DATA добавляются найденные в записи ip и CIDR-подсети (после проверки на повторы)
            if(ENVIRON["BLOCK_MODE"] == "2") {
                if(length(fqdn_string) > 0 && fqdn_string !~ /^[0-9]{1,3}([.][0-9]{1,3}){3}$/) {
                    sub(/[.]$/, "", fqdn_string);
                    checkFQDN(fqdn_string);
                }
                else if(length(ip_string) > 0) {
                    checkIp(ip_string);
                };
            }
            else if(length(ip_string) > 0) {
                checkIp(ip_string);
            };
            ### Удаление массива с полями текущей записи
            delete string_array;
        }
        END {
            output_fqdn=0; exit_code=0;
            ### Если кол-во обработанных записей менее $BLLIST_MIN_ENTRS, то код завершения 2
            if((total_ip + total_cidr + total_fqdn) < ENVIRON["BLLIST_MIN_ENTRS"])
                exit_code=2;
            else {
                ### Запись в $IP_DATA ip-адресов и подсетей CIDR
                system("rm -f \"" ENVIRON["IP_DATA"] "\"");
                writeIpsetEntries(total_ip_array, ENVIRON["IPSET_IP_TMP"]);
                writeIpsetEntries(total_cidr_array, ENVIRON["IPSET_CIDR_TMP"]);
                ### Оптимизация отобранных FQDN и запись в $DNSMASQ_DATA
                system("rm -f \"" ENVIRON["DNSMASQ_DATA"] "\"");
                if(ENVIRON["BLOCK_MODE"] == "2") {
                    ### Чистка sld_array[] от тех SLD, которые встречались при обработке менее $SD_LIMIT (остаются только достигнувшие $SD_LIMIT) и добавление их в $DNSMASQ_DATA (вместо исключаемых далее субдоменов достигнувших $SD_LIMIT)
                    if(ENVIRON["SD_LIMIT"] > 1) {
                        for(j in sld_array) {
                            if(sld_array[j] < ENVIRON["SD_LIMIT"])
                                delete sld_array[j];
                            else {
                                output_fqdn++;
                                writeDNSData(j);
                            };
                        };
                    };
                    ### Запись из total_fqdn_array[] в $DNSMASQ_DATA с исключением всех SLD присутствующих в sld_array[] и их субдоменов (если ENVIRON["SD_LIMIT"] > 1)
                    for(k in total_fqdn_array) {
                        if(ENVIRON["SD_LIMIT"] > 1 && total_fqdn_array[k] in sld_array)
                            continue;
                        else {
                            output_fqdn++;
                            writeDNSData(k);
                        };
                    };
                };
            };
            ### Запись в $UPDATE_STATUS_FILE
            printf "%s %s %s", total_ip, total_cidr, output_fqdn > ENVIRON["UPDATE_STATUS_FILE"];
            exit exit_code;
        }'

    return $?

}

############################# Run section ##############################

case $BL_UPDATE_MODE in
    2)
        GetRublacklist | MakeDataFiles
    ;;
    *)
        GetAntizapret | MakeDataFiles
    ;;
esac

exit $?
