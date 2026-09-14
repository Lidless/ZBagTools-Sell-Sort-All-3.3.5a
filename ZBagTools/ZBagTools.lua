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

-- itemID-t mindig a linkbol olvassuk ki (ez biztosan mukodik nalad),
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

----------------------------------------------------------------
-- Sell Grey
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

local function SellGrey()
	if not (MerchantFrame and MerchantFrame:IsShown()) then
		p("Csak kereskedonel hasznalhato (nyisd meg a bolt ablakat eloszor).")
		return
	end
	local sold = 0
	for _, bag in ipairs(BAGS) do
		local slots = NumSlots(bag)
		for slot = 1, slots do
			-- direktben a linket nezzuk (ugyanugy, mint a mukodo makro),
			-- nem tamaszkodunk a GetContainerItemInfo/quality mezore
			local link = GetLink(bag, slot)
			if link and IsGrey(link, nil) then
				UseSlot(bag, slot)
				sold = sold + 1
			end
		end
	end
	if sold > 0 then
		p("Eladva: " .. sold .. " db szurke item.")
	else
		p("Nincs eladhato szurke item a taskaban.")
	end
end

----------------------------------------------------------------
-- Combine partial stacks
----------------------------------------------------------------

-- reszleges stack-ek osszevonasa, csendben (visszaadja hany osszevonas tortent)
local function CombineStacks()
	local buckets = {}
	for _, bag in ipairs(BAGS) do
		local slots = NumSlots(bag)
		for slot = 1, slots do
			local itemID, count, locked = SlotInfo(bag, slot)
			if itemID and not locked and count then
				local _, _, _, _, _, _, _, maxStack = GetItemInfo(itemID)
				maxStack = maxStack or 1
				if maxStack > 1 and count < maxStack then
					buckets[itemID] = buckets[itemID] or {}
					table.insert(buckets[itemID], {bag = bag, slot = slot, count = count, maxStack = maxStack})
				end
			end
		end
	end

	local merges = 0
	for itemID, list in pairs(buckets) do
		if #list > 1 then
			table.sort(list, function(a, b) return a.count < b.count end)
			for i = 1, #list - 1 do
				local src = list[i]
				-- keresunk egy meg nem tele celt utana a listaban
				for j = i + 1, #list do
					local dst = list[j]
					if dst and dst.count < dst.maxStack then
						PickupSlot(src.bag, src.slot)
						PickupSlot(dst.bag, dst.slot)
						merges = merges + 1
						break
					end
				end
			end
		end
	end

	if CursorHasItem and CursorHasItem() then
		PutItemInBackpack()
	end

	return merges
end

----------------------------------------------------------------
-- Lyukak eltuntetese, ZSAKOK KOZOTT is: a bagek egyetlen folytonos
-- listakent kezelve tomoriti elore az itemeket a BAGS sorrendben
-- (0=Backpack toltodik fel elsonek -> ez felel meg a "jobbrol balra"
-- sorrendnek a gyari bag-savon, ahol a Backpack van legjobbra).
----------------------------------------------------------------

local function CompactBags()
	local moves = 0
	local slotList = {}
	for _, bag in ipairs(BAGS) do
		local n = NumSlots(bag)
		for slot = 1, n do
			table.insert(slotList, {bag = bag, slot = slot})
		end
	end

	local writeIdx = 1
	for readIdx = 1, #slotList do
		local rs = slotList[readIdx]
		local link = GetLink(rs.bag, rs.slot)
		if link then
			if writeIdx < readIdx then
				local ws = slotList[writeIdx]
				PickupSlot(rs.bag, rs.slot)
				PickupSlot(ws.bag, ws.slot)
				moves = moves + 1
			end
			writeIdx = writeIdx + 1
		end
	end

	if CursorHasItem and CursorHasItem() then
		PutItemInBackpack()
	end

	return moves
end

----------------------------------------------------------------
-- Sort = osszevonas + lyuk-eltuntetes, TOBB KORBEN.
-- A bag-mozgatas a szerverrel szinkronban tortenik, nem azonnali,
-- ezert egy korben nem mindig all be a vegleges allapot -- ezert
-- rovid szunetekkel tobbszor ujra lefuttatjuk, amig nincs tobb
-- valtozas (vagy el nem erjuk a korlatot).
----------------------------------------------------------------

local sortRunner = CreateFrame("Frame")
local sortState = {running = false, pass = 0, maxPasses = 8, elapsed = 0, totalMerges = 0, totalMoves = 0}

local function SortPass()
	local merges = CombineStacks()
	local moves = CompactBags()
	sortState.totalMerges = sortState.totalMerges + merges
	sortState.totalMoves = sortState.totalMoves + moves
	sortState.pass = sortState.pass + 1

	if (merges == 0 and moves == 0) or sortState.pass >= sortState.maxPasses then
		sortState.running = false
		sortRunner:SetScript("OnUpdate", nil)
		p(string.format("Kesz (%d kor): %d osszevonas, %d lyuk-eltuntetes.", sortState.pass, sortState.totalMerges, sortState.totalMoves))
	end
end

