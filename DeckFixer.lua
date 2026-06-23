--[[
  Deck Fixer
  Author: Soareverix

  A deck that merges any combination of other decks (vanilla or modded)
  into one. The mod config shows a compact checklist of every registered
  deck; tick the ones you want and play Deck Fixer to get all of their
  effects at once.

  How the merge works (per ticked deck):
    * config deltas (hands, discards, dollars, slots, hand size, etc.)
      are summed / merged into starting_params and modifiers, mirroring
      vanilla Back:apply_to_run.
    * event-based effects (starting jokers / consumables / vouchers /
      editions) are queued the same way vanilla decks queue them.
    * a modded deck's own apply()/calculate() are called best-effort
      (wrapped in pcall) so most modded decks come along for the ride.

  Known v1 limitations (Bean: "doesn't have to work with everything"):
    * Name-gated vanilla effects merge only where re-implemented here
      (Checkered suit-swap and Plasma equalize are handled; Anaglyph's
      double-tag is not).
    * If several calculate-based decks are merged, the first to return a
      result for a given context wins.
--]]

local DF_KEY = 'b_df_deckfixer'

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
-- Merge helpers (mirror vanilla Back:apply_to_run)
----------------------------------------------------------------------

-- Numeric / flag config deltas.
local function df_merge_config(c)
    local sp = G.GAME.starting_params
    if c.hands then sp.hands = sp.hands + c.hands end
    if c.dollars then sp.dollars = sp.dollars + c.dollars end
    if c.discards then sp.discards = sp.discards + c.discards end
    if c.joker_slot then sp.joker_slots = sp.joker_slots + c.joker_slot end
    if c.hand_size then sp.hand_size = sp.hand_size + c.hand_size end
    if c.consumable_slot then sp.consumable_slots = sp.consumable_slots + c.consumable_slot end
    if c.reroll_discount then sp.reroll_cost = sp.reroll_cost - c.reroll_discount end
    if c.remove_faces then sp.no_faces = true end
    if c.randomize_rank_suit then sp.erratic_suits_and_ranks = true end
    if c.ante_scaling then sp.ante_scaling = math.max(sp.ante_scaling or 1, c.ante_scaling) end
    if c.boosters_in_shop then sp.boosters_in_shop = c.boosters_in_shop end
    if c.spectral_rate then G.GAME.spectral_rate = math.max(G.GAME.spectral_rate or 0, c.spectral_rate) end
    if c.no_interest then G.GAME.modifiers.no_interest = true end
    if c.extra_hand_bonus then
        G.GAME.modifiers.money_per_hand = (G.GAME.modifiers.money_per_hand or 0) + c.extra_hand_bonus
    end
    if c.extra_discard_bonus then
        G.GAME.modifiers.money_per_discard = (G.GAME.modifiers.money_per_discard or 0) + c.extra_discard_bonus
    end
end

-- Event-queued starting content: vouchers, jokers, consumables, editions.
local function df_merge_events(c)
    if c.voucher then
        G.GAME.used_vouchers[c.voucher] = true
        G.GAME.starting_voucher_count = (G.GAME.starting_voucher_count or 0) + 1
        G.E_MANAGER:add_event(Event({ func = function()
            Card.apply_to_run(nil, G.P_CENTERS[c.voucher]); return true
        end }))
    end
    if c.vouchers then
        for _, v in pairs(c.vouchers) do
            G.GAME.used_vouchers[v] = true
            G.GAME.starting_voucher_count = (G.GAME.starting_voucher_count or 0) + 1
            G.E_MANAGER:add_event(Event({ func = function()
                Card.apply_to_run(nil, G.P_CENTERS[v]); return true
            end }))
        end
    end
    if c.jokers then
        G.E_MANAGER:add_event(Event({ func = function()
            for _, v in ipairs(c.jokers) do
                local card = create_card('Joker', G.jokers, nil, nil, nil, nil, v, 'deck')
                card:add_to_deck(); G.jokers:emplace(card); card:start_materialize()
            end
            return true
        end }))
    end
    if c.consumables then
        G.E_MANAGER:add_event(Event({ func = function()
            for _, v in ipairs(c.consumables) do
                local set = (G.P_CENTERS[v] and G.P_CENTERS[v].set) or 'Tarot'
                local card = create_card(set, G.consumeables, nil, nil, nil, nil, v, 'deck')
                card:add_to_deck(); G.consumeables:emplace(card)
            end
            return true
        end }))
    end
    if c.edition and c.edition_count then
        G.E_MANAGER:add_event(Event({ func = function()
            local i, guard = 0, 0
            while i < c.edition_count and guard < 500 do
                guard = guard + 1
                local card = pseudorandom_element(G.playing_cards, pseudoseed('df_edition_deck'))
                if card and not card.edition then
                    i = i + 1
                    card:set_edition({ [c.edition] = true }, nil, true)
                end
            end
            return true
        end }))
    end
end

-- Checkered Deck is name-gated in vanilla; re-implement its suit swap.
local function df_checkered_suits()
    G.E_MANAGER:add_event(Event({ func = function()
        for _, v in pairs(G.playing_cards or {}) do
            if v.base.suit == 'Clubs' then v:change_suit('Spades') end
            if v.base.suit == 'Diamonds' then v:change_suit('Hearts') end
        end
        return true
    end }))
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
        for _, key in ipairs(df_enabled_decks()) do
            local center = G.P_CENTERS[key]
            if center then
                local c = center.config or {}
                df_merge_config(c)
                df_merge_events(c)
                -- Modded decks: run their own apply best-effort.
                if type(center.apply) == 'function' then
                    pcall(function() center.apply(center, self) end)
                end
                -- Name-gated vanilla special cases.
                if key == 'b_checkered' then df_checkered_suits() end
            end
        end
    end,

    calculate = function(self, back, context)
        -- Chain modded decks' calculate; first result for a context wins.
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

        -- Collect every registered back except Deck Fixer itself.
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
            return { n = G.UIT.C, config = { align = 'cl', padding = 0.04, minw = 3.2 }, nodes = {
                create_toggle({
                    label = center.name or center.key,
                    label_scale = 0.3,
                    w = 1.6,
                    ref_table = cfg.decks,
                    ref_value = center.key,
                }),
            } }
        end

        -- Two columns per row.
        local rows = {}
        for i = 1, #decks, 2 do
            local nodes = { cell(decks[i]) }
            if decks[i + 1] then nodes[#nodes + 1] = cell(decks[i + 1]) end
            rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.01 }, nodes = nodes }
        end

        local body = {
            { n = G.UIT.R, config = { align = 'cm', padding = 0.04 }, nodes = {
                { n = G.UIT.T, config = {
                    text = 'Tick the decks to merge, then play Deck Fixer:',
                    scale = 0.36, colour = G.C.UI.TEXT_LIGHT,
                } },
            } },
        }
        for _, r in ipairs(rows) do body[#body + 1] = r end

        return { n = G.UIT.ROOT, config = { align = 'cm', padding = 0.02, colour = G.C.CLEAR }, nodes = body }
    end
end
