--[[
    IP, FQDN, CIDR

    Модуль для следующих источников:
     http://api.antizapret.info/all.php?type=csv
     http://api.antizapret.info/group.php?data=ip
     http://api.antizapret.info/group.php?data=domain
     http://reestr.rublacklist.net/api/current

    Исходный скрипт из статьи: https://habrahabr.ru/post/270657
--]]

local config = {
    dataDir = "/opt/var/ruantiblock",
    wgetCmd = "wget -q -O -",
    blSource = "antizapret",    -- antizapret или rublacklist
    blockMode = "hybrid",  -- ip, fqdn, hybrid
    groupBySld = 16,    -- количество поддоменов после которого в список вносится весь домен второго уровня целиком
    excludeEntries = {  -- записи, исключаемые из итоговых файлов (ip, FQDN, CIDR)
        ["youtube.com"] = true
    },
    neverGroupSld = {
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
        ["co.uk"] = true
    },
    neverGroupMasks = {},   -- { "^%a%a%a?.%a%a$" },    -- не распространять на org.ru, net.ua и аналогичные
    stripWww = true,
    idnCmd = "idn", -- внешняя утилита idn
    convertIdn = true,
    idnType = "standalone",   -- standalone или lua. Тип idn: внешняя утилита или библиотека lua-idn
    altNsLookup = true,    -- отправлять DNS запросы заблокированных доменов через альтернативный DNS
    blMinimumEntries = 1000,    -- костыль если список получился короче, значит что-то пошло не так и конфиги не обновляем
    ipsetDns = "ruantiblock-dnsmasq",
    ipsetIp = "ruantiblock-ip-tmp",
    ipsetCidr = "ruantiblock-cidr-tmp",
    altDnsAddr = "8.8.8.8",
    bllistUrl1_0="http://api.antizapret.info/all.php?type=csv",
    bllistUrl1_1="http://api.antizapret.info/group.php?data=ip",
    bllistUrl1_2="http://api.antizapret.info/group.php?data=domain",
    bllistUrl2="http://reestr.rublacklist.net/api/current",
    --bllistUrl2="http://api.reserve-rbl.ru/api/current",
}
config.dnsmasqConfigPath = config.dataDir .. "/ruantiblock.dnsmasq"
config.ipsetConfigPath = config.dataDir .. "/ruantiblock.ip"
config.updateStatusPath = config.dataDir .. "/update_status"

local ipPattern = "%d+%.%d+%.%d+%.%d+"
local cidrPattern = ipPattern .. "[/]%d[%d]?"
local fqdnPattern = "[a-z0-9_%-%.]-[a-z0-9_%-]+%.[a-z0-9%-%.]"
local blTables = {
    ["ipCount"] = 0,
    ["cidrCount"] = 0,
    ["fqdn"] = {},
    ["sdCount"] = {},
    ["ip"] = {},
    ["cidr"] = {},
}

local function prequire(package)
    local result = pcall(require, package)
    if not result then
        return nil
    end
    return require(package)
end

local idn = prequire("idn")
if config.convertIdn and config.idnType == "lua" and not idn then
    error("You need to install idn.lua (github.com/haste/lua-idn) or use standalone idn tool... Otherwise 'config.convertIdn' must be set to 'false'")
end

local http = prequire("socket.http")
local ltn12 = prequire("ltn12")
if not ltn12 then
    error("You need to install ltn12...")
end

local function hex2unicode(code)
    local n = tonumber(code, 16)
    if n < 128 then
        return string.char(n)
    elseif n < 2048 then
        return string.char(192 + ((n - (n % 64)) / 64), 128 + (n % 64))
    else
        return string.char(224 + ((n - (n % 4096)) / 4096), 128 + (((n % 4096) - (n % 64)) / 64), 128 + (n % 64))
    end
end

