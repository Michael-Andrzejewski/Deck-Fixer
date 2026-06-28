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

-- Decks excluded from merging, matched by key substring. Cocktail is the
-- Multiplayer mod's own deck-merger; nesting a merger inside Deck Fixer is
-- recursive and behaves strangely, so it stays out. Other Multiplayer
-- decks (Gradient, Violet, ...) ARE mergeable; their global hooks are
-- kept non-fatal by df_wrap_card_methods below.
local DF_EXCLUDED_KEYS = { 'cocktail' }

-- Can this deck be safely merged?
local function df_mergeable(center)
    if not (center and center.key) or center.key == DF_KEY then return false end
    for _, frag in ipairs(DF_EXCLUDED_KEYS) do
        if center.key:find(frag, 1, true) then return false end
    end
    return true
end

-- Is Deck Fixer the currently selected deck?
local function df_active()
    local sb = G.GAME and G.GAME.selected_back
    local center = sb and sb.effect and sb.effect.center
    return center and center.key == DF_KEY or false
end

-- Run fn() with E_MANAGER.add_event temporarily wrapped so any event a
-- merged deck queues -- whether in its apply or its calculate -- has its
-- func pcall-guarded. Wrapping at queue time bakes the guard into the
-- event, so it is protected whenever it later runs (apply events run
-- after run-start; calculate events run during scoring animation).
-- Restored immediately after fn so normal gameplay events are untouched.
-- Returns fn's return value (nil if fn errored synchronously).
local function df_with_guarded_events(fn)
    local mgr = G.E_MANAGER
    local orig_add = mgr and mgr.add_event
    if orig_add then
        mgr.add_event = function(self_mgr, event, ...)
            if event and type(event.func) == 'function' then
                local inner = event.func
                event.func = function(...)
                    local ok, ret = pcall(inner, ...)
                    if not ok then
                        df_log('merged-deck event errored (skipped): ' .. tostring(ret))
                        return true  -- complete the event so it does not retry
                    end
                    return ret
                end
            end
            return orig_add(self_mgr, event, ...)
        end
    end
    local ok, ret = pcall(fn)
    if orig_add then mgr.add_event = orig_add end
    if not ok then df_log('guarded block errored: ' .. tostring(ret)) end
    return ok and ret or nil
end

-- Lazy hook installation, done at run start so our wrappers sit on top of
-- every mod's override regardless of load order. Covers three things:
--   1. Crash guards on global Card methods that merged decks override and
--      that run outside the deferred-event guard (the Multiplayer mod's
--      Gradient does arithmetic on card.base.id, nil for a Joker).
--   2. Too Many Decks' Joker deck: free Jokers and Buffoon packs (its own
--      set_cost gate keys off being the selected deck, which we are not).
--   3. Joshi's Legendary deck: permanent Showman (its SMODS.showman
--      override keys off the selected deck).
-- All behaviour is gated on df_active() so non-Deck-Fixer runs are untouched.
local DF_GUARDED_METHODS = { 'calculate_joker', 'is_face' }
local df_hooks_installed = false
local function df_install_hooks()
    if df_hooks_installed then return end
    df_hooks_installed = true

    -- 1. Generic crash guards.
    for _, name in ipairs(DF_GUARDED_METHODS) do
        local orig = Card[name]
        if type(orig) == 'function' then
            Card[name] = function(self, ...)
                if not df_active() then return orig(self, ...) end
                local ok, a, b = pcall(orig, self, ...)
                if ok then return a, b end
                df_log(('Card:%s errored (skipped): %s'):format(name, tostring(a)))
                return nil
            end
        end
    end

    -- 2. set_cost: crash-guarded, plus TMD Joker free Jokers / Buffoon packs.
    local orig_set_cost = Card.set_cost
    if type(orig_set_cost) == 'function' then
        Card.set_cost = function(self, ...)
            if not df_active() then return orig_set_cost(self, ...) end
            local ok, ret = pcall(orig_set_cost, self, ...)
            if not ok then df_log('Card:set_cost errored (skipped): ' .. tostring(ret)) end
            if df_deck_enabled('b_SGTMD_Joker') and self.ability then
                if self.ability.set == 'Joker'
                   or (self.ability.set == 'Booster' and self.ability.name and self.ability.name:find('Buffoon')) then
                    self.cost = 0
                end
            end
            return ret
        end
    end

    -- 3. Joshi's Legendary: permanent Showman while it is ticked.
    if SMODS.showman then
        local orig_showman = SMODS.showman
        SMODS.showman = function(...)
            if df_active() and df_deck_enabled('b_JoDe_legendary') then return true end
            return orig_showman(...)
        end
    end
end

