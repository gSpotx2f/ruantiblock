--[[
    FQDN

    Модуль для следующих источников:
     http://api.antizapret.info/group.php?data=domain
     http://reestr.rublacklist.net/api/current

    Исходный скрипт из статьи: https://habrahabr.ru/post/270657
--]]

local dataDir = "/opt/var/ruantiblock"
local config = {
    wgetCmd = "wget -T 60 -q -O -",
    blSource = "antizapret",    -- antizapret или rublacklist
    groupBySld = 16,    -- количество поддоменов после которого в список вносится весь домен второго уровня целиком
    excludeEntries = {  -- записи, исключаемые из итоговых файлов (ip, FQDN)
        ["youtube.com"] = true
    },
    --neverGroupMasks = { "^%a%a%a?.%a%a$" },   -- не распространять на org.ru, net.ua и аналогичные
    neverGroupMasks = {},
    neverGroupDomains = {
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
    stripWww = true,
    convertIdn = false,
    altNsLookup = true,    -- отправлять DNS запросы заблокированных доменов через альтернативный DNS
    blMinimumEntries = 1000,    -- костыль если список получился короче, значит что-то пошло не так и конфиги не обновляем
    dnsmasqConfigPath = dataDir .. "/ruantiblock.dnsmasq",
    ipsetConfigPath = dataDir .. "/ruantiblock.ip",
    updateStatusPath = dataDir .. "/update_status",
    ipsetDns = "ruantiblock-dnsmasq",
    ipsetIp = "ruantiblock-ip-tmp",
    altDnsAddr = "8.8.8.8",
    bllistUrl1="http://api.antizapret.info/group.php?data=domain",
    bllistUrl2="http://reestr.rublacklist.net/api/current"
}


local function prequire(package)
    local result, err = pcall(function() require(package) end)
    if not result then
        return nil, err
    end
    return require(package)     -- return the package value
end

local idn = prequire("idn")
if (not idn) and (config.convertIdn) then
    error("you need either put idn.lua (github.com/haste/lua-idn) in script dir  or set 'convertIdn' to false")
end

local http = prequire("socket.http")
if not http then
    local ltn12 = require("ltn12")
end
if not ltn12 then
    error("you need either install luasocket package (prefered) or put ltn12.lua in script dir")
end

local function hex2unicode(code)
    local n = tonumber(code, 16)
    if (n < 128) then
        return string.char(n)
    elseif (n < 2048) then
        return string.char(192 + ((n - (n % 64)) / 64), 128 + (n % 64))
    else
        return string.char(224 + ((n - (n % 4096)) / 4096), 128 + (((n % 4096) - (n % 64)) / 64), 128 + (n % 64))
    end
end

local function rublacklistExtractDomains()
    local currentRecord = ""
    local buffer = ""
    local bufferPos = 1
    local streamEnded = false
    return function(chunk)
        local retVal = ""
        if chunk == nil then
            streamEnded = true
        else
            buffer = buffer .. chunk
        end

        while true do
            local escapeStart, escapeEnd, escapedChar = buffer:find("\\(.)", bufferPos)
            if escapedChar then
                currentRecord = currentRecord .. buffer:sub(bufferPos, escapeStart - 1)
                bufferPos = escapeEnd + 1
                if escapedChar == "n" then
                    retVal = currentRecord
                    break
                elseif escapedChar == "u" then
                    currentRecord = currentRecord .. "\\u"
                else
                    currentRecord = currentRecord .. escapedChar
                end
            else
                currentRecord = currentRecord .. buffer:sub(bufferPos, #buffer)
                buffer = ""
                bufferPos = 1
                if streamEnded then
                    if currentRecord == "" then
                        retVal = nil
                    else
                        retVal = currentRecord
                    end
                end
                break
            end
        end
        if retVal and (retVal ~= "") then
            currentRecord = ""
            retVal = retVal:match("^[^;]*;([^;]+);[^;]*;[^;]*;[^;]*;[^;]*.*$")
            if retVal then
                retVal = retVal:gsub("\\u(%x%x%x%x)", hex2unicode)
            else
                retVal = ""
            end
        end
        return (retVal)
    end
end

local function antizapretExtractDomains()
    local currentRecord = ""
    local buffer = ""
    local bufferPos = 1
    local streamEnded = false
    return function(chunk)
        local haveOutput = 0
        local retVal = ""
        if chunk == nil then
            streamEnded = true
        else
            buffer = buffer .. chunk
        end
        local newlinePosition = buffer:find("\n", bufferPos)
        if newlinePosition then
            currentRecord = currentRecord .. buffer:sub(bufferPos, newlinePosition - 1)
            bufferPos = newlinePosition + 1
            retVal = currentRecord
        else
            currentRecord = currentRecord .. buffer:sub(bufferPos, #buffer)
            buffer = ""
            bufferPos = 1
            if streamEnded then
                if currentRecord == "" then
                    retVal = nil
                else
                    retVal = currentRecord
                end
            end
        end
        if retVal and (retVal ~= "") then
            currentRecord = ""
        end
        return (retVal)
    end
end

local function normalizeFqdn()
    return function(chunk)
        if chunk and (chunk ~= "") then
            if config["stripWww"] then chunk = chunk:gsub("^www%.", "") end
            if idn and config["convertIdn"] then chunk = idn.encode(chunk) end
            if #chunk > 255 then chunk = "" end
            chunk = chunk:lower()
        end
        return (chunk)
    end
end

local function cunstructTables(bltables)
    bltables = bltables or { fqdn = {}, sdcount = {}, ips = {}, ips_counter = 0 }
    local f = function(blEntry, err)
        if blEntry and (blEntry ~= "") then
            if blEntry:match("^%d+%.%d+%.%d+%.%d+$") then
                -- ip адреса - в отдельную таблицу для iptables
                if not config.excludeEntries[blEntry] and not bltables.ips[blEntry] then
                    bltables.ips[blEntry] = true
                    bltables.ips_counter = bltables.ips_counter + 1
                end
            else
                -- как можем проверяем, FQDN ли это. заодно выделяем домен 2 уровня (если в bl станут попадать TLD - дело плохо :))
                local subDomain, secondLevelDomain = blEntry:match("^([a-z0-9%-%.]-)([a-z0-9%-]+%.[a-z0-9%-]+)$")
                if secondLevelDomain then
                    bltables.fqdn[blEntry] = secondLevelDomain
                    if 1 > 0 then
                        bltables.sdcount[secondLevelDomain] = (bltables.sdcount[secondLevelDomain] or 0) + 1
                    end
                end
            end
        end
        return 1
    end
    return f, bltables
end

local function compactDomainList(fqdnList, subdomainsCount)
    local domainTable = {}
    local numEntries = 0
    if config.groupBySld and (config.groupBySld > 0) then
        for sld in pairs(subdomainsCount) do
            if config.neverGroupDomains[sld] then
                subdomainsCount[sld] = 0
                break
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
        if (not fqdnList[sld]) or (fqdn == sld) then
            local keyValue;
            if config.groupBySld and (config.groupBySld > 0) and (subdomainsCount[sld] > config.groupBySld) then
                keyValue = sld
            else
                keyValue = fqdn
            end
            if not config.excludeEntries[keyValue] and not domainTable[keyValue] then
                domainTable[keyValue] = true
                numEntries = numEntries + 1
            end
        end
    end
    return domainTable, numEntries
end

local function generateDnsmasqConfig(configPath, domainList)
    local configFile = assert(io.open(configPath, "w"), "could not open dnsmasq config")
    for fqdn in pairs(domainList) do
        if config.altNsLookup then
            configFile:write(string.format("server=/%s/%s\n", fqdn, config.altDnsAddr))
        end
        configFile:write(string.format("ipset=/%s/%s\n", fqdn, config.ipsetDns))
    end
    configFile:close()
end

local function generateIpsetConfig(configPath, ipList)
    local configFile = assert(io.open(configPath, "w"), "could not open ipset config")
    for ipaddr in pairs(ipList) do
            configFile:write(string.format("add %s %s\n", config.ipsetIp, ipaddr))
    end
    configFile:close()
end

local retVal, retCode, url
local output, bltables = cunstructTables()

if config.blSource == "rublacklist" then
    output = ltn12.sink.chain(ltn12.filter.chain(rublacklistExtractDomains(), normalizeFqdn()), output)
    url = config.bllistUrl2
elseif config.blSource == "antizapret" then
    output = ltn12.sink.chain(ltn12.filter.chain(antizapretExtractDomains(), normalizeFqdn()), output)
    url = config.bllistUrl1
else
    error("blacklist source should be either 'rublacklist' or 'antizapret'")
end

if http then
    retVal, retCode = http.request { url = url, sink = output }
else
    retVal, retCode = ltn12.pump.all(ltn12.source.file(io.popen(config.wgetCmd .. " " .. url)), output)
end

local domainTable returnCode=0

if (retVal == 1) and ((retCode == 200) or (http == nil)) then
    domainTable, recordsNum = compactDomainList(bltables.fqdn, bltables.sdcount)
    if (recordsNum) > config.blMinimumEntries then
        generateDnsmasqConfig(config.dnsmasqConfigPath, domainTable)
        generateIpsetConfig(config.ipsetConfigPath, bltables.ips)
        returnCode=0
    else
        returnCode=2
    end
else
    returnCode=1
end

-- запись в update_status
local updateStatusFile = assert(io.open(config.updateStatusPath, "w"), "could not open update_status file")
updateStatusFile:write(string.format("%d %d %d", bltables.ips_counter, 0, recordsNum))
updateStatusFile:close()

os.exit(returnCode)
