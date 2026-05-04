local ADDON_NAME = ...

local math = math
local table = table
local string = string
local ipairs = ipairs
local pairs = pairs
local tonumber = tonumber
local tostring = tostring
local type = type
local unpack = unpack
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local UnitAffectingCombat = UnitAffectingCombat

-- ImpTracker estimates and decorates Blizzard cooldown icons. Keep it inside
-- normal addon Lua; no external helpers or hidden-state tricks.
local TARGET_AURA_NAME = "Wild Imp"
local MAX_AURA_SLOTS = 255

-- Spell IDs and tuning used by the local Demonology model.
-- Recheck these when the Midnight spell dump changes.
local HAND_OF_GULDAN_SPELL_ID = 105174
local IMPLOSION_SPELL_ID = 196277
local POWER_SIPHON_SPELL_ID = 264130
local CALL_DREADSTALKERS_SPELL_ID = 104316
local CALL_DREADSTALKERS_CAST_SPELL_ID = 334727
local CALL_DREADSTALKERS_REPLACEMENT_SPELL_IDS = {
    193331,
    193332,
    196273,
    196274,
    196281,
    364750,
    364751,
    464880,
    1217615,
    1251704,
}
local GRIMOIRE_SLOT_TRACKING_KEY = "grimoireSlot"
local SUMMON_DEMONIC_TYRANT_SPELL_ID = 265187
local SUMMON_DEMONIC_TYRANT_CAST_SPELL_ID = 334585
local DEMONBOLT_SPELL_ID = 264178
local RUINATION_SPELL_ID = 434635
local DEMONOLOGY_SPEC_ID = 266

local MAX_HAND_OF_GULDAN_IMPS = 3
local RUINATION_WILD_IMPS = 3
local IMPS_REMOVED_PER_IMPLOSION = 6
local IMPS_REMOVED_PER_POWER_SIPHON = 2
local TO_HELL_AND_BACK_IMPS_PER_BATCH = 1
local TO_HELL_AND_BACK_SACRIFICE_BATCH_SIZE = 2
local DOOMGUARD_DEMONIC_CORE_CDR = 3
local TYRANT_BASE_WINDOW_DURATION = 15
local TYRANT_REIGN_BONUS_DURATION = 5
local DISPLAY_UPDATE_INTERVAL = 0.10
local STRUCTURAL_CLEANUP_INTERVAL = 0.50
local COMPLETED_WILD_IMP_CAST_CACHE_LIMIT = 24

local IMP_START_ENERGY = 100
local IMP_ENERGY_PER_CAST = 20
local IMP_CASTS_PER_WILD_IMP = IMP_START_ENERGY / IMP_ENERGY_PER_CAST
local IMP_FEL_FIREBOLT_CAST_TIME = 2
local IMP_FIRST_CAST_DELAY = 0.9
local IMP_HARD_TIMEOUT = 20
local INNER_DEMON_INTERVAL = 12
local IMPLOSION_NATIVE_COUNT_FONT_PATH = "Fonts\\FRIZQT__.TTF"
local IMPLOSION_NATIVE_COUNT_FONT_SIZE = 24
local IMPLOSION_NATIVE_COUNT_X_OFFSET = -3
local IMPLOSION_NATIVE_COUNT_Y_OFFSET = 3
local IMPLOSION_NATIVE_COUNT_COLOR = { 1.00, 0.84, 0.18, 1.00 }
local IMPLOSION_NATIVE_COUNT_SHADOW_COLOR = { 0, 0, 0, 1.00 }
local IMPLOSION_NATIVE_COUNT_SHADOW_OFFSET = { 1, -1 }
local IMPLOSION_NATIVE_COUNT_FONT_FLAGS = "THICKOUTLINE"
local IMPLOSION_DEBUG_COUNT_COLOR = { 0.22, 1.00, 0.88, 1.00 }
local IMPLOSION_DEBUG_COUNT_SHADOW_COLOR = { 0, 0, 0, 1.00 }
local IMPLOSION_DEBUG_COUNT_SHADOW_OFFSET = { 1, -1 }
-- Keep this plain; tooltip border art sits badly against Blizzard's masked icons.
local READY_BORDER_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local READY_BORDER_COLOR = { 0.18, 1.00, 0.36 }
local READY_BORDER_INSET = 1
local READY_BORDER_THICKNESS = 2
local READY_BORDER_BASE_ALPHA = 0.68
local READY_BORDER_PULSE_ALPHA = 0.22
local READY_BORDER_PULSE_SPEED = 4.25
local Advisor = {
    borderColors = {
        ready = READY_BORDER_COLOR,
    },
    textColors = {
        ready = { 0.92, 1.00, 0.95 },
        tracking = { 0.84, 0.96, 1.00 },
        offspec = { 0.55, 0.55, 0.60 },
    },
    impExpiringSoonSeconds = 3,
    impAgingSoonSeconds = 6,
    tyrantSetupSoonSeconds = 8,
    doomguardSoonSeconds = 8,
}

-- First-load fallbacks. Learned names are cached once the client exposes them.
local FALLBACK_NAMES = {
    wildImpAura = TARGET_AURA_NAME,
    innerDemons = "Inner Demons",
    toHellAndBack = "To Hell and Back",
    spitefulReconstitution = "Spiteful Reconstitution",
    callDreadstalkers = "Call Dreadstalkers",
    callGreaterDreadstalker = "Call Greater Dreadstalker",
    infernalHoundmaster = "Infernal Houndmaster",
    grimoireImpLord = "Grimoire: Imp Lord",
    grimoireFelRavager = "Grimoire: Fel Ravager",
    singeMagic = "Singe Magic",
    spellLock = "Spell Lock",
    devourMagic = "Devour Magic",
    reignOfTyranny = "Reign of Tyranny",
    powerSiphon = "Power Siphon",
    summonDoomguard = "Summon Doomguard",
}

local defaults = {
    implosionThreshold = 6,
    implosionCooldown = 15,
    powerSiphonCooldown = 30,
    dreadstalkersCooldown = 20,
    grimoireCooldown = 120,
    tyrantCooldown = 60,
    doomguardCooldown = 120,
    showImplosionOverlay = true,
    showPowerSiphonOverlay = true,
    showDreadstalkersOverlay = true,
    showGrimoireOverlay = true,
    showTyrantOverlay = true,
    showDoomguardOverlay = true,
    debugImplosionEstimate = false,
    learnedNames = {},
    learnedSpellIDs = {},
}

local db
local trackedItemFrames = {}
local GetSpellNameByID
local GetTrackedItemFrame
local RebuildLocalizedNameCaches
local GetLearnedSpellID

-- Runtime state. Imp counts and cooldowns here are estimates, not server truth.
local activeGroups = {}
local pendingHoG = {}
local completedWildImpSummonCasts = {}
local completedWildImpSummonCastOrder = {}
local pendingHardcastDemonbolts = {}
local talentState = {
    innerDemons = false,
    toHellAndBack = false,
    spitefulReconstitution = false,
    reignOfTyranny = false,
}

local nextInnerDemonAt
local nextImplosionReadyAt = 0
local lastEstimateUpdate = GetTime()
local startupGraceUntil = 0
local localizedNames = {}
local dreadstalkerTrackedSpellNames = {}
local grimoireTrackedSpellNames = {}
local grimoireSlotSpellNames = {}
local grimoireCooldownReplacementNames = {}
local spellNameCache = {}
local spellTextureCache = {}
local overlayKeyCache = {}
local isDemonologyActive = false
local specStateKnown = false
local tyrantWindowUntil = 0
local tyrantHoGCount = 0
local cachedHastePercent = 0
local lastStructuralCleanupAt = 0

local trackedSpellConfigs = {
    [IMPLOSION_SPELL_ID] = {
        cooldownKey = "implosionCooldown",
        enabledKey = "showImplosionOverlay",
        showCount = true,
    },
    [POWER_SIPHON_SPELL_ID] = {
        cooldownKey = "powerSiphonCooldown",
        enabledKey = "showPowerSiphonOverlay",
        showCount = true,
    },
    [CALL_DREADSTALKERS_SPELL_ID] = {
        cooldownKey = "dreadstalkersCooldown",
        enabledKey = "showDreadstalkersOverlay",
    },
    [GRIMOIRE_SLOT_TRACKING_KEY] = {
        cooldownKey = "grimoireCooldown",
        enabledKey = "showGrimoireOverlay",
    },
    [SUMMON_DEMONIC_TYRANT_SPELL_ID] = {
        cooldownKey = "tyrantCooldown",
        enabledKey = "showTyrantOverlay",
    },
}

local trackedCooldownState = {
    [POWER_SIPHON_SPELL_ID] = { activated = false, readyAt = 0 },
    [CALL_DREADSTALKERS_SPELL_ID] = { activated = false, readyAt = 0 },
    [GRIMOIRE_SLOT_TRACKING_KEY] = { activated = false, readyAt = 0 },
    [SUMMON_DEMONIC_TYRANT_SPELL_ID] = { activated = false, readyAt = 0 },
}

local lastGrimoireSlotSpellName
local trackedReadySpellIDs = {
    CALL_DREADSTALKERS_SPELL_ID,
    GRIMOIRE_SLOT_TRACKING_KEY,
    SUMMON_DEMONIC_TYRANT_SPELL_ID,
}

local trackedSpellAliases = {
    [CALL_DREADSTALKERS_CAST_SPELL_ID] = CALL_DREADSTALKERS_SPELL_ID,
    [SUMMON_DEMONIC_TYRANT_CAST_SPELL_ID] = SUMMON_DEMONIC_TYRANT_SPELL_ID,
}

local trackedItemSpellAliases = {}

for _, spellID in ipairs(CALL_DREADSTALKERS_REPLACEMENT_SPELL_IDS) do
    trackedItemSpellAliases[spellID] = CALL_DREADSTALKERS_SPELL_ID
end

-- Keep saved data boring; patch behavior belongs in the model below.
local function CopyDefaults(src, dst)
    for key, value in pairs(src) do
        if type(value) == "table" then
            dst[key] = dst[key] or {}
            CopyDefaults(value, dst[key])
        elseif dst[key] == nil then
            dst[key] = value
        end
    end
end

local function EnsureDB()
    ImpTrackerDB = ImpTrackerDB or {}
    CopyDefaults(defaults, ImpTrackerDB)
    db = ImpTrackerDB
    RebuildLocalizedNameCaches()

    local learnedPowerSiphonSpellID = GetLearnedSpellID("powerSiphon")
    if learnedPowerSiphonSpellID and learnedPowerSiphonSpellID ~= POWER_SIPHON_SPELL_ID then
        trackedSpellAliases[learnedPowerSiphonSpellID] = POWER_SIPHON_SPELL_ID
    end
end

local function GetLearnedName(key)
    if db and db.learnedNames and db.learnedNames[key] and db.learnedNames[key] ~= "" then
        return db.learnedNames[key]
    end

    return FALLBACK_NAMES[key]
end

local function RememberName(key, value)
    if not db or not db.learnedNames or not value or value == "" then
        return
    end

    db.learnedNames[key] = value
