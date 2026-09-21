# MacroDeploy

**Bake a character's macros, action bars and keybindings into a file, then redeploy the whole layout onto a fresh character in one command.**

Rerolling alts and twinks means rebuilding the same bars every time: recreate the macros, drag every spell and macro back to the right slot, redo the keybinds. MacroDeploy captures a *template* character's full setup once, bakes it into `Profile.lua`, and replays it onto any new character — including the classic trick of placing macros on the bar *before* their spells are even learned.

## Why it works

In WoW you can drag a **macro** onto an action slot even when the spell it casts is not yet trained. A level‑1 character can therefore carry a complete, correctly‑placed bar from the very first login, and each button lights up the moment you learn its spell. MacroDeploy automates that: it (re)creates any missing macros, places everything by name, and quietly parks anything not yet placeable — an unlearned spell, a missing item — in a retry queue that fills it in as you level.

## Installation

Clone (or download) directly into your AddOns folder so the addon lands at `Interface/AddOns/MacroDeploy/`:

```sh
cd "/path/to/World of Warcraft/_classic_beta_/Interface/AddOns"
git clone https://github.com/hybris-code/MacroDeploy.git
```

Or download the ZIP and extract it there. The `.toc` must sit **directly** inside `Interface/AddOns/MacroDeploy/` — not double‑nested (`.../MacroDeploy/MacroDeploy/`), which will not load.

Enable **MacroDeploy** in the character‑select AddOns list, then `/md diag` in‑game to confirm it loaded and that every required API resolved.

## Quick start

1. On a **template character** — the one whose bars, macros and keybinds you want to clone — set everything up by hand.
2. Run `/md export`. A window opens with the full replacement text for `Profile.lua`.
3. Copy it, paste it over `Profile.lua`, save.
4. Copy the `MacroDeploy` folder to the target client's AddOns folder (if it's a different install).
5. On a **fresh character**, run `/md scan` to preview, then `/md apply`.

## Commands

| Command | What it does |
| --- | --- |
| `/md export` | Dump this character's macros, action slots and bindings as a new `Profile.lua`. |
| `/md scan` | Dry run — what *would* be deployed, and whether the guards pass or block. Writes nothing. |
| `/md apply` | Deploy the baked profile (guards enforced). |
| `/md apply force` | Deploy, ignoring all guards. |
| `/md retry` | Re‑attempt slots still waiting on unlearned spells / missing items. |
| `/md diag` | Client build and API‑availability check. |

`/macrodeploy` is a long‑form alias; `/md deploy` and `/md dryrun` are accepted synonyms for `apply` and `scan`.

## The profile (`Profile.lua`)

`Profile.lua` is the **only** file you regenerate. It is plain Lua data — no SavedVariables — so it survives clients that don't persist saved variables between sessions. The bundled copy is an empty template; `/md export` fills these tables:

- `P.macros` — `{ name, icon, perChar, body }` per macro.
- `P.actions` — `slot → { kind = "macro" | "spell" | "item", name | id }`.
- `P.bindings` — `{ key, action }` per binding.
- `P.meta` — who/what/when it was exported from.
- `P.guards` / `P.options` — see below.

### Guards (safety)

Deployment is blocked unless every guard passes; override with `/md apply force`.

| Guard | Default | Meaning |
| --- | --- | --- |
| `autoApply` | `false` | Auto‑deploy on a character's first login. |
| `maxLevel` | `5` | Only deploy at or below this level. |
| `requireEmptyBars` | `true` | Only deploy when the bars are essentially empty… |
| `emptyBarsRatio` | `0.9` | …i.e. at least this fraction of profiled slots are free. |
| `requireClass` | `nil` | Restrict to a class token, e.g. `"WARLOCK"`. |
| `realmWhitelist` | `nil` | Restrict to specific realms. |
| `loginDelay` | `3` | Seconds to wait after login before an auto‑deploy. |

`requireEmptyBars` is the main re‑run guard: it stops the addon from clobbering a character you've already set up.

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `overwriteMacros` | `true` | Update existing macros to match the profile body. |
| `overwriteSlots` | `false` | Replace actions already sitting in a target slot. |
| `includeSpells` | `true` | Place bare spell actions. |
| `includeItems` | `true` | Place bare item actions. |
| `includeBindings` | `true` | Apply keybindings. |
| `bindingSet` | `1` | `1` = account bindings, `2` = character bindings. |
| `retryQueue` | `true` | Park unplaceable actions and fill them as spells/items appear. |
| `verbosity` | `1` | Chat output level. |

## How deployment works

- **Macros first, by name.** Missing macros are created (respecting the 120‑account / 18‑character pools, 16‑char names, 255‑char bodies); actions are then placed by macro *name*, never by a fragile index.
- **Deferred placement.** A slot whose spell isn't trained or whose item isn't in bags goes to a retry queue, replayed on `PLAYER_LEVEL_UP`, `SPELLS_CHANGED`, `LEARNED_SPELL_IN_TAB` / `LEARNED_SPELL_IN_SKILL_LINE` and `BAG_UPDATE_DELAYED`.
- **Full keybind sweep.** Bindings are read across the entire key × modifier space instead of walking `GetNumBindings()`, so `CLICK` bindings created by Bartender4 / ElvUI are captured too.
- **API compatibility shims.** Every API call resolves globals first, then `C_Spell` / `C_Item` / `C_ActionBar`; if a required API is missing the deploy aborts cleanly instead of half‑applying.
- **Combat‑safe.** `CreateMacro` / `PlaceAction` are protected, so a deploy requested in combat is queued until combat ends.

## Compatibility

Built and tested against the **"Forever" `_classic_beta_` client** (interface `16001` — a 12.0‑era API on a Classic shell). The `.toc` also lists retail interface numbers so it can load on current Retail.

Two client‑specific quirks are handled in code — worth knowing if you fork:

- **Event registration is `pcall`‑guarded.** This client raises a hard Lua error for an unknown event name, and `LEARNED_SPELL_IN_TAB` no longer exists here (superseded by `LEARNED_SPELL_IN_SKILL_LINE`). An unguarded register would abort the file before the slash commands are set up.
- **Macro‑slot names come from `GetActionText`.** On this client `GetActionInfo` returns a macro's *resolved spell id* rather than a macro index, so slot names are read with `GetActionText(slot)`.
- **Don't add `## AllowLoadGameType: retail, classic`** to the `.toc`. Those tokens don't exist on this client (valid ones: `standard, vanilla, tbc, wrath, cata, mists, camelot`); a mismatched line silently hides the addon from the AddOns list.

## Limitations

- It does **not** manage Bartender4 / ElvUI's own bar configuration (visibility, paging, state conditions). Those live outside Blizzard's action slots — export them from the bar addon's own profile string.
- Only Blizzard action‑slot contents, macros and keybindings are captured.

## License

[MIT](LICENSE) © hybris-code
