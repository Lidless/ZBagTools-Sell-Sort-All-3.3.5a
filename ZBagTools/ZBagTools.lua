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

local DEFAULTS = {mode = "bag", cols = 10, scale = 1}
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

-- kereskedonel vagyunk-e: a MERCHANT_SHOW / MERCHANT_CLOSED esemeny allitja
local atMerchant = false

local function SellGrey()
	if not (atMerchant or (MerchantFrame and MerchantFrame:IsShown())) then
		p("Only usable at a vendor (open the merchant window first).")
		return
	end
	local sold = 0
	for _, bag in ipairs(BAGS) do
		local slots = NumSlots(bag)
		for slot = 1, slots do
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
-- mindketto a rendezesi sorrendben. A lista vegerol toltjuk az elejet.
-- Egy korben minden slot csak egyszer szerepel (a szerver zarolja a
-- mozgatott slotokat), a maradekot a kovetkezo kor intezi.
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
-- quiver stb.), azt atrakjuk oda. Hatulrol elore haladunk.
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
-- Sort = 1. osszevonas + 2. specialis itemek + 3. lyukak, TOBB KORBEN.
-- Minden kor elott megvarjuk, hogy a szerver visszaigazolja az elozo
-- kor mozgatasait (nincs zarolt slot, ures a kurzor).
----------------------------------------------------------------

local SORT_MAX_PASSES = 10
local SORT_TICK = 0.1
local SORT_TIMEOUT = 5

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
-- Kozos zsak (Box mod): egyetlen ablak az 5 zsak osszes slotjaval,
-- a Sort sorrendjeben (Backpack, majd 1-4. zsak, slotonkent).
-- Az item gombok a gyari ContainerFrameItemButtonTemplate-et hasznaljak,
-- a szulo keret ID-je a zsak szama, a gombe a slot szama -> a kattintas,
-- hasznalat, huzas, tooltip, eladas, split mind gyarilag mukodik.
----------------------------------------------------------------

local SLOT_SIZE = 37
local SLOT_GAP = 4
local PAD = 8
local GRID_TOP = 58
local FOOTER = 38
local MIN_WIDTH = 300

local combined = CreateFrame("Frame", "ZBagToolsCombined", UIParent)
combined:Hide()
combined:SetFrameStrata("HIGH")
combined:SetToplevel(true)
combined:SetClampedToScreen(true)
combined:EnableMouse(true)
combined:SetMovable(true)
combined:RegisterForDrag("LeftButton")
combined:SetBackdrop({
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = {left = 4, right = 4, top = 4, bottom = 4},
})
combined:SetBackdropColor(0, 0, 0, 0.9)
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
end

local title = combined:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", combined, "TOPLEFT", 12, -10)
title:SetText("ZBag")

