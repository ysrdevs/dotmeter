# Dotmeter: technical notes

How each reading is taken, what was measured, and the reasons behind the design. The short version is in the [README](../README.md).

A check-up for your Mac in two places: the menu bar for the quick look, and a desktop window for the full picture. Both show what is using the processor, graphics, memory, disk, network and power right now, and what the heat and fans are doing about it. Every area has an Explain button that asks Claude about that area alone. Apps can be quit from wherever they show up. A timeline keeps a week of history and notes each time the Mac ran hot, so the question "why was it loud last night?" has an answer. Any live area can have its own menu bar item, with a graph and a panel about just that area.

The screenshots in the README use made-up data (`DOTMETER_APPS_DEMO=1`, `DOTMETER_NET_DEMO=1`, `DOTMETER_STORAGE_DEMO=1`, `DOTMETER_USB_DEMO=laptop`, `DOTMETER_TIMELINE_DEMO=1`, `DOTMETER_SPEED_DEMO=1`, `DOTMETER_MOCK_ANALYSIS=1`, `DOTMETER_MODELS_DEMO=1`, `DOTMETER_MACS_DEMO=1`, `DOTMETER_WALL_DEMO=1`, `DOTMETER_FLOATING_DEMO=1`), so no real app, address, device or history appears in them.

No sudo. Everything is read through public macOS APIs plus the SMC for fans and temperatures.

## The design language

Every card is the same object: one headline number, one status line, one segmented dot-matrix bar, one legend, one footer with at most one action. The layout was measured from a reference recording at 2x and reproduced point for point (583 × 343 pt card, 22.5 pt headline, 12 pt body, a bar on a 3.635 pt grid with 22 rows).

- **The bar** is a share-of-a-whole. Each segment has its own color, a tinted fill, a grid of dim dots and lit cells that twinkle in checker patches about ten times a second.
- **Hover** a legend row or a segment: that segment fills to a dense checker and glows, the rest dim, and the status line swaps to a sentence about it.
- **Scanning** collapses the bar white-hot to the left, then refills it behind a glowing white edge while the headline and legend count up.
- **Clearing** shrinks a segment from its right edge under a hot white line, with square particles rising off it, while the numbers count down.

The storage card is the reference itself. The CPU, memory, thermal and network cards, Claude's card, the menu bar panels and the menu bar items themselves are that language applied to the rest of the app.

## Areas

The window has a sidebar. Each area shows its live headline figure next to its name.

