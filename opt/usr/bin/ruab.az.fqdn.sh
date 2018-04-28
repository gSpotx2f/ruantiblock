#!/bin/sh

########################################################################
#
# FQDN
#
# Модуль для http://api.antizapret.info/group.php?data=domain
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
### Записи (ip, FQDN) исключаемые из списка блокировки (через пробел)
export EXCLUDE_ENTRIES="youtube.com"
### SLD не подлежащие оптимизации (через пробел)
export OPT_EXCLUDE_SLD="livejournal.com facebook.com vk.com blog.jp msk.ru net.ru org.ru net.ua com.ua org.ua co.uk"
### Не оптимизировать домены 3-го ур-ня вида: subdomain.xx(x).xx (.msk.ru .net.ru .org.ru .net.ua .com.ua .org.ua .co.uk и т.п.) (0 - off, 1 - on)
export OPT_EXCLUDE_3LD_REGEXP=0
### Лимит для субдоменов. При превышении, в список ${NAME}.dnsmasq будет добавлен весь домен 2-го ур-ня, вместо множества субдоменов
export SD_LIMIT=16
### Преобразование кириллических доменов в punycode
export USE_IDN=0

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
export IP_DATA="${DATA_DIR}/${NAME}.ip"
export IPSET_IP="${NAME}-ip"
export IPSET_IP_TMP="${IPSET_IP}-tmp"
export IPSET_DNSMASQ="${NAME}-dnsmasq"
export UPDATE_STATUS_FILE="${DATA_DIR}/update_status"
### Источник списка блокировок
BLLIST_URL="http://api.antizapret.info/group.php?data=domain"

############################# Run section ##############################

$WGETCMD $WGET_PARAMS "$BLLIST_URL" | $AWKCMD -v IDNCMD="$IDNCMD" '
    BEGIN {
        ### Массивы из констант с исключениями
        makeConstArray(ENVIRON["EXCLUDE_ENTRIES"], ex_entrs_array, " ");
        makeConstArray(ENVIRON["OPT_EXCLUDE_SLD"], ex_sld_array, " ");
        total_ip=0; total_fqdn=0;
    }
    ### Массивы из констант
    function makeConstArray(string, array, separator,  _split_array, _i) {
        split(string, _split_array, separator);
        for(_i in _split_array)
            array[_split_array[_i]]="";
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
    ### Запись в $IP_DATA
    function writeIpsetEntries(array, set,  _i) {
        for(_i in array)
            printf "add %s %s\n", set, _i > ENVIRON["IP_DATA"];
    };
    ### Обработка ip и CIDR
    function checkIp(val, array2, counter) {
        if(!(val in ex_entrs_array)) {
            array2[val]="";
            counter++;
        };
        return counter;
    };
    ### Обработка FQDN
    function checkFQDN(val, array, cyr,  _sld, _call_idn) {
        sub(/^[\052][.]/, "", val);
        if(ENVIRON["STRIP_WWW"] == "1") sub(/^www[.]/, "", val);
        if(val in ex_entrs_array) next;
        if(cyr == 1) {
            ### Кириллические FQDN кодируются $IDNCMD в punycode ($AWKCMD вызывает $IDNCMD с параметром val, в отдельном экземпляре /bin/sh, далее STDOUT $IDNCMD функцей getline помещается в val)
            _call_idn=IDNCMD" "val;
            _call_idn | getline val;
            close(_call_idn);
        }
        ### Проверка на отсутствие лишних символов и повторы
        if(val ~ /^[a-z0-9.-]+$/) {
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
                array[val]=_sld;
                ### Исключение доменов не подлежащих оптимизации
                if(_sld in ex_sld_array) next;
                ### Если SLD (полученный из записи низшего ур-ня) уже обрабатывался ранее, то счетчик++, если нет, то добавляется элемент sld_array[SLD] и счетчик=1 (далее, если после обработки всех записей, счетчик >= $SD_LIMIT, то в итоговом выводе остается только запись SLD, а все записи низших ур-ней будут удалены)
                if(_sld in sld_array) sld_array[_sld]++;
                else sld_array[_sld]=1;
            };
        };
    };
    {
        ### Отбор ip
        if($0 ~ /^[0-9]{1,3}([.][0-9]{1,3}){3}?$/)
            total_ip=checkIp($0, total_ip_array, total_ip);
        ### Отбор FQDN
        else if($0 ~ /^[a-z0-9.\052-]+[.]([a-z]{2,}|xn--[a-z0-9]+)$/) {
            checkFQDN($0, total_fqdn_array, 0);
            total_fqdn++;
        }
        ### Отбор кириллических FQDN
        else if(ENVIRON["USE_IDN"] == "1" && $0 ~ /^[^a-zA-Z.]+[.]([a-z]|[^a-z]){2,}$/) {
            checkFQDN($0, total_fqdn_array, 1);
            total_fqdn++;
        };
    }
    END {
        output_fqdn=0; exit_code=0;
        ### Если кол-во обработанных записей менее $BLLIST_MIN_ENTRS, то код завершения 2
        if((total_ip + total_fqdn) < ENVIRON["BLLIST_MIN_ENTRS"])
            exit_code=2;
        else {
            ### Запись в $IP_DATA
            system("rm -f \"" ENVIRON["IP_DATA"] "\"");
            writeIpsetEntries(total_ip_array, ENVIRON["IPSET_IP_TMP"]);
            ### Оптимизация отобранных FQDN и запись в $DNSMASQ_DATA
            system("rm -f \"" ENVIRON["DNSMASQ_DATA"] "\"");
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
                #print(total_fqdn_array[k])
                if(ENVIRON["SD_LIMIT"] > 1 && total_fqdn_array[k] in sld_array)
                    continue;
                else {
                    output_fqdn++;
                    writeDNSData(k);
                };
            };
        };
        ### Запись в $UPDATE_STATUS_FILE
        printf "%s %s %s", total_ip, "0", output_fqdn > ENVIRON["UPDATE_STATUS_FILE"];
        exit exit_code;
    }'

exit $?
