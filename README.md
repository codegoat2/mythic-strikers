# MYTHIC STRIKERS
### Supernatural Multiplayer Football — Roblox Game

---

## What This Is

Mythic Strikers is a server-authoritative supernatural football game for Roblox.
Football is the foundation. Anime-style special techniques, elemental powers,
combination attacks, and Mythic Awakening are what make it extraordinary.

Players spawn in a **full explorable lobby world** — walk around, browse shops,
visit the trophy room, train in the dome, hang out in the canteen — then walk
through the Match Portal to join the football arena.

**Max server size: 40 players.**

---

## Project Structure

```
src/
├── ReplicatedStorage/
│   ├── Shared/
│   │   ├── Config/
│   │   │   ├── Constants.lua            — all tunable numbers (incl. MAX_SERVER_SIZE=40)
│   │   │   ├── MatchConfig.lua          — per-mode match settings (1v1 → 6v6)
│   │   │   └── DefaultAttributes.lua    — baseline player stats
│   │   ├── Types/
│   │   │   └── init.lua                 — exported type definitions
│   │   └── Techniques/
│   │       └── TechniqueDefinitions.lua — master library of 40+ original techniques
│   └── Remotes/
│       └── init.lua                     — all RemoteEvents + RemoteFunctions
│
├── ServerScriptService/
│   ├── ServerMain.lua                   — single server boot, wires all services
│   └── Services/
│       ├── BallService.lua              — server-authoritative ball physics
│       ├── TeamService.lua              — team assignment, colours, spawn points
│       ├── MatchService.lua             — full match lifecycle state machine
│       ├── PlayerService.lua            — DataStore profiles, stamina/energy/awakening
│       ├── ShopService.lua              — shop catalogue, purchase validation, daily bonus
│       ├── AntiExploitService.lua       — rate limiting, distance/possession validation
│       └── LobbyBuilder.lua            — procedural lobby world builder (Script)
│
├── StarterPlayer/
│   └── StarterPlayerScripts/
│       ├── ClientMain.lua               — single client boot script
│       └── Controllers/
│           ├── InputController.lua      — unified PC + mobile input, custom signals
│           ├── CameraController.lua     — football third-person camera + cinematic mode
│           ├── FootballController.lua   — translates input → server remotes, ball interp
│           ├── UIController.lua         — programmatic HUD + mobile virtual joystick
│           └── LobbyController.lua      — proximity prompts, shop/NPC interaction
│
├── StarterGui/
│   └── UI/
│       └── ShopUI.lua                   — shop screen, emote picker, leaderboard, stats
│
└── Workspace/
    └── Stadium/
        └── StadiumBuilder.lua           — procedural stadium, pitch, goals, lighting
```

---

## Roblox Studio Setup

### 1 — Script types

| File | Roblox type | Location |
|---|---|---|
| `ServerMain.lua` | **Script** | ServerScriptService |
| `StadiumBuilder.lua` | **Script** | ServerScriptService → Services |
| `LobbyBuilder.lua` | **Script** | ServerScriptService → Services |
| `ClientMain.lua` | **LocalScript** | StarterPlayer → StarterPlayerScripts |
| `ShopUI.lua` | **ModuleScript** | StarterGui → UI |
| Everything else (`*.lua`) | **ModuleScript** | matching folder structure |

### 2 — Execution order

Both `StadiumBuilder` and `LobbyBuilder` are Scripts under `Services` — they run
at server start and build the world before `ServerMain` needs it. `ServerMain`
waits up to 20 s for `Workspace.Stadium` and 15 s for `Workspace.Lobby`.

### 3 — Max players

In Studio: **Game Settings → Players → Max Players → 40**.

The server also enforces this in `ServerMain` via `enforceMaxPlayers()` which
kicks any player that pushes the count above `Constants.MAX_SERVER_SIZE`.

### 4 — Test

Set **Players → MaxPlayers** to at least 2.
Press **Play** in Studio using **Team Test** with 2 local players.

To test solo, set `MIN_PLAYERS_TO_START = 1` in `ServerMain.lua`.

Players spawn in the **lobby** at the `SpawnLobby_*` ring. Walk south along the
connector path to the **Match Portal** to enter the arena.

---

## Lobby World

Players start here every session. The world is built procedurally at runtime by
`LobbyBuilder.lua` — no pre-built Studio models needed.

### Layout

