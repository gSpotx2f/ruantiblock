"""Модуль-парсер для ruantiblock

Поддерживает следующие источники:
    https://api.antizapret.info/all.php?type=csv
    https://api.antizapret.info/group.php?data=ip
    https://api.antizapret.info/group.php?data=domain
    https://reestr.rublacklist.net/api/v2/current/csv
    https://reestr.rublacklist.net/api/v2/ips/csv
    https://reestr.rublacklist.net/api/v2/domains/json
    https://raw.githubusercontent.com/zapret-info/z-i/master/dump.csv

Python >= 3.6
"""

from contextlib import contextmanager
import os
import re
import socket
import ssl
import sys
from urllib import request


NAME = "ruantiblock"
CONFIG_FILE = "/opt/etc/ruantiblock/ruantiblock.conf"


class Config:
    ### Тип обновления списка блокировок (antizapret, rublacklist, zapret-info)
    BL_UPDATE_MODE = "rublacklist"
    ### Режим обхода блокировок: ip (если провайдер блокирует по ip), hybrid (если провайдер использует DPI, подмену DNS и пр.), fqdn (если провайдер использует DPI, подмену DNS и пр.)
    BLOCK_MODE = "hybrid"
    ### Перенаправлять DNS-запросы на альтернативный DNS-сервер для заблокированных FQDN (или в tor если провайдер блокирует сторонние DNS-серверы) (0 - off, 1 - on)
    ALT_NSLOOKUP = 1
    ### Альтернативный DNS-сервер ($ONION_DNS_ADDR в ruantiblock.sh (tor), 8.8.8.8 и др.). Если провайдер не блокирует сторонние DNS-запросы, то оптимальнее будет использовать для заблокированных сайтов, например, 8.8.8.8, а не резолвить через tor...
    ALT_DNS_ADDR = "8.8.8.8"
    ### Преобразование кириллических доменов в punycode (0 - off, 1 - on)
    USE_IDN = 0
    ### Перекодировка данных для источников с кодировкой отличной от UTF-8 (0 - off, 1 - on)
    #USE_ICONV = 1
    ### SLD не подлежащие оптимизации
    OPT_EXCLUDE_SLD = {
        "livejournal.com",
        "facebook.com",
        "vk.com",
        "blog.jp",
        "msk.ru",
        "net.ru",
        "org.ru",
        "net.ua",
        "com.ua",
        "org.ua",
        "co.uk",
        "amazonaws.com",
    }
    ### Не оптимизировать SLD попадающие под выражения
    OPT_EXCLUDE_MASKS = set()   # {"^[a-z]{2,3}.[a-z]{2}$"}
    ### Фильтрация записей блэклиста по шаблонам из файла ENTRIES_FILTER_FILE. Записи (FQDN) попадающие под шаблоны исключаются из кофига dnsmasq (0 - off, 1 - on)
    ENTRIES_FILTER = 1
    ### Файл с шаблонами FQDN для опции ENTRIES_FILTER (каждый шаблон в отдельной строке. # в первом символе строки - комментирует строку)
    ENTRIES_FILTER_FILE = "/opt/etc/ruantiblock/ruab_entries_filter"
    ### Стандартные шаблоны для опции ENTRIES_FILTER. Добавляются к шаблонам из файла ENTRIES_FILTER_FILE (также применяются при отсутствии ENTRIES_FILTER_FILE)
    ENTRIES_FILTER_PATTERNS = {
        "^youtube[.]com",
    }
    ### Фильтрация записей блэклиста по шаблонам из файла IP_FILTER_FILE. Записи (ip, CIDR) попадающие под шаблоны исключаются из кофига ipset (0 - off, 1 - on)
    IP_FILTER = 1
    ### Файл с шаблонами ip для опции ENTRIES_FILTER (каждый шаблон в отдельной строке. # в первом символе строки - комментирует строку)
    IP_FILTER_FILE = "/opt/etc/ruantiblock/ruab_ip_filter"
    ### Стандартные шаблоны для опции IP_FILTER. Добавляются к шаблонам из файла IP_FILTER_FILE (также применяются при отсутствии IP_FILTER_FILE)
    IP_FILTER_PATTERNS = set()
    ### Лимит для субдоменов. При достижении, в конфиг dnsmasq будет добавлен весь домен 2-го ур-ня вместо множества субдоменов
    SD_LIMIT = 16
    ### Лимит ip адресов. При достижении, в конфиг ipset будет добавлена вся подсеть /24 вместо множества ip-адресов пренадлежащих этой сети (0 - off)
    IP_LIMIT = 0
    ### Подсети класса C (/24). Ip-адреса из этих подсетей не группируются при оптимизации (записи д.б. в виде: 68.183.221. 149.154.162. и пр.)
    OPT_EXCLUDE_NETS = set()    # {"68.183.221.", "149.154.162."}
    ### В случае если из источника получено менее указанного кол-ва записей, то обновления списков не происходит
    BLLIST_MIN_ENTRS = 30000
    ### Обрезка www[0-9]. в FQDN (0 - off, 1 - on)
    STRIP_WWW = 1
    DATA_DIR = "/opt/var/" + NAME
    IPSET_DNSMASQ = NAME + "-dnsmasq"
    IPSET_IP = NAME + "-ip-tmp"
    IPSET_CIDR = NAME + "-cidr-tmp"
    DNSMASQ_DATA_FILE = os.path.join(DATA_DIR, NAME + ".dnsmasq")
    IP_DATA_FILE = os.path.join(DATA_DIR, NAME + ".ip")
    UPDATE_STATUS_FILE = os.path.join(DATA_DIR, "update_status")
    ### Источники блэклиста
    AZ_ALL_URL = "https://api.antizapret.info/all.php?type=csv"
    AZ_IP_URL = "https://api.antizapret.info/group.php?data=ip"
    AZ_FQDN_URL = "https://api.antizapret.info/group.php?data=domain"
    RBL_ALL_URL = "https://reestr.rublacklist.net/api/v2/current/csv"
    RBL_IP_URL = "https://reestr.rublacklist.net/api/v2/ips/csv"
    RBL_FQDN_URL = "https://reestr.rublacklist.net/api/v2/domains/json"
    ZI_ALL_URL = "https://raw.githubusercontent.com/zapret-info/z-i/master/dump.csv"
    AZ_ENCODING = ""
    RBL_ENCODING = ""
    ZI_ENCODING = "CP1251"

    @classmethod
    def load_external_config(cls, file_path=CONFIG_FILE):

        def normalize_string(string):
            return re.sub('"', '', string)

        config_arrays = {"ENTRIES_FILTER_PATTERNS", "IP_FILTER_PATTERNS",
                        "OPT_EXCLUDE_SLD", "OPT_EXCLUDE_NETS"}
        try:
            with open(file_path, "rt") as file_handler:
                for line in file_handler:
                    regexp_obj = re.match("([a-zA-Z0-9_-]+)=([^#]+)\n", line)
                    if regexp_obj:
                        if regexp_obj.group(1) in config_arrays:
                            value = {normalize_string(i) for i in regexp_obj.group(2).split(" ")}
                        else:
                            try:
                                value = int(regexp_obj.group(2))
                            except ValueError:
                                value = normalize_string(regexp_obj.group(2))
                        setattr(cls, regexp_obj.group(1), value)
        except OSError:
            pass
        else:
            cls.DNSMASQ_DATA_FILE = os.path.join(cls.DATA_DIR, NAME + ".dnsmasq")
            cls.IP_DATA_FILE = os.path.join(cls.DATA_DIR, NAME + ".ip")
            cls.UPDATE_STATUS_FILE = os.path.join(cls.DATA_DIR, "update_status")

    @classmethod
    def _load_filter(cls, file_path, filter_patterns):
        try:
            with open(file_path, "rt") as file_handler:
                for line in file_handler:
                    if line and re.match("[^#]", line):
                        filter_patterns.add(line.strip())
        except OSError:
            pass

    @classmethod
    def load_entries_filter(cls, file_path=None):
        if cls.ENTRIES_FILTER:
            cls._load_filter(file_path or cls.ENTRIES_FILTER_FILE, cls.ENTRIES_FILTER_PATTERNS)

    @classmethod
    def load_ip_filter(cls, file_path=None):
        if cls.IP_FILTER:
            cls._load_filter(file_path or cls.IP_FILTER_FILE, cls.IP_FILTER_PATTERNS)


