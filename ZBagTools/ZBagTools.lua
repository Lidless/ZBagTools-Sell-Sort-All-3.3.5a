local BAGS = {0,1,2,3,4}

local function p(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ccff[ZBagTools]|r " .. msg)
end

local function NumSlots(bag)
	if C_Container and C_Container.GetContainerNumSlots then
		return C_Container.GetContainerNumSlots(bag)
	end
	return GetContainerNumSlots(bag)
end

local function GetLink(bag, slot)
	if C_Container and C_Container.GetContainerItemLink then
		return C_Container.GetContainerItemLink(bag, slot)
	end
	return GetContainerItemLink(bag, slot)
end

local function ParseItemID(link)
	if not link then return nil end
	local id = link:match("item:(%d+)")
	return id and tonumber(id) or nil
end

-- itemID-t mindig a linkbol olvassuk ki,
-- count/locked-hoz pedig sorra probaljuk a lehetseges API-kat
local function SlotInfo(bag, slot)
	local link = GetLink(bag, slot)
	local itemID = ParseItemID(link)
	local count, locked

	if C_Container and C_Container.GetContainerItemInfo then
		local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
		if ok and info then
			count = info.stackCount
			locked = info.isLocked
			itemID = info.itemID or itemID
		end
	end

	if not count and GetContainerItemInfo then
		local ok, texture, c, l = pcall(GetContainerItemInfo, bag, slot)
		if ok and texture then
			count = c
			locked = l
		end
	end

	return itemID, count, locked, link
end

local function PickupSlot(bag, slot)
	if C_Container and C_Container.PickupContainerItem then
		C_Container.PickupContainerItem(bag, slot)
	else
		PickupContainerItem(bag, slot)
	end
end

local function UseSlot(bag, slot)
	if C_Container and C_Container.UseContainerItem then
		C_Container.UseContainerItem(bag, slot)
	else
		UseContainerItem(bag, slot)
	end
end

local function SplitSlot(bag, slot, amount)
	if C_Container and C_Container.SplitContainerItem then
		C_Container.SplitContainerItem(bag, slot, amount)
	else
		SplitContainerItem(bag, slot, amount)
	end
end

-- a zsak tipusa es szabad helyei: bagType 0 = normal zsak, egyeb = specialis
-- (herb, enchant, gem, mining, soul, quiver, ammo pouch...) -- bitmaszk
local function FreeSlots(bag)
	local free, bagType
	if C_Container and C_Container.GetContainerNumFreeSlots then
		free, bagType = C_Container.GetContainerNumFreeSlots(bag)
	else
		free, bagType = GetContainerNumFreeSlots(bag)
	end
	return free or 0, bagType or 0
end

local function BagType(bag)
	local _, bagType = FreeSlots(bag)
	return bagType
end

----------------------------------------------------------------
-- Beallitasok (account szintu SavedVariables)
----------------------------------------------------------------

local DEFAULTS = {
	mode = "bag", cols = 10, scale = 1,
	autoSell = false, sortAfterSell = true, sellReport = true,
	autoRepair = false, repairGuild = true,
	lowWarn = true, lowThreshold = 3,
	bgAlpha = 0.9,
	sortMode = "fill",          -- fill | type | typeslot
	sellUnusable = false,       -- nem hasznalhato soulbound felszereles eladasa
	sellWorse = false,          -- minden statban rosszabb soulbound felszereles eladasa
	keepUncollected = true,     -- ...kiveve, ha a kinezete meg nincs osszegyujtve
	tintUnusable = true, newGlow = true,
	tipCounts = false, tipAlts = false,
}

-- kesobb definialt fuggvenyek (az opcios nezethez)
local RefreshOptions, OpenOptions, RefreshAllBagViews
local MODES = {"bag", "all", "box"}
local MODE_LABEL = {bag = "Bag", all = "All", box = "Box"}
local MODE_DESC = {
	bag = "backpack only",
	all = "all bags, separate windows",
	box = "all bags in one window",
}

local function DB()
	return ZBagToolsDB or DEFAULTS
end

local function Mode()
	local m = DB().mode
	if m ~= "bag" and m ~= "all" and m ~= "box" then
		m = "bag"
	end
	return m
end

local function NextMode(m)
	for i, v in ipairs(MODES) do
		if v == m then
			return MODES[i % #MODES + 1]
		end
	end
	return "bag"
end

-- penz kiirasa arany/ezust/rez ikonokkal (chatben es a Box ablakban is)
local function FormatMoney(m)
	local g = math.floor(m / 10000)
	local s = math.floor((m % 10000) / 100)
	local c = m % 100
	local gi = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
	local si = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t"
	local ci = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t"
	if g > 0 then
		return string.format("%d%s %d%s %d%s", g, gi, s, si, c, ci)
	elseif s > 0 then
		return string.format("%d%s %d%s", s, si, c, ci)
	end
	return string.format("%d%s", c, ci)
end

----------------------------------------------------------------
-- Karakter-azonosito, vedett (rogzitett) slotok
-- A vedett slot karakterenkent tarolodik (bag:slot). A benne levo itemet
-- a Sort nem mozgatja, az eladas nem adja el; ures vedett slotba sem
-- rak semmit a Sort. Ki/be: Alt+jobb klikk a sloton.
----------------------------------------------------------------

local function CharKey()
	return (GetRealmName() or "?") .. "-" .. (UnitName("player") or "?")
end

local function Pins()
	if not ZBagToolsDB then
		return {}
	end
	ZBagToolsDB.pins = ZBagToolsDB.pins or {}
	local k = CharKey()
	ZBagToolsDB.pins[k] = ZBagToolsDB.pins[k] or {}
	return ZBagToolsDB.pins[k]
end

local function IsPinned(bag, slot)
	return Pins()[bag .. ":" .. slot] and true or false
end

----------------------------------------------------------------
-- Tooltip-olvasas (rejtett tooltip): soulbound, BoE, piros sorok.
-- Slotonkent cache-eljuk; a zsak valtozasakor, szintlepeskor es
-- uj fegyverismeretnel uritjuk.
--  red      = barmi piros a tooltipben (szint, kaszt, pancel/fegyvertipus...)
--  classRed = kaszt / faj / pancel- vagy fegyvertipus miatt nem hasznalhato
--             (a "Requires Level" NEM ide tartozik: az atmeneti)
----------------------------------------------------------------

local scanTip = CreateFrame("GameTooltip", "ZBagToolsScanTip", nil, "GameTooltipTemplate")
local scanCache = {}

local TXT_SOULBOUND = ITEM_SOULBOUND or "Soulbound"
local TXT_BOE = ITEM_BIND_ON_EQUIP or "Binds when equipped"
local TXT_CLASSES = (ITEM_CLASSES_ALLOWED or "Classes: %s"):gsub("%%s", "")
local TXT_RACES = (ITEM_RACES_ALLOWED or "Races: %s"):gsub("%%s", "")
local TXT_USE = ITEM_SPELL_TRIGGER_ONUSE or "Use:"
local TXT_PROC = ITEM_SPELL_TRIGGER_ONPROC or "Chance on hit:"
local TXT_EQUIP = ITEM_SPELL_TRIGGER_ONEQUIP or "Equip:"

local function IsRedText(fs)
	local r, g, b = fs:GetTextColor()
	return r and r > 0.95 and g < 0.2 and b < 0.2
end

local function ClearScanCache(bag)
	if bag == nil then
		scanCache = {}
		return
	end
	local prefix = bag .. ":"
	for k in pairs(scanCache) do
		if k:sub(1, #prefix) == prefix then
			scanCache[k] = nil
		end
	end
end

local function ScanSlot(bag, slot)
	local link = GetLink(bag, slot)
	if not link then
		return nil
	end
	local key = bag .. ":" .. slot
	local c = scanCache[key]
	if c and c.link == link then
		return c
	end
	local info = {link = link, soulbound = false, boe = false, red = false, classRed = false}
	-- a felszereles helyenek neve (pl. "One-Hand", "Chest"): ha ez piros,
	-- a fegyvert / pancelt nem tudod hasznalni (nincs hozza ismereted)
	local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
	local slotName = equipLoc and equipLoc ~= "" and _G[equipLoc]
	scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
	scanTip:ClearLines()
	scanTip:SetBagItem(bag, slot)
	for i = 2, scanTip:NumLines() do
		local l = _G["ZBagToolsScanTipTextLeft" .. i]
		local r = _G["ZBagToolsScanTipTextRight" .. i]
		local lt = l and l:GetText()
		if lt then
			if lt == TXT_SOULBOUND then
				info.soulbound = true
			elseif lt == TXT_BOE then
				info.boe = true
			end
			-- kulonleges hatas: Use: / Chance on hit: / set bonusz, vagy olyan
			-- Equip: sor, ami nem sima stat ("... by 20." / "... per 5 sec.")
			if lt:sub(1, #TXT_USE) == TXT_USE or lt:sub(1, #TXT_PROC) == TXT_PROC
				or lt:sub(1, 4) == "Set:" or lt:find("%(%d+/%d+%)$") then
				info.special = true
			elseif lt:sub(1, #TXT_EQUIP) == TXT_EQUIP then
				if not (lt:find(" by %d+%.?$") or lt:find("per 5 sec%.?$")) then
					info.special = true
				end
			end
			if lt:find("haven't collected this appearance", 1, true) then
				info.uncollected = true
			end
			if IsRedText(l) then
				info.red = true
				if lt:sub(1, #TXT_CLASSES) == TXT_CLASSES or lt:sub(1, #TXT_RACES) == TXT_RACES
					or (slotName and lt == slotName) then
					info.classRed = true
				end
			end
		end
		-- a jobb oldali piros szoveg a pancel-/fegyvertipus (pl. "Plate", "Polearm");
		-- fegyvereknel a bal oldali hely-nev lehet piros (pl. "One-Hand"), azt fent nezzuk
		if r and r:IsShown() and r:GetText() and IsRedText(r) then
			info.red = true
			info.classRed = true
		end
	end
	scanTip:Hide()
	local _, _, locked = GetContainerItemInfo(bag, slot)
	if not locked then
		scanCache[key] = info   -- mozgatas kozben (zarolt slot) nem taroljuk
	end
	return info
end

----------------------------------------------------------------
-- Keszlet: itemID -> darabszam. A sajat zsakokat mindig, a bankot csak
-- nyitott bankablaknal lehet olvasni (utana a legutobbi allapot marad).
-- Karakterenkent tarolva (account szintu SavedVariables), a tooltip
-- darabszamhoz es az alt karakterekhez.
----------------------------------------------------------------

local BANK_BAGS = {-1, 5, 6, 7, 8, 9, 10, 11}
local bankOpen = false

local function ScanContainers(list)
	local t = {}
	for _, bag in ipairs(list) do
		for slot = 1, (NumSlots(bag) or 0) do
			local id, count = SlotInfo(bag, slot)
			if id then
				t[id] = (t[id] or 0) + (count or 1)
			end
		end
	end
	return t
end

local function CharData()
	ZBagToolsDB.chars = ZBagToolsDB.chars or {}
	local k = CharKey()
	ZBagToolsDB.chars[k] = ZBagToolsDB.chars[k] or {}
	return ZBagToolsDB.chars[k]
end

local function SaveBags()
	if ZBagToolsDB then
		CharData().bags = ScanContainers(BAGS)
	end
end

local function SaveBank()
	if ZBagToolsDB and bankOpen then
		CharData().bank = ScanContainers(BANK_BAGS)
	end
end

----------------------------------------------------------------
-- Uj itemek: ami a legutobbi zsaknyitas ota kerult be. Itemenkent a
-- darabszamot nezzuk (igy a Sort mozgatasa nem szamit ujnak). Amikor
-- minden zsak bezarul, vagy az egeret egy item fole viszed, "lattuk".
----------------------------------------------------------------

local seenCounts = nil
local nowCounts, nowStamp = {}, nil

local function CurrentCounts()
	local t = GetTime()
	if nowStamp ~= t then
		nowCounts = ScanContainers(BAGS)
		nowStamp = t
	end
	return nowCounts
end

local function MarkAllSeen()
	nowStamp = nil
	seenCounts = CurrentCounts()
end

local function MarkSeen(id)
	if seenCounts and id then
		seenCounts[id] = CurrentCounts()[id] or 0
	end
end

local function IsNewItem(id)
	if not seenCounts or not id then
		return false
	end
	return (CurrentCounts()[id] or 0) > (seenCounts[id] or 0)
end

----------------------------------------------------------------
-- Kereses a nevben + szuro gombok a kereso mellett:
--  resource : szakma-alapanyag (Trade Goods: herb, erc, szovet, bor,
--             elemental, enchant anyag, hus... + nyers gem)
--  boe      : Bind on Equip (lehetseges aukcios hazi aru)
----------------------------------------------------------------

local RESOURCE_TYPES = {["Trade Goods"] = true, ["Gem"] = true}

local function MatchesSearch(text, bag, slot, link, name)
	return name and name:lower():find(text, 1, true) and true or false
end

local function MatchesFilter(filter, bag, slot, link)
	if filter == "resource" then
		local _, _, _, _, _, itemType = GetItemInfo(link)
		return itemType and RESOURCE_TYPES[itemType] or false
	elseif filter == "boe" then
		local info = ScanSlot(bag, slot)
		return info and info.boe and not info.soulbound or false
	end
	return true
end

----------------------------------------------------------------
-- Gombok diszitese (Box ablak es a gyari zsakablakok is):
-- vedett slot jel, piros a nem hasznalhato item, feny az uj itemen
----------------------------------------------------------------

local function DecorateButton(b, bag, slot)
	if not b or not b.GetName or not b:GetName() then
		return
	end
	if not b.zbPin then
		-- ugyanaz a lakat, mint a ZBar-ban: a Dungeon Finder (sotetszurke)
		-- lakatja aranyra szinezve, es ugyanez a kep meg ketszer ADD modban
		-- rarakva, hogy fenyes legyen (magaban szinte lathatatlan)
		local lock = {}
		for i = 1, 3 do
			local t = b:CreateTexture(nil, "OVERLAY")
			t:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-LOCK")
			t:SetTexCoord(0, 0.71875, 0, 0.875)
			t:SetWidth(12)
			t:SetHeight(14)
			t:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
			t:SetVertexColor(1, 0.82, 0)
			if i > 1 then
				t:SetBlendMode("ADD")
			end
			t:Hide()
			lock[i] = t
		end
		b.zbPin = {
			Show = function() for _, t in ipairs(lock) do t:Show() end end,
			Hide = function() for _, t in ipairs(lock) do t:Hide() end end,
		}
		local g = b:CreateTexture(nil, "OVERLAY")
		g:SetTexture("Interface\\Buttons\\CheckButtonHilight")
		g:SetBlendMode("ADD")
		g:SetAllPoints(b)
		g:Hide()
		b.zbGlow = g
	end

	if IsPinned(bag, slot) then b.zbPin:Show() else b.zbPin:Hide() end

	local link = GetLink(bag, slot)
	local icon = _G[b:GetName() .. "IconTexture"]
	if not link then
		b.zbGlow:Hide()
		return
	end
	-- a zarolast ugyanonnan olvassuk, mint a gyari szurkites (SetItemButtonDesaturated);
	-- a Grimfall C_Container zarolas-adata kesve frissul, emiatt maradt feher
	local _, _, locked = GetContainerItemInfo(bag, slot)
	if icon and not locked then
		local info = DB().tintUnusable and ScanSlot(bag, slot)
		if info and info.red then
			icon:SetVertexColor(1, 0.3, 0.3)
		else
			icon:SetVertexColor(1, 1, 1)
		end
	end
	if DB().newGlow and IsNewItem(ParseItemID(link)) then
		b.zbGlow:Show()
	else
		b.zbGlow:Hide()
	end
end

----------------------------------------------------------------
-- "Minden statban rosszabb", mint ami rajtad van ugyanazon a helyen.
-- GetItemStats: elsodleges/masodlagos statok, pancel, DPS, socketek.
-- Rosszabb = egyik statban sem jobb, es legalabb egyben rosszabb.
-- Ket helyre veheto itemnel (gyuru, trinket, egykezes fegyver) mindket
-- felvett darabnal rosszabbnak kell lennie; ha valamelyik hely ures, vagy
-- nem osszevetheto (pl. ketkezes van rajtad), megtartjuk.
----------------------------------------------------------------

local EQUIP_SLOTS = {
	INVTYPE_HEAD = {1}, INVTYPE_NECK = {2}, INVTYPE_SHOULDER = {3},
	INVTYPE_CHEST = {5}, INVTYPE_ROBE = {5}, INVTYPE_WAIST = {6},
	INVTYPE_LEGS = {7}, INVTYPE_FEET = {8}, INVTYPE_WRIST = {9},
	INVTYPE_HAND = {10}, INVTYPE_FINGER = {11, 12}, INVTYPE_TRINKET = {13, 14},
	INVTYPE_CLOAK = {15}, INVTYPE_2HWEAPON = {16}, INVTYPE_WEAPONMAINHAND = {16},
	INVTYPE_SHIELD = {17}, INVTYPE_WEAPONOFFHAND = {17}, INVTYPE_HOLDABLE = {17},
	INVTYPE_RANGED = {18}, INVTYPE_RANGEDRIGHT = {18}, INVTYPE_THROWN = {18},
	INVTYPE_RELIC = {18},
	INVTYPE_WEAPON = {16, 17},
}

local ONEHAND_OK = {INVTYPE_WEAPON = true, INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true}

local function StatsWorse(cand, eq)
	if not cand or not eq then
		return false
	end
	local worse = false
	for k, v in pairs(cand) do
		if v > (eq[k] or 0) then
			return false
		elseif v < (eq[k] or 0) then
			worse = true
		end
	end
	for k, v in pairs(eq) do
		if cand[k] == nil and v > 0 then
			worse = true
		end
	end
	return worse
end

local function IsWorseThanEquipped(link, equipLoc)
	local slots = EQUIP_SLOTS[equipLoc or ""]
	if not slots or not GetItemStats then
		return false
	end
	local cand = GetItemStats(link)
	if not cand then
		return false
	end
	for _, invSlot in ipairs(slots) do
		local eqLink = GetInventoryItemLink("player", invSlot)
		if not eqLink then
			return false                   -- ures hely: megtartjuk
		end
		local _, _, _, _, _, _, _, _, eqLoc = GetItemInfo(eqLink)
		if equipLoc == "INVTYPE_WEAPON" and not ONEHAND_OK[eqLoc or ""] then
			return false                   -- ketkezes / pajzs van ott: nem osszevetheto
		end
		if equipLoc == "INVTYPE_2HWEAPON" and eqLoc ~= "INVTYPE_2HWEAPON" then
			return false
		end
		if not StatsWorse(cand, GetItemStats(eqLink)) then
			return false
		end
	end
	return true
end

----------------------------------------------------------------
-- Sell Grey (+ opcionalisan a nem hasznalhato / elavult soulbound felszereles)
----------------------------------------------------------------

local function IsGrey(link, quality)
	if quality == 0 then
		return true
	end
	if link then
		-- a link szine "|cffXXXXXX" alakban all a nev elott; szurke = 9d9d9d
		local color = link:match("|cff(%x%x%x%x%x%x)")
		if color and color:lower() == "9d9d9d" then
			return true
		end
	end
	return false
end

-- kereskedonel vagyunk-e: a MERCHANT_SHOW / MERCHANT_CLOSED esemeny allitja
local atMerchant = false

-- visszaadja az eladott slotok listajat (a Sort ezek eltuneset varja meg)
-- auto = true: automatikus eladas, ilyenkor nem szol, ha nincs mit eladni
local function SellGrey(auto)
	if not (atMerchant or (MerchantFrame and MerchantFrame:IsShown())) then
		if not auto then
			p("Only usable at a vendor (open the merchant window first).")
		end
		return {}
	end
	local soldSlots = {}
	local earned = 0
	local greys, unusable, worse = 0, 0, 0
	local sellUnusable = DB().sellUnusable
	local sellWorse = DB().sellWorse
	for _, bag in ipairs(BAGS) do
		local slots = NumSlots(bag)
		for slot = 1, slots do
			local link = GetLink(bag, slot)
			if link and not IsPinned(bag, slot) then
				local sell = false
				if IsGrey(link, nil) then
					sell = true
					greys = greys + 1
				elseif sellUnusable or sellWorse then
					local _, _, _, _, _, _, _, _, equipLoc, _, price = GetItemInfo(link)
					if equipLoc and equipLoc ~= "" and price and price > 0 then
						local info = ScanSlot(bag, slot)
						if info and info.soulbound then
							if sellUnusable and info.classRed then
								-- kaszt / pancel- vagy fegyvertipus miatt nem hasznalhato
								-- (szintigeny miatt nem adjuk el)
								sell = true
								unusable = unusable + 1
							elseif sellWorse and not info.special and not info.red
								and not (info.uncollected and DB().keepUncollected)
								and IsWorseThanEquipped(link, equipLoc) then
								sell = true
								worse = worse + 1
							end
						end
					end
				end
				if sell then
					local _, count = SlotInfo(bag, slot)
					local price = select(11, GetItemInfo(link)) or 0
					earned = earned + price * (count or 1)
					UseSlot(bag, slot)
					table.insert(soldSlots, {bag = bag, slot = slot, link = link})
				end
			end
		end
	end
	if #soldSlots > 0 then
		local parts = {}
		if greys > 0 then table.insert(parts, greys .. " grey item(s)") end
		if unusable > 0 then table.insert(parts, unusable .. " unusable item(s)") end
		if worse > 0 then table.insert(parts, worse .. " outdated item(s)") end
		local msg = (auto and "Auto-sold " or "Sold ") .. table.concat(parts, " and ")
		if DB().sellReport and earned > 0 then
			msg = msg .. " for " .. FormatMoney(earned)
		end
		p(msg .. ".")
	elseif not auto then
		p("Nothing to sell in your bags.")
	end
	return soldSlots
end

----------------------------------------------------------------
-- Rendezes segedfuggvenyek
----------------------------------------------------------------

-- befer-e az item egy adott tipusu zsakba?
local function ItemFitsBag(link, bagType)
	if bagType == 0 then
		return true
	end
	if not link then
		return false
	end
	-- a zsak-itemek a sajat tipusukat adjak vissza family-kent,
	-- de specialis zsakba nem tehetok -> kizarjuk oket
	local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
	if equipLoc == "INVTYPE_BAG" or equipLoc == "INVTYPE_QUIVER" then
		return false
	end
	local family = GetItemFamily(link)
	if not family or family == 0 then
		return false
	end
	return bit.band(family, bagType) ~= 0
end

-- pillanatkep az osszes slotrol, a rendezesi sorrendben:
-- zsakok jobbrol balra (0 = Backpack, 1..4), zsakon belul slot 1 (bal felso)
-- -> utolso slot (jobb also)
local function Snapshot()
	local list = {}
	for _, bag in ipairs(BAGS) do
		local n = NumSlots(bag) or 0
		local bagType = BagType(bag)
		for slot = 1, n do
			local itemID, count, locked, link = SlotInfo(bag, slot)
			table.insert(list, {
				bag = bag, slot = slot, bagType = bagType,
				link = link, itemID = itemID, count = count,
				locked = locked and true or false,
				pinned = IsPinned(bag, slot),
			})
		end
	end
	return list
end

-- van-e folyamatban levo mozgatas (zarolt slot) vagy item a kurzoron?
local function BagsBusy()
	if CursorHasItem() then
		return true
	end
	for _, bag in ipairs(BAGS) do
		local n = NumSlots(bag) or 0
		for slot = 1, n do
			local _, _, locked = SlotInfo(bag, slot)
			if locked then
				return true
			end
		end
	end
	return false
end

-- egy mozgatas: src -> dst. amount megadasa eseten csak annyit viszunk at
-- (stack-reszlet), igy nem marad semmi a kurzoron. Ha a cel visszadobja
-- (pl. nem illik a specialis zsakba), a ClearCursor visszateszi a helyere.
local function MoveItem(src, dst, amount)
	if amount then
		SplitSlot(src.bag, src.slot, amount)
	else
		PickupSlot(src.bag, src.slot)
	end
	if CursorHasItem() then
		PickupSlot(dst.bag, dst.slot)
	end
	if CursorHasItem() then
		ClearCursor()
		return false
	end
	return true
end

----------------------------------------------------------------
-- 1. fazis: reszleges stack-ek osszevonasa
-- Itemenkent a stack-eket ebben a sorrendben vesszuk: elobb a specialis
-- zsakban levok (oda gyujtjuk az anyagot), utana a normal zsakokban levok,
-- mindketto a rendezesi sorrendben. A lista vegerol toltjuk az elejet.
-- Egy korben minden slot csak egyszer szerepel (a szerver zarolja a
-- mozgatott slotokat), a maradekot a kovetkezo kor intezi.
----------------------------------------------------------------

local function CombineStacks()
	local list = Snapshot()
	local buckets = {}
	for _, s in ipairs(list) do
		if s.itemID and s.count and not s.locked and not s.pinned then
			local _, _, _, _, _, _, _, maxStack = GetItemInfo(s.itemID)
			if maxStack and maxStack > 1 and s.count < maxStack then
				s.maxStack = maxStack
				buckets[s.itemID] = buckets[s.itemID] or {}
				table.insert(buckets[s.itemID], s)
			end
		end
	end

	local merges = 0
	for _, stacks in pairs(buckets) do
		local special, normal = {}, {}
		for _, st in ipairs(stacks) do
			table.insert(st.bagType ~= 0 and special or normal, st)
		end
		for _, st in ipairs(normal) do
			table.insert(special, st)
		end
		stacks = special
		local i, j = 1, #stacks
		while i < j do
			local dst, src = stacks[i], stacks[j]
			local space = dst.maxStack - dst.count
			if src.count <= space then
				MoveItem(src, dst)          -- az egesz stack atfer
			else
				MoveItem(src, dst, space)   -- csak annyi, amennyi befer
			end
			merges = merges + 1
			i = i + 1
			j = j - 1
		end
	end
	return merges
end

----------------------------------------------------------------
-- 2. fazis: specialis itemek a helyukre
-- A normal zsakokban levo itemek kozul, amelyik befer egy specialis
-- zsak ures slotjaba (herb -> herb bag, soul shard -> soul bag, nyil ->
-- quiver stb.), azt atrakjuk oda. Hatulrol elore haladunk.
----------------------------------------------------------------

local function MoveSpecialItems()
	local list = Snapshot()
	local holes = {}
	for _, s in ipairs(list) do
		if s.bagType ~= 0 and not s.link and not s.locked and not s.pinned then
			table.insert(holes, s)
		end
	end
	if #holes == 0 then
		return 0
	end

	local moves = 0
	for k = #list, 1, -1 do
		local s = list[k]
		if s.bagType == 0 and s.link and not s.locked and not s.pinned then
			for _, hole in ipairs(holes) do
				if not hole.used and ItemFitsBag(s.link, hole.bagType) then
					MoveItem(s, hole)
					hole.used = true
					moves = moves + 1
					break
				end
			end
		end
	end
	return moves
end

----------------------------------------------------------------
-- 3. fazis: lyukak betoltese ket mutatoval
-- elol:  az elso ures slot
-- hatul: az utolso item
-- Az utolso itemet az elso lyukba tesszuk, amig a ket mutato ossze nem er.
--  * specialis zsak lyukaba csak odaillo item kerul (hatulrol keresve)
--  * specialis zsakban levo itemet nem viszunk ki normal zsakba
-- Zarolt slotokat atugorjuk. Egy korben egy slot csak egyszer szerepel.
----------------------------------------------------------------

local function CompactBags()
	local list = Snapshot()
	local used = {}
	local moves = 0
	local back = #list
	local normalDone = false

	for front = 1, #list do
		local hole = list[front]
		if not hole.link and not hole.locked and not hole.pinned and not used[front] then
			local k
			if hole.bagType == 0 then
				if not normalDone then
					k = back
					while k > front do
						local s = list[k]
						if not used[k] and s.link and not s.locked and not s.pinned and s.bagType == 0 then
							break
						end
						k = k - 1
					end
					if k > front then
						back = k - 1
					else
						k = nil
						normalDone = true   -- a mutatok osszeertek
					end
				end
			else
				k = #list
				while k > front do
					local s = list[k]
					if not used[k] and s.link and not s.locked and not s.pinned and ItemFitsBag(s.link, hole.bagType) then
						break
					end
					k = k - 1
				end
				if k <= front then
					k = nil
				end
			end

			if k then
				MoveItem(list[k], hole)
				used[k] = true
				used[front] = true
				moves = moves + 1
			end
		end
	end
	return moves
end

----------------------------------------------------------------
-- Sort = 1. osszevonas + 2. specialis itemek + 3. lyukak, TOBB KORBEN.
-- Minden kor elott megvarjuk, hogy a szerver visszaigazolja az elozo
-- kor mozgatasait (nincs zarolt slot, ures a kurzor).
----------------------------------------------------------------

----------------------------------------------------------------
-- 3/b. fazis (Sort mod: "type" / "typeslot"): valodi rendezes.
-- Zsak-csoportonkent (normal zsakok egyutt, specialis zsakok tipusonkent
-- kulon) kiszamoljuk a kivant sorrendet, es cserekkel odarakjuk az
-- itemeket; az ures helyek a csoport vegere kerulnek. Vedett slot nem
-- vesz reszt. Egy korben egy slot csak egyszer szerepel.
--  type     : tipus -> altipus -> minoseg (jobb elore) -> nev
--  typeslot : tipus -> felszereles-hely (pl. a mellvertek egymas mellett)
--             -> altipus -> minoseg -> nev
----------------------------------------------------------------

local TYPE_ORDER = {
	["Consumable"] = 1, ["Reagent"] = 2, ["Trade Goods"] = 3, ["Gem"] = 4,
	["Glyph"] = 5, ["Recipe"] = 6, ["Weapon"] = 7, ["Armor"] = 8,
	["Projectile"] = 9, ["Quiver"] = 10, ["Container"] = 11, ["Quest"] = 12,
	["Key"] = 13, ["Miscellaneous"] = 14,
}

local EQUIP_ORDER = {
	INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3, INVTYPE_CLOAK = 4,
	INVTYPE_CHEST = 5, INVTYPE_ROBE = 5, INVTYPE_BODY = 6, INVTYPE_TABARD = 7,
	INVTYPE_WRIST = 8, INVTYPE_HAND = 9, INVTYPE_WAIST = 10, INVTYPE_LEGS = 11,
	INVTYPE_FEET = 12, INVTYPE_FINGER = 13, INVTYPE_TRINKET = 14,
	INVTYPE_WEAPON = 15, INVTYPE_2HWEAPON = 16, INVTYPE_WEAPONMAINHAND = 17,
	INVTYPE_WEAPONOFFHAND = 18, INVTYPE_SHIELD = 19, INVTYPE_HOLDABLE = 20,
	INVTYPE_RANGED = 21, INVTYPE_RANGEDRIGHT = 21, INVTYPE_THROWN = 22,
	INVTYPE_RELIC = 23,
}

local function SortKey(s, mode)
	local name, _, quality, _, _, itemType, subType, _, equipLoc = GetItemInfo(s.link)
	return {
		TYPE_ORDER[itemType or ""] or 50,
		mode == "typeslot" and (EQUIP_ORDER[equipLoc or ""] or 99) or 0,
		subType or "",
		-(quality or 0),
		name or "",
		-(s.count or 1),
		s.link,
	}
end

local function KeyLess(a, b)
	for i = 1, #a do
		if a[i] ~= b[i] then
			return a[i] < b[i]
		end
	end
	return false
end

local function SameItem(a, b)
	return a and b and a.link and b.link and a.link == b.link and a.count == b.count
end

local function ArrangeBags(mode)
	local list = Snapshot()
	local groups, order = {}, {}
	for _, s in ipairs(list) do
		if not s.pinned then
			local g = groups[s.bagType]
			if not g then
				g = {pos = {}, items = {}, busy = false}
				groups[s.bagType] = g
				table.insert(order, g)
			end
			table.insert(g.pos, s)
			if s.locked then
				g.busy = true
			end
			if s.link then
				s.key = SortKey(s, mode)
				table.insert(g.items, s)
			end
		end
	end

	local moves = 0
	for _, g in ipairs(order) do
		if not g.busy then
			table.sort(g.items, function(a, b) return KeyLess(a.key, b.key) end)
			local used = {}
			for i, dst in ipairs(g.pos) do
				local want = g.items[i]
				if want and not used[i] and not SameItem(dst, want) then
					for j, src in ipairs(g.pos) do
						if j ~= i and not used[j] and SameItem(src, want) and not SameItem(src, g.items[j]) then
							-- csere (vagy mozgatas ures helyre)
							PickupSlot(src.bag, src.slot)
							if CursorHasItem() then
								PickupSlot(dst.bag, dst.slot)
							end
							if CursorHasItem() then
								ClearCursor()
							end
							used[i] = true
							used[j] = true
							moves = moves + 1
							break
						end
					end
				end
			end
		end
	end
	return moves
end

local SORT_MAX_PASSES = 10
local ARRANGE_MAX_PASSES = 40
local SORT_TICK = 0.1
local SORT_TIMEOUT = 5

local sortRunner = CreateFrame("Frame")
local sortState = {running = false}

local function SortStop(msg)
	sortState.running = false
	sortRunner:SetScript("OnUpdate", nil)
	if msg then
		p(msg)
	end
end

local function SortStep()
	if sortState.phase == "merge" then
		local n = CombineStacks()
		sortState.totalMerges = sortState.totalMerges + n
		sortState.passes = sortState.passes + 1
		if n == 0 or sortState.passes >= SORT_MAX_PASSES then
			sortState.phase = "special"
			sortState.passes = 0
		end
	elseif sortState.phase == "special" then
		local n = MoveSpecialItems()
		sortState.totalSpecial = sortState.totalSpecial + n
		sortState.passes = sortState.passes + 1
		if n == 0 or sortState.passes >= SORT_MAX_PASSES then
			local m = DB().sortMode
			sortState.phase = (m == "type" or m == "typeslot") and "arrange" or "compact"
			sortState.passes = 0
		end
	else
		local arrange = sortState.phase == "arrange"
		local n = arrange and ArrangeBags(DB().sortMode) or CompactBags()
		sortState.totalMoves = sortState.totalMoves + n
		sortState.passes = sortState.passes + 1
		if n == 0 or sortState.passes >= (arrange and ARRANGE_MAX_PASSES or SORT_MAX_PASSES) then
			local changed = sortState.totalMerges + sortState.totalSpecial + sortState.totalMoves
			if sortState.quiet and changed == 0 then
				-- eladas utani auto Sort: ha nem tortent semmi, nem szolunk
				SortStop(nil)
			else
				SortStop(string.format("Done: %d stack merges, %d items moved to special bags, %d %s.",
					sortState.totalMerges, sortState.totalSpecial, sortState.totalMoves,
					arrange and "items rearranged" or "gaps filled"))
			end
		end
	end
end

-- quiet = true: eladas utani auto Sort (0 valtozasnal nem ir a chatbe)
local function StartSort(quiet)
	if CursorHasItem and CursorHasItem() then
		p("Put down the item on your cursor first.")
		return
	end
	if sortState.running then
		return
	end
	sortState.running = true
	sortState.quiet = quiet and true or false
	sortState.phase = "merge"
	sortState.passes = 0
	sortState.totalMerges = 0
	sortState.totalMoves = 0
	sortState.totalSpecial = 0
	sortState.elapsed = 0
	sortState.waited = 0

	sortRunner:SetScript("OnUpdate", function(self, elapsed)
		sortState.elapsed = sortState.elapsed + elapsed
		if sortState.elapsed < SORT_TICK then
			return
		end
		local dt = sortState.elapsed
		sortState.elapsed = 0
		if BagsBusy() then
			sortState.waited = sortState.waited + dt
			if sortState.waited > SORT_TIMEOUT then
				ClearCursor()
				SortStop("Stopped: the server did not confirm the item moves in time. Try /zsort again.")
			end
			return
		end
		sortState.waited = 0
		SortStep()
	end)
end

-- normal Sort (gomb, /zsort): mindig kiirja az eredmenyt
local function SortBags()
	StartSort(false)
end

----------------------------------------------------------------
-- Kozos zsak (Box mod): egyetlen ablak az 5 zsak osszes slotjaval,
-- a Sort sorrendjeben (Backpack, majd 1-4. zsak, slotonkent).
-- Az item gombok a gyari ContainerFrameItemButtonTemplate-et hasznaljak,
-- a szulo keret ID-je a zsak szama, a gombe a slot szama -> a kattintas,
-- hasznalat, huzas, tooltip, eladas, split mind gyarilag mukodik.
----------------------------------------------------------------

local SLOT_SIZE = 37
local SLOT_GAP = 4
local PAD = 8
local GRID_TOP_WIDE = 36     -- egysoros fejlec: cim + gombsor + kereso + Options + X
local GRID_TOP_NARROW = 62   -- keskeny ablak: a kereso a gombsor alatt, kulon sorban
local HEADER_WIDE_MIN = 420  -- ennyi szelessegtol fer el minden egy sorban (10 oszlop)
local FOOTER = 38
local MIN_WIDTH = 320
local OPT_WIDTH = 600
local OPT_TOP = 32      -- opcios nezetben nincs gombsor/kereso, feljebb kezdodik
local OPT_HEIGHT = OPT_TOP + 414 + FOOTER

local combined = CreateFrame("Frame", "ZBagToolsCombined", UIParent)
combined:Hide()
combined:SetFrameStrata("HIGH")
combined:SetToplevel(true)
combined:SetClampedToScreen(true)
combined:EnableMouse(true)
combined:SetMovable(true)
combined:RegisterForDrag("LeftButton")
-- tomor (egyszinu) hatter: a gyari DialogBox hatter maga is attetszo, igy
-- 100%-on sem takart rendesen. Az atlatszosagot a BackdropColor alfaja adja.
combined:SetBackdrop({
	bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = false, edgeSize = 16,
	insets = {left = 4, right = 4, top = 4, bottom = 4},
})
local BG_R, BG_G, BG_B = 0.06, 0.06, 0.06
combined:SetBackdropColor(BG_R, BG_G, BG_B, 0.9)
combined:SetWidth(MIN_WIDTH)
combined:SetHeight(200)
tinsert(UISpecialFrames, "ZBagToolsCombined")   -- Esc bezarja

combined:SetScript("OnDragStart", combined.StartMoving)
combined:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, relPoint, x, y = self:GetPoint()
	if ZBagToolsDB then
		ZBagToolsDB.point = {point, relPoint, x, y}
	end
end)

local function RestorePosition()
	combined:ClearAllPoints()
	local pt = ZBagToolsDB and ZBagToolsDB.point
	if pt then
		combined:SetPoint(pt[1], UIParent, pt[2], pt[3], pt[4])
	else
		combined:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -60, 100)
	end
	combined:SetScale(DB().scale or 1)
	combined:SetBackdropColor(BG_R, BG_G, BG_B, DB().bgAlpha or 0.9)
end

local title = combined:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("LEFT", combined, "TOPLEFT", 12, -18)
title:SetText("ZBag")

local closeBtn = CreateFrame("Button", "ZBagToolsCombinedClose", combined, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", combined, "TOPRIGHT", -2, -2)
closeBtn:SetScript("OnClick", function() combined:Hide() end)   -- kesobb: CloseAll

local freeText = combined:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
local moneyText = combined:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
moneyText:SetPoint("BOTTOMRIGHT", combined, "BOTTOMRIGHT", -12, 14)

local holders = {}      -- zsakonkent egy lathatatlan szulo, ID = zsak szama
local buttons = {}      -- buttons[bag][slot]
local searchText = ""
local activeFilter = nil   -- nil | "resource" | "boe"
local hoverBag = nil    -- a tasksor egy ikonja felett: csak az a zsak latszik elesen

for _, bag in ipairs(BAGS) do
	local h = CreateFrame("Frame", "ZBagToolsHolder" .. bag, combined)
	h:SetID(bag)
	h:SetAllPoints(combined)
	h.zbHolder = true
	holders[bag] = h
	buttons[bag] = {}
end

local function GetButton(bag, slot)
	local b = buttons[bag][slot]
	if not b then
		b = CreateFrame("Button", "ZBagToolsItem" .. bag .. "_" .. slot, holders[bag], "ContainerFrameItemButtonTemplate")
		b:SetID(slot)
		local border = b:CreateTexture(nil, "OVERLAY")
		border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
		border:SetBlendMode("ADD")
		border:SetWidth(SLOT_SIZE * 1.8)
		border:SetHeight(SLOT_SIZE * 1.8)
		border:SetPoint("CENTER", b, "CENTER", 0, 0)
		border:Hide()
		b.zbBorder = border
		buttons[bag][slot] = b
	end
	return b
end

local function UpdateButton(b, bag, slot)
	local texture, count, locked, quality = GetContainerItemInfo(bag, slot)
	local link = GetLink(bag, slot)
	local name

	if texture then
		SetItemButtonTexture(b, texture)
		SetItemButtonCount(b, count)
		SetItemButtonDesaturated(b, locked, 0.5, 0.5, 0.5)
		local itemName, _, q = GetItemInfo(link or "")
		name = itemName
		if (not quality or quality < 0) and q then
			quality = q
		end
	else
		SetItemButtonTexture(b, "Interface\\PaperDoll\\UI-Backpack-EmptySlot")
		SetItemButtonCount(b, 0)
		SetItemButtonDesaturated(b, false)
		quality = nil
	end

	if quality and quality >= 2 and GetItemQualityColor then
		local r, g, bl = GetItemQualityColor(quality)
		b.zbBorder:SetVertexColor(r, g, bl, 0.7)
		b.zbBorder:Show()
	else
		b.zbBorder:Hide()
	end

	local cd = _G[b:GetName() .. "Cooldown"]
	if cd and texture then
		local start, duration, enable = GetContainerItemCooldown(bag, slot)
		CooldownFrame_SetTimer(cd, start, duration, enable)
	elseif cd then
		cd:Hide()
	end

	-- kereses / tasksor-hover: ami nem illik, elhalvanyul
	local alpha = 1
	if hoverBag and hoverBag ~= bag then
		alpha = 0.25
	else
		if searchText ~= "" and not (link and MatchesSearch(searchText, bag, slot, link, name)) then
			alpha = 0.25
		end
		if activeFilter and not (link and MatchesFilter(activeFilter, bag, slot, link)) then
			alpha = 0.25
		end
	end
	b:SetAlpha(alpha)

	-- vedett slot jel, piros (nem hasznalhato), feny (uj item)
	DecorateButton(b, bag, slot)

	-- Ha az egér épp ezen a gombon áll (pl. most tettél ide egy itemet),
	-- a tooltipet újra rákötjük, különben nem kap új OnEnter-t, és a Shift
	-- összehasonlítás csak akkor jönne, ha elviszed és visszahozod az egeret.
	if GetMouseFocus and GetMouseFocus() == b and b:IsVisible() then
		if texture and not CursorHasItem() then
			ContainerFrameItemButton_OnEnter(b)
		elseif GameTooltip:IsOwned(b) then
			GameTooltip:Hide()
		end
	end
end

-- tasksor: az 1-4. zsak helye (csere: ra kell huzni a zsakot / felvenni)
local bagBar = {}
local BAGBAR_SIZE = 24

local function UpdateBagBar()
	for bag = 1, 4 do
		local bb = bagBar[bag]
		local invID = ContainerIDToInventoryID(bag)
		local tex = GetInventoryItemTexture("player", invID)
		bb.icon:SetTexture(tex or "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag")
	end
end

for bag = 1, 4 do
	local bb = CreateFrame("Button", "ZBagToolsBagSlot" .. bag, combined)
	bb:SetWidth(BAGBAR_SIZE)
	bb:SetHeight(BAGBAR_SIZE)
	-- a gyari tasksor sorrendje: balrol jobbra 4., 3., 2., 1. zsak
	bb:SetPoint("BOTTOMLEFT", combined, "BOTTOMLEFT", PAD + 2 + (4 - bag) * (BAGBAR_SIZE + 2), PAD + 2)
	bb.icon = bb:CreateTexture(nil, "ARTWORK")
	bb.icon:SetAllPoints(bb)
	bb:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	bb:RegisterForClicks("LeftButtonUp")
	bb:RegisterForDrag("LeftButton")
	local function invID() return ContainerIDToInventoryID(bag) end
	bb:SetScript("OnClick", function()
		if CursorHasItem() then
			PutItemInBag(invID())
		else
			PickupBagFromSlot(invID())
		end
	end)
	bb:SetScript("OnReceiveDrag", function() PutItemInBag(invID()) end)
	bb:SetScript("OnDragStart", function() PickupBagFromSlot(invID()) end)
	bb:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		if not GameTooltip:SetInventoryItem("player", invID()) then
			GameTooltip:SetText("Empty bag slot")
		end
		GameTooltip:Show()
		hoverBag = bag
		if combined.Refresh then combined.Refresh() end
	end)
	bb:SetScript("OnLeave", function()
		GameTooltip:Hide()
		hoverBag = nil
		if combined.Refresh then combined.Refresh() end
	end)
	bagBar[bag] = bb
end
freeText:SetPoint("LEFT", bagBar[1], "RIGHT", 8, 0)

local lastSizes = {}

-- a fejlec elrendezese a szelesseg alapjan (kesobb definialjuk, amikor
-- a gombsor, a kereso es az Options gomb mar letezik); a racs tetejet adja
local ApplyHeader

local function Layout()
	local cols = DB().cols or DEFAULTS.cols
	local width = math.max(MIN_WIDTH, PAD * 2 + cols * SLOT_SIZE + (cols - 1) * SLOT_GAP)
	local gridTop = ApplyHeader and ApplyHeader(width) or GRID_TOP_NARROW
	local index = 0
	for _, bag in ipairs(BAGS) do
		local n = NumSlots(bag) or 0
		lastSizes[bag] = n
		for slot = 1, n do
			local b = GetButton(bag, slot)
			local col = index % cols
			local row = math.floor(index / cols)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", combined, "TOPLEFT", PAD + col * (SLOT_SIZE + SLOT_GAP), -gridTop - row * (SLOT_SIZE + SLOT_GAP))
			b:Show()
			index = index + 1
		end
		for slot = n + 1, #buttons[bag] do
			buttons[bag][slot]:Hide()
		end
	end
	local rows = math.max(1, math.ceil(index / cols))
	if combined.optionsMode then
		combined:SetWidth(math.max(width, OPT_WIDTH))
		combined:SetHeight(OPT_HEIGHT)
	else
		combined:SetWidth(width)
		combined:SetHeight(gridTop + rows * SLOT_SIZE + (rows - 1) * SLOT_GAP + FOOTER)
	end
end

local function SizesChanged()
	for _, bag in ipairs(BAGS) do
		if (NumSlots(bag) or 0) ~= lastSizes[bag] then
			return true
		end
	end
	return false
end

----------------------------------------------------------------
-- Szabad hely / teli zsak jelzes
-- Csak a normal zsakok szabad helyei szamitanak (a specialis zsakba nem
-- fer barmi); a specialis szabad helyek zarojelben latszanak.
-- Ha keves a hely: a szamlalo es a tasksor ikonjai (a gyari Backpack ikon
-- is) pirosra valtanak, es egyszer szol a chatben, amikor ala esik.
----------------------------------------------------------------

local lowState = nil

local function CheckLowSpace(fromEvent)
	local free, total, special = 0, 0, 0
	for _, bag in ipairs(BAGS) do
		local n = NumSlots(bag) or 0
		local f, bagType = FreeSlots(bag)
		if bagType == 0 then
			free = free + f
			total = total + n
		else
			special = special + f
		end
	end
	local low = DB().lowWarn and free <= (DB().lowThreshold or 3) and total > 0

	local text = string.format("Free: %d / %d", free, total)
	if special > 0 then
		text = text .. string.format(" (+%d)", special)
	end
	freeText:SetText(text)
	if low then
		freeText:SetTextColor(1, 0.25, 0.25)
	else
		freeText:SetTextColor(1, 1, 1)
	end
	local r, g, b = 1, 1, 1
	if low then
		r, g, b = 1, 0.35, 0.35
	end
	for bag = 1, 4 do
		bagBar[bag].icon:SetVertexColor(r, g, b)
	end
	if MainMenuBarBackpackButtonIconTexture then
		MainMenuBarBackpackButtonIconTexture:SetVertexColor(r, g, b)
	end

	if fromEvent then
		if low and lowState == false then
			p("Bags almost full: " .. free .. " free slot(s) left.")
		end
		lowState = low
	end
end

local function RefreshCombined()
	if not combined:IsShown() then
		return
	end
	if SizesChanged() then
		Layout()
	end
	if not combined.optionsMode then
		for _, bag in ipairs(BAGS) do
			local n = NumSlots(bag) or 0
			for slot = 1, n do
				UpdateButton(buttons[bag][slot], bag, slot)
			end
		end
	end
	moneyText:SetText(FormatMoney(GetMoney()))
	UpdateBagBar()
	CheckLowSpace(false)
end

-- teli zsak figyeles: Box ablaktol fuggetlenul, kepkockankent egyszer
local lowCheckPending = false
local lowChecker = CreateFrame("Frame")
local function RequestLowCheck()
	if lowCheckPending then
		return
	end
	lowCheckPending = true
	lowChecker:SetScript("OnUpdate", function(self)
		self:SetScript("OnUpdate", nil)
		lowCheckPending = false
		CheckLowSpace(true)
		SaveBags()
	end)
end
combined.Refresh = RefreshCombined

-- esemenyek osszevonasa: egy kepkockan belul csak egyszer frissitunk
local refreshPending = false
local refresher = CreateFrame("Frame")
local function RequestRefresh()
	if refreshPending or not combined:IsShown() then
		return
	end
	refreshPending = true
	refresher:SetScript("OnUpdate", function(self)
		self:SetScript("OnUpdate", nil)
		refreshPending = false
		RefreshCombined()
	end)
end

combined:SetScript("OnShow", function()
	Layout()
	RefreshCombined()
end)
combined:SetScript("OnHide", function()
	hoverBag = nil
	if combined.optionsMode and combined.SetOptionsView then
		combined.SetOptionsView(false)
	end
	if ZBagToolsSearch then
		ZBagToolsSearch:ClearFocus()
	end
end)

----------------------------------------------------------------
-- Zsakok nyitasa / zarasa a mod szerint
-- A gyari fuggvenyeket lecsereljuk; a gyari valtozat belul maga is hivja
-- a ToggleBackpack/ToggleBag-et, ezert amikor mi hivjuk a gyarit,
-- "atengedo" modban vagyunk, es a csereink a gyarit hivjak tovabb.
----------------------------------------------------------------

local orig = {
	ToggleBackpack = ToggleBackpack,
	OpenBackpack = OpenBackpack,
	CloseBackpack = CloseBackpack,
	OpenAllBags = OpenAllBags,
	CloseAllBags = CloseAllBags,
}
local passthrough = 0

local function CallOrig(name, ...)
	local fn = orig[name]
	if not fn then return end
	passthrough = passthrough + 1
	local ok, err = pcall(fn, ...)
	passthrough = passthrough - 1
	if not ok then
		geterrorhandler()(err)
	end
end

local function AnyBagOpen()
	for _, bag in ipairs(BAGS) do
		if IsBagOpen(bag) then
			return true
		end
	end
	return false
end

-- minden zsak bezarasa (kulon ablakok + kozos ablak)
-- A kulon zsakablakok bezarasa. A gyari CloseBackpack NEM zarja be a
-- Backpack-et, ha az OpenBackpack korabban "mar nyitva volt"-nak jelolte
-- (backpackWasOpen) -- ez kereskedonel / mod-valtasnal konnyen bennragad.
-- Ezert a gyari zaras utan a 0-4. zsakot mutato ablakokat kezzel is
-- bezarjuk, a jelolest torolve. (Bank- es kulcszsak ablakokhoz nem nyulunk.)
local function CloseSeparateBags()
	CallOrig("CloseAllBags")
	for i = 1, (NUM_CONTAINER_FRAMES or 13) do
		local cf = _G["ContainerFrame" .. i]
		if cf and cf:IsShown() then
			local id = cf:GetID()
			if id and id >= 0 and id <= 4 then
				cf.backpackWasOpen = nil
				cf:Hide()
			end
		end
	end
end

local function CloseAll()
	combined:Hide()
	CloseSeparateBags()
end

-- az aktualis mod nezetenek megnyitasa (nem valt, csak nyit)
local function OpenModeView()
	local m = Mode()
	if m == "bag" then
		combined:Hide()
		CallOrig("OpenBackpack")
	elseif m == "all" then
		combined:Hide()
		CallOrig("OpenAllBags", true)
	else
		CloseSeparateBags()
		combined:Show()
	end
end

-- B billentyu: az aktualis mod nezetet nyitja/zarja
local function ToggleModeView()
	local m = Mode()
	if m == "bag" then
		combined:Hide()
		CallOrig("ToggleBackpack")
	elseif m == "all" then
		if AnyBagOpen() then
			CloseAll()
		else
			OpenModeView()
		end
	else
		if combined:IsShown() then
			combined:Hide()
		else
			OpenModeView()
		end
	end
end

ToggleBackpack = function(...)
	if passthrough > 0 then return orig.ToggleBackpack(...) end
	ToggleModeView()
end

OpenBackpack = function(...)
	if passthrough > 0 then return orig.OpenBackpack(...) end
	OpenModeView()
end

CloseBackpack = function(...)
	if passthrough > 0 then return orig.CloseBackpack(...) end
	if Mode() == "bag" then
		combined:Hide()
		CallOrig("CloseBackpack", ...)
	else
		-- All/Box modban az automatikus nyitas mindent nyitott -> mindent zarunk
		CloseAll()
	end
end

OpenAllBags = function(forceOpen, ...)
	if passthrough > 0 then return orig.OpenAllBags(forceOpen, ...) end
	if forceOpen then
		-- automatikus nyitas (kereskedo, posta, bank): a mod nezete
		OpenModeView()
	else
		-- Shift+B: a gyari "minden zsak kulon" viselkedes
		combined:Hide()
		CallOrig("OpenAllBags")
	end
end

CloseAllBags = function(...)
	if passthrough > 0 then return orig.CloseAllBags(...) end
	CloseAll()
end

----------------------------------------------------------------
-- Eladas + utana Sort (csak ha tenyleg kelt el valami)
-- A Sort-ot csak akkor inditjuk, amikor az eladott itemek mar eltuntek
-- a zsakbol (a szerver visszaigazolta), vagy max. 3 mp utan.
----------------------------------------------------------------

local SELL_SORT_TIMEOUT = 3
local AUTOSELL_DELAY = 0.3

local afterSell = CreateFrame("Frame")

local function SoldItemsGone(soldSlots)
	for _, s in ipairs(soldSlots) do
		if GetLink(s.bag, s.slot) == s.link then
			return false
		end
	end
	return true
end

local function SellAndSort(auto)
	local soldSlots = SellGrey(auto)
	if #soldSlots == 0 or not DB().sortAfterSell then
		return
	end
	local waited = 0
	afterSell:SetScript("OnUpdate", function(self, elapsed)
		waited = waited + elapsed
		if waited < 0.2 then
			return
		end
		if SoldItemsGone(soldSlots) or waited > SELL_SORT_TIMEOUT then
			self:SetScript("OnUpdate", nil)
			StartSort(true)
		end
	end)
end

----------------------------------------------------------------
-- Auto javitas kereskedonel
-- Ha be van allitva, elobb a guild bankbol probal fizetni; ha az nem
-- sikerult (nincs jog / keret / penz), sajat penzbol javit.
----------------------------------------------------------------

local repairCheck = CreateFrame("Frame")

local function RepairOwn(cost)
	if GetMoney() >= cost then
		RepairAllItems()
		p("Repaired for " .. FormatMoney(cost) .. ".")
	else
		p("Not enough money to repair (" .. FormatMoney(cost) .. " needed).")
	end
end

local function AutoRepair()
	if not DB().autoRepair then
		return
	end
	if not (CanMerchantRepair and CanMerchantRepair()) then
		return
	end
	local cost, canRepair = GetRepairAllCost()
	if not canRepair or not cost or cost <= 0 then
		return
	end
	local useGuild = DB().repairGuild and IsInGuild and IsInGuild()
		and CanGuildBankRepair and CanGuildBankRepair()
	if not useGuild then
		RepairOwn(cost)
		return
	end
	RepairAllItems(1)
	local waited = 0
	repairCheck:SetScript("OnUpdate", function(self, elapsed)
		waited = waited + elapsed
		if waited < 0.5 then
			return
		end
		self:SetScript("OnUpdate", nil)
		if not atMerchant then
			return
		end
		local left = GetRepairAllCost()
		if left and left > 0 then
			RepairOwn(left)
		else
			p("Repaired for " .. FormatMoney(cost) .. " (guild bank).")
		end
	end)
end

-- auto eladas kereskedo nyitasakor, kis kesleltetessel
local autoSellTimer = CreateFrame("Frame")
local function ScheduleAutoSell()
	if not DB().autoSell then
		return
	end
	local waited = 0
	autoSellTimer:SetScript("OnUpdate", function(self, elapsed)
		waited = waited + elapsed
		if waited >= AUTOSELL_DELAY then
			self:SetScript("OnUpdate", nil)
			if atMerchant then
				SellAndSort(true)
			end
		end
	end)
end

----------------------------------------------------------------
-- Gombsor: Sell | Sort | Bag/All/Box | X
-- Ket helyen van: a Backpack ablakban es a kozos ablak fejleceben.
----------------------------------------------------------------

local modeButtons = {}
local sellButtons = {}

-- A Sell gomb mindig kattinthato (jobb klikk = auto ki/be), de kereskedon
-- kivul szurkenek latszik es a bal klikkre nem reagal.
-- Auto modban zold keretet kap.
local function UpdateSellButtons()
	local auto = DB().autoSell
	for _, b in ipairs(sellButtons) do
		local fs = b:GetFontString()
		local tex = b:GetNormalTexture()
		if atMerchant then
			if fs then fs:SetTextColor(1, 0.82, 0) end
			if tex then tex:SetDesaturated(false) end
		else
			if fs then fs:SetTextColor(0.5, 0.5, 0.5) end
			if tex then tex:SetDesaturated(true) end
		end
		if auto then
			b.zbAutoFrame:Show()
		else
			b.zbAutoFrame:Hide()
		end
	end
end

local function SellTooltip(self)
	local auto = DB().autoSell
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText("Sell grey items")
	if auto then
		GameTooltip:AddLine("Auto sell: ON - greys are sold when you open a vendor", 0.2, 1, 0.2, true)
	else
		GameTooltip:AddLine("Auto sell: OFF", 1, 1, 1)
	end
	if DB().autoRepair then
		GameTooltip:AddLine("Auto repair: ON" .. (DB().repairGuild and " (guild bank first)" or ""), 0.2, 1, 0.2, true)
	else
		GameTooltip:AddLine("Auto repair: OFF", 1, 1, 1)
	end
	if atMerchant then
		GameTooltip:AddLine("Left-click: sell now (then Sort)", 0.6, 0.8, 1)
	else
		GameTooltip:AddLine("Left-click: only at a vendor", 0.6, 0.6, 0.6)
	end
	GameTooltip:AddLine("Right-click: toggle auto sell", 0.6, 0.8, 1)
	GameTooltip:Show()
end

local function SetAutoSell(on)
	if ZBagToolsDB then
		ZBagToolsDB.autoSell = on and true or false
	end
	UpdateSellButtons()
	if RefreshOptions then
		RefreshOptions()
	end
end

local function SellClick(self, button)
	if button == "RightButton" then
		SetAutoSell(not DB().autoSell)
		p("Auto sell " .. (DB().autoSell and "ON" or "OFF") .. ".")
		if GameTooltip:IsOwned(self) then
			SellTooltip(self)
		end
	elseif atMerchant then
		SellAndSort(false)
	end
end

local function UpdateModeButtons()
	local m = Mode()
	for _, b in ipairs(modeButtons) do
		b:SetText(MODE_LABEL[m])
	end
end

local function ModeTooltip(self)
	local m = Mode()
	local n = NextMode(m)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText("Bag mode: " .. MODE_LABEL[m])
	GameTooltip:AddLine(MODE_DESC[m], 1, 1, 1)
	GameTooltip:AddLine("Click: switch to " .. MODE_LABEL[n] .. " (" .. MODE_DESC[n] .. ")", 0.6, 0.8, 1)
	GameTooltip:AddLine("B opens the current mode, Shift+B opens all bags separately.", 0.7, 0.7, 0.7, true)
	GameTooltip:Show()
end

local function SetMode(m)
	if ZBagToolsDB then
		ZBagToolsDB.mode = m
	end
	UpdateModeButtons()
end

local function CycleMode(self)
	SetMode(NextMode(Mode()))
	CloseAll()
	OpenModeView()
	if self and self:IsVisible() and GameTooltip:IsOwned(self) then
		ModeTooltip(self)
	end
end

-- cim + opcionalis tovabbi sorok (roviden tartva, hogy ne legyen hosszu csik)
local function SimpleTooltip(btn, text, ...)
	local lines = {...}
	btn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(text)
		for _, l in ipairs(lines) do
			GameTooltip:AddLine(l, 1, 1, 1)
		end
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", GameTooltip_Hide)
end

local function CreateToolbar(name, parent, withGear)
	local bar = CreateFrame("Frame", name, parent)
	bar:SetWidth(140)
	bar:SetHeight(20)

	local sell = CreateFrame("Button", name .. "Sell", bar, "UIPanelButtonTemplate")
	sell:SetWidth(38)
	sell:SetHeight(20)
	sell:SetText("Sell")
	sell:SetPoint("LEFT", bar, "LEFT", 0, 0)
	sell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	sell:SetScript("OnClick", SellClick)
	sell:SetScript("OnEnter", SellTooltip)
	sell:SetScript("OnLeave", GameTooltip_Hide)
	-- zold keret auto modhoz
	local af = CreateFrame("Frame", nil, sell)
	af:SetPoint("TOPLEFT", sell, "TOPLEFT", -3, 3)
	af:SetPoint("BOTTOMRIGHT", sell, "BOTTOMRIGHT", 3, -3)
	af:SetBackdrop({edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10})
	af:SetBackdropBorderColor(0.1, 1, 0.1, 1)
	af:SetFrameLevel(sell:GetFrameLevel() + 2)
	af:Hide()
	sell.zbAutoFrame = af
	table.insert(sellButtons, sell)

	local sort = CreateFrame("Button", name .. "Sort", bar, "UIPanelButtonTemplate")
	sort:SetWidth(38)
	sort:SetHeight(20)
	sort:SetText("Sort")
	sort:SetPoint("LEFT", sell, "RIGHT", 2, 0)
	sort:SetScript("OnClick", SortBags)
	SimpleTooltip(sort, "Sort bags",
		"1. Merge partial stacks",
		"2. Move herbs, shards, ammo... into their bags",
		"3. Fill gaps or sort by type (see Options)")

	local mode = CreateFrame("Button", name .. "Mode", bar, "UIPanelButtonTemplate")
	mode:SetWidth(38)
	mode:SetHeight(20)
	mode:SetPoint("LEFT", sort, "RIGHT", 2, 0)
	mode:SetScript("OnClick", CycleMode)
	mode:SetScript("OnEnter", ModeTooltip)
	mode:SetScript("OnLeave", GameTooltip_Hide)
	table.insert(modeButtons, mode)

	-- a sor vegen a fogaskerek (opciok) -- a Box ablakban nem kell, ott az
	-- Options gomb van; a mindent bezaro X a jobb felso sarokba kerult
	if withGear then
		local gear = CreateFrame("Button", name .. "Gear", bar)
		gear:SetWidth(18)
		gear:SetHeight(18)
		gear:SetPoint("LEFT", mode, "RIGHT", 2, 0)
		-- a jatek sajat arany fogaskerek kurzora (INTERACT_CURSOR), gyari fajl
		gear:SetNormalTexture("Interface\\Cursor\\Interact")
		gear:SetHighlightTexture("Interface\\Cursor\\Interact", "ADD")
		gear:SetScript("OnClick", function()
			if OpenOptions then OpenOptions() end
		end)
		SimpleTooltip(gear, "ZBagTools options")
	else
		bar:SetWidth(118)
	end

	return bar
end

-- Backpack ablak gombsora. A gyari kliens nem mindig a ContainerFrame1-et
-- adja a Backpack-nek (ha elobb egy masik zsakot nyitsz, az kapja), ezert
-- mindig ahhoz az ablakhoz tesszuk, amelyik eppen a Backpack-et (ID 0) mutatja.
local bpBar = CreateToolbar("ZBagToolsFrame", ContainerFrame1, true)
bpBar:Hide()

-- A Backpack ablak jobb felso sarkaban a gyari X helyen a SAJAT bezaro
-- gombunk all (ugyanolyan kinezet), ami minden zsakot bezar. A gyari X-et
-- elrejtjuk; az 1-4. zsak ablakain a gyari X marad (egyenkenti bezaras).
local bpClose = CreateFrame("Button", "ZBagToolsBackpackClose", bpBar, "UIPanelCloseButton")
bpClose:SetScript("OnClick", function() CloseAll() end)
bpClose:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText("Close all bags")
	GameTooltip:Show()
end)
bpClose:SetScript("OnLeave", GameTooltip_Hide)
bpClose:Hide()

local function AttachBackpackBar(frame)
	bpBar:SetParent(frame)
	bpBar:ClearAllPoints()
	bpBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 47, -28)
	bpBar:SetFrameLevel(frame:GetFrameLevel() + 5)
	bpBar:Show()

	local closeX = _G[frame:GetName() .. "CloseButton"]
	bpClose:ClearAllPoints()
	if closeX then
		closeX:Hide()
		bpClose:SetPoint("CENTER", closeX, "CENTER", 0, 0)
		bpClose:Show()
	else
		bpClose:Hide()
	end
end

hooksecurefunc("ContainerFrame_GenerateFrame", function(frame, size, id)
	if id == 0 then
		AttachBackpackBar(frame)
	else
		-- ugyanaz az ablak kesobb mas zsakot is mutathat: ott kell a gyari X
		local closeX = _G[frame:GetName() .. "CloseButton"]
		if closeX then
			closeX:Show()
		end
		if bpBar:GetParent() == frame then
			bpBar:Hide()
		end
	end
end)

-- a kozos ablak fejlece: gombsor + kereso
local boxBar = CreateToolbar("ZBagToolsBoxBar", combined)

local search = CreateFrame("EditBox", "ZBagToolsSearch", combined, "InputBoxTemplate")
search:SetAutoFocus(false)
search:SetHeight(20)
search:SetScript("OnTextChanged", function(self)
	searchText = (self:GetText() or ""):lower()
	RequestRefresh()
end)
search:SetScript("OnEscapePressed", function(self)
	self:SetText("")
	self:ClearFocus()
end)
search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
search:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText("Search items by name")
	GameTooltip:Show()
end)
search:SetScript("OnLeave", GameTooltip_Hide)

----------------------------------------------------------------
-- Opcios nezet: a Box ablakban az item racs helyen jelenik meg.
-- "Options" gomb a fejlecben (Box nezetben), "<- Back" vissza a mentett
-- mod nezetere. Mashonnan: fogaskerek a Backpack ablakban, vagy /zbag.
----------------------------------------------------------------

local optBtn = CreateFrame("Button", "ZBagToolsOptionsButton", combined, "UIPanelButtonTemplate")
optBtn:SetWidth(70)
optBtn:SetHeight(20)
optBtn:SetPoint("RIGHT", closeBtn, "LEFT", 2, 0)
-- a jobb felso X mindent bezar (Box + kulon zsakok), mint a Backpack X-e
closeBtn:SetScript("OnClick", function() CloseAll() end)
optBtn:SetText("Options")

-- Szuro gombok a kereso mellett (ki/be kapcsolhato, egyszerre egy aktiv):
--  Resource (erc ikon): szakma-alapanyagok   BOE (erme ikon): Bind on Equip
local filterButtons = {}

local function UpdateFilterButtons()
	for key, fb in pairs(filterButtons) do
		if activeFilter == key then
			fb:LockHighlight()
			fb.zbBorder:Show()
		else
			fb:UnlockHighlight()
			fb.zbBorder:Hide()
		end
	end
end

local function CreateFilterButton(key, icon, title, line)
	local fb = CreateFrame("Button", "ZBagToolsFilter_" .. key, combined)
	fb:SetWidth(20)
	fb:SetHeight(20)
	fb:SetNormalTexture(icon)
	fb:GetNormalTexture():SetTexCoord(0.08, 0.92, 0.08, 0.92)
	fb:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	local border = fb:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	border:SetBlendMode("ADD")
	border:SetAllPoints(fb)
	border:Hide()
	fb.zbBorder = border
	fb:SetScript("OnClick", function()
		activeFilter = (activeFilter ~= key) and key or nil
		UpdateFilterButtons()
		RequestRefresh()
	end)
	fb:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(title)
		GameTooltip:AddLine(line, 1, 1, 1)
		GameTooltip:AddLine("Click to toggle the filter", 0.6, 0.8, 1)
		GameTooltip:Show()
	end)
	fb:SetScript("OnLeave", GameTooltip_Hide)
	filterButtons[key] = fb
	return fb
