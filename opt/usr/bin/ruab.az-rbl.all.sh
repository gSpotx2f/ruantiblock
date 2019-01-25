#!/bin/sh

########################################################################
#
# IP, FQDN, CIDR
#
# Модуль поддерживает следующие источники:
#  http://api.antizapret.info/group.php?data=ip
#  http://api.antizapret.info/group.php?data=domain
#  http://api.antizapret.info/all.php?type=csv
#  http://api.reserve-rbl.ru/api/current
#  https://raw.githubusercontent.com/zapret-info/z-i/master/dump.csv
#
########################################################################

############################## Settings ################################

### Тип обновления списка блокировок (antizapret, rublacklist, zapret-info)
export BL_UPDATE_MODE="antizapret"
### Режим обхода блокировок: ip (если провайдер блокирует по ip), hybrid (если провайдер использует DPI, подмену DNS и пр.), fqdn (если провайдер использует DPI, подмену DNS и пр.)
export BLOCK_MODE="hybrid"
### Перенаправлять DNS-запросы на альтернативный DNS-сервер для заблокированных FQDN (или в tor если провайдер блокирует сторонние DNS-серверы) (0 - off, 1 - on)
export ALT_NSLOOKUP=1
### Альтернативный DNS-сервер ($ONION_DNS_ADDR в ruantiblock.sh (tor), 8.8.8.8 и др.). Если провайдер не блокирует сторонние DNS-запросы, то оптимальнее будет использовать для заблокированных сайтов, например, 8.8.8.8, а не резолвить через tor...
export ALT_DNS_ADDR="8.8.8.8"
### Преобразование кириллических доменов в punycode (0 - off, 1 - on)
export USE_IDN=0
### Записи (ip, CIDR, FQDN) исключаемые из списка блокировки (через пробел)
export EXCLUDE_ENTRIES="youtube.com"
### SLD не подлежащие оптимизации (через пробел)
export OPT_EXCLUDE_SLD="livejournal.com facebook.com vk.com blog.jp msk.ru net.ru org.ru net.ua com.ua org.ua co.uk amazonaws.com"
### Не оптимизировать SLD содержащие поддомены типа subdomain.xx(x).xx (.msk.ru .net.ru .org.ru .net.ua .com.ua .org.ua .co.uk и т.п.) (0 - off, 1 - on)
export OPT_EXCLUDE_3LD_REGEXP=0
### Лимит для субдоменов. При достижении, в конфиг dnsmasq будет добавлен весь домен 2-го ур-ня вместо множества субдоменов
export SD_LIMIT=16
### В случае если из источника получено менее указанного кол-ва записей, то обновления списков не происходит
export BLLIST_MIN_ENTRS=30000
### Обрезка www[0-9]. в FQDN (0 - off, 1 - on)
export STRIP_WWW=1

############################ Configuration #############################

export PATH="${PATH}:/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin"
export NAME="ruantiblock"
export LANG="en_US.UTF-8"
### Необходим gawk. Ибо "облегчённый" mawk, похоже, не справляется с огромным кол-вом обрабатываемых записей и крашится с ошибками...
AWK_CMD="awk"
WGET_CMD=`which wget`
if [ $? -ne 0 ]; then
    echo " Error! Wget doesn't exists" >&2
    exit 1
fi
WGET_PARAMS="--no-check-certificate -q -O -"
IDN_CMD=`which idn`
if [ $USE_IDN = "1" -a $? -ne 0 ]; then
    echo " Idn doesn't exists" >&2
    USE_IDN=0
fi
DATA_DIR="/opt/var/${NAME}"
export DNSMASQ_DATA_FILE="${DATA_DIR}/${NAME}.dnsmasq"
export IP_DATA_FILE="${DATA_DIR}/${NAME}.ip"
export IPSET_IP="${NAME}-ip"
export IPSET_IP_TMP="${IPSET_IP}-tmp"
export IPSET_CIDR="${NAME}-cidr"
export IPSET_CIDR_TMP="${IPSET_CIDR}-tmp"
export IPSET_DNSMASQ="${NAME}-dnsmasq"
export UPDATE_STATUS_FILE="${DATA_DIR}/update_status"
### Источники блэклиста
AZ_ALL_URL="http://api.antizapret.info/all.php?type=csv"
AZ_IP_URL="http://api.antizapret.info/group.php?data=ip"
AZ_FQDN_URL="http://api.antizapret.info/group.php?data=domain"
#RBL_ALL_URL="http://reestr.rublacklist.net/api/current"
RBL_ALL_URL="http://api.reserve-rbl.ru/api/current"
ZI_ALL_URL="https://raw.githubusercontent.com/zapret-info/z-i/master/dump.csv"

############################## Functions ###############################

DlRun () {
    $WGET_CMD $WGET_PARAMS "$1"
    if [ $? -ne 0 ]; then
        echo "Connection error (${1})" >&2
        exit 1
    fi
}

GetAntizapret () {
    local _url
    case $BLOCK_MODE in
        "fqdn")
            _url="$AZ_FQDN_URL"
        ;;
        "hybrid")
            _url="$AZ_ALL_URL"
        ;;
        *)
            _url="$AZ_IP_URL"
        ;;
    esac
    DlRun "$_url"
}

GetRublacklist () {
    DlRun "$RBL_ALL_URL"
}

GetZapretinfo () {
    DlRun "$ZI_ALL_URL"
}

