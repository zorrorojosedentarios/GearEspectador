-- ============================================================
-- GearEspectador v3.0 - WoW 3.3.5a (esMX)
-- Ventana con dos pestanas:
--   1) Mi Equipo  - equipo actual del personaje
--   2) Mejoras    - objetos de bolsas/banco mejores que lo equipado
-- Comando: /ge  /gearcheck
-- ============================================================

local GE = CreateFrame("Frame", "GearEspectadorEventFrame")
GE:RegisterEvent("ADDON_LOADED")

local bancoAbierto = false
local resultados   = {}
local ventana      = nil
local filaFrames   = { equipo = {}, mejoras = {} }

-- ============================================================
-- COLORES DE CALIDAD
-- ============================================================
local QUALITY_COLOR = {
    [0] = "|cff9d9d9d", -- Pobre
    [1] = "|cffffffff", -- Normal
    [2] = "|cff1eff00", -- Poco comun
    [3] = "|cff0070dd", -- Raro
    [4] = "|cffa335ee", -- Epico
    [5] = "|cffff8000", -- Legendario
    [6] = "|cffe6cc80", -- Artefacto
}
local function GetQC(q) return QUALITY_COLOR[q] or QUALITY_COLOR[1] end

-- ============================================================
-- SLOTS CONOCIDOS
-- ============================================================
local SLOT_IDS = { 1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17,18 }
local SLOT_NOMBRES = {
    [1]="Cabeza",     [2]="Cuello",    [3]="Hombros",
    [5]="Pecho",      [6]="Cintura",   [7]="Piernas",
    [8]="Pies",       [9]="Munecas",   [10]="Manos",
    [11]="Anillo 1",  [12]="Anillo 2",
    [13]="Abalorio 1",[14]="Abalorio 2",
    [15]="Espalda",   [16]="Mano Prin.",[17]="Mano Sec.",
    [18]="Distancia",
}
local INVTYPE_A_SLOTS = {
    INVTYPE_HEAD=           {1},
    INVTYPE_NECK=           {2},
    INVTYPE_SHOULDER=       {3},
    INVTYPE_CHEST=          {5},
    INVTYPE_ROBE=           {5},
    INVTYPE_WAIST=          {6},
    INVTYPE_LEGS=           {7},
    INVTYPE_FEET=           {8},
    INVTYPE_WRIST=          {9},
    INVTYPE_HAND=           {10},
    INVTYPE_FINGER=         {11,12},
    INVTYPE_TRINKET=        {13,14},
    INVTYPE_CLOAK=          {15},
    INVTYPE_WEAPON=         {16},
    INVTYPE_2HWEAPON=       {16},
    INVTYPE_WEAPONMAINHAND= {16},
    INVTYPE_SHIELD=         {17},
    INVTYPE_HOLDABLE=       {17},
    INVTYPE_WEAPONOFFHAND=  {17},
    INVTYPE_RANGED=         {18},
    INVTYPE_RELIC=          {18},
}

-- ============================================================
-- DETECCION DE ROL
-- Prioridad: GetShapeshiftForm() > Talentos > Clase
-- Inspirado en TidyPlates_ThreatPlates (Functions.lua)
-- ============================================================
local ROL_COLOR = {
    TANK="0088ff", DPS_MELEE="ff4444", DPS_CASTER="aa44ff", HEALER="44ff88"
}

-- Mapa de formas/posturas/presencias a rol para cada clase
-- GetShapeshiftForm() devuelve el indice de la forma activa (0 = ninguna)
local SHAPESHIFT_TANK = {
    -- WARRIOR: 1=Combate, 2=Defensiva, 3=Berserker
    WARRIOR     = { [2] = true },
    -- DRUID: 1=Oso (Feral Tank)
    DRUID       = { [1] = true },
    -- DEATHKNIGHT presencias: 1=Sangre(DPS), 2=Escarcha(TANK), 3=Profano(DPS)
    -- Confirmado por GearAnalyzer/SpecDetection.lua:622 y API WoW 3.3.5a
    -- Presencia de Escarcha: +80% armor, reduce 8% dmg recibido -> ROL TANQUE
    DEATHKNIGHT = { [2] = true },
    -- PALADIN: sin aura = sin info fiable, se delega a talentos
}

local SHAPESHIFT_HEALER = {
    -- DRUID: 5 = Forma de Arbol de Vida (restauracion)
    DRUID = { [5] = true, [6] = true },
}

local SHAPESHIFT_DPS_MELEE = {
    -- WARRIOR: Postura de Combate (1) o Berserker (3) = DPS
    WARRIOR = { [1] = true, [3] = true },
    -- DRUID: Gato (3) = DPS melee feral
    DRUID   = { [3] = true },
    -- DEATHKNIGHT: Presencia de Sangre (1) = DPS (+15% dmg)
    --              Presencia de Profano (3) = DPS (+15% attack/move speed)
    DEATHKNIGHT = { [1] = true, [3] = true },
}