end

local resBtn = CreateFilterButton("resource", "Interface\\Icons\\INV_Ore_Copper_01",
	"Resource", "Profession materials: herbs, ore, cloth, leather, gems...")
local boeBtn = CreateFilterButton("boe", "Interface\\Icons\\INV_Misc_Coin_02",
	"BOE", "Bind on Equip items (possible Auction House goods)")

-- Fejlec: ha eleg szeles az ablak, minden egy sorban; ha nem, a kereso
-- (es a szuro gombok) a gombsor ala kerulnek, teljes szelessegben.
ApplyHeader = function(width)
	boxBar:ClearAllPoints()
	boxBar:SetPoint("LEFT", title, "RIGHT", 10, 0)
	search:ClearAllPoints()
	boeBtn:ClearAllPoints()
	resBtn:ClearAllPoints()
	if width >= HEADER_WIDE_MIN then
		boeBtn:SetPoint("RIGHT", optBtn, "LEFT", -6, 0)
		resBtn:SetPoint("RIGHT", boeBtn, "LEFT", -3, 0)
		search:SetPoint("LEFT", boxBar, "RIGHT", 12, 0)
		search:SetPoint("RIGHT", resBtn, "LEFT", -6, 0)
		return GRID_TOP_WIDE
	end
	boeBtn:SetPoint("TOPRIGHT", combined, "TOPRIGHT", -PAD - 4, -34)
	resBtn:SetPoint("RIGHT", boeBtn, "LEFT", -3, 0)
	search:SetPoint("TOPLEFT", combined, "TOPLEFT", PAD + 8, -34)
	search:SetPoint("BOTTOMRIGHT", resBtn, "BOTTOMLEFT", -6, 0)
	return GRID_TOP_NARROW
