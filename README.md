# ZBagTools

A lightweight bag-management addon for WotLK 3.3.5a, built for the Grimfall private server. It adds smart bag sorting, one-click grey selling and three bag modes — including a combined, Bagnon-style bag window — on top of the default bag UI.

## Features

### Bag modes (`Bag` / `All` / `Box` button, `B` key)

The mode button cycles through three modes. The `B` key (and the Backpack icon on the bag bar) always opens the current mode, so the button doubles as a setting that is remembered between sessions (account-wide).

| Mode | What `B` opens |
|------|----------------|
| `Bag` | The Backpack only (default WoW behavior) |
| `All` | All bags, each in its own window |
| `Box` | All bags combined into one window |

- Clicking the button switches to the next mode right away: it closes whatever is open and opens the new mode's view.
- `Shift+B` keeps the default behavior: all bags in separate windows.
- Clicking a single bag icon (bags 1-4) on the bag bar still opens just that bag.
- At a merchant, the bank or the mailbox your bags open in the current mode, and close again when you leave.

### Combined bag window (`Box` mode)

- All slots of the Backpack and bags 1-4 in one movable window (position is saved, `Esc` closes it).
- Items are laid out in the same order Sort uses (Backpack first, then bags 1-4), so after sorting your items form one continuous block.
- Uses the default item buttons: using, dragging, splitting, selling at a merchant and tooltips all work as usual.
- Item quality borders, cooldowns, locked items shown greyed out.
- Search box: items that don't match fade out.
- Bag bar at the bottom: swap bags by dragging; hovering a bag icon highlights that bag's items.
- Free slot counter and your money.
- Adjustable columns and scale (see slash commands).

### Sort (`Sort` button / `/zsort`)

Cleans up your bags in one click, across the Backpack and bags 1-4, in three phases:

1. **Merge partial stacks.** The back-most partial stack fills the front-most one. If only part of it fits, exactly that amount is split off, so nothing is left on the cursor. Stacks in a special bag (herb, enchanting, gem, mining, soul, quiver, ammo pouch...) are always the preferred target.
2. **Move special items into their bags.** Herbs go into the herb bag, soul shards into the soul bag, arrows into the quiver, and so on — as long as there is free room there.
3. **Fill the gaps.** Bags are processed right to left as on the default bag bar (Backpack first), and within a bag from the top-left slot to the bottom-right one. The last item is moved into the first empty slot until the two meet. Special bag slots only receive items that fit them, and items are never pulled out of a special bag into a normal one.

Locked slots are skipped. Before every pass Sort waits for the server to confirm the previous moves, so you only need to press it once.

### Sell Grey (`Sell` button / `/zsell`)

Sells every grey (poor quality) item in your bags in one click. Left-click only works while a merchant window is open; away from a vendor the button looks greyed out.

- **Auto sell:** right-click the `Sell` button (or use `/zbag autosell`) to toggle it. While it's on, the button has a green border and your greys are sold automatically a moment after you open a vendor. The setting is saved account-wide.
- **Sort after selling:** whenever something was actually sold (manually or automatically), Sort runs by itself once the sold items have left your bags. After a sale it only reports in chat if it actually moved something.

### Close all bags (`X` button)

Closes every open bag window, including the combined window.

## Where the buttons are

The button row (`Sell` `Sort` `Bag/All/Box` `X`) lives inside the Backpack window, just below the "Backpack" title, and in the header of the combined window. It only appears while those windows are open.

## Slash commands

| Command | Effect |
|---------|--------|
| `/zbag` | Lists the options |
| `/zbag mode bag\|all\|box` | Sets the bag mode (same as the mode button) |
| `/zbag autosell [on\|off]` | Toggles automatic grey selling at vendors (same as right-clicking `Sell`) |
| `/zbag cols <4-24>` | Number of columns in the combined window (default 10) |
| `/zbag scale <0.5-2>` | Scale of the combined window |
| `/zbag reset` | Resets the combined window's position, scale and columns |
| `/zsort` | Sort your bags |
| `/zsell` | Sell all grey items, then Sort (merchant window must be open) |
| `/zbagsall` | Open/close all bags in separate windows (same as Shift+B) |
| `/zbagdebug` | Prints the current mode and diagnostic info about the container API and bag contents |

## Installation

1. Download `ZBagTools.lua` and `ZBagTools.toc`.
2. Put both files into `Interface/AddOns/ZBagTools/` (create the folder if it doesn't exist).
3. Fully log out and back in (not just `/reload`) so the addon and its saved settings load cleanly. This is also needed when updating from an older version, because the saved settings moved to `ZBagToolsDB`.

## Notes

- Built and tested against Grimfall's custom `C_Container` API, which doesn't always reliably return item quality/count/lock data through `GetContainerItemInfo`. Sell and Sort therefore read item identity and quality directly from the item's hyperlink.
- Other bag addons that replace the default bag windows may conflict with the `All`/`Box` modes.
