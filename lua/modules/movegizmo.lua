moveGizmo = {
	Axis = { X = 1, Y = 2, Z = 3 },
	AxisName = { "X", "Y", "Z" },
	Orientation = { Local = 1, World = 2 },
}

plane = require("plane")

local functions = {}

functions.show = function(self)
	self.hidden = false
	if self.object ~= nil then
		self.gizmoObject:SetParent(World)
	end
end

functions.hide = function(self)
	self.hidden = true
	self.gizmoObject:SetParent(nil)
end

functions.isShown = function(self)
	return self.gizmoObject.Parent ~= nil
end

functions.setLayer = function(self, layer)
	self.camera.Layers = layer
	self.handles[moveGizmo.Axis.X].Layers = layer
	self.handles[moveGizmo.Axis.Y].Layers = layer
	self.handles[moveGizmo.Axis.Z].Layers = layer
end

functions.up = function(self, _)
	if self.selectedHandle then
		if self.onDragEnd then
			self.onDragEnd(self.object.Position)
		end
		self.selectedHandle = nil
		return true
	end
	return false
end

functions.drag = function(self, pe)
	if not self.object or not self.selectedHandle then
		return false
	end
	if not self.p then
		return
	end

	local ray = Ray(pe.Position, pe.Direction)
	local pos = self.p:hit(ray)
	if pos == nil then
		return false
	end

	-- project pos on move axis
	pos = self.p2:hit(Ray(pos, self.p2.normal))
	if pos == nil then
		return false
	end

	-- get final pos
	pos = self.originalPosition + pos - self.impactPosition

	-- align if snap > 0
	local axisName = moveGizmo.AxisName[self.selectedHandle.axis]
	local snap = (self.snap or 0)
	if snap > 0 then
		if self.orientation == moveGizmo.Orientation.Local then
			pos = self.object:PositionWorldToLocal(pos)
		end
		pos[axisName] = math.floor(pos[axisName] / snap) * snap
		if self.orientation == moveGizmo.Orientation.Local then
			pos = self.object:PositionLocalToWorld(pos)
		end
	end

	local currentLocalPos = self.object:PositionWorldToLocal(self.object.Position)
	if currentLocalPos[axisName] ~= self.object:PositionWorldToLocal(pos)[axisName] then
		self.object.Position = pos
		self.gizmoObject.Position = pos
	end

	if self.onDrag then
		self.onDrag(self.object.Position)
	end

	functions.updateHandles(self)

	return true
end

functions.down = function(self, pe)
	if not self.object then
		return false
	end
	if self:isShown() == false then
		return
	end

	local ray = Ray(pe.Position, pe.Direction)
	for axis = moveGizmo.Axis.X, moveGizmo.Axis.Z do
		local handle = self.handles[axis]
		local impact = ray:Cast(handle)
		if impact then
			self.selectedHandle = handle

			self.impactPosition = ray.Origin + ray.Direction * impact.Distance
			self.originalPosition = self.object.Position:Copy()

			if handle.axis == moveGizmo.Axis.X then
				self.p = plane:New(self.impactPosition, handle.Forward, self.handles[moveGizmo.Axis.Y].Forward)
				self.p2 = plane:New(self.impactPosition, handle.Forward, self.handles[moveGizmo.Axis.Z].Forward)
			elseif handle.axis == moveGizmo.Axis.Y then
				self.p = plane:New(self.impactPosition, handle.Forward, self.handles[moveGizmo.Axis.X].Forward)
				self.p2 = plane:New(self.impactPosition, handle.Forward, self.handles[moveGizmo.Axis.Z].Forward)
			elseif handle.axis == moveGizmo.Axis.Z then
				self.p = plane:New(self.impactPosition, handle.Forward, self.handles[moveGizmo.Axis.Y].Forward)
				self.p2 = plane:New(self.impactPosition, handle.Forward, self.handles[moveGizmo.Axis.X].Forward)
			end

			if self.onDragBegin then
				self.onDragBegin(self.object.Position)
			end
			return true
		end
	end
	self.selectedHandle = nil
	return false
end

functions.setObject = function(self, object)
	if self.object == object then
		return
	end
	self.object = object
	if object == nil then
		self.gizmoObject:RemoveFromParent()
		return
	end

	if not self.hidden then
		self.gizmoObject:SetParent(World)
	end
	self:updateHandles()
end

functions.setOrientation = function(self, v)
	self.orientation = v
	self:updateHandles()
end

