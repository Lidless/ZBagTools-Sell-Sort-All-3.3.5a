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
		p("Only usable at a vendor (open the merchant window first).")
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
		p("Sold " .. sold .. " grey item(s).")
	else
		p("No grey items to sell in your bags.")
	end
end

----------------------------------------------------------------
-- Rendezes segedfuggvenyek
----------------------------------------------------------------

local function SplitSlot(bag, slot, amount)
	if C_Container and C_Container.SplitContainerItem then
		C_Container.SplitContainerItem(bag, slot, amount)
	else
		SplitContainerItem(bag, slot, amount)
	end
end

-- a zsak tipusa: 0 = normal zsak, egyeb = specialis (herb, enchant, gem,
-- mining, soul, quiver, ammo pouch...) -- bitmaszk, ItemFamily-vel vetjuk ossze
local function BagType(bag)
	local _, bagType
	if C_Container and C_Container.GetContainerNumFreeSlots then
		_, bagType = C_Container.GetContainerNumFreeSlots(bag)
	else
		_, bagType = GetContainerNumFreeSlots(bag)
	end
	return bagType or 0
end

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
-- mindketto a rendezesi sorrendben. A lista vegerol toltjuk az elejet. Egy korben minden slot csak egyszer
-- szerepel (a szerver zarolja a mozgatott slotokat), a maradekot a
-- kovetkezo kor intezi.
----------------------------------------------------------------

local function CombineStacks()
	local list = Snapshot()
	local buckets = {}
	for _, s in ipairs(list) do
		if s.itemID and s.count and not s.locked then
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
-- quiver stb.), azt atrakjuk oda. Hatulrol elore haladunk, igy a
-- normal zsakok vegen levo itemek mennek elobb, ami a lyuk-betoltest is
-- segiti. A specialis lyukakat a rendezesi sorrendben toltjuk.
----------------------------------------------------------------

local function MoveSpecialItems()
	local list = Snapshot()
	local holes = {}
	for _, s in ipairs(list) do
		if s.bagType ~= 0 and not s.link and not s.locked then
			table.insert(holes, s)
		end
	end
	if #holes == 0 then
		return 0
	end

	local moves = 0
	for k = #list, 1, -1 do
		local s = list[k]
		if s.bagType == 0 and s.link and not s.locked then
			for h, hole in ipairs(holes) do
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
--
-- Specialis zsakok (b opcio):
--  * specialis zsak lyukaba csak odaillo item kerul (hatulrol keresve)
--  * specialis zsakban levo itemet nem viszunk ki normal zsakba
--    (kulonben pl. a herb bag kiurulne a Backpack-be)
-- Zarolt slotokat atugorjuk. Egy korben egy slot csak egyszer szerepel.
----------------------------------------------------------------

local function CompactBags()
	local list = Snapshot()
	local used = {}
	local moves = 0
	local back = #list          -- normal lyukakhoz tartozo hatso mutato
	local normalDone = false

	for front = 1, #list do
		local hole = list[front]
		if not hole.link and not hole.locked and not used[front] then
			local k
			if hole.bagType == 0 then
				if not normalDone then
					k = back
					while k > front do
						local s = list[k]
						if not used[k] and s.link and not s.locked and s.bagType == 0 then
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
					if not used[k] and s.link and not s.locked and ItemFitsBag(s.link, hole.bagType) then
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
-- Sort = 1. osszevonas + 2. specialis itemek a helyukre + 3. lyukak, TOBB KORBEN.
-- Minden kor elott megvarjuk, hogy a szerver visszaigazolja az elozo
-- kor mozgatasait (nincs zarolt slot, ures a kurzor).
----------------------------------------------------------------

local SORT_MAX_PASSES = 10    -- fazisonkent
local SORT_TICK = 0.1         -- ennyi masodpercenkent nezzuk, vegeztunk-e
local SORT_TIMEOUT = 5        -- ennyit varunk max. a szerverre

local sortRunner = CreateFrame("Frame")
local sortState = {running = false}

local function SortStop(msg)
	sortState.running = false
	sortRunner:SetScript("OnUpdate", nil)
	p(msg)
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
			sortState.phase = "compact"
			sortState.passes = 0
		end
	else
		local n = CompactBags()
		sortState.totalMoves = sortState.totalMoves + n
		sortState.passes = sortState.passes + 1
		if n == 0 or sortState.passes >= SORT_MAX_PASSES then
			SortStop(string.format("Done: %d stack merges, %d items moved to special bags, %d gaps filled.", sortState.totalMerges, sortState.totalSpecial, sortState.totalMoves))
		end
	end
end

local function SortBags()
	if CursorHasItem and CursorHasItem() then
		p("Put down the item on your cursor first.")
		return
	end
	if sortState.running then
		return
	end
	sortState.running = true
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
		p("bag " .. bag .. ": " .. tostring(slots) .. " slots")
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
	GameTooltip:SetText("Sell grey items (vendor only)")
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
	GameTooltip:SetText("Merge partial stacks, move special items (herbs, shards, ammo...) into their bags, then fill gaps from the back")
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
	GameTooltip:SetText("Open/close all bags (like Shift+B)")
	GameTooltip:Show()
end)
allBtn:SetScript("OnLeave", GameTooltip_Hide)

p("loaded. /zsell, /zsort, /zbagsall -- the button bar appears inside the Backpack window, below the title, while the backpack is open.")