end

local opt = CreateFrame("Frame", "ZBagToolsOptions", combined)
opt:SetPoint("TOPLEFT", combined, "TOPLEFT", PAD + 4, -OPT_TOP)
opt:SetPoint("BOTTOMRIGHT", combined, "BOTTOMRIGHT", -PAD - 4, FOOTER)
opt:Hide()

local optWidgets = {}
local optX = 0          -- az aktualis oszlop bal szele (ket oszlopos elrendezes)
local OPT_COL2 = 305

local function OptHeader(text, y)
	local fs = opt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("TOPLEFT", opt, "TOPLEFT", optX, y)
	fs:SetText(text)
end

local function OptNote(text, y)
	local fs = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("TOPLEFT", opt, "TOPLEFT", optX, y)
	fs:SetJustifyH("LEFT")
	fs:SetText(text)
end

local function OptCheck(key, label, y, indent, onChange)
	local name = "ZBagToolsOpt_" .. key
	local cb = CreateFrame("CheckButton", name, opt, "OptionsCheckButtonTemplate")
	cb:SetPoint("TOPLEFT", opt, "TOPLEFT", optX + (indent or 0), y)
	_G[name .. "Text"]:SetText(label)
	cb:SetScript("OnClick", function(self)
		ZBagToolsDB[key] = self:GetChecked() and true or false
		if onChange then onChange() end
	end)
	cb.zbKey = key
	table.insert(optWidgets, cb)
	return cb