class ParserError(Exception):
    def __init__(self, reason=None):
        super().__init__(reason)
        self.reason = reason

    def __str__(self):
        return self.reason


class FieldValueError(ParserError):
    pass


class BlackListParser(Config):
    def __init__(self):
        self.ip_pattern = re.compile("(([0-9]{1,3}[.]){3})[0-9]{1,3}")
        self.cidr_pattern = re.compile("([0-9]{1,3}[.]){3}[0-9]{1,3}/[0-9]{1,2}")
        self.fqdn_pattern = re.compile(
            "([а-яa-z0-9_.*-]*?)([а-яa-z0-9_-]+[.][а-яa-z0-9-]+)",
            re.U)
        self.www_pattern = re.compile("^www[0-9]?[.]")
        self.cyr_pattern = re.compile("[а-я]", re.U)
        self.fqdn_set = set()
        self.sld_dict = {}
        self.ip_set = set()
        self.ip_subnet_dict = {}
        self.cidr_set = set()
        self.cidr_count = 0
        self.ip_count = 0
        self.output_fqdn_count = 0
        self.ssl_unverified = False
        self.send_headers_dict = {
            "User-Agent": "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:68.0) Gecko/20100101 Firefox/68.0",
        }
        ### Прокси серверы (прим.: self.proxies = {"http": "http://192.168.0.1:8080", "https": "http://192.168.0.1:8080"})
        self.proxies = None
        self.connect_timeout = None
        self.data_chunk = 2048
        self.write_buffer = -1
        self.url = "http://127.0.0.1"
        self.records_separator = "\n"
        self.fields_separator = ";"
        self.ips_separator = " | "
        self.default_site_encoding = "utf-8"
        self.site_encoding = self.default_site_encoding

    @staticmethod
    def _compile_filter_patterns(filters_seq):
        return {
            re.compile(i, re.U)
            for i in filters_seq
                if i and type(i) == str
        }

    @contextmanager
    def _make_connection(self,
                        url,
                        method="GET",
                        postData=None,
                        send_headers_dict=None,
                        timeout=None):
        conn_object = http_code = received_headers = None
        req_object = request.Request(url,
                                    data=postData,
                                    headers=send_headers_dict,
                                    method=method)
        opener_args = [request.ProxyHandler(self.proxies)]
        if self.ssl_unverified:
            opener_args.append(request.HTTPSHandler(context=ssl._create_unverified_context()))
        try:
            conn_object = request.build_opener(*opener_args).open(
                req_object,
                timeout=(
                    timeout if type(timeout) == int else socket._GLOBAL_DEFAULT_TIMEOUT
                )
            )
            http_code, received_headers = conn_object.status, conn_object.getheaders()
        except Exception as exception_object:
            print(f" Connection error! {exception_object} ( {url} )",
                file=sys.stderr)
        try:
            yield (conn_object, http_code, received_headers)
        except Exception as exception_object:
            raise ParserError(f"Parser error! {exception_object} ( {self.url} )")
        finally:
            if conn_object:
                conn_object.close()

    def _download_data(self):
        with self._make_connection(
            self.url,
            send_headers_dict=self.send_headers_dict,
            timeout=self.connect_timeout
        ) as conn_params:
            conn_object, http_code, _ = conn_params
            if http_code == 200:
                while True:
                    chunk = conn_object.read(self.data_chunk)
                    yield (chunk or None)
                    if not chunk:
                        break

    def _align_chunk(self):
        rest = bytes()
        for chunk in self._download_data():
            if chunk is None:
                yield rest
                continue
            data, _, rest = (rest + chunk).rpartition(self.records_separator)
            yield data

    def _split_entries(self):
        for chunk in self._align_chunk():
            for entry in chunk.split(self.records_separator):
                try:
                    yield entry.decode(
                        self.site_encoding or self.default_site_encoding)
                except UnicodeError:
                    pass

    @staticmethod
    def _check_filter(string, filter_patterns):
        if filter_patterns and string:
            for pattern in filter_patterns:
                if pattern and pattern.search(string):
                    return True
        return False

    def _get_subnet(self, ip_addr):
        regexp_obj = self.ip_pattern.fullmatch(ip_addr)
        return regexp_obj.group(1) if regexp_obj else None

    def ip_field_processing(self, string):
        for i in string.split(self.ips_separator):
            if self.IP_FILTER and self._check_filter(i, self.IP_FILTER_PATTERNS):
                continue
            if self.ip_pattern.fullmatch(i) and i not in self.ip_set:
                subnet = self._get_subnet(i)
                if subnet in self.OPT_EXCLUDE_NETS or (
                    not self.IP_LIMIT or (
                        subnet not in self.ip_subnet_dict or self.ip_subnet_dict[subnet] < self.IP_LIMIT
                    )
                ):
                    self.ip_set.add(i)
                    self.ip_subnet_dict[subnet] = (self.ip_subnet_dict.get(subnet) or 0) + 1
            elif self.cidr_pattern.fullmatch(i) and i not in self.cidr_set:
                self.cidr_set.add(i)

    def _convert_to_punycode(self, string):
        if self.cyr_pattern.search(string):
            if self.USE_IDN:
                try:
                    string = string.encode("idna").decode(
                        self.site_encoding or self.default_site_encoding)
                except UnicodeError:
                    pass
            else:
                string = ""
        return string

    def _get_sld(self, fqdn):
        regexp_obj = self.fqdn_pattern.fullmatch(fqdn)
        return regexp_obj.group(2) if regexp_obj else None

    def fqdn_field_processing(self, string):
        if self.ip_pattern.fullmatch(string):
            raise FieldValueError()
        string = string.strip("*.").lower()
        if self.STRIP_WWW:
            string = self.www_pattern.sub("", string)
        string = self._convert_to_punycode(string)
        if not self.ENTRIES_FILTER or (
            self.ENTRIES_FILTER and not self._check_filter(string, self.ENTRIES_FILTER_PATTERNS)
        ):
            sld = self._get_sld(string)
            if sld in self.OPT_EXCLUDE_SLD or (
                not self.SD_LIMIT or (
                    sld not in self.sld_dict or self.sld_dict[sld] < self.SD_LIMIT
                )
            ):
                self.sld_dict[sld] = (self.sld_dict.get(sld) or 0) + 1
                self.fqdn_set.add(string)

    def parser_func(self):
        raise NotImplementedError()

    def _check_sld_masks(self, sld):
        if self.OPT_EXCLUDE_MASKS:
            for pattern in self.OPT_EXCLUDE_MASKS:
                if re.fullmatch(pattern, sld):
                    return True
        return False

    def _make_dnsmasq_config(self):
        with open(self.DNSMASQ_DATA_FILE, "wt", buffering=self.write_buffer) as file_handler:
            for fqdn in self.fqdn_set:
                sld = self._get_sld(fqdn)
                if sld and (fqdn == sld or sld not in self.fqdn_set) and self.sld_dict.get(sld):
                    if (not self._check_sld_masks(sld) and (
                            self.SD_LIMIT and sld not in self.OPT_EXCLUDE_SLD
                        )) and (self.sld_dict[sld] >= self.SD_LIMIT):
                        record_value = sld
                        del(self.sld_dict[sld])
                    else:
                        record_value = fqdn
                    file_handler.write(
                        f"server=/{record_value}/{self.ALT_DNS_ADDR}\nipset=/{record_value}/{self.IPSET_DNSMASQ}\n"
                        if self.ALT_NSLOOKUP else
                        f"ipset=/{record_value}/{self.IPSET_DNSMASQ}\n")
                    self.output_fqdn_count += 1

    def _make_ipset_config(self):
        with open(self.IP_DATA_FILE, "wt", buffering=self.write_buffer) as file_handler:
            for ipaddr in self.ip_set:
                subnet = self._get_subnet(ipaddr)
                if subnet in self.ip_subnet_dict:
                    if subnet not in self.OPT_EXCLUDE_NETS and (
                        self.IP_LIMIT and self.ip_subnet_dict[subnet] >= self.IP_LIMIT
                    ):
                        key_value, ipset = f"{subnet}0/24", self.IPSET_CIDR
                        del(self.ip_subnet_dict[subnet])
                        self.cidr_count += 1
                        self.cidr_set.discard(key_value)
                    else:
                        key_value, ipset = ipaddr, self.IPSET_IP
                        self.ip_count += 1
                    file_handler.write(f"add {ipset} {key_value}\n")
            for i in self.cidr_set:
                self.cidr_count += 1
                file_handler.write(f"add {self.IPSET_CIDR} {i}\n")

    def _make_update_status_file(self):
        with open(self.UPDATE_STATUS_FILE, "wt") as file_handler:
            file_handler.write(
                f"{self.ip_count} {self.cidr_count} {self.output_fqdn_count}")

    def run(self):
        ret_value = 1
        self.ENTRIES_FILTER_PATTERNS = self._compile_filter_patterns(self.ENTRIES_FILTER_PATTERNS)
        self.IP_FILTER_PATTERNS = self._compile_filter_patterns(self.IP_FILTER_PATTERNS)
        self.records_separator = bytes(self.records_separator, "utf-8")
        self.parser_func()
        if (len(self.ip_set) + len(self.cidr_set) + len(self.fqdn_set)) >= self.BLLIST_MIN_ENTRS:
            self._make_dnsmasq_config()
            self._make_ipset_config()
            ret_value = 0
        else:
            ret_value = 2
        self._make_update_status_file()
        return ret_value


