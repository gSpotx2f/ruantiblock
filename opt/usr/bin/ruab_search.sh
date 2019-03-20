#!/bin/sh

########################################################################
#
# Поиск записей в конфигах dnsmasq и ipset по шаблону
# Шаблон может быть подстрокой (поиск в любой позиции записи) или регулярным выражением POSIX
# Прим.:
#  ruab_search.sh "thepiratebay.org"    # FQDN
#  ruab_search.sh "abc"                 # произвольная подстрока в любой позиции записи
#  ruab_search.sh "^torrent"            # подстрока в начале записи
#  ruab_search.sh "/21$"                # подстрока в конце записи (подсети с маской /21)
#  ruab_search.sh "^195[.]154[.]"       # ip адреса 195.154.* ("." - спец символ рег.выражений, поэтому [.])
#  и т.п.
#
########################################################################

############################ Configuration #############################

#export PATH="${PATH}:/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin"
export PATH="/opt/bin:/opt/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export NAME="ruantiblock"
export LANG="en_US.UTF-8"
export LANGUAGE="en"

DATA_DIR="/opt/var/${NAME}"

### External config
CONFIG_FILE="/opt/etc/${NAME}/${NAME}.conf"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

AWK_CMD="awk"
export DNSMASQ_DATA_FILE="${DATA_DIR}/${NAME}.dnsmasq"
export IP_DATA_FILE="${DATA_DIR}/${NAME}.ip"

############################## Functions ###############################

Search () {
    $AWK_CMD -F "$2" -v FIELD="$3" -v PATTERN="$4" '($FIELD ~ PATTERN) {
        print $FIELD
    }' "$1"
}

############################# Run section ##############################

if [ -n "$1" ]; then
    printf "\n FQDN matches (${DNSMASQ_DATA_FILE}) :\n"
    Search "$DNSMASQ_DATA_FILE" "/" "2" "$1"
    printf "\n Ip matches (${IP_DATA_FILE}) :\n"
    Search "$IP_DATA_FILE" " " "3" "$1"
else
    echo " Usage: `basename ${0}` \"<pattern>\""
fi

exit 0