end

GetLearnedSpellID = function(key)
    if not db or not db.learnedSpellIDs then
        return nil
    end

    local spellID = tonumber(db.learnedSpellIDs[key])
    if spellID and spellID > 0 then
        return spellID
    end

    return nil
end

local function RememberSpellID(key, spellID)
    spellID = tonumber(spellID)
    if not db or not db.learnedSpellIDs or not spellID or spellID <= 0 then
        return
    end

    db.learnedSpellIDs[key] = spellID
end

local function MarkTrackedSpellName(target, name)
    if name and name ~= "" then
        target[name] = true
    end
end

-- Cooldown Viewer can show replacement buttons, so names get mapped back to
-- the stable tracker buckets before the UI layer looks at them.
RebuildLocalizedNameCaches = function()
    localizedNames.wildImpAura = GetLearnedName("wildImpAura")
    localizedNames.innerDemons = GetLearnedName("innerDemons")
    localizedNames.toHellAndBack = GetLearnedName("toHellAndBack")
    localizedNames.spitefulReconstitution = GetLearnedName("spitefulReconstitution")
    localizedNames.reignOfTyranny = GetLearnedName("reignOfTyranny")
    localizedNames.callDreadstalkers = GetSpellNameByID(CALL_DREADSTALKERS_SPELL_ID) or GetLearnedName("callDreadstalkers")
    localizedNames.callGreaterDreadstalker = GetSpellNameByID(1217615) or GetLearnedName("callGreaterDreadstalker")
    localizedNames.infernalHoundmaster = GetSpellNameByID(1251704) or GetLearnedName("infernalHoundmaster")
    localizedNames.grimoireImpLord = GetLearnedName("grimoireImpLord")
    localizedNames.grimoireFelRavager = GetLearnedName("grimoireFelRavager")
    localizedNames.singeMagic = GetLearnedName("singeMagic")
    localizedNames.spellLock = GetLearnedName("spellLock")
    localizedNames.devourMagic = GetLearnedName("devourMagic")
    localizedNames.powerSiphon = GetSpellNameByID(POWER_SIPHON_SPELL_ID) or GetLearnedName("powerSiphon")
    localizedNames.summonDoomguard = GetLearnedName("summonDoomguard")

    wipe(dreadstalkerTrackedSpellNames)
    wipe(grimoireTrackedSpellNames)
    wipe(grimoireSlotSpellNames)
    wipe(grimoireCooldownReplacementNames)

    MarkTrackedSpellName(dreadstalkerTrackedSpellNames, localizedNames.callDreadstalkers)
    MarkTrackedSpellName(dreadstalkerTrackedSpellNames, localizedNames.callGreaterDreadstalker)
    MarkTrackedSpellName(dreadstalkerTrackedSpellNames, localizedNames.infernalHoundmaster)

    MarkTrackedSpellName(grimoireTrackedSpellNames, localizedNames.grimoireImpLord)
    MarkTrackedSpellName(grimoireTrackedSpellNames, localizedNames.grimoireFelRavager)

    for name in pairs(grimoireTrackedSpellNames) do
        grimoireSlotSpellNames[name] = true
    end

    MarkTrackedSpellName(grimoireCooldownReplacementNames, localizedNames.singeMagic)
    MarkTrackedSpellName(grimoireCooldownReplacementNames, localizedNames.spellLock)
    MarkTrackedSpellName(grimoireCooldownReplacementNames, localizedNames.devourMagic)

    for name in pairs(grimoireCooldownReplacementNames) do
        grimoireSlotSpellNames[name] = true
    end
end

local function GetDoomguardSpellID()
    return GetLearnedSpellID("summonDoomguard")
end

local function EnsureDoomguardTracking(spellID)
    spellID = tonumber(spellID)
    if not spellID or spellID <= 0 then
        return nil
    end

    if not trackedSpellConfigs[spellID] then
        trackedSpellConfigs[spellID] = {
            cooldownKey = "doomguardCooldown",
            enabledKey = "showDoomguardOverlay",
        }
    end

    if not trackedCooldownState[spellID] then
        trackedCooldownState[spellID] = { activated = false, readyAt = 0 }
    end

    RememberSpellID("summonDoomguard", spellID)
    local spellName = GetSpellNameByID(spellID)
    if spellName then
        RememberName("summonDoomguard", spellName)
        RebuildLocalizedNameCaches()
    end

    return spellID
end

local function GetTrackedReadySpellIDs()
    local doomguardSpellID = GetDoomguardSpellID()
    trackedReadySpellIDs[4] = doomguardSpellID

    return trackedReadySpellIDs
end

local function IsOverlayEnabled(spellID)
    local config = trackedSpellConfigs[spellID]
    if not config or not config.enabledKey then
        return true
    end

    if db and db[config.enabledKey] ~= nil then
        return db[config.enabledKey]
    end

    return defaults[config.enabledKey] ~= false
end

local function IsImplosionEstimateDebugEnabled()
    return db and db.debugImplosionEstimate == true
end

local function GetChargeCountTextRegion(chargeCount)
    if not chargeCount then
        return nil
    end

    if chargeCount.GetFont and chargeCount.SetFont then
        return chargeCount
    end

    if chargeCount.Current and chargeCount.Current.GetFont and chargeCount.Current.SetFont then
        return chargeCount.Current
    end

    if chargeCount.Text and chargeCount.Text.GetFont and chargeCount.Text.SetFont then
        return chargeCount.Text
    end

    return nil
end

local function RememberChargeCountStyle(chargeCount)
    if not chargeCount or chargeCount.ImpTrackerChargeCountStyle then
        return
    end

    local textRegion = GetChargeCountTextRegion(chargeCount)
    if not textRegion then
        return
    end

    local fontPath, fontSize, fontFlags = textRegion:GetFont()
    local points = {}
    local pointCount = textRegion.GetNumPoints and textRegion:GetNumPoints() or 0
    for i = 1, pointCount do
        local point, relativeTo, relativePoint, xOfs, yOfs = textRegion:GetPoint(i)
        if type(point) == "string" then
            points[#points + 1] = {
                point = point,
                relativeTo = relativeTo,
                relativePoint = type(relativePoint) == "string" and relativePoint or point,
                xOfs = type(xOfs) == "number" and xOfs or 0,
                yOfs = type(yOfs) == "number" and yOfs or 0,
            }
        end
    end

    chargeCount.ImpTrackerChargeCountStyle = {
        target = textRegion,
        fontPath = fontPath,
        fontSize = fontSize,
        fontFlags = fontFlags,
        justifyH = textRegion.GetJustifyH and textRegion:GetJustifyH() or nil,
        justifyV = textRegion.GetJustifyV and textRegion:GetJustifyV() or nil,
        textColor = textRegion.GetTextColor and { textRegion:GetTextColor() } or nil,
        shadowColor = textRegion.GetShadowColor and { textRegion:GetShadowColor() } or nil,
        shadowOffset = textRegion.GetShadowOffset and { textRegion:GetShadowOffset() } or nil,
        points = points,
    }
end

local function RestoreChargeCountStyle(chargeCount)
    local style = chargeCount and chargeCount.ImpTrackerChargeCountStyle
    if not style then
        return
    end

    local textRegion = style.target or GetChargeCountTextRegion(chargeCount)
    if not textRegion then
        return
    end

    if style.fontPath and style.fontSize then
        textRegion:SetFont(style.fontPath, style.fontSize, style.fontFlags)
    end

    if style.justifyH then
        textRegion:SetJustifyH(style.justifyH)
    end

    if style.justifyV then
        textRegion:SetJustifyV(style.justifyV)
    end

    if style.textColor and textRegion.SetTextColor then
        textRegion:SetTextColor(unpack(style.textColor))
    end

    if style.shadowColor and textRegion.SetShadowColor then
        textRegion:SetShadowColor(unpack(style.shadowColor))
    end

    if style.shadowOffset and textRegion.SetShadowOffset then
        textRegion:SetShadowOffset(unpack(style.shadowOffset))
    end

    local restoredPoint = false
    textRegion:ClearAllPoints()
    for _, pointInfo in ipairs(style.points or {}) do
        if type(pointInfo.point) == "string" then
            local ok = pcall(textRegion.SetPoint, textRegion, pointInfo.point, pointInfo.relativeTo, pointInfo.relativePoint or pointInfo.point, pointInfo.xOfs or 0, pointInfo.yOfs or 0)
            restoredPoint = restoredPoint or ok
        end
    end

    if not restoredPoint then
        textRegion:SetPoint("CENTER", chargeCount, "CENTER", 0, 0)
    end
end

local function SetImplosionChargeCountStyle(itemFrame, enabled, mode, force)
    local chargeCount = itemFrame and itemFrame.ChargeCount
    local textRegion = GetChargeCountTextRegion(chargeCount)
    if not chargeCount or not textRegion then
        return
    end

    enabled = enabled and true or false
    if chargeCount.ImpTrackerChargeCountStyleEnabled == enabled and (not force or not enabled) then
        return
    end

    RememberChargeCountStyle(chargeCount)
    chargeCount.ImpTrackerChargeCountStyleEnabled = enabled

    if enabled then
        local style = chargeCount.ImpTrackerChargeCountStyle or {}
        local fontPath = IMPLOSION_NATIVE_COUNT_FONT_PATH or style.fontPath or "Fonts\\FRIZQT__.TTF"
        local fontSize = IMPLOSION_NATIVE_COUNT_FONT_SIZE
        local anchor = itemFrame.Icon or itemFrame

        -- Midnight can return a secret boolean here; never branch on it.
        textRegion:SetFont(fontPath, fontSize, IMPLOSION_NATIVE_COUNT_FONT_FLAGS)
        textRegion:SetJustifyH("RIGHT")
        textRegion:SetJustifyV("BOTTOM")
        textRegion:ClearAllPoints()
        textRegion:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", IMPLOSION_NATIVE_COUNT_X_OFFSET, IMPLOSION_NATIVE_COUNT_Y_OFFSET)

        if textRegion.SetTextColor then
            textRegion:SetTextColor(unpack(IMPLOSION_NATIVE_COUNT_COLOR))
        end

        if textRegion.SetShadowColor then
            textRegion:SetShadowColor(unpack(IMPLOSION_NATIVE_COUNT_SHADOW_COLOR))
        end

        if textRegion.SetShadowOffset then
            textRegion:SetShadowOffset(unpack(IMPLOSION_NATIVE_COUNT_SHADOW_OFFSET))
        end
    else
        RestoreChargeCountStyle(chargeCount)
    end
end

local function SetReadyBorderEdge(edge)
    if edge.SetColorTexture then
        edge:SetColorTexture(READY_BORDER_COLOR[1], READY_BORDER_COLOR[2], READY_BORDER_COLOR[3], 1)
    else
        edge:SetTexture(READY_BORDER_TEXTURE)
        edge:SetVertexColor(unpack(READY_BORDER_COLOR))
    end
    edge:SetAlpha(0)
    edge:Hide()
end