end

-- valasztogomb: ugyanahhoz a kulcshoz tobb ertek, mindig egy van bejelolve
local function OptRadio(key, value, label, y, onChange)
	local name = "ZBagToolsOpt_" .. key .. "_" .. value
	local cb = CreateFrame("CheckButton", name, opt, "OptionsCheckButtonTemplate")
	cb:SetPoint("TOPLEFT", opt, "TOPLEFT", optX, y)
	_G[name .. "Text"]:SetText(label)
	cb:SetScript("OnClick", function()
		ZBagToolsDB[key] = value
		RefreshOptions()
		if onChange then onChange() end
	end)
	cb.zbKey = key
	cb.zbRadio = value
	table.insert(optWidgets, cb)
	return cb
end

-- toUI/fromUI: atvaltas a tarolt ertek es a csuszka erteke kozott (pl. scale %)
local function OptSlider(key, y, minV, maxV, step, fmt, toUI, fromUI, onChange)
	local name = "ZBagToolsOpt_" .. key
	local sl = CreateFrame("Slider", name, opt, "OptionsSliderTemplate")
	sl:SetPoint("TOPLEFT", opt, "TOPLEFT", optX + 6, y)
	sl:SetWidth(220)
	sl:SetMinMaxValues(minV, maxV)
	sl:SetValueStep(step)
	local lim = fmt:find("%%%%") and "%d%%" or "%d"
	_G[name .. "Low"]:SetText(string.format(lim, minV))
	_G[name .. "High"]:SetText(string.format(lim, maxV))
	sl:SetScript("OnValueChanged", function(self, value)
		value = math.floor(value / step + 0.5) * step
		_G[name .. "Text"]:SetText(string.format(fmt, value))
		if self.zbUpdating then return end
		ZBagToolsDB[key] = fromUI and fromUI(value) or value
		if onChange then onChange() end
	end)
	sl.zbKey = key
	sl.zbToUI = toUI
	sl.zbFmt = fmt
	sl.zbName = name
	sl.zbIsSlider = true
	table.insert(optWidgets, sl)
	return sl