local function convertToPunycode(input)
    local output
    if config["idnType"] == "lua" and idn then
        output = idn.encode(input)
    elseif config["idnType"] == "standalone" then
        local idnHandler = assert(io.popen(config.idnCmd .. " \"" .. input .. "\"", "r"), "Standalone idn returns an error")
        output = idnHandler:read("*l")
        idnHandler:close()
    else
        error("idnType should be either 'lua' or 'standalone'")
    end
    return (output)
end

local function chunkBuffer(recordsSeparator)
    local recordsSeparator = recordsSeparator
    local buff = ""
    local retValue = ""
    local lastChunk
    return function(chunk)
        if lastChunk then
            return nil
        end
        if chunk then
            buff = buff .. chunk
            local lastRsPosition = select(2, buff:find("^.*" .. recordsSeparator))
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

local function fillIpTable(val, tname)
    if not config.excludeEntries[val] and not blTables[tname][val] then
        blTables[tname][val] = true
        local counter = tname .. "Count"
        blTables[counter] = blTables[counter] + 1
    end
end

local function fillDomainTables(val)
    if config["stripWww"] then val = val:gsub("^www%.", "") end
    local subDomain, secondLevelDomain = val:match("^([a-z0-9_%-%.]-)([a-z0-9_%-]+%.[a-z0-9%-]+)$")
    if secondLevelDomain then
        blTables.fqdn[val] = secondLevelDomain
        blTables.sdCount[secondLevelDomain] = (blTables.sdCount[secondLevelDomain] or 0) + 1
    end
end

local function parseIpString(val)
    if val and val ~= "" then
        for ipEntry in val:gmatch("[0-9%./]+") do
            if ipEntry:match("^" .. ipPattern .. "$") then
                fillIpTable(ipEntry, "ip")
            elseif ipEntry:match("^" .. cidrPattern .. "$") then
                fillIpTable(ipEntry, "cidr")
            end
        end
    end
end

local function ipSink(chunk)
    if chunk and chunk ~= "" then
        local ipStringPattern = (config.blSource == "antizapret") and "(.-)\n" or "([^;]+);[^;]-;[^;]-;[^;]-;[^;]-;[^;]-\\n"
        for ipString in chunk:gmatch(ipStringPattern) do
            parseIpString(ipString)
        end
    end
    return true
end

local function azFqdnSink(chunk)
    if chunk and chunk ~= "" then
        --chunk = chunk:gsub("&amp;", "")
        local entryPattern = (config.blockMode == "fqdn") and "((.-))\n" or "[^;]+;[^;]-;([^;]-);([^;]+)\n"
        for fqdnStr, ipStr in chunk:gmatch(entryPattern) do
            if #fqdnStr > 0 and not fqdnStr:match("^" .. ipPattern .. "$") then
                fqdnStr = fqdnStr:gsub("*%.", ""):gsub("%.$", ""):lower()
                if fqdnStr:match("^" .. fqdnPattern .. "+$") then
                    fillDomainTables(fqdnStr)
                elseif config["convertIdn"] and fqdnStr:match("^[^\\/&%?]-[^\\/&%?%.]+%.[^\\/&%?%.]+%.?$") then
                    fqdnStr = convertToPunycode(fqdnStr)
                    fillDomainTables(fqdnStr)
                end
            elseif (config.blockMode == "hybrid" or fqdnStr:match("^" .. ipPattern .. "$")) and #ipStr > 0 then
                parseIpString(ipStr)
            end
        end
    end
    return true
end

local function rblFqdnSink(chunk)
    if chunk and chunk ~= "" then
        --chunk = chunk:gsub("&amp;", "")
        for ipStr, fqdnStr in chunk:gmatch("([^;]+);([^;]-);[^;]-;[^;]-;[^;]-;[^;]-\\n") do
            if #fqdnStr > 0 and not fqdnStr:match("^" .. ipPattern .. "$") then
                fqdnStr = fqdnStr:gsub("*%.", ""):gsub("%.$", ""):lower()
                if config["convertIdn"] then
                    fqdnStr = fqdnStr:gsub("\\u(%x%x%x%x)", function(s) return convertToPunycode(hex2unicode(s)) end)
                end
                if fqdnStr:match("^" .. fqdnPattern .. "+$") then
                    fillDomainTables(fqdnStr)
                end
            elseif (config.blockMode == "hybrid" or fqdnStr:match("^" .. ipPattern .. "$")) and #ipStr > 0 then
                parseIpString(ipStr)
            end
        end
    end
    return true