local function ObtenerRolActual()
    local _, c = UnitClass("player")
    local forma = GetShapeshiftForm()  -- 0 = sin forma/postura/presencia

    -- ── Deteccion por forma/postura/presencia (mas precisa) ───────────────────
    if forma and forma > 0 then
        if SHAPESHIFT_TANK[c] and SHAPESHIFT_TANK[c][forma] then
            return "TANK"
        end
        if SHAPESHIFT_HEALER[c] and SHAPESHIFT_HEALER[c][forma] then
            return "HEALER"
        end
        if SHAPESHIFT_DPS_MELEE[c] and SHAPESHIFT_DPS_MELEE[c][forma] then
            return "DPS_MELEE"
        end
    end

    -- ── Fallback: talentos (cuando no hay forma activa o clase sin forma) ─────
    local t = { 0, 0, 0 }
    for i = 1, GetNumTalentTabs() do
        local _, _, p = GetTalentTabInfo(i); t[i] = p or 0
    end

    if c == "WARRIOR" then
        -- Sin postura activa: detectar por talentos
        if t[3] > t[1] and t[3] > t[2] then return "TANK" end
        return "DPS_MELEE"

    elseif c == "PALADIN" then
        -- Sagrado (t1) = Healer | Proteccion (t2) = Tank | Represalia (t3) = DPS
        if t[1] > t[2] and t[1] > t[3] then return "HEALER" end
        if t[2] > t[1] and t[2] > t[3] then return "TANK" end
        return "DPS_MELEE"

    elseif c == "DEATHKNIGHT" then
        -- Sin presencia activa: usar rating de defensa como indicador de rol tanque
        -- (un DK tanque tiene defense >= 535 para ser inmune a crits)
        -- Fallback secundario: arboles Sangre o Escarcha dominantes -> Tank si tiene def alta
        local defRating = GetCombatRating(CR_DEFENSE_SKILL) or 0
        if defRating > 140 then return "TANK" end  -- ~400 def skill = tanqueable
        return "DPS_MELEE"

    elseif c == "DRUID" then
        -- Equilibrio (t1) = Caster DPS | Feral (t2) = Tank/Cat DPS | Restauracion (t3) = Healer
        if t[3] > t[1] and t[3] > t[2] then return "HEALER" end
        if t[2] > t[1] and t[2] > t[3] then
            -- Feral: sin forma activa asumimos cat DPS (mas comun fuera de combate)
            return "DPS_MELEE"
        end
        return "DPS_CASTER"

    elseif c == "PRIEST" then
        -- Disciplina (t1) = Healer | Sagrado (t2) = Healer | Sombras (t3) = DPS Caster
        if t[3] > t[1] and t[3] > t[2] then return "DPS_CASTER" end
        return "HEALER"

    elseif c == "SHAMAN" then
        -- Elemental (t1) = Caster DPS | Mejora (t2) = Melee DPS | Restauracion (t3) = Healer
        if t[3] > t[1] and t[3] > t[2] then return "HEALER" end
        if t[2] > t[1] and t[2] > t[3] then return "DPS_MELEE" end
        return "DPS_CASTER"

    elseif c == "MAGE" or c == "WARLOCK" then
        return "DPS_CASTER"

    elseif c == "HUNTER" or c == "ROGUE" then
        return "DPS_MELEE"
    end

    return "DPS_MELEE"
end


-- ============================================================
-- PESOS ESTADISTICOS
-- ============================================================
local STAT_WEIGHTS = {
    TANK       = {Stam=1.5,Def=15.0,Dodg=12.0,Parr=12.0,Agi=0.5,Hit=4.0,Armor=1.5,Str=0.3,Exp=15.0,AP=0,Spel=0,Haste=0,Crit=0},
    DPS_MELEE  = {Hit=18.0,ArP=15.0,Str=2.0,Crit=12.0,Haste=11.0,Agi=1.4,AP=10.0,Exp=15.0,Stam=0.2,Spel=0},
    DPS_CASTER = {Hit=14.0,Spel=12.0,Haste=10.0,Crit=8.0,Int=0.4,Spirit=0.2},
    HEALER     = {Mp5=15.0,Spel=12.0,Int=0.6,Haste=9.0,Crit=6.0,Spirit=0.8},
}

-- ============================================================
-- TOOLTIP ESCANER
-- ============================================================
local ScanTip = CreateFrame("GameTooltip","GESpectadorScanTip",nil,"GameTooltipTemplate")
ScanTip:SetOwner(WorldFrame,"ANCHOR_NONE")

-- Abalorios de tanque con efectos de Uso/Proc que no se pueden leer por texto simple
local TANK_TRINKET_SITUATIONAL = {
    [50356] = { score=5000, desc="Mitigacion" }, -- Llave esqueleto
    [50341] = { score=5000, desc="Fisico" },     -- Organo normal
    [50352] = { score=5000, desc="Fisico" },     -- Organo heroico
    [50361] = { score=5000, desc="Magico" },     -- Colmillo normal
    [50364] = { score=5000, desc="Magico" },     -- Colmillo heroico
    [54571] = { score=5000, desc="Fis. Fuerte" },-- Escama normal
    [54591] = { score=5000, desc="Fis. Fuerte" },-- Escama heroica
    [47088] = { score=5000, desc="Max Vida" },   -- Escarabajo normal
    [47276] = { score=5000, desc="Max Vida" },   -- Escarabajo heroico
    [47451] = { score=5000, desc="Max Vida" },   -- Vitalidad normal
    [47498] = { score=5000, desc="Max Vida" },   -- Vitalidad heroica
    [49487] = { score=5000, desc="Especial" },   -- Extra ID proveido
}

