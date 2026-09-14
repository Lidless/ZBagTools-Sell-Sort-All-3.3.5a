ZBagTools
A lightweight bag-management addon for WotLK 3.3.5a, built for the Grimfall private server. It adds one-button bag sorting and grey-item selling — features that didn't exist yet in WotLK — directly into the Backpack window.
Features
Sort (`Sort` button / `/zsort`)
Cleans up your bags in one click: merges partial item stacks together, then compacts everything so there are no empty gaps left between items — across all your bags at once (Backpack, and bags 1-4), filling them right to left the same way they're laid out on the default bag bar. Bag moves aren't instant on the server, so Sort automatically re-runs itself a few times (up to 8 passes, spaced out over a fraction of a second) until nothing changes anymore. You only need to press it once.
Sell Grey (`Sell` button / `/zsell`)
Sells every grey (poor quality) item in your bags in one click. Only works while a merchant window is open, exactly like the vendor's own "sell junk" behavior.
Toggle All Bags (`All` button / `/zbagsall`)
Opens all of your bags at once, and — press it again — closes them all again. Same behavior as the default Shift+B shortcut, just as a clickable button.
Where the buttons are
The button row lives inside the Backpack window itself, just below the "Backpack" title and above the item grid. It only appears while your bags are open, and disappears again when you close them — it never floats around on its own or covers other UI elements like action bars or cast bars.
Slash commands
Command	Effect
`/zsort`	Merge stacks and compact all bags
`/zsell`	Sell all grey items (merchant window must be open)
`/zbagsall`	Open/close all bags (same as Shift+B)
`/zbagdebug`	Prints diagnostic info about the container API and current bag contents — useful for troubleshooting on servers with a non-standard `C_Container` implementation
Installation
Download `ZBagTools.lua` and `ZBagTools.toc`.
Put both files into `Interface/AddOns/ZBagTools/` (create the folder if it doesn't exist).
Fully log out/in (not just `/reload`) so the addon loads cleanly.
Notes
This addon was built and tested against Grimfall's custom `C_Container` API, which doesn't always reliably return item quality/count/lock data through `GetContainerItemInfo`. To work around that, item identity and quality (grey/not grey) are read directly from the item's hyperlink instead of relying on that API, so the addon should behave consistently even on servers where those fields are unreliable or missing.
