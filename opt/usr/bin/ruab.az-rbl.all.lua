--[[
    IP, FQDN, CIDR

    Модуль для следующих источников:
     http://api.antizapret.info/all.php?type=csv
     http://api.antizapret.info/group.php?data=ip
     http://api.antizapret.info/group.php?data=domain
     http://api.reserve-rbl.ru/api/current
     https://raw.githubusercontent.com/zapret-info/z-i/master/dump.csv

--]]

local NAME = "ruantiblock"

------------------------------ Settings --------------------------------

local Config = {
    -- Тип обновления списка блокировок (antizapret, rublacklist, zapret-info)
    BL_UPDATE_MODE = "antizapret",
    -- Режим обхода блокировок: ip (если провайдер блокирует по ip), hybrid (если провайдер использует DPI, подмену DNS и пр.), fqdn (если провайдер использует DPI, подмену DNS и пр.)
    BLOCK_MODE = "hybrid",
    -- Перенаправлять DNS-запросы на альтернативный DNS-сервер для заблокированных FQDN (или в tor если провайдер блокирует сторонние DNS-серверы) (0 - off, 1 - on)
    ALT_NSLOOKUP = 1,
    -- Альтернативный DNS-сервер ($ONION_DNS_ADDR в ruantiblock.sh (tor), 8.8.8.8 и др.). Если провайдер не блокирует сторонние DNS-запросы, то оптимальнее будет использовать для заблокированных сайтов, например, 8.8.8.8, а не резолвить через tor...
    ALT_DNS_ADDR = "8.8.8.8",
    -- Преобразование кириллических доменов в punycode (0 - off, 1 - on)
    USE_IDN = 0,
    -- Записи (ip, CIDR, FQDN) исключаемые из списка блокировки
    EXCLUDE_ENTRIES = {
        ["youtube.com"] = true,
    },
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
    -- Лимит для субдоменов. При достижении, в конфиг dnsmasq будет добавлен весь домен 2-го ур-ня вместо множества субдоменов
    SD_LIMIT = 16,
    -- В случае если из источника получено менее указанного кол-ва записей, то обновления списков не происходит
    BLLIST_MIN_ENTRS = 30000,
    -- Обрезка www[0-9]. в FQDN (0 - off, 1 - on)
    STRIP_WWW = 1,
    -- Тип idn: внешняя утилита или библиотека lua-idn (standalone, lua)
    IDN_TYPE = "standalone",
    -- Внешняя утилита idn
    IDN_CMD = "idn",
    WGET_CMD = "wget --no-check-certificate -q -O -",
    DATA_DIR = "/opt/var/" .. NAME,
    IPSET_DNSMASQ = NAME .. "-dnsmasq",
    IPSET_IP = NAME .. "-ip-tmp",
    IPSET_CIDR = NAME .. "-cidr-tmp",
    -- Источники блэклиста
    AZ_ALL_URL = "https://api.antizapret.info/all.php?type=csv",
    AZ_IP_URL = "http://api.antizapret.info/group.php?data=ip",
    AZ_FQDN_URL = "http://api.antizapret.info/group.php?data=domain",
    --RBL_ALL_URL = "http://reestr.rublacklist.net/api/current",
    RBL_ALL_URL = "https://api.reserve-rbl.ru/api/current",
    ZI_ALL_URL = "https://raw.githubusercontent.com/zapret-info/z-i/master/dump.csv",
    httpSendHeadersTable = {
        --["User-Agent"] = "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:52.5) Gecko/20100101 Firefox/52.5",
    },
}
Config.__index = Config
Config.__call = true
Config.DNSMASQ_DATA_FILE = Config.DATA_DIR .. "/" .. NAME .. ".dnsmasq"
Config.IP_DATA_FILE = Config.DATA_DIR .. "/" .. NAME .. ".ip"
Config.UPDATE_STATUS_FILE = Config.DATA_DIR .. "/update_status"