class AzHybrid(BlackListParser):
    def __init__(self):
        super().__init__()
        self.url = self.AZ_ALL_URL
        self.ips_separator = ","
        self.site_encoding = self.AZ_ENCODING

    def parser_func(self):
        for entry in self._split_entries():
            entry_list = entry.split(self.fields_separator)
            try:
                if entry_list[-2]:
                    try:
                        self.fqdn_field_processing(entry_list[-2])
                    except FieldValueError:
                        self.ip_field_processing(entry_list[-1])
                else:
                    self.ip_field_processing(entry_list[-1])
            except IndexError:
                pass


class AzIp(BlackListParser):
    def __init__(self):
        super().__init__()
        self.url = self.AZ_IP_URL
        self.ips_separator = ","

    def parser_func(self):
        for entry in self._split_entries():
            self.ip_field_processing(entry)


class AzFQDN(BlackListParser):
    def __init__(self):
        super().__init__()
        self.url = self.AZ_FQDN_URL

    def parser_func(self):
        for entry in self._split_entries():
            try:
                self.fqdn_field_processing(entry)
            except FieldValueError:
                self.ip_field_processing(entry)


class RblHybrid(BlackListParser):
    def __init__(self):
        super().__init__()
        self.url = self.RBL_ALL_URL
        self.fields_separator = "],"
        self.ips_separator = ","

    def parser_func(self):
        for entry in self._split_entries():
            entry_list = entry.partition(self.fields_separator)
            ip_string = re.sub(r"[' \]\[]", "", entry_list[0])
            fqdn_string = re.sub(",.*$", "", entry_list[2])
            if fqdn_string:
                try:
                    self.fqdn_field_processing(fqdn_string)
                except FieldValueError:
                    self.ip_field_processing(ip_string)
            else:
                self.ip_field_processing(ip_string)