end

RefreshOptions = function()
	if not opt:IsShown() then
		return
	end
	local db = DB()
	for _, w in ipairs(optWidgets) do
		if w.zbIsSlider then
			local v = db[w.zbKey]
			if w.zbToUI then v = w.zbToUI(v) end
			w.zbUpdating = true
			w:SetValue(v)
			w.zbUpdating = false
			_G[w.zbName .. "Text"]:SetText(string.format(w.zbFmt, v))
		elseif w.zbRadio then
			w:SetChecked(db[w.zbKey] == w.zbRadio)
		else
			w:SetChecked(db[w.zbKey] and true or false)
		end
	end
end

local function RefreshDecor()
	RefreshAllBagViews()
end

-------- bal oszlop --------
optX = 0

OptHeader("Vendor", 0)
OptCheck("autoSell", "Auto sell grey items at vendors", -16, 0, UpdateSellButtons)
OptCheck("sortAfterSell", "Sort bags after selling", -40)
OptCheck("sellReport", "Show earnings in chat", -64)
OptCheck("sellUnusable", "Also sell unusable soulbound gear", -88)
OptCheck("sellWorse", "Also sell gear worse than equipped", -112)
OptCheck("keepUncollected", "Keep if appearance not collected", -136, 20)
OptCheck("autoRepair", "Auto repair at vendors", -160)
OptCheck("repairGuild", "Use guild bank funds first (experimental)", -184, 20)