local function CreateReadyBorder(parent)
    local border = { edges = {} }

    -- Four inside edges stay crisp without bleeding into neighboring icons.
    local top = parent:CreateTexture(nil, "ARTWORK")
    SetReadyBorderEdge(top)
    top:SetPoint("TOPLEFT", parent, "TOPLEFT", READY_BORDER_INSET, -READY_BORDER_INSET)
    top:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -READY_BORDER_INSET, -READY_BORDER_INSET)
    top:SetHeight(READY_BORDER_THICKNESS)
    border.edges[#border.edges + 1] = top

    local bottom = parent:CreateTexture(nil, "ARTWORK")
    SetReadyBorderEdge(bottom)
    bottom:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", READY_BORDER_INSET, READY_BORDER_INSET)
    bottom:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -READY_BORDER_INSET, READY_BORDER_INSET)
    bottom:SetHeight(READY_BORDER_THICKNESS)
    border.edges[#border.edges + 1] = bottom

    local left = parent:CreateTexture(nil, "ARTWORK")
    SetReadyBorderEdge(left)
    left:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", bottom, "TOPLEFT", 0, 0)
    left:SetWidth(READY_BORDER_THICKNESS)
    border.edges[#border.edges + 1] = left

    local right = parent:CreateTexture(nil, "ARTWORK")
    SetReadyBorderEdge(right)
    right:SetPoint("TOPRIGHT", top, "BOTTOMRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", bottom, "TOPRIGHT", 0, 0)
    right:SetWidth(READY_BORDER_THICKNESS)
    border.edges[#border.edges + 1] = right

    return border
end

local function SetReadyBorderAlpha(border, alpha)
    if not border then
        return
    end

    alpha = math.max(0, math.min(1, tonumber(alpha) or 0))
    if border.ImpTrackerAlpha == alpha then
        return
    end

    border.ImpTrackerAlpha = alpha

    for _, edge in ipairs(border.edges or {}) do
        edge:SetAlpha(alpha)

        if alpha > 0 then
            edge:Show()
        else
            edge:Hide()
        end
    end
end

function Advisor.SetReadyBorderColor(border, color)
    if not border or not color then
        return
    end

    if border.ImpTrackerColor == color then
        return
    end

    border.ImpTrackerColor = color
    for _, edge in ipairs(border.edges or {}) do
        if edge.SetColorTexture then
            edge:SetColorTexture(color[1], color[2], color[3], 1)
        else
            edge:SetTexture(READY_BORDER_TEXTURE)
            edge:SetVertexColor(color[1], color[2], color[3], 1)
        end
    end
end

local function GetReadyBorderAlpha(now)
    local pulse = math.abs(math.sin((now or GetTime()) * READY_BORDER_PULSE_SPEED))
    return READY_BORDER_BASE_ALPHA + (READY_BORDER_PULSE_ALPHA * pulse)
end

function Advisor.SetReadyBorderMode(border, mode, now)
    local color = Advisor.borderColors[mode]
    if not color then
        SetReadyBorderAlpha(border, 0)
        return
    end

    Advisor.SetReadyBorderColor(border, color)
    SetReadyBorderAlpha(border, GetReadyBorderAlpha(now))
end

function Advisor.GetTextColor(mode)
    if mode == "ready" or mode == "offspec" then
        return Advisor.textColors[mode]
    end

    return Advisor.textColors.tracking
end

local function GetPlayerSpecID()
    if not GetSpecialization or not GetSpecializationInfo then
        return nil
    end

    local specIndex = GetSpecialization()
    if not specIndex then
        return nil
    end

    return GetSpecializationInfo(specIndex)
end

local function RefreshSpecState()
    local specID = GetPlayerSpecID()
    if not specID then
        isDemonologyActive = false
        specStateKnown = false
        return false
    end

    isDemonologyActive = specID == DEMONOLOGY_SPEC_ID
    specStateKnown = true
    return isDemonologyActive
end

local function IsDemonologySpecActive()
    if not specStateKnown then
        return RefreshSpecState()
    end

    return isDemonologyActive
end

-- Retail 12.x can surface "secret" spell identifiers from secure UI widgets.
-- Treat them as unavailable so table lookups/comparisons do not hard-error.
local function IsSecretValue(value)
    local valueType = type(value)
    if valueType == "nil" then
        return false
    end

    if issecretvalue then
        local ok, result = pcall(issecretvalue, value)
        if ok and result then
            return true
        end
    end

    if valueType == "table" and issecrettable then
        local ok, result = pcall(issecrettable, value)
        if ok and result then
            return true
        end
    end

    return false
end

local function NormalizeSafeSpellID(spellID)
    local valueType = type(spellID)
    if valueType == "nil" or IsSecretValue(spellID) then
        return nil
    end

    if valueType == "number" or valueType == "string" then
        local numericSpellID = tonumber(spellID)
        if numericSpellID and numericSpellID > 0 then
            return numericSpellID
        end

        return nil
    end

    if valueType == "table" then
        local extractedSpellID
        local ok, result = pcall(function()
            return spellID.spellID or spellID.baseSpellID or spellID.overrideSpellID or spellID.id
        end)
        if ok then
            extractedSpellID = result
        end

        return NormalizeSafeSpellID(extractedSpellID)
    end

    return nil
end

local function NormalizeSafeStringKey(value)
    local valueType = type(value)
    if valueType == "nil" or IsSecretValue(value) then
        return nil
    end

    if valueType == "string" and value ~= "" then
        return value
    end

    return nil
end

local function NormalizeSafeNumber(value)
    local valueType = type(value)
    if valueType == "nil" or IsSecretValue(value) then
        return nil
    end

    if valueType == "number" or valueType == "string" then
        return tonumber(value)
    end

    return nil
end

local function GetTrackedFrameSpellID(itemFrame)
    if not itemFrame or not itemFrame.GetSpellID then
        return nil
    end

    local ok, rawSpellID = pcall(itemFrame.GetSpellID, itemFrame)
    if not ok then
        return nil
    end

    return NormalizeSafeSpellID(rawSpellID)
end

local function GetSpellTextureByID(spellID)
    spellID = NormalizeSafeSpellID(spellID)
    if not spellID then
        return nil
    end

    local cachedTexture = spellTextureCache[spellID]
    if cachedTexture ~= nil then
        return cachedTexture
    end

    if C_Spell and C_Spell.GetSpellTexture then
        local ok, texture = pcall(C_Spell.GetSpellTexture, spellID)
        if ok and type(texture) ~= "nil" and not IsSecretValue(texture) then
            spellTextureCache[spellID] = texture
            return texture
        end
    end

    if GetSpellTexture then
        local ok, texture = pcall(GetSpellTexture, spellID)
        if ok and type(texture) ~= "nil" and not IsSecretValue(texture) then
            spellTextureCache[spellID] = texture
            return texture
        end
    end

    return nil
end

GetSpellNameByID = function(spellID)
    spellID = NormalizeSafeSpellID(spellID)
    if not spellID then
        return nil
    end

    local cachedName = spellNameCache[spellID]
    if cachedName ~= nil then
        return cachedName
    end

    if C_Spell and C_Spell.GetSpellName then
        local ok, spellName = pcall(C_Spell.GetSpellName, spellID)
        if ok and type(spellName) ~= "nil" and not IsSecretValue(spellName) then
            spellNameCache[spellID] = spellName
            return spellName
        end
    end

    if GetSpellInfo then
        local ok, spellName = pcall(GetSpellInfo, spellID)
        if ok and type(spellName) ~= "nil" and not IsSecretValue(spellName) then
            spellNameCache[spellID] = spellName
            return spellName
        end
    end

    return nil
end

-- Talent scans are best-effort through normal spellbook surfaces. "Not seen"
-- means not modeled right now, not proof Blizzard removed the spell.
local function RefreshTalentState()
    talentState.innerDemons = false
    talentState.toHellAndBack = false
    talentState.spitefulReconstitution = false
    talentState.reignOfTyranny = false

    RefreshSpecState()

    if not IsDemonologySpecActive() then
        return
    end

    if not (
        C_ClassTalents and C_ClassTalents.GetActiveConfigID and
        C_Traits and C_Traits.GetConfigInfo and C_Traits.GetTreeNodes and
        C_Traits.GetNodeInfo and C_Traits.GetEntryInfo and C_Traits.GetDefinitionInfo
    ) then
        return
    end

    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then
        return
    end

    local configInfo = C_Traits.GetConfigInfo(configID)
    local treeIDs = configInfo and configInfo.treeIDs
    if not treeIDs then
        return
    end

    for _, treeID in ipairs(treeIDs) do
        local nodeIDs = C_Traits.GetTreeNodes(treeID)
        if nodeIDs then
            for _, nodeID in ipairs(nodeIDs) do
                local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
                local activeEntryID = nodeInfo and nodeInfo.activeEntry and nodeInfo.activeEntry.entryID

                if not activeEntryID and nodeInfo and nodeInfo.activeEntryID then
                    activeEntryID = nodeInfo.activeEntryID
                end

                if not activeEntryID and nodeInfo and nodeInfo.entryIDs and nodeInfo.currentRank and nodeInfo.currentRank > 0 and #nodeInfo.entryIDs == 1 then
                    activeEntryID = nodeInfo.entryIDs[1]
                end

                if activeEntryID then
                    local entryInfo = C_Traits.GetEntryInfo(configID, activeEntryID)
                    local definitionID = entryInfo and entryInfo.definitionID
                    if definitionID then
                        local definitionInfo = C_Traits.GetDefinitionInfo(definitionID)
                        local spellID = NormalizeSafeSpellID(definitionInfo and (definitionInfo.overrideSpellID or definitionInfo.spellID))
                        local spellName = GetSpellNameByID(spellID)

                        if spellName and (spellName == localizedNames.innerDemons or spellName == FALLBACK_NAMES.innerDemons) then
                            talentState.innerDemons = true
                            RememberName("innerDemons", spellName)
                        elseif spellName and (spellName == localizedNames.toHellAndBack or spellName == FALLBACK_NAMES.toHellAndBack) then
                            talentState.toHellAndBack = true
                            RememberName("toHellAndBack", spellName)
                        elseif spellName and (spellName == localizedNames.spitefulReconstitution or spellName == FALLBACK_NAMES.spitefulReconstitution) then
                            talentState.spitefulReconstitution = true
                            RememberName("spitefulReconstitution", spellName)
                        elseif spellName and (spellName == localizedNames.reignOfTyranny or spellName == FALLBACK_NAMES.reignOfTyranny) then
                            talentState.reignOfTyranny = true
                            RememberName("reignOfTyranny", spellName)
                        elseif spellName and (spellName == localizedNames.powerSiphon or spellName == FALLBACK_NAMES.powerSiphon) then
                            RememberName("powerSiphon", spellName)
                            RememberSpellID("powerSiphon", spellID)
                            trackedSpellAliases[spellID] = POWER_SIPHON_SPELL_ID
                        elseif spellName and (spellName == localizedNames.summonDoomguard or spellName == FALLBACK_NAMES.summonDoomguard) then
                            EnsureDoomguardTracking(spellID)
                        end
                    end
                end
            end
        end
    end

    RebuildLocalizedNameCaches()
end

local function HasInnerDemons()
    return IsDemonologySpecActive() and talentState.innerDemons
end

local function HasToHellAndBack()
    return IsDemonologySpecActive() and talentState.toHellAndBack
end

local function GetToHellAndBackReplacementCount(removedCount)
    if not HasToHellAndBack() then
        return 0
    end

    local sacrificed = math.max(0, tonumber(removedCount) or 0)
    return math.floor(sacrificed / TO_HELL_AND_BACK_SACRIFICE_BATCH_SIZE) * TO_HELL_AND_BACK_IMPS_PER_BATCH
end

local function HasReignOfTyranny()
    return IsDemonologySpecActive() and talentState.reignOfTyranny
end

local function NormalizeTrackedCastSpellID(spellID)
    spellID = NormalizeSafeSpellID(spellID)
    if not spellID then
        return nil
    end

    local normalized = trackedSpellAliases[spellID] or spellID
    local spellName = GetSpellNameByID(normalized)

    if spellName and grimoireTrackedSpellNames[spellName] then
        return GRIMOIRE_SLOT_TRACKING_KEY
    end

    return normalized
end

local function NormalizeTrackedItemSpellID(spellID)
    spellID = NormalizeSafeSpellID(spellID)
    if not spellID then
        return nil
    end

    local normalized = trackedItemSpellAliases[spellID] or trackedSpellAliases[spellID] or spellID
    local spellName = GetSpellNameByID(normalized)

    if spellName and grimoireSlotSpellNames[spellName] then
        return GRIMOIRE_SLOT_TRACKING_KEY
    end

    if spellName and dreadstalkerTrackedSpellNames[spellName] then
        return CALL_DREADSTALKERS_SPELL_ID
    end

    return normalized
end

-- Cooldowns are local estimates from casts and checked talent text. Do not swap
-- this for live combat cooldown reads without retesting Midnight secret values.
local function GetEstimatedImplosionRemaining(now)
    now = now or GetTime()
    return math.max(0, (nextImplosionReadyAt or 0) - now)
end

local function ResetEstimatedCooldowns()
    nextImplosionReadyAt = 0
    lastGrimoireSlotSpellName = nil
    tyrantWindowUntil = 0
    tyrantHoGCount = 0

    for spellID, state in pairs(trackedCooldownState) do
        state.activated = false
        state.readyAt = 0
    end
end

local function GetTyrantWindowDuration()
    return TYRANT_BASE_WINDOW_DURATION + (HasReignOfTyranny() and TYRANT_REIGN_BONUS_DURATION or 0)
end

local function IsTyrantWindowActive(now)
    now = now or GetTime()
    return IsDemonologySpecActive() and (tyrantWindowUntil or 0) > now
end

local function StartTyrantWindow(now)
    now = now or GetTime()
    tyrantWindowUntil = now + GetTyrantWindowDuration()
    tyrantHoGCount = 0
end

local function ClearTyrantWindow()
    tyrantWindowUntil = 0
    tyrantHoGCount = 0
end

local function UpdateTyrantWindowState(now)
    if not IsTyrantWindowActive(now) and ((tyrantWindowUntil or 0) > 0 or (tyrantHoGCount or 0) > 0) then
        ClearTyrantWindow()
    end
end

local function GetEstimatedTrackedCooldownRemaining(spellID, now)
    local state = trackedCooldownState[spellID]
    if not state or not state.activated then
        return nil
    end

    now = now or GetTime()
    return math.max(0, (state.readyAt or 0) - now)
end

local function IsEstimatedTrackedCooldownReady(spellID, now)
    local remaining = GetEstimatedTrackedCooldownRemaining(spellID, now)
    return remaining ~= nil and remaining <= 0
end

local function StartEstimatedTrackedCooldown(spellID, now)
    local config = trackedSpellConfigs[spellID]
    local state = trackedCooldownState[spellID]
    if not config or not state then
        return
    end

    now = now or GetTime()
    state.activated = true
    state.readyAt = now + (db[config.cooldownKey] or defaults[config.cooldownKey] or 0)
end

local function ReduceEstimatedTrackedCooldown(spellID, seconds, now)
    local state = trackedCooldownState[spellID]
    local reduction = math.max(0, tonumber(seconds) or 0)
    if not state or not state.activated or reduction <= 0 then
        return 0
    end

    now = now or GetTime()
    local readyAt = tonumber(state.readyAt) or 0
    if readyAt <= now then
        return 0
    end

    local newReadyAt = math.max(now, readyAt - reduction)
    local appliedReduction = readyAt - newReadyAt
    state.readyAt = newReadyAt
    return appliedReduction
end

local function ApplyDemonicCoreDoomguardReduction(now)
    local doomguardSpellID = GetDoomguardSpellID()
    if not doomguardSpellID then
        return 0
    end

    return ReduceEstimatedTrackedCooldown(doomguardSpellID, DOOMGUARD_DEMONIC_CORE_CDR, now)
end

local function RefreshCachedHastePercent()
    if not GetHaste then
        return cachedHastePercent or 0
    end

    if (InCombatLockdown and InCombatLockdown()) or UnitAffectingCombat("player") then
        return cachedHastePercent or 0
    end

    local ok, hastePercent = pcall(function()
        local value = GetHaste()
        if type(value) ~= "number" then
            return nil
        end

        return value + 0
    end)
    if ok and type(hastePercent) == "number" then
        cachedHastePercent = math.max(0, hastePercent)
    end

    return cachedHastePercent or 0
end

-- Wild Imp count is modeled as timed groups, then resynced when normal aura
-- reads are safe again.
local function GetCachedHasteMultiplier()
    return 1 + (RefreshCachedHastePercent() / 100)
end

local function GetImpEnergyDecayPerSecond()
    return (IMP_ENERGY_PER_CAST / IMP_FEL_FIREBOLT_CAST_TIME) * GetCachedHasteMultiplier()
end

local function AddGroup(count, source, spawnTime)
    local amount = math.max(0, tonumber(count) or 0)
    if amount <= 0 then
        return
    end

    local spawn = tonumber(spawnTime) or GetTime()
    table.insert(activeGroups, {
        count = amount,
        source = source or "unknown",
        spawn = spawn,
        energy = IMP_START_ENERGY,
        energyStartAt = spawn + IMP_FIRST_CAST_DELAY,
        expiresAt = spawn + IMP_HARD_TIMEOUT,
    })
end

local function AdvanceCombatDecay(now)
    now = now or GetTime()

    local previous = lastEstimateUpdate or now
    local dt = now - previous
    lastEstimateUpdate = now

    if dt <= 0 then
        return
    end

    if dt > 1.5 then
        dt = 1.5
        previous = now - dt
    end

    if not UnitAffectingCombat("player") then
        return
    end

    local decayPerSecond = GetImpEnergyDecayPerSecond()
    for i = 1, #activeGroups do
        local group = activeGroups[i]
        local energyStartAt = group.energyStartAt or group.spawn or now
        local decayWindowStart = math.max(previous, energyStartAt)
        if now > decayWindowStart then
            local activeDt = now - decayWindowStart
            group.energy = math.max(0, (group.energy or IMP_START_ENERGY) - (decayPerSecond * activeDt))
        end
    end
end

local function ClearExpiredGroups(now)
    now = now or GetTime()

    for i = #activeGroups, 1, -1 do
        local group = activeGroups[i]
        if now >= (group.expiresAt or 0) or (group.energy or IMP_START_ENERGY) <= 0 or (group.count or 0) <= 0 then
            table.remove(activeGroups, i)
        end
    end
end

local function GetEstimatedImpCount(now)
    ClearExpiredGroups(now)

    local total = 0
    for i = 1, #activeGroups do
        total = total + (activeGroups[i].count or 0)
    end

    return total
end

function Advisor.GetImpPressure(now)
    now = now or GetTime()
    local decayPerSecond = math.max(0.1, GetImpEnergyDecayPerSecond())
    local pressure = {
        expiring = 0,
        aging = 0,
        fresh = 0,
    }

    for i = 1, #activeGroups do
        local group = activeGroups[i]
        local count = group and math.max(0, tonumber(group.count) or 0) or 0
        if count > 0 then
            local energyStartAt = group.energyStartAt or group.spawn or now
            if now < energyStartAt then
                pressure.fresh = pressure.fresh + count
            else
                local timeLeft = ((group.energy or IMP_START_ENERGY) / decayPerSecond)
                if timeLeft <= Advisor.impExpiringSoonSeconds then
                    pressure.expiring = pressure.expiring + count
                elseif timeLeft <= Advisor.impAgingSoonSeconds then
                    pressure.aging = pressure.aging + count
                end
            end
        end
    end

    return pressure
end

function Advisor.IsCooldownReady(remaining)
    return remaining ~= nil and remaining <= 0
end

function Advisor.IsCooldownSoon(remaining, seconds)
    return remaining ~= nil and remaining > 0 and remaining <= seconds
end

function Advisor.GetState(estimated, threshold, now)
    now = now or GetTime()
    estimated = math.max(0, tonumber(estimated) or 0)
    threshold = math.max(1, tonumber(threshold) or defaults.implosionThreshold)

    local implosionRemaining = GetEstimatedImplosionRemaining(now)
    local powerSiphonRemaining = GetEstimatedTrackedCooldownRemaining(POWER_SIPHON_SPELL_ID, now)
    local dreadstalkerRemaining = GetEstimatedTrackedCooldownRemaining(CALL_DREADSTALKERS_SPELL_ID, now)
    local grimoireRemaining = GetEstimatedTrackedCooldownRemaining(GRIMOIRE_SLOT_TRACKING_KEY, now)
    local tyrantRemaining = GetEstimatedTrackedCooldownRemaining(SUMMON_DEMONIC_TYRANT_SPELL_ID, now)
    local doomguardSpellID = GetDoomguardSpellID()
    local doomguardRemaining = doomguardSpellID and GetEstimatedTrackedCooldownRemaining(doomguardSpellID, now) or nil
    local impPressure = Advisor.GetImpPressure(now)

    local state = {
        estimated = estimated,
        threshold = threshold,
        impPressure = impPressure,
        tyrantActive = IsTyrantWindowActive(now),
        tyrantReady = Advisor.IsCooldownReady(tyrantRemaining),
        tyrantSoon = Advisor.IsCooldownReady(tyrantRemaining) or Advisor.IsCooldownSoon(tyrantRemaining, Advisor.tyrantSetupSoonSeconds),
        dreadstalkersReady = Advisor.IsCooldownReady(dreadstalkerRemaining),
        grimoireReady = Advisor.IsCooldownReady(grimoireRemaining),
        doomguardReady = Advisor.IsCooldownReady(doomguardRemaining),
        doomguardSoon = Advisor.IsCooldownSoon(doomguardRemaining, Advisor.doomguardSoonSeconds),
        modes = {},
    }

    local enoughForImplosion = estimated >= threshold
    if enoughForImplosion and implosionRemaining <= 0 then
        if HasToHellAndBack() then
            state.modes[IMPLOSION_SPELL_ID] = "ready"
        elseif state.tyrantActive then
            state.modes[IMPLOSION_SPELL_ID] = "hold"
        elseif state.tyrantSoon and impPressure.expiring < 2 and estimated < (threshold + 2) then
            state.modes[IMPLOSION_SPELL_ID] = "hold"
        else
            state.modes[IMPLOSION_SPELL_ID] = "ready"
        end
    elseif enoughForImplosion then
        state.modes[IMPLOSION_SPELL_ID] = "building"
    elseif estimated > 0 then
        state.modes[IMPLOSION_SPELL_ID] = "building"
    else
        state.modes[IMPLOSION_SPELL_ID] = "tracking"
    end

    local enoughForSiphon = estimated >= IMPS_REMOVED_PER_POWER_SIPHON
    if powerSiphonRemaining ~= nil and powerSiphonRemaining > 0 then
        state.modes[POWER_SIPHON_SPELL_ID] = enoughForSiphon and "building" or "tracking"
    elseif enoughForSiphon then
        if state.tyrantActive or (state.tyrantSoon and impPressure.expiring < IMPS_REMOVED_PER_POWER_SIPHON) then
            state.modes[POWER_SIPHON_SPELL_ID] = "hold"
        elseif state.doomguardSoon or estimated >= 4 or impPressure.expiring >= IMPS_REMOVED_PER_POWER_SIPHON then
            state.modes[POWER_SIPHON_SPELL_ID] = "ready"
        else
            state.modes[POWER_SIPHON_SPELL_ID] = "building"
        end
    else
        state.modes[POWER_SIPHON_SPELL_ID] = estimated > 0 and "building" or "tracking"
    end

    if state.dreadstalkersReady then
        state.modes[CALL_DREADSTALKERS_SPELL_ID] = state.tyrantSoon and "setup" or "ready"
    else
        state.modes[CALL_DREADSTALKERS_SPELL_ID] = "tracking"
    end

    if state.grimoireReady then
        state.modes[GRIMOIRE_SLOT_TRACKING_KEY] = state.tyrantSoon and "setup" or "ready"
    else
        state.modes[GRIMOIRE_SLOT_TRACKING_KEY] = "tracking"
    end

    if state.tyrantActive then
        state.modes[SUMMON_DEMONIC_TYRANT_SPELL_ID] = "tracking"
    elseif state.tyrantReady then
        if state.dreadstalkersReady or state.grimoireReady or estimated < threshold then
            state.modes[SUMMON_DEMONIC_TYRANT_SPELL_ID] = "hold"
        else
            state.modes[SUMMON_DEMONIC_TYRANT_SPELL_ID] = "ready"
        end
    elseif Advisor.IsCooldownSoon(tyrantRemaining, Advisor.tyrantSetupSoonSeconds) then
        state.modes[SUMMON_DEMONIC_TYRANT_SPELL_ID] = "setup"
    else
        state.modes[SUMMON_DEMONIC_TYRANT_SPELL_ID] = "tracking"
    end

    if doomguardSpellID then
        if state.doomguardReady then
            state.modes[doomguardSpellID] = "ready"
        elseif state.doomguardSoon then
            state.modes[doomguardSpellID] = "setup"
        else
            state.modes[doomguardSpellID] = "tracking"
        end
    end

    return state
end

local function BuildRemovalOrder()
    local indices = {}
    for i = 1, #activeGroups do
        indices[i] = i
    end

    table.sort(indices, function(a, b)
        local groupA = activeGroups[a]
        local groupB = activeGroups[b]
        local startA = groupA and (groupA.energyStartAt or groupA.spawn) or 0
        local startB = groupB and (groupB.energyStartAt or groupB.spawn) or 0

        if startA ~= startB then
            return startA < startB
        end

        local spawnA = groupA and groupA.spawn or 0
        local spawnB = groupB and groupB.spawn or 0
        return spawnA < spawnB
    end)

    return indices
end

local function RemoveImpCount(count, now)
    local toRemove = math.max(0, tonumber(count) or 0)
    if toRemove <= 0 then
        return 0
    end

    ClearExpiredGroups(now)

    local removedTotal = 0
    local orderedIndices = BuildRemovalOrder()
    for _, index in ipairs(orderedIndices) do
        local group = activeGroups[index]
        if group and toRemove > 0 then
            local removed = math.min(group.count or 0, toRemove)
            group.count = (group.count or 0) - removed
            removedTotal = removedTotal + removed
            toRemove = toRemove - removed
        end

        if toRemove <= 0 then
            break
        end
    end

    ClearExpiredGroups(now)
    return removedTotal
end

local function ResetEstimate(actualCount, now)
    wipe(activeGroups)

    local count = math.max(0, tonumber(actualCount) or 0)
    if count <= 0 then
        return
    end

    local current = now or GetTime()
    local hasteMultiplier = GetCachedHasteMultiplier()
    local impliedLifetime = (IMP_CASTS_PER_WILD_IMP * IMP_FEL_FIREBOLT_CAST_TIME) / math.max(0.1, hasteMultiplier)
    local assumedAge = math.max(0, math.min(impliedLifetime * 0.45, impliedLifetime - 0.5))
    AddGroup(count, "sync", current - assumedAge)
end

local function ResyncEstimate(actualCount, now)
    now = now or GetTime()
    local count = math.max(0, tonumber(actualCount) or 0)

    if count == 0 then
        wipe(activeGroups)
        return
    end

    local estimated = GetEstimatedImpCount(now)
    if estimated == count then
        return
    end

    if estimated == 0 then
        ResetEstimate(count, now)
        return
    end

    if estimated < count then
        AddGroup(count - estimated, "sync", now)
    else
        RemoveImpCount(estimated - count, now)
    end
end

-- Friendly resync path only. In combat, let the local model carry the display.
local function GetWildImpAuraSnapshot()
    if (InCombatLockdown and InCombatLockdown()) or UnitAffectingCombat("player") then
        return 0, nil, nil
    end

    local learnedAuraSpellID = GetLearnedSpellID("wildImpAura")
    if learnedAuraSpellID and AuraUtil and AuraUtil.FindAuraBySpellID then
        local ok, name, icon, count, _, _, _, _, _, spellID = pcall(AuraUtil.FindAuraBySpellID, learnedAuraSpellID, "player", "HELPFUL")
        name = NormalizeSafeStringKey(name)
        spellID = NormalizeSafeSpellID(spellID)
        count = NormalizeSafeNumber(count)
        if ok and name then
            RememberName("wildImpAura", name)
            RememberSpellID("wildImpAura", spellID or learnedAuraSpellID)
            RebuildLocalizedNameCaches()
            return math.max(0, tonumber(count) or 0), icon, spellID or learnedAuraSpellID
        end
    end

    if AuraUtil and AuraUtil.FindAuraByName then
        local ok, name, icon, count, _, _, _, _, _, spellID = pcall(AuraUtil.FindAuraByName, localizedNames.wildImpAura, "player", "HELPFUL")
        name = NormalizeSafeStringKey(name)
        spellID = NormalizeSafeSpellID(spellID)
        count = NormalizeSafeNumber(count)
        if ok and name then
            RememberName("wildImpAura", name)
            RememberSpellID("wildImpAura", spellID)
            RebuildLocalizedNameCaches()
            return math.max(0, tonumber(count) or 0), icon, spellID
        end
    end

    if localizedNames.wildImpAura ~= TARGET_AURA_NAME and AuraUtil and AuraUtil.FindAuraByName then
        local ok, name, icon, count, _, _, _, _, _, spellID = pcall(AuraUtil.FindAuraByName, TARGET_AURA_NAME, "player", "HELPFUL")
        name = NormalizeSafeStringKey(name)
        spellID = NormalizeSafeSpellID(spellID)
        count = NormalizeSafeNumber(count)
        if ok and name then
            RememberName("wildImpAura", name)
            RememberSpellID("wildImpAura", spellID)
            RebuildLocalizedNameCaches()
            return math.max(0, tonumber(count) or 0), icon, spellID
        end
    end

    local ok, name, icon, count, _, _, _, _, _, spellID = pcall(UnitBuff, "player", localizedNames.wildImpAura)
    name = NormalizeSafeStringKey(name)
    spellID = NormalizeSafeSpellID(spellID)
    count = NormalizeSafeNumber(count)
    if ok and name then
        RememberName("wildImpAura", name)
        RememberSpellID("wildImpAura", spellID)
        RebuildLocalizedNameCaches()
        return math.max(0, tonumber(count) or 0), icon, spellID
    end

    if localizedNames.wildImpAura ~= TARGET_AURA_NAME then
        local fallbackOk, fallbackName, fallbackIcon, fallbackCount, _, _, _, _, _, fallbackSpellID = pcall(UnitBuff, "player", TARGET_AURA_NAME)
        fallbackName = NormalizeSafeStringKey(fallbackName)
        fallbackSpellID = NormalizeSafeSpellID(fallbackSpellID)
        fallbackCount = NormalizeSafeNumber(fallbackCount)
        if fallbackOk and fallbackName then
            RememberName("wildImpAura", fallbackName)
            RememberSpellID("wildImpAura", fallbackSpellID)
            RebuildLocalizedNameCaches()
            return math.max(0, tonumber(fallbackCount) or 0), fallbackIcon, fallbackSpellID
        end
    end

    for i = 1, MAX_AURA_SLOTS do
        local okIndex, auraName, auraIcon, auraCount, _, _, _, _, _, auraSpellID = pcall(UnitBuff, "player", i)
        auraName = NormalizeSafeStringKey(auraName)
        auraSpellID = NormalizeSafeSpellID(auraSpellID)
        auraCount = NormalizeSafeNumber(auraCount)
        if not okIndex or not auraName then
            break
        end

        if auraSpellID == learnedAuraSpellID or auraName == localizedNames.wildImpAura or auraName == TARGET_AURA_NAME then
            RememberName("wildImpAura", auraName)
            RememberSpellID("wildImpAura", auraSpellID)
            RebuildLocalizedNameCaches()
            return math.max(0, tonumber(auraCount) or 0), auraIcon, auraSpellID
        end
    end

    return 0, nil, nil
end

local function PrintStatus(now)
    now = now or GetTime()
    local estimated = GetEstimatedImpCount(now)
    local auraCount, _, auraSpellID = GetWildImpAuraSnapshot()
    local threshold = db.implosionThreshold or defaults.implosionThreshold
    local adviceState = Advisor.GetState(estimated, threshold, now)

    print(string.format("|cff9d7dffImpTracker:|r Estimated imps = %d", estimated))
    print(string.format("|cff9d7dffImpTracker:|r Active groups = %d", #activeGroups))
    print(string.format("|cff9d7dffImpTracker:|r Spec = %s", IsDemonologySpecActive() and "Demonology" or "Other"))
    print(string.format("|cff9d7dffImpTracker:|r Inner Demons = %s | To Hell and Back = %s | Reign of Tyranny = %s", talentState.innerDemons and "on" or "off", talentState.toHellAndBack and "on" or "off", talentState.reignOfTyranny and "on" or "off"))
    print(string.format("|cff9d7dffImpTracker:|r Spiteful Reconstitution = %s | Random Wild Imp proc not estimated", talentState.spitefulReconstitution and "on" or "off"))
    print(string.format("|cff9d7dffImpTracker:|r Implosion threshold = %s | Implosion CD = %ss | Ready in %.1fs", tostring(threshold), tostring(db.implosionCooldown or defaults.implosionCooldown), GetEstimatedImplosionRemaining(now)))
    print(string.format("|cff9d7dffImpTracker:|r Power Siphon ready in %.1fs | Dreadstalkers ready in %.1fs | Grimoire ready in %.1fs | Tyrant ready in %.1fs", GetEstimatedTrackedCooldownRemaining(POWER_SIPHON_SPELL_ID, now) or 0, GetEstimatedTrackedCooldownRemaining(CALL_DREADSTALKERS_SPELL_ID, now) or 0, GetEstimatedTrackedCooldownRemaining(GRIMOIRE_SLOT_TRACKING_KEY, now) or 0, GetEstimatedTrackedCooldownRemaining(SUMMON_DEMONIC_TYRANT_SPELL_ID, now) or 0))
    print(string.format("|cff9d7dffImpTracker:|r Tyrant window = %s | HoG during Tyrant = %d | Ends in %.1fs", IsTyrantWindowActive(now) and "active" or "idle", tyrantHoGCount or 0, math.max(0, (tyrantWindowUntil or 0) - now)))
    print(string.format("|cff9d7dffImpTracker:|r Advice = Implosion:%s | Power Siphon:%s | Dogs:%s | Grimoire:%s | Tyrant:%s", tostring(adviceState.modes[IMPLOSION_SPELL_ID]), tostring(adviceState.modes[POWER_SIPHON_SPELL_ID]), tostring(adviceState.modes[CALL_DREADSTALKERS_SPELL_ID]), tostring(adviceState.modes[GRIMOIRE_SLOT_TRACKING_KEY]), tostring(adviceState.modes[SUMMON_DEMONIC_TYRANT_SPELL_ID])))

    local doomguardSpellID = GetDoomguardSpellID()
    if doomguardSpellID then
        print(string.format("|cff9d7dffImpTracker:|r Doomguard spellID=%s | Ready in %.1fs", tostring(doomguardSpellID), GetEstimatedTrackedCooldownRemaining(doomguardSpellID, now) or 0))
    end

    print(string.format("|cff9d7dffImpTracker:|r Wild Imp model = %d casts at %.1fs base cast, %.1f energy per cast", IMP_CASTS_PER_WILD_IMP, IMP_FEL_FIREBOLT_CAST_TIME, IMP_ENERGY_PER_CAST))

    if auraCount > 0 then
        print(string.format("|cff9d7dffImpTracker:|r Aura count=%s spellID=%s", tostring(auraCount), tostring(auraSpellID or "?")))
    elseif (InCombatLockdown and InCombatLockdown()) or UnitAffectingCombat("player") then
        print("|cff9d7dffImpTracker:|r In combat: using estimate only.")
    else
        print("|cff9d7dffImpTracker:|r Wild Imp aura count assumed to be 0.")
    end
end

local function ProcessInnerDemon(now)
    if not HasInnerDemons() then
        nextInnerDemonAt = nil
        return
    end

    if not UnitAffectingCombat("player") then
        nextInnerDemonAt = nil
        return
    end

    if not nextInnerDemonAt then
        nextInnerDemonAt = now + INNER_DEMON_INTERVAL
        return
    end

    while now >= nextInnerDemonAt do
        AddGroup(1, "inner", nextInnerDemonAt)
        nextInnerDemonAt = nextInnerDemonAt + INNER_DEMON_INTERVAL
    end
end

local function UpdateEstimateState(now)
    now = now or GetTime()

    if not IsDemonologySpecActive() then
        wipe(activeGroups)
        nextInnerDemonAt = nil
        return
    end

    AdvanceCombatDecay(now)
    ClearExpiredGroups(now)
    ProcessInnerDemon(now)
    ClearExpiredGroups(now)
end

GetTrackedItemFrame = function(spellID)
    local cachedFrame = trackedItemFrames[spellID]
    if cachedFrame and NormalizeTrackedItemSpellID(GetTrackedFrameSpellID(cachedFrame)) == spellID then
        return cachedFrame
    end

    trackedItemFrames[spellID] = nil

    if not EssentialCooldownViewer or not EssentialCooldownViewer.GetItemFrames then
        return nil
    end

    local itemFrames = EssentialCooldownViewer:GetItemFrames()
    if not itemFrames then
        return nil
    end

    for _, itemFrame in ipairs(itemFrames) do
        local itemSpellID = GetTrackedFrameSpellID(itemFrame)
        if NormalizeTrackedItemSpellID(itemSpellID) == spellID then
            trackedItemFrames[spellID] = itemFrame
            return itemFrame
        end
    end

    return nil
end

-- UI layer: decorate Blizzard's Cooldown Viewer frames only. Keep it visual and
-- cheap; the estimate logic stays above this point.
local function GetOverlayKey(spellID)
    local overlayKey = overlayKeyCache[spellID]
    if not overlayKey then
        overlayKey = "ImpTrackerOverlay" .. tostring(spellID)
        overlayKeyCache[spellID] = overlayKey
    end

    return overlayKey
end

local function EnsureTrackedOverlay(spellID)
    if not IsOverlayEnabled(spellID) then
        return nil
    end

    local itemFrame = GetTrackedItemFrame(spellID)
    if not itemFrame then
        return nil
    end

    local overlayKey = GetOverlayKey(spellID)
    local overlay = itemFrame[overlayKey]

    if not overlay then
        local anchor = itemFrame.Icon or itemFrame

        overlay = CreateFrame("Frame", nil, itemFrame)
        overlay:SetAllPoints(anchor)
        overlay:SetFrameStrata(itemFrame:GetFrameStrata())
        overlay:SetFrameLevel((anchor.GetFrameLevel and anchor:GetFrameLevel()) or (itemFrame:GetFrameLevel() + 8))
        overlay:EnableMouse(false)

        overlay.Border = CreateReadyBorder(overlay)

        if trackedSpellConfigs[spellID] and trackedSpellConfigs[spellID].showCount then
            local countText = overlay:CreateFontString(nil, "OVERLAY")
            countText:SetFont("Fonts\\FRIZQT__.TTF", 30, "THICKOUTLINE")
            countText:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", 6, -1)
            countText:SetJustifyH("RIGHT")
            countText:SetText("0")
            overlay.CountText = countText

            if spellID == IMPLOSION_SPELL_ID then
                local debugCountText = overlay:CreateFontString(nil, "OVERLAY")
                debugCountText:SetFont("Fonts\\FRIZQT__.TTF", 24, "THICKOUTLINE")
                debugCountText:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", 2, 2)
                debugCountText:SetJustifyH("LEFT")
                debugCountText:SetText("0")
                debugCountText:SetTextColor(unpack(IMPLOSION_DEBUG_COUNT_COLOR))
                debugCountText:SetShadowColor(unpack(IMPLOSION_DEBUG_COUNT_SHADOW_COLOR))
                debugCountText:SetShadowOffset(unpack(IMPLOSION_DEBUG_COUNT_SHADOW_OFFSET))
                debugCountText:Hide()
                overlay.DebugCountText = debugCountText
            end
        end

        if spellID == SUMMON_DEMONIC_TYRANT_SPELL_ID then
            local countText = overlay:CreateFontString(nil, "OVERLAY")
            countText:SetFont("Fonts\\FRIZQT__.TTF", 26, "THICKOUTLINE")
            countText:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", 6, -1)
            countText:SetJustifyH("RIGHT")
            countText:SetText("0")
            countText:Hide()
            overlay.WindowCountText = countText

            local hogIcon = overlay:CreateTexture(nil, "OVERLAY")
            hogIcon:SetSize(16, 16)
            hogIcon:SetPoint("RIGHT", countText, "LEFT", -3, 0)
            hogIcon:SetTexture(GetSpellTextureByID(HAND_OF_GULDAN_SPELL_ID))
            hogIcon:Hide()
            overlay.HoGIcon = hogIcon
        end

        itemFrame[overlayKey] = overlay
    end

    if trackedSpellConfigs[spellID] and trackedSpellConfigs[spellID].showCount and itemFrame.ChargeCount then
        itemFrame.ChargeCount:SetAlpha(spellID == IMPLOSION_SPELL_ID and 1 or 0)
        SetImplosionChargeCountStyle(itemFrame, spellID == IMPLOSION_SPELL_ID)
    end

    return overlay, itemFrame
end

local function CleanupStaleOverlays()
    if not EssentialCooldownViewer or not EssentialCooldownViewer.GetItemFrames then
        return
    end

    local itemFrames = EssentialCooldownViewer:GetItemFrames()
    if not itemFrames then
        return
    end

    for _, itemFrame in ipairs(itemFrames) do
        local rawSpellID = GetTrackedFrameSpellID(itemFrame)
        local activeSpellID = NormalizeTrackedItemSpellID(rawSpellID)
        local hideChargeCount = false

        for spellID, config in pairs(trackedSpellConfigs) do
            local overlayKey = GetOverlayKey(spellID)
            local overlay = itemFrame[overlayKey]

            if overlay then
                if activeSpellID == spellID and itemFrame:IsShown() and IsDemonologySpecActive() and IsOverlayEnabled(spellID) then
                    if config.showCount and spellID ~= IMPLOSION_SPELL_ID then
                        hideChargeCount = true
                    end
                else
                    overlay:Hide()
                end
            end
        end

        if itemFrame.ChargeCount then
            itemFrame.ChargeCount:SetAlpha(hideChargeCount and 0 or 1)
            SetImplosionChargeCountStyle(itemFrame, activeSpellID == IMPLOSION_SPELL_ID and itemFrame:IsShown() and IsDemonologySpecActive() and IsOverlayEnabled(IMPLOSION_SPELL_ID), nil, true)
        end
    end
end

local function ObserveGrimoireSlot(now)
    local itemFrame = GetTrackedItemFrame(GRIMOIRE_SLOT_TRACKING_KEY)
    if not itemFrame or not itemFrame.GetSpellID then
        lastGrimoireSlotSpellName = nil
        return
    end

    local rawSpellID = GetTrackedFrameSpellID(itemFrame)
    local rawSpellName = GetSpellNameByID(rawSpellID)
    local grimoireState = trackedCooldownState[GRIMOIRE_SLOT_TRACKING_KEY]

    if grimoireState and (not grimoireState.activated) and lastGrimoireSlotSpellName and grimoireTrackedSpellNames[lastGrimoireSlotSpellName] and grimoireCooldownReplacementNames[rawSpellName] then
        StartEstimatedTrackedCooldown(GRIMOIRE_SLOT_TRACKING_KEY, now)
    end

    lastGrimoireSlotSpellName = rawSpellName
end

-- Grimoire turns into utility buttons on cooldown. Track the slot by name, but
-- only show ready guidance when the visible button is an actual summon.
local function IsGrimoireSummonFrame(itemFrame)
    local rawSpellID = GetTrackedFrameSpellID(itemFrame)
    local rawSpellName = GetSpellNameByID(rawSpellID)
    return rawSpellName and grimoireTrackedSpellNames[rawSpellName]
end

local function UpdateCountOverlay(spellID, estimated, mode, now)
    if not IsOverlayEnabled(spellID) then
        return
    end

    local overlay, itemFrame = EnsureTrackedOverlay(spellID)
    if not overlay or not itemFrame then
        return
    end

    if not itemFrame:IsShown() or not IsDemonologySpecActive() then
        overlay:Hide()
        return
    end

    local count = math.max(0, tonumber(estimated) or 0)
    local countText = overlay.CountText
    local debugCountText = overlay.DebugCountText
    local border = overlay.Border
    local usesNativeImplosionCount = spellID == IMPLOSION_SPELL_ID and itemFrame.ChargeCount
    local showPrimaryOverlayCount = not usesNativeImplosionCount

    overlay:Show()
    if countText then
        countText:SetText(tostring(count))
    end

    if debugCountText then
        if IsImplosionEstimateDebugEnabled() then
            debugCountText:SetText(tostring(count))
            debugCountText:SetTextColor(unpack(IMPLOSION_DEBUG_COUNT_COLOR))
            debugCountText:SetShadowColor(unpack(IMPLOSION_DEBUG_COUNT_SHADOW_COLOR))
            debugCountText:SetShadowOffset(unpack(IMPLOSION_DEBUG_COUNT_SHADOW_OFFSET))
            debugCountText:Show()
        else
            debugCountText:Hide()
        end
    end

    if itemFrame.ChargeCount then
        itemFrame.ChargeCount:SetAlpha(usesNativeImplosionCount and 1 or 0)
        SetImplosionChargeCountStyle(itemFrame, usesNativeImplosionCount, mode)
    end

    if countText then
        if showPrimaryOverlayCount then
            countText:Show()
        else
            countText:Hide()
        end
    end

    if countText then
        countText:SetTextColor(unpack(Advisor.GetTextColor(mode)))
    end

    Advisor.SetReadyBorderMode(border, mode, now)
end

local function UpdateImplosionOverlay(estimated, mode, now)
    UpdateCountOverlay(IMPLOSION_SPELL_ID, estimated, mode, now)
end

local function UpdatePowerSiphonOverlay(estimated, mode, now)
    UpdateCountOverlay(POWER_SIPHON_SPELL_ID, estimated, mode, now)
end

local function UpdateTrackedReadyOverlay(spellID, now, adviceState)
    if not IsOverlayEnabled(spellID) then
        local itemFrame = GetTrackedItemFrame(spellID)
        if itemFrame then
            local overlay = itemFrame[GetOverlayKey(spellID)]
            if overlay then
                overlay:Hide()
            end
        end
        return
    end

    local overlay, itemFrame = EnsureTrackedOverlay(spellID)
    if not overlay or not itemFrame then
        return
    end

    if not itemFrame:IsShown() or not IsDemonologySpecActive() then
        overlay:Hide()
        return
    end

    if spellID == GRIMOIRE_SLOT_TRACKING_KEY and not IsGrimoireSummonFrame(itemFrame) then
        overlay:Hide()
        if overlay.Border then
            SetReadyBorderAlpha(overlay.Border, 0)
        end
        return
    end

    overlay:Show()

    local border = overlay.Border
    local mode = adviceState and adviceState.modes and adviceState.modes[spellID]
    if not mode then
        mode = IsEstimatedTrackedCooldownReady(spellID, now) and "ready" or "tracking"
    end

    Advisor.SetReadyBorderMode(border, mode, now)
end

local function UpdateTyrantWindowOverlay(now)
    if not IsOverlayEnabled(SUMMON_DEMONIC_TYRANT_SPELL_ID) then
        return
    end

    local overlay, itemFrame = EnsureTrackedOverlay(SUMMON_DEMONIC_TYRANT_SPELL_ID)
    if not overlay or not itemFrame then
        return
    end

    local countText = overlay.WindowCountText
    local hogIcon = overlay.HoGIcon
    if not countText or not hogIcon then
        return
    end

    if not itemFrame:IsShown() or not IsDemonologySpecActive() or not IsTyrantWindowActive(now) then
        countText:Hide()
        hogIcon:Hide()
        return
    end

    countText:SetText(tostring(math.max(0, tonumber(tyrantHoGCount) or 0)))
    countText:SetTextColor(0.92, 1.00, 0.95)
    hogIcon:SetTexture(GetSpellTextureByID(HAND_OF_GULDAN_SPELL_ID))
    countText:Show()
    hogIcon:Show()
end

local function EnsureAllTrackedOverlays()
    EnsureTrackedOverlay(IMPLOSION_SPELL_ID)
    EnsureTrackedOverlay(POWER_SIPHON_SPELL_ID)

    for _, spellID in ipairs(GetTrackedReadySpellIDs()) do
        EnsureTrackedOverlay(spellID)
    end
end

local function UpdateAllReadyOverlays(now, adviceState)
    for _, spellID in ipairs(GetTrackedReadySpellIDs()) do
        UpdateTrackedReadyOverlay(spellID, now, adviceState)
    end
end

local function ResetTrackerState(clearGroups)
    if clearGroups then
        wipe(activeGroups)
    end

    wipe(pendingHoG)
    wipe(completedWildImpSummonCasts)
    wipe(completedWildImpSummonCastOrder)
    wipe(pendingHardcastDemonbolts)
    nextInnerDemonAt = nil
    ResetEstimatedCooldowns()
    lastEstimateUpdate = GetTime()
end

-- Main refresh path. Light display updates can run often; structural cleanup is
-- forced after layout/spec changes or throttled during normal ticks.
local function UpdateDisplay(forceStructuralCleanup)
    if not db then
        return
    end

    local now = GetTime()
    RefreshCachedHastePercent()
    UpdateEstimateState(now)
    UpdateTyrantWindowState(now)
    ObserveGrimoireSlot(now)

    if forceStructuralCleanup or (now - (lastStructuralCleanupAt or 0)) >= STRUCTURAL_CLEANUP_INTERVAL then
        CleanupStaleOverlays()
        lastStructuralCleanupAt = now
    end

    if not IsDemonologySpecActive() then
        wipe(activeGroups)
        wipe(pendingHoG)
        nextInnerDemonAt = nil
        ClearTyrantWindow()
        UpdateImplosionOverlay(0, "offspec", now)
        UpdatePowerSiphonOverlay(0, "offspec", now)
        UpdateAllReadyOverlays(now)
        UpdateTyrantWindowOverlay(now)
        return
    end

    local auraCount = 0
    if not ((InCombatLockdown and InCombatLockdown()) or UnitAffectingCombat("player")) then
        auraCount = GetWildImpAuraSnapshot()
        ResyncEstimate(auraCount or 0, now)
        if (auraCount or 0) <= 0 and now >= (startupGraceUntil or 0) then
            wipe(activeGroups)
        end
    elseif now >= (startupGraceUntil or 0) then
        ClearExpiredGroups(now)
    end

    local estimated = GetEstimatedImpCount(now)
    local threshold = db.implosionThreshold or defaults.implosionThreshold
    local adviceState = Advisor.GetState(estimated, threshold, now)

    UpdateImplosionOverlay(estimated, adviceState.modes[IMPLOSION_SPELL_ID], now)
    UpdatePowerSiphonOverlay(estimated, adviceState.modes[POWER_SIPHON_SPELL_ID], now)
    UpdateAllReadyOverlays(now, adviceState)
    UpdateTyrantWindowOverlay(now)
end

local optionsPanel
local optionsCategory

-- Small config surface for testing and tuning without editing saved variables.
local overlayOptionEntries = {
    { key = "showImplosionOverlay", label = function() return GetSpellNameByID(IMPLOSION_SPELL_ID) or "Implosion" end },
    { key = "showPowerSiphonOverlay", label = function() return localizedNames.powerSiphon or FALLBACK_NAMES.powerSiphon end },
    { key = "showDreadstalkersOverlay", label = function() return GetSpellNameByID(CALL_DREADSTALKERS_SPELL_ID) or "Call Dreadstalkers" end },
    { key = "showGrimoireOverlay", label = function() return "Grimoire: Imp Lord / Fel Ravager" end },
    { key = "showTyrantOverlay", label = function() return GetSpellNameByID(SUMMON_DEMONIC_TYRANT_SPELL_ID) or "Summon Demonic Tyrant" end },
    { key = "showDoomguardOverlay", label = function() return localizedNames.summonDoomguard or FALLBACK_NAMES.summonDoomguard end },
}

local function RefreshOptionsPanel()
    if not optionsPanel or not optionsPanel.checkButtons then
        return
    end

    EnsureDB()
    RebuildLocalizedNameCaches()

    for _, option in ipairs(overlayOptionEntries) do
        local checkButton = optionsPanel.checkButtons[option.key]
        if checkButton then
            checkButton:SetChecked(db[option.key] ~= false)
            if checkButton.Label then
                checkButton.Label:SetText(option.label())
            end
        end
    end
end

local function EnsureOptionsPanel()
    if optionsPanel then
        return optionsPanel
    end

    optionsPanel = CreateFrame("Frame", ADDON_NAME .. "OptionsPanel")
    optionsPanel.name = "ImpTracker"
    optionsPanel.checkButtons = {}

    local title = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("ImpTracker")

    local subtitle = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetWidth(620)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Choose which cooldown viewer icons ImpTracker is allowed to enhance.")

    local anchor = subtitle
    for _, option in ipairs(overlayOptionEntries) do
        local checkButton = CreateFrame("CheckButton", nil, optionsPanel, "UICheckButtonTemplate")
        checkButton:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -2, -12)

        local label = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        label:SetPoint("LEFT", checkButton, "RIGHT", 4, 1)
        label:SetText(option.label())
        checkButton.Label = label

        checkButton:SetScript("OnClick", function(self)
            EnsureDB()
            db[option.key] = self:GetChecked() and true or false
            UpdateDisplay(true)
        end)

        optionsPanel.checkButtons[option.key] = checkButton
        anchor = checkButton
    end

    optionsPanel:SetScript("OnShow", RefreshOptionsPanel)

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        optionsCategory = Settings.RegisterCanvasLayoutCategory(optionsPanel, "ImpTracker")
        Settings.RegisterAddOnCategory(optionsCategory)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(optionsPanel)
    end

    return optionsPanel
end

local function OpenOptionsPanel()
    local panel = EnsureOptionsPanel()
    RefreshOptionsPanel()

    if Settings and optionsCategory and optionsCategory.GetID and Settings.OpenToCategory then
        Settings.OpenToCategory(optionsCategory:GetID())
        return
    end

    if InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end

-- Slash commands are intentionally plain: useful while testing, not a second UI.
SLASH_WILDIMPTRACKER1 = "/wit"
SLASH_WILDIMPTRACKER2 = "/itr"
SlashCmdList["WILDIMPTRACKER"] = function(msg)
    EnsureDB()
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")

    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    cmd = string.lower(cmd or "")
    arg = string.lower(arg or "")

    if cmd == "clear" then
        ResetTrackerState(true)
        print("|cff9d7dffImpTracker:|r Estimate cleared.")
    elseif cmd == "status" or cmd == "scan" then
        RefreshTalentState()
        PrintStatus()
    elseif cmd == "threshold" then
        local value = tonumber(arg)
        if value then
            db.implosionThreshold = math.max(1, math.min(40, math.floor(value)))
            print("|cff9d7dffImpTracker:|r Implosion threshold set to " .. tostring(db.implosionThreshold) .. ".")
        end
    elseif cmd == "implodecd" then
        local seconds = tonumber(arg)
        if seconds then
            db.implosionCooldown = math.max(0, math.min(60, seconds))
            print("|cff9d7dffImpTracker:|r Implosion cooldown estimate set to " .. tostring(db.implosionCooldown) .. "s.")
        end
    elseif cmd == "siphoncd" then
        local seconds = tonumber(arg)
        if seconds then
            db.powerSiphonCooldown = math.max(0, math.min(60, seconds))
            print("|cff9d7dffImpTracker:|r Power Siphon cooldown estimate set to " .. tostring(db.powerSiphonCooldown) .. "s.")
        end
    elseif cmd == "doomguardcd" then
        local seconds = tonumber(arg)
        if seconds then
            db.doomguardCooldown = math.max(0, math.min(300, seconds))
            print("|cff9d7dffImpTracker:|r Summon Doomguard cooldown estimate set to " .. tostring(db.doomguardCooldown) .. "s.")
        end
    elseif cmd == "impdebug" then
        if arg == "on" or arg == "1" then
            db.debugImplosionEstimate = true
        elseif arg == "off" or arg == "0" then
            db.debugImplosionEstimate = false
        else
            db.debugImplosionEstimate = not db.debugImplosionEstimate
        end

        print("|cff9d7dffImpTracker:|r Implosion debug estimate overlay " .. (db.debugImplosionEstimate and "enabled" or "disabled") .. ".")
    elseif cmd == "options" or cmd == "config" then
        OpenOptionsPanel()
    else
        print("|cff9d7dffImpTracker:|r Commands: /wit clear | status | options")
        print("|cff9d7dffImpTracker:|r /wit threshold <n> | implodecd <sec> | siphoncd <sec> | doomguardcd <sec>")
    end

    UpdateDisplay()
end

local function HandleImplosionCast(now)
    local removed = RemoveImpCount(IMPS_REMOVED_PER_IMPLOSION, now)
    local replacementCount = GetToHellAndBackReplacementCount(removed)
    if replacementCount > 0 then
        AddGroup(replacementCount, "to-hell-and-back", now)
    end

    nextImplosionReadyAt = now + (db.implosionCooldown or defaults.implosionCooldown)
end

local function HandlePowerSiphonCast(now)
    local removed = RemoveImpCount(IMPS_REMOVED_PER_POWER_SIPHON, now)
    local replacementCount = GetToHellAndBackReplacementCount(removed)
    if replacementCount > 0 then
        AddGroup(replacementCount, "to-hell-and-back", now)
    end

    StartEstimatedTrackedCooldown(POWER_SIPHON_SPELL_ID, now)
end

local function HandleWildImpSummonCast(count, source, now)
    AddGroup(count or MAX_HAND_OF_GULDAN_IMPS, source, now)
    if IsTyrantWindowActive(now) then
        tyrantHoGCount = (tyrantHoGCount or 0) + 1
    end
end

local function RememberCompletedWildImpSummonCast(castGUID)
    if not castGUID or completedWildImpSummonCasts[castGUID] then
        return
    end

    completedWildImpSummonCasts[castGUID] = true
    table.insert(completedWildImpSummonCastOrder, castGUID)
    while #completedWildImpSummonCastOrder > COMPLETED_WILD_IMP_CAST_CACHE_LIMIT do
        local oldCastGUID = table.remove(completedWildImpSummonCastOrder, 1)
        if oldCastGUID then
            completedWildImpSummonCasts[oldCastGUID] = nil
        end
    end
end

-- Blizzard owns layout. Rebuild cached frame links after it moves things.
local function HookCooldownViewer()
    if not EssentialCooldownViewer or EssentialCooldownViewer.ImpTrackerHooked or not EssentialCooldownViewer.GetItemFrames then
        return
    end

    EssentialCooldownViewer.ImpTrackerHooked = true
    hooksecurefunc(EssentialCooldownViewer, "Layout", function()
        wipe(trackedItemFrames)
        EnsureAllTrackedOverlays()
        UpdateDisplay(true)
    end)
end

-- Player-only event wiring. Normalize incoming values before comparing them;
-- some Midnight surfaces can hand addon Lua protected values.
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("UNIT_SPELLCAST_START")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_FAILED")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event ~= "ADDON_LOADED" and not db then
        EnsureDB()
    end

    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= ADDON_NAME then
            return
        end

        EnsureDB()
        RefreshTalentState()
        EnsureDoomguardTracking(GetDoomguardSpellID())
        EnsureOptionsPanel()
        HookCooldownViewer()
        EnsureAllTrackedOverlays()
        startupGraceUntil = GetTime() + 3
        lastEstimateUpdate = GetTime()
        UpdateDisplay(true)
        print("|cff9d7dffImpTracker:|r Loaded. Enhancing Blizzard cooldown icons.")
    elseif event == "PLAYER_ENTERING_WORLD" then
        HookCooldownViewer()
        wipe(trackedItemFrames)
        ResetTrackerState(true)
        RefreshTalentState()
        EnsureDoomguardTracking(GetDoomguardSpellID())
        startupGraceUntil = GetTime() + 3
        UpdateDisplay(true)
    elseif event == "PLAYER_REGEN_DISABLED" then
        lastEstimateUpdate = GetTime()
        UpdateDisplay()
    elseif event == "PLAYER_REGEN_ENABLED" then
        lastEstimateUpdate = GetTime()
        UpdateDisplay()
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        local unit = ...
        unit = NormalizeSafeStringKey(unit)
        if unit ~= "player" then
            return
        end

        RefreshTalentState()
        EnsureDoomguardTracking(GetDoomguardSpellID())
        ResetTrackerState(true)
        UpdateDisplay(true)
    elseif event == "PLAYER_TALENT_UPDATE" or event == "TRAIT_CONFIG_UPDATED" then
        RefreshTalentState()
        EnsureDoomguardTracking(GetDoomguardSpellID())
        nextInnerDemonAt = nil
        UpdateTyrantWindowState()
        UpdateDisplay(true)
    elseif event == "UNIT_AURA" then
        local unit = ...
        unit = NormalizeSafeStringKey(unit)
        if unit == "player" then
            UpdateDisplay()
        end
    elseif event == "UNIT_SPELLCAST_START" then
        local unit, castGUID, spellID = ...
        unit = NormalizeSafeStringKey(unit)
        castGUID = NormalizeSafeStringKey(castGUID)
        spellID = NormalizeSafeSpellID(spellID)
        if unit ~= "player" then
            return
        end

        if castGUID and (spellID == HAND_OF_GULDAN_SPELL_ID or spellID == RUINATION_SPELL_ID) then
            pendingHoG[castGUID] = spellID == RUINATION_SPELL_ID and RUINATION_WILD_IMPS or MAX_HAND_OF_GULDAN_IMPS
        elseif spellID == DEMONBOLT_SPELL_ID and castGUID then
            pendingHardcastDemonbolts[castGUID] = true
        end

        UpdateDisplay()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...
        unit = NormalizeSafeStringKey(unit)
        castGUID = NormalizeSafeStringKey(castGUID)
        spellID = NormalizeSafeSpellID(spellID)
        if unit ~= "player" then
            return
        end

        local now = GetTime()
        local normalizedSpellID = NormalizeTrackedCastSpellID(spellID)
        local castSpellName = GetSpellNameByID(spellID)
        if castSpellName and (castSpellName == localizedNames.powerSiphon or castSpellName == FALLBACK_NAMES.powerSiphon) then
            RememberName("powerSiphon", castSpellName)
            RememberSpellID("powerSiphon", spellID)
            trackedSpellAliases[spellID] = POWER_SIPHON_SPELL_ID
            normalizedSpellID = POWER_SIPHON_SPELL_ID
        elseif castSpellName and (castSpellName == localizedNames.summonDoomguard or castSpellName == FALLBACK_NAMES.summonDoomguard) then
            RememberName("summonDoomguard", castSpellName)
            normalizedSpellID = EnsureDoomguardTracking(spellID) or normalizedSpellID
        end

        if spellID == DEMONBOLT_SPELL_ID then
            -- Instant Demonbolts arrive without SPELLCAST_START, which lets us
            -- infer Demonic Core consumption without reading combat-locked auras.
            local usedDemonicCore = not (castGUID and pendingHardcastDemonbolts[castGUID])
            if castGUID then
                pendingHardcastDemonbolts[castGUID] = nil
            end
            if usedDemonicCore then
                ApplyDemonicCoreDoomguardReduction(now)
            end
        end

        if spellID == HAND_OF_GULDAN_SPELL_ID or spellID == RUINATION_SPELL_ID then
            if castGUID and completedWildImpSummonCasts[castGUID] then
                pendingHoG[castGUID] = nil
            else
                local count = castGUID and pendingHoG[castGUID]
                if castGUID then
                    pendingHoG[castGUID] = nil
                    RememberCompletedWildImpSummonCast(castGUID)
                end
                if spellID == RUINATION_SPELL_ID then
                    HandleWildImpSummonCast(count or RUINATION_WILD_IMPS, "ruination", now)
                else
                    HandleWildImpSummonCast(count or MAX_HAND_OF_GULDAN_IMPS, "hand-of-guldan", now)
                end
            end
        elseif normalizedSpellID == IMPLOSION_SPELL_ID then
            HandleImplosionCast(now)
        elseif normalizedSpellID == POWER_SIPHON_SPELL_ID then
            HandlePowerSiphonCast(now)
        elseif normalizedSpellID == SUMMON_DEMONIC_TYRANT_SPELL_ID then
            StartEstimatedTrackedCooldown(normalizedSpellID, now)
            StartTyrantWindow(now)
        elseif trackedCooldownState[normalizedSpellID] then
            StartEstimatedTrackedCooldown(normalizedSpellID, now)
        end

        UpdateDisplay()
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
        local unit, castGUID = ...
        unit = NormalizeSafeStringKey(unit)
        castGUID = NormalizeSafeStringKey(castGUID)
        if unit == "player" and castGUID then
            pendingHoG[castGUID] = nil
            completedWildImpSummonCasts[castGUID] = nil
            pendingHardcastDemonbolts[castGUID] = nil
        end
        UpdateDisplay()
    end
end)

C_Timer.NewTicker(DISPLAY_UPDATE_INTERVAL, function()
    UpdateDisplay()
end)
