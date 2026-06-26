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
        -- first to return a result for this context wins. Steamodded's
        -- Back wrapper prefers center.calculate but falls back to the
        -- deprecated center.trigger_effect (different arity: it takes
        -- (center, args), not (center, back, args)). Some modded decks
        -- (e.g. Silly Decks' Busted) still use trigger_effect, so we
        -- mirror that fallback here.
        for _, key in ipairs(df_enabled_decks()) do
            local center = G.P_CENTERS[key]
            if center then
                local ok, ret
                if type(center.calculate) == 'function' then
                    -- Pass the deck's OWN Back so back.effect.config reads
                    -- the deck's config, not Deck Fixer's empty one.
                    ok, ret = pcall(function() return center.calculate(center, df_deck_back(center), context) end)
                elseif type(center.trigger_effect) == 'function' then
                    ok, ret = pcall(function() return center.trigger_effect(center, context) end)
                end
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
-- Config tab: simple Clear / Randomize / Select-All controls
--
-- With 100+ modded decks a full checklist is unusable, so the tab is
-- driven by buttons plus a live summary line. Randomize is the main
-- workflow for "play a random assortment". The summary text re-reads its
-- ref each frame, so it updates instantly when a button is pressed.
----------------------------------------------------------------------

local df_ui = { summary = 'Selected: 0 decks' }

-- Keys of every registered back except Deck Fixer itself.
local function df_all_deck_keys()
    local keys = {}
    for _, center in ipairs(G.P_CENTER_POOLS.Back or {}) do
        if center.key and center.key ~= DF_KEY then keys[#keys + 1] = center.key end
    end
    return keys
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

-- All deck centers except Deck Fixer, sorted by display name.
local function df_deck_centers()
    local decks = {}
    for _, center in ipairs(G.P_CENTER_POOLS.Back or {}) do
        if center.key and center.key ~= DF_KEY then decks[#decks + 1] = center end
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
