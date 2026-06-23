--[[
  Deck Fixer
  Author: Soareverix

  A deck that merges any combination of other decks (vanilla or modded)
  into one. The mod config shows a compact checklist of every registered
  deck; tick the ones you want and play Deck Fixer to get all of their
  effects at once.

  How the merge works:
    For each ticked deck we build a real Back instance and run its actual
    Back:apply_to_run() path -- the exact code Balatro runs when you pick
    that deck. That means every config field (vanilla AND any Steamodded
    or modded extension), the deck's own apply() function, and name-gated
    vanilla cases (Checkered's suit swap, etc.) all integrate for free,
    with no per-deck wiring on our side. New modded decks appear in the
    checklist automatically and merge through the same path. Each deck's
    apply runs inside a pcall so one misbehaving deck can't break the run.

  Scoring-time deck effects (Back:calculate / trigger_effect) only run on
  the selected back, so we ALSO chain each ticked deck's calculate() from
  our own, and re-implement Plasma's name-gated equalize.

  Known v1 limitations (Bean: "doesn't have to work with everything"):
    * Decks whose behaviour gates on "is MY deck selected" (some mods
      check G.GAME.selected_back) self-disable when merged. That is
      inherent to any deck merger and cannot be fixed from here.
    * Name-gated vanilla scoring effects merge only where re-implemented
      (Plasma equalize yes; Anaglyph's post-boss double-tag no).
    * If several calculate-based decks are merged, the first to return a
      result for a given context wins.
    * Conflicting absolute setters (a deck that hard-sets dollars/slots)
      will overwrite rather than add.
--]]

local DF_KEY = 'b_df_deckfixer'

local DF_DEBUG = false
local function df_log(msg)
    if not DF_DEBUG then return end
    if sendInfoMessage then sendInfoMessage(tostring(msg), 'DeckFixer') end
    print('DeckFixer: ' .. tostring(msg))
end

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------

local df_mod = SMODS.current_mod
if df_mod then
    df_mod.config = df_mod.config or {}
    df_mod.config.decks = df_mod.config.decks or {}
end

local function df_cfg()
    local c = (df_mod and df_mod.config) or { decks = {} }
    c.decks = c.decks or {}
    return c
end

local function df_deck_enabled(key)
    return df_cfg().decks[key] == true
end

-- Ticked decks that actually exist and are not Deck Fixer itself.
local function df_enabled_decks()
    local out = {}
    for key, on in pairs(df_cfg().decks) do
        if on and key ~= DF_KEY and G.P_CENTERS and G.P_CENTERS[key] then
            out[#out + 1] = key
        end
    end
    table.sort(out)
    return out
end

----------------------------------------------------------------------
-- Atlas + Deck
----------------------------------------------------------------------

SMODS.Atlas({
    key  = 'df_decks',
    path = 'df_deck.png',
    px   = 71,
    py   = 95,
})

SMODS.Back({
    key = 'deckfixer',
    name = 'Deck Fixer',
    atlas = 'df_decks',
    pos = { x = 0, y = 0 },
    config = {},
    unlocked = true,

    apply = function(self)
        -- Run each ticked deck's real application path. Back(center)
        -- copies the center's config; apply_to_run handles all config
        -- fields, the deck's own apply(), and name-gated vanilla cases.
        for _, key in ipairs(df_enabled_decks()) do
            local center = G.P_CENTERS[key]
            if center then
                local ok, err = pcall(function()
                    local deck_back = Back(center)
                    deck_back:apply_to_run()
                end)
                if not ok then
                    df_log(('deck %s failed to merge: %s'):format(key, tostring(err)))
                end
            end
        end
    end,

    calculate = function(self, back, context)
        -- Scoring-time effects: chain each ticked deck's calculate; the
        -- first to return a result for this context wins.
        for _, key in ipairs(df_enabled_decks()) do
            local center = G.P_CENTERS[key]
            if center and type(center.calculate) == 'function' then
                local ok, ret = pcall(function() return center.calculate(center, back, context) end)
                if ok and ret then return ret end
            end
        end
        -- Plasma equalize (name-gated in vanilla) when Plasma is ticked.
        if df_deck_enabled('b_plasma') and context.context == 'final_scoring_step' then
            local tot  = (context.chips or 0) + (context.mult or 0)
            local half = math.floor(tot / 2)
            context.chips = half
            context.mult  = half
            update_hand_text({ delay = 0 }, { chips = half, mult = half })
            return half, half
        end
    end,
})

----------------------------------------------------------------------
-- Config tab: compact checklist of every deck
----------------------------------------------------------------------

if df_mod then
    df_mod.config_tab = function()
        local cfg = df_cfg()

        -- Collect every registered back except Deck Fixer itself. This
        -- list is built fresh each time the tab opens, so any newly
        -- installed modded deck shows up automatically.
        local decks = {}
        for _, center in ipairs(G.P_CENTER_POOLS.Back or {}) do
            if center.key and center.key ~= DF_KEY then
                decks[#decks + 1] = center
            end
        end
        table.sort(decks, function(a, b)
            return (a.name or a.key) < (b.name or b.key)
        end)

        local function cell(center)
            return { n = G.UIT.C, config = { align = 'cl', padding = 0.03, minw = 3.0 }, nodes = {
                create_toggle({
                    label = center.name or center.key,
                    label_scale = 0.28,
                    w = 1.4,
                    ref_table = cfg.decks,
                    ref_value = center.key,
                }),
            } }
        end

        -- Three columns per row to stay compact even with many modded decks.
        local rows = {}
        for i = 1, #decks, 3 do
            local nodes = {}
            for j = i, math.min(i + 2, #decks) do
                nodes[#nodes + 1] = cell(decks[j])
            end
            rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.008 }, nodes = nodes }
        end

        local body = {
            { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
                { n = G.UIT.T, config = {
                    text = 'Tick the decks to merge, then play Deck Fixer:',
                    scale = 0.34, colour = G.C.UI.TEXT_LIGHT,
                } },
            } },
        }
        for _, r in ipairs(rows) do body[#body + 1] = r end

        return { n = G.UIT.ROOT, config = { align = 'cm', padding = 0.02, colour = G.C.CLEAR }, nodes = body }
    end
end