end

local function compactDomainList(fqdnList, subdomainsCount)
    local domainTable = {}
    local numEntries = 0
    if config.groupBySld and config.groupBySld > 0 then
        for sld in pairs(subdomainsCount) do
            if config.neverGroupSld[sld] then
                subdomainsCount[sld] = 0
            end
            for _, pattern in ipairs(config.neverGroupMasks) do
                if sld:find(pattern) then
                    subdomainsCount[sld] = 0
                    break
                end
            end
        end
    end
    for fqdn, sld in pairs(fqdnList) do
        if not fqdnList[sld] or fqdn == sld then
            local keyValue = ((config.groupBySld and config.groupBySld > 0) and subdomainsCount[sld] > config.groupBySld) and sld or fqdn
            if not config.excludeEntries[keyValue] and not domainTable[keyValue] then
                domainTable[keyValue] = true
                numEntries = numEntries + 1
            end
        end
    end
    return domainTable, numEntries
end

local function generateDnsmasqConfig(configPath, domainList)
    local configFile = assert(io.open(configPath, "w"), "Could not open dnsmasq config")
    for fqdn in pairs(domainList) do
        if config.altNsLookup then
            configFile:write(string.format("server=/%s/%s\n", fqdn, config.altDnsAddr))
        end
        configFile:write(string.format("ipset=/%s/%s\n", fqdn, config.ipsetDns))
    end
    configFile:close()
end

local function generateIpsetConfig(configPath, t)
    local configFile = assert(io.open(configPath, "w"), "Could not open ipset config")
    for k, v in pairs(t) do
        for ipaddr in pairs(v) do
            configFile:write(string.format("add %s %s\n", k, ipaddr))
        end
    end
    configFile:close()
end

local retVal, retCode, url, rs, sink

if config.blSource == "antizapret" then
    sink = (config.blockMode == "fqdn" or config.blockMode == "hybrid") and azFqdnSink or ipSink
    url = (config.blockMode == "fqdn") and config.bllistUrl1_2 or ((config.blockMode == "hybrid") and config.bllistUrl1_0 or config.bllistUrl1_1)
    rs = "\n"
elseif config.blSource == "rublacklist" then
    sink = (config.blockMode == "fqdn" or config.blockMode == "hybrid") and rblFqdnSink or ipSink
    url = config.bllistUrl2
    rs = "\\n"
else
    error("Blacklist source should be either 'rublacklist' or 'antizapret'")
end

local output = ltn12.sink.chain(chunkBuffer(rs), sink)

if http then
    retVal, retCode = http.request{ url = url, sink = output }
else
    retVal, retCode = ltn12.pump.all(ltn12.source.file(io.popen(config.wgetCmd .. " " .. url, "r")), output)
end

local domainTable, recordsNum
local returnCode = 0

if retVal == 1 and (retCode == 200 or not http) then
    domainTable, recordsNum = compactDomainList(blTables.fqdn, blTables.sdCount)
    if (recordsNum + blTables.ipCount + blTables.cidrCount) > config.blMinimumEntries then
        generateDnsmasqConfig(config.dnsmasqConfigPath, domainTable)
        generateIpsetConfig(config.ipsetConfigPath, { [config.ipsetIp] = blTables.ip, [config.ipsetCidr] = blTables.cidr })
        returnCode = 0
    else
        returnCode = 2
    end
else
    returnCode = 1
end

-- запись в update_status
local updateStatusFile = assert(io.open(config.updateStatusPath, "w"), "Could not open 'update_status' file")
updateStatusFile:write(string.format("%d %d %d", blTables.ipCount, blTables.cidrCount, recordsNum))
updateStatusFile:close()

os.exit(returnCode)