- **Dashboard** — one reference-size card each for processor, graphics, memory, storage, thermals, power and network, five minutes of traffic, plus Claude. Every card has a Details link to its area, and a footer that names an app offers to quit it.
- **Processor** — the meter across the full width with eighteen apps; one column of cells per core (performance and efficiency clusters labelled); five-minute charts for processor and graphics load with now, average and peak; and a table of apps where each row opens to show its helper processes with their pids. Clicking an app in the meter opens its row in the table.
- **Graphics** — who is using the graphics cores (the meter by app, from the GPU time each process has been charged); the cores' three loads and their memory as strips; five-minute charts of load, memory, temperature and power; and the app table sorted by graphics use.
- **Memory** — who is using it (wide meter by app), what kind it is (app, wired, compressed, cached, free, swap), a five-minute chart, and the same expandable table sorted by memory.
- **Storage** — the reference card, the disk itself (capacity, free now, what macOS can reclaim, how much is shared between files), five minutes of reading and writing mirrored about one seam with the apps doing it, and the largest items in any category. Click a category in the card's legend or bar and the list follows. Each row has its own action: clear one cache, uninstall one app, delete one Trash item, or move a folder to the Trash. The Apps list has a search that finds any installed app, not only the largest, and an app dropped anywhere on the page lands there with its row already asking. System data is itemized from Library.
- **Thermals** — the temperature meter, each fan against its range, five-minute charts for CPU and GPU temperature and fan speed against load, and every sensor grouped with one cell per sensor colored by heat.
- **Network** — who is using the connection (the meter by app, drawn against a round figure just above the last five minutes' busiest moment, which the status line states); the route out as three stops, this Mac, the router and the internet, with upload and download running between them as cells; address, router, DNS, IPv6 and any tunnel; five minutes of download and upload mirrored about one seam, each on its own scale; the Wi-Fi link (rate, channel, band, width, standard, security, signal where macOS reports one) or the wired link (speed, duplex, share in use, packets, errors); every port and tunnel, where a row opens to show its addresses and counters and idle ports collapse into chips; latency to the router and to the internet as two charts, with jitter and loss; a speed test on request; and a table of apps with their processes, sorted by traffic.
- **USB** — every port and what is on it. Pick a port and the page is about that connection: its speed with the chain from the Mac through the cable to the device, and what each of the three could do, with whichever is holding the speed where it is marked as the limit; what the chip in the cable's plug says (speed, current and wattage, length, maker, certificate number) and how the Mac's own controller rates the cable; every finding in plain words ("Cable is limiting data speed", "EX400U runs at 40 Gb/s, the fastest it supports", "Running slower than expected"), with anything that needs a look on an orange card; a Thunderbolt link lane by lane with what both ends support, the tunnels riding it and the chain of routers through docks; each screen with the signal really being sent, the link carrying it and how much of the link that takes; the devices as a tree, each inside what it is plugged into, hubs hidden until asked for; a charger's offers with the one in force, what is arriving and an estimate of the resistance between charger and Mac; the port's error counters. Name a cable and Dotmeter follows it: when it was last seen, what each connection came up at, whether it has misbehaved.
- **Power** — what the whole Mac is drawing, with apps as segments (the energy the kernel bills each one), the graphics cores, and the remainder; where it goes, part by part; five minutes and the last twenty-four hours of draw; energy and cost over a period you choose (today, 7 days, this month, this year, all time; this month unless you pick another), as bars by the hour, day or month, with the price per kWh typed right there; energy today, yesterday and per year at this rate; on a laptop, the battery's charge, time left, health, cycles and temperature; and the app table sorted by energy.
- **Battery** — on a Mac that has one (the area, its menu bar item and its alert do not appear on a desktop). The card shows the battery as a share of the whole it was built as: what is in it now, what is still to fill, and what wear has taken for good, with time left or time until full, the rate in or out, cycles and temperature. Beside it, health: what it holds when full against what it held when new. Below, the charge over the last twenty-four hours colored by level, five minutes of drain or charging rate with how long a full charge would last at that rate, and the apps drawing the most, each with a Quit button.
- **Timeline** — a week as seven strips, one per day, a column for every five minutes, drawn by heat, processor, graphics, memory, network, power or fans (and by battery level on a laptop, where a column shows how low it got), with a mark above each event. Click a day for its midnight-to-midnight charts and its figures (average and peak load, hottest moment, energy, data moved). Below, every event: ran hot, throttled, memory pressure, disk nearly full, an app holding several cores for minutes, connection lost, battery low. Each opens to show what was on top at its worst, and "Ask Claude why" answers inside the row.
- **Login Items** — every launch agent and daemon on the Mac: whose it is (yours, all users, the system), what it runs, how it starts (at login, kept running, on a schedule, on demand) and whether it is running now. Your own agents can be removed: that stops the agent and moves its file to the Trash, in two clicks. The list of apps under Open at Login is private to macOS, so the page links to System Settings for those.
- **Ask Claude** — a question field for anything about this Mac ("what is corespotlightd?", "what can I safely delete?"), a few suggested questions, and Full check-up for the structured read (verdict, what is using it, what to do, thermal note). Follow-ups continue the same conversation. Claude is sent the live snapshot plus the storage scan when there is one, and the page lists exactly what that is. Of the network it gets the rates, the kind of link and the busiest apps; addresses, network names and hardware ids stay on the Mac.

## Figures that were being read and thrown away

Several collectors fetched more than the app showed. Nothing new is read for these; the values were already in hand:

- **Memory**: what the memory system is doing this moment, from the same kernel structure that gives its size: pages read in from files and written back, moved to and from swap, squeezed into and out of the compressor, each as bytes a second. Swap is shown against its limit, and the Swap row says "swapping out 12 MB/s" when it is. Memory temperature where the Mac has that sensor.
- **Storage**: requests a second and how long each took (time spent over requests served since the last reading), bytes read and written since the Mac started, errors and retries the drives have counted, and the drive's temperature.
- **Processor**: the two kinds of core averaged separately ("P 9% · E 17%"), the number of processes, and how long the Mac has been up.
- **Thermals**: today so far: how often and how long the Mac ran hot, and the day's peak, from the Timeline's own records.
- **Network**: latency and loss in the menu bar panel (it was already being measured while the panel was open), the Wi-Fi standard and signal quality there, traffic since midnight beside the total since Dotmeter started, the best echo beside the jitter, and where the external address exits.

## Explain

Every area has an Explain button at the top of its page, and so does every menu bar panel. It sends Claude the snapshot plus what only that area knows (every sensor group for thermals, latency and interfaces for the network, the power split, the launch items) and asks one question about that area: what the figures mean, what is causing them, whether that is normal for this Mac, and the one thing worth doing. The answer streams into a card where it was asked, and each area keeps its own until dismissed. In the Timeline, "Ask Claude why" on an event does the same with the minutes recorded around it.

## Acting on an app

Open any row in the Processor, Graphics, Memory, Power or Network tables and there are Quit and Force Quit buttons beside Show in Finder. A card footer that names an app (using eight cores, drawing 40 W, downloading at 30 MB/s) has a Quit button too, and when Claude's check-up says to quit something, that step carries the button.

- Two clicks, as with deleting: the first arms the button for six seconds, the second sends the request.
- Apps are asked the way the Dock asks them; bare processes get `SIGTERM`. Force Quit is `forceTerminate` or `SIGKILL`.
- The row says it is closing until the app is gone. If it has not gone after twelve seconds (an unsaved document, a hung process) a line above the table says so and points at Force Quit.
- macOS itself is off limits (the window server, the login window, Finder, the Dock, launchd, Dotmeter), and so is anything owned by another user: that needs an administrator, and the app says so rather than asking for a password.

## Notifications and what counts as an event

Settings has a switch for each: the Mac runs hot or throttles, an app holds N cores for M minutes, memory pressure rises, free space falls under N GB, the connection drops, something plugged in runs slower than it could, and on a laptop the battery falls under N% while unplugged. The figures decide what counts; the switches only decide which ones also send a notification (at most one every ten minutes each). All of them are written to the Timeline regardless. A condition has to hold for twenty seconds before it becomes an event, so one odd reading does not.

A slow connection is the exception to both rules. It is an event the moment the ports are read after something is plugged in (a cable holding a drive to USB 2 speed, a link that came up slower than its parts allow, a cable limiting a charger), one per connection, each with its own notification, from then until it is pulled out or put right. What was already slow when Dotmeter started is not announced.

## Arranging the Dashboard

The Dashboard's cards can be put in any order. Drag a card onto another and it takes that place, with the rest sliding along; the six dots at the top of a card show while the pointer is over it. A right-click on a card has Move to the Top, Move Up, Move Down, Move to the Bottom, and a way back to the usual order. The assistant's card is the one that spans the page: it goes wherever it is put, and never leaves half a row empty above it. The order is remembered, and the Dashboard's menu bar panel lists its areas in the same order, so what matters most is on top in both.

## Menu bar items

Any of Dashboard, Processor, Graphics, Memory, Storage, Thermals, Network, USB and Power can sit in the menu bar, in any combination, and Battery too on a Mac that has one. Three ways to choose: the button at the top right of each area's page, a right-click on any item (Show in Menu Bar), or Settings. One item always stays, so the app can be reached.

- **Dashboard** is the heartbeat icon. It tints when the Mac is hot and can show CPU, temperature or fan speed beside it. Its panel is the overview: a compact meter for all seven areas, each labelled with a link to its page, and Claude. On a short screen the meters fold to number and bar so the panel always fits.
- **The other seven** each draw a small dot-matrix graph and their figure: ten samples of load for the processor and for graphics, ten samples of draw in watts for power, a chip that fills for memory with used over free stacked beside it ("U 149 GB" above "F 363 GB"), a bar that fills for the disk with the same two rows, ten samples of the hottest sensor for thermals with its reading in °C, and download above upload for the network with both rates stacked beside it. Each has three styles: graph and value, icon and value, graph only. Memory turns orange or red under pressure, thermals when the Mac runs hot, the disk when under 5% is free, the network when offline.
- **USB** draws one column per port, lit by how fast its link is (a third for USB 2, full for 40 Gb/s and up, dots for an empty port), with how many ports are in use beside it. It turns orange while any connection is held below what its parts could do. It is redrawn when something is plugged in or pulled out, not on a clock, so it costs nothing while nothing changes. Its panel lists each port in use: what is on it, its speed, and the finding that matters most, with the empty ports named underneath.
- **Battery** draws a battery: a body of cells that fills with the charge, a terminal on its right, a small bolt while it charges, and the percentage macOS itself reports beside it. On battery it turns orange under 20% and red under 10%. The icon style uses the system's battery symbol for the nearest level instead.
- **Each of those opens its own panel**, about that area alone: the meter with a fuller legend, then the detail that area is about (every core; what kind of memory; scan and clear with the disk's figures; each fan against its range; five minutes of traffic and the connection), a five-minute chart, and the numbers behind it. Open leads to the same area in the window.

An item is one template image, so macOS colors it for a light or dark menu bar, and it only ever widens to fit the widest figure it has shown, so the items beside it do not shuffle as digits change. Positions are remembered per item once you Command-drag them.

## Dot colours

Settings › Display chooses what the dots are lit in: Color, where every kind of thing has its own colour as it always had, or Amber, Green or White, where everything is one colour in several strengths so the parts of a bar can still be told apart. Red stays red in all of them, because it is the one colour that means something is wrong. The category colours are not constants any more: `PX.blue` and the rest read from `PX.tones`, which `DotTheme` swaps, so nothing may keep one in a `static let`. A new theme is applied by building the window and the panel again from nothing (`followsTheme()` gives their roots a new identity), which is simpler and safer than teaching every cached picture to notice. Settings is not rebuilt, so the form stays where the choice was made. `DOTMETER_THEME=amber` chooses one for a run without saving it.

## Wall mode and the floating meter

**The wall** is one lattice of dots whose pitch is a whole number of pixels: the screen's shorter side decides it, about 480 dots across a 16:9 screen, so 8 px at 4K, 5 at 1440p and 4 at 1080p. `WallLayout` works out everything from the pixel size: the lattice (a little larger than the screen), the header, nine tiles, and the largest figure scale at which the longest reading of every tile ("9999 RPM", "999 KB/s") still fits with a chart under it. A reading is drawn as a picture with one pixel per dot (about 484 × 274, whatever the screen), and the graphics card does the rest through four layers: the dots scaled up without smoothing, two sets of black stripes (one picture a pixel tall, one a pixel wide, stretched across) that cut the squares apart, and the lit dots blurred, scaled up smoothly and laid over as the glow. Nothing is drawn at screen size by the process, so a 4K wall costs about 1.1% of a core at the two-second pace, most of it the readings themselves, and 40 MB. A picture is made once per reading and once when the minute turns. Every minute the picture moves a pixel or two along a slow back-and-forth, within one pitch each way, so no pixel is always lit. While it is open it holds a display-sleep assertion if Settings says so, and counts as something on screen (`StatusController.setViewer`) so readings arrive at the open-window pace. Captures (`DOTMETER_CAPTURE_WALL`) render the same layers offscreen through `CARenderer`, so the wall can be looked at without taking a screen, and `--self-test wall` reads pixels from that render to check for sharp dots, dark gaps and glow.

**The floating meter** is a non-activating panel at screen-saver level that joins every space, full-screen ones included. It asks the monitor for the live pace in the background (`setBackgroundLive("floating", graphics: true)`), keeps its own small model fed by `addObserver`, and replaces its readings only when the words on the strip change, so most passes redraw nothing; side by side with the same build it adds about 0.05% of a core. Each figure keeps a fixed width so the strip does not shift as digits change. Its place is stored as its top left corner per arrangement of screens and moved the least it takes to be wholly on one screen when that arrangement changes. Opacity applies to the backdrop only. It shows no frame rate: macOS does not let one app read another's. With click-through on it ignores the mouse, and the way back is Settings › Display.

Not run for real: nobody has looked at the wall on the panel itself (only at renders of the same layers and AppKit's capture of the open window), the floating meter has not been tried over a real full-screen game, and nothing with a second screen was exercised.

## The week card

`WeekCardFigures` works the week out from plain arrays of minutes and events (the seven calendar days up to today, nothing older), `WeekCardSpec` turns that into the words, cells and colours of one card on the main thread, where the theme is read, and `WeekCardPlate` lays it out as rectangles on whole pixels and keeps every string it set. A test checks what a card says by reading those strings, not pixels. `WeekCardRenderer` draws a plate off the main thread: the lit cells into one bitmap, two blurred copies of it added back as the glow (three box blurs each, by vImage), and the lit cells again on top. A full week takes about 3 ms to work out, 25 ms to draw and 40 ms to write as a PNG.

The drawing's bitmaps are mapped, not allocated, and unmapped when the picture is done, and vImage is handed its working space the same way: left to itself it takes about 19.5 MB for the wide blur from the allocator, which then keeps it on the app's account. The window is released when closed and builds a new card when opened again; while open it follows the store, the price and the theme. App names are the only thing on the card that could be private, and the "App names" switch removes them; with it on, only the busiest app is named, counted from hot, throttled and busy-app events (the timeline keeps no per-app energy). Day and month names are English capitals whatever the Mac's language. Save, Copy and Share were never clicked by hand.

## Macs

Off until switched on (the page's switch, or Settings). Then the Mac listens on a TCP port advertised over Bonjour as `_dotmeter._tcp`, under a name that is twelve characters of a random id, so the advertisement says nothing about the Mac. Neither end has a certificate: both derive a key from the group code (HKDF-SHA256, fixed salt and label) and use it as a TLS 1.2 pre-shared key, so a Mac with another code never completes the handshake and is told nothing. Its failed handshake is what the "has another code" notice counts. Messages are one JSON object a line with the protocol version; unknown fields and unknown kinds are skipped, and a message may say it needs a newer reader. A hello carries the Mac's name, model, chip, app version and id. A reading carries the headline figures and the three busiest apps: no addresses, no process list. The code is twelve characters from an alphabet without look-alikes and lives in preferences, because it guards readings, not secrets. The suite has no forward secrecy and the code is about 56 bits.

Nothing is sent unless a connection is open, and a Mac opens connections only while its Macs page can be seen: the page registers with the model, and the model also follows the window's own visibility flag, because a closed window is released without its views being told. While a Mac is watched it keeps the light readings at the live pace through `setBackgroundLive("macs")`; measured side by side with a copy that had the feature off, serving one watcher cost nothing that could be told apart (0.22% against 0.25% of a core). A watcher says it is still there every five seconds and is let go after sixteen of silence. A Mac whose readings are overdue by two and a half intervals (at least five seconds) is marked as not answering, dimmed with when it was last seen, and dropped after five minutes. The busiest apps come from the full pass, so on a watched Mac with no window they can be half a minute old.

Tests never touch Bonjour: `DOTMETER_MACS_LOOPBACK` and `DOTMETER_MACS_PEER` put both ends on 127.0.0.1, and `--self-test macs` runs both in one process. **Discovery between two real Macs, and the local network prompt macOS shows the first time, have never been run.** Treat the first report from two real Macs as the first real test.

## Models

Local model runners are found two ways. While the Models area is on screen, and only then, each new reading asks the runners' own ports on this Mac: Ollama (`/api/ps` every time, `/api/tags` every sixteen seconds or when a new model appears, `/api/version` now and then), LM Studio (its `/api/v1/models`, falling back to `/api/v0/models`, then the plain OpenAI list, which cannot say what is loaded), and llama.cpp's and MLX's servers on 8080, 9931 and whatever `--port` their command line names. Requests go off the main thread with a 1.5 second limit; a port that refuses with no process behind it is tried again every fifth refresh, the shared ports every fifteenth. The second way is the process list the app already reads: a runner's processes are picked out by name and path (and, for MLX, by a Python process's arguments), which gives memory, processor and graphics share even when the API is silent. Only loopback addresses are ever asked, the debug switches included. Every field of every answer is optional, and an unknown shape reads as nothing.

What a model "holds" is Ollama's own figure; for LM Studio and llama.cpp it is the size on disk, which is a little less than memory; with no size at all it is the runner's process memory, shared between its models. A server on 8080 that does not identify itself as llama.cpp, with no MLX process in sight, is left alone. Speed is the one thing that makes a model work: one fixed prompt of 48 tokens, on a click, to a model the runner has just confirmed is still loaded, timed by the runner's counters (Ollama's `eval_count` over `eval_duration`, LM Studio's `stats`, llama.cpp's `timings`) or, for MLX, by timing the stream. The sidebar's count is shown only while the reading is under half a minute old.

**Never run against a real loaded model**, a running LM Studio, llama.cpp or MLX: only a stand-in server and the documented shapes. The Mac it was written on had Ollama running with nothing loaded and nothing installed.

## Command line and AI server

The app's own program is the command: `Dotmeter status`, `cpu`, `graphics`, `memory`, `thermals`, `network`, `power`, `storage`, `apps`, `usb`, `timeline`, `help`, and `mcp`. `main.swift` hands over to `Command` when the first argument is a word, before `NSApplication` exists and before the carry-over from the app's earlier name. Every flag of the app starts with a dash, so a mistyped word is refused (exit 2) rather than opening the app. A command opens no window, asks the Keychain for nothing, sends nothing over the network and writes no file; it was run with writes and the network denied by a sandbox profile.

Readings come from `Collectors`. Load, traffic and each app's share are differences, so a command takes two readings 0.8 s apart: the process sampler ignores anything under 0.75 s and would return zeros. `storage`, `usb` and `timeline` read no sensor and return at once. A cold `status` takes about 1.05 s. The command leaves its own process out of the app lists.

`--json` and the server share one set of shapes, written by a small JSON writer of our own (`CommandJSON.swift`) so keys keep their order and figures keep fixed digits on every macOS. Units are in the key names; a key is absent where the Mac does not report the figure. Addresses, the Wi-Fi name, the router, DNS servers and search domains appear only with `--addresses`, and never from the server. The external address is never printed. `timeline` decodes the app's file read-only, skips events of a kind it does not know, and honours `DOTMETER_TIMELINE_PATH`.

`Dotmeter mcp` speaks the Model Context Protocol on standard input and output, one JSON-RPC message a line. It implements revision 2026-07-28 (no handshake: `server/discover`, the version in each request's `_meta`) and the handshake revisions 2025-11-25 back to 2024-11-05 (`initialize`, `ping`). Eleven read-only tools; an unknown tool is error -32602, a bad argument is an `isError` result the model can read. The real standard output is set aside for protocol messages and anything else that prints goes to standard error. The server keeps its collectors: calls within 0.3 s share a reading, a call within 5 s is the difference since the last, and a call after a longer pause waits 0.8 s again. Idle, it uses no CPU and 28 MB.

**No real AI app has connected to the server yet**: it was driven by a script that checks every answer. Settings › Command line and AI apps has the command, the setup JSON for Claude's desktop app and the line for Claude Code.

## Drive health and accessory batteries

**Drive health** is the internal drive's own NVMe SMART log, the 512 bytes the specification calls log page 02h. macOS gives it to any user through a plug-in that ships inside the NVMe driver (the same way smartmontools reads a Mac): the registry entry that says "NVMe SMART Capable" is opened with `IOCreatePlugInInterfaceForService` and its first function fills the log. That part is C (`CDotmeter/smart.c`), because the interface is a table of function pointers; `SMARTLog` decodes the bytes, 128-bit counters included, and `DriveHealth` is what the page shows. A data unit is a thousand 512-byte sectors: over twelve minutes the drive's written and read counters moved by exactly what the block driver counted. A read takes 2 to 3 ms, so it is done at launch and every ten minutes, in a full pass, and carried between. Only the drive built into the Mac is reported. A Mac whose drive is not NVMe, or a log that comes back empty, gets no panel, never a guessed figure. The drive's own temperature reads at the cool end of the SMC sensors the app groups as "Storage".

**Accessory batteries** come from two places. The hardware registry: every entry that publishes `BatteryPercent`, found by property, not by class, with its `Product`, `Transport` and, where published, whether it is charging. And the system's accessory power sources (what `pmset -g accps` prints), which is where headphones and their cases are; that list is read through an IOKit call with no public header, looked up at run time and skipped where it is missing (`DOTMETER_ACCESSORY_SOURCES=0` leaves it out). No Bluetooth framework is used, so macOS never asks for Bluetooth permission. A pair of earbuds is one row with macOS's combined figure and its case is another. A device at or under 15% that is not charging becomes a Timeline event at once and sends its own notification, and is not news again until it has been above 20%; devices known only from the power sources list are shown but never start an event, because that list also holds what is merely nearby, such as a case draining in a drawer. Explain is told what each accessory is, not its name, since a name is often its owner's.

Not run for real: no keyboard, mouse or trackpad that reports a level was on the Mac this was written on, so the registry reader, the event and the notification ran only on made-up entries (`DOTMETER_HEALTH_DEMO=1` invents a drive and three accessories). Earbuds with uneven halves, or one bud out of its case, were only decoded from made-up dictionaries.

## The activity watch

Three things are noted in the Timeline without being readings: an app using the microphone, the camera coming on, and an app crashing. None of them polls. Core Audio keeps an object for every process connected to it (macOS 14.2 and later); the watch listens to the list and to each one's "is running input", and asks a process again only when told it changed. A look every ten seconds stands behind the listeners, and at rest it only asks whether any device that can record is running, because asking 40 processes costs 3.4 ms. Only properties are read; no device is opened and no stream started, so macOS asks nothing. A process is named by the outermost app it runs from, like the process list. The system's own listeners outside any app are left out, except the one that carries FaceTime's calls. Recording from a virtual device alone is not a microphone. Before 14.2 only input-only devices can be asked, with no app name. The camera is CoreMediaIO's "is running somewhere" on each video device; macOS does not say for whom, so the event does not either. A use becomes an event after two seconds, ends when it stops, and carries on if it restarts within five.

Crashes come from the header line of the `.ips` reports in `~/Library/Logs/DiagnosticReports` and `/Library/Logs/DiagnosticReports`; the body is never parsed. Only `bug_type` 309 with a bundle identifier counts, which leaves out command-line tools, background processes and faults the process survived: on the Mac this was written on, 6 of 65 reports in a week. Crashes of one app within an hour are one event with a count. The identifiers of reports already taken are kept in the timeline file, so nothing is counted twice and a forgotten event stays forgotten. The last seven days are written in silently at launch; a new report while the app runs can also send the notification. `TimelineStore.begin` now inserts by start time, so a backfilled crash lands at its real place. Measured side by side with the watch off: 0.17 s against 0.16 s of CPU over 90 s, and about a megabyte of memory. The watch does not run on made-up data (`DOTMETER_TIMELINE_DEMO=1` or `DOTMETER_APPS_DEMO=1`), so nothing real appears in a capture.

**Not run for real: the Mac this was written on has no microphone and no camera.** Real microphone use, real camera use and their listeners have never been seen; hangs make no event because no hang report was there to learn from.

## Build and install

Requires Xcode 15 or later on macOS 14+.

```bash
Scripts/build.sh release --install --run
```

That builds the Swift package, assembles `Dotmeter.app`, signs it with your Apple Development identity if one exists (so Keychain access survives rebuilds), copies it to `/Applications` and launches it.

### The name, in one place

What the app is called and how macOS knows it are set twice, and the build refuses to go on if the two disagree: `Resources/Info.plist` (the bundle's name, program and identifier, which the scripts read through `Scripts/identity.sh`) and `Sources/DotmeterShared/AppIdentity.swift` (the same facts compiled into the app and its helper, whose trust in each other must not depend on a file read at run time). Every sentence in the app that names it reads `App.name`; the helper's launchd description is written at build time from `Resources/helper.plist.in`; the install window takes the name from the script. A new name is a change to those two files.

### It used to be called Vitals

Until 2.0 the app was Vitals, with the identifier `com.ysr.vitals`. Another Mac monitor already uses that name. To macOS a new identifier is a new app, so the first launch as Dotmeter carries over what the old one kept (`Migration`): its settings, including the window frames; its folder under Application Support, which is moved, with the timeline and the followed cables in it; and the API keys in the Keychain, for which macOS asks once before handing over an item another app saved. What macOS ties to the app and asks the person about cannot be carried: the uninstall helper's approval, Launch at Login, and the permissions for notifications, the local network, the Finder and Full Disk Access are asked for again when next needed. The debug switches changed prefix with it, from `VITALS_` to `DOTMETER_`.

Opening the app shows the window and puts an icon in the Dock while the window is open. Close the window and Dotmeter goes back to living in the menu bar only. When it starts at login it stays in the menu bar. Left-click a menu bar item for its panel, right-click for Open Dotmeter, Settings, which items to show, Launch at Login and Quit.

## Packaging for other Macs

```
Scripts/package.sh
```

builds `dist/Dotmeter-<version>.dmg`: a universal app (Apple silicon and Intel) signed with a Developer ID certificate and the hardened runtime, inside an install image with a laid-out window, then notarized by Apple and stapled so it opens on a Mac that has never seen it, even offline.

The install window is drawn in the app's own language (`docs/dmg-window-preview.png`): the name and version with a strip of menu bar items as the app draws them, the app's meter bar with one segment per area, a tray holding the two icons with the icon's pulse running from the app to Applications as the arrow, and the areas as a legend underneath. The icons and their names sit on a mid grey because Finder writes the names in black or in white depending on the appearance, whatever is behind them.

It needs two things on the Mac that does the packaging:

- A **Developer ID Application** certificate in the keychain. The script picks it up by name.
- **Notarization credentials**, saved in the keychain as a `notarytool` profile. The script uses the profile `dotmeter-notary` by default; `NOTARY_PROFILE=<name>`, in the environment or in an untracked `Scripts/local.env`, picks another. To save one on a Mac that has none, this asks for an app-specific password from account.apple.com and keeps it in the keychain:

  ```
  xcrun notarytool store-credentials PROFILE_NAME --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
  ```

Without the profile the script still produces a signed image and says plainly that it is not notarized. Other Macs refuse to open such an image.

Notes:

- The everyday `Scripts/build.sh` keeps signing with the Apple Development certificate. The packaged app has a different signature, so installing it over a development copy on the same Mac makes the Keychain ask once before it hands over the saved API key.
- The window layout is written directly by `Scripts/make-dmg-layout.swift` instead of by scripting Finder, which needs Automation permission and a visible window. It writes the same seven records, in the same file layout, as layout files in other install images. `Scripts/make-dmg-background.swift` draws the background; with `--preview <app>` it also renders the window in light and dark appearance (`docs/dmg-window-preview.png`). Finder draws icon labels black or white to suit the appearance, not the background, which is why the icons sit on a mid grey tray.
- The Intel half is built and runs under Rosetta. It has never been run on an Intel Mac, where the sensor names differ.

## Updates

Once a day the app asks GitHub for the newest release of `ysrdevs/dotmeter` (`UpdateFeed`, one request to `api.github.com/repos/…/releases/latest`, nothing about the Mac in it). The first look is twenty seconds after launch, a failed one is tried again within the hour, and the switch is in Settings under Updates. A newer version brings up a window with what is new (`UpdateView`); found by the daily look, the window comes forward without taking the keyboard. Later closes it until the next day's look, Skip this version silences the daily look for that version only, and the menus, Settings and a line at the foot of the sidebar all lead back to it.

Nothing is downloaded until Install is pressed. Then (`UpdateInstaller.prepare`):

1. The release's `.dmg` is downloaded to a temporary folder. Its size has to be the size GitHub gave.
2. The image is mounted read-only, out of sight, and the app inside is checked by macOS against one requirement: it is Dotmeter (the identifier), signed with the developer's Developer ID (the team), and notarized by Apple. Every architecture and the helper inside are checked. Its version has to be newer than the one running, so an old release cannot be put back.
3. It is copied beside the installed app, on the same volume, and the copy is checked again: what was checked is what gets installed.
4. The copy and the app change places in one step (`renamex_np` with `RENAME_SWAP`; two renames where the disk cannot swap), the old copy is removed, and a small shell waits for this process to go and opens the new one with the same arguments and `DOTMETER_` switches.

Where the app may not change its own folder, or macOS is running it from a temporary place, steps 3 and 4 give way to a button that opens the checked image for dragging by hand.

Where a download came from is never the reason to trust it. A feed pointed elsewhere (`DOTMETER_UPDATE_FEED`) can only offer what passes the same check, which is what makes the switch safe to ship and the whole way testable: `--self-test update` with `DOTMETER_UPDATE_TEST_IMAGE=dist/Dotmeter-<version>.dmg` runs a real install on a copy of the app in a temporary folder and then changes one bit of the program, the Info.plist and the helper in turn to see each refused.

The notes shown are the release's text up to its `## Install` heading, so keep what is new above that heading when writing a release.

Not tried: an update of a copy whose uninstall helper is switched on (the helper's approval should carry over, since the team is the same), and a development-signed copy replacing itself with the released one, which makes the Keychain ask once about each saved key as any change of signature does. The first release with this in it still has to be installed by hand.

## Storage: what it reads and what it deletes

The first scan asks macOS for permission to look in Documents, Desktop and Downloads. It reads file sizes only, never contents. The Photos library and the Trash are private to macOS; without Full Disk Access they are counted under System data, and the card says so and offers to open the right Settings pane.

Nothing is ever removed without two clicks: the button first changes to a confirmation and reverts after six seconds if you do nothing.

While one item is being removed its row shows the work: the dot strip drains from the right behind a bright edge, the size counts down, and the button gives way to the spinner with a percentage. Clearing a cache and deleting from the Trash go folder by folder, so the percentage is real. A move to the Trash is a single step, so that row shows a running highlight and no percentage. When it finishes the row shows a check mark, fades, and the list closes up.

- **Clear caches** removes the contents of `~/Library/Caches`, except Dotmeter's own cache and the caches of apps that are running at that moment.
- **Empty Trash** removes what is in `~/.Trash`.
- **One item at a time**, from Largest items. In Apps, typing in the search lists every installed app that matches (in `/Applications` and `~/Applications`, one folder down), and dropping an app on the page offers that one wherever it lives; both work before any scan has run:

| Category | Button | What happens |
| --- | --- | --- |
| Caches | Clear | That cache folder is deleted. Refused while its app is running. |
| Apps | Uninstall | The row itself asks: it says what would go with the app, and Uninstall deletes the app and what it left behind, for good. Refused while the app is running. See below. |
| Trash | Delete | That item is deleted for good. |
| Developer, Documents, Photos, Movies, Music | Move to Trash | Recoverable until the Trash is emptied. Only inside the home folder; Desktop, Documents, Downloads, the Photos library and the like cannot be removed from here. |
| System data | none | Show in Finder only. |

Moving something to the Trash does not free space yet; the status line says how much emptying it will free. If macOS refuses (an app owned by another user, for example), the card says why.

Sizes are decimal (as Finder shows them). A full scan of a 2 TB disk takes about three minutes on an M3 Ultra.

### Uninstalling an app

Uninstall is not a move to the Trash, and it does not open anything. The app's row turns into the question: it says what would go ("deletes the app and 6 things it left behind (513 MB) for good"; rest the pointer on it for the list), with Cancel and Uninstall beside it. Uninstall deletes all of it for good, and the row counts down as it goes.

- **What is looked for.** Entries directly inside the folders apps keep their own files in: Application Support, Caches, Preferences, Saved Application State, HTTPStorages, WebKit, Cookies, Logs, Application Scripts and LaunchAgents in your Library; Application Support, Caches, Preferences, Logs, LaunchAgents, LaunchDaemons and PrivilegedHelperTools in `/Library`; install receipts; and the app's own container, looked for by name because macOS asks before another app's containers may even be listed.
- **What counts as the app's.** An entry named for the app's bundle identifier, exactly or followed by a dot and more, unless another installed app's identifier fits it better; and, in Application Support, Caches and Logs only, an entry named exactly for the app, unless another installed app has the same name. Nothing is matched by a looser rule, because what is found is deleted without a review. When a second installed copy has the same identifier (a renamed duplicate, a beta beside the release), only the app goes, because the files are the other copy's too.
- **Apple's App Store apps** (iMovie, GarageBand, Keynote, Xcode) uninstall like any other app. Their files are matched by identifier only and only in your Library, since Apple's apps share folders named for each other. What is part of macOS sits on the sealed system volume and has no Uninstall button (Safari in Applications is a link into it).
- **Order.** The app goes first. If it will not go, nothing else is touched. If the app goes and something of its will not, the status line names it.
- **What the system owns.** Apps from the App Store or an installer, and anything in `/Library`, belong to root, and a plain delete is refused. Those go to a helper: a launch daemon inside the app bundle (`Contents/MacOS/DotmeterHelper`), registered with `SMAppService`. Nothing has to be switched on beforehand. The first uninstall that needs it registers it, opens Login Items & Extensions where macOS wants your OK, says so in the row, and carries on by itself the moment Dotmeter is switched on there (or gives up after four minutes, or on Cancel). After that no uninstall asks for anything. Settings has a row to switch it off again.
- **What keeps the helper safe.** It answers only a caller that macOS confirms is Dotmeter signed by the same developer (and Dotmeter only talks to a helper signed the same way). It does one thing, deleting, and only an app in an Applications folder or one entry directly inside one of the folders above, for the user who is asking. It refuses anything on the system volume, any leftover with an Apple name, anything deeper or shallower than that, and anything whose folder is reached through a link (`RemovalPolicy`). It exits when idle.
- **Containers.** A sandboxed app's container is private to it. macOS may ask whether Dotmeter can touch another app's data, or refuse without Full Disk Access; a container that cannot be removed is named in the status line.

### Why the numbers add up

Adding up every file's size does not work on APFS. Files can share storage (a cloned copy costs nothing until it changes) and one file can have several names (hard links, which package managers and Xcode use heavily). On the disk this was built on, a naive sum came to 3.08 TB on a 2 TB disk, because 1.76 TB of storage was shared and had been counted once per copy.

- **Hard links** are recognized by inode and counted once.
- **Clones** are recognized by APFS clone id (`ATTR_CMNEXT_CLONEID`); the first file carries the shared blocks and the rest count only their private size. The lookup is made for files over 96 KB.
- **Who owns a shared file** is settled after every folder has been walked, in a fixed order (Apps, Developer, Photos, Movies, Music, Caches, Trash, Documents, Library), so a game cloned into the home folder counts under Apps on every scan rather than under whichever folder a thread reached first.
- **Used** means capacity minus what is free right now. macOS reports more as "available" because it can purge snapshots and caches on demand; that amount is shown separately as reclaimable.
- **System data** is what is used and not attributed to a category. The part of it that lives in Library is measured too and listed under Largest items.
- If folders still add up to more than the disk holds (small shared files are not de-duplicated), they are scaled to fit and the Disk panel says by how much. The headline can never exceed the disk.

## Claude or GPT: setup

Answers can come from Claude (Anthropic) or from GPT (OpenAI). Settings has the choice under Assistant, and each provider keeps its own key, so switching back and forth loses nothing. Paste a key from console.anthropic.com or from platform.openai.com; it is stored in the macOS Keychain and only ever sent to that provider (`api.anthropic.com` or `api.openai.com`). The prompts, the report and everything on screen are the same for both; only the name on the buttons changes ("Ask Claude", "Ask GPT").

- **Claude** defaults to Claude Opus 5.5 at low effort, which answers in a few seconds and costs roughly a cent per analysis. Sonnet 5.5 and Haiku 5.5 can be chosen instead.
- **GPT** uses `gpt-6.1-sol` through OpenAI's Responses API (`POST /v1/responses`), streamed, with the same three effort levels, and with `store` off so OpenAI keeps nothing of the conversation. Its output allowance is set well above what an answer needs (16,384 tokens), because the model's reasoning is paid for out of the same allowance.

The first answer is requested as JSON against a schema and rendered natively; follow-ups are prose. The schema names every field as required and closes every object, which is what both providers' strict modes ask for.

The OpenAI side was built and tested without an OpenAI key: the request and every stream event are checked by `--self-test openai`, and a whole analysis was run against a stand-in server on this Mac that speaks the same protocol (a good answer, a rejected key, an empty balance, an answer cut short). It has not yet made a real call to OpenAI.

## How it reads the machine

| Reading | Source |
| --- | --- |
| CPU total and per core | `host_processor_info` deltas |
| Memory, pressure, swap | `host_statistics64`, `kern.memorystatus_vm_pressure_level`, `vm.swapusage` |
| Per-process CPU and memory | libproc (`proc_pid_rusage`), grouped by `.app` bundle |
| Thermal state, speed limit | `ProcessInfo.thermalState`, `IOPMCopyCPUPowerStatus` |
| Fans and temperatures | AppleSMC via IOKit (`F0Ac`, `Tp*`, `Te*`, `Tg*`, …) |
| GPU utilization | `IOAccelerator` performance statistics |
| Network rates and totals | the routing sysctl (`NET_RT_IFLIST2`), added up by Dotmeter from its own start |
| Addresses, ports, route, DNS | `getifaddrs`, `SCNetworkInterfaceCopyAll`, the system configuration store (`State:/Network/Global/…`) |
| Carrier and duplex | `SIOCGIFMEDIA` |
| Wi-Fi link | CoreWLAN |
| Per-app traffic | `/usr/bin/nettop`, one sample at a time |
| Latency | ICMP echo over an unprivileged datagram socket |
| Speed test | `/usr/bin/networkQuality -c`, with the live figures read from the interface counters while it runs |
| Whole-machine power | the SMC's `PSTR` sensor |
| Power by part | the Energy Model counters behind `powermetrics`, through `libIOReport` (no public header) |
| Per-app energy and disk bytes | `proc_pid_rusage` version 6 (`ri_energy_nj`, `ri_diskio_bytesread`, `ri_diskio_byteswritten`) |
| Per-app graphics time | the accelerator's clients in the IO registry: each carries the pid that opened it and its accumulated GPU time |
| Graphics memory | `IOAccelerator` performance statistics |
| Battery charge, state, time left | the power sources list (`IOPSCopyPowerSourcesInfo`), which is what macOS's own battery item shows |
| Battery health, cycles, rate, temperature | `AppleSmartBattery` in the IO registry |
| Launch agents and daemons | the three launch folders, `launchctl list` for what is loaded, `proc_pidpath` for what is running |
| Disk usage | `fts(3)` over the home folder, Applications and developer directories |

Power notes:

- On the M3 Ultra this was built on, the whole-machine sensor and the graphics cores report, and the processor's own energy channels are listed but never leave zero. So the Power card shows what apps are billed for processor work, the graphics cores, and the remainder as "Everything else": supply losses, storage, fans, ports and macOS itself. At idle that remainder is most of it (about 30 of 35 W), which is simply what a Mac Studio draws for being on. Chips that do report the processor total get that row instead.
- Per-app energy checks out against a known load: one process pinning one performance core reads 4.9 W.
- An Ultra chip lists about 650 energy channels, nearly all per-core detail. Reading every one cost 7 ms; Dotmeter subscribes to the totals only.
- "Today" and the twenty-four hour chart count only the minutes Dotmeter was running.
- Cost is in dollars and always carries the sign. Set the price per kWh on the Power page or in Settings; with none set, the same panel shows kilowatt-hours alone.
- Totals for a month, a year and all time come from a ledger of one entry per day that is never trimmed, kept in the same file as the timeline. The minute records only go back a week. A file from before the ledger existed starts it from whatever minutes it still holds. Clearing the history on the Timeline page clears the ledger too.
- "The whole month, at this rate" multiplies the average recorded day by the days in the month. It is a guide, and it says how many days it rests on.
- **Nothing about the battery has run against a real one.** This was built on a Mac Studio, which has none, so the Battery area, its menu bar item and the low-battery event were only ever fed made-up laptops (`DOTMETER_POWER_DEMO=laptop`, `charging`, `low`, `full`). The reading itself uses the public power sources list for charge, state and time, and the battery's registry entry for the rest; the first MacBook it runs on is its first real test. What was checked here: a Mac without a battery reports none, hides the area, and refuses a saved battery menu bar item.

Timeline notes:

- One record a minute (averages, plus the peak processor load), a week kept, in `~/Library/Application Support/Dotmeter/timeline.json`, about a megabyte. It is written every five minutes and when the app quits, including when it is ended by a signal.
- Events come from the same readings as everything else. In the background the process list is read every thirty seconds, so "what was on top" can be that old.
- Nothing is recorded while Dotmeter is not running, and the page says how much of each day it has.

USB notes:

- **Everything comes from the hardware registry**, matched by base class (`IOPort`, `IOThunderboltSwitch`, `IOUSBHostDevice`, `AppleUSBHostPort`), so the reader does not depend on which port chip a Mac has. Nothing is sent to a device and nothing is looked up over the network. It needs Apple silicon and a recent macOS; elsewhere the page says the ports are not published.
- **The cable's marker is decoded from the raw answer.** macOS hands over the 32-bit objects a cable's plug (and the device at the far end) replied with to Power Delivery's Discover Identity. `PowerDelivery.swift` decodes them as the specification lays them out, and `--self-test usb` checks that against the words read from two real cables.
- **The verdict is arithmetic on three ceilings.** The Mac's port (the lane speeds its router lists, or Apple's published USB 3 figure for the port kind), the cable (the Mac's Thunderbolt controller's own rating where there is one, else the marker), and the device (the lane speeds its router lists, or its USB version when that pins the speed). A link at the lowest ceiling names what set it; a link below every ceiling is "running slower than expected". A part that states nothing is said to state nothing: a USB device that says 3.1 or later may be a 5, 10 or 20 Gb/s one, and one that says 2.1 may be a USB 3 device that fell back.
- **A short passive cable marked 40 Gb/s is rated for 80 by the controller**, and that is expected: the 80 Gb/s mode was designed to run over such cables. The page shows both figures and says so.
- **Unusual values are flagged in hedged words.** A marker with vendor ID 0, a reserved value in the speed, current, length or termination field, a withdrawn voltage marking, or an extended-power claim without the voltage to match gets an orange card that says the marker looks unusual, not that the cable is fake.
- **No certification or vendor register is bundled.** A cable's USB-IF certificate number is shown as read; who holds it is not, until a list is added (`usb-certifications.tsv` in the app's resources, number then holder). Vendor names come from a short built-in list plus whatever attached devices call themselves, so an unnamed vendor ID says nothing about the ID.
- **Screens are read from the framebuffer driving them**, which lists every timing with its full raster and says which is in use: that gives the true resolution on a scaled screen, the exact refresh rate and the pixel clock. What a mode needs is the pixel clock times 24 bits; what the link carries is lanes times lane rate times 0.8. A mode that needs more than the link carries is being sent compressed, and the page says so. That is worked out, not read.
- **Followed cables** are kept in `~/Library/Application Support/Dotmeter/cables.json`. A cable is recognised by its marker, so two of the same make and model share a record, and one with no marker cannot be followed. While any cable is followed the ports are read once a minute in the background as well as whenever something is plugged in.
- **What has not run against real hardware.** This was built on a Mac Studio, which is never charged through a port. The charger's offers, the contract, the arriving power and the charger-to-Mac resistance are read from the keys a MacBook publishes, and were only ever fed made-up data (`DOTMETER_USB_DEMO=laptop`). The resistance figure is one reading of how far the arriving voltage sags below the agreed one, so a charger that lets its output droop reads as resistance too.
- **When the ports are read.** A pass over ten ports, eight Thunderbolt routers and thirteen devices takes about 55 ms, 21 ms of it on a core, so it is not done on a clock. `USBWatcher` asks the hardware registry to say when a USB device or one of a port's transports appears or goes, and the ports are read then (0.7 s later, and again at 3 s, since a hub's devices arrive one by one). Behind that is a slow clock in case the registry says nothing: every 10 s while the USB page is open, 30 s while USB sits in the menu bar, 60 s while a cable is followed, 120 s otherwise (for the Timeline). Only a charger on a port brings back a reading on every pass, for its live figures. The watcher's plumbing was tested by mounting a disk image; a real plug has not been, on a desk where nothing could be unplugged.

Network notes:

- **What Dotmeter sends.** Requests for an analysis or an explanation go to `api.anthropic.com` or `api.openai.com`, whichever you chose, when you ask for one. While the Network area or its panel is open, a 32-byte ICMP echo goes to your router and to `1.1.1.1` every two seconds (Settings can switch this off; the first time, macOS may ask to allow access to the local network, which the router echo needs). A speed test runs only when its button is pressed: it is Apple's own `networkQuality`, against Apple's servers, for about fifteen seconds, and on a fast line it moves a few hundred megabytes. The external IP address is asked of the same `1.1.1.1`, one small HTTPS request for its plain-text trace page, when the Network panel or area is opened and at most once every five minutes for the same connection (Settings can switch this off too). Nothing else leaves the Mac.
- **Open ports** lists every app that is waiting for TCP connections, split into those other devices can reach (bound to every address or to one of this Mac's network addresses) and those that answer only to this Mac, with the usual meaning of well-known ports beside the number and whether the macOS firewall is on. What launchd holds open for Remote Login, File Sharing and Screen Sharing is shown as macOS sharing services. It is read from `nettop` every five seconds while the Network page is open; nothing is probed and nothing leaves the Mac. (`netstat` is the obvious tool for this and works from a shell, but run by an app macOS hands it an empty TCP table.)
- **Where the external address exits.** The page that carries the address also carries the country it is registered in and the Cloudflare site that answered, which is near wherever the traffic leaves for the internet. Both are shown beside the address ("Canada · leaves near YVR") at no extra request. With a VPN or a relay they are the tunnel's far end.
- **Addresses copy with a click.** In the Network item's panel, and on the Network page, the local and the external IP are rows that copy their address when clicked.
- **Latency is measured without privileges**, over a datagram ICMP socket. A lost echo is drawn as a full red column, so loss is visible at a glance.
- **Totals run from when Dotmeter started, not from when the Mac did.** The kernel's own totals cannot be trusted as they stand: the routing sysctl's structure is 64-bit, but some drivers still wrap at 4 GB inside it (this Mac's Wi-Fi went from 4.2 GB sent to 452 MB while this was being built). Dotmeter adds up the movement between readings instead, recognises a wrap, and says how long it has been counting.
- **Totals count physical links only** (`en*`, AirDrop's `awdl`/`llw`, cellular). Traffic through a VPN also crosses the link under it, and a bridge repeats its members; counting those would count the same bytes twice.
- **Per-app traffic is an estimate.** A sample is the bytes carried by each process's open connections, and the rate is the change since the sample before. A process that closes connections sees its total drop; for that one sample its rate is carried over at half strength. With a tunnel up, the same bytes appear under the app and under the tunnel's own process, so the bar scales the apps to what the interfaces actually carried. Left running in its logging mode `nettop` spins a full core, so each sample is a fresh one-shot (about 40 ms of CPU), taken every two seconds on the Network area, every four on the dashboard, and never while neither is on screen.
- **macOS withholds some things from apps.** The Wi-Fi network name needs Location access, which Dotmeter does not ask for. The Wi-Fi hardware address comes back as a placeholder and is shown as private. On the Mac this was built on, macOS reports no Wi-Fi signal strength at all (0 dBm, in System Information too), so the Wi-Fi card leads with the link rate and shows the signal chart only where a reading exists.
- Processes owned by root are invisible to libproc, so in the apps table they keep the name `nettop` gives them, cut to 15 characters.

SMC sensor names are undocumented. On an M3 Ultra the `Tp*`/`Te*`/`Tc*` keys were verified to track CPU load and `Tg*` the GPU; the `Tf*` family never moves under load, so it is listed in Settings but never used for the headline temperature. `kernel_task` and other root processes are not visible without privileges.

## Performance

Measured on a release build with the display awake:

| State | CPU | Memory |
| --- | --- | --- |
| Menu bar only, the dashboard icon | 0.4% | 60 MB |
| Menu bar only, live items updating every two seconds (all eight: 1.2%) | 0.6 to 1.3% | 60 MB |
| A panel open | about 2.4% | 55 MB |
| Window open on the Timeline or Ask Claude | 1.5% | 60 to 90 MB |
| Window open on most areas (Processor, with 32 core cells: 3.8%) | 2.5 to 3.8% | 105 to 160 MB |
| Window open on the Dashboard, eight live bars | 4.8% | 180 MB |

(Share of one core, from the process's accumulated CPU time over half a minute; memory is the footprint. Of the Dashboard's figure about a third is reading the system every two seconds, a third is SwiftUI laying out the new numbers, and the rest is the bars twinkling.)

Before the charts and the bars were reworked (see below), the Dashboard cost 10% and every page with a chart on it held 600 to 630 MB.

What keeps the menu bar cheap:

- **Hidden views are told nothing.** A hidden panel keeps its SwiftUI views, and every new reading used to rebuild them for nobody: with live items that was 4% of a core in the background. Readings are now published to views only while a panel or window is on screen; the menu bar items and the alerts read them from a side that nothing observes. This also took the plain icon's background cost from about 1% (once the window had been opened) to 0.3%.
- **A closed window is let go.** It used to keep its views, and with them about 100 MB, until the app quit. Closing it now releases the window; opening it again builds a new one on the same area at the saved frame.
- **Light passes.** While only the menu bar is showing, a pass reads the processor, memory and network counters, the power sensor, the fans and the five hottest die sensors: a few milliseconds. Recording the timeline rides on the same passes and costs nothing that can be measured. The full pass, with the process list (11 ms for 1,100 processes) and every sensor, drops back to every thirty seconds, and runs at once when a panel opens.
- **An item is redrawn only when its picture changes**, by comparing the lit cells and the text with what it last drew. This matters more than the drawing itself: touching a status item's button at all makes macOS redraw it and re-snapshot its copy for every other display, and with the window closed that was half of the app's main-thread time. The Dashboard icon used to be set again on every reading; it is now left alone unless its tint or figure changed.
- **Pages that show no apps get no process list.** On the Timeline, Login Items, Ask Claude and USB pages nothing on screen needs what only a full pass reads, so the counters keep their two-second pace (with the graphics load added, a tenth of a millisecond, so every figure in the sidebar stays live) and the full pass drops back to every ten seconds.
- **The ports are read when something is plugged in**, not on every pass (see the USB notes).
- **Lists are not sorted for nobody.** The alerts used to sort every app by memory and by energy on each reading, to have the top three ready for an event that starts about once a week. They are worked out when the condition holds.

Side by side with the build before these four, on the same Mac at the same time (about 1,480 processes running, which is why these are above the table's figures):

| State | Before | After |
| --- | --- | --- |
| Menu bar only: Dashboard, Storage and Network items | 0.96% | 0.75% |
| Menu bar only: Dashboard and USB items | n/a | 0.36% |
| Window open on USB | 2.00% | 1.25% |
| Window open on the Timeline | 1.68% | 1.04% |

The bars' twinkling cells are a tiny picture replaced ten times a second, and Core Animation used to re-render each one into its own memory before showing it, which cost more than working the cells out. The pixel order makes no difference to that, and neither does an untagged colour space. The colour space the picture is tagged with does: see the next section.

### A second round

Measured with the old and the new build running side by side in the same state, because readings of one build taken an hour apart differ by more than these changes do:

| State | Before | After |
| --- | --- | --- |
| Menu bar only, five live items | 1.17% · 29 MB | 1.19% · 30 MB |
| The same, items shown by layers of their own (off by default, see below) | 1.16% | 0.35% |
| A panel open | 3.03% · 54 MB | 2.81% · 56 MB |
| Window on the Dashboard | 5.93% · 149 MB | 5.72% · 138 MB |
| Window on Graphics | 3.23% · 82 MB | 2.94% · 72 MB |
| Window on Thermals | 3.22% · 93 MB | 3.17% · 82 MB |
| Window on Power | 3.11% · 102 MB | 2.86% · 93 MB |

The other pages moved by less than the readings scatter. What changed:

- **Pictures are made in the screen's own colour space** (`ScreenInk`). A picture handed to a layer in any other space is converted and copied by macOS on arrival, on this process's time: a bar's cells cost 30 µs to show in sRGB and 11 µs in the screen's space, a chart 917 µs against 315 µs (`Dotmeter --bench-contents`). It also means one copy of each picture in memory instead of two, which is where the ten megabytes went. macOS converts a see-through pixel after multiplying it by its alpha, so the colours are converted the same way here, and a picture comes out as it did before: exactly where a pixel is fully covered, within five levels of 255 on the antialiased edges of the dim dots, and only on a screen whose tone curve is not sRGB's. The bar's still render, which blends see-through fills inside one bitmap, stays in sRGB, and so do sprites that are made once.
- **The process list asks less.** A quarter of the processes may not be read by an ordinary user, and each was asked three times a pass; the rest were asked twice. Unreadable ones are now left alone and tried again every sixteenth pass, and a process already known, the same one by its pid and start time, keeps its name and parent. The list is the same; the pass makes about a third of the system calls.
- **The twinkle's noise is worked out per column**, not per cell: the same numbers to sixteen decimal places for an eighth of the arithmetic.
- **Moving the window by its background** makes macOS work out, after every change to the page, which parts can be dragged: half a percent of a core on the Dashboard. It is switched on only while the pointer is over the window.
- **Storage figures follow the disk without asking the volume on every tick**: only when the free space has moved by ten megabytes.

**Menu bar items by layer.** Giving a status item's button a new image makes AppKit draw the button, lay the item out again and draw it once more for the copies it keeps for other screens: about six milliseconds an item, every time a figure changes. `StatusFace` shows the picture through a layer of its own instead, and five live items then cost what the plain icon costs. It is matched to the button's own drawing from captures of the item windows (`DOTMETER_CAPTURE_ITEMS=<folder>`): the same width, ink at nine tenths as macOS inks a template, no font smoothing. It was tried beside the usual items on a real menu bar and looked the same, so it is how the items are drawn; side by side, five items went from 1.11% of a core to 0.38%. The way back is `DOTMETER_ITEM_DRAW=button` for one run, or `defaults write com.ysr.dotmeter menuBarLayers -bool false`. With more than one screen the items are drawn the usual way regardless, since the copies on other screens only follow a button that is asked to draw.

Getting there took the bar through three renderers, and the reasons are worth keeping:

- **SwiftUI `Canvas` in a `TimelineView`** cost about 4 ms per redraw regardless of what was drawn. Each tick ran an AppKit layout pass and a SwiftUI render for the whole hosting view. The animation schedule also holds a display link open at full refresh rate even when asked for ten updates a second.
- **CoreGraphics in a layer-backed view** was no better, for a different reason: CoreGraphics parallelizes compositing with `dispatch_apply`, and on a 32-core machine every draw woke about 32 threads that spin while waiting for work.
- **A bitmap for the static parts** (track, tint, dim dots, borders, glow), redrawn with CoreGraphics only when the data or the animation state changed, with the twinkling cells as a one-pixel-per-cell texture (148 × 22) updated ten times a second and scaled up by the GPU through a mask. A cell update costs 0.03 ms, and the cells still work this way. The bitmap did not last: every new reading moves a segment a little, so each bar redrew its base three or four times per reading, 2 ms a time plus a megabyte of bitmap sent to the window server. On the Dashboard's eight bars that was half of everything the app did.
- **What ships**: the static parts are composited from layers (`MatrixLiveLayers`), at rest as well as during a scan, a clear or an intro. The glow, the border and the filled shape are small stretchable sprites used as masks over one plain colour layer per segment, the halos and hairlines are sprites that only move, and the particles of a clear are written by hand into a bitmap the size of their bounding box. A change moves layers and sets colours, and at rest they are only touched when something changed. Nothing is rasterized by CoreGraphics on screen; `drawBase` stays the reference for the look and is what still renders use.
- **No SwiftUI `Canvas` anywhere.** One that redraws, on a timeline or simply on every new reading, makes SwiftUI keep a pool of GPU surfaces for as long as it is on screen: about 455 MB, at times 780 MB, however small the drawing, freed a few seconds after the last redraw and taken again on the next. Every chart and strip was a Canvas, so every page with one held that much. They are now pictures drawn with CoreGraphics into a bitmap and shown as an image (`BitmapPicture`), redrawn only when what they show has changed, and small ones that many rows share (a core cell, a table row's strip) are drawn once and reused. The spinner is eight layers whose opacity is stepped by the render server, and the draining strip in a row being cleared is one layer fed by a hand-filled bitmap.

Measured on the Storage page with demo data, release build:

| State | Before | After |
| --- | --- | --- |
| At rest | 2.6% | 1.8% |
| One row being cleared, big bar at rest | 9.0% | 2.8% |
| Clearing, big bar animating | 30% | 8.5% |
| Scanning | 45% | 31% |
| Memory while anything animates | 615 MB | 100 MB |

What is left during a scan is not drawing: the storage model reports progress about 16 times a second and SwiftUI rebuilds much of the page each time.

Other things that mattered: counting numbers re-lay out text every frame, so they only count during a scan or a clear; card shadows live on a static background shape, not on animating content; bars pause when their window is hidden or covered.

Measurement traps: nothing redraws while the display is asleep, so CPU readings taken then look far better than reality (`DOTMETER_LOG_FPS=1` prints the real update rate); graphics memory comes and goes, so one `footprint` reading can show 11 MB or 459 MB for the same page and has to be taken every few seconds; and the unsigned binary in `.build/` blocks on a Keychain prompt, so always test the signed bundle in `build/`.

## Debugging

```bash
BIN=build/Dotmeter.app/Contents/MacOS/Dotmeter
$BIN --dump                      # print every reading and SMC key
$BIN --dump --net                # the same, waiting long enough to include per-app network traffic
$BIN --net-test                  # check the byte-counter arithmetic: growth, a 4 GB wrap, resets
$BIN --ping-test                 # three echoes to the router and to the internet, as the Network area sends them
$BIN --agent-test                # load a throwaway launch agent, remove it the way Login Items does, clean up
$BIN --self-test quit            # quit a process and a hidden app that the test itself starts; refuse a protected one
$BIN --self-test events          # feed the event detector an hour of made-up readings and check what it notes
$BIN --self-test energy          # check the energy ledger, every period's total, an old file, and the dollar figures
$BIN --self-test speed           # one real speed test (fifteen seconds of real traffic)
$BIN --bench                     # time each collector: elapsed, and how much of it on a core
$BIN --usb                       # every port, cable, link, device and screen as text, with the verdicts
$BIN --usb --json                # the same as JSON, raw identity words and certificate number included
$BIN --self-test usb             # decoders, verdicts and the cable record, on made-up ports and a file of its own
$BIN --self-test uninstall       # the rule for what the helper may delete, and the search for leftovers, on a made-up app
open -n -W --stdout out.txt /Applications/Dotmeter.app --args --helper-test   # the helper for real, on locked made-up apps (asks for it if it is off)
$BIN --self-test openai          # the OpenAI request and stream parsing, without OpenAI
$BIN --self-test dashboard       # the rules for the Dashboard's card order
DOTMETER_PROVIDER=openai $BIN --analyze   # one analysis from GPT (the key from the Keychain, or DOTMETER_OPENAI_API_KEY)
$BIN --helper-state              # what macOS reports about the helper and whether it answers; changes nothing
$BIN --ports                     # every app listening for connections, as the Network page lists them
$BIN --watch-test                # arm the plug watcher for 15 s and print each change the registry reports
$BIN --watch-test IOMedia 20     # the same for another class: mount a disk image meanwhile to see it fire
$BIN --external-ip-test          # one real lookup of the external address; prints its kind, not the address
$BIN --update-check              # asks GitHub for the newest version and says whether this copy would offer it
$BIN --self-test update          # versions, GitHub's answer, the signature check; with DOTMETER_UPDATE_TEST_IMAGE, a real install on a scratch copy
$BIN --self-test wall            # the wall's grid for fourteen screen sizes, its font, and pixels read back from a render of the real layers
$BIN --self-test floating        # the floating meter's placement across made-up screens, its strings, its menu
$BIN --self-test card            # the week card's figures on a made-up week, its picture, and the empty and ten-minute cases
$BIN --self-test macs            # two Macs in one process over loopback: the handshake, a wrong code, readings, a Mac going quiet (50 s)
$BIN --self-test models          # decoding of each runner's recorded answers, process matching, the speed arithmetic
$BIN --self-test command         # the command's words and JSON shapes, the AI server fed lines in-process, no address in any output
$BIN --self-test watch           # crash report headers from fixtures, coalescing, the microphone rules on a fake source, one live read
$BIN --self-test health          # the SMART decoder on a made-up log, accessories from made-up entries, the low-battery event, one live read
$BIN status                      # the command itself: any of status, cpu, graphics, memory, thermals, network, power, storage, apps, usb, timeline
$BIN --bench-draw                # wall and CPU time per bar redraw, per pixel format
$BIN --scan-test /Applications   # time the disk walker on one folder
open -n -W build/Dotmeter.app --args --scan-report /tmp/report.txt   # full real scan, totals written to a file
$BIN --clear-test <temp folder>  # run the real delete path; refuses anything outside a temp directory
$BIN --remove-test <temp path> delete|trash   # single-item removal, same guard
DOTMETER_QUESTION="what is mds_stores?" $BIN --analyze   # ask one free-form question headlessly
$BIN --analyze                   # one structured analysis, headless
$BIN --render-card out.png scan  # the storage card alone at 2x: rest | scan | clearing | done
```

`--open` drives the UI for captures and measurement, controlled by environment variables:

| Variable | Effect |
| --- | --- |
| `DOTMETER_STORAGE_DEMO=1` | Storage card replays the reference recording's dataset and timing. Touches nothing on disk. |
| `DOTMETER_SHOW_WINDOW=1`, `DOTMETER_SHOW_PANEL=1` | Open the window or the panel. |
| `DOTMETER_SECTION=dashboard\|cpu\|gpu\|memory\|storage\|thermal\|network\|power\|timeline\|startup\|claude` | Open the window on that area. |
| `DOTMETER_TIMELINE_PATH=file` | Keep the timeline in that file instead of Application Support. Every test run should set it, so tests stay out of the real history. |
| `DOTMETER_TIMELINE_DEMO=1`, `DOTMETER_DEBUG_METRIC=heat\|cpu\|…` | A made-up week with events and speed tests, never written down; and which metric the Timeline opens on. |
| `DOTMETER_POWER_DEMO=laptop\|charging\|low\|full` | Reports a made-up MacBook in that state, which also turns on the Battery area, its menu bar item, and (with the timeline demo) a week of charge history. |
| `DOTMETER_ENERGY_PRICE=0.16`, `DOTMETER_ENERGY_PERIOD=today\|week\|month\|year\|all` | A price per kWh and a period for one run, without saving either. With the timeline demo there are five months of made-up days behind them. |
| `DOTMETER_SETTINGS_SCROLL=alerts` | With `DOTMETER_CAPTURE_SETTINGS`: open the form at the notifications section. |
| `DOTMETER_UPDATE_DEMO=available` | A made-up release in that state (`available`, `downloading`, `verifying`, `restarting`, `failed`, `byhand`, `current`, `checking`, `unreachable`). Nothing is asked or installed. |
| `DOTMETER_CAPTURE_UPDATE=path` | Write the update window as it stands. |
| `DOTMETER_UPDATE_FEED=<url or path>` | Read the newest release from there instead of GitHub; its image may be a file or a server on this Mac. Nothing is saved from such a run. |
| `DOTMETER_UPDATE_AUTO=1` | With `DOTMETER_UPDATE_FEED`: press Install as soon as a newer version is found. |
| `DOTMETER_THEME=amber` | The dot colour for one run (`color`, `amber`, `green`, `white`), not saved. |
| `DOTMETER_CAPTURE_WALL=out.png` | Render the wall offscreen at `DOTMETER_WALL_SIZE=3840x2160` (pixels; default 1920x1080). `DOTMETER_WALL_DEMO=1` shows made-up readings; `DOTMETER_SHOW_WALL=1` opens it for real; `DOTMETER_WALL_CLOSE_AFTER=<seconds>`; `DOTMETER_WALL_SCREEN`, `DOTMETER_WALL_AWAKE=on\|off` set its settings for one run. |
| `DOTMETER_FLOATING=on\|off` | The floating meter for one run, not saved. Always set it in a test run, or the run follows and may change the saved choice. `DOTMETER_FLOATING_DEMO=1`, `DOTMETER_FLOATING_FIGURES=cpu,gpu,temperature,power,memory,network`, `DOTMETER_FLOATING_OPACITY=0.55`, `DOTMETER_FLOATING_CLICK_THROUGH=on\|off`, `DOTMETER_CAPTURE_FLOATING=out.png`. |
| `DOTMETER_CAPTURE_CARD=out.png` | Write the week card (with `DOTMETER_TIMELINE_DEMO=1`, a made-up week). `DOTMETER_CAPTURE_CARD_WINDOW=out.png` writes its window; `DOTMETER_CARD_LIGHT=heat\|cpu\|power`, `DOTMETER_CARD_APPS=0\|1`, `DOTMETER_CARD_HISTORY=<minutes>`, `DOTMETER_CARD_MAC="model\|chip"`. |
| `DOTMETER_MACS_DEMO=1` | Made-up Macs on the Macs page, nothing on the network. For a real exchange without Bonjour: `DOTMETER_MACS=on DOTMETER_MACS_CODE=<code> DOTMETER_MACS_LOOPBACK=<port>` on one copy and `DOTMETER_MACS_PEER=127.0.0.1:<port>` on the other. `DOTMETER_MACS=on` alone uses real Bonjour and makes macOS ask about the local network: never in an automated run. |
| `DOTMETER_MODELS_DEMO=1` | Invented runners and models on the Models page (`=empty` for nothing found). `DOTMETER_OLLAMA_BASE`, `DOTMETER_LMSTUDIO_BASE`, `DOTMETER_LOCALSERVER_BASE` point a reader at a stand-in on this Mac (or `off`); `DOTMETER_MODELS_SPEED=<model>\|first` presses Speed, on demo data or a stand-in only. |
| `DOTMETER_COMMAND_DEMO=1` | Made-up data for a command, and an install path in Settings in place of this copy's. `DOTMETER_LOG_COMMAND=1` prints how long each part of a reading took. |
| `DOTMETER_HEALTH_DEMO=1` | An invented drive record and three invented accessories. `DOTMETER_ACCESSORY_SOURCES=0` leaves the system's accessory list out. |
| `DOTMETER_WATCH=off` | No microphone, camera or crash watching for the run. `DOTMETER_WATCH_DEMO=mic\|camera\|both` pretends something is in use; `DOTMETER_CRASH_FOLDER=<path>` reads reports from there; `DOTMETER_LOG_WATCH=1` prints every change. |
| `DOTMETER_SPEED_DEMO=1`, `DOTMETER_DEBUG_SPEED=1`, `DOTMETER_SPEED_DEMO_HOLD=1` | Play a made-up speed test without touching the network; start a test on launch; keep it in its running state. |
| `DOTMETER_DEBUG_EXPLAIN=1` | Press Explain on whatever page or panel is shown (with `DOTMETER_MOCK_ANALYSIS=1`, a canned answer). |
| `DOTMETER_SCROLL=<points>` | Shift every page up by that much, to capture what is below the fold. |
| `DOTMETER_LOG_POWER=1` | With `--dump`: list every power channel, including those that are not energies. |
| `DOTMETER_NET_DEMO=1` | Replaces the network readings with a busy made-up connection (documentation addresses, five minutes of history), for design review and captures. |
| `DOTMETER_MENU_ITEMS=dashboard,cpu,network`, `DOTMETER_MENU_STYLE=graph\|icon\|compact` | Choose the menu bar items and their style for one run, without saving the choice. |
| `DOTMETER_PANEL=<area>` | With `DOTMETER_SHOW_PANEL` or `DOTMETER_CAPTURE_PANEL`: open that area's panel instead of the dashboard's. |
| `DOTMETER_CAPTURE_MENUBAR=path` | Write every area's menu bar item in every style, on a dark and a light strip. The menu bar itself cannot be captured. |
| `DOTMETER_LOG_ITEMS=1\|2`, `DOTMETER_DEBUG_TOGGLE=cpu,network` | Print where each item sits and where its panel opened (2: once a second); add or remove items at run time and print the result. |
| `DOTMETER_WINDOW_SIZE=1458x1380` | Open the window at that content size and leave the saved frame alone. |
| `DOTMETER_LOG_COST=1` | Print how long each pass took to collect and to publish, and whether it was a light or a full one. |
| `DOTMETER_CAPTURE_WINDOW=path`, `DOTMETER_CAPTURE_PANEL=path` | Write a PNG of it after `DOTMETER_CAPTURE_DELAY` seconds. |
| `DOTMETER_CAPTURE_SEQ=dir`, `DOTMETER_SCRIPT=scan\|clear\|item` | Run a scripted scan, clear, or single-item removal (`DOTMETER_DEBUG_ITEM=<name>`, demo data only) and write frames every `DOTMETER_SEQ_INTERVAL` ms. |
| `DOTMETER_PIN_PANEL=1`, `DOTMETER_FORCE_ACTIVE=1` | Keep the panel open and the window animating regardless of clicks or occlusion. |
| `DOTMETER_MOCK_ANALYSIS=1`, `DOTMETER_DEBUG_ANALYZE=1` | Stream a canned report without an API key. |
| `DOTMETER_PROVIDER=anthropic\|openai` | Choose who answers for one run, without saving the choice. |
| `DOTMETER_OPENAI_BASE=http://127.0.0.1:<port>/v1` | Send OpenAI requests to a stand-in on this Mac. Only this Mac is accepted, so a key can never be pointed elsewhere. |
| `DOTMETER_DEBUG_ASK=<question>` | Ask that question on launch. |
| `DOTMETER_DEBUG_CATEGORY=<id>`, `DOTMETER_DEBUG_ARM=<item name>` | Storage page opens on that category, with that row waiting for its second click (demo data only). |
| `DOTMETER_DEBUG_BUSY=<cache name>`, `DOTMETER_DEBUG_PROGRESS=0.42` | Holds that cache row part-way through being cleared (demo data only). `DOTMETER_DEBUG_BUSY_ROW_ONLY=1` leaves the big bar at rest, to measure the row alone. |
| `DOTMETER_CLOSE_AFTER=<seconds>` | Closes the panel and window again after that long, to measure what the app costs in the background once they have been used. `DOTMETER_REOPEN_AFTER=<seconds>` then opens the window again and reports whether it had been released; `DOTMETER_REOPEN_CAPTURE=path` writes what it shows. |
| `DOTMETER_USB_DEMO=laptop\|slow` | Made-up ports: a dock with two screens, a charger on a cable that limits it, a fast drive on a charging cable; `slow` has the dock's link come up on one slow lane. Followed cables are made up too and nothing is saved. |
| `DOTMETER_USB_PORT=USB-C@3`, `DOTMETER_USB_HUBS=1`, `DOTMETER_USB_FOLLOW=<name>` | Open the USB page on that port, with hubs shown, and follow that port's cable under that name. |
| `DOTMETER_CABLES_PATH=<file>` | Where followed cables are kept. With `DOTMETER_TIMELINE_PATH` set and this not, they go beside that file, so a test run never touches the real record. |
| `--remove-test <path> trash\|delete` | Runs the single-item removal on a throwaway item: anything in a temp folder, or an app named exactly `/Applications/Dotmeter Removal Test.app`. To exercise the ask-the-Finder route, lock a throwaway app (`chmod 555`) and launch through LaunchServices, so that macOS attributes the request to Dotmeter and not to the terminal: `open -n -W --stdout out.txt build/Dotmeter.app --args --remove-test <path> trash`. |
| `DOTMETER_APPS_DEMO=1` | Made-up apps in place of the real ones, in shares that add up to this Mac's real load, memory and power. With `DOTMETER_NET_DEMO=1` the charts get a made-up past as well. |
| `DOTMETER_DASHBOARD_ORDER=network,thermal,cpu` | Show the Dashboard's cards in that order for one run, without saving it. Cards not named follow in their usual order. |
| `DOTMETER_DEBUG_APP_QUERY=<text>` | Open the Storage page with that typed into the Apps search. |
| `DOTMETER_DEBUG_DROP=<path to an app>` | Act as if that app had just been dropped on the Storage page. Its row asks; nothing is removed. |
| `DOTMETER_DEBUG_UNINSTALL=<app name>` | With the demo disk, shows that made-up app's row asking to be confirmed. With `DOTMETER_DEBUG_UNINSTALL_STATE=wait` or `run`: waiting for permission, or part-way through. |
| `DOTMETER_DEBUG_CLICKS=<area>` | Walks that area's menu bar item through open, second click, open again and a click elsewhere, and prints whether the panel is open after each. |
| `DOTMETER_BAR=cg` | Draws the bar's base with CoreGraphics instead of compositing it from layers (the old way), to compare the two pictures. |
| `DOTMETER_DEBUG_LOOP=scan` | Demo data only: scans again and again, to measure the scan animation. |
| `DOTMETER_COUNT=step` | Shows each new number as it arrives instead of counting to it, to measure what the counting costs. |
| `DOTMETER_DEBUG_HOVER=<item id>` | Start with a legend item hovered. |
| `DOTMETER_APPEARANCE=light\|dark`, `DOTMETER_STATIC=1`, `DOTMETER_LOG_FPS=1` | Force appearance, skip entrance animations, log update rate. |

## Layout

```
Sources/CDotmeter              C shim: libproc, rusage and the SMC parameter struct
Sources/DotmeterShared         What the app and its helper share: their messages and the rule for what may be deleted
Sources/DotmeterHelper         The uninstall helper, a launch daemon that runs with the system's rights
Sources/Dotmeter/App           AppKit shell: menu bar items and their renderer, floating panel, window, menus, quitting apps, debug tools
Sources/Dotmeter/Model         Snapshot types, SystemMonitor polling loop, settings, the timeline store, events and alerts, speed test, login items, updates
Sources/Dotmeter/Collectors    One sampler per subsystem
Sources/Dotmeter/Storage       Disk scanner, demo dataset, storage state machine
Sources/Dotmeter/Claude        Keychain, streaming client, prompts, report schema, analysis session, Explain
Sources/Dotmeter/UI/Pixel      The design kit: tokens, the dot-matrix bar, the meter card
Sources/Dotmeter/UI/Dashboard  Card models built from a snapshot, and Claude's card
Sources/Dotmeter/UI/Pages      Sidebar, page scaffold and the areas
Sources/Dotmeter/Wall          Wall mode and the floating meter
Sources/Dotmeter/WeekCard      The week card: its figures, its picture, its window
Sources/Dotmeter/Macs          Other Macs on the network: the protocol, the link, the page
Sources/Dotmeter/Runners       The Models area: local model runners and what they hold
Sources/Dotmeter/Command       The command line and the server for AI apps
Sources/Dotmeter/Health        Drive health and accessory batteries
Sources/Dotmeter/Watch         Microphone and camera use and app crashes, for the Timeline
Sources/Dotmeter/UI/Popover    Menu bar panels: the dashboard's overview and one per area
Scripts/build.sh             Build, bundle, sign, install
```