local closeBtn = CreateFrame("Button", "ZBagToolsCombinedClose", combined, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", combined, "TOPRIGHT", -2, -2)
closeBtn:SetScript("OnClick", function() combined:Hide() end)

local freeText = combined:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
local moneyText = combined:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
moneyText:SetPoint("BOTTOMRIGHT", combined, "BOTTOMRIGHT", -12, 14)

local holders = {}      -- zsakonkent egy lathatatlan szulo, ID = zsak szama
local buttons = {}      -- buttons[bag][slot]
local searchText = ""
local hoverBag = nil    -- a tasksor egy ikonja felett: csak az a zsak latszik elesen

for _, bag in ipairs(BAGS) do
	local h = CreateFrame("Frame", "ZBagToolsHolder" .. bag, combined)
	h:SetID(bag)
	h:SetAllPoints(combined)
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
	elseif searchText ~= "" then
		if not (name and name:lower():find(searchText, 1, true)) then
			alpha = 0.25
		end
	end
	b:SetAlpha(alpha)
end

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
	bb:SetPoint("BOTTOMLEFT", combined, "BOTTOMLEFT", PAD + 2 + (bag - 1) * (BAGBAR_SIZE + 2), PAD + 2)
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
freeText:SetPoint("LEFT", bagBar[4], "RIGHT", 8, 0)

local lastSizes = {}

local function Layout()
	local cols = DB().cols or DEFAULTS.cols
	local index = 0
	for _, bag in ipairs(BAGS) do
		local n = NumSlots(bag) or 0
		lastSizes[bag] = n
		for slot = 1, n do
			local b = GetButton(bag, slot)
			local col = index % cols
			local row = math.floor(index / cols)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", combined, "TOPLEFT", PAD + col * (SLOT_SIZE + SLOT_GAP), -GRID_TOP - row * (SLOT_SIZE + SLOT_GAP))
			b:Show()
			index = index + 1
		end
		for slot = n + 1, #buttons[bag] do
			buttons[bag][slot]:Hide()
		end
	end
	local rows = math.max(1, math.ceil(index / cols))
	local width = math.max(MIN_WIDTH, PAD * 2 + cols * SLOT_SIZE + (cols - 1) * SLOT_GAP)
	combined:SetWidth(width)
	combined:SetHeight(GRID_TOP + rows * SLOT_SIZE + (rows - 1) * SLOT_GAP + FOOTER)
end

local function SizesChanged()
	for _, bag in ipairs(BAGS) do
		if (NumSlots(bag) or 0) ~= lastSizes[bag] then
			return true
		end
	end
	return false
end

local function RefreshCombined()
	if not combined:IsShown() then
		return
	end
	if SizesChanged() then
		Layout()
	end
	local free, total = 0, 0
	for _, bag in ipairs(BAGS) do
		local n = NumSlots(bag) or 0
		total = total + n
		free = free + (FreeSlots(bag))
		for slot = 1, n do
			UpdateButton(buttons[bag][slot], bag, slot)
		end
	end
	freeText:SetText(string.format("Free: %d / %d", free, total))
	moneyText:SetText(FormatMoney(GetMoney()))
	UpdateBagBar()
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
local function CloseAll()
	combined:Hide()
	CallOrig("CloseAllBags")
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
		CallOrig("CloseAllBags")
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
-- Gombsor: Sell | Sort | Bag/All/Box | X
-- Ket helyen van: a Backpack ablakban es a kozos ablak fejleceben.
----------------------------------------------------------------

local modeButtons = {}
local sellButtons = {}

-- a Sell gomb csak kereskedonel aktiv
local function UpdateSellButtons()
	for _, b in ipairs(sellButtons) do
		if atMerchant then
			b:Enable()
		else
			b:Disable()
		end
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

local function SimpleTooltip(btn, text)
	btn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(text)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", GameTooltip_Hide)
end

local function CreateToolbar(name, parent)
	local bar = CreateFrame("Frame", name, parent)
	bar:SetWidth(140)
	bar:SetHeight(20)

	local sell = CreateFrame("Button", name .. "Sell", bar, "UIPanelButtonTemplate")
	sell:SetWidth(38)
	sell:SetHeight(20)
	sell:SetText("Sell")
	sell:SetPoint("LEFT", bar, "LEFT", 0, 0)
	sell:SetScript("OnClick", SellGrey)
	SimpleTooltip(sell, "Sell grey items (vendor only)")
	table.insert(sellButtons, sell)

	local sort = CreateFrame("Button", name .. "Sort", bar, "UIPanelButtonTemplate")
	sort:SetWidth(38)
	sort:SetHeight(20)
	sort:SetText("Sort")
	sort:SetPoint("LEFT", sell, "RIGHT", 2, 0)
	sort:SetScript("OnClick", SortBags)
	SimpleTooltip(sort, "Merge partial stacks, move special items (herbs, shards, ammo...) into their bags, then fill gaps from the back")

	local mode = CreateFrame("Button", name .. "Mode", bar, "UIPanelButtonTemplate")
	mode:SetWidth(38)
	mode:SetHeight(20)
	mode:SetPoint("LEFT", sort, "RIGHT", 2, 0)
	mode:SetScript("OnClick", CycleMode)
	mode:SetScript("OnEnter", ModeTooltip)
	mode:SetScript("OnLeave", GameTooltip_Hide)
	table.insert(modeButtons, mode)

	local close = CreateFrame("Button", name .. "CloseAll", bar, "UIPanelButtonTemplate")
	close:SetWidth(20)
	close:SetHeight(20)
	close:SetText("X")
	close:SetPoint("LEFT", mode, "RIGHT", 2, 0)
	close:SetScript("OnClick", CloseAll)
	SimpleTooltip(close, "Close all bags")

	return bar
end

-- Backpack ablak gombsora. A gyari kliens nem mindig a ContainerFrame1-et
-- adja a Backpack-nek (ha elobb egy masik zsakot nyitsz, az kapja), ezert
-- mindig ahhoz az ablakhoz tesszuk, amelyik eppen a Backpack-et (ID 0) mutatja.
local bpBar = CreateToolbar("ZBagToolsFrame", ContainerFrame1)
bpBar:Hide()

local function AttachBackpackBar(frame)
	bpBar:SetParent(frame)
	bpBar:ClearAllPoints()
	bpBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 47, -28)
	bpBar:SetFrameLevel(frame:GetFrameLevel() + 5)
	bpBar:Show()
