## ruantiblock




Подробно об установке и настройке: [https://github.com/gSpotx2f/ruantiblock/wiki](https://github.com/gSpotx2f/ruantiblock/wiki)

___________________


Описание.


ruantiblock - решение позволяющее использовать выборочную проксификацию (посредством tor либо VPN-соединения) для доступа к заблокированным ресурсам из блэклиста с сайтов antizapret.info или rublacklist.net. При этом доступ к остальным ресурсам осуществляется напрямую. Написано на shell, "по мотивам" статьи https://habrahabr.ru/post/270657. Включает в себя, помимо текстового парсера, функции управления правилами iptables и списками ipset. Можно включать и отключать в любой момент, не нуждается в перезагрузке роутера при обновлении блэклиста (принудительно перезапускает dnsmasq). Может работать как с tor, так и с VPN конфигурацией. Парсер написан на awk и не требует установки дополнительных пакетов. Из зависимостей только tor (если используется tor-конфигурация) и, опционально, idn для преобразования кириллических доменов в punycode.

___________________


Установка.


1. Установите idn и tor из репозитория Entware:

    opkg install idn tor tor-geoip


2. Скачайте ruantiblock.sh в /opt/usr/bin/ и выполните chmod:

    mkdir -p /opt/usr/bin

    wget --no-check-certificate -O /opt/usr/bin/ruantiblock.sh https://raw.githubusercontent.com/gSpotx2f/ruantiblock/master/opt/usr/bin/ruantiblock.sh

    chmod +x /opt/usr/bin/ruantiblock.sh


3. Скачайте S40ruantiblock в /opt/etc/init.d и выполните chmod:

    wget --no-check-certificate -O /opt/etc/init.d/S40ruantiblock https://raw.githubusercontent.com/gSpotx2f/ruantiblock/master/opt/etc/init.d/S40ruantiblock

    chmod +x /opt/etc/init.d/S40ruantiblock


4. Скачайте torrc в /opt/etc/tor/torrc и запустите tor:

    mv -f /opt/etc/tor/torrc /opt/etc/tor/torrc.default

    wget --no-check-certificate -O /opt/etc/tor/torrc https://raw.githubusercontent.com/gSpotx2f/ruantiblock/master/opt/etc/tor/torrc

    /opt/etc/init.d/S35tor start

   В файле /opt/etc/tor/torrc в параметре "TransListenAddress 192.168.0.1" ip-адрес LAN интерфейса роутера должен быть актуальным.

___________________


Настройка прошивки.


1. В /etc/storage/started_script.sh раскомментируйте следующие строки:

    modprobe ip_set

    modprobe ip_set_hash_ip

    modprobe ip_set_hash_net

    modprobe ip_set_list_set

    modprobe xt_set


2. В /etc/storage/post_iptables_script.sh добавьте следующие строки:

    RUAB="/opt/usr/bin/ruantiblock.sh"

    [ -f "$RUAB" ] && $RUAB renew-ipt


3. В /etc/storage/dnsmasq/dnsmasq.conf добавьте следующую строку:

    conf-file=/opt/var/ruantiblock/ruantiblock.dnsmasq


4. Также можно добавить задание для обновления в Cron (прим.: обновление списка каждые 5 дней в 05:00). В /etc/storage/cron/crontabs/admin добавьте следующую строку:

    0 5 */5 * * /opt/usr/bin/ruantiblock.sh update


5. Перезагрузите роутер или выполните в консоли:

    modprobe ip_set

    modprobe ip_set_hash_ip

    modprobe ip_set_hash_net

    modprobe ip_set_list_set

    modprobe xt_set

    /opt/etc/init.d/S35tor start

    /opt/etc/init.d/S40ruantiblock start

___________________


Установка во внутреннюю память роутера (для VPN-конфигурации).


1. Скачайте ruantiblock.sh в /etc/storage и выполните chmod:

    wget --no-check-certificate -O /etc/storage/ruantiblock.sh https://raw.githubusercontent.com/gSpotx2f/ruantiblock/master/opt/usr/bin/ruantiblock.sh

    chmod +x /etc/storage/ruantiblock.sh


2. В скрипте /etc/storage/ruantiblock.sh измените следующие переменные:

    USE_IDN=0

    USE_HTML_STATUS=0

    DATA_DIR="/tmp/var/${NAME}"

    INIT_SCRIPT="$0"


3. В /etc/storage/post_iptables_script.sh добавьте следующие строки:

    RUAB="/etc/storage/ruantiblock.sh"

    [ -f "$RUAB" ] && $RUAB renew-ipt


4. В /etc/storage/dnsmasq/dnsmasq.conf добавьте следующую строку:

    conf-file=/tmp/var/ruantiblock/ruantiblock.dnsmasq


5. В /etc/storage/started_script.sh добавьте следующие строки:

    mkdir -p /tmp/var/ruantiblock

    echo "" > /tmp/var/ruantiblock/ruantiblock.dnsmasq

    /etc/storage/ruantiblock.sh start

    /etc/storage/ruantiblock.sh update


6. Можно добавить задание для обновления в Cron (прим.: обновление списка каждые 5 дней в 05:00). В /etc/storage/cron/crontabs/admin добавьте следующую строку:

    0 5 */5 * * /etc/storage/ruantiblock.sh update


Также должен быть выполнен пункт 1 из раздела "Настройка прошивки" (раскомментировать строки с modprobe).

После установки не забудьте записать хранилище /etc/storage во флеш-память.

___________________


Параметры запуска.


    ruantiblock.sh start            # Включение ruantiblock. Создаются списки ipset, правила iptables и пр. При первом запуске выполняется обновление блэклиста.
    ruantiblock.sh stop             # Выключение ruantiblock. Очищаются все списки ipset, удаляются правила iptables. Трафик идет стандартным способом, tor или VPN не используется
    ruantiblock.sh destroy          # То же, что и stop + удаление всех списков ipset
    ruantiblock.sh restart          # Рестарт
    ruantiblock.sh update           # Обновление блэклиста и списков ipset
    ruantiblock.sh force-update     # Принудительное обновление блэклиста (может потребоваться в случае если предыдущее обновление выполнено некорректно или было прервано в процессе выполнения)
    ruantiblock.sh data-files       # Создание файлов ruantiblock.dnsmasq и ruantiblock.ip, без обновления сетевой конфигурации
    ruantiblock.sh total-proxy-on   # Включение режима полного прокси. Весь трафик всегда идёт через прокси (tor или VPN), списки блокировок не используются для фильтрации (работает при включенном ruantiblock)
    ruantiblock.sh total-proxy-off  # Выключение режима полного прокси (работает при включенном ruantiblock)
    ruantiblock.sh status           # Вывод текущего статуса, а также общей инфо (кол-во записей в списках ipset, дату последнего обновления и пр.)
    ruantiblock.sh status-html      # Обновление html-страницы статуса


После изменения конфигурации ruantiblock.sh необходимо обязательно выполнить удаление всех сетов и правил iptables, а также обновление (если оно не запустилось автоматически):

    ruantiblock.sh destroy
    ruantiblock.sh start
    ruantiblock.sh update