```
         [Training Dome]
               ↑
  [House Row]  [PLAZA]  [House Row]
         (fountain + lamps)
               ↓
      [Market Street / Shops]
               ↓
        [Lobby Spawn Ring]
               ↓
    ── Connector Path (lamp-lined) ──
               ↓
          [Match Portal]  →  Stadium
```

### Buildings

| Building | Interact | What you can do |
|---|---|---|
| **6 × Player Houses** | Walk through door | Explore furnished interior, view player board |
| **Technique Shop** ⚡ | Enter / Talk to NPC | Browse & buy technique VFX skins |
| **Gear Shop** 👟 | Enter / Talk to NPC | Browse & buy boots, gloves, ball skins, celebrations |
| **Aura Shop** ✨ | Enter / Talk to NPC | Browse & buy awakening aura effects |
| **Locker Room** 🎒 | Enter / Talk to NPC | Expand technique slots (purchasable) |
| **Trophy Room** 🏆 | Enter door | View trophy pedestals, top-player leaderboard |
| **Training Dome** ⚽ | Enter door | Practice shooting/dribbling freely |
| **Canteen** 🍜 | Enter door | Social hangout; step on **Emote Zone** to open emote picker |
| **Notice Board** 📋 | Read | Upcoming quests, events, unlock requirements |
| **Match Portal** ▶ | Activate | Confirm dialog → joins match queue |

### Interaction

Every interactive object has:
- A `ProximityPrompt` (walk up and press to activate)
- A `StringValue` named `InteractType` (read by `LobbyController`)
- A floating `BillboardGui` label above it

Lobby prompts are **automatically disabled** while a match is Active or in
Countdown/HalfTime, so the UI doesn't clutter gameplay.

---

## Shop System

### How it works

1. Player walks up to a shop door or NPC and activates the ProximityPrompt.
2. `LobbyController` fires `OpenShop` remote to server with the shop type.
3. `ShopService` builds a filtered catalogue (ownership flags, can-afford flags)
   and fires `ShopCatalogueUpdate` back to the client.
4. `ShopUI` renders the shop screen with item cards, tier badges, and buy buttons.
5. Player clicks **Buy** → client fires `ShopPurchase` with item ID only.
6. `ShopService` re-validates on server (coins, ownership, item exists) and
   deducts coins via `PlayerService`. Never trusts the client coin count.
7. `ShopPurchaseResult` fires back — success or failure with reason.
8. `UIController` shows a toast notification. Shop screen refreshes.

### Catalogue (24 items at launch)

| Shop | Items |
|---|---|
| **Technique Shop** | 6 VFX reskins — Golden Solar Fang, Violet Thunder Comet, Crimson Void Cannon, Rainbow Celestial Break, Shadow Phantom Dash, Cosmic Nova Pack |
| **Gear Shop** | 7 items — Inferno/Thunder/Void Boots, Solar/Cosmic Ball Skins, Titan/Celestial Gloves, Power Pose/Thunder Dance/Cosmic Burst celebrations |
| **Aura Shop** | 5 auras — Blaze, Storm, Shadow Shroud, Galaxy, Prismatic (Mythic tier) |
| **Locker Room** | Extra Technique Slot (500 coins) |

### Daily Bonus

Every player receives **+50 coins** on their first join each calendar day.
The claim is recorded per-profile in `Statistics["DailyBonus_YYYY-MM-DD"]`
so it cannot be claimed twice. A toast notification confirms it.

### Currency

All items currently use **Coins** (in-game currency earned through matches).
Robux items are stubbed and return a "coming in Phase 9" message.

---

## Controls

### PC

| Input | Action |
|---|---|
| WASD / Arrow Keys | Move |
| Left Shift | Sprint |
| F | Pass |
| LMB (hold + release) | Shoot / charged shot |
| G | Tackle |
| Q / E / R / T | Technique slots 1–4 |
| Z | Mythic Awakening |
| V | Celebration |
| RMB drag | Orbit camera |

### Mobile

| Control | Action |
|---|---|
| Left virtual joystick | Move |
| PASS / SHOOT / SPRINT / TACKLE buttons | Football actions |
| T1–T4 buttons | Technique slots |
| ⚡ button | Mythic Awakening |
| One-finger right-side drag | Orbit camera |

---

## Architecture Decisions

### Server authority
All game state — ball, goals, score, timer, coins, purchases, rank — is
resolved server-side. Clients send requests; the server validates and replies.

### No client physics ownership
`Ball:SetNetworkOwner(nil)` ensures the server controls all ball physics.
Clients receive `BallStateUpdate` at 20 hz and interpolate locally.