end

hooksecurefunc("ContainerFrame_GenerateFrame", function(frame, size, id)
	if id == 0 then
		AttachBackpackBar(frame)
	elseif bpBar:GetParent() == frame then
		bpBar:Hide()
	end
end)

-- a kozos ablak fejlece: gombsor + kereso
local boxBar = CreateToolbar("ZBagToolsBoxBar", combined)
boxBar:SetPoint("TOPLEFT", combined, "TOPLEFT", PAD + 2, -28)

local search = CreateFrame("EditBox", "ZBagToolsSearch", combined, "InputBoxTemplate")
search:SetAutoFocus(false)
search:SetHeight(20)
search:SetPoint("LEFT", boxBar, "RIGHT", 12, 0)
search:SetPoint("RIGHT", combined, "RIGHT", -PAD - 4, 0)
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
-- Esemenyek
----------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("BAG_UPDATE")
events:RegisterEvent("ITEM_LOCK_CHANGED")
events:RegisterEvent("BAG_UPDATE_COOLDOWN")
events:RegisterEvent("PLAYER_MONEY")
events:RegisterEvent("UNIT_INVENTORY_CHANGED")
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
	elseif event == "MERCHANT_CLOSED" then
		if atMerchant then
			atMerchant = false
			UpdateSellButtons()
			CloseAll()
		end
	elseif event == "BANKFRAME_OPENED" or event == "MAIL_SHOW" then
		OpenModeView()
	elseif event == "BANKFRAME_CLOSED" or event == "MAIL_CLOSED" then
		CloseAll()
	else
		RequestRefresh()
	end
end)

UpdateModeButtons()

----------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------

SLASH_ZSELL1 = "/zsell"
SlashCmdList["ZSELL"] = SellGrey

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
	elseif cmd == "cols" and tonumber(arg) then
		local n = math.floor(tonumber(arg))
		if n < 4 then n = 4 elseif n > 24 then n = 24 end
		ZBagToolsDB.cols = n
		if combined:IsShown() then Layout() RefreshCombined() end
		p("Box columns: " .. n)
	elseif cmd == "scale" and tonumber(arg) then
		local s = tonumber(arg)
		if s < 0.5 then s = 0.5 elseif s > 2 then s = 2 end
		ZBagToolsDB.scale = s
		combined:SetScale(s)
		p("Box scale: " .. s)
	elseif cmd == "reset" then
		ZBagToolsDB.point = nil
		ZBagToolsDB.scale = 1
		ZBagToolsDB.cols = DEFAULTS.cols
		RestorePosition()
		if combined:IsShown() then Layout() RefreshCombined() end
		p("Box window position, scale and columns reset.")
	else
		p("Commands:")
		p("  /zbag mode bag|all|box - bag mode (same as the Bag/All/Box button)")
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

p("loaded. B opens the current bag mode (Bag/All/Box button), Shift+B all bags. /zbag for options.")
