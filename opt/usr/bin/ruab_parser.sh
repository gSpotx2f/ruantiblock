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
### Перекодировка данных для источников с кодировкой отличной от UTF-8 (0 - off, 1 - on)
export USE_ICONV=0
### SLD не подлежащие оптимизации (через пробел)
export OPT_EXCLUDE_SLD="livejournal.com facebook.com vk.com blog.jp msk.ru net.ru org.ru net.ua com.ua org.ua co.uk amazonaws.com"
### Не оптимизировать SLD попадающие под выражения (через пробел)
export OPT_EXCLUDE_MASKS=""     # "[.][a-z]{2,3}[.][a-z]{2}$"
### Фильтрация записей блэклиста по шаблонам из файла ENTRIES_FILTER_FILE. Записи (ip, CIDR, FQDN) попадающие под шаблоны исключаются из кофигов ipset и dnsmasq (0 - off, 1 - on)
export ENTRIES_FILTER=1
### Файл с шаблонами для опции ENTRIES_FILTER (каждый шаблон в отдельной строке. # в первом символе строки - комментирует строку)
export ENTRIES_FILTER_FILE="/opt/etc/ruantiblock/ruab_entries_filter"
### Стандартные шаблоны для опции ENTRIES_FILTER (через пробел). Добавляются к шаблонам из файла ENTRIES_FILTER_FILE (также применяются при отсутствии ENTRIES_FILTER_FILE)
export ENTRIES_FILTER_PATTERNS="^youtube[.]com"
### Лимит для субдоменов. При достижении, в конфиг dnsmasq будет добавлен весь домен 2-го ур-ня вместо множества субдоменов (0 - off)
export SD_LIMIT=16
### Лимит ip адресов. При достижении, в конфиг ipset будет добавлена вся подсеть /24 вместо множества ip-адресов пренадлежащих этой сети (0 - off)
export IP_LIMIT=0
### Подсети класса C (/24). Ip-адреса из этих подсетей не группируются при оптимизации (записи д.б. в виде: 68.183.221. 149.154.162. и пр.). Прим.: OPT_EXCLUDE_NETS="68.183.221. 149.154.162."
export OPT_EXCLUDE_NETS=""
### В случае если из источника получено менее указанного кол-ва записей, то обновления списков не происходит
export BLLIST_MIN_ENTRS=30000
### Обрезка www[0-9]. в FQDN (0 - off, 1 - on)
export STRIP_WWW=1

############################ Configuration #############################

#export PATH="${PATH}:/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin"
export PATH="/opt/bin:/opt/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export NAME="ruantiblock"
export LANG="en_US.UTF-8"
export LANGUAGE="en"
export ENCODING="UTF-8"

DATA_DIR="/opt/var/${NAME}"

### Источники блэклиста
AZ_ALL_URL="http://api.antizapret.info/all.php?type=csv"
AZ_IP_URL="http://api.antizapret.info/group.php?data=ip"
AZ_FQDN_URL="http://api.antizapret.info/group.php?data=domain"
#RBL_ALL_URL="http://reestr.rublacklist.net/api/current"
RBL_ALL_URL="http://api.reserve-rbl.ru/api/current"
ZI_ALL_URL="https://raw.githubusercontent.com/zapret-info/z-i/master/dump.csv"
AZ_ENCODING=""
RBL_ENCODING=""
ZI_ENCODING="CP1251"

### External config
CONFIG_FILE="/opt/etc/${NAME}/${NAME}.conf"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

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
ICONV_CMD=`which iconv`
if [ $USE_ICONV = "1" -a $? -ne 0 ]; then
    echo " Iconv doesn't exists" >&2
    USE_ICONV=0
fi
export DNSMASQ_DATA_FILE="${DATA_DIR}/${NAME}.dnsmasq"
export IP_DATA_FILE="${DATA_DIR}/${NAME}.ip"
export IPSET_IP="${NAME}-ip"
export IPSET_IP_TMP="${IPSET_IP}-tmp"
export IPSET_CIDR="${NAME}-cidr"
export IPSET_CIDR_TMP="${IPSET_CIDR}-tmp"
export IPSET_DNSMASQ="${NAME}-dnsmasq"
export UPDATE_STATUS_FILE="${DATA_DIR}/update_status"

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