local function remapBool(val)
    return (val ~= 0 and val ~= false and val ~= nil) and true or false
end

Config.ALT_NSLOOKUP = remapBool(Config.ALT_NSLOOKUP)
Config.USE_IDN = remapBool(Config.USE_IDN)
Config.STRIP_WWW = remapBool(Config.STRIP_WWW)

-- Import packages

local function prequire(package)
    local result = pcall(require, package)
    if not result then
        return nil
    end
    return require(package)
end

local idn = prequire("idn")
if Config.USE_IDN and Config.IDN_TYPE == "lua" and not idn then
    error("You need to install idn.lua (github.com/haste/lua-idn) or use standalone idn tool... Otherwise 'Config.USE_IDN' must be set to 'false'")
end

local http = prequire("socket.http")
local ltn12 = prequire("ltn12")
if not ltn12 then
    error("You need to install ltn12...")
end

------------------------------ Classes --------------------------------

-- Constructor

function Class(super, t)
    local function instanceConstructor(cls, t)
        local instance = t or {}
        setmetatable(instance, cls)
        instance.__class = cls
        return instance
    end
    local class = t or {}
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

-- Mixin class

local BlackListParser = Class(Config, {
    ipPattern = "%d+%.%d+%.%d+%.%d+",
    cidrPattern = "%d+%.%d+%.%d+%.%d+/%d%d?",
    fqdnPattern = "[a-z0-9_%.%-]-[a-z0-9_%-]+%.[a-z0-9%.%-]",
    url = "http://127.0.0.1",
    recordsSeparator = "\n",
})

function BlackListParser:new(t)
    -- extended instance constructor
    local instance = self(t)
    instance.url = instance["url"] or self.url
    instance.recordsSeparator = instance["recordsSeparator"] or self.recordsSeparator
    instance.ipCount = 0
    instance.cidrCount = 0
    instance.fqdn = {}
    instance.sdCount = {}
    instance.ip = {}
    instance.cidr = {}
    return instance
end

function BlackListParser:convertToPunycode(input)
    local output
    if self.IDN_TYPE == "lua" and idn then
        output = idn.encode(input)
    elseif self.IDN_TYPE == "standalone" then
        local idnHandler = assert(io.popen(self.IDN_CMD .. " \"" .. input .. "\"", "r"))
        output = idnHandler:read("*l")
        idnHandler:close()
    else
        error("Config.IDN_TYPE should be either 'lua' or 'standalone'")
    end
    return (output)
end

function BlackListParser:fillIpTable(val, tname)
    if not self.EXCLUDE_ENTRIES[val] and not self[tname][val] then
        self[tname][val] = true
        local counter = tname .. "Count"
        self[counter] = self[counter] + 1
    end
end

function BlackListParser:fillDomainTables(val)
    if self.STRIP_WWW then val = val:gsub("^www[0-9]?%.", "") end
    local subDomain, secondLevelDomain = val:match("^([a-z0-9_%.%-]-)([a-z0-9_%-]+%.[a-z0-9%-]+)$")
    if secondLevelDomain then
        self.fqdn[val] = secondLevelDomain
        self.sdCount[secondLevelDomain] = (self.sdCount[secondLevelDomain] or 0) + 1
    end
end

function BlackListParser:parseIpString(val)
    if val and val ~= "" then
        for ipEntry in val:gmatch("[0-9][0-9%./]+[0-9]") do
            if ipEntry:match("^" .. self.ipPattern .. "$") then
                self:fillIpTable(ipEntry, "ip")
            elseif ipEntry:match("^" .. self.cidrPattern .. "$") then
                self:fillIpTable(ipEntry, "cidr")
            end
        end
    end
end

function BlackListParser:sink()
    -- Must be reload in the subclass
    error("Method BlackListParser:sink() must be reload in the subclass!")
end