OptHeader("Sort", -218)
OptRadio("sortMode", "fill", "Fill gaps only", -234)
OptRadio("sortMode", "type", "Fill gaps + sort by type", -258)
OptRadio("sortMode", "typeslot", "Sort by type + group same slot", -282)

OptHeader("Bag space", -316)
OptCheck("lowWarn", "Warn when bags are almost full", -332, 0, function() CheckLowSpace(false) end)
OptSlider("lowThreshold", -376, 1, 20, 1, "Warn at %d free slots or less", nil, nil, function() CheckLowSpace(false) end)

-------- jobb oszlop --------
optX = OPT_COL2

OptHeader("Bag display", 0)
OptCheck("tintUnusable", "Tint unusable items red", -16, 0, RefreshDecor)
OptCheck("newGlow", "Highlight new items", -40, 0, RefreshDecor)

OptHeader("Tooltip", -74)
OptCheck("tipCounts", "Show item counts (bags, bank)", -90)
OptCheck("tipAlts", "Include alt characters", -114, 20)

OptHeader("Box window", -148)
OptSlider("cols", -182, 4, 24, 1, "Columns: %d", nil, nil, function() Layout() end)
OptSlider("scale", -224, 50, 200, 10, "Scale: %d%%",
	function(v) return math.floor((v or 1) * 100 + 0.5) end,
	function(v) return v / 100 end,
	function() combined:SetScale(DB().scale) end)