local function CalcularScore(link, rol, eqLoc)
    if not link then return 0, {} end
    local itemID = tonumber(link:match("item:(%d+)"))

    
    local ok = pcall(function() 
        ScanTip:SetOwner(WorldFrame,"ANCHOR_NONE")
        ScanTip:ClearLines()
        ScanTip:SetHyperlink(link) 
    end)
    if not ok then return 0, {} end

    local score = 0
    local stats = {}
    
    local pesos = STAT_WEIGHTS[rol]
    if not pesos then return 0, {} end
    
    local tieneMitigacion = false
    local esPiezaArmadura = (eqLoc == "INVTYPE_HEAD" or eqLoc == "INVTYPE_SHOULDER" or eqLoc == "INVTYPE_CHEST" or eqLoc == "INVTYPE_ROBE" or eqLoc == "INVTYPE_HAND" or eqLoc == "INVTYPE_LEGS")

    for i=1, ScanTip:NumLines() do
        local obj = _G["GESpectadorScanTipTextLeft"..i]
        if not obj then break end
        local txt = obj:GetText()
        if txt then
            local lt = txt:lower()
            local function tryAdd(v, s)
                v = tonumber(v) or 0
                s = s:lower()
                if s:find("aguante")   and pesos.Stam   then score=score+v*pesos.Stam;   stats["Aguante"] = (stats["Aguante"] or 0) + v end
                if s:find("agilidad")  and pesos.Agi    then score=score+v*pesos.Agi;    stats["Agilidad"] = (stats["Agilidad"] or 0) + v end
                if s:find("fuerza")    and pesos.Str    then score=score+v*pesos.Str;    stats["Fuerza"] = (stats["Fuerza"] or 0) + v end
                if s:find("intelecto") and pesos.Int    then score=score+v*pesos.Int;    stats["Intelecto"] = (stats["Intelecto"] or 0) + v end
                if s:find("esp")       and pesos.Spirit then score=score+v*pesos.Spirit; stats["Espíritu"] = (stats["Espíritu"] or 0) + v end
            end
            local v1,s1 = txt:match("%+(%d+)%s+(.+)"); if v1 then tryAdd(v1,s1) end
            local v2,s2 = txt:match("(%d+) de (.+)");  if v2 then tryAdd(v2,s2) end

            local nv = tonumber(txt:match("(%d+)") or 0) or 0
            if     lt:find("golpe cr") or lt:find("cr") and lt:find("tico")  then if pesos.Crit   then score=score+nv*pesos.Crit;   stats["Crítico"] = (stats["Crítico"] or 0) + nv end
            elseif lt:find("hechizo") and lt:find("poder")                   then if pesos.Spel   then score=score+nv*pesos.Spel;   stats["Poder Hechizo"] = (stats["Poder Hechizo"] or 0) + nv end
            elseif lt:find("poder de ataque")                                then if pesos.AP     then score=score+nv*pesos.AP;     stats["Poder Ataque"] = (stats["Poder Ataque"] or 0) + nv end
            elseif lt:find("pericia")                                        then if pesos.Exp    then score=score+nv*pesos.Exp;    stats["Pericia"] = (stats["Pericia"] or 0) + nv end
            elseif lt:find("celeridad")                                      then if pesos.Haste  then score=score+nv*pesos.Haste;  stats["Celeridad"] = (stats["Celeridad"] or 0) + nv end
            elseif lt:find("esquive") or lt:find("esquivar")                 then if pesos.Dodg   then score=score+nv*pesos.Dodg;   stats["Esquivar"] = (stats["Esquivar"] or 0) + nv; tieneMitigacion = true end
            elseif lt:find("parada")                                         then if pesos.Parr   then score=score+nv*pesos.Parr;   stats["Parada"] = (stats["Parada"] or 0) + nv; tieneMitigacion = true end
            elseif lt:find("defensa")                                        then if pesos.Def    then score=score+nv*pesos.Def;    stats["Defensa"] = (stats["Defensa"] or 0) + nv; tieneMitigacion = true end
            elseif lt:find("penetraci") and lt:find("armadura")              then if pesos.ArP    then score=score+nv*pesos.ArP;    stats["ArP"] = (stats["ArP"] or 0) + nv end
            elseif lt:find("armadura") and not lt:find("penetraci")          then if pesos.Armor  then score=score+nv*pesos.Armor;  stats["Armadura"] = (stats["Armadura"] or 0) + nv end
            elseif lt:find("impacto") or (lt:find("golpe") and not lt:find("cr")) then if pesos.Hit then score=score+nv*pesos.Hit;  stats["Golpe"] = (stats["Golpe"] or 0) + nv end
            elseif lt:find("cada 5") or lt:find("5 seg")                     then if pesos.Mp5    then score=score+nv*pesos.Mp5;    stats["Mp5"] = (stats["Mp5"] or 0) + nv end
            end
        end
    end
    ScanTip:Hide()
    
    -- Filtro estricto para Tanques: piezas de armadura principal DEBEN tener mitigacion nativa
    if rol == "TANK" and esPiezaArmadura and not tieneMitigacion then
        return 0, {}
    end
    
    -- Bonus manual para abalorios de tanque conocidos (sus procs/usos no se leen bien en el texto)
    if rol == "TANK" and itemID and TANK_TRINKET_SITUATIONAL[itemID] then
        score = score + TANK_TRINKET_SITUATIONAL[itemID].score
    end
    
    return score, stats