local function SortBags()
	if CursorHasItem and CursorHasItem() then
		p("Elobb tedd le, ami a kurzoron van.")
		return
	end
	if sortState.running then
		return
	end
	sortState.running = true
	sortState.pass = 0
	sortState.elapsed = 0
	sortState.totalMerges = 0
	sortState.totalMoves = 0

	SortPass()
	if sortState.running then
		sortRunner:SetScript("OnUpdate", function(self, elapsed)
			sortState.elapsed = sortState.elapsed + elapsed
			if sortState.elapsed >= 0.35 then
				sortState.elapsed = 0
				SortPass()
			end
		end)
	end
end

----------------------------------------------------------------
-- Osszes bag megnyitasa (mint Shift+B)
----------------------------------------------------------------

local function ToggleAllBags()
	-- forceOpen NELKUL: ha minden zsak mar nyitva volt, ez bezarja mindet
	-- (pontosan ugyanez a Shift+B alapertelmezett viselkedese)
	if OpenAllBags then
		OpenAllBags()
	end
end

----------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------

SLASH_ZSELL1 = "/zsell"
SlashCmdList["ZSELL"] = SellGrey

SLASH_ZSORT1 = "/zsort"
SlashCmdList["ZSORT"] = SortBags

SLASH_ZBAGSALL1 = "/zbagsall"
SlashCmdList["ZBAGSALL"] = ToggleAllBags

SLASH_ZBAGDEBUG1 = "/zbagdebug"
SlashCmdList["ZBAGDEBUG"] = function()
	p("C_Container = " .. tostring(C_Container ~= nil))
	if C_Container then
		p("  GetContainerNumSlots=" .. tostring(C_Container.GetContainerNumSlots ~= nil))
		p("  GetContainerItemLink=" .. tostring(C_Container.GetContainerItemLink ~= nil))
		p("  GetContainerItemInfo=" .. tostring(C_Container.GetContainerItemInfo ~= nil))
		p("  UseContainerItem=" .. tostring(C_Container.UseContainerItem ~= nil))
	end
	for _, bag in ipairs(BAGS) do
		local slots = NumSlots(bag)
		p("bag " .. bag .. ": " .. tostring(slots) .. " slot")
		for slot = 1, slots do
			local link = GetLink(bag, slot)
			if link then
				local itemID, count, locked = SlotInfo(bag, slot)
				p("  slot " .. slot .. " id=" .. tostring(itemID) .. " count=" .. tostring(count) .. " locked=" .. tostring(locked))
			end
		end
	end
end

----------------------------------------------------------------
-- Gombsor a Backpack ablakon BELUL, a "Backpack" felirat es az
-- itemek kozott (a Backpack sajat, altalaban ures ikon-teruleten).
-- A gombsor a ContainerFrame1-hez van szulositve, igy automatikusan
-- csak akkor latszik, amikor a Backpack nyitva van -- amikor
-- becsukod, eltunik, nincs kulon show/hide logika ra.
----------------------------------------------------------------

local f = CreateFrame("Frame", "ZBagToolsFrame", ContainerFrame1)
f:SetWidth(140)
f:SetHeight(20)
f:SetPoint("TOPLEFT", ContainerFrame1, "TOPLEFT", 47, -28)
f:SetFrameLevel(ContainerFrame1:GetFrameLevel() + 5)

local sellBtn = CreateFrame("Button", "ZBagToolsSellBtn", f, "UIPanelButtonTemplate")
sellBtn:SetWidth(44)
sellBtn:SetHeight(20)
sellBtn:SetText("Sell")
sellBtn:SetPoint("LEFT", f, "LEFT", 0, 0)
sellBtn:SetScript("OnClick", SellGrey)
sellBtn:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText("Szurke itemek eladasa (csak boltnal)")
	GameTooltip:Show()
end)
sellBtn:SetScript("OnLeave", GameTooltip_Hide)

local sortBtn = CreateFrame("Button", "ZBagToolsSortBtn", f, "UIPanelButtonTemplate")
sortBtn:SetWidth(44)
sortBtn:SetHeight(20)
sortBtn:SetText("Sort")
sortBtn:SetPoint("LEFT", sellBtn, "RIGHT", 2, 0)
sortBtn:SetScript("OnClick", SortBags)
sortBtn:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText("Stack-ek osszevonasa + lyukak eltuntetese, zsakok kozott is")
	GameTooltip:Show()
end)
sortBtn:SetScript("OnLeave", GameTooltip_Hide)

local allBtn = CreateFrame("Button", "ZBagToolsAllBtn", f, "UIPanelButtonTemplate")
allBtn:SetWidth(44)
allBtn:SetHeight(20)
allBtn:SetText("All")
allBtn:SetPoint("LEFT", sortBtn, "RIGHT", 2, 0)
allBtn:SetScript("OnClick", ToggleAllBags)
allBtn:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText("Osszes zsak megnyitasa (mint Shift+B)")
	GameTooltip:Show()
end)
allBtn:SetScript("OnLeave", GameTooltip_Hide)

p("betoltve. /zsell, /zsort, /zbagsall -- a gombsor a Backpack ablakon belul, a felirat alatt jelenik meg, amikor nyitva van a taska.")