OptSlider("bgAlpha", -266, 20, 100, 5, "Background opacity: %d%%",
	function(v) return math.floor((v or 0.9) * 100 + 0.5) end,
	function(v) return v / 100 end,
	function() combined:SetBackdropColor(BG_R, BG_G, BG_B, DB().bgAlpha) end)

OptNote("Alt+Right-click a bag slot to pin it.", -330)

local resetBtn = CreateFrame("Button", "ZBagToolsOptReset", opt, "UIPanelButtonTemplate")
resetBtn:SetWidth(130)
resetBtn:SetHeight(20)
resetBtn:SetPoint("TOPLEFT", opt, "TOPLEFT", OPT_COL2 + 4, -298)
resetBtn:SetText("Reset window")
resetBtn:SetScript("OnClick", function()
	ZBagToolsDB.point = nil
	ZBagToolsDB.scale = 1
	ZBagToolsDB.cols = DEFAULTS.cols
	ZBagToolsDB.bgAlpha = DEFAULTS.bgAlpha
	RestorePosition()
	Layout()
	RefreshOptions()
end)
SimpleTooltip(resetBtn, "Reset window", "Position, scale, columns and opacity")

local function SetOptionsView(on)
	combined.optionsMode = on and true or false
	for _, h in pairs(holders) do
		if on then h:Hide() else h:Show() end
	end
	if on then
		search:Hide()
		boxBar:Hide()       -- a gyors gombsor itt felesleges
		resBtn:Hide()
		boeBtn:Hide()
		opt:Show()
		optBtn:SetText("<- Back")
		RefreshOptions()
	else
		search:Show()
		boxBar:Show()
		resBtn:Show()
		boeBtn:Show()
		opt:Hide()
		optBtn:SetText("Options")
	end
	Layout()
	RefreshCombined()
end
combined.SetOptionsView = SetOptionsView

optBtn:SetScript("OnClick", function()
	if combined.optionsMode then
		-- vissza a mentett mod nezetere
		if Mode() == "box" then
			CloseSeparateBags()   -- kulon zsakok ne maradjanak nyitva a Box mellett
			SetOptionsView(false)
		else
			combined:Hide()
			OpenModeView()
		end
	else
		SetOptionsView(true)
	end
end)

OpenOptions = function()
	-- a kulon zsakablakokat bezarjuk (pl. a fogaskereket a Backpack-bol
	-- nyomtad); a <- Back utana a mentett mod nezetet nyitja vissza
	CloseSeparateBags()
	if not combined:IsShown() then
		combined:Show()
	end
	SetOptionsView(true)
end

----------------------------------------------------------------
-- Gyari zsakablakok: ugyanaz a diszites (vedett jel, piros, feny)
----------------------------------------------------------------

local function UpdateOpenContainerFrames()
	for i = 1, (NUM_CONTAINER_FRAMES or 13) do
		local cf = _G["ContainerFrame" .. i]
		if cf and cf:IsShown() then
			local id = cf:GetID()
			if id and id >= 0 and id <= 4 then
				ContainerFrame_Update(cf)
			end
		end
	end
end

hooksecurefunc("ContainerFrame_Update", function(frame)
	local bag = frame:GetID()
	if not bag or bag < 0 or bag > 4 then
		return
	end
	local name = frame:GetName()
	for j = 1, (frame.size or NumSlots(bag) or 0) do
		local b = _G[name .. "Item" .. j]
		if b then
			DecorateButton(b, bag, b:GetID())
		end
	end
end)

