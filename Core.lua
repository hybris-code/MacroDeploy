-- MacroDeploy / Core.lua
-- Export, deploy and retry engine.

local ADDON, NS = ...
local P = NS.Profile

local NUM_SLOTS        = _G.MAX_ACTIONBAR_SLOTS or 180
local MAX_ACCOUNT      = _G.MAX_ACCOUNT_MACROS or 120
local MAX_CHARACTER    = _G.MAX_CHARACTER_MACROS or 18
local FALLBACK_ICON    = 134400 -- INV_Misc_QuestionMark

-- ===========================================================================
-- Compatibility shims
--
-- 12.0 moved a lot of globals into C_ namespaces and the Forever beta client
-- is a Retail API wearing a 16001 interface number, so nothing is assumed to
-- exist. Every resolved function is reported by /md diag.
-- ===========================================================================
local API = {}

local function resolve(...)
    for i = 1, select("#", ...) do
        local f = select(i, ...)
        if type(f) == "function" then return f end
    end
end

local C_Spell        = _G.C_Spell
local C_Item         = _G.C_Item
local C_SpellBook    = _G.C_SpellBook
local C_ActionBar    = _G.C_ActionBar
local C_MountJournal = _G.C_MountJournal
local C_EquipmentSet = _G.C_EquipmentSet

API.PickupSpell   = resolve(C_Spell and C_Spell.PickupSpell, _G.PickupSpell)
API.PickupItem    = resolve(C_Item and C_Item.PickupItem, _G.PickupItem)
API.GetItemCount  = resolve(C_Item and C_Item.GetItemCount, _G.GetItemCount)
API.IsPlayerSpell = resolve(_G.IsPlayerSpell, C_SpellBook and C_SpellBook.IsSpellKnown, _G.IsSpellKnown)
API.GetSpellName  = resolve(C_Spell and C_Spell.GetSpellName, _G.GetSpellInfo)
API.PlaceAction   = resolve(_G.PlaceAction, C_ActionBar and C_ActionBar.PlaceAction)
API.HasAction     = resolve(_G.HasAction, C_ActionBar and C_ActionBar.HasAction)
API.GetActionText = _G.GetActionText
API.PickupMacro   = _G.PickupMacro
API.CreateMacro   = _G.CreateMacro
API.EditMacro     = _G.EditMacro
API.GetMacroInfo  = _G.GetMacroInfo
API.GetNumMacros  = _G.GetNumMacros
API.GetMacroIndexByName = _G.GetMacroIndexByName
API.SetBinding        = _G.SetBinding
API.SaveBindings      = _G.SaveBindings
API.GetBindingAction  = _G.GetBindingAction
API.GetCurrentBindingSet = _G.GetCurrentBindingSet

-- GetActionInfo: prefer the global; normalise a table return if the C_ version
-- is all that exists.
local function GetActionInfo(slot)
    if _G.GetActionInfo then return _G.GetActionInfo(slot) end
    local f = C_ActionBar and C_ActionBar.GetActionInfo
    if not f then return nil end
    local a, b, c = f(slot)
    if type(a) == "table" then
        return a.type or a.actionType, a.id or a.actionID or a.spellID, a.subType
    end
    return a, b, c
end
API.GetActionInfo = GetActionInfo

-- ===========================================================================
-- Output
-- ===========================================================================
local function say(level, fmt, ...)
    if (P.options.verbosity or 1) < level then return end
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    print("|cff33ccffMacroDeploy|r: " .. msg)
end