class RblIp(BlackListParser):
    def __init__(self):
        super().__init__()
        self.url = self.RBL_IP_URL

    def parser_func(self):
        for entry in self._split_entries():
            self.ip_field_processing(entry.rstrip(","))


class RblFQDN(BlackListParser):
    def __init__(self):
        super().__init__()
        self.url = self.RBL_FQDN_URL
        self.records_separator = ", "

    @staticmethod
    def hex_to_unicode(code):
        return chr(int(code, 16))

    def parser_func(self):
        for entry in self._split_entries():
            entry = entry.strip(']["')
            try:
                self.fqdn_field_processing(
                    re.sub(r"\\u([a-f0-9]{4})",
                            lambda s: self.hex_to_unicode(s.group(1)),
                            entry)
                )
            except FieldValueError:
                self.ip_field_processing(entry)


class ZiHybrid(BlackListParser):
    def __init__(self):
        super().__init__()
        self.url = self.ZI_ALL_URL
        self.site_encoding = self.ZI_ENCODING

    def parser_func(self):
        for entry in self._split_entries():
            entry_list = entry.split(self.fields_separator)
            try:
                if entry_list[1]:
                    try:
                        self.fqdn_field_processing(entry_list[1])
                    except FieldValueError:
                        self.ip_field_processing(entry_list[0])
                else:
                    self.ip_field_processing(entry_list[0])
            except IndexError:
                pass