RefreshAllBagViews = function()
	RequestRefresh()
	UpdateOpenContainerFrames()
end

-- Alt+jobb klikk egy sloton (gyari zsak es Box ablak is): vedett slot ki/be
hooksecurefunc("ContainerFrameItemButton_OnModifiedClick", function(self, button)
	if button ~= "RightButton" or not IsAltKeyDown() or IsShiftKeyDown() or IsControlKeyDown() then
		return
	end
	local parent = self:GetParent()
	local bag, slot = parent and parent:GetID(), self:GetID()
	if not bag or bag < 0 or bag > 4 or not ZBagToolsDB then
		return
	end
	local pins = Pins()
	local key = bag .. ":" .. slot
	if pins[key] then
		pins[key] = nil
		p("Slot unpinned.")
	else
		pins[key] = true
		p("Slot pinned: Sort won't move it and selling won't touch it. Alt+Right-click again to unpin.")
	end
	RefreshAllBagViews()
end)

-- ha az egeret egy uj item fole viszed, azt mar "lattad"
hooksecurefunc("ContainerFrameItemButton_OnEnter", function(self)
	local parent = self:GetParent()
	local bag = parent and parent:GetID()
	if not bag or bag < 0 or bag > 4 then
		return
	end
	local id = ParseItemID(GetLink(bag, self:GetID()))
	if id and IsNewItem(id) then
		MarkSeen(id)
		if self.zbGlow then self.zbGlow:Hide() end
		RefreshAllBagViews()
	end
end)

-- amikor minden zsak bezarult: minden item "latott"
local seenChecker = CreateFrame("Frame")
local function CheckAllClosed()
	seenChecker:SetScript("OnUpdate", function(self)
		self:SetScript("OnUpdate", nil)
		if not combined:IsShown() and not AnyBagOpen() then
			MarkAllSeen()
		end
	end)
end
hooksecurefunc("ContainerFrame_OnHide", CheckAllClosed)
combined:HookScript("OnHide", CheckAllClosed)

----------------------------------------------------------------
-- Tooltip: darabszam (zsak / bank / alt karakterek), vedett slot jelzes
----------------------------------------------------------------

local function IsBagItemButton(owner)
	local n = owner and owner.GetName and owner:GetName()
	return n and (n:find("^ContainerFrame%d+Item%d+$") or n:find("^ZBagToolsItem%d+_%d+$"))
end

local function AddTooltipInfo(tt)
	local _, link = tt:GetItem()
	local id = ParseItemID(link)
	if not id then
		return
	end
	local added = false

	local owner = tt:GetOwner()
	if IsBagItemButton(owner) then
		local bag = owner:GetParent() and owner:GetParent():GetID()
		if bag and bag >= 0 and bag <= 4 and IsPinned(bag, owner:GetID()) then
			tt:AddLine("ZBag: pinned slot (Alt+Right-click to unpin)", 0.4, 0.8, 1)
			added = true
		end
	end

	if DB().tipCounts and ZBagToolsDB and ZBagToolsDB.chars then
		local me = CharKey()
		local d = ZBagToolsDB.chars[me] or {}
		local bags = d.bags and d.bags[id] or 0
		local bank = d.bank and d.bank[id] or 0
		if bags > 0 then
			tt:AddDoubleLine("Bags:", bags, 0.5, 0.8, 1, 1, 1, 1)
			added = true
		end
		if bank > 0 then
			tt:AddDoubleLine("Bank:", bank, 0.5, 0.8, 1, 1, 1, 1)
			added = true
		end
		if DB().tipAlts then
			local realm = (GetRealmName() or "?") .. "-"
			for k, cd in pairs(ZBagToolsDB.chars) do
				if k ~= me and k:sub(1, #realm) == realm then
					local b = cd.bags and cd.bags[id] or 0
					local k2 = cd.bank and cd.bank[id] or 0
					if b + k2 > 0 then
						tt:AddDoubleLine(k:sub(#realm + 1) .. ":", string.format("%d bags, %d bank", b, k2), 0.5, 0.8, 1, 1, 1, 1)
						added = true
					end
				end
			end
		end
	end
	if added then
		tt:Show()
	end
end

GameTooltip:HookScript("OnTooltipSetItem", AddTooltipInfo)
if ItemRefTooltip then
	ItemRefTooltip:HookScript("OnTooltipSetItem", AddTooltipInfo)
end

-- bank mentese: a nyitott bankablak alatt minden valtozaskor (kovetkezo kepkockan)
local bankSaver = CreateFrame("Frame")
local function RequestBankSave()
	bankSaver:SetScript("OnUpdate", function(self)
		self:SetScript("OnUpdate", nil)
		SaveBank()
	end)
end

----------------------------------------------------------------
-- Esemenyek
----------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("BAG_UPDATE")
events:RegisterEvent("ITEM_LOCK_CHANGED")
events:RegisterEvent("BAG_UPDATE_COOLDOWN")
events:RegisterEvent("PLAYER_MONEY")
events:RegisterEvent("UNIT_INVENTORY_CHANGED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("MODIFIER_STATE_CHANGED")
events:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:RegisterEvent("SKILL_LINES_CHANGED")
-- kereskedo / bank / posta: a nyitast-zarast az esemenyek vezerlik,
-- igy nem fuggunk attol, melyik gyari nyito fuggvenyt hivja a kliens
events:RegisterEvent("MERCHANT_SHOW")
events:RegisterEvent("MERCHANT_CLOSED")
events:RegisterEvent("BANKFRAME_OPENED")
events:RegisterEvent("BANKFRAME_CLOSED")
events:RegisterEvent("MAIL_SHOW")
events:RegisterEvent("MAIL_CLOSED")
events:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= "ZBagTools" then return end
		ZBagToolsDB = ZBagToolsDB or {}
		for k, v in pairs(DEFAULTS) do
			if ZBagToolsDB[k] == nil then
				ZBagToolsDB[k] = v
			end
		end
		RestorePosition()
		UpdateModeButtons()
		UpdateSellButtons()
		self:UnregisterEvent("ADDON_LOADED")
	elseif event == "MERCHANT_SHOW" then
		atMerchant = true
		UpdateSellButtons()
		OpenModeView()
		AutoRepair()
		ScheduleAutoSell()
	elseif event == "MERCHANT_CLOSED" then
		if atMerchant then
			atMerchant = false
			UpdateSellButtons()
			CloseAll()
		end
	elseif event == "BANKFRAME_OPENED" then
		bankOpen = true
		RequestBankSave()
		OpenModeView()
	elseif event == "BANKFRAME_CLOSED" then
		bankOpen = false
		CloseAll()
	elseif event == "MAIL_SHOW" then
		OpenModeView()
	elseif event == "MAIL_CLOSED" then
		CloseAll()
	elseif event == "PLAYERBANKSLOTS_CHANGED" then
		RequestBankSave()
	elseif event == "PLAYER_LEVEL_UP" or event == "SKILL_LINES_CHANGED" then
		-- uj szint / fegyverismeret: ujra kell nezni, mi hasznalhato
		ClearScanCache()
		RefreshAllBagViews()
	elseif event == "MODIFIER_STATE_CHANGED" then
		-- Shift/Ctrl lenyomasakor a Box ablak gombja alatti tooltip azonnal
		-- frissul (osszehasonlitas, probababu kurzor)
		local focus = GetMouseFocus and GetMouseFocus()
		if focus and combined:IsShown() and focus:GetParent() and focus:GetParent().zbHolder
			and GetLink(focus:GetParent():GetID(), focus:GetID()) and not CursorHasItem() then
			ContainerFrameItemButton_OnEnter(focus)
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		CheckLowSpace(true)
		SaveBags()
		if not seenCounts then
			MarkAllSeen()
		end
	else
		if event == "BAG_UPDATE" then
			if arg1 then
				ClearScanCache(arg1)
			end
			if arg1 and (arg1 == -1 or arg1 >= 5) then
				RequestBankSave()
			else
				RequestLowCheck()
			end
		end
		RequestRefresh()
	end
end)

UpdateModeButtons()

----------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------

SLASH_ZSELL1 = "/zsell"
SlashCmdList["ZSELL"] = function() SellAndSort(false) end

SLASH_ZSORT1 = "/zsort"
SlashCmdList["ZSORT"] = SortBags

SLASH_ZBAGSALL1 = "/zbagsall"
SlashCmdList["ZBAGSALL"] = function()
	combined:Hide()
	CallOrig("OpenAllBags")
end

SLASH_ZBAG1 = "/zbag"
SlashCmdList["ZBAG"] = function(msg)
	local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "mode" and (arg == "bag" or arg == "all" or arg == "box") then
		SetMode(arg)
		CloseAll()
		OpenModeView()
		p("Mode: " .. MODE_LABEL[arg] .. " (" .. MODE_DESC[arg] .. ")")
	elseif cmd == "autosell" then
		if arg == "on" then
			SetAutoSell(true)
		elseif arg == "off" then
			SetAutoSell(false)
		else
			SetAutoSell(not DB().autoSell)
		end
		p("Auto sell " .. (DB().autoSell and "ON" or "OFF") .. ".")
	elseif cmd == "cols" and tonumber(arg) then
		local n = math.floor(tonumber(arg))
		if n < 4 then n = 4 elseif n > 24 then n = 24 end
		ZBagToolsDB.cols = n
		if combined:IsShown() then Layout() RefreshCombined() end
		RefreshOptions()
		p("Box columns: " .. n)
	elseif cmd == "scale" and tonumber(arg) then
		local s = tonumber(arg)
		if s < 0.5 then s = 0.5 elseif s > 2 then s = 2 end
		ZBagToolsDB.scale = s
		combined:SetScale(s)
		RefreshOptions()
		p("Box scale: " .. s)
	elseif cmd == "reset" then
		ZBagToolsDB.point = nil
		ZBagToolsDB.scale = 1
		ZBagToolsDB.cols = DEFAULTS.cols
		RestorePosition()
		if combined:IsShown() then Layout() RefreshCombined() end
		RefreshOptions()
		p("Box window position, scale and columns reset.")
	elseif cmd == "" or cmd == "options" then
		OpenOptions()
	else
		p("Commands (/zbag alone opens the options):")
		p("  /zbag mode bag|all|box - bag mode (same as the Bag/All/Box button)")
		p("  /zbag autosell [on|off] - sell greys automatically at vendors (now " .. (DB().autoSell and "on" or "off") .. ")")
		p("  /zbag cols <4-24> - columns in the Box window (now " .. tostring(DB().cols) .. ")")
		p("  /zbag scale <0.5-2> - Box window scale (now " .. tostring(DB().scale) .. ")")
		p("  /zbag reset - reset Box window position, scale and columns")
		p("  /zsell, /zsort, /zbagsall, /zbagdebug")
	end
end

SLASH_ZBAGDEBUG1 = "/zbagdebug"
SlashCmdList["ZBAGDEBUG"] = function()
	p("mode = " .. Mode())
	p("C_Container = " .. tostring(C_Container ~= nil))
	for _, bag in ipairs(BAGS) do
		local slots = NumSlots(bag)
		p("bag " .. bag .. ": " .. tostring(slots) .. " slots, type " .. tostring(BagType(bag)))
		for slot = 1, slots do
			local link = GetLink(bag, slot)
			if link then
				local itemID, count, locked = SlotInfo(bag, slot)
				p("  slot " .. slot .. " id=" .. tostring(itemID) .. " count=" .. tostring(count) .. " locked=" .. tostring(locked))
			end
		end
	end
end

p("loaded. B opens the current bag mode (Bag/All/Box button), Shift+B all bags. /zbag opens the options, /zbag help lists the commands.")
