# Deck Fixer

By **Soareverix**.

A Balatro deck that **merges any combination of other decks** (vanilla or modded) into one. Open the mod config, tick the decks you want in the compact checklist, then play the **Deck Fixer** deck to get all of their effects at once.

## How it works

For every deck you tick, Deck Fixer applies, at run start:

- **Config deltas** summed/merged into your run: extra hands, discards, dollars, joker slots, hand size, consumable slots, reroll discount, no-face cards, erratic ranks/suits, ante scaling, spectral rate, booster count, no-interest, and per-hand / per-discard money bonuses.
- **Starting content** queued the same way vanilla decks do it: starting jokers, consumables, vouchers, and deck-wide editions.
- A modded deck's own `apply()` and `calculate()` are called best-effort, so most modded decks come along for the ride.

## Requirements

- [Lovely](https://github.com/ethangreen-dev/lovely-injector) and [Steamodded](https://github.com/Steamodded/smods) (1.0.0-beta or newer).

## Install

Clone (or download + extract) into your Balatro `Mods` folder so the files sit directly inside a `DeckFixer` folder:

```
cd %AppData%\Balatro\Mods
git clone https://github.com/Michael-Andrzejewski/Deck-Fixer.git DeckFixer
```

## Known limitations (v1)

- Bean's brief was "doesn't have to work with everything," and this is scoped to match.
- Name-gated vanilla effects merge only where re-implemented here. **Checkered** (suit swap) and **Plasma** (chips/mult equalize) are handled; **Anaglyph**'s post-boss double-tag is not.
- If several `calculate`-based decks are merged, the first to return a result for a given context wins.
- Merging is applied on a **new run**. Continuing a save uses whatever was baked in when the run started.
- The deck art is a placeholder for now.