class ZiIp(ZiHybrid):
    def parser_func(self):
        for entry in self._split_entries():
            entry_list = entry.split(self.fields_separator)
            self.ip_field_processing(entry_list[0])


class ZiFQDN(ZiHybrid):
    def parser_func(self):
        for entry in self._split_entries():
            entry_list = entry.split(self.fields_separator)
            try:
                if entry_list[1]:
                    try:
                        self.fqdn_field_processing(entry_list[1])
                    except FieldValueError:
                        self.ip_field_processing(entry_list[0])
            except IndexError:
                pass


if __name__ == "__main__":
    Config.load_external_config()
    Config.load_entries_filter()
    Config.load_ip_filter()
    ctx_dict = {
        "ip": {"antizapret": AzIp, "rublacklist": RblIp, "zapret-info": ZiIp},
        "fqdn": {"antizapret": AzFQDN, "rublacklist": RblFQDN, "zapret-info": ZiFQDN},
        "hybrid": {"antizapret": AzHybrid, "rublacklist": RblHybrid, "zapret-info": ZiHybrid},
    }
    try:
        ctx = ctx_dict[Config.BLOCK_MODE][Config.BL_UPDATE_MODE]()
    except KeyError:
        print("Wrong configuration! (Config.BLOCK_MODE or Config.BL_UPDATE_MODE)",
            file=sys.stderr)
        sys.exit(1)
    sys.exit(ctx.run())