-- Ticked decks that are real, mergeable, and not Deck Fixer itself.
local function df_enabled_decks()
    local out = {}
    for key, on in pairs(df_cfg().decks) do
        if on and G.P_CENTERS and df_mergeable(G.P_CENTERS[key]) then
            out[#out + 1] = key
        end
    end
    table.sort(out)
    return out
end

-- A real Back instance per ticked deck, cached by key. Many deck
-- calculate() functions read their increment/value from
-- back.effect.config (e.g. Ruina's Hod uses back.effect.config.mult), so
-- when we chain a deck's calculate we must pass ITS own Back, not Deck
-- Fixer's (whose config is empty). Back(center) copies the center config.
local df_back_cache = {}
local function df_deck_back(center)
    local b = df_back_cache[center.key]
    if not b then
        b = Back(center)
        df_back_cache[center.key] = b
    end
    return b
end

-- Display name for a deck. Most modded backs store their name only in
-- localization, so try that first, then the center's name field, then
-- the raw key as a last resort.
local function df_deck_name(center_or_key)
    local center = type(center_or_key) == 'table' and center_or_key or G.P_CENTERS[center_or_key]
    local key = (type(center_or_key) == 'string') and center_or_key or (center and center.key)
    if not key then return tostring(center_or_key) end
    local ok, nm = pcall(function() return localize({ type = 'name_text', set = 'Back', key = key }) end)
    if ok and type(nm) == 'string' and nm ~= '' and nm ~= 'ERROR' and not nm:match('^b_') then
        return nm
    end
    if center and center.name and center.name ~= '' then return center.name end
    return key
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

    -- Dynamic hover description: list the currently-selected decks. Back:
    -- generate_UI calls loc_vars before localizing the description, so we
    -- rebuild this deck's text (and the parsed cache) from the live config
    -- each time it is shown. Capped so a huge Select-All stays readable.
    loc_vars = function(self, info_queue, card)
        local sel = df_enabled_decks()
        local lines = {}
        if #sel == 0 then
            lines = { 'No decks selected.', '{C:inactive}Pick some in the mod config.{}' }
        else
            lines[#lines + 1] = ('{C:attention}%d{} decks merged:'):format(#sel)
            local cap = 12
            for i = 1, math.min(cap, #sel) do
                lines[#lines + 1] = '{C:blue}' .. df_deck_name(sel[i]) .. '{}'
            end
            if #sel > cap then
                lines[#lines + 1] = ('{C:inactive}+%d more{}'):format(#sel - cap)
            end
        end
        local desc = G.localization and G.localization.descriptions
            and G.localization.descriptions.Back and G.localization.descriptions.Back[self.key]
        if desc and loc_parse_string then
            desc.text = lines
            desc.text_parsed = {}
            for _, line in ipairs(lines) do
                desc.text_parsed[#desc.text_parsed + 1] = loc_parse_string(line)
            end
        end
        return { vars = {} }
    end,

    apply = function(self)
        -- Install our global hooks now that every mod is loaded, so our
        -- wrappers sit on top of merged decks' overrides.
        df_install_hooks()

        -- New run: drop cached deck Backs so any deck that mutates its
        -- back.effect.config across rounds (e.g. Too Many Decks' ballot
        -- counter) starts fresh instead of carrying over from a prior run.
        for k in pairs(df_back_cache) do df_back_cache[k] = nil end

        -- Joshi's Legendary deck makes only Legendary Jokers appear by
        -- bumping the legendary rarity weight. Its own start_run hook resets
        -- that weight to 0 whenever it is NOT the selected deck (i.e. always,
        -- under Deck Fixer), so re-apply it in a deferred event that runs
        -- after start_run finishes. The deck's apply() (config + bans) is
        -- already handled by the merge below.
        if df_deck_enabled('b_JoDe_legendary') then
            G.E_MANAGER:add_event(Event({ func = function()
                local jt = SMODS.ObjectTypes and SMODS.ObjectTypes['Joker']
                if jt and jt.rarities and jt.rarities[4] then
                    jt.rarities[4].weight = 100
                end
                return true
            end }))
        end

        -- Run each ticked deck's real application path on its own cached
        -- Back, the same instance its calculate() will later receive, so
        -- apply() and calculate() share one config. apply_to_run handles
        -- all config fields, the deck's apply(), and name-gated cases.
        -- Deferred events these apply()s queue are guarded (merge-hostile
        -- decks like Silly's Discovered crash assuming a vanilla deck).
        df_with_guarded_events(function()
            for _, key in ipairs(df_enabled_decks()) do
                local center = G.P_CENTERS[key]
                if center then
                    local ok, err = pcall(function()
                        df_deck_back(center):apply_to_run()
                    end)
                    if not ok then
                        df_log(('deck %s failed to merge: %s'):format(key, tostring(err)))
                    end
                end
            end
        end)
    end,

    calculate = function(self, back, context)
        -- Scoring-time effects: chain each ticked deck's calculate; the
        -- first to return a result for this context wins. Steamodded's
        -- Back wrapper prefers center.calculate but falls back to the
        -- deprecated center.trigger_effect (different arity: it takes
        -- (center, args), not (center, back, args)). Some modded decks
        -- (e.g. Silly Decks' Busted) still use trigger_effect, so we
        -- mirror that fallback here. Wrapped so events a deck's calculate
        -- queues (e.g. Silly's Herculean re-bases scored cards in a
        -- deferred event that can hit a suitless card) can't crash the run.
        local result
        df_with_guarded_events(function()
            for _, key in ipairs(df_enabled_decks()) do
                local center = G.P_CENTERS[key]
                if center then
                    local ok, ret
                    if type(center.calculate) == 'function' then
                        -- Pass the deck's OWN Back so back.effect.config
                        -- reads the deck's config, not Deck Fixer's empty one.
                        ok, ret = pcall(function() return center.calculate(center, df_deck_back(center), context) end)
                    elseif type(center.trigger_effect) == 'function' then
                        ok, ret = pcall(function() return center.trigger_effect(center, context) end)
                    end
                    if ok and ret then result = ret; return end
                end
            end
        end)
        if result then return result end

        -- Anaglyph (name-gated in vanilla): a Double tag after each boss.
        -- Side effect only, no return, so it coexists with other decks.
        if df_deck_enabled('b_anaglyph') and context.context == 'eval'
           and G.GAME.last_blind and G.GAME.last_blind.boss then
            G.E_MANAGER:add_event(Event({ func = function()
                add_tag(Tag('tag_double'))
                play_sound('generic1', 0.9 + math.random() * 0.1, 0.8)
                play_sound('holo1', 1.2 + math.random() * 0.1, 0.4)
                return true
            end }))
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
-- Crash guard: invalid suit changes
--
-- Some merged decks rewrite card suits in deferred events that assume
-- they are the only deck (e.g. Silly Decks' Confused Deck double-prefixes
-- a suit into "sdecks_sdecks_Hearts??"). Those events run outside our
-- apply pcall, and Card:change_suit crashes on an unregistered suit
-- (card.lua indexes SMODS.Suits[new_suit].card_key). While Deck Fixer is
-- the active deck, skip a change to a suit that does not exist so a bad
-- deck combination degrades to a no-op instead of taking down the run.
----------------------------------------------------------------------
local df_orig_change_suit = Card.change_suit
function Card:change_suit(new_suit, ...)
    if df_active() and new_suit and SMODS and SMODS.Suits and not SMODS.Suits[new_suit] then
        df_log('skipped invalid suit change: ' .. tostring(new_suit))
        return
    end
    return df_orig_change_suit(self, new_suit, ...)
end

----------------------------------------------------------------------
-- Config tab: simple Clear / Randomize / Select-All controls
--
-- With 100+ modded decks a full checklist is unusable, so the tab is
-- driven by buttons plus a live summary line. Randomize is the main
-- workflow for "play a random assortment". The summary text re-reads its
-- ref each frame, so it updates instantly when a button is pressed.
----------------------------------------------------------------------

local df_ui = { summary = 'Selected: 0 decks' }

-- Keys of every mergeable registered back.
local function df_all_deck_keys()
    local keys = {}
    for _, center in ipairs(G.P_CENTER_POOLS.Back or {}) do
        if df_mergeable(center) then keys[#keys + 1] = center.key end
    end
    return keys
end

local function df_refresh_summary()
    local sel = df_enabled_decks()
    local n = #sel
    if n == 0 then
        df_ui.summary = 'Selected: 0 decks'
        return
    end
    local names = {}
    for i = 1, math.min(3, n) do
        names[i] = df_deck_name(sel[i])
    end
    local txt = ('Selected %d: %s'):format(n, table.concat(names, ', '))
    if n > 3 then txt = txt .. (', +%d more'):format(n - 3) end
    df_ui.summary = txt
end

G.FUNCS.df_clear = function()
    df_cfg().decks = {}
    df_refresh_summary()
end

G.FUNCS.df_select_all = function()
    local cfg = df_cfg()
    for _, key in ipairs(df_all_deck_keys()) do cfg.decks[key] = true end
    df_refresh_summary()
end

G.FUNCS.df_randomize = function()
    local cfg = df_cfg()
    cfg.decks = {}
    local keys = df_all_deck_keys()
    -- Fisher-Yates shuffle, then keep a random 3..8.
    for i = #keys, 2, -1 do
        local j = math.random(i)
        keys[i], keys[j] = keys[j], keys[i]
    end
    local count = math.min(#keys, math.random(3, 8))
    for i = 1, count do cfg.decks[keys[i]] = true end
    df_refresh_summary()
end

----------------------------------------------------------------------
-- Config tab with in-page pagination
--
-- One tab. Page 1 is the controls; pages 2..N are grids of deck toggles.
-- A "< Controls / Decks N >" cycle at the bottom swaps the content in
-- place by rebuilding the tab_contents UIBox (the same mechanism
-- Steamodded's collection/achievements pages use), so nothing spills off
-- the top of the screen like a row of tabs would.
----------------------------------------------------------------------

local DF_PER_PAGE = 18   -- deck toggles per page (3 columns x 6 rows)
local DF_COLS     = 3

-- All mergeable deck centers, sorted by display name.
local function df_deck_centers()
    local decks = {}
    for _, center in ipairs(G.P_CENTER_POOLS.Back or {}) do
        if df_mergeable(center) then decks[#decks + 1] = center end
    end
    table.sort(decks, function(a, b) return df_deck_name(a) < df_deck_name(b) end)
    return decks
end

local function df_deck_toggle(center)
    return { n = G.UIT.C, config = { align = 'cl', padding = 0.04, minw = 3.3 }, nodes = {
        create_toggle({
            label = df_deck_name(center),
            label_scale = 0.3,
            w = 1.2,
            ref_table = df_cfg().decks,
            ref_value = center.key,
        }),
    } }
end

-- Build the full tab definition for a given page (1 = controls).
local function df_build_config(page)
    page = tonumber(page) or 1
    local decks = df_deck_centers()
    local deck_pages = math.max(1, math.ceil(#decks / DF_PER_PAGE))
    local total = 1 + deck_pages
    if page < 1 then page = 1 end
    if page > total then page = total end

    local content = {}
    if page == 1 then
        df_refresh_summary()
        local function btn(label, func, colour)
            return UIBox_button({ label = { label }, button = func, colour = colour, minw = 2.4, scale = 0.42 })
        end
        content = {
            { n = G.UIT.R, config = { align = 'cm', padding = 0.06 }, nodes = {
                { n = G.UIT.T, config = { ref_table = df_ui, ref_value = 'summary', scale = 0.42, colour = G.C.UI.TEXT_LIGHT } },
            } },
            { n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = {
                btn('Clear', 'df_clear', G.C.RED),
                btn('Randomize', 'df_randomize', G.C.BLUE),
                btn('Select All', 'df_select_all', G.C.GREEN),
            } },
            { n = G.UIT.R, config = { align = 'cm', padding = 0.04 }, nodes = {
                { n = G.UIT.T, config = {
                    text = 'Randomize picks 3 to 8 decks. Page through the Decks pages below to pick your own.',
                    scale = 0.3, colour = G.C.UI.TEXT_LIGHT,
                } },
            } },
        }
    else
        local dp = page - 1
        local start_i = (dp - 1) * DF_PER_PAGE + 1
        local end_i = math.min(start_i + DF_PER_PAGE - 1, #decks)
        for i = start_i, end_i, DF_COLS do
            local nodes = {}
            for j = i, math.min(i + DF_COLS - 1, end_i) do
                nodes[#nodes + 1] = df_deck_toggle(decks[j])
            end
            content[#content + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.01 }, nodes = nodes }
        end
        if #content == 0 then
            content[1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.04 }, nodes = {
                { n = G.UIT.T, config = { text = 'No decks installed.', scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
            } }
        end
    end

    -- Page selector: "Controls", then "Decks 1".."Decks N".
    local options = { 'Controls' }
    for i = 1, deck_pages do options[#options + 1] = 'Decks ' .. i end
    local cycle = create_option_cycle({
        options = options,
        current_option = page,
        opt_callback = 'df_config_page',
        cycle_shoulders = true,
        no_pips = true,
        w = 4,
        focus_args = { snap_to = true, nav = 'wide' },
        colour = G.C.BLUE,
    })

    local nodes = {}
    for _, r in ipairs(content) do nodes[#nodes + 1] = r end
    nodes[#nodes + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = { cycle } }

    return { n = G.UIT.ROOT, config = { align = 'cm', padding = 0.04, colour = G.C.CLEAR }, nodes = nodes }
end

-- Swap the tab content in place when the page cycle changes.
G.FUNCS.df_config_page = function(args)
    if not args or not args.cycle_config then return end
    local tab_contents = G.OVERLAY_MENU and G.OVERLAY_MENU:get_UIE_by_ID('tab_contents')
    if not (tab_contents and tab_contents.config and tab_contents.config.object) then return end
    tab_contents.config.object:remove()
    tab_contents.config.object = UIBox({
        definition = df_build_config(args.cycle_config.current_option),
        config = { offset = { x = 0, y = 0 }, parent = tab_contents, type = 'cm' },
    })
    tab_contents.UIBox:recalculate()
end

if df_mod then
    df_mod.config_tab = function() return df_build_config(1) end
end
