--[[
 Модуль поддерживает следующие источники:
    https://api.antizapret.info/all.php?type=csv
    https://api.antizapret.info/group.php?data=ip
    https://api.antizapret.info/group.php?data=domain
    https://reestr.rublacklist.net/api/v2/current/csv
    https://reestr.rublacklist.net/api/v2/ips/csv
    https://reestr.rublacklist.net/api/v2/domains/json
    https://raw.githubusercontent.com/zapret-info/z-i/master/dump.csv
--]]

local NAME = "ruantiblock"
local CONFIG_FILE = "/opt/etc/ruantiblock/ruantiblock.conf"

-------------------------- Class constructor -------------------------

local function Class(super, t)
    local class = t or {}
    local function instanceConstructor(cls, t)
        local instance = t or {}
        setmetatable(instance, cls)
        instance.__class = cls
        return instance
    end
    if not super then
        local mt = {__call = instanceConstructor}
        mt.__index = mt
        setmetatable(class, mt)
    elseif type(super) == "table" and super.__index and super.__call then
        setmetatable(class, super)
        class.__super = super
    else
        error("Argument error! Incorrect object of a 'super'")
    end
    class.__index = class
    class.__call = instanceConstructor
    return class
end

------------------------------ Settings ------------------------------

local Config = Class(nil, {
    -- Тип обновления списка блокировок (antizapret, rublacklist, zapret-info)
    BL_UPDATE_MODE = "rublacklist",
    -- Режим обхода блокировок: ip (если провайдер блокирует по ip), hybrid (если провайдер использует DPI, подмену DNS и пр.), fqdn (если провайдер использует DPI, подмену DNS и пр.)
    BLOCK_MODE = "hybrid",
    -- Перенаправлять DNS-запросы на альтернативный DNS-сервер для заблокированных FQDN (или в tor если провайдер блокирует сторонние DNS-серверы) (0 - off, 1 - on)
    ALT_NSLOOKUP = 1,
    -- Альтернативный DNS-сервер ($ONION_DNS_ADDR в ruantiblock.sh (tor), 8.8.8.8 и др.). Если провайдер не блокирует сторонние DNS-запросы, то оптимальнее будет использовать для заблокированных сайтов, например, 8.8.8.8, а не резолвить через tor...
    ALT_DNS_ADDR = "8.8.8.8",
    -- Преобразование кириллических доменов в punycode (0 - off, 1 - on)
    USE_IDN = 0,
    -- Перекодировка данных для источников с кодировкой отличной от UTF-8 (0 - off, 1 - on)
    USE_ICONV = 0,
    -- SLD не подлежащие оптимизации
    OPT_EXCLUDE_SLD = {
        ["livejournal.com"] = true,
        ["facebook.com"] = true,
        ["vk.com"] = true,
        ["blog.jp"] = true,
        ["msk.ru"] = true,
        ["net.ru"] = true,
        ["org.ru"] = true,
        ["net.ua"] = true,
        ["com.ua"] = true,
        ["org.ua"] = true,
        ["co.uk"] = true,
        ["amazonaws.com"] = true,
    },
    -- Не оптимизировать SLD попадающие под выражения из таблицы
    OPT_EXCLUDE_MASKS = {},     -- { "^%a%a%a?.%a%a$" },
    -- Фильтрация записей блэклиста по шаблонам из файла ENTRIES_FILTER_FILE. Записи (FQDN) попадающие под шаблоны исключаются из кофига dnsmasq (0 - off, 1 - on)
    ENTRIES_FILTER = 1,
    -- Файл с шаблонами FQDN для опции ENTRIES_FILTER (каждый шаблон в отдельной строке. # в первом символе строки - комментирует строку)
    ENTRIES_FILTER_FILE = "/opt/etc/ruantiblock/ruab_entries_filter",
    -- Стандартные шаблоны для опции ENTRIES_FILTER (через пробел). Добавляются к шаблонам из файла ENTRIES_FILTER_FILE (также применяются при отсутствии ENTRIES_FILTER_FILE)
    ENTRIES_FILTER_PATTERNS = {
        ["^youtube[.]com"] = true,
    },
    -- Фильтрация записей блэклиста по шаблонам из файла IP_FILTER_FILE. Записи (ip, CIDR) попадающие под шаблоны исключаются из кофига ipset (0 - off, 1 - on)
    IP_FILTER = 1,
    -- Файл с шаблонами ip для опции ENTRIES_FILTER (каждый шаблон в отдельной строке. # в первом символе строки - комментирует строку)
    IP_FILTER_FILE = "/opt/etc/ruantiblock/ruab_ip_filter",
    -- Стандартные шаблоны для опции IP_FILTER. Добавляются к шаблонам из файла IP_FILTER_FILE (также применяются при отсутствии IP_FILTER_FILE)
    IP_FILTER_PATTERNS = {},
    -- Лимит для субдоменов. При достижении, в конфиг dnsmasq будет добавлен весь домен 2-го ур-ня вместо множества субдоменов (0 - off)
    SD_LIMIT = 16,
    -- Лимит ip адресов. При достижении, в конфиг ipset будет добавлена вся подсеть /24 вместо множества ip-адресов пренадлежащих этой сети (0 - off)
    IP_LIMIT = 0,
    -- Подсети класса C (/24). Ip-адреса из этих подсетей не группируются при оптимизации (записи д.б. в виде: 68.183.221. 149.154.162. и пр.)
    OPT_EXCLUDE_NETS = {
        --["68.183.221."] = true,
        --["149.154.162."] = true,
    },
    -- В случае если из источника получено менее указанного кол-ва записей, то обновления списков не происходит
    BLLIST_MIN_ENTRS = 30000,
    -- Обрезка www[0-9]. в FQDN (0 - off, 1 - on)
    STRIP_WWW = 1,
    -- Тип idn: внешняя утилита или библиотека lua-idn (standalone, lua)
    IDN_TYPE = "standalone",
    -- Внешняя утилита idn
    IDN_CMD = "idn",
    -- Тип iconv: внешняя утилита или библиотека lua-iconv (standalone, lua)
    ICONV_TYPE = "standalone",
    -- Внешняя утилита iconv
    ICONV_CMD = "iconv",
    WGET_CMD = "wget --no-check-certificate -q -O -",
    DATA_DIR = "/opt/var/" .. NAME,
    IPSET_DNSMASQ = NAME .. "-dnsmasq",
    IPSET_IP = NAME .. "-ip-tmp",
    IPSET_CIDR = NAME .. "-cidr-tmp",
    -- Источники блэклиста
    AZ_ALL_URL = "https://api.antizapret.info/all.php?type=csv",
    AZ_IP_URL = "https://api.antizapret.info/group.php?data=ip",
    AZ_FQDN_URL = "https://api.antizapret.info/group.php?data=domain",
    RBL_ALL_URL = "https://reestr.rublacklist.net/api/v2/current/csv",
    RBL_IP_URL = "https://reestr.rublacklist.net/api/v2/ips/csv",
    RBL_FQDN_URL = "https://reestr.rublacklist.net/api/v2/domains/json",
    ZI_ALL_URL = "https://raw.githubusercontent.com/zapret-info/z-i/master/dump.csv",
    AZ_ENCODING = "",
    RBL_ENCODING = "",
    ZI_ENCODING = "CP1251",
    encoding = "UTF-8",
    siteEncoding = "UTF-8",
    httpSendHeadersTable = {
        --["User-Agent"] = "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:68.0) Gecko/20100101 Firefox/68.0",
    },
})
Config.wgetUserAgent = (Config.httpSendHeadersTable["User-Agent"]) and ' -U "' .. Config.httpSendHeadersTable["User-Agent"] .. '"' or ''

-- Load external config

function Config:loadExternalConfig()
    local configArrays = {["ENTRIES_FILTER_PATTERNS"] = true, ["IP_FILTER_PATTERNS"] = true, ["OPT_EXCLUDE_SLD"] = true, ["OPT_EXCLUDE_NETS"] = true,}
    local fileHandler = io.open(CONFIG_FILE, "r")
    if fileHandler then
        for line in fileHandler:lines() do
            local var, val = line:match("^([a-zA-Z0-9_%-]+)%=([^#]+)")
            if var then
                if configArrays[var] then
                    local valueTable = {}
                    for v in val:gmatch('[^" ]+') do
                        valueTable[v] = true
                    end
                    self[var] = valueTable
                else
                    self[var] = val:match("^[0-9.]+$") and tonumber(val) or val:gsub('"', '')
                end
            end
        end
        fileHandler:close()
    end
end

Config:loadExternalConfig()
Config.DNSMASQ_DATA_FILE = Config.DATA_DIR .. "/" .. NAME .. ".dnsmasq"
Config.IP_DATA_FILE = Config.DATA_DIR .. "/" .. NAME .. ".ip"
Config.UPDATE_STATUS_FILE = Config.DATA_DIR .. "/update_status"

local function remapBool(val)
    return (val ~= 0 and val ~= false and val ~= nil) and true or false
end

Config.ALT_NSLOOKUP = remapBool(Config.ALT_NSLOOKUP)
Config.USE_IDN = remapBool(Config.USE_IDN)
Config.USE_ICONV = remapBool(Config.USE_ICONV)
Config.STRIP_WWW = remapBool(Config.STRIP_WWW)
Config.ENTRIES_FILTER = remapBool(Config.ENTRIES_FILTER)
Config.IP_FILTER = remapBool(Config.IP_FILTER)

-- Load filters

function Config:loadFilterFiles()
    function loadFile(file, t)
        local fileHandler = io.open(file, "r")
        if fileHandler then
            for line in fileHandler:lines() do
                if #line > 0 and line:match("^[^#]") then
                    t[line] = true
                end
            end
            fileHandler:close()
        end
    end
    if self.ENTRIES_FILTER then
        loadFile(self.ENTRIES_FILTER_FILE, self.ENTRIES_FILTER_PATTERNS)
    end
    if self.IP_FILTER then
        loadFile(self.IP_FILTER_FILE, self.IP_FILTER_PATTERNS)
    end
end

Config:loadFilterFiles()

-- Import packages

local function prequire(package)
    local retVal, pkg = pcall(require, package)
    return retVal and pkg
end

local idn = prequire("idn")
if Config.USE_IDN and Config.IDN_TYPE == "lua" and not idn then
    error("You need to install idn.lua (github.com/haste/lua-idn) or use standalone idn tool... Otherwise 'Config.USE_IDN' must be set to 'false'")
end
local iconv = prequire("iconv")
if Config.USE_ICONV and Config.ICONV_TYPE == "lua" and not iconv then
    error("You need to install lua-iconv or use standalone iconv tool... Otherwise 'Config.USE_ICONV' must be set to 'false'")
end
local http = prequire("socket.http")
local https = prequire("ssl.https")
local ltn12 = prequire("ltn12")
if not ltn12 then
    error("You need to install ltn12...")
end

------------------------------ Classes -------------------------------

local BlackListParser = Class(Config, {
    ipPattern = "%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?",
    cidrPattern = "%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?/%d%d?",
    fqdnPattern = "[a-z0-9_%.%-]-[a-z0-9_%-]+%.[a-z0-9%.%-]",
    url = "http://127.0.0.1",
    recordsSeparator = "\n",
    ipsSeparator = " | ",
})

function BlackListParser:new(t)
    -- extended instance constructor
    local instance = self(t)
    instance.url = instance["url"] or self.url
    instance.recordsSeparator = instance["recordsSeparator"] or self.recordsSeparator
    instance.ipsSeparator = instance["ipsSeparator"] or self.ipsSeparator
    instance.siteEncoding = instance["siteEncoding"] or self.siteEncoding
    instance.ipRecordsCount = 0
    instance.ipCount = 0
    instance.ipSubnetTable = {}
    instance.cidrCount = 0
    instance.fqdnTable = {}
    instance.fqdnCount = 0
    instance.sldTable = {}
    instance.fqdnRecordsCount = 0
    instance.ipTable = {}
    instance.cidrTable = {}
    instance.iconvHandler = (self.USE_ICONV and iconv) and iconv.open(instance.encoding, instance.siteEncoding) or nil
    return instance
end

function BlackListParser:convertEncoding(input)
    if self.siteEncoding and self.siteEncoding ~= "" then
        local output, err
        if self.ICONV_TYPE == "lua" and self.iconvHandler then
            output, err = self.iconvHandler:iconv(input)
        elseif self.ICONV_TYPE == "standalone" then
            local iconvHandler = assert(io.popen('echo \'' .. input .. '\' | ' .. self.ICONV_CMD .. ' -f "' .. self.siteEncoding .. '" -t "' .. self.encoding .. '"', 'r'))
            output = iconvHandler:read("*a")
            iconvHandler:close()
        else
            error("Config.ICONV_TYPE should be either 'lua' or 'standalone'")
        end
        return (output)
    end
    return (input)
end

function BlackListParser:convertToPunycode(input)
    local output
    if self.IDN_TYPE == "lua" and idn then
        input = self:convertEncoding(input)
        output = idn.encode(input)
    elseif self.IDN_TYPE == "standalone" then
        if self.ICONV_TYPE == "lua" then
            input = self:convertEncoding(input)
        end
        local idnCmdString = (self.IDN_TYPE == "standalone" and self.ICONV_TYPE == "standalone" and self.siteEncoding and self.siteEncoding ~= "") and 'echo \'' .. input .. '\' | ' .. self.ICONV_CMD .. ' -f "' .. self.siteEncoding .. '" -t "' .. self.encoding .. '" | ' .. self.IDN_CMD or self.IDN_CMD .. ' "' .. input .. '"'
        local idnHandler = assert(io.popen(idnCmdString, 'r'))
        output = idnHandler:read("*l")
        idnHandler:close()
    else
        error("Config.IDN_TYPE should be either 'lua' or 'standalone'")
    end
    return (output)
end

function BlackListParser:checkFilter(str, filterPatterns)
    if filterPatterns and str then
        for pattern in pairs(filterPatterns) do
            if str:match(pattern) then
                return true
            end
        end
    end
    return false
end

function BlackListParser:getSLD(fqdn)
    return fqdn:match("^[a-z0-9_%.%-]-([a-z0-9_%-]+%.[a-z0-9%-]+)$")
end

function BlackListParser:fillDomainTables(val)
    if self.STRIP_WWW then val = val:gsub("^www[0-9]?%.", "") end
    if not self.ENTRIES_FILTER or (self.ENTRIES_FILTER and not self:checkFilter(val, self.ENTRIES_FILTER_PATTERNS)) then
        local secondLevelDomain = self:getSLD(val)
        if secondLevelDomain and (self.OPT_EXCLUDE_SLD[secondLevelDomain] or ((not self.SD_LIMIT or self.SD_LIMIT == 0) or (not self.sldTable[secondLevelDomain] or self.sldTable[secondLevelDomain] < self.SD_LIMIT))) then
            self.fqdnTable[val] = true
            self.sldTable[secondLevelDomain] = (self.sldTable[secondLevelDomain] or 0) + 1
            self.fqdnCount = self.fqdnCount + 1
        end
    end
end

function BlackListParser:getSubnet(ip)
    return ip:match("^(%d+%.%d+%.%d+%.)%d+$")
end

function BlackListParser:fillIpTables(val)
    if val and val ~= "" then
        for ipEntry in val:gmatch(self.ipPattern .. "/?%d?%d?") do
            if not self.IP_FILTER or (self.IP_FILTER and not self:checkFilter(ipEntry, self.IP_FILTER_PATTERNS)) then
                if ipEntry:match("^" .. self.ipPattern .. "$") and not self.ipTable[ipEntry] then
                    local subnet = self:getSubnet(ipEntry)
                    if subnet and (self.OPT_EXCLUDE_NETS[subnet] or ((not self.IP_LIMIT or self.IP_LIMIT == 0) or (not self.ipSubnetTable[subnet] or self.ipSubnetTable[subnet] < self.IP_LIMIT))) then
                        self.ipTable[ipEntry] = true
                        self.ipSubnetTable[subnet] = (self.ipSubnetTable[subnet] or 0) + 1
                        self.ipCount = self.ipCount + 1
                    end
                elseif ipEntry:match("^" .. self.cidrPattern .. "$") and not self.cidrTable[ipEntry] then
                    self.cidrTable[ipEntry] = true
                    self.cidrCount = self.cidrCount + 1
                end
            end
        end
    end
end

function BlackListParser:sink()
    -- Must be reload in the subclass
    error("Method BlackListParser:sink() must be reload in the subclass!")
end

function BlackListParser:makeDnsmasqConfig()
    local configFile = assert(io.open(self.DNSMASQ_DATA_FILE, "w"), "Could not open dnsmasq config")
    --configFile:setvbuf("no")
    if self.OPT_EXCLUDE_MASKS and #self.OPT_EXCLUDE_MASKS > 0 then
        for sld in pairs(self.sldTable) do
            for _, pattern in ipairs(self.OPT_EXCLUDE_MASKS) do
                if sld:find(pattern) then
                    self.sldTable[sld] = 0
                    break
                end
            end
        end
    end
    for fqdn in pairs(self.fqdnTable) do
        local sld = self:getSLD(fqdn)
        local keyValue = fqdn
        if (not self.fqdnTable[sld] or fqdn == sld) and self.sldTable[sld] then
            if (self.SD_LIMIT and self.SD_LIMIT > 0 and not self.OPT_EXCLUDE_SLD[sld]) and self.sldTable[sld] >= self.SD_LIMIT then
                keyValue = sld
                self.sldTable[sld] = nil
            end
            if self.ALT_NSLOOKUP then
                configFile:write(string.format("server=/%s/%s\n", keyValue, self.ALT_DNS_ADDR))
            end
            configFile:write(string.format("ipset=/%s/%s\n", keyValue, self.IPSET_DNSMASQ))
            self.fqdnRecordsCount = self.fqdnRecordsCount + 1
        end
    end
    configFile:close()
end

function BlackListParser:makeIpsetConfig()
    local configFile = assert(io.open(self.IP_DATA_FILE, "w"), "Could not open ipset config")
    --configFile:setvbuf("no")
    for ipaddr in pairs(self.ipTable) do
        local subnet = self:getSubnet(ipaddr)
        local keyValue, ipset
        if self.ipSubnetTable[subnet] then
            if (self.IP_LIMIT and self.IP_LIMIT > 0 and not self.OPT_EXCLUDE_NETS[subnet]) and self.ipSubnetTable[subnet] >= self.IP_LIMIT then
                keyValue, ipset = string.format("%s0/24", subnet), self.IPSET_CIDR
                self.ipSubnetTable[subnet] = nil
                self.cidrCount = self.cidrCount + 1
                self.cidrTable[keyValue] = nil
            else
                keyValue, ipset = ipaddr, self.IPSET_IP
                self.ipRecordsCount = self.ipRecordsCount + 1
            end
            configFile:write(string.format("add %s %s\n", ipset, keyValue))
        end
    end
    for cidr in pairs(self.cidrTable) do
        configFile:write(string.format("add %s %s\n", self.IPSET_CIDR, cidr))
    end
    configFile:close()
end

function BlackListParser:makeUpdateStatus()
    local updateStatusFile = assert(io.open(self.UPDATE_STATUS_FILE, "w"), "Could not open 'update_status' file")
    updateStatusFile:write(string.format("%d %d %d", self.ipRecordsCount, self.cidrCount, self.fqdnRecordsCount))
    updateStatusFile:close()
end

function BlackListParser:chunkBuffer()
    local buff = ""
    local retValue = ""
    local lastChunk
    return function(chunk)
        if lastChunk then
            return nil
        end
        if chunk then
            buff = buff .. chunk
            local lastRsPosition = select(2, buff:find("^.*" .. self.recordsSeparator))
            if lastRsPosition then
                retValue = buff:sub(1, lastRsPosition)
                buff = buff:sub((lastRsPosition + 1), -1)
            else
                retValue = ""
            end
        else
            retValue = buff
            lastChunk = true
        end
        return (retValue)
    end
end

function BlackListParser:getHttpData(url)
    local retVal, retCode, retHeaders
    local httpModule = url:match("^https") and https or http
    if httpModule then
        local httpSink = ltn12.sink.chain(self:chunkBuffer(), self:sink())
        retVal, retCode, retHeaders = httpModule.request{url = url, sink = httpSink, headers = self.httpSendHeadersTable}
        if not retVal or retCode ~= 200 then
            retVal = nil
            print(string.format("Connection error! (%s) URL: %s", retCode, url))
        end
    end
    if not retVal then
        local wgetSink = ltn12.sink.chain(self:chunkBuffer(), self:sink())
        retVal = ltn12.pump.all(ltn12.source.file(io.popen(self.WGET_CMD .. self.wgetUserAgent .. ' "' .. url .. '"', 'r')), wgetSink)
    end
    return (retVal == 1) and true or false
end

function BlackListParser:run()
    local returnCode = 0
    if self:getHttpData(self.url) then
        if (self.fqdnCount + self.ipCount + self.cidrCount) > self.BLLIST_MIN_ENTRS then
            self:makeDnsmasqConfig()
            self:makeIpsetConfig()
            returnCode = 0
        else
            returnCode = 2
        end
    else
        returnCode = 1
    end
    self:makeUpdateStatus()
    return returnCode
end

-- Subclasses

local function ipSink(self)
    return function(chunk)
        if chunk and chunk ~= "" then
            for ipString in chunk:gmatch(self.ipStringPattern) do
                self:fillIpTables(ipString)
            end
        end
        return true
    end
end

local function hybridSinkFunc(self, ipStr, fqdnStr)
    if #fqdnStr > 0 and not fqdnStr:match("^" .. self.ipPattern .. "$") then
        fqdnStr = fqdnStr:gsub("%*%.", ""):gsub("%.$", ""):lower()
        if fqdnStr:match("^" .. self.fqdnPattern .. "+$") then
            self:fillDomainTables(fqdnStr)
        elseif self.USE_IDN and fqdnStr:match("^[^\\/&%?]-[^\\/&%?%.]+%.[^\\/&%?%.]+%.?$") then
            fqdnStr = self:convertToPunycode(fqdnStr)
            self:fillDomainTables(fqdnStr)
        end
    elseif (self.BLOCK_MODE == "hybrid" or fqdnStr:match("^" .. self.ipPattern .. "$")) and #ipStr > 0 then
        self:fillIpTables(ipStr)
    end
end

    -- antizapret.info

local Az = Class(BlackListParser, {
    url = Config.AZ_ALL_URL,
    ipsSeparator = ",",
    ipStringPattern = "(.-)\n",
})

function Az:sink()
    local entryPattern = (self.BLOCK_MODE == "fqdn") and "((.-))" .. self.recordsSeparator or ";([^;]-);([^;]-)" .. self.recordsSeparator
    return function(chunk)
        if chunk and chunk ~= "" then
            for fqdnStr, ipStr in chunk:gmatch(entryPattern) do
                hybridSinkFunc(self, ipStr, fqdnStr)
            end
        end
        return true
    end
end

local AzFqdn = Class(Az, {
    url = Config.AZ_FQDN_URL,
})

local AzIp = Class(Az, {
    url = Config.AZ_IP_URL,
    sink = ipSink,
})

    -- rublacklist.net

local Rbl = Class(BlackListParser, {
    url = Config.RBL_ALL_URL,
    ipsSeparator = ", ",
    ipStringPattern = "([a-f0-9/.:]+),?\n?",
})

function Rbl:sink()
    return function(chunk)
        if chunk and chunk ~= "" then
            for ipStr, fqdnStr in chunk:gmatch("%[([a-f0-9/.:', ]+)%],([^,]-),.-" .. self.recordsSeparator) do
                hybridSinkFunc(self, ipStr, fqdnStr)
            end
        end
        return true
    end
end

local RblIp = Class(Rbl, {
    url = Config.RBL_IP_URL,
    sink = ipSink,
})

local RblFqdn = Class(BlackListParser, {
    url = Config.RBL_FQDN_URL,
    recordsSeparator = ", ",
    unicodeHexPattern = "\\u(%x%x%x%x)",
})

function RblFqdn:hexToUnicode(code)
    local n = tonumber(code, 16)
    if n < 128 then
        return string.char(n)
    elseif n < 2048 then
        return string.char(192 + ((n - (n % 64)) / 64), 128 + (n % 64))
    else
        return string.char(224 + ((n - (n % 4096)) / 4096), 128 + (((n % 4096) - (n % 64)) / 64), 128 + (n % 64))
    end
end

function RblFqdn:sink()
    return function(chunk)
        if chunk and chunk ~= "" then
            for fqdnStr in chunk:gmatch('"(.-)",? ?') do
                if #fqdnStr > 0 and not fqdnStr:match("^" .. self.ipPattern .. "$") then
                    fqdnStr = fqdnStr:gsub("%*%.", ""):gsub("%.$", ""):lower()
                    if self.USE_IDN and fqdnStr:match(self.unicodeHexPattern) then
                        fqdnStr = self:convertToPunycode(fqdnStr:gsub(self.unicodeHexPattern, function(s) return self:hexToUnicode(s) end))
                    end
                    if fqdnStr:match("^" .. self.fqdnPattern .. "+$") then
                        self:fillDomainTables(fqdnStr)
                    end
                elseif fqdnStr:match("^" .. self.ipPattern .. "$") and #fqdnStr > 0 then
                    self:fillIpTables(fqdnStr)
                end
            end
        end
        return true
    end
end

    -- zapret-info

local Zi = Class(BlackListParser, {
    url = Config.ZI_ALL_URL,
    ipStringPattern = "([a-f0-9%.:/ |]+);.-\n",
    siteEncoding = Config.ZI_ENCODING,
})

function Zi:sink()
    return function(chunk)
        if chunk and chunk ~= "" then
            for ipStr, fqdnStr in chunk:gmatch("([^;]-);([^;]-);.-" .. self.recordsSeparator) do
                hybridSinkFunc(self, ipStr, fqdnStr)
            end
        end
        return true
    end
end

local ZiIp = Class(Zi, {
    sink = ipSink,
})

------------------------------ Run section ------------------------------

local ctxTable = {
    ["ip"] = {["antizapret"] = AzIp, ["rublacklist"] = RblIp, ["zapret-info"] = ZiIp},
    ["fqdn"] = {["antizapret"] = AzFqdn, ["rublacklist"] = RblFqdn, ["zapret-info"] = Zi},
    ["hybrid"] = {["antizapret"] = Az, ["rublacklist"] = Rbl, ["zapret-info"] = Zi},
}

local returnCode = 1
local ctx = ctxTable[Config.BLOCK_MODE] and ctxTable[Config.BLOCK_MODE][Config.BL_UPDATE_MODE]
if ctx then
    returnCode = ctx:new():run()
else
    error("Wrong configuration! (Config.BLOCK_MODE or Config.BL_UPDATE_MODE)")
end

os.exit(returnCode)