ConvertEncoding () {
    if [ "$USE_ICONV" = "1" -a -n "$1" ]; then
        $ICONV_CMD -f "$1" -t "$ENCODING"
    else
        cat -
    fi
}

MakeDataFiles () {
    local _return_code
    $AWK_CMD -F ";" -v IDN_CMD="$IDN_CMD" -v ENTRIES_FILTER_FILE="$ENTRIES_FILTER_FILE" '
        BEGIN {
            ### Коды unicode для кириллицы
            cyr_array["0430"]="а"; cyr_array["0431"]="б"; cyr_array["0432"]="в"; cyr_array["0433"]="г"; cyr_array["0434"]="д"; cyr_array["0435"]="е"; cyr_array["0451"]="ё"; cyr_array["0436"]="ж"; cyr_array["0437"]="з"; cyr_array["0438"]="и"; cyr_array["0439"]="й"; cyr_array["043a"]="к"; cyr_array["043b"]="л"; cyr_array["043c"]="м"; cyr_array["043d"]="н"; cyr_array["043e"]="о"; cyr_array["043f"]="п"; cyr_array["0440"]="р"; cyr_array["0441"]="с"; cyr_array["0442"]="т"; cyr_array["0443"]="у"; cyr_array["0444"]="ф"; cyr_array["0445"]="х"; cyr_array["0446"]="ц"; cyr_array["0447"]="ч"; cyr_array["0448"]="ш"; cyr_array["0449"]="щ"; cyr_array["044a"]="ъ"; cyr_array["044b"]="ы"; cyr_array["044c"]="ь"; cyr_array["044d"]="э"; cyr_array["044e"]="ю"; cyr_array["044f"]="я";
            #cyr_array["0410"]="А"; cyr_array["0411"]="Б"; cyr_array["0412"]="В"; cyr_array["0413"]="Г"; cyr_array["0414"]="Д"; cyr_array["0415"]="Е"; cyr_array["0401"]="Ё"; cyr_array["0416"]="Ж"; cyr_array["0417"]="З"; cyr_array["0418"]="И"; cyr_array["0419"]="Й"; cyr_array["041a"]="К"; cyr_array["041b"]="Л"; cyr_array["041c"]="М"; cyr_array["041d"]="Н"; cyr_array["041e"]="О"; cyr_array["041f"]="П"; cyr_array["0420"]="Р"; cyr_array["0421"]="С"; cyr_array["0422"]="Т"; cyr_array["0423"]="У"; cyr_array["0424"]="Ф"; cyr_array["0425"]="Х"; cyr_array["0426"]="Ц"; cyr_array["0427"]="Ч"; cyr_array["0428"]="Ш"; cyr_array["0429"]="Щ"; cyr_array["042a"]="Ъ"; cyr_array["042b"]="Ы"; cyr_array["042c"]="Ь"; cyr_array["042d"]="Э"; cyr_array["042e"]="Ю"; cyr_array["042f"]="Я";
            ### Массивы из констант с исключениями
            makeConstArray(ENVIRON["OPT_EXCLUDE_MASKS"], ex_masks_array, " ");
            makeConstArray(ENVIRON["OPT_EXCLUDE_SLD"], ex_sld_array, " ");
            makeConstArray(ENVIRON["ENTRIES_FILTER_PATTERNS"], remove_patterns_array, " ");
            makeConstArray(ENVIRON["OPT_EXCLUDE_NETS"], ex_nets_array, " ");
            ### Массив шаблонов из $ENTRIES_FILTER_FILE
            null="";
            if(ENVIRON["ENTRIES_FILTER"] == 1) {
                pattern="";
                while((getline pattern <ENTRIES_FILTER_FILE) > 0){
                    if(pattern ~ /^[^#]/)
                        remove_patterns_array[pattern]=null;
                };
                close(ENTRIES_FILTER_FILE);
            };
            total_ip=0; total_cidr=0; total_fqdn=0;
        }
        ### Массивы из констант
        function makeConstArray(string, array, separator,  _split_array, _i) {
            split(string, _split_array, separator);
            for(_i in _split_array)
                array[_split_array[_i]]=null;
        };
        ### Проверка по массиву рег.выражений
        function checkExpr(val, array) {
            if(ENVIRON["ENTRIES_FILTER"] == 1) {
                for(pattern in array) {
                    if(val ~ pattern)
                        return 1;
                };
                return 0;
            };
        };
        ### Буквы кириллицы из hex юникода
        function hexToUnicode(val, _i) {
            for(_i in cyr_array)
                gsub("\134\134u"_i, cyr_array[_i], val);
            return val;
        };
        ### SLD из доменов высших уровней
        function getSld(val) {
            return substr(val, match(val, /[a-z0-9_-]+[.][a-z0-9-]+$/));
        };
        ### Подсеть из ip
        function getSubnet(val) {
            sub(/[0-9]{1,3}$/, "", val);
            return val
        };
        ### Обработка ip и CIDR
        function checkIp(val,  _val_array, _i, _ip_entry, _subnet) {
            split(val, _val_array, /[|,]/);
            for(_i in _val_array) {
                _ip_entry=_val_array[_i]
                if(checkExpr(_ip_entry, remove_patterns_array) == 1) continue;
                if(_ip_entry ~ /^[0-9]{1,3}([.][0-9]{1,3}){3}[\057][0-9]{1,2}$/ && !(_ip_entry in total_cidr_array)) {
                    total_cidr_array[_ip_entry]=null;
                    total_cidr++;
                }
                else if(_ip_entry ~ /^[0-9]{1,3}([.][0-9]{1,3}){3}$/ && !(_ip_entry in total_ip_array)) {
                    _subnet=getSubnet(_ip_entry);
                    if(_subnet in ex_nets_array || ENVIRON["IP_LIMIT"] == 0 || (subnet_array[_subnet] < ENVIRON["IP_LIMIT"])) {
                        if(_subnet in subnet_array) subnet_array[_subnet]++;
                        else subnet_array[_subnet]=1;
                        total_ip_array[_ip_entry]=_subnet;
                        total_ip++;
                    };
                };
            };
            return counter;
        };
        ### Обработка FQDN
        function checkFQDN(val,  _sld, _call_idn) {
            sub(/[.]$/, "", val);
            sub(/^[\052][.]/, "", val);
            if(ENVIRON["STRIP_WWW"] == "1") sub(/^www[0-9]?[.]/, "", val);
            if(ENVIRON["USE_IDN"] == "1" && val !~ /^[a-z0-9._-]+[.]([a-z]{2,}|xn--[a-z0-9]+)$/ && val ~ /^([a-z0-9.-])*[^a-zA-Z.]+[.]([a-z]|[^a-z]){2,}$/) {
                ### Кириллические FQDN кодируются $IDN_CMD в punycode ($AWK_CMD вызывает $IDN_CMD с параметром val, в отдельном экземпляре /bin/sh, далее STDOUT $IDN_CMD функцей getline помещается в val)
                _call_idn=IDN_CMD" "val;
                _call_idn | getline val;
                close(_call_idn);
            };
            if(checkExpr(val, remove_patterns_array) == 1) next;
            ### Проверка на лишние символы
            if(val ~ /^[a-z0-9._-]+[.]([a-z]{2,}|xn--[a-z0-9]+)$/) {
                total_fqdn++;
                ### SLD из FQDN
                _sld=getSld(val);
                if(_sld in ex_sld_array || (ENVIRON["SD_LIMIT"] == 0 || (sld_array[_sld] < ENVIRON["SD_LIMIT"]))) {
                    ### Исключение доменов совпадающих с выражениями из $OPT_EXCLUDE_MASKS
                    if(length(ex_masks_array) > 0 && checkExpr(val, ex_masks_array) == 1) next;
                    total_fqdn_array[val]=_sld;
                    ### Если SLD уже обрабатывался ранее, то счетчик++, если нет, то добавляется элемент sld_array[SLD] и счетчик=1 (далее, если после обработки всех записей, счетчик >= $SD_LIMIT, то в итоговом выводе остается только запись SLD вместо записей высших ур-ней)
                    if(_sld in sld_array) sld_array[_sld]++;
                    else sld_array[_sld]=1;
                };
            };
        };
        {
            ip_string=""; fqdn_string="";
            split($0, string_array, ";")
            if(ENVIRON["BL_UPDATE_MODE"] == "rublacklist" || ENVIRON["BL_UPDATE_MODE"] == "zapret-info") {
                ip_string=string_array[1];
                fqdn_string=string_array[2];
                gsub(/[ n]/, "", ip_string);
                if(ENVIRON["BL_UPDATE_MODE"] == "rublacklist" && ENVIRON["USE_IDN"] == "1" && fqdn_string ~ /\134\134u[a-f0-9]{4}/)
                    fqdn_string=hexToUnicode(fqdn_string);
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
            ### В случае, если запись реестра не содержит FQDN, то при $BLOCK_MODE="hybrid" в $IP_DATA_FILE добавляются найденные в записи ip и CIDR-подсети
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
            output_fqdn=0; output_ip=0; exit_code=0;
            ### Если кол-во обработанных записей менее $BLLIST_MIN_ENTRS, то код завершения 2
            if((total_ip + total_cidr + total_fqdn) < ENVIRON["BLLIST_MIN_ENTRS"])
                exit_code=2;
            else {
                system("rm -f \"" ENVIRON["IP_DATA_FILE"] "\"");
                ### Оптимизация ip-адресов и запись в $IP_DATA_FILE
                for(ip in total_ip_array) {
                    subnet=total_ip_array[ip];
                    if(subnet in subnet_array) {
                        if(ENVIRON["IP_LIMIT"] > 0 && !(subnet in ex_nets_array) && (subnet_array[subnet] >= ENVIRON["IP_LIMIT"])) {
                            value=subnet"0/24";
                            ipset=ENVIRON["IPSET_CIDR_TMP"];
                            delete subnet_array[subnet];
                            total_cidr++;
                            delete total_cidr_array[value]
                        }
                        else {
                            value=ip;
                            ipset=ENVIRON["IPSET_IP_TMP"];
                            output_ip++;
                        };
                        printf "add %s %s\n", ipset, value > ENVIRON["IP_DATA_FILE"];
                    };
                };
                ### Запись в $IP_DATA_FILE подсетей CIDR
                for(_i in total_cidr_array)
                    printf "add %s %s\n", ENVIRON["IPSET_CIDR_TMP"], _i > ENVIRON["IP_DATA_FILE"];
                ### Оптимизация отобранных FQDN и запись в $DNSMASQ_DATA_FILE
                system("rm -f \"" ENVIRON["DNSMASQ_DATA_FILE"] "\"");
                if(ENVIRON["BLOCK_MODE"] == "hybrid" || ENVIRON["BLOCK_MODE"] == "fqdn") {
                    for(fqdn in total_fqdn_array) {
                        sld=total_fqdn_array[fqdn];
                        keyValue=fqdn;
                        if((!(sld in total_fqdn_array) || fqdn == sld) && sld in sld_array) {
                            if(ENVIRON["SD_LIMIT"] > 0 && !(sld in ex_sld_array) && (sld_array[sld] >= ENVIRON["SD_LIMIT"])) {
                                keyValue=sld;
                                delete sld_array[sld];
                            };
                            if(ENVIRON["ALT_NSLOOKUP"] == 1)
                                printf "server=/%s/%s\n", keyValue, ENVIRON["ALT_DNS_ADDR"] > ENVIRON["DNSMASQ_DATA_FILE"];
                            printf "ipset=/%s/%s\n", keyValue, ENVIRON["IPSET_DNSMASQ"] > ENVIRON["DNSMASQ_DATA_FILE"];
                            output_fqdn++;
                        };
                    };
                };
            };
            ### Запись в $UPDATE_STATUS_FILE
            printf "%s %s %s", output_ip, total_cidr, output_fqdn > ENVIRON["UPDATE_STATUS_FILE"];
            exit exit_code;
        }'
    return $?
}

############################# Run section ##############################

case $BL_UPDATE_MODE in
    "rublacklist")
        #GetRublacklist | ConvertEncoding "$RBL_ENCODING" | $AWK_CMD 'BEGIN {RS="\134"} {sub(/^n/, "\n", $0); printf "%s", RS$0}' | MakeDataFiles
        GetRublacklist | $AWK_CMD 'BEGIN {RS="\134"} {sub(/^n/, "\n", $0); printf "%s", RS$0}' | MakeDataFiles
    ;;
    "zapret-info")
        GetZapretinfo | ConvertEncoding "$ZI_ENCODING" | MakeDataFiles
    ;;
    *)
        #GetAntizapret | ConvertEncoding "$AZ_ENCODING" | MakeDataFiles
        GetAntizapret | MakeDataFiles
    ;;
esac

exit $?