functions.updateHandles = function(self)
	if not self.object then
		return
	end

	if self.orientation == moveGizmo.Orientation.Local then
		self.gizmoObject.Rotation = self.object.Rotation
	else
		self.gizmoObject.Rotation = { 0, 0, 0 }
	end

	if self.orientation == moveGizmo.Orientation.World and self.object.Center ~= nil then
		self.gizmoObject.Position = self.object:BlockToWorld(self.object.Center)
	else
		self.gizmoObject.Position = self.object.Position
	end

	-- Does not hide or rotate handles if moving gizmo
	if self.selectedHandle then
		return
	end

	self.handles[moveGizmo.Axis.X].Forward = self.gizmoObject.Right
	self.handles[moveGizmo.Axis.Y].Forward = self.gizmoObject.Up
	self.handles[moveGizmo.Axis.Z].Forward = self.gizmoObject.Forward

	for _, handle in ipairs(self.handles) do
		local v = self.gizmoObject.Position - Camera.Position
		v:Normalize()
		local crossProduct = handle.Forward:Dot(v) - 0.001 -- Avoid glitch when attaching object to Camera
		handle.IsHidden = math.abs(crossProduct) >= 0.98 -- threshold to hide handle
		-- Revert if camera on the other side, not for axis Y
		if crossProduct > 0 then
			handle.Forward = -handle.Forward
		end
	end
end

functions.setAxisVisibility = function(self, x, y, z)
	self.handles[moveGizmo.Axis.X]:setVisible(x == true)
	self.handles[moveGizmo.Axis.Y]:setVisible(y == true)
	self.handles[moveGizmo.Axis.Z]:setVisible(z == true)
end

functions.setScale = function(self, scale)
	self.gizmoObject.Scale = scale
end

mt = {
	__gc = function(t)
		for _, l in ipairs(t.listeners) do
			l:Remove()
		end
		t.listeners = nil
	end,
	__index = {
		show = functions.show,
		hide = functions.hide,
		isShown = functions.isShown,
		setObject = functions.setObject,
		setOrientation = functions.setOrientation,
		updateHandles = functions.updateHandles,
		setAxisVisibility = functions.setAxisVisibility,
		setScale = functions.setScale,
		setLayer = functions.setLayer,
	},
	__metatable = false,
}

-- Variables shared by all gizmo instances:

local scale = 1.0
local layer = nil
local camera = Camera()
camera:SetParent(Camera)
camera.On = true

moveGizmo.setLayer = function(_, l)
	layer = l
	camera.Layers = l
end
moveGizmo.setLayer(2) -- TODO: we need a way to ask for unused layer

moveGizmo.setScale = function(_, s)
	scale = s
end

moveGizmo.create = function(_, config)
	local _config = { -- default config
		orientation = moveGizmo.Orientation.World,
		snap = 0.0,
		scale = scale,
		camera = camera,
	}

	local function sameType(a, b)
		if type(a) == type(b) then
			return true
		end
		if type(a) == "number" and type(b) == "integer" then
			return true
		end
		if type(a) == "integer" and type(b) == "number" then
			return true
		end
		return false
	end

	if config ~= nil then
		for k, v in pairs(_config) do
			if sameType(v, config[k]) then
				_config[k] = config[k]
			end
		end
	end

	local moveGizmo = {
		selectedHandle = nil,
		gizmoObject = nil,
		object = nil,
		orientation = _config.orientation,
		handles = {},
		snap = _config.snap,
		listeners = {},
		onDragBegin = nil,
		onDrag = nil,
		onDragEnd = nil,
		camera = _config.camera,
	}
	setmetatable(moveGizmo, mt)

	moveGizmo.gizmoObject = Object()
	moveGizmo.gizmoObject.Scale = _config.scale

	local axisColors = { Color.Red, Color.Green, Color.Blue }

	for axis, color in ipairs(axisColors) do
		local handle = MutableShape()

		handle:AddBlock(color, 0, 0, 0)
		handle.Pivot = Number3(0.5, 0.5, 0)
		handle.Scale = Number3(1, 1, 10)
		handle.Physics = PhysicsMode.Trigger

		handle.Layers = layer
		handle:SetParent(moveGizmo.gizmoObject)

		handle.axis = axis

		handle.setVisible = function(_, visible)
			if visible then
				handle:SetParent(moveGizmo.gizmoObject)
			else
				handle:RemoveFromParent()
			end
		end
		moveGizmo.handles[handle.axis] = handle
	end

	local l = LocalEvent:Listen(LocalEvent.Name.PointerDown, function(pe)
		return functions.down(moveGizmo, pe)
	end, { topPriority = true })
	table.insert(moveGizmo.listeners, l)

	l = LocalEvent:Listen(LocalEvent.Name.PointerUp, function(pe)
		return functions.up(moveGizmo, pe)
	end, { topPriority = true })
	table.insert(moveGizmo.listeners, l)

	l = LocalEvent:Listen(LocalEvent.Name.PointerDrag, function(pe)
		return functions.drag(moveGizmo, pe)
	end, { topPriority = true })
	table.insert(moveGizmo.listeners, l)

	l = LocalEvent:Listen(LocalEvent.Name.Tick, function(_)
		moveGizmo:updateHandles()
	end)
	table.insert(moveGizmo.listeners, l)

	return moveGizmo
end

return moveGizmo