function BlackListParser:compactDomainList(fqdnList, sdCountList)
    local domainTable = {}
    local numEntries = 0
    if self.OPT_EXCLUDE_MASKS and #self.OPT_EXCLUDE_MASKS > 0 then
        for sld in pairs(sdCountList) do
            for _, pattern in ipairs(self.OPT_EXCLUDE_MASKS) do
                if sld:find(pattern) then
                    sdCountList[sld] = 0
                    break
                end
            end
        end
    end
    for fqdn, sld in pairs(fqdnList) do
        if not fqdnList[sld] or fqdn == sld then
            local keyValue = ((self.SD_LIMIT and self.SD_LIMIT > 0 and not self.OPT_EXCLUDE_SLD[sld]) and sdCountList[sld] >= self.SD_LIMIT) and sld or fqdn
            if not self.EXCLUDE_ENTRIES[keyValue] and not domainTable[keyValue] then
                domainTable[keyValue] = true
                numEntries = numEntries + 1
            end
        end
    end
    return domainTable, numEntries
end

function BlackListParser:generateDnsmasqConfig(configPath, domainList)
    local configFile = assert(io.open(configPath, "w"), "Could not open dnsmasq config")
    for fqdn in pairs(domainList) do
        if self.ALT_NSLOOKUP then
            configFile:write(string.format("server=/%s/%s\n", fqdn, self.ALT_DNS_ADDR))
        end
        configFile:write(string.format("ipset=/%s/%s\n", fqdn, self.IPSET_DNSMASQ))
    end
    configFile:close()
end

function BlackListParser:generateIpsetConfig(configPath, t)
    local configFile = assert(io.open(configPath, "w"), "Could not open ipset config")
    for k, v in pairs(t) do
        for ipaddr in pairs(v) do
            configFile:write(string.format("add %s %s\n", k, ipaddr))
        end
    end
    configFile:close()
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
    local retVal
    if http then
        local httpSink = ltn12.sink.chain(self:chunkBuffer(), self:sink())
        retVal, retCode, retHeaders = http.request{ url = url, sink = httpSink, headers = self.httpSendHeadersTable }
        --[[
        for k, v in pairs(retHeaders) do
            print(k, v)
        end
        --]]
        if not retVal or retCode ~= 200 then
            retVal = nil
            print(string.format("Connection error! (%s) URL: %s", retCode, url))
        end
    else
        retVal = nil
    end
    if not retVal then
        local wgetSink = ltn12.sink.chain(self:chunkBuffer(), self:sink())
        retVal = ltn12.pump.all(ltn12.source.file(io.popen(self.WGET_CMD .. " \"" .. url .. "\"", "r")), wgetSink)
    end
    return (retVal == 1) and true or false
end

function BlackListParser:run()
    local domainTable
    local recordsNum = 0
    local returnCode = 0
    if self:getHttpData(self.url) then
        domainTable, recordsNum = self:compactDomainList(self.fqdn, self.sdCount)
        if (recordsNum + self.ipCount + self.cidrCount) > self.BLLIST_MIN_ENTRS then
            self:generateDnsmasqConfig(self.DNSMASQ_DATA_FILE, domainTable)
            self:generateIpsetConfig(self.IP_DATA_FILE, { [self.IPSET_IP] = self.ip, [self.IPSET_CIDR] = self.cidr })
            returnCode = 0
        else
            returnCode = 2
        end
    else
        returnCode = 1
    end
    -- update_status
    local updateStatusFile = assert(io.open(self.UPDATE_STATUS_FILE, "w"), "Could not open 'update_status' file")
    updateStatusFile:write(string.format("%d %d %d", self.ipCount, self.cidrCount, recordsNum))
    updateStatusFile:close()
    return returnCode
end

-- Subclasses

function ipSink(self)
    return function(chunk)
        if chunk and chunk ~= "" then
            for ipString in chunk:gmatch(self.ipStringPattern) do
                self:parseIpString(ipString)
            end
        end
        return true
    end
end

    -- antizapret.info

local Az = Class(BlackListParser, {
    url = Config.AZ_ALL_URL,
    recordsSeparator = "\n",
    ipStringPattern = "(.-)\n",
})

