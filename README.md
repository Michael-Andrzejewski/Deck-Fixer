# Deck Fixer

By **Soareverix**.

A Balatro deck that **merges any combination of other decks** (vanilla or modded) into one. Open the mod config, pick your decks, then play the **Deck Fixer** deck to get all of their effects at once.

## Picking decks

The mod config is a single page with a `< Controls / Decks N >` selector at the bottom (the same paging the in-game collection uses).

- **Controls** (first page): three buttons and a live summary of what is selected.
  - **Randomize** — selects a random 3 to 8 of your installed decks (the quick way to play a surprise assortment; press again to reroll).
  - **Select All** — merge everything you have.
  - **Clear** — start over.
- **Decks 1, Decks 2, ...**: grids of individual deck checkboxes, 18 per page. Page through them to hand-pick. Toggles, Randomize, and the buttons all stay in sync.

## How it works

For every deck you tick, Deck Fixer builds a real `Back` for that deck and runs its actual `apply_to_run()` path at run start. That is the exact code Balatro runs when you pick the deck, so everything integrates with no per-deck wiring:

- **All config fields** (vanilla and any Steamodded or modded extension): hands, discards, dollars, joker slots, hand size, consumable slots, reroll discount, no-face cards, erratic ranks/suits, ante scaling, spectral rate, boosters, no-interest, per-hand/discard money, and anything new a deck adds.
- **The deck's own `apply()`** function (how most modded decks do their work).
- **Name-gated vanilla cases** like Checkered's suit swap, for free.
- Scoring-time `calculate()` effects are chained from Deck Fixer's own, and Plasma's equalize is re-implemented.

Each deck's application runs inside a `pcall`, so one misbehaving deck can't break the run. New modded decks appear in the checklist automatically and merge through the same path.

## Requirements

- [Lovely](https://github.com/ethangreen-dev/lovely-injector) and [Steamodded](https://github.com/Steamodded/smods) (1.0.0-beta or newer).

## Install

Clone (or download + extract) into your Balatro `Mods` folder so the files sit directly inside a `DeckFixer` folder:

```
cd %AppData%\Balatro\Mods
git clone https://github.com/Michael-Andrzejewski/Deck-Fixer.git DeckFixer
```

## Known limitations (v1)

Bean's brief was "doesn't have to work with everything," and this is scoped to match.

- **Self-gating decks can't merge.** Some mods gate their behaviour on "is my deck the selected one" (checking `G.GAME.selected_back`). Those self-disable when merged, because the selected deck is Deck Fixer. This is inherent to any deck merger, not specific to this mod.
- **Name-gated scoring effects** merge only where re-implemented. **Plasma** (chips/mult equalize) is handled; **Anaglyph**'s post-boss double-tag is not.
- If several `calculate`-based decks are merged, the first to return a result for a given context wins.
- **Select All can combine mutually-incompatible decks.** A deck whose `apply` queues a deferred effect assuming it is the only deck (e.g. Silly Decks' Confused Deck rewriting every suit, or Discovered Deck looping over the deck expecting exactly 12 face cards) can clash with another or with itself. Deck Fixer guards this two ways: deferred events queued during a deck's apply *or* its scoring `calculate` are `pcall`-wrapped (a crashing event logs and completes instead of taking down the run), and invalid suit changes are skipped. These cover the common cases, but a merged deck left in a half-applied state may still behave oddly. Prefer **Randomize** or hand-picking over Select All for large modded collections.
- A deck that **hard-sets** an absolute value (e.g. forces a specific starting dollar amount) will overwrite rather than add.
- **Multiplayer decks are mergeable, but quirky.** The Multiplayer mod's decks (Gradient, Violet, ...) install global `Card` hooks that assume a clean board. Deck Fixer wraps those hooks (`calculate_joker`, `is_face`, `set_cost`) so they skip instead of crashing when they hit a card they do not expect. Skipping can leave a card in a slightly off state, so merged MP decks may behave oddly, but they will not take down the run. The Cocktail deck is the one exception: it is itself a deck-merger, so it stays excluded from the pool.
- Merging is applied on a **new run**. Continuing a save uses whatever was baked in when the run started.
- The deck art is a placeholder for now.

## Tested with

Vetted against these popular deck packs (109 decks total). The large majority merge correctly; the exceptions below are all the inherent "effect only fires when this deck is selected" type, and none of them crash the run (a non-mergeable deck simply no-ops).

| Pack | Decks | Result |
|---|---|---|
| Vanilla+ Decks | 3 | All merge |
| Shenanigans's Decks | 31 | All merge (Hieroglyph loses only its sleeve-paired bonus) |
| Silly Decks | 14 | Merge, except **Casino** (needs a run-start snapshot) |
| Ruina Decks | 9 | Merge, except **Hokma** (Lovely patch gated on selection) |
| Joshi's Decks | 8 | Merge, except **Legendary** (selection-gated hooks) |
| Too Many Decks | 42 | Merge, except **invisible, throwback, champ** and the gated parts of **tds, Joker, thereisnogod** |

Decks that hard-set a shop rate or rarity (e.g. some of Joshi's) overwrite rather than stack when combined with each other.