local function warn(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    print("|cff33ccffMacroDeploy|r |cffff6060warning|r: " .. msg)
end

-- ===========================================================================
-- Serializer (Lua literal, human-readable, paste-ready)
-- ===========================================================================
local function quote(s)
    -- %q escapes a newline as backslash + real newline; fold it to \n so the
    -- generated file stays one-macro-per-line and readable.
    local out = string.format("%q", tostring(s))
    out = out:gsub("\\\n", "\\n")
    return out
end

local function serializeMacros(macros)
    local out = {}
    for _, m in ipairs(macros) do
        out[#out + 1] = string.format(
            "    { name = %s, icon = %s, perChar = %s, body = %s },",
            quote(m.name),
            type(m.icon) == "number" and tostring(m.icon) or quote(m.icon or FALLBACK_ICON),
            m.perChar and "true" or "false",
            quote(m.body or "")
        )
    end
    return table.concat(out, "\n")
end

local function serializeActions(actions)
    local slots = {}
    for slot in pairs(actions) do slots[#slots + 1] = slot end
    table.sort(slots)

    local out = {}
    for _, slot in ipairs(slots) do
        local e = actions[slot]
        local body
        if e.name then
            body = string.format("kind = %s, name = %s", quote(e.kind), quote(e.name))
        else
            body = string.format("kind = %s, id = %d", quote(e.kind), e.id)
        end
        out[#out + 1] = string.format("    [%d] = { %s },%s", slot, body,
            e.comment and (" -- " .. e.comment) or "")
    end
    return table.concat(out, "\n")
end

local function serializeBindings(bindings)
    local out = {}
    for _, b in ipairs(bindings) do
        out[#out + 1] = string.format("    { key = %s, action = %s },",
            quote(b.key), quote(b.action))
    end
    return table.concat(out, "\n")
end

-- ===========================================================================
-- Export
-- ===========================================================================
local function scanMacros()
    local macros, seen, dupes = {}, {}, {}
    local numAccount, numChar = API.GetNumMacros()
    numAccount, numChar = numAccount or 0, numChar or 0

    local function grab(index, perChar)
        local name, icon, body = API.GetMacroInfo(index)
        if not name or name == "" then return end
        if seen[name] then dupes[name] = true end
        seen[name] = true
        macros[#macros + 1] = { name = name, icon = icon, body = body, perChar = perChar }
    end

    for i = 1, numAccount do grab(i, false) end
    for i = 1, numChar do grab(MAX_ACCOUNT + i, true) end

    for name in pairs(dupes) do
        warn("duplicate macro name %q - placement by name is ambiguous, rename one.", name)
    end
    return macros
end

local function macroNameForIndex(index)
    local name = API.GetMacroInfo(index)
    return name
end

local function scanActions()
    local actions, count, used = {}, 0, 0
    for slot = 1, NUM_SLOTS do
        local kind, id, subType = API.GetActionInfo(slot)
        if kind then
            used = used + 1
            local entry
            if kind == "macro" then
                -- This client's GetActionInfo returns a macro's *resolved spell id*
                -- (as a string) as the second value, not the macro index, so
                -- macroNameForIndex(id) fails. GetActionText(slot) returns the macro
                -- name directly and is reliable whether or not the spell is learned.
                local name = API.GetActionText and API.GetActionText(slot)
                if not name or name == "" then
                    name = macroNameForIndex(tonumber(id) or id)
                end
                if name and name ~= "" then
                    entry = { kind = "macro", name = name }
                else
                    warn("slot %d holds a macro with no resolvable name; skipped.", slot)
                end
            elseif kind == "spell" then
                local sname = API.GetSpellName and API.GetSpellName(id)
                entry = { kind = "spell", id = id, comment = sname }
            elseif kind == "item" then
                entry = { kind = "item", id = id }
            elseif kind == "summonmount" then
                entry = { kind = "summonmount", id = id }
            elseif kind == "equipmentset" then
                entry = { kind = "equipmentset", name = tostring(id) }
            else
                warn("slot %d holds unsupported action type %q; skipped.", slot, tostring(kind))
            end
            if entry then
                actions[slot] = entry
                count = count + 1
            end
        end
    end
    return actions, count, used
end

-- Sweep the realistic key universe and ask the client what each key does.
-- More reliable than walking GetNumBindings(), and it catches CLICK bindings
-- created by Bartender4 / ElvUI, which is the whole point under a bar addon.
local KEY_BASES = {}
do
    for i = 0, 9 do KEY_BASES[#KEY_BASES + 1] = tostring(i) end
    for c = 65, 90 do KEY_BASES[#KEY_BASES + 1] = string.char(c) end
    for i = 1, 12 do KEY_BASES[#KEY_BASES + 1] = "F" .. i end
    for i = 0, 9 do KEY_BASES[#KEY_BASES + 1] = "NUMPAD" .. i end
    for i = 3, 15 do KEY_BASES[#KEY_BASES + 1] = "BUTTON" .. i end
    for _, k in ipairs({
        "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`",
        "TAB", "SPACE", "INSERT", "DELETE", "HOME", "END", "PAGEUP", "PAGEDOWN",
        "UP", "DOWN", "LEFT", "RIGHT", "MOUSEWHEELUP", "MOUSEWHEELDOWN",
        "NUMPADPLUS", "NUMPADMINUS", "NUMPADMULTIPLY", "NUMPADDIVIDE", "NUMPADDECIMAL",
    }) do
        KEY_BASES[#KEY_BASES + 1] = k
    end
end

local MODIFIERS = {
    "", "SHIFT-", "CTRL-", "ALT-",
    "CTRL-SHIFT-", "ALT-SHIFT-", "ALT-CTRL-", "ALT-CTRL-SHIFT-",
}

local function scanBindings()
    local out = {}
    if not API.GetBindingAction then return out end
    for _, mod in ipairs(MODIFIERS) do
        for _, base in ipairs(KEY_BASES) do
            local key = mod .. base
            local action = API.GetBindingAction(key)
            if action and action ~= "" then
                out[#out + 1] = { key = key, action = action }
            end
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

local TEMPLATE_HEAD = [[
-- MacroDeploy / Profile.lua  (generated by /md export)
-- Regenerate by running /md export and pasting over this file.

local ADDON, NS = ...

local P = {}
NS.Profile = P

P.meta = {
    exportedBy = %s,
    class      = %s,
    spec       = %s,
    level      = %d,
    build      = %s,
    interface  = %d,
    exportedAt = %s,
}

P.guards = {
    autoApply        = %s,
    maxLevel         = %d,
    requireClass     = %s,
    requireEmptyBars = %s,
    emptyBarsRatio   = %s,
    realmWhitelist   = nil,
    loginDelay       = %d,
}

P.options = {
    overwriteMacros = %s,
    overwriteSlots  = %s,
    includeSpells   = %s,
    includeItems    = %s,
    includeBindings = %s,
    bindingSet      = %d,
    retryQueue      = %s,
    verbosity       = %d,
}

P.macros = {
]]

local function buildExportText()
    local macros = scanMacros()
    local actions, placed = scanActions()
    local bindings = scanBindings()

    local _, class = UnitClass("player")
    local name, realm
    if UnitFullName then
        name, realm = UnitFullName("player")
    end
    name  = name or UnitName("player")
    realm = realm or GetRealmName()
    local version, build, _, iface = GetBuildInfo()
    local g, o = P.guards, P.options

    local specName = ""
    if _G.GetSpecialization and _G.GetSpecializationInfo then
        local idx = GetSpecialization()
        if idx then
            local _, sn = GetSpecializationInfo(idx)
            specName = sn or ""
        end
    end

    local head = TEMPLATE_HEAD:format(
        quote((name or "?") .. "-" .. (realm or "?")),
        quote(class or "?"),
        quote(specName),
        UnitLevel("player") or 0,
        quote(tostring(version) .. "." .. tostring(build)),
        tonumber(iface) or 0,
        quote(date("%Y-%m-%d %H:%M:%S")),
        tostring(g.autoApply and true or false),
        g.maxLevel or 0,
        g.requireClass and quote(g.requireClass) or "nil",
        tostring(g.requireEmptyBars and true or false),
        tostring(g.emptyBarsRatio or 0.9),
        g.loginDelay or 3,
        tostring(o.overwriteMacros and true or false),
        tostring(o.overwriteSlots and true or false),
        tostring(o.includeSpells and true or false),
        tostring(o.includeItems and true or false),
        tostring(o.includeBindings and true or false),
        o.bindingSet or 1,
        tostring(o.retryQueue and true or false),
        o.verbosity or 1
    )

    local text = head
        .. serializeMacros(macros) .. "\n}\n\nP.actions = {\n"
        .. serializeActions(actions) .. "\n}\n\nP.bindings = {\n"
        .. serializeBindings(bindings) .. "\n}\n\nreturn P\n"

    return text, #macros, placed, #bindings
end

-- ===========================================================================
-- Export window
-- ===========================================================================
local exportFrame
local function showExport(text)
    if not exportFrame then
        -- Fall back to a bare frame if the Blizzard template is absent on this client.
        local ok, f = pcall(CreateFrame, "Frame", "MacroDeployExportFrame", UIParent, "BasicFrameTemplateWithInset")
        if not ok or not f then
            f = CreateFrame("Frame", "MacroDeployExportFrame", UIParent)
            local bg = f:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0, 0, 0, 0.9)
        end
        f:SetSize(660, 520)
        f:SetPoint("CENTER")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetFrameStrata("DIALOG")

        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        f.title:SetPoint("TOP", 0, -6)
        f.title:SetText("MacroDeploy export - Ctrl+A, Ctrl+C, paste over Profile.lua")

        local scroll = CreateFrame("ScrollFrame", "$parentScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -32)
        scroll:SetPoint("BOTTOMRIGHT", -32, 12)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(600)
        edit:SetAutoFocus(false)
        edit:SetMaxLetters(0)
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(edit)

        f.edit = edit
        exportFrame = f
    end
    exportFrame.edit:SetText(text)
    exportFrame:Show()
    exportFrame.edit:SetFocus()
    exportFrame.edit:HighlightText()
end

-- ===========================================================================
-- Deploy
-- ===========================================================================
local pending = {}   -- slot -> entry, retried on level-up / spell learn / bag update

local function existingMacroMap()
    local map = {}
    local numAccount, numChar = API.GetNumMacros()
    for i = 1, (numAccount or 0) do
        local n, _, b = API.GetMacroInfo(i)
        if n then map[n] = { index = i, body = b, perChar = false } end
    end
    for i = 1, (numChar or 0) do
        local n, _, b = API.GetMacroInfo(MAX_ACCOUNT + i)
        if n then map[n] = { index = MAX_ACCOUNT + i, body = b, perChar = true } end
    end
    return map
end

local function deployMacros()
    local created, updated, skipped, failed = 0, 0, 0, 0
    local map = existingMacroMap()
    local numAccount, numChar = API.GetNumMacros()
    local freeAccount = MAX_ACCOUNT - (numAccount or 0)
    local freeChar    = MAX_CHARACTER - (numChar or 0)

    for _, m in ipairs(P.macros) do
        local have = map[m.name]
        if have then
            if P.options.overwriteMacros and have.body ~= m.body then
                local ok = pcall(API.EditMacro, have.index, m.name, m.icon or FALLBACK_ICON, m.body)
                if ok then updated = updated + 1 else failed = failed + 1 end
                say(2, "macro %q updated", m.name)
            else
                skipped = skipped + 1
            end
        else
            local room = m.perChar and freeChar or freeAccount
            if room <= 0 then
                warn("no free %s macro slots left; %q not created.",
                    m.perChar and "character" or "account", m.name)
                failed = failed + 1
            else
                local ok, idx = pcall(API.CreateMacro, m.name, m.icon or FALLBACK_ICON, m.body, m.perChar and true or nil)
                if ok and idx then
                    created = created + 1
                    if m.perChar then freeChar = freeChar - 1 else freeAccount = freeAccount - 1 end
                    say(2, "macro %q created", m.name)
                else
                    warn("CreateMacro failed for %q (%s)", m.name, tostring(idx))
                    failed = failed + 1
                end
            end
        end
    end
    return created, updated, skipped, failed
end

-- Returns: true placed, false retry-later, nil unsupported/permanently failed
local function pickup(entry)
    local kind = entry.kind
    if kind == "macro" then
        local idx = API.GetMacroIndexByName and API.GetMacroIndexByName(entry.name) or 0
        if idx == 0 then return nil, "macro not found" end
        API.PickupMacro(idx)
        return true
    elseif kind == "spell" then
        if not P.options.includeSpells then return nil, "spells disabled" end
        if API.IsPlayerSpell and not API.IsPlayerSpell(entry.id) then
            return false, "spell not known yet"
        end
        if not API.PickupSpell then return nil, "no PickupSpell" end
        API.PickupSpell(entry.id)
        return true
    elseif kind == "item" then
        if not P.options.includeItems then return nil, "items disabled" end
        if API.GetItemCount and (API.GetItemCount(entry.id) or 0) < 1 then
            return false, "item not in bags yet"
        end
        if not API.PickupItem then return nil, "no PickupItem" end
        API.PickupItem(entry.id)
        return true
    elseif kind == "summonmount" then
        if C_MountJournal and C_MountJournal.PickupByID then
            C_MountJournal.PickupByID(entry.id)
            return true
        end
        if API.PickupSpell then API.PickupSpell(entry.id); return true end
        return nil, "no mount pickup API"
    elseif kind == "equipmentset" then
        if C_EquipmentSet and C_EquipmentSet.GetEquipmentSetID and C_EquipmentSet.PickupEquipmentSet then
            local id = C_EquipmentSet.GetEquipmentSetID(entry.name)
            if not id then return false, "equipment set missing" end
            C_EquipmentSet.PickupEquipmentSet(id)
            return true
        end
        return nil, "no equipment set API"
    end
    return nil, "unsupported kind " .. tostring(kind)
end

local function deployActions(intoPending)
    local placed, deferred, skipped = 0, 0, 0
    for slot = 1, NUM_SLOTS do
        local entry = P.actions[slot]
        if entry then
            local occupied = API.HasAction and API.HasAction(slot)
            if occupied and not P.options.overwriteSlots then
                skipped = skipped + 1
            else
                ClearCursor()
                local ok, reason = pickup(entry)
                if ok then
                    API.PlaceAction(slot)
                    ClearCursor()
                    placed = placed + 1
                    say(2, "slot %d <- %s %s", slot, entry.kind, entry.name or entry.id)
                elseif ok == false then
                    ClearCursor()
                    deferred = deferred + 1
                    if intoPending then pending[slot] = entry end
                    say(2, "slot %d deferred (%s)", slot, reason)
                else
                    ClearCursor()
                    skipped = skipped + 1
                    say(2, "slot %d skipped (%s)", slot, reason)
                end
            end
        end
    end
    return placed, deferred, skipped
end

local function deployBindings()
    if not P.options.includeBindings then return 0 end
    if not (API.SetBinding and API.SaveBindings) then
        warn("binding API unavailable; bindings not applied.")
        return 0
    end
    local n = 0
    for _, b in ipairs(P.bindings) do
        if API.SetBinding(b.key, b.action) then n = n + 1 end
    end
    if n > 0 then
        local set = P.options.bindingSet or 1
        pcall(API.SaveBindings, set)
    end
    return n
end

local function retryPending()
    if not next(pending) then return end
    local done = {}
    for slot, entry in pairs(pending) do
        ClearCursor()
        local ok = pickup(entry)
        if ok then
            API.PlaceAction(slot)
            done[#done + 1] = slot
            say(2, "slot %d filled on retry (%s %s)", slot, entry.kind, entry.name or entry.id)
        end
        ClearCursor()
    end
    for _, slot in ipairs(done) do pending[slot] = nil end
    if #done > 0 then
        say(1, "%d deferred slot(s) filled, %d still waiting.", #done, (function()
            local c = 0; for _ in pairs(pending) do c = c + 1 end; return c
        end)())
    end
end

-- ===========================================================================
-- Guards
-- ===========================================================================
local function barsAreEmpty()
    local used, total = 0, 0
    for slot = 1, 120 do
        total = total + 1
        if API.HasAction and API.HasAction(slot) then used = used + 1 end
    end
    local emptyRatio = (total - used) / total
    return emptyRatio >= (P.guards.emptyBarsRatio or 0.9), emptyRatio
end

local function checkGuards()
    local g = P.guards
    if g.maxLevel and g.maxLevel > 0 and (UnitLevel("player") or 0) > g.maxLevel then
        return false, ("level %d exceeds maxLevel %d"):format(UnitLevel("player"), g.maxLevel)
    end
    if g.requireClass then
        local _, class = UnitClass("player")
        if class ~= g.requireClass then
            return false, ("class %s does not match requireClass %s"):format(tostring(class), g.requireClass)
        end
    end
    if g.realmWhitelist then
        local realm = GetRealmName()
        if not g.realmWhitelist[realm] then
            return false, ("realm %s not in whitelist"):format(tostring(realm))
        end
    end
    if g.requireEmptyBars then
        local ok, ratio = barsAreEmpty()
        if not ok then
            return false, ("bars are %d%% empty, need %d%%"):format(ratio * 100, (g.emptyBarsRatio or 0.9) * 100)
        end
    end
    return true
end

-- ===========================================================================
-- Entry point
-- ===========================================================================
local applyQueuedAfterCombat = false

local REQUIRED = { "CreateMacro", "GetMacroInfo", "GetNumMacros", "GetMacroIndexByName",
                   "PickupMacro", "PlaceAction", "HasAction", "GetActionInfo" }

local function Deploy(force)
    for _, n in ipairs(REQUIRED) do
        if type(API[n]) ~= "function" then
            warn("required API %s is unavailable on this client; aborting. Run /md diag.", n)
            return
        end
    end

    if InCombatLockdown() then
        applyQueuedAfterCombat = force and "force" or true
        say(1, "in combat; deployment queued until combat ends.")
        return
    end

    if not force then
        local ok, reason = checkGuards()
        if not ok then
            say(1, "guards blocked deployment: %s. Use |cffffff00/md apply force|r to override.", reason)
            return
        end
    end

    if #P.macros == 0 and not next(P.actions) and #P.bindings == 0 then
        warn("profile is empty. Run /md export on a configured character first.")
        return
    end

    local c, u, s, f = deployMacros()
    local placed, deferred, slotSkipped = deployActions(P.options.retryQueue)
    local bound = deployBindings()

    say(1, "macros: %d created, %d updated, %d unchanged, %d failed.", c, u, s, f)
    say(1, "slots: %d placed, %d deferred, %d skipped.", placed, deferred, slotSkipped)
    if bound > 0 then say(1, "bindings: %d applied (set %d).", bound, P.options.bindingSet or 1) end
    if deferred > 0 then
        say(1, "%d slot(s) waiting on unlearned spells or missing items; they will fill automatically.", deferred)
    end

    MacroDeployCharDB = MacroDeployCharDB or {}
    MacroDeployCharDB.deployedAt = date("%Y-%m-%d %H:%M:%S")
end

local function DryRun()
    local macroCount = #P.macros
    local map = existingMacroMap()
    local missing = 0
    for _, m in ipairs(P.macros) do if not map[m.name] then missing = missing + 1 end end

    local slotCount, occupied = 0, 0
    for slot, _ in pairs(P.actions) do
        slotCount = slotCount + 1
        if API.HasAction and API.HasAction(slot) then occupied = occupied + 1 end
    end

    local ok, reason = checkGuards()
    print("|cff33ccffMacroDeploy|r dry run:")
    print(("  profile: %s, %s, level %d, built %s"):format(
        P.meta.exportedBy or "?", P.meta.class or "?", P.meta.level or 0, P.meta.exportedAt or "?"))
    print(("  macros: %d in profile, %d missing on this character"):format(macroCount, missing))
    print(("  slots: %d in profile, %d already occupied here"):format(slotCount, occupied))
    print(("  bindings: %d in profile"):format(#P.bindings))
    print(("  guards: %s%s"):format(ok and "|cff60ff60pass|r" or "|cffff6060block|r",
        ok and "" or (" - " .. reason)))
end

local function Diag()
    local version, build, _, iface = GetBuildInfo()
    print(("|cff33ccffMacroDeploy|r diagnostics - client %s.%s, interface %s"):format(
        tostring(version), tostring(build), tostring(iface)))
    print(("  action slots scanned: %d | macro pool: %d account / %d character"):format(
        NUM_SLOTS, MAX_ACCOUNT, MAX_CHARACTER))
    local names = {
        "CreateMacro", "EditMacro", "GetMacroInfo", "GetNumMacros", "GetMacroIndexByName",
        "PickupMacro", "PlaceAction", "HasAction", "GetActionInfo", "GetActionText",
        "PickupSpell", "PickupItem", "GetItemCount", "IsPlayerSpell",
        "SetBinding", "SaveBindings", "GetBindingAction",
    }
    local missing = {}
    for _, n in ipairs(names) do
        if type(API[n]) ~= "function" then missing[#missing + 1] = n end
    end
    if #missing == 0 then
        print("  |cff60ff60all required APIs resolved|r")
    else
        print("  |cffff6060missing:|r " .. table.concat(missing, ", "))
    end
    local numAccount, numChar = API.GetNumMacros()
    print(("  macros present: %d account, %d character"):format(numAccount or 0, numChar or 0))
end

-- ===========================================================================
-- Events
-- ===========================================================================
local f = CreateFrame("Frame")
-- Register defensively. On this client RegisterEvent raises a Lua error for an
-- event name it does not know, which would abort the rest of this file --
-- including the slash-command registration below. LEARNED_SPELL_IN_TAB was
-- superseded by LEARNED_SPELL_IN_SKILL_LINE around 11.0, so register both and
-- pcall each so an unknown one is skipped instead of killing the addon.
for _, ev in ipairs({
    "PLAYER_ENTERING_WORLD",
    "PLAYER_REGEN_ENABLED",
    "PLAYER_LEVEL_UP",
    "SPELLS_CHANGED",
    "LEARNED_SPELL_IN_TAB",
    "LEARNED_SPELL_IN_SKILL_LINE",
    "BAG_UPDATE_DELAYED",
}) do
    pcall(f.RegisterEvent, f, ev)
end

f:SetScript("OnEvent", function(_, event, isInitialLogin)
    if event == "PLAYER_ENTERING_WORLD" then
        if isInitialLogin and P.guards.autoApply then
            C_Timer.After(P.guards.loginDelay or 3, function() Deploy(false) end)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if applyQueuedAfterCombat then
            local force = applyQueuedAfterCombat == "force"
            applyQueuedAfterCombat = false
            Deploy(force)
        end
    elseif P.options.retryQueue then
        C_Timer.After(0.5, retryPending)
    end
end)

-- ===========================================================================
-- Slash commands
-- ===========================================================================
SLASH_MACRODEPLOY1 = "/md"
SLASH_MACRODEPLOY2 = "/macrodeploy"
SlashCmdList.MACRODEPLOY = function(msg)
    local cmd, arg = msg:lower():match("^(%S*)%s*(.-)$")
    if cmd == "export" then
        local text, nm, na, nb = buildExportText()
        showExport(text)
        say(1, "exported %d macros, %d action slots, %d bindings.", nm, na, nb)
    elseif cmd == "apply" or cmd == "deploy" then
        Deploy(arg == "force")
    elseif cmd == "scan" or cmd == "dryrun" then
        DryRun()
    elseif cmd == "retry" then
        retryPending()
    elseif cmd == "diag" then
        Diag()
    else
        print("|cff33ccffMacroDeploy|r commands:")
        print("  |cffffff00/md export|r      - dump this character's setup as a new Profile.lua")
        print("  |cffffff00/md apply|r       - deploy the baked profile (guards enforced)")
        print("  |cffffff00/md apply force|r - deploy, ignoring all guards")
        print("  |cffffff00/md scan|r        - dry run: what would happen, and why guards pass or block")
        print("  |cffffff00/md retry|r       - retry slots waiting on unlearned spells / missing items")
        print("  |cffffff00/md diag|r        - client build and API availability check")
    end
end
