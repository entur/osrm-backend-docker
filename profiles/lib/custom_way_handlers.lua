local get_turn_lanes = require("lib/guidance").get_turn_lanes
local set_classification = require("lib/guidance").set_classification
local get_destination = require("lib/destination").get_destination
local Tags = require('lib/tags')
local Measure = require("lib/measure")

CustomWayHandlers = {}

-- handle oneways tags
function CustomWayHandlers.oneway(profile,way,result,data)
  if not profile.oneway_handling then
    return
  end

  local oneway
  if profile.oneway_handling == true then
    oneway = Tags.get_value_by_prefixed_sequence(way,profile.restrictions,'oneway') or way:get_value_by_key("oneway")
  elseif profile.oneway_handling == 'specific' then
    oneway = Tags.get_value_by_prefixed_sequence(way,profile.restrictions,'oneway')
  elseif profile.oneway_handling == 'conditional' then
    -- Following code assumes that `oneway` and `oneway:conditional` tags have opposite values and takes weakest (always `no`).
    -- So if we will have:
    -- oneway=yes, oneway:conditional=no @ (condition1)
    -- oneway=no, oneway:conditional=yes @ (condition2)
    -- condition1 will be always true and condition2 will be always false.
    if way:get_value_by_key("oneway:conditional") then
        oneway = "no"
    else
        oneway = Tags.get_value_by_prefixed_sequence(way,profile.restrictions,'oneway') or way:get_value_by_key("oneway")
    end
  end

  data.oneway = oneway

  local psv = way:get_value_by_key("psv")

  if oneway == "-1" and "opposite_lane" ~= psv then
    data.is_reverse_oneway = true
    result.forward_mode = mode.inaccessible
  elseif oneway == "yes" or
         oneway == "1" or
         oneway == "true" then
    data.is_forward_oneway = true
    result.backward_mode = mode.inaccessible
  elseif profile.oneway_handling == true then
    local junction = way:get_value_by_key("junction")

    if data.highway == "motorway" or
       junction == "roundabout" or
       junction == "circular"  then
      if oneway ~= "no" then
        -- implied oneway
        data.is_forward_oneway = true
        result.backward_mode = mode.inaccessible
      end
    end
  end
end