### Dependency injection
Services that would create circular requires use injected callbacks and
setter functions (`SetStatProvider`, `SetEnergyCallback`, `SetPlayerService`).

### Modular remotes
All remote names are in `Constants.Remotes`. `Remotes.Get()` is the only
access path — no loose string literals in service code.

### Anti-exploit
`AntiExploitService` validates every remote call:
- Rate buckets (30 calls/s per player)
- Distance-to-ball checks
- Possession assertion
- Cooldown enforcement
- Violation counter → warn at 5, kick at 15

### Shop security
`ShopService` re-validates every purchase server-side. The client only sends
the item ID. Coin balance, ownership, and item existence are all checked
against the server-held `PlayerProfile` before any deduction occurs.

---

## Phase Roadmap

| Phase | Status | Contents |
|---|---|---|
| **1 — Core Football** | ✅ Complete | Movement, ball, possession, pass, shoot, tackle, goals, score, timer, teams |
| **1b — Lobby World** | ✅ Complete | 6 houses, 4 shops, trophy room, training dome, canteen, 40-player server, shop system |
| 2 — Football Polish | Pending | Sprint feel, curve shots, GK positioning, ball physics tuning, animations |
| 3 — Mythic System | Pending | Mythic Energy, basic techniques, elemental VFX, cooldown UI |
| 4 — Supernatural Football | Pending | Advanced/Ultimate/Mythic techniques, GK techniques, combination system, cinematic mode |
| 5 — Awakening | Pending | Awakening meter, Mythic Awakening activation, aura VFX |
| 6 — Multiplayer | Pending | Matchmaking, reserved servers, reconnect, mode select |
| 7 — Progression | Pending | XP, levels, quests, achievements, leaderboards, ranked |
| 8 — Customisation | Pending | Player style, aura equip UI, loadout screen |
| 9 — Monetisation | Pending | Game Passes, Developer Products, Robux shop items |
| 10 — Polish | Pending | Animations, VFX/SFX pass, tutorial, mobile optimisation, perf audit |

---

## Technique Library (defined, executable in Phase 3)

40+ original techniques across all types and tiers:

| Type | Examples |
|---|---|
| **Shoot** | Solar Fang · Thunder Comet · Meteor Spiral · Void Cannon · Cosmic Oblivion |
| **Dribble** | Phantom Dash · Mirage Step · Flash Spiral · Astral Glide |
| **Pass** | Starline Pass · Thunder Thread · Aurora Feed |
| **Tackle** | Thunder Crash · Gravity Sweep · Earthquake Tackle |
| **Block** | Titan Wall · Phantom Barrier · Crystal Lock |
| **Goalkeeper** | Titan's Fortress · Celestial Hands · Astral Shield |
| **Combination** | Solar Cyclone · Thunder Inferno · Frozen Torrent · Celestial Nova |

---

## Element System

10 elements: `Fire` · `Lightning` · `Wind` · `Earth` · `Water` · `Ice` · `Shadow` · `Light` · `Void` · `Cosmic`

Not rock-paper-scissors — elements define visual identity and interact through
the technique counter system built in Phase 4.

---

## DataStore

Key: `MythicStrikers_PlayerProfiles_v1`

Stores: Level, XP, Coins, Rank, Goals, Assists, Saves, Tackles, MatchesPlayed,
Wins, Losses, RankedRating, EquippedTechniques, **Cosmetics** (owned shop items),
Attributes, Statistics (daily bonus claims, etc.).

Saves on: player leave · 60 s auto-save · `BindToClose` shutdown flush.
Retry: 3× with 2 s delay. Uses `UpdateAsync` for atomic writes.

---

## Known Limitations (by design — fixed in later phases)

- Techniques are defined and equipped but **not yet executable** — Phase 3
- VFX/SFX asset IDs are string tags — wired to real assets in Phase 3/4
- NPC shop keepers are static geometry — animated NPCs in Phase 10
- Leaderboard shows current-session players only — full DataStore query in Phase 7
- Matchmaking is threshold auto-start — dedicated queue system in Phase 6
- Robux shop items return a stub — Phase 9 MarketplaceService integration

---

## License

All code, technique names, building designs, shop item names, and world-building
concepts are original works created for Mythic Strikers. No copyrighted characters,
names, special moves, or assets from existing franchises are used or referenced.
#   m y t h i c - s t r i k e r s  
 