function Az:sink()
    local entryPattern = (self.BLOCK_MODE == "fqdn") and "((.-))" .. self.recordsSeparator or ";([^;]-);([^;]-)" .. self.recordsSeparator
    return function(chunk)
        if chunk and chunk ~= "" then
            for fqdnStr, ipStr in chunk:gmatch(entryPattern) do
                if #fqdnStr > 0 and not fqdnStr:match("^" .. self.ipPattern .. "$") then
                    fqdnStr = fqdnStr:gsub("*%.", ""):gsub("%.$", ""):lower()
                    if fqdnStr:match("^" .. self.fqdnPattern .. "+$") then
                        self:fillDomainTables(fqdnStr)
                    elseif self.USE_IDN and fqdnStr:match("^[^\\/&%?]-[^\\/&%?%.]+%.[^\\/&%?%.]+%.?$") then
                        fqdnStr = self:convertToPunycode(fqdnStr)
                        self:fillDomainTables(fqdnStr)
                    end
                elseif (self.BLOCK_MODE == "hybrid" or fqdnStr:match("^" .. self.ipPattern .. "$")) and #ipStr > 0 then
                    self:parseIpString(ipStr)
                end
            end
        end
        return true
    end
end

local AzFqdn = Class(Az, {
    url = Config.AZ_FQDN_URL
})

local AzIp = Class(Az, {
    url = Config.AZ_IP_URL,
    sink = ipSink,
})

    -- rublacklist.net

local Rbl = Class(BlackListParser, {
    url = Config.RBL_ALL_URL,
    recordsSeparator = "\\n",
    ipStringPattern = "([0-9%./ |]+);.-\\n",
    unicodeHexPattern = "\\u(%x%x%x%x)",
})

function Rbl:hex2unicode(code)
    local n = tonumber(code, 16)
    if n < 128 then
        return string.char(n)
    elseif n < 2048 then
        return string.char(192 + ((n - (n % 64)) / 64), 128 + (n % 64))
    else
        return string.char(224 + ((n - (n % 4096)) / 4096), 128 + (((n % 4096) - (n % 64)) / 64), 128 + (n % 64))
    end
end

function Rbl:sink()
    return function(chunk)
        if chunk and chunk ~= "" then
            for ipStr, fqdnStr in chunk:gmatch("([^;]-);([^;]-);.-" .. self.recordsSeparator) do
                if #fqdnStr > 0 and not fqdnStr:match("^" .. self.ipPattern .. "$") then
                    fqdnStr = fqdnStr:gsub("*%.", ""):gsub("%.$", ""):lower()
                    if self.USE_IDN and fqdnStr:match(self.unicodeHexPattern) then
                        fqdnStr = self:convertToPunycode(fqdnStr:gsub(self.unicodeHexPattern, function(s) return self:hex2unicode(s) end))
                    end
                    if fqdnStr:match("^" .. self.fqdnPattern .. "+$") then
                        self:fillDomainTables(fqdnStr)
                    end
                elseif (self.BLOCK_MODE == "hybrid" or fqdnStr:match("^" .. self.ipPattern .. "$")) and #ipStr > 0 then
                    self:parseIpString(ipStr)
                end
            end
        end
        return true
    end
end

local RblIp = Class(Rbl, {
    sink = ipSink
})

    -- zapret-info

local Zi = Class(Rbl, {
    url = Config.ZI_ALL_URL,
    recordsSeparator = "\n",
    ipStringPattern = "([0-9%./ |]+);.-\n",
})

local ZiIp = Class(Zi, {
    sink = ipSink
})

------------------------------ Run section --------------------------------

local ctxTable = {
    ["ip"] = {["antizapret"] = AzIp, ["rublacklist"] = RblIp, ["zapret-info"] = ZiIp},
    ["fqdn"] = {["antizapret"] = AzFqdn, ["rublacklist"] = Rbl, ["zapret-info"] = Zi},
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