MakeDataFiles () {
    local _return_code
    $AWK_CMD -F ";" -v IDN_CMD="$IDN_CMD" '
        BEGIN {
            ### Массивы из констант с исключениями
            makeConstArray(ENVIRON["EXCLUDE_ENTRIES"], ex_entrs_array, " ");
            makeConstArray(ENVIRON["OPT_EXCLUDE_SLD"], ex_sld_array, " ");
            total_ip=0; total_cidr=0; total_fqdn=0;
            ### Определение разделителя записей (строк)
            if(ENVIRON["BL_UPDATE_MODE"] == "rublacklist")
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
        ### Запись в $DNSMASQ_DATA_FILE
        function writeDNSData(val) {
            if(ENVIRON["ALT_NSLOOKUP"] == 1)
                printf "server=/%s/%s\n", val, ENVIRON["ALT_DNS_ADDR"] > ENVIRON["DNSMASQ_DATA_FILE"];
            printf "ipset=/%s/%s\n", val, ENVIRON["IPSET_DNSMASQ"] > ENVIRON["DNSMASQ_DATA_FILE"];
        };
        ### Запись в $IP_DATA_FILE
        function writeIpsetEntries(array, set,  _i) {
            for(_i in array)
                printf "add %s %s\n", set, _i > ENVIRON["IP_DATA_FILE"];
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
            sub(/[.]$/, "", val);
            sub(/^[\052][.]/, "", val);
            if(ENVIRON["STRIP_WWW"] == "1") sub(/^www[0-9]?[.]/, "", val);
            if(val in ex_entrs_array) next;
            if(ENVIRON["USE_IDN"] == "1" && val !~ /^[a-z0-9._-]+[.]([a-z]{2,}|xn--[a-z0-9]+)$/ && val ~ /^([a-z0-9.-])*[^a-zA-Z.]+[.]([a-z]|[^a-z]){2,}$/) {
                ### Кириллические FQDN кодируются $IDN_CMD в punycode ($AWK_CMD вызывает $IDN_CMD с параметром val, в отдельном экземпляре /bin/sh, далее STDOUT $IDN_CMD функцей getline помещается в val)
                _call_idn=IDN_CMD" "val;
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
        (ENVIRON["BL_UPDATE_MODE"] != "rublacklist") || ($0 ~ /^n/) {
            ip_string=""; fqdn_string="";
            split($0, string_array, ";")
            if(ENVIRON["BL_UPDATE_MODE"] == "rublacklist" || ENVIRON["BL_UPDATE_MODE"] == "zapret-info") {
                ip_string=string_array[1];
                fqdn_string=string_array[2];
                gsub(/[ n]/, "", ip_string);
            }
            else {
                if(ENVIRON["BLOCK_MODE"] == "hybrid") {
                    ip_string=string_array[length(string_array)];
                    fqdn_string=string_array[length(string_array)-1];
                }
                else if(ENVIRON["BLOCK_MODE"] == "fqdn") {
                    fqdn_string=string_array[1];
                }
                else
                    ip_string=string_array[1];
            };
            ### В случае, если запись реестра не содержит FQDN, то при $BLOCK_MODE="hybrid" в $IP_DATA_FILE добавляются найденные в записи ip и CIDR-подсети (после проверки на повторы)
            if(ENVIRON["BLOCK_MODE"] == "hybrid") {
                if(length(fqdn_string) > 0 && fqdn_string !~ /^[0-9]{1,3}([.][0-9]{1,3}){3}$/) {
                    checkFQDN(fqdn_string);
                }
                else if(length(ip_string) > 0)
                    checkIp(ip_string);
            }
            else if(ENVIRON["BLOCK_MODE"] == "fqdn") {
                if(length(fqdn_string) > 0) {
                    if(fqdn_string ~ /^[0-9]{1,3}([.][0-9]{1,3}){3}$/) {
                        checkIp(fqdn_string);
                    }
                    else {
                        checkFQDN(fqdn_string);
                    };
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
                ### Запись в $IP_DATA_FILE ip-адресов и подсетей CIDR
                system("rm -f \"" ENVIRON["IP_DATA_FILE"] "\"");
                writeIpsetEntries(total_ip_array, ENVIRON["IPSET_IP_TMP"]);
                writeIpsetEntries(total_cidr_array, ENVIRON["IPSET_CIDR_TMP"]);
                ### Оптимизация отобранных FQDN и запись в $DNSMASQ_DATA_FILE
                system("rm -f \"" ENVIRON["DNSMASQ_DATA_FILE"] "\"");
                if(ENVIRON["BLOCK_MODE"] == "hybrid" || ENVIRON["BLOCK_MODE"] == "fqdn") {
                    ### Чистка sld_array[] от тех SLD, которые встречались при обработке менее $SD_LIMIT (остаются только достигнувшие $SD_LIMIT) и добавление их в $DNSMASQ_DATA_FILE (вместо исключаемых далее субдоменов достигнувших $SD_LIMIT)
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
                    ### Запись из total_fqdn_array[] в $DNSMASQ_DATA_FILE с исключением всех SLD присутствующих в sld_array[] и их субдоменов (если ENVIRON["SD_LIMIT"] > 1)
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
    "rublacklist")
        GetRublacklist | MakeDataFiles
    ;;
    "zapret-info")
        GetZapretinfo | MakeDataFiles
    ;;
    *)
        GetAntizapret | MakeDataFiles
    ;;
esac

exit $?