end

-- Score con fallback a iLevel si el tooltip no devuelve nada
local function ScoreConFallback(link, rol, iLvl, eqLoc)
    local s, st = CalcularScore(link, rol, eqLoc)
    -- Si el tooltip no pudo parsear nada, usamos iLevel como proxy
    if s == 0 and (iLvl or 0) > 0 then
        -- Revisamos si realmente fallo el parseo o fue el filtro TANK
        local esArmadura = (eqLoc == "INVTYPE_HEAD" or eqLoc == "INVTYPE_SHOULDER" or eqLoc == "INVTYPE_CHEST" or eqLoc == "INVTYPE_ROBE" or eqLoc == "INVTYPE_HAND" or eqLoc == "INVTYPE_LEGS")
        if rol == "TANK" and esArmadura then
            s = 0
        else
            s = (iLvl or 0) * 0.5
        end
    end
    return s, st
end

-- ============================================================
-- ESCANEO
-- ============================================================
local function EscanearYComparar(rol)
    resultados = {}
    local scoreEquip = {}
    local statsEquip = {}
    local iLvlEquip  = {}
    local linkEquip  = {}

    for _,slotID in ipairs(SLOT_IDS) do
        local lk = GetInventoryItemLink("player", slotID)
        linkEquip[slotID] = lk
        if lk then
            local _,_,_,iLvl,_,_,_,_,eqLoc = GetItemInfo(lk)
            iLvlEquip[slotID] = iLvl or 0
            scoreEquip[slotID], statsEquip[slotID] = ScoreConFallback(lk, rol, iLvl, eqLoc)
        else
            iLvlEquip[slotID]  = 0
            scoreEquip[slotID] = 0
            statsEquip[slotID] = {}
        end
        resultados[slotID] = {} -- Array de mejoras
    end

    local bolsas = {}
    for i=0,4 do table.insert(bolsas,{id=i,esBank=false}) end

    for _,bolsa in ipairs(bolsas) do
        local numSlots = GetContainerNumSlots(bolsa.id)
        if numSlots and numSlots>0 then
            for s=1,numSlots do
                local link = GetContainerItemLink(bolsa.id,s)
                if link then
                    local _,_,qual,iLvl,_,_,_,_,eqLoc = GetItemInfo(link)
                    if qual and qual >= 2 and eqLoc and eqLoc~="" and eqLoc~="INVTYPE_BAG"
                       and eqLoc~="INVTYPE_QUIVER" and eqLoc~="INVTYPE_AMMO"
                       and eqLoc~="INVTYPE_THROWN" then
                        local slots = INVTYPE_A_SLOTS[eqLoc]
                        if slots then
                            local itemID = tonumber(link:match("item:(%d+)"))
                            local sBolsa, stBolsa = ScoreConFallback(link, rol, iLvl, eqLoc)
                            for _,slotID in ipairs(slots) do
                                local diff = sBolsa - (scoreEquip[slotID] or 0)
                                local isSituational = rol == "TANK" and itemID and TANK_TRINKET_SITUATIONAL[itemID]
                                
                                local equippedLink = GetInventoryItemLink("player", slotID)
                                local equippedID = equippedLink and tonumber(equippedLink:match("item:(%d+)"))
                                
                                if (diff > 0 or isSituational) and itemID ~= equippedID then
                                    local diffStats = {}
                                    local bestStatName = nil
                                    local bestStatDiff = -99999
                                    local eqSt = statsEquip[slotID] or {}
                                    for k,v in pairs(stBolsa) do
                                        local d = v - (eqSt[k] or 0)
                                        diffStats[k] = d
                                        if d > bestStatDiff then
                                            bestStatDiff = d
                                            bestStatName = k
                                        end
                                    end
                                    for k,v in pairs(eqSt) do
                                        if not stBolsa[k] then diffStats[k] = -v end
                                    end
                                
                                    local descExtra = nil
                                    if isSituational then
                                        descExtra = TANK_TRINKET_SITUATIONAL[itemID].desc
                                        diff = 10000 + sBolsa -- Forzar arriba en la lista
                                    end
                                    table.insert(resultados[slotID], {
                                        linkBolsa = link,
                                        sBolsa    = sBolsa,
                                        iLvlB     = iLvl or 0,
                                        diff      = diff,
                                        esBank    = bolsa.esBank,
                                        desc      = descExtra,
                                        bagID     = bolsa.id,
                                        slotIdx   = s,
                                        diffStats = diffStats,
                                        bestStat  = bestStatName and ("+"..math.floor(bestStatDiff).." "..bestStatName) or nil,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if GE_BankCache then
        for _,link in ipairs(GE_BankCache) do
            local _,_,qual,iLvl,_,_,_,_,eqLoc = GetItemInfo(link)
            if qual and qual >= 2 and eqLoc and eqLoc~="" and eqLoc~="INVTYPE_BAG"
               and eqLoc~="INVTYPE_QUIVER" and eqLoc~="INVTYPE_AMMO"
               and eqLoc~="INVTYPE_THROWN" then
                local slots = INVTYPE_A_SLOTS[eqLoc]
                if slots then
                    local itemID = tonumber(link:match("item:(%d+)"))
                    local sBolsa, stBolsa = ScoreConFallback(link, rol, iLvl, eqLoc)
                    for _,slotID in ipairs(slots) do
                        local diff = sBolsa - (scoreEquip[slotID] or 0)
                        local isSituational = rol == "TANK" and itemID and TANK_TRINKET_SITUATIONAL[itemID]
                        
                        local equippedLink = GetInventoryItemLink("player", slotID)
                        local equippedID = equippedLink and tonumber(equippedLink:match("item:(%d+)"))
                        
                        if (diff > 0 or isSituational) and itemID ~= equippedID then
                            local diffStats = {}
                            local bestStatName = nil
                            local bestStatDiff = -99999
                            local eqSt = statsEquip[slotID] or {}
                            for k,v in pairs(stBolsa) do
                                local d = v - (eqSt[k] or 0)
                                diffStats[k] = d
                                if d > bestStatDiff then
                                    bestStatDiff = d
                                    bestStatName = k
                                end
                            end
                            for k,v in pairs(eqSt) do
                                if not stBolsa[k] then diffStats[k] = -v end
                            end
                        
                            local descExtra = nil
                            if isSituational then
                                descExtra = TANK_TRINKET_SITUATIONAL[itemID].desc
                                diff = 10000 + sBolsa
                            end
                            table.insert(resultados[slotID], {
                                linkBolsa = link,
                                sBolsa    = sBolsa,
                                iLvlB     = iLvl or 0,
                                diff      = diff,
                                esBank    = true,
                                desc      = descExtra,
                                diffStats = diffStats,
                                bestStat  = bestStatName and ("+"..math.floor(bestStatDiff).." "..bestStatName) or nil,
                            })
                        end
                    end
                end
            end
        end
    end

    for slotID, arr in pairs(resultados) do
        table.sort(arr, function(a,b) return a.diff > b.diff end)
        -- Limitar a 4 mejoras
        if #arr > 4 then
            local limit = {}
            for i=1,4 do limit[i]=arr[i] end
            resultados[slotID] = limit
        end
    end
end

-- ============================================================
-- CONSTRUCCION DE VENTANA
-- ============================================================
local VENTA_W = 680
local VENTA_H = 530
local FILA_H  = 40

local function TipBtn(btn, link, diffStats)
    btn._link = link
    btn.diffStats = diffStats
    btn:SetScript("OnEnter", function(self)
        if self._link then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self._link)
            if self.diffStats then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Cambio vs Equipado:", 1, 0.8, 0)
                local hasStats = false
                for k,v in pairs(self.diffStats) do
                    if v > 0 then
                        GameTooltip:AddLine("+"..math.floor(v).." "..k, 0.1, 1, 0.1)
                        hasStats = true
                    end
                end
                for k,v in pairs(self.diffStats) do
                    if v < 0 then
                        GameTooltip:AddLine(math.floor(v).." "..k, 1, 0.1, 0.1)
                        hasStats = true
                    end
                end
                if not hasStats then
                    GameTooltip:AddLine("Mejora por iLvl o Proc", 0.5, 0.5, 0.5)
                end
            end
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function MakeFila(idx)
    if filaFrames.equipo[idx] then return filaFrames.equipo[idx] end
    local content = ventana.content
    local fila = CreateFrame("Frame",nil,content)
    fila:SetHeight(FILA_H)

    local bg = fila:CreateTexture(nil,"BACKGROUND")
    bg:SetAllPoints(); fila.bg = bg

    local sep = fila:CreateTexture(nil,"ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("BOTTOMLEFT",fila,"BOTTOMLEFT",0,0)
    sep:SetPoint("BOTTOMRIGHT",fila,"BOTTOMRIGHT",0,0)
    sep:SetTexture(0.2,0.2,0.2,0.5)

    fila.txtSlot = fila:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    fila.txtSlot:SetPoint("LEFT",fila,"LEFT",8,0)
    fila.txtSlot:SetWidth(78)
    fila.txtSlot:SetJustifyH("LEFT")

    -- Boton item equipado
    local btnE = CreateFrame("Button",nil,fila)
    btnE:SetSize(32,32)
    btnE:SetPoint("LEFT",fila,"LEFT",100,0)
    fila.btnEquip = btnE
    fila.txtEquip = fila:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    fila.txtEquip:SetPoint("LEFT", btnE, "RIGHT", 8, 0)
    fila.txtEquip:SetJustifyH("LEFT")

    -- Botones item mejora (hasta 4)
    fila.mejorasBtns = {}
    for j=1,4 do
        local btnM = CreateFrame("Button",nil,fila)
        btnM:SetSize(32,32)
        btnM:SetPoint("LEFT",fila,"LEFT", 280 + (j-1)*95, 0)
        
        local txtM = btnM:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        txtM:SetPoint("TOPLEFT", btnM, "TOPRIGHT", 4, -4)
        txtM:SetJustifyH("LEFT")
        btnM.txtDiff = txtM

        local txtO = btnM:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        txtO:SetPoint("BOTTOMLEFT", btnM, "BOTTOMRIGHT", 4, 4)
        txtO:SetJustifyH("LEFT")
        btnM.txtOrigen = txtO
        
        fila.mejorasBtns[j] = btnM
    end

    filaFrames.equipo[idx] = fila
    return fila
end

local function CrearVentana()
    if ventana then return ventana end

    local f = CreateFrame("Frame","GESpectadorV3",UIParent)
    f:SetSize(VENTA_W, VENTA_H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames,"GESpectadorV3")

    f:SetBackdrop({
        bgFile  ="Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true, tileSize=32, edgeSize=32,
        insets={left=11,right=12,top=12,bottom=11},
    })
    f:SetBackdropColor(0,0,0,0.97)

    local titleBar = f:CreateTexture(nil,"ARTWORK")
    titleBar:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleBar:SetWidth(340); titleBar:SetHeight(64)
    titleBar:SetPoint("TOP",0,12)

    local titleTxt = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
    titleTxt:SetPoint("TOP",0,-2)
    titleTxt:SetText("|cff00ffffGearEspectador|r  v3.0")

    local closeBtn = CreateFrame("Button",nil,f,"UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT",f,"TOPRIGHT",-4,-4)

    f.subtitulo = f:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    f.subtitulo:SetPoint("TOP",0,-26)
    f.subtitulo:SetText("")

    local btnAct = CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
    btnAct:SetSize(100,24)
    btnAct:SetPoint("TOPRIGHT",f,"TOPRIGHT",-15,-10)
    btnAct:SetText("Actualizar")
    btnAct:SetScript("OnClick", function()
        local rol = ObtenerRolActual()
        EscanearYComparar(rol)
        GE:RefreshAll(rol)
    end)

    local btnInfo = CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
    btnInfo:SetSize(80,24)
    btnInfo:SetPoint("RIGHT",btnAct,"LEFT",-5,0)
    btnInfo:SetText("Info")

    -- Panel de Informacion
    local infoF = CreateFrame("Frame", "GE_InfoFrame", f)
    infoF:SetSize(450, 400)
    infoF:SetPoint("CENTER", UIParent, "CENTER")
    infoF:SetBackdrop({
        bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true, tileSize=32, edgeSize=32,
        insets={left=11, right=12, top=12, bottom=11}
    })
    infoF:SetBackdropColor(0,0,0,1)
    infoF:Hide()
    infoF:SetFrameStrata("FULLSCREEN_DIALOG")
    infoF:SetToplevel(true)
    infoF:SetMovable(true)
    infoF:EnableMouse(true)
    infoF:RegisterForDrag("LeftButton")
    infoF:SetScript("OnDragStart", infoF.StartMoving)
    infoF:SetScript("OnDragStop", infoF.StopMovingOrSizing)
    
    local infoH = infoF:CreateFontString(nil,"OVERLAY","GameFontNormalHuge")
    infoH:SetPoint("TOP", 0, -20)
    infoH:SetText("Acerca de GearEspectador")
    
    local infoTxt = infoF:CreateFontString(nil,"OVERLAY","GameFontNormal")
    infoTxt:SetPoint("TOPLEFT", 25, -60)
    infoTxt:SetPoint("BOTTOMRIGHT", -25, 50)
    infoTxt:SetJustifyH("LEFT")
    infoTxt:SetJustifyV("TOP")
    infoTxt:SetText(
        "|cff00ffaa¿Qué hace?|r\n"..
        "Analiza tu talento actual para determinar tu rol (Tanque, DPS Melee, etc.) y evalúa tu equipo aplicando 'Pesos de Estadísticas' matemáticos.\n\n"..
        "|cff00ffaaVentajas:|r\n"..
        "- Te permite visualizar qué objetos perdidos en tu banco son superiores a tu equipo.\n"..
        "- Equipa recomendaciones directamente desde la interfaz con un simple clic.\n"..
        "- Extremadamente rápido para equiparte equipo de off-spec de tus bolsas.\n\n"..
        "|cffff4444Limitaciones y Falencias:|r\n"..
        "- |cffffff00No calcula 'Capps'|r (límites de Golpe o Pericia). Puede seguir recomendando Golpe aunque ya estés capeado.\n"..
        "- |cffffff00No simula el DPS real.|r Para maximizar al 100% el daño final se recomienda usar herramientas como Rawr.\n"..
        "- |cffffff00Abalorios y Procs:|r Los efectos raros o procs especiales no se pueden medir con exactitud, salvo los abalorios situacionales explícitamente programados en el código."
    )
    
    local btnCloseI = CreateFrame("Button",nil,infoF,"UIPanelButtonTemplate")
    btnCloseI:SetSize(100,24)
    btnCloseI:SetPoint("BOTTOM",0,15)
    btnCloseI:SetText("Entendido")
    btnCloseI:SetScript("OnClick",function() infoF:Hide() end)

    btnInfo:SetScript("OnClick", function()
        if infoF:IsShown() then infoF:Hide() else infoF:Show() end
    end)

    local inset = CreateFrame("Frame",nil,f)
    inset:SetPoint("TOPLEFT",f,"TOPLEFT",14,-44)
    inset:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-14,14)
    f.inset = inset

    local bgHeader = inset:CreateTexture(nil,"BACKGROUND")
    bgHeader:SetHeight(22)
    bgHeader:SetPoint("TOPLEFT",inset,"TOPLEFT",0,0)
    bgHeader:SetPoint("TOPRIGHT",inset,"TOPRIGHT",0,0)
    bgHeader:SetTexture(0.08,0.08,0.28,0.95)

    local function MH(txt,x)
        local h=inset:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        h:SetPoint("TOPLEFT",inset,"TOPLEFT",x,-4)
        h:SetText("|cffffdd00"..txt.."|r")
    end
    MH("Ranura",8); MH("Equipado",100); MH("Mejoras Sugeridas (Opciones)",280)

    local scroll = CreateFrame("ScrollFrame","GESpectadorScroll",inset,"UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",inset,"TOPLEFT",0,-24)
    scroll:SetPoint("BOTTOMRIGHT",inset,"BOTTOMRIGHT",-22,0)

    local content = CreateFrame("Frame",nil,scroll)
    content:SetWidth(VENTA_W-52)
    content:SetHeight(1)
    scroll:SetScrollChild(content)
    f.content = content

    ventana = f
    return f
end

-- ============================================================
-- REFRESH GLOBAL
-- ============================================================
function GE:RefreshAll(rol)
    rol = rol or ObtenerRolActual()
    local f = ventana; if not f then return end

    local rolHex = ROL_COLOR[rol] or "ffffff"
    local bancoTxt = (GE_BankCache and #GE_BankCache > 0)
        and "|cff44ff44[Banco en Cache ("..#GE_BankCache.." items)]|r"
        or  "|cffff8800[Abre el banco para guardarlo]|r"
    f.subtitulo:SetText("Rol: |cff"..rolHex..rol.."|r   "..bancoTxt)

    for _,fr in ipairs(filaFrames.equipo) do fr:Hide() end

    local y = 0
    for i,slotID in ipairs(SLOT_IDS) do
        local fila = MakeFila(i)
        fila:SetPoint("TOPLEFT",f.content,"TOPLEFT",0,-y)
        fila:SetPoint("TOPRIGHT",f.content,"TOPRIGHT",0,-y)
        fila:Show()

        if i%2==0 then fila.bg:SetTexture(0.07,0.07,0.18,0.80)
        else            fila.bg:SetTexture(0.04,0.04,0.10,0.80) end

        fila.txtSlot:SetText("|cffffff99"..SLOT_NOMBRES[slotID].."|r")

        -- Equipado
        local linkEq = GetInventoryItemLink("player",slotID)
        if linkEq then
            local _,_,_,iLvlEq,_,_,_,_,eqLocEq,texE = GetItemInfo(linkEq)
            local sEq = ScoreConFallback(linkEq,rol,iLvlEq,eqLocEq)
            fila.btnEquip:SetNormalTexture(texE or "Interface\\Icons\\INV_Misc_QuestionMark")
            fila.txtEquip:SetText("|cff888888"..string.format("%.0f",sEq).." pts\niL"..(iLvlEq or "?").."|r")
        else
            fila.btnEquip:SetNormalTexture(nil)
            fila.txtEquip:SetText("|cff555555(vacio)|r")
        end
        TipBtn(fila.btnEquip, linkEq, nil)

        -- Mejoras (hasta 4)
        local arr = resultados[slotID] or {}
        for j=1,4 do
            local btnM = fila.mejorasBtns[j]
            local mej = arr[j]
            if mej then
                local _,_,_,_,_,_,_,_,_,texB = GetItemInfo(mej.linkBolsa)
                btnM:SetNormalTexture(texB or "Interface\\Icons\\INV_Misc_QuestionMark")
                
                local dTxt = mej.bestStat or string.format("%.1f pts", mej.diff)
                if mej.desc then
                    dTxt = mej.desc
                end
                
                btnM.txtDiff:SetText("|cff00ff88"..dTxt.."|r")
                
                if mej.esBank then
                    btnM.txtOrigen:SetText("|cff44aaffBanco|r")
                else
                    btnM.txtOrigen:SetText("|cff44ffaaBolsa|r")
                end
                
                TipBtn(btnM, mej.linkBolsa, mej.diffStats)
                
                btnM:SetScript("OnClick", function()
                    if not mej.esBank and mej.bagID and mej.slotIdx then
                        ClearCursor()
                        PickupContainerItem(mej.bagID, mej.slotIdx)
                        EquipCursorItem(slotID)
                    else
                        DEFAULT_CHAT_FRAME:AddMessage("|cff00ffffGearEspectador:|r El objeto esta en el banco. Pasalo a tu mochila primero.")
                    end
                end)
                
                btnM:Show()
            else
                btnM:Hide()
                btnM:SetScript("OnClick", nil)
            end
        end

        y = y + FILA_H
    end
    f.content:SetHeight(y+8)
end

-- ============================================================
-- TOGGLE
-- ============================================================
local function Toggle()
    local f = CrearVentana()
    if f:IsShown() then f:Hide(); return end

    local rol = ObtenerRolActual()
    EscanearYComparar(rol)
    GE:RefreshAll(rol)
    f:Show()
end

-- ============================================================
-- EVENTOS
-- ============================================================
GE:SetScript("OnEvent", function(self,event,...)
    if event=="ADDON_LOADED" and select(1,...) == "GearEspectador" then
        GE_BankCache = GE_BankCache or {}
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ff00GearEspectador v3.0 cargado.|r "
            .."Usa |cffffff00/ge|r para abrir la ventana."
        )
        self:RegisterEvent("BANKFRAME_OPENED")
        self:RegisterEvent("BANKFRAME_CLOSED")
        self:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
        self:RegisterEvent("BAG_UPDATE")
        self:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
        self:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
        self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    elseif event=="BANKFRAME_OPENED" or ((event=="PLAYERBANKSLOTS_CHANGED" or event=="BAG_UPDATE") and bancoAbierto) then
        if event=="BANKFRAME_OPENED" then bancoAbierto = true end
        
        -- Si es un update de bolsa pero no es del banco, lo ignoramos para optimizar
        if event=="BAG_UPDATE" then
            local bagID = select(1, ...)
            if bagID >= 0 and bagID <= 4 then return end -- bolsas del jugador
        end

        GE_BankCache = {}
        local bankBags = {-1, 5, 6, 7, 8, 9, 10, 11}
        for _,bag in ipairs(bankBags) do
            local numSlots = GetContainerNumSlots(bag)
            if numSlots and numSlots>0 then
                for s=1,numSlots do
                    local link = GetContainerItemLink(bag,s)
                    if link then table.insert(GE_BankCache, link) end
                end
            end
        end
        if ventana and ventana:IsShown() then
            local rol = ObtenerRolActual()
            EscanearYComparar(rol)
            GE:RefreshAll(rol)
        end
    elseif event=="BANKFRAME_CLOSED" then
        bancoAbierto = false
        -- NO borramos la cache aqui, asi se guarda para la proxima sesion
    elseif event=="UPDATE_SHAPESHIFT_FORM" or event=="ACTIVE_TALENT_GROUP_CHANGED" or event=="PLAYER_EQUIPMENT_CHANGED" then
        -- Actualizar automaticamente la interfaz si esta visible
        if ventana and ventana:IsShown() then
            local rol = ObtenerRolActual()
            EscanearYComparar(rol)
            GE:RefreshAll(rol)
        end
    end
end)

-- ============================================================
-- COMANDOS
-- ============================================================
SLASH_GEARESPECTADOR1 = "/ge"
SLASH_GEARESPECTADOR2 = "/gearcheck"
SlashCmdList["GEARESPECTADOR"] = function() Toggle() end

-- ============================================================
-- BOTON DEL MINIMAPA
-- ============================================================
local minimapBtn = CreateFrame("Button", "GearEspectadorMinimapBtn", Minimap)
minimapBtn:SetSize(32, 32)
minimapBtn:SetMovable(true)
minimapBtn:EnableMouse(true)
minimapBtn:RegisterForDrag("LeftButton")
minimapBtn:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 0, 0)
minimapBtn:SetFrameStrata("MEDIUM")
minimapBtn:SetFrameLevel(8)

local icon = minimapBtn:CreateTexture(nil, "BACKGROUND")
-- NOTA: WoW 3.3.5a requiere TGA o BLP. La imagen 'gearespectator.png' debe ser convertida a 'gearespectador.tga'
icon:SetTexture("Interface\\AddOns\\GearEspectador\\gearespectador.tga")
icon:SetSize(21, 21)
icon:SetPoint("CENTER", 0, 0)

local border = minimapBtn:CreateTexture(nil, "OVERLAY")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetSize(54, 54)
border:SetPoint("TOPLEFT")

minimapBtn:SetScript("OnClick", function()
    Toggle()
end)

minimapBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cff00ffaaGearEspectador|r")
    GameTooltip:AddLine("Clic izquierdo para abrir/cerrar", 1, 1, 1)
    GameTooltip:Show()
end)
minimapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

minimapBtn:SetScript("OnUpdate", function(self)
    if self.isDragging then
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        local radius = (Minimap:GetWidth() / 2) + 10
        local dx, dy = px - mx, py - my
        local angle = math.atan2(dy, dx)
        local x = math.cos(angle) * radius
        local y = math.sin(angle) * radius
        self:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end
end)

minimapBtn:SetScript("OnDragStart", function(self)
    self.isDragging = true
end)
minimapBtn:SetScript("OnDragStop", function(self)
    self.isDragging = false
end)
