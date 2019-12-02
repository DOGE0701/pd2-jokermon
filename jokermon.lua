if not Jokermon then
  _G.Jokermon = {}
  
  dofile(ModPath .. "req/JokerPanel.lua")

  Jokermon.mod_path = ModPath
  Jokermon.save_path = SavePath
  Jokermon.settings = {
    nuzlocke = false,
    show_panels = true,
    panel_x_pos = 0.03,
    panel_y_pos = 0.2,
    panel_spacing = 8,
    panel_layout = 1,
    panel_x_align = 1,
    panel_y_align = 1,
    show_messages = true,
    spawn_mode = 1,
    sorting = 1,
    sorting_order = 1,
    keys = {
      menu = "m",
      spawn_joker = "j"
    }
  }
  Jokermon.jokers = {}
  Jokermon.panels = {}
  Jokermon.units = {}
  Jokermon._num_panels = 0
  Jokermon._queued_keys = {}
  Jokermon._queued_converts = {}
  Jokermon._unit_id_mappings = {}
  Jokermon._jokers_added = 0
  Jokermon._joker_index = 1
  Jokermon._joker_slot = World:make_slot_mask(16)
  Jokermon._jokermon_key_press_t = 0

  function Jokermon:display_message(message, macros, force)
    if force or Jokermon.settings.show_messages then
      managers.chat:_receive_message(1, "JOKERMON", managers.localization:text(message, macros), tweak_data.system_chat_color)
    end
  end

  local to_vec = Vector3()
  function Jokermon:send_or_retrieve_joker()
    local t = managers.player:player_timer():time()
    if self._jokermon_key_press_t + 1 > t then
      return
    end
    self._jokermon_key_press_t = t
    local viewport = managers.viewport
    if viewport:get_current_camera() then
      local from = viewport:get_current_camera_position()
      mvector3.set(to_vec, viewport:get_current_camera_rotation():y())
      mvector3.multiply(to_vec, 1000)
      mvector3.add(to_vec, from)
      local col = World:raycast("ray", from, to_vec, "slot_mask", Jokermon._joker_slot)
      if col and col.unit and col.unit:base()._jokermon_key then
        return self:retrieve_joker(col.unit)
      end
    end
    return self:send_out_joker()
  end

  function Jokermon:send_out_joker(num, skip_check)
    local player = managers.player:local_player()
    if not player or not skip_check and (not managers.player:has_category_upgrade("player", "convert_enemies") or managers.player:chk_minion_limit_reached()) then
      return
    end
    if #self.jokers == 0 then
      return
    end
    local index, joker
    for i = self._joker_index, self._joker_index + #self.jokers do
      index = ((i - 1) % #self.jokers) + 1
      joker = self.jokers[index]
      if not self.units[index] and joker.hp_ratio > 0 and not table.contains(self._queued_keys, index) and self:spawn(joker, index, player) then
        self._joker_index = index + 1
        break
      end
    end
    return num and num > 1 and self:send_out_joker(num - 1)
  end

  function Jokermon:retrieve_joker(unit)
    if not alive(unit) then
      return
    end
    if Network:is_server() then
      unit:brain():set_active(false)
      unit:base():set_slot(unit, 0)
    else
      LuaNetworking:SendToPeer(1, "jokermon_retrieve", json.encode({ uid = unit:id() }))
    end
  end

  function Jokermon:spawn(joker, index, player_unit)
    if not alive(player_unit) then
      return
    end
    local is_local_player = player_unit == managers.player:local_player()
    local xml = ScriptSerializer:from_custom_xml(string.format("<table type=\"table\" id=\"@ID%s@\">", joker.uname))
    local ids = xml and xml.id
    if ids and PackageManager:has(Idstring("unit"), ids) then
      if is_local_player then
        table.insert(self._queued_keys, index)
      end
      -- If we are client, request spawn from server
      if Network:is_client() then
        LuaNetworking:SendToPeer(1, "jokermon_spawn", json.encode({ uname = joker.uname, name = joker.name }))
        return true
      end
      local unit = World:spawn_unit(ids, player_unit:position() + Vector3(math.random(-50, 50), math.random(-50, 50), 0), player_unit:rotation())
      unit:movement():set_team({ id = "law1", foes = {}, friends = {} })
      -- Queue for conversion (to avoid issues when converting instantly after spawn)
      self:queue_unit_convert(unit, is_local_player, player_unit, joker)
      return true
    elseif is_local_player then
      self:display_message("Jokermon_message_no_company", { NAME = joker.name })
    end
  end

  function Jokermon:_convert_queued_units()
    for _, data in pairs(self._queued_converts) do
      if alive(data.unit) then
        if not alive(data.player_unit) then
          World:delete_unit(data.unit)
        else
          if Keepers then
            Keepers.joker_names[data.player_unit:network():peer():id()] = data.joker.name
          end
          managers.groupai:state():convert_hostage_to_criminal(data.unit, (not data.is_local_player) and data.player_unit)
        end
      end
    end
    self._queued_converts = {}
  end

  function Jokermon:queue_unit_convert(unit, is_local_player, player_unit, joker)
    table.insert(self._queued_converts, { 
      is_local_player = is_local_player,
      player_unit = player_unit,
      unit = unit,
      joker = joker
    })
    -- Convert all queued units after a short delay (Resets the delayed call if it already exists)
    DelayedCalls:Add("ConvertJokermon", 0.25, function ()
      Jokermon:_convert_queued_units()
    end)
  end

  function Jokermon:setup_joker(key, unit, joker)
    if not alive(unit) then
      return
    end
    -- correct nickname
    self:set_joker_name(unit, joker.name, true)
    -- Save to units
    self.units[key] = unit
    unit:base()._jokermon_key = key
    -- Create panel
    self:add_panel(key, joker)
  end

  function Jokermon:set_joker_name(unit, name, sync)
    if not alive(unit) then
      return
    end
    HopLib:unit_info_manager():get_info(unit)._nickname = name
    local peer_id = unit:base().kpr_minion_owner_peer_id
    if Keepers and peer_id then
      Keepers:DestroyLabel(unit)
      unit:base().kpr_minion_owner_peer_id = peer_id
      Keepers.joker_names[peer_id] = name
      Keepers:SetJokerLabel(unit)
    end
    if sync then
      LuaNetworking:SendToPeers("jokermon_name", json.encode({ uid = unit:id(), name = name }))
    end
  end

  function Jokermon:get_base_stats(joker)
    return tweak_data.character[joker.tweak].jokermon_stats or {
      base_hp = 8,
      exp_rate = 2
    }
  end

  function Jokermon:level_to_exp(joker, level)
    local exp_rate = self:get_base_stats(joker).exp_rate
    return 10 * math.ceil(math.pow(math.min(level or joker.level, 100), exp_rate))
  end

  function Jokermon:exp_to_level(joker, exp)
    local exp_rate = self:get_base_stats(joker).exp_rate
    return math.min(math.floor(math.pow((exp or joker.exp) / 10, 1 / exp_rate)), 100)
  end

  function Jokermon:get_exp_ratio(joker)
    if joker.level >= 100 then
      return 1
    end
    local needed_current, needed_next = self:level_to_exp(joker), self:level_to_exp(joker, joker.level + 1)
    return (joker.exp - needed_current) / (needed_next - needed_current)
  end

  function Jokermon:get_heal_price(joker)
    local base_price = 10000
    return math.ceil((joker.hp_ratio <= 0 and base_price * 2 or (1 - joker.hp_ratio) * base_price) * joker.level / 10)
  end

  function Jokermon:give_exp(key, exp)
    exp = math.ceil(exp)
    local joker = self.jokers[key]
    if joker and joker.level < 100 then
      local panel = self.panels[key]
      local old_level = joker.level
      joker.exp = joker.exp + exp
      joker.level = self:exp_to_level(joker)
      if joker.level ~= old_level then
        local base_hp = self:get_base_stats(joker).base_hp
        for i = old_level, joker.level - 1 do
          joker.hp = joker.hp + base_hp * (i / 99) * 0.25
        end
        self:set_unit_stats(self.units[key], joker, true)
        if panel then
          panel:update_hp(joker.hp, joker.hp_ratio)
          panel:update_level(joker.level)
          panel:update_exp(0, true)
        end
        self:display_message("Jokermon_message_levelup", { NAME = joker.name, LEVEL = joker.level })
      end
      if joker.level >= 100 then
        joker.exp = self:level_to_exp(joker)
      end
      if panel then
        panel:update_exp(self:get_exp_ratio(joker))
      end
    end
  end

  function Jokermon:set_unit_stats(unit, data, sync)
    if not alive(unit) then
      return
    end
    local u_damage = unit:character_damage()
    u_damage._HEALTH_INIT = data.hp
    u_damage._health_ratio = data.hp_ratio
    u_damage._health = u_damage._health_ratio * u_damage._HEALTH_INIT
    u_damage._HEALTH_INIT_PRECENT = u_damage._HEALTH_INIT / u_damage._HEALTH_GRANULARITY
    if sync then
      LuaNetworking:SendToPeers("jokermon_stats", json.encode({ uid = unit:id(), hp = data.hp, hp_ratio = data.hp_ratio }))
    end
  end

  local _sort_comp = {
    default = function (a, b) return a < b end,
    [2] = function (a, b) return a > b end
  }
  local _sort_val = {
    default = function (v) return v.order end,
    [1] = function (v) return v.stats.catch_date end,
    [2] = function (v) return v.level end,
    [3] = function (v) return v.hp end,
    [4] = function (v) return v.hp * v.hp_ratio end,
    [5] = function (v) return v.hp_ratio end,
    [6] = function (v) return v.exp end,
    [7] = function (v) return Jokermon:level_to_exp(v, v.level + 1) - v.exp end,
    [8] = function (v) return Jokermon:level_to_exp(v, 100) end
  }
  function Jokermon:sort_jokers()
    local c = _sort_comp[self.settings.sorting_order] or _sort_comp.default
    local v = _sort_val[self.settings.sorting] or _sort_val.default
    local va, vb
    table.sort(self.jokers, function (a, b)
      va, vb = v(a), v(b)
      if va == vb then
        return c(a.order, b.order)
      end
      return c(va, vb)
    end)
  end

  function Jokermon:layout_panels()
    local i = 0
    local x, y
    local x_pos, y_pos, spacing = self.settings.panel_x_pos, self.settings.panel_y_pos, self.settings.panel_spacing
    local x_align, y_align = self.settings.panel_x_align, self.settings.panel_y_align
    local horizontal_layout = self.settings.panel_layout ~= 1 and 1 or 0
    local vertical_layout = self.settings.panel_layout == 1 and 1 or 0
    for _, panel in pairs(self.panels) do
      if x_align == 2 and horizontal_layout == 1 then
        x = (panel._parent_panel:w() - panel._panel:w() * self._num_panels - spacing * (self._num_panels - 1)) * x_pos + (panel._panel:w() + spacing) * i
      else
        x = (panel._parent_panel:w() - panel._panel:w()) * x_pos + (panel._panel:w() + spacing) * i * horizontal_layout * (x_align == 3 and -1 or 1)
      end
      if y_align == 2 and vertical_layout == 1 then
        y = (panel._parent_panel:h() - panel._panel:h() * self._num_panels - spacing * (self._num_panels - 1)) * y_pos + (panel._panel:h() + spacing) * i
      else
        y = (panel._parent_panel:h() - panel._panel:h()) * y_pos + (panel._panel:h() + spacing) * i * vertical_layout * (y_align == 3 and -1 or 1)
      end
      panel:set_position(x, y)
      i = i + 1
    end
  end

  function Jokermon:add_panel(key, joker)
    local hud = self.settings.show_panels and managers.hud:script(PlayerBase.PLAYER_INFO_HUD_FULLSCREEN_PD2)
    if not hud then
      return
    end
    local panel = JokerPanel:new(hud.panel)
    panel:update_name(joker.name)
    panel:update_hp(joker.hp, joker.hp_ratio, true)
    panel:update_level(joker.level)
    panel:update_exp(self:get_exp_ratio(joker), true)
    self.panels[key] = panel
    self._num_panels = self._num_panels + 1
    self:layout_panels()
  end

  function Jokermon:remove_panel(key)
    if self.panels[key] then
      self.panels[key]:remove()
      self.panels[key] = nil
      self._num_panels = self._num_panels - 1
      self:layout_panels()
    end
  end

  function Jokermon:save(full_save)
    local file = io.open(self.save_path .. "jokermon_settings.txt", "w+")
    if file then
      file:write(json.encode(self.settings))
      file:close()
    end
    if full_save then
      file = io.open(self.save_path .. "jokermon.txt", "w+")
      if file then
        local jokers = self.settings.nuzlocke and table.filter_list(self.jokers, function (j) return j.hp_ratio > 0 end) or self.jokers
        file:write(json.encode(jokers))
        file:close()
      end
    end
  end
  
  function Jokermon:load()
    local file = io.open(self.save_path .. "jokermon_settings.txt", "r")
    if file then
      local data = json.decode(file:read("*all"))
      file:close()
      for k, v in pairs(data) do
        self.settings[k] = v
      end
    end
    file = io.open(self.save_path .. "jokermon.txt", "r")
    if file then
      self.jokers = json.decode(file:read("*all"))
      file:close()
    end
    self:sort_jokers()
  end

  function Jokermon:check_create_menu()

    if self.menu then
      return
    end
  
    self.menu_title_size = 22
    self.menu_items_size = 18
    self.menu_padding = 16
    self.menu_background_color = Color.black:with_alpha(0.75)
    self.menu_accent_color = BeardLib.Options:GetValue("MenuColor"):with_alpha(0.75)--Color("0bce99"):with_alpha(0.75)
    self.menu_highlight_color = self.menu_accent_color:with_alpha(0.075)
    self.menu_grid_item_color = Color.black:with_alpha(0.5)
  
    self.menu = MenuUI:new({
      name = "JokermonMenu",
      layer = 1000,
      background_blur = true,
      animate_toggle = true,
      text_offset = self.menu_padding / 4,
      show_help_time = 0.5,
      border_size = 1,
      accent_color = self.menu_accent_color,
      highlight_color = self.menu_highlight_color,
      localized = true,
      use_default_close_key = true,
      disable_player_controls = true
    })
    
    local menu_w = self.menu._panel:w()
    local menu_h = self.menu._panel:h()
  
    self._menu_w_left = menu_w / 3 - self.menu_padding
    self._menu_w_right = menu_w - self._menu_w_left - self.menu_padding * 2
  
    local menu = self.menu:Menu({
      name = "JokermonMainMenu",
      background_color = self.menu_background_color
    })
  
    local title = menu:DivGroup({
      name = "JokermonTitle",
      text = "Jokermon_menu_main_name",
      size = 26,
      background_color = Color.transparent,
      position = { self.menu_padding, self.menu_padding }
    })
  
    local base_settings = menu:DivGroup({
      name = "JokermonBaseSettings",
      text = "Jokermon_menu_base_settings",
      size = self.menu_title_size,
      inherit_values = {
        size = self.menu_items_size
      },
      border_bottom = true,
      border_position_below_title = true,
      w = self._menu_w_left,
      position = { self.menu_padding, title:Bottom() }
    })
    base_settings:ComboBox({
      name = "spawn_mode",
      text = "Jokermon_menu_spawn_mode",
      help = "Jokermon_menu_spawn_mode_desc",
      items = { "Jokermon_menu_spawn_mode_manual", "Jokermon_menu_spawn_mode_automatic" },
      value = self.settings.spawn_mode,
      free_typing = false,
      on_callback = function (item)
        self:change_menu_setting(item)
        if self.settings.spawn_mode > 1 and Utils:IsInHeist() then
          self:send_out_joker(managers.player:upgrade_value("player", "convert_enemies_max_minions", 0))
        end
      end
    })
    base_settings:Toggle({
      name = "show_messages",
      text = "Jokermon_menu_show_messages",
      help = "Jokermon_menu_show_messages_desc",
      on_callback = function (item) self:change_menu_setting(item) end,
      value = self.settings.show_messages
    })
    self.menu_nuzlocke = base_settings:Toggle({
      name = "nuzlocke",
      text = "Jokermon_menu_nuzlocke",
      help = "Jokermon_menu_nuzlocke_desc",
      on_callback = function (item) self:change_menu_setting(item) end,
      value = self.settings.nuzlocke
    })
    base_settings:Divider({
      h = self.menu_padding * 2
    })
  
    local panel_settings = menu:DivGroup({
      name = "JokermonPanelSettings",
      text = "Jokermon_menu_panel_settings",
      size = self.menu_title_size,
      inherit_values = {
        size = self.menu_items_size,
        wheel_control = true
      },
      border_bottom = true,
      border_position_below_title = true,
      w = self._menu_w_left,
      position = { self.menu_padding, base_settings:Bottom() }
    })
    panel_settings:Toggle({
      name = "show_panels",
      text = "Jokermon_menu_show_panels",
      help = "Jokermon_menu_show_panels_desc",
      on_callback = function (item) self:change_menu_setting(item) end,
      value = self.settings.show_panels
    })
    panel_settings:ComboBox({
      name = "panel_layout",
      text = "Jokermon_menu_panel_layout",
      items = { "Jokermon_menu_panel_layout_vertical", "Jokermon_menu_panel_layout_horizontal" },
      value = self.settings.panel_layout,
      free_typing = false,
      on_callback = function (item)
        self:change_menu_setting(item)
        self:layout_panels()
      end
    })
    panel_settings:ComboBox({
      name = "panel_x_align",
      text = "Jokermon_menu_panel_x_align",
      items = { "Jokermon_menu_panel_align_left", "Jokermon_menu_panel_align_center", "Jokermon_menu_panel_align_right" },
      value = self.settings.panel_x_align,
      free_typing = false,
      on_callback = function (item)
        self:change_menu_setting(item)
        self:layout_panels()
      end
    })
    panel_settings:ComboBox({
      name = "panel_y_align",
      text = "Jokermon_menu_panel_y_align",
      items = { "Jokermon_menu_panel_align_top", "Jokermon_menu_panel_align_center", "Jokermon_menu_panel_align_bottom" },
      value = self.settings.panel_y_align,
      free_typing = false,
      on_callback = function (item)
        self:change_menu_setting(item)
        self:layout_panels()
      end
    })
    panel_settings:Slider({
      name = "panel_x_pos",
      text = "Jokermon_menu_panel_x_pos",
      value = self.settings.panel_x_pos,
      min = 0,
      max = 1,
      step = 0.01,
      on_callback = function (item)
        self:change_menu_setting(item)
        self:layout_panels()
      end
    })
    panel_settings:Slider({
      name = "panel_y_pos",
      text = "Jokermon_menu_panel_y_pos",
      value = self.settings.panel_y_pos,
      min = 0,
      max = 1,
      step = 0.01,
      on_callback = function (item)
        self:change_menu_setting(item)
        self:layout_panels()
      end
    })
    panel_settings:Slider({
      name = "panel_spacing",
      text = "Jokermon_menu_panel_spacing",
      value = self.settings.panel_spacing,
      min = 0,
      max = 256,
      step = 1,
      floats = 1,
      on_callback = function (item)
        self:change_menu_setting(item)
        self:layout_panels()
      end
    })
    panel_settings:Divider({
      h = self.menu_padding * 2
    })

    local keybinds = menu:DivGroup({
      name = "JokermonKeybinds",
      text = "Jokermon_menu_keybinds",
      size = self.menu_title_size,
      inherit_values = {
        size = self.menu_items_size
      },
      border_bottom = true,
      border_position_below_title = true,
      w = self._menu_w_left,
      position = { self.menu_padding, panel_settings:Bottom() }
    })
    keybinds:KeyBind({
      name = "menu",
      text = "Jokermon_menu_key_menu",
      help = "Jokermon_menu_key_menu_desc",
      value = self.settings.keys.menu,
      on_callback = function (item)
        self:change_key_binding(item)
      end
    })
    keybinds:KeyBind({
      name = "spawn_joker",
      text = "Jokermon_menu_key_spawn_joker",
      help = "Jokermon_menu_key_spawn_joker_desc",
      value = self.settings.keys.spawn_joker,
      on_callback = function (item)
        self:change_key_binding(item)
      end
    })
  
    menu:Button({
      name = "exit",
      text = "menu_back",
      size = 24,
      size_by_text = true,
      on_callback = function (item) self:set_menu_state(false) end,
      position = function (item) item:SetPosition(title:Right() - item:W() - self.menu_padding, title:Y()) end
    })
  
    self.menu_management = menu:DivGroup({
      name = "JokermonManagement",
      text = "Jokermon_menu_management",
      size = self.menu_title_size,
      inherit_values = {
        size = self.menu_items_size
      },
      enabled = not Utils:IsInHeist(),
      border_bottom = true,
      border_position_below_title = true,
      w = self._menu_w_right,
      position = { base_settings:Right() + self.menu_padding, title:Bottom() }
    })
    local sorting = self.menu_management:ComboBox({
      name = "sorting",
      text = "Jokermon_menu_sorting",
      help = "Jokermon_menu_sorting_desc",
      items = { "Jokermon_menu_sorting_date", "Jokermon_menu_sorting_level", "Jokermon_menu_sorting_max_hp", "Jokermon_menu_sorting_hp", "Jokermon_menu_sorting_rel_hp", "Jokermon_menu_sorting_exp", "Jokermon_menu_sorting_exp_needed", "Jokermon_menu_sorting_total_exp", "Jokermon_menu_sorting_custom" },
      value = self.settings.sorting,
      free_typing = false
    })
    local order = self.menu_management:ComboBox({
      name = "sorting_order",
      text = "Jokermon_menu_sorting_order",
      items = { "Jokermon_menu_sorting_order_asc", "Jokermon_menu_sorting_order_desc" },
      value = self.settings.sorting_order,
      free_typing = false
    })
    self.menu_management:Divider({
      h = self.menu_padding / 2
    })
    local apply_sorting = self.menu_management:Button({
      name = "JokermonApplySorting",
      text = "Jokermon_menu_apply_sorting",
      on_callback = function (item)
        self:change_menu_setting(sorting)
        self:change_menu_setting(order)
        self:sort_jokers()
        self:refresh_joker_list()
        self:save(true)
      end
    })

    self.menu_jokermon_list = self.menu_management:Menu({
      name = "JokermonList",
      inherit_values = {
        size = self.menu_items_size
      },
      align_method = "grid",
      scrollbar = true,
      max_height = menu_h - self.menu_management:Y() - apply_sorting:Bottom() - self.menu_padding * 4
    })
  end

  function Jokermon:refresh_joker_list()
    self.menu_nuzlocke:SetEnabled(not Utils:IsInHeist())
    self.menu_management:SetEnabled(not Utils:IsInHeist())
    self.menu_jokermon_list:ClearItems()
    local sub_menu, roll
    for i, joker in ipairs(self.jokers) do
      sub_menu = self.menu_jokermon_list:Holder({
        name = "Joker" .. i,
        border_visible = true,
        w = self.menu_jokermon_list:W() / 2 - self.menu_padding * 2,
        auto_height = true,
        localized = false,
        background_color = self.menu_grid_item_color,
        offset = self.menu_padding,
        inherit_values = {
          offset = 0,
          text_offset = { self.menu_padding, self.menu_padding / 4 }
        }
      })
      self:fill_joker_panel(sub_menu, i, joker)
    end
  end

  local floor = math.floor
  local pseudo_random = function (seed, ...)
    math.randomseed(seed)
    return math.random(...)
  end
  function Jokermon:fill_joker_panel(menu, i, joker)
    menu:ClearItems()
    menu:Divider({
      h = self.menu_padding / 2
    })
    local title = menu:Divider({
      name = "JokerType" .. i,
      text = string.format("%s (Lv.%u)", tostring(HopLib:name_provider():name_by_unit(nil, joker.uname) or "UNKNOWN"), joker.level),
      size = self.menu_items_size + 4
    })
    menu:Button({
      name = "JokerStats" .. i,
      text = string.format("%u ", (joker.stats.kills or 0) + (joker.stats.special_kills or 0)),
      help = managers.localization:text("Jokermon_menu_stats", { KILLS = joker.stats.kills or 0, SPECIAL_KILLS = joker.stats.special_kills or 0, DAMAGE = floor((joker.stats.damage or 0) * 10) }),
      help_localized = false,
      size = self.menu_items_size + 4,
      size_by_text = true,
      highlight_color = Color.transparent,
      position = function (item) item:SetRightTop(menu:W(), title:Y()) end
    })
    menu:Divider({
      name = "JokerHpExp" .. i,
      text = managers.localization:text("Jokermon_menu_hp_exp", { HP = floor(joker.hp * joker.hp_ratio * 10), MAXHP = floor(joker.hp * 10), HPRATIO = floor(joker.hp_ratio * 100), EXP = joker.exp, TOTALEXP = self:level_to_exp(joker, 100), MISSINGEXP = self:level_to_exp(joker, joker.level + 1) - joker.exp })
    })
    menu:TextBox({
      name = "JokerNick" .. i,
      text = "Jokermon_menu_nickname",
      localized = true,
      fit_text = true,
      value = joker.name,
      focus_mode = true,
      on_callback = function (item)
        joker.name = item:Value()
        self:save(true)
      end
    })
    menu:Divider({
      h = self.menu_padding / 2
    })
    menu:Divider({
      name = "JokerTrivia" .. i,
      text = managers.localization:text("Jokermon_menu_catch_stats", {
        DATE = os.date("%b %d, %Y", joker.stats.catch_date),
        LEVEL = joker.stats.catch_level or 1,
        HEIST = tweak_data.levels[joker.stats.catch_heist] and managers.localization:text(tweak_data.levels[joker.stats.catch_heist].name_id) or "UNKNOWN",
        DIFFICULTY = managers.localization:to_upper_text(tweak_data.difficulty_name_ids[joker.stats.catch_difficulty or "normal"])
      }) .. "\n" .. managers.localization:text("Jokermon_menu_flavour_" .. pseudo_random(joker.stats.catch_date, 1, 30)),
      size = self.menu_items_size - 4,
      foreground = Color.white:with_alpha(0.5)
    })
    menu:NumberBox({
      name = "JokerOrder" .. i,
      text = "Jokermon_menu_order",
      help = "Jokermon_menu_order_desc",
      localized = true,
      fit_text = true,
      value = joker.order,
      floats = 0,
      size = self.menu_items_size - 4,
      focus_mode = true,
      on_callback = function (item)
        joker.order = item:Value()
        self:save(true)
      end
    })
    menu:Divider({
      h = self.menu_padding
    })
    local heal_price = self:get_heal_price(joker)
    menu:Button({
      name = "JokerHeal" .. i,
      text = string.format(managers.localization:text(joker.hp_ratio <= 0 and "Jokermon_menu_action_revive" or "Jokermon_menu_action_heal", { COST = managers.money._cash_sign .. managers.money:add_decimal_marks_to_string(tostring(heal_price)) })),
      text_align = "right",
      enabled = joker.hp_ratio < 1 and managers.money:total() >= heal_price,
      on_callback = function (item)
        managers.money:deduct_from_spending(heal_price)
        joker.hp_ratio = 1
        self:save(true)
        self:fill_joker_panel(menu, i, joker)
      end
    })
    menu:Button({
      name = "JokerRelease" .. i,
      text = "Jokermon_menu_action_release",
      localized = true,
      text_align = "right",
      on_callback = function (item)
        self:show_release_confirmation(i)
      end
    })
    menu:Divider({
      h = self.menu_padding / 2
    })
  end

  function Jokermon:show_release_confirmation(i)
    local diag = MenuDialog:new({
      accent_color = self.menu_accent_color,
      highlight_color = self.menu_highlight_color,
      background_color = self.menu_background_color,
      border_size = 1,
      offset = 0,
      text_offset = {self.menu_padding, self.menu_padding / 4},
      size = self.menu_items_size,
      items_size = self.menu_items_size
    })
    diag:Show({
      title = managers.localization:text("dialog_warning_title"),
      message = managers.localization:text("Jokermon_menu_confirm_release", { NAME = self.jokers[i].name }),
      w = self.menu._panel:w() / 2,
      yes = false,
      title_merge = {
        size = self.menu_title_size
      },
      create_items = function (menu)
        menu:Button({
          name = "JokermonYes",
          text = "dialog_yes",
          text_align = "right",
          localized = true,
          on_callback = function (item)
            diag:hide()
            table.remove(self.jokers, i)
            self:save(true)
            self:refresh_joker_list()
          end
        })
        menu:Button({
          name = "JokermonNo",
          text = "dialog_no",
          text_align = "right",
          localized = true,
          on_callback = function (item)
            diag:hide()
          end
        })
      end
    })
  end

  function Jokermon:change_menu_setting(item)
    self.settings[item:Name()] = item:Value()
    self:save()
  end

  function Jokermon:change_key_binding(item)
    self.settings.keys[item:Name()] = item:Value()
    BLT.Keybinds:get_keybind("jokermon_" .. item:Name()):SetKey(item:Value())
    self:save()
  end

  function Jokermon:set_menu_state(enabled)
    self:check_create_menu()
    if enabled and not self.menu:Enabled() then
      self:refresh_joker_list()
      self.menu:Enable()
    elseif not enabled then
      self.menu:Disable()
    end
  end
  
  Hooks:Add("HopLibOnMinionAdded", "HopLibOnMinionAddedJokermon", function(unit, player_unit)
    local uid = unit:id()
    Jokermon._unit_id_mappings[uid] = unit
    
    if player_unit ~= managers.player:local_player() then
      return
    end

    local key = Jokermon._queued_keys[1]
    if key then
      -- Use existing Jokermon entry
      local joker = Jokermon.jokers[key]
      local uname = Network:is_server() and unit:name():key() or NameProvider.CLIENT_TO_SERVER_MAPPING[unit:name():key()]
      if joker.uname ~= uname then
        log("[Jokermon] Warning: Requested " .. NameProvider.UNIT_MAPPIGS[joker.uname] .. " but got " .. NameProvider.UNIT_MAPPIGS[uname])
      end
      Jokermon:set_unit_stats(unit, joker, true)
      Jokermon:setup_joker(key, unit, joker)
      table.remove(Jokermon._queued_keys, 1)

      Jokermon:display_message("Jokermon_message_go", { NAME = joker.name })
      player_unit:sound_source():post_event("grenade_gas_npc_fire")
    else
      -- Create new Jokermon entry
      key = #Jokermon.jokers + 1
      local mul = (tweak_data:difficulty_to_index(Global.game_settings.difficulty) - 1) / (#tweak_data.difficulties - 1)
      local joker = {
        tweak = unit:base()._tweak_table,
        uname = Network:is_server() and unit:name():key() or NameProvider.CLIENT_TO_SERVER_MAPPING[unit:name():key()],
        name = HopLib:unit_info_manager():get_info(unit):nickname(),
        hp = unit:character_damage()._HEALTH_INIT,
        hp_ratio = 1,
        level = math.max(1, math.floor(40 * mul + math.random(0, 10 + 10 * mul))),
        order = 0
      }
      joker.exp = Jokermon:level_to_exp(joker, joker.level)
      joker.stats = {
        catch_level = joker.level,
        catch_date = os.time(),
        catch_heist = managers.job:current_level_id(),
        catch_difficulty = Global.game_settings.difficulty
      }

      Jokermon:display_message("Jokermon_message_capture", { NAME = HopLib:unit_info_manager():get_info(unit):name(), LEVEL = joker.level })
      table.insert(Jokermon.jokers, joker)
      Jokermon:setup_joker(key, unit, joker)

      Jokermon._jokers_added = Jokermon._jokers_added + 1
    end

  end)

  Hooks:Add("HopLibOnMinionRemoved", "HopLibOnMinionRemovedJokermon", function(unit)
    local key = unit:base()._jokermon_key
    local joker = key and Jokermon.jokers[key]
    if joker then
      joker.hp_ratio = unit:character_damage()._health_ratio
      if joker.hp_ratio <= 0 then
        Jokermon:display_message(Jokermon.settings.nuzlocke and "Jokermon_message_die" or "Jokermon_message_faint", { NAME = joker.name })
      else
        Jokermon:display_message("Jokermon_message_retrieve", { NAME = joker.name })
      end
      Jokermon:remove_panel(key)
      Jokermon.units[key] = nil
      if Jokermon.settings.spawn_mode ~= 1 then
        Jokermon:send_out_joker(1, true)
      end
    end
    Jokermon._unit_id_mappings[unit:id()] = nil
  end)

  Hooks:Add("HopLibOnUnitDamaged", "HopLibOnUnitDamagedJokermon", function(unit, damage_info)
    local u_damage = unit:character_damage()
    local key = unit:base()._jokermon_key
    local joker = key and Jokermon.jokers[key]
    if joker then
      joker.hp_ratio = u_damage._health_ratio
      local panel = Jokermon.panels[key]
      if panel then
        panel:update_hp(joker.hp, joker.hp_ratio)
      end
    end
    local attacker_key = alive(damage_info.attacker_unit) and damage_info.attacker_unit:base()._jokermon_key
    if attacker_key then
      u_damage._jokermon_assists = u_damage._jokermon_assists or {}
      local dmg = u_damage._jokermon_assists[attacker_key]
      u_damage._jokermon_assists[attacker_key] = dmg and dmg + damage_info.damage or damage_info.damage
      local attacker_joker = Jokermon.jokers[attacker_key]
      if attacker_joker then
        attacker_joker.stats.damage = (attacker_joker.stats.damage or 0) + damage_info.damage
        if u_damage:dead() then
          local info = HopLib:unit_info_manager():get_info(unit)
          local cat = info and info:is_special() and "special_kills" or "kills"
          attacker_joker.stats[cat] = (attacker_joker.stats[cat] or 0) + 1
        end
      end
    end
    if u_damage:dead() and u_damage._jokermon_assists then
      for key, dmg in pairs(u_damage._jokermon_assists) do
        -- Assists get exp based on the damage they did, kills get exp based on enemy hp
        Jokermon:give_exp(key, key == attacker_key and math.max(u_damage._HEALTH_INIT, dmg) or dmg)
      end
    end
  end)

  Hooks:Add("NetworkReceivedData", "NetworkReceivedDataJokermon", function(sender, id, data)
    if id == "jokermon_spawn" then
      Jokermon:spawn(json.decode(data), nil, LuaNetworking:GetPeers()[sender]:unit())
    elseif id == "jokermon_stats" then
      data = json.decode(data)
      Jokermon:set_unit_stats(Jokermon._unit_id_mappings[data.uid], data)
    elseif id == "jokermon_name" then
      data = json.decode(data)
      Jokermon:set_joker_name(Jokermon._unit_id_mappings[data.uid], data.name)
    elseif id == "jokermon_retrieve" then
      data = json.decode(data)
      Jokermon:retrieve_joker(Jokermon._unit_id_mappings[data.uid])
    end
  end)

  Hooks:Add("LocalizationManagerPostInit", "LocalizationManagerPostInitJokermon", function(loc)
    local language = "english"
    local system_language = HopLib:get_game_language()
    local blt_language = BLT.Localization:get_language().language

    local loc_path = Jokermon.mod_path .. "loc/"
    if io.file_is_readable(loc_path .. system_language .. ".txt") then
      language = system_language
    end
    if io.file_is_readable(loc_path .. blt_language .. ".txt") then
      language = blt_language
    end

    loc:load_localization_file(loc_path .. language .. ".txt")
    loc:load_localization_file(loc_path .. "english.txt", false)
  end)

  Hooks:Add("MenuManagerPostInitialize", "MenuManagerPostInitializeJokermon", function(menu_manager, nodes)
  
    Jokermon:load()

    MenuCallbackHandler.Jokermon_open_menu = function ()
      Jokermon:set_menu_state(true)
    end

    MenuHelperPlus:AddButton({
      id = "JokermonMenu",
      title = "Jokermon_menu_main_name",
      desc = "Jokermon_menu_main_desc",
      node_name = "blt_options",
      callback = "Jokermon_open_menu"
    })

    local mod = BLT.Mods:GetMod(Jokermon.mod_path:gsub(".+/(.+)/$", "%1"))
    if not mod then
      log("[Jokermon] ERROR: Could not get mod object to register keybinds!")
      return
    end
    BLT.Keybinds:register_keybind(mod, { id = "jokermon_menu", allow_menu = true, allow_game = true, show_in_menu = false, callback = function()
      Jokermon:set_menu_state(true)
    end }):SetKey(Jokermon.settings.keys.menu)
    BLT.Keybinds:register_keybind(mod, { id = "jokermon_spawn_joker", allow_game = true, show_in_menu = false, callback = function()
      Jokermon:send_or_retrieve_joker()
    end }):SetKey(Jokermon.settings.keys.spawn_joker)
  
  end)
  
end

if RequiredScript then

  local fname = Jokermon.mod_path .. "lua/" .. RequiredScript:gsub(".+/(.+)", "%1.lua")
  if io.file_is_readable(fname) then
    dofile(fname)
  end

end