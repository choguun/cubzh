--- This module allows you to create User Interface components (buttons, labels, texts, etc.).

-- CONSTANTS

UI_FAR = 1000
UI_LAYER = 12
UI_LAYER_SYSTEM = 13
UI_COLLISION_GROUP = 12
UI_COLLISION_GROUP_SYSTEM = 13
UI_SHAPE_SCALE = 5
LAYER_STEP = -0.1 -- children offset
UI_FOREGROUND_DEPTH = -945
UI_ALERT_DEPTH = -950
BUTTON_PADDING = 4
BUTTON_BORDER = 3
BUTTON_UNDERLINE = 1
COMBO_BOX_SELECTOR_SPEED = 400

SCROLL_LOAD_MARGIN = 50
SCROLL_UNLOAD_MARGIN = 100
SCROLL_DEFAULT_RIGIDITY = 0.99
SCROLL_TIME_TO_TARGET = 0.1
SCROLL_EPSILON = 0.01
SCROLL_DRAG_EPSILON = 5
-- SCROLL_NB_TICKS_TO_DEFUSE_SPEED = 4
SCROLL_TIME_TO_DEFUSE_SPEED = 0.05

-- ENUMS

local State = {
	Idle = 0,
	Pressed = 1,
	Focused = 2,
	Disabled = 3,
	Selected = 4,
}

local NodeType = {
	None = 0,
	Frame = 1,
	Button = 2,
}

-- MODULES

codes = require("inputcodes")
cleanup = require("cleanup")
hierarchyActions = require("hierarchyactions")
sfx = require("sfx")
theme = require("uitheme").current
ease = require("ease")
conf = require("config")

-- GLOBALS

sharedUI = nil
sharedUIRootFrame = nil

systemUI = nil
systemUIRootFrame = nil

keyboardToolbar = nil

-- Using global to keep reference on focused node because
-- local within createUI conflicts between both uikit instances.
-- We could not find a better solution yet.
focused = nil

-- focused combo box
comboBoxSelector = nil

function focus(node)
	if focused ~= nil then
		if focused == node then
			return false -- already focused
		end
		if focused._unfocus ~= nil then
			focused:_unfocus()
		end
		focused = nil
	end
	focused = node

	if comboBoxSelector ~= nil then
		if comboBoxSelector.close ~= nil then
			comboBoxSelector:close()
			comboBoxSelector = nil
		end
	end

	applyVirtualKeyboardOffset()
	return true
end

function unfocus()
	focus(nil)
end

function getPointerXYWithinNode(pe, node)
	local x = pe.X * Screen.Width
	local y = pe.Y * Screen.Height
	local n = node
	while n do
		x = x - n.pos.X
		y = y - n.pos.Y
		n = n.parent
	end
	return Number2(x, y)
end

-- Pne UI instance is automatically created when requiring module.
-- a second one is also created for system menus.
-- This function is not exposed, thus no other instances can be created.
function createUI(system)
	local ui = {}

	-- exposing some constants used by other modules
	ui.kShapeScale = UI_SHAPE_SCALE
	ui.kButtonPadding = BUTTON_PADDING
	ui.kButtonBorder = BUTTON_BORDER
	ui.kForegroundDepth = UI_FOREGROUND_DEPTH
	ui.kAlertDepth = UI_ALERT_DEPTH

	----------------------
	-- VARS
	----------------------

	local rootChildren = {}

	-- The pointer index that's currently being used to interract with the UI.
	-- UI won't accept other pointer down events while this is not nil.
	local pointerIndex = nil

	-- Node that's currently being pressed
	local pressed = nil

	-- Scroll nodes pressed but not yet dragged
	-- NOTE: nested scrolls only work so far in moving along non-aligned axis (horizontal vs vertical)
	-- pressed is assigned to scroll node when drag starts (considering epsilon)
	local pressedScrolls = {}

	-- keeping a reference on all text items,
	-- to update fontsize when needed
	local texts = {}

	-- each Text gets a unique ID
	local nodeID = 1

	-- keeping current font size (based on screen size & density)
	local currentFontSize = Text.FontSizeDefault
	local currentFontSizeBig = Text.FontSizeBig
	local currentFontSizeSmall = Text.FontSizeSmall

	local pointerDownListener
	local pointerUpListener

	local privateFunctions = {}

	local function _setLayers(object)
		if system == true then
			System:SetLayersElevated(object, UI_LAYER_SYSTEM)
		else
			System:SetLayersElevated(object, UI_LAYER)
		end
	end

	ui.setLayers = _setLayers

	local function _setCollisionGroups(object)
		if system == true then
			System:SetCollisionGroupsElevated(object, UI_COLLISION_GROUP_SYSTEM)
		else
			System:SetCollisionGroupsElevated(object, UI_COLLISION_GROUP)
		end
	end

	local _groups
	local function _getCollisionGroups()
		if _groups == nil then
			if system == true then
				_groups = System:GetGroupsElevated({ UI_COLLISION_GROUP_SYSTEM })
			else
				_groups = System:GetGroupsElevated({ UI_COLLISION_GROUP })
			end
		end
		return _groups
	end

	-- INIT

	Pointer:Show()

	-- Orthographic camera, to render UI
	local camera = Camera()
	camera:SetParent(World)
	camera.On = true
	camera.Far = UI_FAR
	_setLayers(camera)
	camera.Projection = ProjectionMode.Orthographic
	camera.Width = Screen.Width
	camera.Height = Screen.Height

	-- Top level object, containing all UI nodes
	local rootFrame = Object()
	if system == true then
		systemUIRootFrame = rootFrame
	else
		sharedUIRootFrame = rootFrame
	end

	rootFrame:SetParent(World)
	rootFrame.LocalPosition = { -Screen.Width * 0.5, -Screen.Height * 0.5, UI_FAR }

	local function _setupUIObject(object, collides)
		hierarchyActions:applyToDescendants(object, { includeRoot = true }, function(o)
			if type(o) == "Object" then
				return
			end
			_setLayers(o)
			o.IsUnlit = true

			o.CollidesWithGroups = {}
			o.CollisionGroups = {}
			o.Physics = PhysicsMode.Disabled
		end)

		if collides and object.Width ~= nil and object.Height ~= nil then
			object.Physics = PhysicsMode.Trigger
			_setCollisionGroups(object)
			object.CollisionBox = Box({ 0, 0, 0 }, { object.Width, object.Height, 0.1 })
		end
	end

	local function _nodeSetParent(self, parent)
		local attr = getmetatable(self).attr

		-- setting same parent, nothing to do
		if parent ~= nil then
			if parent.object ~= nil and attr.parent == parent then
				return
			end
		end

		-- remove from current parent
		if attr.object ~= nil then
			attr.object:SetParent(nil)
		end
		if attr.parent.children ~= nil then
			attr.parent.children[self._id] = nil
		end
		-- in case node parent was root
		rootChildren[self._id] = nil
		attr.parent = nil

		if parent == nil then
			return
		end

		local parentObject

		if parent.object ~= nil then
			attr.parent = parent
			parent.children[self._id] = self
			parentObject = parent.object
		else
			if parent == rootFrame then
				rootChildren[self._id] = self
			end
			parentObject = parent
		end

		if type(parentObject.AddChild) ~= "function" then
			error("uikit:setParent(parent): parent must be a node", 2)
		end

		attr.object:SetParent(parentObject)

		if self.shape == nil then
			attr.object.LocalPosition.Z = (parentObject.ChildrenCount + 1) * LAYER_STEP
		else
			-- use custom step for shapes, to make sure above their parent,
			-- could be improved considering Pivot, bounding box, scale...
			-- local s = self.shape
			-- local max = math.max(math.max(s.Width * s.Scale.X, s.Depth * s.Scale.Z), s.Height * s.Scale.Y)
			-- local max = math.max(math.max(self.Width, self.Height), self.Depth)
			-- attr.object.LocalPosition.Z = (parentObject.ChildrenCount + 1) * LAYER_STEP - max

			-- displaying shapes at mid camera far distance
			-- to decrease chances of clipping. This is not ideal...
			-- 0.45 instead of 0.5 to let room for alerts in front
			-- (quick fix for shapes clipping with alert background)
			attr.object.LocalPosition.Z = -UI_FAR * 0.45
		end

		_parentDidResizeWrapper(self)
	end

	local function _nodeHasParent(self)
		return self.object:GetParent() ~= nil
	end

	-- using public wrapper to limit to 1 parameter
	-- (it should not be possible to override the `toClean` table)
	privateFunctions._nodeRemovePublicWrapper = function(t)
		privateFunctions._nodeRemove(t)
	end

	privateFunctions._nodeRemove = function(t, toClean)
		local cleanupWhenDone = false

		if toClean == nil then
			cleanupWhenDone = true
			toClean = {}
		end

		_onRemoveWrapper(t)

		t:setParent(nil)

		-- in case node is a Text
		texts[t._id] = nil

		if pressed == t then
			pressed = nil
		end

		if focused == t then
			focus(nil)
		end

		if t.object then
			t.object:RemoveFromParent()
			t.object = nil
		end

		for _, child in pairs(t.children) do
			if child.remove ~= nil then
				privateFunctions._nodeRemove(child, toClean)
			end
		end

		table.insert(toClean, t)

		if cleanupWhenDone then
			for _, node in ipairs(toClean) do
				cleanup(node)
			end
		end
	end

	local function _buttonRefreshColor(node)
		local state = node.state
		local colors
		local textColor

		if state == State.Pressed then
			colors = node.colorsPressed
			textColor = node.textColorPressed
		else
			if node.selected then
				colors = node.colorsSelected
				textColor = node.textColorSelected
			elseif node.disabled then
				colors = node.colorsDisabled
				textColor = node.textColorDisabled
			else
				colors = node.colors
				textColor = node.textColor
			end
		end

		node.background.Color = colors[1]
		if #node.borders > 0 then
			node.borders[1].Color = colors[2]
			node.borders[2].Color = colors[2]
			node.borders[3].Color = colors[3]
			node.borders[4].Color = colors[3]
		end

		if node.underline ~= nil then
			node.underline.Color = textColor
		end

		if node.content.Text then
			node.content.Color = textColor
		end
	end

	local function _buttonRefresh(self)
		if self.content == nil then
			return
		end

		local padding = BUTTON_PADDING
		local border = BUTTON_BORDER
		local underlinePadding = 0

		if self.config.padding == false then
			padding = 0
		end

		if self.config.borders == false then
			border = 0
			padding = 2 * padding
		end

		if self.config.underline then
			underlinePadding = BUTTON_UNDERLINE * 2
		end

		local paddingAndBorder = padding + border

		local content = self.content

		local paddingLeft = paddingAndBorder
		local paddingBottom = paddingAndBorder
		local totalWidth
		local totalHeight

		if self.fixedWidth ~= nil then
			totalWidth = self.fixedWidth
			paddingLeft = (totalWidth - content.Width) * 0.5
		else
			totalWidth = content.Width + paddingAndBorder * 2
		end

		if self.fixedHeight ~= nil then
			totalHeight = self.fixedHeight
			paddingBottom = (totalHeight - content.Height) * 0.5
		else
			totalHeight = content.Height + paddingAndBorder * 2 + underlinePadding
		end

		local background = self.background
		if background == nil then
			return
		end

		background.Scale.X = totalWidth
		background.Scale.Y = totalHeight

		background.LocalPosition = { 0, 0, 0 }

		content.LocalPosition = { totalWidth * 0.5 - content.Width * 0.5, totalHeight * 0.5 - content.Height * 0.5 }

		if #self.borders > 0 then
			content.LocalPosition = { paddingLeft, paddingBottom, 0 }
			local top = self.borders[1]
			local right = self.borders[2]
			local bottom = self.borders[3]
			local left = self.borders[4]

			top.Scale.X = totalWidth
			top.Scale.Y = BUTTON_BORDER
			top.LocalPosition = { 0, totalHeight - BUTTON_BORDER, LAYER_STEP }

			right.Scale.X = BUTTON_BORDER
			right.Scale.Y = totalHeight - BUTTON_BORDER * 2
			right.LocalPosition = { totalWidth - BUTTON_BORDER, BUTTON_BORDER, LAYER_STEP }

			bottom.Scale.X = totalWidth
			bottom.Scale.Y = BUTTON_BORDER
			bottom.LocalPosition = { 0, 0, LAYER_STEP }

			left.Scale.X = BUTTON_BORDER
			left.Scale.Y = totalHeight - BUTTON_BORDER * 2
			left.LocalPosition = { 0, BUTTON_BORDER, LAYER_STEP }
		end

		if self.underline ~= nil then
			self.underline.Scale.X = totalWidth
			self.underline.Scale.Y = BUTTON_UNDERLINE
			self.underline.LocalPosition = { 0, 0, LAYER_STEP }
		end

		if self.shadow then
			self.shadow.Scale.X = totalWidth - BUTTON_BORDER * 2
			self.shadow.Scale.Y = BUTTON_BORDER
			self.shadow.LocalPosition = { BUTTON_BORDER, -BUTTON_BORDER, 0 }
		end
	end

	local function _buttonOnPress(self, callback, obj, block, pe)
		if self.disabled == true then
			return
		end

		self.state = State.Pressed
		_buttonRefreshColor(self)
		if callback ~= nil then
			callback(self, obj, block, pe)
		end

		Client:HapticFeedback()
	end

	local function _buttonOnRelease(self, callback)
		if self.disabled == true then
			return
		end

		self.state = State.Idle
		_buttonRefreshColor(self)
		if callback ~= nil then
			callback(self)
		end
	end

	local function _buttonOnCancel(self, callback)
		if self.disabled == true then
			return
		end

		self.state = State.Idle
		_buttonRefreshColor(self)
		if callback ~= nil then
			callback(self)
		end
	end

	local function _nodeIndex(t, k)
		local m = getmetatable(t)

		if k == "Width" then
			if t._width ~= nil then
				if type(t._width) == "function" then
					return t:_width()
				else
					return t._width
				end
			else
				return 0
			end
		elseif k == "Height" then
			if t._height ~= nil then
				if type(t._height) == "function" then
					return t:_height()
				else
					return t._height
				end
			else
				return 0
			end
		elseif k == "Depth" then
			if t._depth ~= nil then
				if type(t._depth) == "function" then
					return t:_depth()
				else
					return t._depth
				end
			else
				return 0
			end
		elseif k == "pos" or k == "position" or k == "Position" or k == "LocalPosition" then
			return t.object.LocalPosition
		elseif k == "size" or k == "Size" then
			return Number2(t.Width, t.Height)
		elseif k == "text" or k == "Text" then
			if t._text ~= nil then
				if type(t._text) == "function" then
					return t:_text()
				else
					return t._text
				end
			end
		elseif k == "color" or k == "Color" then
			if t._color ~= nil then
				if type(t._color) == "function" then
					return t:_color()
				else
					return t._color
				end
			else
				return nil
			end
		elseif k == "onRelease" then
			return t._onRelease
		elseif k == "onPress" then
			return t._onPress
		elseif k == "onCancel" then
			return t._onCancel
		elseif k == "onDrag" then
			return t._onDrag
		end

		local v = m.attr[k]
		if v ~= nil then
			return v
		end

		return m.attr.object[k]
	end

	local function _nodeNewindex(t, k, v)
		local m = getmetatable(t)
		local attr = m.attr

		if k == "onPressPrecise" then
			k = "onPress"
			print("⚠️ onPressPrecise is deprecated, use onPress")
		elseif k == "onReleasePrecise" then
			k = "onRelease"
			print("⚠️ onReleasePrecise is deprecated, use onRelease")
		end

		if k == "color" or k == "Color" then
			attr.color = v
			if t._setColor ~= nil then
				t:_setColor(v)
			end
		elseif k == "onPress" then
			if t.type == NodeType.Button then
				t._onPress = function(self, object, block, pe)
					_buttonOnPress(self, v, object, block, pe)
				end
			elseif t.type == NodeType.Frame then
				local background = t.background
				if v == nil then
					t._onPress = nil
					if t._onRelease == nil then
						background.Physics = PhysicsMode.Disabled
						background.CollisionGroups = {}
					end
				elseif v ~= nil then
					background.Physics = PhysicsMode.Trigger
					_setCollisionGroups(background)
					background.CollisionBox = Box({ 0, 0, 0 }, { background.Width, background.Height, 0.1 })
					t._onPress = function(self, object, block, pe)
						if v ~= nil then
							v(self, object, block, pe)
						end
					end
				end
			else
				if t._setCollider then
					t:_setCollider(v ~= nil)
				end
				t._onPress = function(self, object, block, pe)
					if v ~= nil then
						v(self, object, block, pe)
					end
				end
			end
		elseif k == "onRelease" then
			if t.type == NodeType.Button then
				t._onRelease = function(self)
					_buttonOnRelease(self, v)
				end
			elseif t.type == NodeType.Frame then
				local background = t.background
				if v == nil then
					t._onRelease = nil
					if t._onPress == nil then
						background.Physics = PhysicsMode.Disabled
						background.CollisionGroups = {}
					end
				elseif v ~= nil then
					background.Physics = PhysicsMode.Trigger
					_setCollisionGroups(background)
					background.CollisionBox = Box({ 0, 0, 0 }, { background.Width, background.Height, 0.1 })
					t._onRelease = function(self)
						if v ~= nil then
							v(self)
						end
					end
				end
			else
				if t._setCollider then
					t:_setCollider(v ~= nil)
				end
				t._onRelease = function(self, object, block)
					if v ~= nil then
						v(self, object, block)
					end
				end
			end
		elseif k == "onCancel" then
			if t.type == NodeType.Button then
				t._onCancel = function(self)
					_buttonOnCancel(self, v)
				end
			else
				t._onCancel = function(self)
					if v ~= nil then
						v(self)
					end
				end
			end
		elseif k == "onDrag" then
			t._onDrag = function(self, pe)
				if v ~= nil then
					v(self, pe)
				end
			end
		elseif k == "Pivot" then
			if t.background ~= nil and t.background.Pivot ~= nil then
				t.background.Pivot = v
			elseif t.object.Pivot ~= nil then
				t.object.Pivot = v
			elseif t.object.Anchor ~= nil then
				if type(v) == "table" then
					t.object.Anchor = Number2(v[1], v[2])
				elseif type(v) == "Number3" then
					t.object.Anchor = Number2(v.X, v.Y)
				end
			end
			-- TODO: node could use a separate internal object when it needs a pivot, to be type-agnostic
		elseif k == "pos" or k == "position" or k == "Position" or k == "LocalPosition" then
			local isNumber = function(val)
				return type(val) == "number" or type(val) == "integer"
			end

			if type(v) ~= "table" and type(v) ~= "Number2" and type(v) ~= "Number3" then
				error("uikit: node." .. k .. " must be a Number2", 2)
			end
			if type(v) == "table" then
				if #v < 2 then
					error("uikit: node." .. k .. " must be a Number2", 2)
				end
				if isNumber(v[1]) == false or isNumber(v[2]) == false then
					error("uikit: node." .. k .. " subvalues must be numbers", 2)
				end
			end

			local obj = t.object
			local z = obj.LocalPosition.Z
			-- convert to Number3
			if type(v) == "Number2" then
				v = Number3(v.X, v.Y, 0)
			elseif type(v) == "table" and #v == 2 then
				v = Number3(v[1], v[2], 0)
			end
			obj.LocalPosition = v -- v is a Number3
			obj.LocalPosition.Z = z -- restore Z (layer)
		elseif k == "size" or k == "Size" then
			if type(v) == "number" or type(v) == "integer" then
				v = Number2(v, v)
			end
			if type(v) == "table" and v[1] ~= nil and v[2] ~= nil then
				v = Number2(v[1], v[2])
			end
			if type(v) ~= "Number2" then
				error(k .. " must be a Number2", 2)
			end
			if not pcall(function()
				t.Width = v.X
				t.Height = v.Y
			end) then
				error(k .. " can't be set", 2)
			end
		elseif k == "rot" or k == "rotation" or k == "Rotation" or k == "LocalRotation" then
			t.object.LocalRotation = v
		elseif k == "IsHidden" then
			t.object.IsHidden = v
		elseif k == "IsMask" then
			if t._setIsMask ~= nil then
				t:_setIsMask(v)
			end
		elseif k == "Width" then
			if t.Width == v then
				return
			end -- don't do anything if setting same Width

			if t._setWidth ~= nil then
				t:_setWidth(v)

				for _, child in pairs(t.children) do
					_parentDidResizeWrapper(child)
				end

				if t.parent ~= nil then
					_contentDidResizeWrapper(t.parent)
				end
			end
		elseif k == "Height" then
			if t.Height == v then
				return
			end -- don't do anything if setting same Height

			if t._setHeight ~= nil then
				t:_setHeight(v)

				for _, child in pairs(t.children) do
					_parentDidResizeWrapper(child)
				end

				if t.parent ~= nil then
					_contentDidResizeWrapper(t.parent)
				end
			end
		elseif k == "text" or k == "Text" then
			if t._setText ~= nil then
				if type(t._setText) == "function" then
					local r = t:_setText(v)
					_contentDidResizeWrapper(t)
					return r
				end
			else
				attr[k] = v
			end
		else
			-- TMP, to help fixing script
			if k == "width" then
				error("width -> _width", 2)
			end
			if k == "height" then
				error("height -> _height", 2)
			end
			attr[k] = v
		end
	end

	local function _nodeShow(self)
		if not self.object then
			return
		end
		if self.parent.object then
			self.object:SetParent(self.parent.object)
		else
			self.object:SetParent(rootFrame)
		end
		self.object.IsHidden = false
	end

	function _nodeHide(self)
		if not self.object then
			return
		end
		self.object:RemoveFromParent()
		self.object.IsHidden = true
	end

	function _nodeToggle(self, show)
		if show == nil then
			show = self:isVisible() == false
		end
		if show then
			self:show()
		else
			self:hide()
		end
	end

	function _nodeIsVisible(self)
		return self.object.IsHidden == false
	end

	function _nodeHasFocus(self)
		return focused == self
	end

	local function _nodeCreate()
		local node = {}

		local m = {
			attr = {
				-- can be a Shape, Text, Object...
				-- depending on node type
				object = nil,
				color = nil,
				parent = nil,
				type = NodeType.None,
				children = {},
				parentDidResize = nil,
				parentDidResizeSystem = nil,
				contentDidResize = nil,
				contentDidResizeSystem = nil,
				onRemove = nil,
				onRemoveSystem = nil,
				setParent = _nodeSetParent,
				hasParent = _nodeHasParent,
				remove = privateFunctions._nodeRemovePublicWrapper,
				show = _nodeShow,
				hide = _nodeHide,
				toggle = _nodeToggle,
				isVisible = _nodeIsVisible,
				hasFocus = _nodeHasFocus,
				-- returned when requesting Width if defined
				-- can be a number or function(self) that returns a number
				_width = nil,
				-- returned when requesting Height if defined
				-- can be a number or function(self) that returns a number
				_height = nil,
				-- returned when requesting text/Text if defined
				-- can be a string or function(self) that returns a string
				_text = nil,
				-- called when setting text/Text if defined
				-- function(self,string)
				_setText = nil,
				-- returned when requesting color/Color if defined
				-- can be a Color or function(self) that returns a string
				_color = nil,
				-- called when setting color/Color if defined
				-- function(self,color)
				_setColor = nil,
			},
			__index = _nodeIndex,
			__newindex = _nodeNewindex,
		}
		setmetatable(node, m)

		node._id = nodeID
		nodeID = nodeID + 1

		return node
	end

	local function _refreshShapeNode(node)
		if node.shape == nil then
			return
		end

		if node.shape:GetParent() == nil then
			node.shapeContainer:AddChild(node.shape)
		end
		node.shape.LocalPosition:Set(Number3.Zero)
		node.shape.LocalRotation:Set(Number3.Zero)

		local backupScale = node.object.LocalScale:Copy()
		node.object.LocalScale = 1
		node.pivot.LocalPosition = Number3.Zero
		node.shapeContainer.LocalPosition = Number3.Zero

		-- the shape scale is always 1
		-- in the context of a shape node, we always apply scale to the parent object
		node.shape.LocalScale = 1

		node.pivot.LocalRotation:Set(0, 0, 0)

		-- NOTE: Using AABB in pivot space to infer size & placement.
		local aabb = Box()
		aabb:Fit(node.pivot, { recursive = true, ["local"] = true })

		if not node._config.doNotFlip then
			node.pivot.LocalRotation:Set(0, math.pi, 0) -- shape's front facing camera
		end

		node._aabbWidth = aabb.Max.X - aabb.Min.X
		node._aabbHeight = aabb.Max.Y - aabb.Min.Y
		node._aabbDepth = aabb.Max.Z - aabb.Min.Z

		if node._config.spherized then
			node._diameter = math.sqrt(node._aabbWidth ^ 2 + node._aabbHeight ^ 2 + node._aabbDepth ^ 2)
		end

		-- center Shape within pivot
		-- considering Shape's pivot but not modifying it
		-- It could be important for shape's children placement.

		if node._config.spherized then
			local radius = node.Width * 0.5
			node.pivot.LocalPosition:Set(radius, radius, radius)
		else
			node.pivot.LocalPosition:Set(node.Width * 0.5, node.Height * 0.5, node.Depth * 0.5)
		end

		node.shapeContainer.LocalPosition:Set(-aabb.Center + node._config.offset)
		node.object.LocalScale = backupScale
	end

	local function _textInputRefreshColor(node)
		local state = node.state
		local colors
		local textColor
		local placeholderColor

		if state == State.Pressed then
			colors = node.colorsPressed
			textColor = node.textColorPressed
			placeholderColor = node.placeholderColorPressed
		else
			if node.disabled then
				colors = node.colorsDisabled
				textColor = node.textColorDisabled
				placeholderColor = node.placeholderColorDisabled
			elseif state == State.Focused then
				colors = node.colorsFocused
				textColor = node.textColorFocused
				placeholderColor = node.placeholderColorFocused
			else
				colors = node.colors
				textColor = node.textColor
				placeholderColor = node.placeholderColor
			end
		end

		node.background.Color = colors[1]
		node.border.Color = colors[2]
		node.string.Color = textColor
		node.placeholder.Color = placeholderColor
	end

	local function _textInputRefresh(node)
		-- to avoid refresh triggering a call to itself
		local backup = node._refresh
		node._refresh = nil

		local theme = require("uitheme").current

		local padding = theme.padding
		local border = theme.textInputBorderSize

		local paddingAndBorder = padding + border

		local textContainer = node.textContainer
		local placeholder = node.placeholder
		local str = node.string

		local hiddenStr
		if node.hiddenString then
			hiddenStr = node.hiddenString
		end

		local cursor = node.cursor

		if #str.Text > 0 then
			placeholder:hide()
		else
			placeholder:show()
		end

		local h
		h = str.Height + paddingAndBorder * 2
		node.border.Height = h
		node.background.Height = h - theme.textInputBorderSize * 2

		textContainer.Width = node.Width - border * 2
		textContainer.Height = node.Height - border * 2

		textContainer.pos = { border, border, 0 }

		placeholder.pos = { padding, textContainer.Height * 0.5 - placeholder.Height * 0.5, 0 }
		str.pos = { padding, textContainer.Height * 0.5 - str.Height * 0.5, 0 }
		if hiddenStr ~= nil then
			hiddenStr.pos = str.pos
		end

		if node.state == State.Focused then
			if str.Width > textContainer.Width - padding * 2 then
				str.pos.X = padding - str.Width + (textContainer.Width - padding * 2)
			end

			if hiddenStr ~= nil and hiddenStr.Width > textContainer.Width - padding * 2 then
				hiddenStr.pos.X = padding - hiddenStr.Width + (textContainer.Width - padding * 2)
			end

			cursor.Height = str.Height
		end

		node._refresh = backup
	end

	-- EXPOSED FUNCTIONS

	ui.isShown = function(_)
		return rootFrame:GetParent() ~= nil
	end

	ui.hide = function(_)
		rootFrame:SetParent(nil)
	end

	ui.show = function(_)
		rootFrame:SetParent(World)
	end

	ui.turnOff = function(_)
		pointerDownListener:Pause()
		pointerUpListener:Pause()
	end

	ui.turnOn = function(_)
		pointerDownListener:Resume()
		pointerUpListener:Resume()
	end

	ui.createNode = function(_)
		local node = _nodeCreate()
		node.object = Object()
		node.object.LocalPosition = { 0, 0, 0 }

		node:setParent(rootFrame)

		return node
	end

	ui.createFrame = function(self, color, config)
		if self ~= ui then
			error("ui:createFrame(color, config): use `:`", 2)
		end
		if color ~= nil and type(color) ~= Type.Color then
			error("ui:createFrame(color, config): color should be a Color or nil", 2)
		end
		if config ~= nil and type(config) ~= Type.table then
			error("ui:createFrame(color, config): config should be a table", 2)
		end

		local _config = {
			unfocuses = false, -- unfocused focused node when true
			image = nil,
		}

		if type(config.unfocuses) == "boolean" then
			_config.unfocuses = config.unfocuses
		end

		color = color or Color(0, 0, 0, 0) -- default transparent frame
		local node = _nodeCreate()
		node.type = NodeType.Frame

		node.config = _config

		local background = Quad()
		if node.config.image == nil then
			background.Color = color
			background.IsDoubleSided = false
		else
			background.Image = node.config.image
			background.IsDoubleSided = true
		end

		_setupUIObject(background)

		node.object = background

		background._node = node
		node.background = background

		node._setIsMask = function(_, b)
			background.IsMask = b
		end

		node._color = function(self)
			return self.background.Color
		end

		node._setColor = function(self, color)
			self.background.Color = color
		end

		node.setColor = function(self, color)
			if self ~= node then
				error("frame:setColor(color): use `:`", 2)
			end
			if type(color) ~= Type.Color then
				error("frame:setColor(color): color should be a Color", 2)
			end
			self:_setColor(color)
		end

		node.setImage = function(self, image)
			if self ~= node then
				error("frame:setImage(image): use `:`", 2)
			end
			if image ~= nil and type(image) ~= Type.Data then
				error("frame:setImage(image): image should be a Data instance", 2)
			end

			self.background.Image = image
			if image ~= nil then
				self.background.Color = Color.White
				self.background.IsDoubleSided = true
			else
				self.background.Color = color
				self.background.IsDoubleSided = false
			end
		end

		node._width = function(self)
			return self.background.Width
		end
		node._height = function(self)
			return self.background.Height
		end
		node._depth = function(_)
			return 0
		end

		node._setWidth = function(self, v)
			self.background.Width = v
			self.background.CollisionBox = Box({ 0, 0, 0 }, { background.Width, background.Height, 0.1 })
		end

		node._setHeight = function(self, v)
			self.background.Height = v
			self.background.CollisionBox = Box({ 0, 0, 0 }, { background.Width, background.Height, 0.1 })
		end

		if config ~= nil and config.image ~= nil then
			if type(config.image) ~= Type.Data then
				error("ui:createFrame(color, config): config.image should be a Data instance", 2)
			end
			node:setImage(config.image)
		end

		node.object.LocalPosition = { 0, 0, 0 }

		node:setParent(rootFrame)

		return node
	end

	-- NOTES (needs proper documentation)
	-- When the shapeNode needs to be rotated, prefer node.size accessor
	-- Otherwise and when it's required to rely on precize (sharp edge) width & height, use node.width * node.height
	-- But the item can't be rotated when doing to.
	-- It could be improved at some point, computing onscreen bounding box when rotating the item.
	--[[
	-- Returns a UI node displaying a regular Shape or MutableShape.
	-- @param shape {Shape,MutableShape} -
	-- @param config {table} -
	]]
	ui.createShape = function(_, shape, config)
		if shape == nil or (type(shape) ~= "Object" and type(shape) ~= "Shape" and type(shape) ~= "MutableShape") then
			error("ui:createShape(shape) expects a non-nil Shape or MutableShape", 2)
		end

		local node = _nodeCreate()

		local defaultConfig = {
			spherized = false,
			doNotFlip = false,
			offset = Number3.Zero,
			perBlockCollisions = false,
		}

		config = conf:merge(defaultConfig, config)
		node._config = config

		node.object = Object()
		node.object.LocalScale = UI_SHAPE_SCALE

		node.pivot = Object()
		node.shapeContainer = Object()

		node.object:AddChild(node.pivot)
		node.pivot:AddChild(node.shapeContainer)

		-- _diameter defined within _refreshShapeNode
		node.refresh = _refreshShapeNode

		-- getters

		node._width = function(self)
			if config.spherized then
				return self._diameter * self.object.LocalScale.X
			else
				return self._aabbWidth * self.object.LocalScale.X
			end
		end

		node._height = function(self)
			if config.spherized then
				return self._diameter * self.object.LocalScale.X
			else
				return self._aabbHeight * self.object.LocalScale.Y
			end
		end

		node._depth = function(self)
			if config.spherized then
				return self._diameter * self.object.LocalScale.X
			else
				return self._aabbDepth * self.object.LocalScale.Z
			end
		end

		-- setters

		node._setCollider = function(self, b)
			if self.shape == nil then
				return
			end
			if b then
				if config.perBlockCollisions then
					self.shape.Physics = PhysicsMode.TriggerPerBlock
				else
					self.shape.Physics = PhysicsMode.Trigger
				end
				_setCollisionGroups(self.shape)
			else
				self.shape.Physics = PhysicsMode.Disabled
				self.shape.CollisionGroups = {}
			end
		end

		node._setWidth = function(self, newWidth)
			if newWidth == nil then
				return
			end
			if config.spherized then
				if self._diameter == 0 then
					return
				end
				self.object.LocalScale = newWidth / self._diameter
			else
				if self._aabbWidth == 0 then
					return
				end
				self.object.LocalScale.X = newWidth / self._aabbWidth
			end
		end

		node._setHeight = function(self, newHeight)
			if newHeight == nil then
				return
			end
			if config.spherized then
				if self._diameter == 0 then
					return
				end
				self.object.LocalScale = newHeight / self._diameter
			else
				if self._aabbHeight == 0 then
					return
				end
				self.object.LocalScale.Y = newHeight / self._aabbHeight
			end
		end

		node._setDepth = function(self, newDepth)
			if config.spherized then
				if self._diameter == 0 then
					return
				end
				self.object.LocalScale = newDepth / self._diameter
			else
				if self._aabbDepth == 0 then
					return
				end
				self.object.LocalScale.Z = newDepth / self._aabbDepth
			end
		end

		node.setShape = function(self, shape, doNotRefresh)
			local w = nil
			local h = nil

			if self.shape ~= nil then
				w = self.Width
				h = self.Height
				self.shape:RemoveFromParent()
				self.shape._node = nil
				self.shape = nil
			end

			shape:RemoveFromParent()
			_setupUIObject(shape)
			self.shape = shape
			shape._node = self

			node.shapeContainer:AddChild(shape)
			shape.LocalPosition = Number3.Zero

			if doNotRefresh ~= true then
				self:refresh()
				if w ~= nil then
					self.Width = w
				end
				if h ~= nil then
					self.Height = h
				end
			end
		end

		node:setShape(shape, true)

		node:refresh()

		node:setParent(rootFrame)

		return node
	end

	---@function createText Creates a text component.
	---@param string str
	---@param table? config
	---@code -- nodes can have an image if provided image Data (PNG or JPEG)
	--- local url = "https://cu.bzh/img/pen.png"
	--- HTTP:Get(url, function(response)
	---		local f = uikit:createFrame(Color.Black, {image = response.Data})
	---		f:setParent(uikit.rootFrame)
	---		f.LocalPosition = {50, 50, 0}
	--- end)
	-- LEGACY: expecting config table, but it's still ok to provide color and size
	ui.createText = function(_, str, configOrcolor, size) -- "default" (default), "small", "big"
		if str == nil then
			error("ui:createText(str, config) str must be a string", 2)
		end

		local defaultConfig = {
			color = Color(0, 0, 0),
			backgroundColor = Color(0, 0, 0, 0),
			size = "default",
		}

		local config = nil
		if configOrcolor ~= nil then
			if type(configOrcolor) == Type.Color then
				defaultConfig.color = configOrcolor
			else
				config = configOrcolor
			end
		end

		if size ~= nil then
			if type(size) ~= "string" or (size ~= "default" and size ~= "small" and size ~= "big") then
				error('ui:createText(str, color, size) - size must be a string ("default", "small" or "big")', 2)
			end
			defaultConfig.size = size
		end

		local ok, err = pcall(function()
			config = conf:merge(defaultConfig, config)
		end)
		if not ok then
			error("ui:createText(str, config) - config error: " .. err, 2)
		end

		local node = _nodeCreate()
		texts[node._id] = node

		node._text = function(self)
			return self.object.Text
		end

		node._setText = function(self, str)
			if self.object then
				self.object.Text = str
			end
		end

		node._color = function(self)
			return self.object.Color
		end

		node._setColor = function(self, color)
			self.object.Color = color
		end

		node._width = function(self)
			return self.object.Width * self.object.LocalScale.X
		end

		node._height = function(self)
			return self.object.Height * self.object.LocalScale.Y
		end

		-- TODO: max width

		local t = Text()
		t.Anchor = { 0, 0 }
		t.Type = TextType.World
		t.Font = Font.Noto
		_setLayers(t)
		t.Text = str
		t.Padding = 0
		t.Color = config.color
		t.BackgroundColor = config.backgroundColor
		t.MaxDistance = camera.Far + 100

		if config.size == "big" then
			t.FontSize = currentFontSizeBig
		elseif config.size == "small" then
			t.FontSize = currentFontSizeSmall
		else
			t.FontSize = currentFontSize
		end

		t.IsUnlit = true
		t.Physics = PhysicsMode.Disabled
		t.CollisionGroups = {}
		t.CollidesWithGroups = {}
		t.LocalPosition:Set(Number3.Zero)

		node.object = t

		node:setParent(rootFrame)

		node.select = function(self, cursorStart, cursorEnd)
			if self ~= node then
				error("text:select(start, end) should be called with `:`", 2)
			end
			if type(cursorStart) ~= "integer" then
				error("text:select(start, end) - start should be an integer", 2)
			end
			if cursorEnd == nil then
				cursorEnd = cursorStart
			end
			if type(cursorEnd) ~= "integer" then
				error("text:select(start, end) - end should be an integer", 2)
			end
		end

		-- returns both char index and position cursor's snapped position
		node.localPositionToCursor = function(self, pos)
			if self ~= node then
				error("text:localPositionToCursor(pos) should be called with `:`", 2)
			end
			local posType = type(pos)
			if posType ~= "Number2" and posType ~= "table" then
				error("text:localPositionToCursor(pos) - pos should be a Number2 or table with 2 numbers", 2)
			end

			local t = self.object
			local charIndex = 0
			local cursorPos = 0

			local ok, err = pcall(function()
				cursorPos, charIndex = t:LocalToCursor(pos)
			end)

			if not ok then
				error("text:localPositionToCursor(pos) " .. err, 2)
			end

			return charIndex, cursorPos
		end

		node.charIndexToCursor = function(self, charIndex)
			if self ~= node then
				error("text:charIndexToCursor(charIndex) should be called with `:`", 2)
			end
			if type(charIndex) ~= "integer" then
				error("text:charIndexToCursor(charIndex) - charIndex should be an integer", 2)
			end

			local t = self.object
			local verifiedCharIndex = 0
			local cursorPos = 0

			local ok, err = pcall(function()
				cursorPos, verifiedCharIndex = t:CharIndexToCursor(charIndex)
			end)

			if not ok then
				error("text:charIndexToCursor(charIndex) " .. err, 2)
			end

			return verifiedCharIndex, cursorPos
		end

		return node
	end

	function _textInputTextDidChange(textInput)
		if textInput.hiddenString then
			textInput.hiddenString.Text = string.rep("*", #textInput.Text)
		end

		if textInput.onTextChange then
			textInput:onTextChange()
		end
		textInput:_refresh()
	end

	-- ui:createTextInput(<string>, <placeholder>, <size>)
	ui.createTextInput = function(self, str, placeholder, configOrSize) -- "default" (default), "small", "big"
		local defaultConfig = {
			password = false,
			textSize = "default",
			multiline = false, -- not yet implemented
			returnKeyType = "done", -- options: "default", "done", "send", "next"
			keyboardType = "default", -- other options: "email", "phone", "numbers", "url", "ascii"
		}

		local config = {}

		if type(configOrSize) == "string" then
			config.textSize = configOrSize
			config = conf:merge(defaultConfig, config)
		elseif type(configOrSize) == "table" then
			config = conf:merge(defaultConfig, configOrSize)
		else
			config = conf:merge(defaultConfig, config)
		end

		local size = config.textSize

		local theme = require("uitheme").current

		local node = _nodeCreate()

		node.onTextChange = function(_) end

		node.disabled = false

		node._refresh = _textInputRefresh

		node.state = State.Idle
		node.object = Object()

		node.border = self:createFrame()
		node.border:setParent(node)

		node.background = self:createFrame()
		node.background:setParent(node)
		node.background.pos = { theme.textInputBorderSize, theme.textInputBorderSize, 0 }

		local textContainer = ui:createFrame(Color.transparent)
		textContainer:setParent(node)
		textContainer.IsMask = true
		node.textContainer = textContainer

		textContainer.contentDidResize = function(_)
			if node._refresh then
				node:_refresh()
			end
		end

		node.contentDidResizeSystem = function(self)
			if self._refresh then
				self:_refresh()
			end
		end

		node.placeholder = ui:createText(placeholder or "", { color = Color.White, size = size }) -- color replaced later on
		node.placeholder:setParent(textContainer)

		node.string = ui:createText(str or "", { color = Color.White, size = size }) -- color replaced later on
		node.string:setParent(textContainer)

		if config.password then
			node.hiddenString = ui:createText("", Color.White, size)
			node.hiddenString:setParent(textContainer)
			node.hiddenString.Text = string.rep("*", #node.string.Text)
			node.string:hide()
		end

		node.isTextHidden = function(self)
			return self.string:isVisible() == false
		end

		node.showText = function(self)
			self.string:show()
			if self.hiddenString ~= nil then
				self.hiddenString:hide()
			end
		end

		node.hideText = function(self)
			self.string:hide()
			if self.hiddenString ~= nil then
				self.hiddenString:show()
			end
		end

		node.selection = self:createFrame(Color(255, 255, 255, 0.3))
		node.selection:setParent(textContainer)

		node.cursor = self:createFrame(Color.White)
		node.cursor.Width = theme.textInputCursorWidth
		node.cursor:setParent(textContainer)
		node.cursor:hide()

		node._width = function(self)
			return self.border.Width
		end
		node._height = function(self)
			return self.border.Height
		end
		node._depth = function(self)
			return self.border.Depth
		end

		node._setWidth = function(self, newWidth)
			self.border.Width = newWidth
			self.background.Width = newWidth - theme.textInputBorderSize * 2
		end

		node.Width = theme.textInputDefaultWidth

		node._setHeight = function(_, _)
			-- self.border.Height = newHeight
			-- self.background.Height = newHeight - theme.textInputBorderSize * 2
		end

		node._text = function(self)
			return self.string.Text
		end

		node._setText = function(self, str)
			self.string.Text = str
			_textInputTextDidChange(self)
			if focused == self then
				-- put cursor at the end of string
				local charIndex, cursorPos = self.string:charIndexToCursor(#str + 1)
				self.cursor.pos = cursorPos
					+ Number2(self.string.pos.X - theme.textInputCursorWidth * 0.5, self.string.pos.Y)
				Client.OSTextInput:Update({ content = str, cursorStart = nil, cursorEnd = nil })
			end
		end

		node._color = function(self)
			return self.colors[1]
		end

		node.enable = function(self)
			if self.disabled == false then
				return
			end
			self.disabled = false
			_textInputRefreshColor(self)
		end

		node.disable = function(self)
			if self.disabled then
				return
			end
			self.disabled = true
			_textInputRefreshColor(self)
		end

		node.Width = 200

		node.setColor = function(self, background, text, placeholder, doNotrefresh)
			if background ~= nil then
				node.colors = { Color(background), Color(background) }
				node.colors[2]:ApplyBrightnessDiff(theme.textInputBorderBrightnessDiff)
			end
			if text ~= nil then
				node.textColor = Color(text)
			end
			if placeholder ~= nil then
				node.placeholderColor = Color(placeholder)
			end
			if not doNotrefresh then
				_textInputRefreshColor(self)
			end
		end

		node.setColorPressed = function(self, background, text, placeholder, doNotrefresh)
			if background ~= nil then
				node.colorsPressed = { Color(background), Color(background) }
				node.colorsPressed[2]:ApplyBrightnessDiff(theme.textInputBorderBrightnessDiff)
			end
			if text ~= nil then
				node.textColorPressed = Color(text)
			end
			if placeholder ~= nil then
				node.placeholderColorPressed = Color(placeholder)
			end
			if not doNotrefresh then
				_textInputRefreshColor(self)
			end
		end

		node.setColorFocused = function(self, background, text, placeholder, doNotrefresh)
			if background ~= nil then
				node.colorsFocused = { Color(background), Color(background) }
				node.colorsFocused[2]:ApplyBrightnessDiff(theme.textInputBorderBrightnessDiff)
			end
			if text ~= nil then
				node.textColorFocused = Color(text)
			end
			if placeholder ~= nil then
				node.placeholderColorFocused = Color(placeholder)
			end
			if not doNotrefresh then
				_textInputRefreshColor(self)
			end
		end

		node.setColorDisabled = function(self, background, text, placeholder, doNotrefresh)
			if background ~= nil then
				node.colorsDisabled = { Color(background), Color(background) }
				node.colorsDisabled[2]:ApplyBrightnessDiff(theme.textInputBorderBrightnessDiff)
			end
			if text ~= nil then
				node.textColorDisabled = Color(text)
			end
			if placeholder ~= nil then
				node.placeholderColorDisabled = Color(placeholder)
			end
			if not doNotrefresh then
				_textInputRefreshColor(self)
			end
		end

		node:setColor(theme.textInputBackgroundColor, theme.textInputTextColor, theme.textInputPlaceholderColor, true)
		node:setColorPressed(
			theme.textInputBackgroundColorPressed,
			theme.textInputTextColorPressed,
			theme.textInputPlaceholderColorPressed,
			true
		)
		node:setColorFocused(
			theme.textInputBackgroundColorFocused,
			theme.textInputTextColorFocused,
			theme.textInputPlaceholderColorFocused,
			true
		)
		node:setColorDisabled(
			theme.textInputBackgroundColorDisabled,
			theme.textInputTextColorDisabled,
			theme.textInputPlaceholderColorDisabled,
			true
		)

		node:_refresh()
		_textInputRefreshColor(node) -- apply initial colors

		local cursorT = 0
		local cursorShown = true
		local blinkTime = theme.textInputCursorBlinkTime

		local function forceShowCursor()
			node.cursor:show()
			cursorT = 0
			cursorShown = true
			node.cursor.Width = theme.textInputCursorWidth
		end

		local startIndex
		local endIndex
		local startCursorPos

		node.border.onPress = function(self, _, _, pointerEvent)
			if node.disabled == true then
				return
			end
			if not node.string then
				return
			end

			if node.state ~= State.Focused then
				node.state = State.Pressed
				_textInputRefreshColor(node)
			end

			if node.state == State.Focused then
				-- TODO: use hiddenStr instead here when visible
				local pos = getPointerXYWithinNode(pointerEvent, node.string)
				pos.Y = node.string.Height * 0.5 -- enforce event at mid height for single line inputs

				local charIndex, cursorPos = node.string:localPositionToCursor(pos)
				-- print("charIndex:", charIndex, "X:", cursorPos.X)

				node.cursor.pos = cursorPos
					+ Number2(node.string.pos.X - theme.textInputCursorWidth * 0.5, node.string.pos.Y)
				forceShowCursor()

				startCursorPos = node.cursor.pos:Copy()
				node.selection.Width = 0

				startIndex = charIndex
				endIndex = startIndex

				Client.OSTextInput:Update({ content = node.string.Text, cursorStart = startIndex, cursorEnd = endIndex })
			end
		end

		node.border.onDrag = function(self, pointerEvent)
			if node.disabled == true then
				return
			end
			if node.state ~= State.Focused then
				return
			end
			if not node.string then
				return
			end

			local pos = getPointerXYWithinNode(pointerEvent, node.string)
			pos.Y = node.string.Height * 0.5 -- enforce event at mid height for single line inputs

			local charIndex, cursorPos = node.string:localPositionToCursor(pos)

			node.cursor.pos = cursorPos
				+ Number2(node.string.pos.X - theme.textInputCursorWidth * 0.5, node.string.pos.Y)

			endIndex = charIndex

			if startIndex == endIndex then
				forceShowCursor()
			else
				node.cursor:hide()
				node.selection.pos = node.cursor.pos
				if startCursorPos.X < node.cursor.pos.X then
					node.selection.pos.X = startCursorPos.X
				end
				node.selection.Height = node.cursor.Height
				node.selection.Width = math.abs(startCursorPos.X - node.cursor.pos.X)
			end

			Client.OSTextInput:Update({ content = node.string.Text, cursorStart = startIndex, cursorEnd = endIndex })
		end

		node.border.onCancel = function()
			if node.disabled == true then
				return
			end
			node.state = State.Idle
			_textInputRefreshColor(node)
		end

		node.border.onRelease = function()
			if node.disabled == true then
				return
			end
			node:focus()
		end

		node.onFocus = nil
		node.onFocusLost = nil
		node.onSubmit = function()
			node:_unfocus() -- onfocus by default on submit
		end
		node.onUp = nil
		node.onDown = nil

		node.focus = function(self)
			if self.state == State.Focused then
				return
			end
			self.state = State.Focused

			_textInputRefreshColor(self)
			self:_refresh()

			if focus(self) == false then
				-- can't take focus, maybe it already had it
				return
			end

			if self.tickListener == nil then
				self.tickListener = LocalEvent:Listen(LocalEvent.Name.Tick, function(dt)
					if self.cursor:isVisible() then
						cursorT = cursorT + dt
						if cursorT >= blinkTime then
							cursorT = cursorT % blinkTime
							cursorShown = not cursorShown
							local backup = self.contentDidResizeSystem
							self.contentDidResizeSystem = nil
							self.cursor.Width = cursorShown and theme.textInputCursorWidth or 0
							self.contentDidResizeSystem = backup
						end
					end
				end)
			end

			Client.OSTextInput:Request({
				content = self.string.Text,
				multiline = config.multiline,
				returnKeyType = config.returnKeyType,
				keyboardType = config.keyboardType,
				cursorStart = nil,
				cursorEnd = nil,
			})

			if self.textInputUpdateListener == nil then
				self.textInputUpdateListener = LocalEvent:Listen(
					LocalEvent.Name.ActiveTextInputUpdate,
					function(str, cursorStart, cursorEnd)
						if self.string.Text ~= str then -- check if text is different
							self.string.Text = str
							_textInputTextDidChange(self)
						end

						-- print("cursorStart:", cursorStart)
						local charIndex, cursorPos = self.string:charIndexToCursor(cursorStart)
						-- print("CURSOR:", cursorPos.X, cursorPos.Y, charIndex)
						self.cursor.pos = cursorPos
							+ Number2(self.string.pos.X - theme.textInputCursorWidth * 0.5, self.string.pos.Y)

						startIndex = charIndex
						startCursorPos = node.cursor.pos:Copy()

						if cursorStart == cursorEnd then
							forceShowCursor()
							node.selection.Width = 0
						else
							self.cursor:hide()
							_, cursorPos = self.string:charIndexToCursor(cursorEnd)

							self.cursor.pos = cursorPos
								+ Number2(self.string.pos.X - theme.textInputCursorWidth * 0.5, self.string.pos.Y)

							node.selection.pos = node.cursor.pos
							if startCursorPos.X < node.cursor.pos.X then
								node.selection.pos.X = startCursorPos.X
							end
							node.selection.Height = node.cursor.Height
							node.selection.Width = math.abs(startCursorPos.X - node.cursor.pos.X)
						end

						return true -- capture event
					end,
					{
						topPriority = true,
						system = System,
					}
				)
			end

			if self.textInputCloseListener == nil then
				self.textInputCloseListener = LocalEvent:Listen(LocalEvent.Name.ActiveTextInputClose, function()
					self:unfocus()
					return true -- capture event
				end, {
					topPriority = true,
					system = System,
				})
			end

			if self.textInputDoneListener == nil then
				self.textInputDoneListener = LocalEvent:Listen(LocalEvent.Name.ActiveTextInputDone, function()
					if self.onSubmit then
						self:onSubmit()
						return true
					end
				end, {
					topPriority = true,
					system = System,
				})
			end

			if self.textInputNextListener == nil then
				self.textInputNextListener = LocalEvent:Listen(LocalEvent.Name.ActiveTextInputNext, function()
					-- TODO: move to next field, `onNext`?
					return true -- capture event
				end, {
					topPriority = true,
					system = System,
				})
			end

			local keysDown = {}
			if self.keyboardListener == nil then -- better be safe, do not listen if already listening
				self.keyboardListener = LocalEvent:Listen(
					LocalEvent.Name.KeyboardInput,
					function(_, keycode, modifiers, down)
						if keycode ~= codes.UP and keycode ~= codes.DOWN then
							-- only consider UP and DOWN keycodes
							return
						end

						if down then
							if not keysDown[keycode] then
								keysDown[keycode] = true
							end
						else
							if keysDown[keycode] then
								keysDown[keycode] = nil
								return true -- catch
							else
								return -- return without catching
							end
						end

						local cmd = (modifiers & codes.modifiers.Cmd) > 0
						local ctrl = (modifiers & codes.modifiers.Ctrl) > 0
						local option = (modifiers & codes.modifiers.Option) > 0 -- option is alt

						if cmd or ctrl or option then
							return false
						end

						if keycode == codes.UP then
							if self.onUp then
								self:onUp()
								return true
							end
						elseif keycode == codes.DOWN then
							if self.onDown then
								self:onDown()
								return true
							end
						end

						return false
					end,
					{
						topPriority = true,
						system = System,
					}
				)
			end

			if self.onFocus ~= nil then
				self:onFocus()
			end
		end

		node._unfocus = function(self)
			if self.state ~= State.Focused then
				return
			end

			self.state = State.Idle
			self.cursor:hide()

			if self.textInputUpdateListener ~= nil then
				Client.OSTextInput:Close()
				self.textInputUpdateListener:Remove()
				self.textInputUpdateListener = nil
			end

			if self.textInputCloseListener ~= nil then
				self.textInputCloseListener:Remove()
				self.textInputCloseListener = nil
			end

			if self.textInputDoneListener ~= nil then
				self.textInputDoneListener:Remove()
				self.textInputDoneListener = nil
			end

			if self.textInputNextListener ~= nil then
				self.textInputNextListener:Remove()
				self.textInputNextListener = nil
			end

			if self.keyboardListener ~= nil then
				self.keyboardListener:Remove()
				self.keyboardListener = nil
			end

			if self.tickListener ~= nil then
				self.tickListener:Remove()
				self.tickListener = nil
			end

			_textInputRefreshColor(self)
			self:_refresh()

			unfocus()
			if self.onFocusLost ~= nil then
				self:onFocusLost()
			end
		end

		node.unfocus = function(self)
			if self:hasFocus() then
				focus(nil)
			end
		end

		node:setParent(rootFrame)

		return node
	end

	ui.createScroll = function(self, config)
		local defaultConfig = {
			backgroundColor = Color(0, 0, 0, 0),
			direction = "down", -- can also be "up", "left", "right"
			cellPadding = 0,
			rigidity = SCROLL_DEFAULT_RIGIDITY,
			loadCell = function(_) -- index
				return nil
			end,
			unloadCell = function(_, _) -- index, cell
				return nil
			end,
		}

		config = conf:merge(defaultConfig, config)

		local down = config.direction == "down"
		local up = config.direction == "up"
		local right = config.direction == "right"
		local left = config.direction == "left"
		local vertical = down or up
		local horizontal = right or left

		local node = self:createFrame(config.backgroundColor)
		node.isScrollArea = true
		node.IsMask = true

		local listeners = {}
		local l
		local hovering = false

		local cellPadding = config.cellPadding

		local container = self:createNode()
		container:setParent(node)
		node.container = container

		-- loaed cells
		local cells = {}

		-- cache for start position and size of each cell that's been loaded once
		local cache = {
			contentWidth = 0,
			contentHeight = 0,
			cellInfo = {}, -- each entry: { top, bottom, left, right, width, height }
		}

		local released = true
		local scrollPosition = 0
		local targetScrollPosition = 0
		local defuseScrollSpeedCount = 0
		local totalDragSinceLastTick = 0
		local scrollSpeed = 0
		local dragStartScrollPosition = 0

		local cell
		local cellInfo
		local previousCellInfo
		local cellIndex

		local loadTop
		local loadBottom
		local unloadTop
		local unloadBottom

		local loadRight
		local loadLeft
		local unloadRight
		local unloadLeft

		local scrollHandle = self:createFrame(Color(0, 0, 0, 0.5))
		scrollHandle:setParent(node)

		node.refresh = function()
			if not vertical and not horizontal then
				return
			end

			if vertical then
				container.pos.X = 0
			else -- horizontal
				container.pos.Y = 0
			end

			if down then
				container.pos.Y = node.Height - scrollPosition

				loadTop = -scrollPosition + SCROLL_LOAD_MARGIN
				loadBottom = loadTop - node.Height - SCROLL_LOAD_MARGIN * 2

				unloadTop = -scrollPosition + SCROLL_UNLOAD_MARGIN
				unloadBottom = loadTop - node.Height - SCROLL_UNLOAD_MARGIN * 2
			elseif up then
				container.pos.Y = 0 - scrollPosition

				loadBottom = scrollPosition - SCROLL_LOAD_MARGIN
				loadTop = loadBottom + node.Height + SCROLL_LOAD_MARGIN * 2

				unloadBottom = scrollPosition - SCROLL_UNLOAD_MARGIN
				unloadTop = loadBottom + node.Height + SCROLL_UNLOAD_MARGIN * 2
			elseif right then
				container.pos.X = 0 - scrollPosition

				loadLeft = scrollPosition - SCROLL_LOAD_MARGIN
				loadRight = loadLeft + node.Width + SCROLL_LOAD_MARGIN * 2

				unloadLeft = scrollPosition - SCROLL_UNLOAD_MARGIN
				unloadRight = loadLeft + node.Width + SCROLL_UNLOAD_MARGIN * 2
			elseif left then
				container.pos.X = node.Width + scrollPosition

				loadLeft = -scrollPosition - node.Width - SCROLL_LOAD_MARGIN
				loadRight = loadLeft + node.Width + SCROLL_LOAD_MARGIN * 2

				unloadLeft = -scrollPosition - node.Width - SCROLL_LOAD_MARGIN * 2
				unloadRight = loadLeft + node.Width + SCROLL_UNLOAD_MARGIN * 2
			end

			cellIndex = 1
			cellInfo = nil
			previousCellInfo = nil

			if vertical then
				while true do
					cellInfo = cache.cellInfo[cellIndex]

					if cellInfo == nil then
						cell = config.loadCell(cellIndex)
						if cell == nil then
							-- reached the end of cells
							break
						end
						cellInfo = { height = cell.Height }
						if cache.contentHeight == 0 then
							cache.contentHeight = cellInfo.height
						else
							cache.contentHeight = cache.contentHeight + cellInfo.height + cellPadding
						end

						if previousCellInfo ~= nil then
							if down then
								cellInfo.top = previousCellInfo.bottom - cellPadding
							else -- up
								cellInfo.top = previousCellInfo.top + cellPadding + cellInfo.height
							end
						else -- first cell
							if down then
								cellInfo.top = 0
							else -- up
								cellInfo.top = cellInfo.height
							end
						end

						cellInfo.bottom = cellInfo.top - cellInfo.height
						cache.cellInfo[cellIndex] = cellInfo

						cells[cellIndex] = cell
						cell:setParent(container)
						cell.pos.Y = cellInfo.bottom
						cell.pos.X = 0
					end

					previousCellInfo = cellInfo

					if
						(cellInfo.bottom >= loadBottom and cellInfo.bottom <= loadTop)
						or (cellInfo.top >= loadBottom and cellInfo.top <= loadTop)
					then
						cell = cells[cellIndex]
						if cell == nil then
							cell = config.loadCell(cellIndex)
							-- here if cell == nil, it means cell already loaded once now gone
							-- let's just not display anything in this area.
							if cell ~= nil then
								cell:setParent(container)
								cell.pos.Y = cellInfo.bottom
								cell.pos.X = 0
							end
						end
					elseif cellInfo.top <= unloadBottom and cellInfo.bottom >= unloadTop then
						cell = cells[cellIndex]
						if cell ~= nil then
							config.unloadCell(cellIndex, cell)
							cells[cellIndex] = nil
						end

						if down and cellInfo.top <= unloadBottom then
							break -- no need to go further
						elseif up and cellInfo.bottom >= unloadTop then
							break -- no need to go further
						end
					end

					cellIndex = cellIndex + 1
				end
			else -- horizontal
				while true do
					cellInfo = cache.cellInfo[cellIndex]

					if cellInfo == nil then
						cell = config.loadCell(cellIndex)
						if cell == nil then
							-- reached the end of cells
							break
						end
						cellInfo = { width = cell.Width }
						if cache.contentWidth == 0 then
							cache.contentWidth = cellInfo.width
						else
							cache.contentWidth = cache.contentWidth + cellInfo.width + cellPadding
						end

						if previousCellInfo ~= nil then
							if right then
								cellInfo.left = previousCellInfo.right + cellPadding
							else -- left
								cellInfo.left = previousCellInfo.left - cellPadding + cellInfo.width
							end
						else -- first cell
							if right then
								cellInfo.left = 0
							else -- left
								cellInfo.left = -cellInfo.width
							end
						end

						cellInfo.right = cellInfo.left + cellInfo.width
						cache.cellInfo[cellIndex] = cellInfo

						cells[cellIndex] = cell
						cell:setParent(container)
						cell.pos.Y = 0
						cell.pos.X = cellInfo.left
					end

					previousCellInfo = cellInfo

					if
						(cellInfo.left >= loadLeft and cellInfo.left <= loadRight)
						or (cellInfo.right >= loadLeft and cellInfo.right <= loadRight)
					then
						cell = cells[cellIndex]
						if cell == nil then
							cell = config.loadCell(cellIndex)
							-- here if cell == nil, it means cell already loaded once now gone
							-- let's just not display anything in this area.
							if cell ~= nil then
								cell:setParent(container)
								cell.pos.Y = 0
								cell.pos.X = cellInfo.left
							end
						end
					elseif cellInfo.right <= unloadLeft and cellInfo.left >= unloadRight then
						cell = cells[cellIndex]
						if cell ~= nil then
							config.unloadCell(cellIndex, cell)
							cells[cellIndex] = nil
						end

						if right and cellInfo.left >= unloadRight then
							break -- no need to go further
						elseif left and cellInfo.right <= unloadLeft then
							break -- no need to go further
						end
					end

					cellIndex = cellIndex + 1
				end
			end
		end

		node.applyScrollDelta = function(_, dx, dy)
			if vertical then
				node:setScrollPosition(targetScrollPosition - dy)
			elseif horizontal then
				node:setScrollPosition(targetScrollPosition - dx)
			end
		end

		node.capPosition = function(_, pos)
			if down then
				local limit = cache.contentHeight - node.Height
				if limit < 0 then
					limit = 0
				end
				pos = math.max(-limit, math.min(0, pos))
			elseif up then
				-- TODO: review
				pos = math.min(0, math.max(100, pos))
			elseif right then
				local limit = cache.contentWidth - node.Width
				if limit < 0 then
					limit = 0
				end
				pos = math.max(0, math.min(limit, pos)) -- correct
			elseif left then
				-- TODO: review
				pos = math.min(100, math.max(-100, pos))
			end

			return pos
		end

		node.setScrollPosition = function(self, newPosition)
			targetScrollPosition = self:capPosition(newPosition)
		end

		node.flush = function(_)
			local toRemove = {}
			for index, _ in pairs(cells) do
				table.insert(toRemove, index)
			end

			local indexToRemove = table.remove(toRemove)

			while indexToRemove ~= nil do
				local cell = cells[indexToRemove]
				if cell ~= nil then
					config.unloadCell(indexToRemove, cell)
				end

				indexToRemove = table.remove(toRemove)
			end

			cells = {}
			cache = {
				contentWidth = 0,
				contentHeight = 0,
				cellInfo = {},
			}
			scrollPosition = 0
			targetScrollPosition = 0
		end

		container.parentDidResizeSystem = function(self)
			node:refresh()
		end

		node.containsPointer = function(self, pe)
			local x
			local y

			local ok = pcall(function()
				x = pe.X * Screen.Width
				y = pe.Y * Screen.Height
			end)

			if not ok then
				return false
			end

			-- compute absolute screen coordinates
			local bottomY = self.pos.Y
			local topY = bottomY + self.Height
			local leftX = self.pos.X
			local rightX = leftX + self.Width

			local parent = self.parent

			while parent do
				bottomY = bottomY + parent.pos.Y
				topY = topY + parent.pos.Y
				leftX = leftX + parent.pos.X
				rightX = rightX + parent.pos.X
				parent = parent.parent
			end

			return (x >= leftX and x <= rightX and y >= bottomY and y <= topY)
		end

		l = LocalEvent:Listen(LocalEvent.Name.Tick, function(dt)
			if totalDragSinceLastTick ~= 0 then
				scrollSpeed = totalDragSinceLastTick
				totalDragSinceLastTick = 0
			end

			if released == false and defuseScrollSpeedCount > 0 then
				defuseScrollSpeedCount = defuseScrollSpeedCount - dt
				if defuseScrollSpeedCount <= 0 then
					scrollSpeed = 0
					totalDragSinceLastTick = 0
					defuseScrollSpeedCount = 0
				end
			end

			if released == true and scrollSpeed ~= 0 then
				scrollPosition = node:capPosition(scrollPosition + scrollSpeed * dt)
				if scrollSpeed > 0 then
					scrollSpeed = scrollSpeed - math.min(scrollSpeed, 500 * dt)
				else
					scrollSpeed = scrollSpeed + math.min(-scrollSpeed, 500 * dt)
				end
				targetScrollPosition = scrollPosition

				if math.abs(scrollSpeed) < SCROLL_EPSILON then
					scrollSpeed = 0
				end
				node:refresh()
			else
				if targetScrollPosition ~= scrollPosition then
					scrollPosition = scrollPosition
						+ (targetScrollPosition - scrollPosition)
							* config.rigidity
							* dt
							* 1.0
							/ SCROLL_TIME_TO_TARGET
					if math.abs(scrollPosition - targetScrollPosition) < SCROLL_EPSILON then
						scrollPosition = targetScrollPosition
					end
					-- NOTE: possible optimization: refresh content less often, only the position
					node:refresh()
				end
			end
		end, { system = system == true and System or nil, topPriority = true })
		table.insert(listeners, l)

		local startPosition
		-- NOTE: We should have an onPressSystem function for this, to let users
		-- set their own onPress callback if needed, even on scroll nodes.
		node.onPress = function(_, _, _, pointerEvent)
			released = false

			startPosition = Number2(pointerEvent.X * Screen.Width, pointerEvent.Y * Screen.Height)
			if vertical then
				startPosition.X = 0
			elseif horizontal then
				startPosition.Y = 0
			end

			targetScrollPosition = scrollPosition
			dragStartScrollPosition = scrollPosition
		end

		node.onDrag = function(self, pointerEvent)
			local pos = Number2(pointerEvent.X * Screen.Width, pointerEvent.Y * Screen.Height)

			local diff = 0
			if vertical then
				diff = startPosition.Y - pos.Y
			elseif horizontal then
				diff = startPosition.X - pos.X
			end

			defuseScrollSpeedCount = SCROLL_TIME_TO_DEFUSE_SPEED
			totalDragSinceLastTick = totalDragSinceLastTick + diff

			self:setScrollPosition(dragStartScrollPosition + diff)

			if pressed ~= self and math.abs(scrollPosition - dragStartScrollPosition) >= SCROLL_DRAG_EPSILON then
				if pressed._onCancel then
					pressed:_onCancel()
				end
				focus(nil)
				pressed = self
			end
		end

		node.onRelease = function(_)
			released = true
		end

		node.onCancel = function(_)
			released = true
		end

		if Client.IsMobile == false then
			l = LocalEvent:Listen(LocalEvent.Name.PointerMove, function(pe)
				hovering = node:containsPointer(pe)
			end, { system = system == true and System or nil, topPriority = true })
			table.insert(listeners, l)

			l = LocalEvent:Listen(LocalEvent.Name.PointerWheel, function(delta)
				if not hovering then
					return false
				end
				node:applyScrollDelta(delta, delta)
				return true
			end, { system = system == true and System or nil, topPriority = true })
			table.insert(listeners, l)
		end

		node.onRemoveSystem = function(self)
			for _, l in ipairs(listeners) do
				l:Remove()
			end
			listeners = {}
			self:flush()
		end

		node:refresh()
		return node
	end

	-- content can be a string, a uikit node, or a Shape
	ui.createButton = function(_, content, config)
		local defaultConfig = {
			borders = true,
			underline = false,
			padding = true,
			shadow = true,
			textSize = "default",
			sound = "button_1",
			unfocuses = true, -- unfocused focused node when true
			color = theme.buttonColor,
			colorPressed = nil,
			colorSelected = theme.buttonColorSelected,
			colorDisabled = theme.buttonColorDisabled,
			textColor = theme.buttonTextColor,
			textColorPressed = nil,
			textColorSelected = theme.buttonTextColorSelected,
			textColorDisabled = theme.buttonTextColorDisabled,
		}

		local options = {
			acceptTypes = {
				colorPressed = { "Color" },
				textColorPressed = { "Color" },
			},
		}

		config = conf:merge(defaultConfig, config, options)

		if config.colorPressed == nil then
			config.colorPressed = Color(config.color)
			config.colorPressed:ApplyBrightnessDiff(-0.15)
		end

		if config.textColorPressed == nil then
			config.textColorPressed = Color(config.textColor)
			config.textColorPressed:ApplyBrightnessDiff(-0.15)
		end

		local theme = require("uitheme").current

		if content == nil then
			error("ui:createButton(content, config) - content should be a non-nil string, Shape or uikit node", 2)
		end

		local node = _nodeCreate()
		node.config = config

		node.contentDidResizeSystem = function(self)
			self:_refresh()
		end

		node.selected = false
		node.disabled = false

		node.type = NodeType.Button
		node._onCancel = _buttonOnCancel
		node._refresh = _buttonRefresh
		node.state = State.Idle
		node.object = Object()

		node.fixedWidth = nil
		node.fixedHeight = nil

		node._width = function(self)
			return self.background.LocalScale.X
		end

		node._setWidth = function(self, newWidth)
			self.fixedWidth = newWidth
			self:_refresh()
		end

		node._height = function(self)
			return self.background.LocalScale.Y
		end

		node._setHeight = function(self, newHeight)
			self.fixedHeight = newHeight
			self:_refresh()
		end

		node._depth = function(self)
			return self.background.LocalScale.Z
		end

		node._text = function(self)
			return self.content.Text
		end

		node._setText = function(self, str)
			self.content.Text = str
		end

		node.setColor = function(self, background, text, doNotrefresh)
			if background ~= nil then
				if type(background) ~= "Color" then
					error("setColor - first parameter (background color) should be a Color", 2)
				end
				node.colors = { Color(background), Color(background), Color(background) }
				node.colors[2]:ApplyBrightnessDiff(theme.buttonTopBorderBrightnessDiff)
				node.colors[3]:ApplyBrightnessDiff(theme.buttonBottomBorderBrightnessDiff)
			end
			if text ~= nil then
				if type(text) ~= "Color" then
					error("setColor - second parameter (text color) should be a Color", 2)
				end
				node.textColor = Color(text)
			end
			if not doNotrefresh then
				_buttonRefreshColor(self)
			end
		end

		node.setColorPressed = function(self, background, text, doNotrefresh)
			if background ~= nil then
				node.colorsPressed = { Color(background), Color(background), Color(background) }
				node.colorsPressed[2]:ApplyBrightnessDiff(theme.buttonTopBorderBrightnessDiff)
				node.colorsPressed[3]:ApplyBrightnessDiff(theme.buttonBottomBorderBrightnessDiff)
			end
			if text ~= nil then
				node.textColorPressed = Color(text)
			end
			if not doNotrefresh then
				_buttonRefreshColor(self)
			end
		end

		node.setColorSelected = function(self, background, text, doNotrefresh)
			if background ~= nil then
				node.colorsSelected = { Color(background), Color(background), Color(background) }
				node.colorsSelected[2]:ApplyBrightnessDiff(theme.buttonTopBorderBrightnessDiff)
				node.colorsSelected[3]:ApplyBrightnessDiff(theme.buttonBottomBorderBrightnessDiff)
			end
			if text ~= nil then
				node.textColorSelected = Color(text)
			end
			if not doNotrefresh then
				_buttonRefreshColor(self)
			end
		end

		node.setColorDisabled = function(self, background, text, doNotrefresh)
			if background ~= nil then
				node.colorsDisabled = { Color(background), Color(background), Color(background) }
				node.colorsDisabled[2]:ApplyBrightnessDiff(theme.buttonTopBorderBrightnessDiff)
				node.colorsDisabled[3]:ApplyBrightnessDiff(theme.buttonBottomBorderBrightnessDiff)
			end
			if text ~= nil then
				node.textColorDisabled = Color(text)
			end
			if not doNotrefresh then
				_buttonRefreshColor(self)
			end
		end

		node:setColor(config.color, config.textColor, true)
		node:setColorPressed(config.colorPressed, config.textColorPressed, true)
		node:setColorSelected(config.colorSelected, config.textColorSelected, true)
		node:setColorDisabled(config.colorDisabled, config.textColorDisabled, true)

		if type(content) == "string" then
			local n = ui:createText(content, { size = config.textSize })
			n:setParent(node)
			node.content = n
		elseif type(content) == "Shape" or type(content) == "MutableShape" then
			local n = ui:createShape(content, { spherized = false, doNotFlip = true })
			n:setParent(node)
			node.content = n
		else
			local ok = pcall(function()
				content:setParent(node)
				node.content = content
			end)
			if not ok then
				error("ui:createButton(content, config) - content should be a non-nil string, Shape or uikit node", 2)
			end
		end

		local background = Quad()
		background.Color = node.colors[1]
		background.IsDoubleSided = false
		_setupUIObject(background, true)
		node.object:AddChild(background)
		background._node = node

		node.background = background
		node.borders = {}

		if config.borders then
			local borderTop = Quad()
			borderTop.Color = node.colors[2]
			borderTop.IsDoubleSided = false
			_setupUIObject(borderTop)
			node.object:AddChild(borderTop)
			table.insert(node.borders, borderTop)

			local borderRight = Quad()
			borderRight.Color = node.colors[2]
			borderRight.IsDoubleSided = false
			_setupUIObject(borderRight)
			node.object:AddChild(borderRight)
			table.insert(node.borders, borderRight)

			local borderBottom = Quad()
			borderBottom.Color = node.colors[3]
			borderBottom.IsDoubleSided = false
			_setupUIObject(borderBottom)
			node.object:AddChild(borderBottom)
			table.insert(node.borders, borderBottom)

			local borderLeft = Quad()
			borderLeft.Color = node.colors[3]
			borderLeft.IsDoubleSided = false
			_setupUIObject(borderLeft)
			node.object:AddChild(borderLeft)
			table.insert(node.borders, borderLeft)
		end

		if config.underline and not config.borders then
			local underline = Quad()
			underline.Color = node.textColor
			underline.IsDoubleSided = false
			_setupUIObject(underline)
			node.object:AddChild(underline)
			node.underline = underline
		end

		if config.shadow then
			local shadow = Quad()
			shadow.Color = Color(0, 0, 0, 20)
			shadow.IsDoubleSided = false
			_setupUIObject(shadow)
			node.object:AddChild(shadow)
			node.shadow = shadow
		end

		node:_refresh()
		_buttonRefreshColor(node) -- apply initial colors

		node.onPress = function(_) end
		node.onRelease = function(_) end

		node.select = function(self)
			if self.selected then
				return
			end
			self.selected = true
			_buttonRefreshColor(self)
		end

		node.unselect = function(self)
			if self.selected == false then
				return
			end
			self.selected = false
			_buttonRefreshColor(self)
		end

		node.enable = function(self)
			if self.disabled == false then
				return
			end
			self.disabled = false
			_buttonRefreshColor(self)
		end

		node.disable = function(self)
			if self.disabled then
				return
			end
			self.disabled = true
			_buttonRefreshColor(self)
		end

		node:setParent(rootFrame)

		return node
	end -- createButton

	ui.createComboBox = function(self, stringOrShape, choices, config)
		if choices == nil then
			return
		end

		local btn = self:createButton(stringOrShape, config)

		btn.onSelect = function(_, _) end

		btn.onRelease = function(_)
			btn:disable()

			local selector = ui:createFrame(Color(0, 0, 0, 100))
			selector:setParent(btn.parent)

			focus(nil)
			comboBoxSelector = selector

			local frame = ui:createFrame(Color(255, 255, 255))
			frame:setParent(selector)
			frame.IsMask = true
			frame.pos = { theme.paddingTiny, theme.paddingTiny }
			frame.Width = btn.Width + theme.padding * 2

			local choiceButtons = {}

			local container = ui:createFrame(Color.transparent)
			container:setParent(frame)

			local showBelow = false
			local showAbove = false

			local down = ui:createButton("⬇️", { borders = true, shadow = false, unfocuses = false })
			-- NOTE: setting parent after hiding creates issues with collisions, it should not...
			down:setParent(frame)
			down.pos.Z = -20
			down:hide()
			down:disable()

			local up = ui:createButton("⬆️", { borders = true, shadow = false, unfocuses = false })
			up:setParent(frame)
			up.pos.Z = -20
			up:hide()
			up:disable()

			local dragged = false
			local selectedBtn = nil
			local totaldragY = 0

			local function onDrag(_, pe)
				totaldragY = totaldragY + pe.DY
				if dragged == false and math.abs(totaldragY) > 5 then
					dragged = true
				end

				if selectedBtn ~= nil then
					selectedBtn:unselect()
					selectedBtn = nil
				end

				container.pos.Y = container.pos.Y + pe.DY
				if container.pos.Y >= 0 then
					container.pos.Y = 0
					if down:isVisible() then
						down:hide()
						down:disable()
					end
				end

				if container.pos.Y + container.Height <= frame.Height then
					container.pos.Y = frame.Height - container.Height
					if up:isVisible() then
						up:hide()
						up:disable()
					end
				end

				if down:isVisible() == false and container.pos.Y < 0 then
					down:show()
					down:enable()
				end
				if up:isVisible() == false and container.pos.Y + container.Height > frame.Height then
					up:show()
					up:enable()
				end
			end

			local function onRelease(self)
				if dragged == false then
					btn.selectedRow = self._choiceIndex
					if btn.onSelect ~= nil then
						btn:onSelect(self._choiceIndex)
					end
					if selector.close then
						selector:close()
					end
				end
				dragged = false
			end

			local function onPress(self)
				dragged = false
				totaldragY = 0
				if selectedBtn ~= nil then
					selectedBtn:unselect()
				end
				selectedBtn = self
				self:select()
			end

			for i, choice in ipairs(choices) do
				local c = ui:createButton(choice, { borders = false, shadow = false, unfocuses = false })
				c:setParent(container)

				c._onDrag = onDrag
				c._choiceIndex = i

				if selectedBtn == nil and btn.selectedRow ~= nil and i == btn.selectedRow then
					c:select()
					selectedBtn = c
				end

				c.onRelease = onRelease
				c.onPress = onPress

				table.insert(choiceButtons, c)
			end

			down.onPress = function()
				showBelow = true
			end
			down.onRelease = function()
				showBelow = false
			end
			down.onCancel = function()
				showBelow = false
			end

			up.onPress = function()
				showAbove = true
			end
			up.onRelease = function()
				showAbove = false
			end
			up.onCancel = function()
				showAbove = false
			end

			local comboTickListener = LocalEvent:Listen(LocalEvent.Name.Tick, function(dt)
				if down:isVisible() == false and container.pos.Y < 0 then
					down:show()
					down:enable()
				end
				if up:isVisible() == false and container.pos.Y + container.Height > frame.Height then
					up:show()
					up:enable()
				end

				if showBelow then
					container.pos.Y = container.pos.Y + dt * COMBO_BOX_SELECTOR_SPEED
					if container.pos.Y >= 0 then
						container.pos.Y = 0
						down:onRelease()
						down:hide()
						down:disable()
					end
				end

				if showAbove then
					container.pos.Y = container.pos.Y - dt * COMBO_BOX_SELECTOR_SPEED
					if container.pos.Y + container.Height <= frame.Height then
						container.pos.Y = frame.Height - container.Height
						up:onRelease()
						up:hide()
						up:disable()
					end
				end
			end)

			-- refresh

			local absY = btn.pos.Y + btn.Height
			local parent = btn.parent

			while parent do
				absY = absY + parent.pos.Y
				parent = parent.parent
			end

			local contentHeight = 0

			for _, c in ipairs(choiceButtons) do
				contentHeight = contentHeight + c.Height
			end

			-- frame.Height = math.min(absY - Screen.SafeArea.Bottom, contentHeight)
			frame.Height = math.min(
				Screen.Height - Screen.SafeArea.Top - Screen.SafeArea.Bottom - theme.paddingBig * 2,
				contentHeight
			)

			frame.pos.Z = -10 -- render on front

			selector.Height = frame.Height + theme.paddingTiny * 2
			selector.Width = frame.Width + theme.paddingTiny * 2

			local p = Number3(btn.pos.X - theme.padding, btn.pos.Y + btn.Height - frame.Height + theme.padding, 0)

			parent = btn.parent
			absPy = p.Y
			while parent do
				absPy = absPy + parent.pos.Y
				parent = parent.parent
			end

			local offset = 0
			if absPy < Screen.SafeArea.Bottom + theme.paddingBig then
				offset = Screen.SafeArea.Bottom + theme.paddingBig - absPy
			end
			p.Y = p.Y + offset

			selector.pos.X = p.X
			selector.pos.Y = p.Y - 50

			ease:outBack(selector, 0.22).pos = p

			selector.pos.Z = -10 -- render on front

			container.Height = contentHeight
			container.Width = frame.Width

			local cursorY = container.Height
			for _, c in ipairs(choiceButtons) do
				c.Width = container.Width
				c.pos.Y = cursorY - c.Height
				cursorY = cursorY - c.Height
			end

			local selectionVisibilityOffset = 0
			if selectedBtn ~= nil then
				local visibleY = container.Height - frame.Height
				if selectedBtn.pos.Y < visibleY then -- place button at center if not visible by default
					selectionVisibilityOffset = visibleY
						- selectedBtn.pos.Y
						+ frame.Height * 0.5
						- selectedBtn.Height * 0.5
				end
			end

			container.pos.Y = frame.Height - container.Height + selectionVisibilityOffset
			if container.pos.Y >= 0 then
				container.pos.Y = 0
			end
			if container.pos.Y + container.Height <= frame.Height then
				container.pos.Y = frame.Height - container.Height
			end

			up.pos = { 0, frame.Height - up.Height }
			up.Width = frame.Width

			down.pos = { 0, 0 }
			down.Width = frame.Width

			selector.close = function(_)
				if comboBoxSelector == selector then
					comboBoxSelector = nil
				end
				ease:cancel(selector)
				comboTickListener:Remove()
				selector:remove()
				if btn.enable then
					btn:enable()
				end
			end
		end

		return btn
	end

	-- LISTENERS

	LocalEvent:Listen(LocalEvent.Name.ScreenDidResize, function(_, _)
		camera.Width = Screen.Width
		camera.Height = Screen.Height

		rootFrame.LocalPosition = { -Screen.Width * 0.5, -Screen.Height * 0.5, UI_FAR }

		if
			currentFontSize ~= Text.FontSizeDefault
			or currentFontSizeBig ~= Text.FontSizeBig
			or currentFontSizeSmall ~= Text.FontSizeSmall
		then
			currentFontSize = Text.FontSizeDefault
			currentFontSizeBig = Text.FontSizeBig
			currentFontSizeSmall = Text.FontSizeSmall

			for _, node in pairs(texts) do
				if node.object and node.object.FontSize then
					if node.fontsize == nil or node.fontsize == "default" then
						node.object.FontSize = currentFontSize
					elseif node.fontsize == "big" then
						node.object.FontSize = currentFontSizeBig
					elseif node.fontsize == "small" then
						node.object.FontSize = currentFontSizeSmall
					end
				end

				_contentDidResizeWrapper(node.parent)
			end
		end

		for _, child in pairs(rootChildren) do
			_parentDidResizeWrapper(child)
		end
	end, { system = system == true and System or nil, topPriority = true })

	pointerDownListener = LocalEvent:Listen(LocalEvent.Name.PointerDown, function(pointerEvent)
		if pointerIndex ~= nil then
			return
		end
		-- TODO: only accept some indexed (no right mouse for example)

		pressedScrolls = {}

		local origin = Number3((pointerEvent.X - 0.5) * Screen.Width, (pointerEvent.Y - 0.5) * Screen.Height, 0)
		local direction = { 0, 0, 1 }

		local impacts
		local hitObject
		local parent
		local skip

		impacts = Ray(origin, direction):Cast(_getCollisionGroups(), nil, false)

		table.sort(impacts, function(a, b)
			return a.Distance < b.Distance
		end)

		local pressedCandidate = nil
		local pressedCandidateImpact = nil

		for _, impact in ipairs(impacts) do
			skip = false

			hitObject = impact.Shape or impact.Object

			-- try to find parent ui object (when impact is a child of a mutable shape)
			while hitObject and not hitObject._node do
				hitObject = hitObject:GetParent()
			end

			if
				hitObject and (hitObject._node._onPress or hitObject._node._onRelease or hitObject._node.isScrollArea)
			then
				-- check if hitObject is within a scroll
				parent = hitObject._node.parent
				while parent ~= nil do
					-- skip action if node parented by scroll but not within area
					-- note: a scroll can itself be within a scroll
					if parent.isScrollArea == true and parent:containsPointer(pointerEvent) == false then
						skip = true
						break
					end
					parent = parent.parent
				end

				if skip == false then
					if hitObject._node.isScrollArea then
						table.insert(pressedScrolls, hitObject._node)
						hitObject._node:_onPress(hitObject, impact.Block, pointerEvent)
					end
					if pressedCandidate == nil then
						pressedCandidate = hitObject._node
						pressedCandidateImpact = impact
					end
				end
			end
		end

		if pressedCandidate ~= nil then
			pressed = pressedCandidate

			-- unfocus focused node, unless hit node.config.unfocused == false
			if pressed ~= focused and pressed.config.unfocuses ~= false then
				focus(nil)
			end

			if pressed.config.sound and pressed.config.sound ~= "" then
				sfx(pressed.config.sound, { Spatialized = false })
			end

			if pressed._onPress then
				pressed:_onPress(hitObject, pressedCandidateImpact.Block, pointerEvent)
			end

			pointerIndex = pointerEvent.Index
			return true -- capture event, other listeners won't get it
		end

		-- did not touch anything, unfocus if focused node
		focus(nil)
	end, { system = system == true and System or nil, topPriority = true })

	pointerUpListener = LocalEvent:Listen(LocalEvent.Name.PointerUp, function(pointerEvent)
		if pointerIndex == nil or pointerIndex ~= pointerEvent.Index then
			return
		end
		pointerIndex = nil

		if pressed ~= nil then
			local origin = Number3((pointerEvent.X - 0.5) * Screen.Width, (pointerEvent.Y - 0.5) * Screen.Height, 0)
			local direction = { 0, 0, 1 }

			local impacts = Ray(origin, direction):Cast(_getCollisionGroups(), nil, false)

			table.sort(impacts, function(a, b)
				return a.Distance < b.Distance
			end)

			local parent
			local skip

			for _, impact in ipairs(impacts) do
				skip = false

				local hitObject = impact.Shape or impact.Object
				-- try to find parent ui object (when impact a child of a mutable shape)
				while hitObject and not hitObject._node do
					hitObject = hitObject:GetParent()
				end

				parent = hitObject._node.parent
				while parent ~= nil do
					if parent.isScrollArea == true and parent:containsPointer(pointerEvent) == false then
						skip = true
						break
					end
					parent = parent.parent
				end

				if skip == false and hitObject._node == pressed and hitObject._node._onRelease then
					pressed:_onRelease(hitObject, impact.Block, pointerEvent)
					pressed = nil
					-- pressed element captures event onRelease event
					-- even if onRelease and onCancel are nil
					return true
				end
			end
		end

		-- no matter what, pressed is now nil
		-- but not capturing event
		if pressed._onCancel then
			pressed:_onCancel()
		end
		pressed = nil
	end, { system = system == true and System or nil, topPriority = true })

	LocalEvent:Listen(LocalEvent.Name.PointerDrag, function(pointerEvent)
		if pointerIndex == nil or pointerIndex ~= pointerEvent.Index then
			return
		end

		local capture = false

		for _, scroll in ipairs(pressedScrolls) do
			capture = true -- at least one scroll capturing drag
			scroll:_onDrag(pointerEvent)
			if pressed == scroll then
				-- scroll took control, early return!
				return true
			end
		end

		local pressed = pressed
		if pressed then
			if pressed._onDrag then
				pressed:_onDrag(pointerEvent)
				return true -- capture only if onDrag is set on the node
			end
		end

		if capture then
			return true
		end
	end, { system = system == true and System or nil, topPriority = true })

	-- TODO: PointerCancel
	-- TODO: PointerMove

	----------------------
	-- DEPRECATED
	----------------------

	local fitScreenWarningDisplayed = false
	ui.fitScreen = function(_)
		if not fitScreenWarningDisplayed then
			print("⚠️ uikit.fitScreen is deprecated, no need to call it anymore!")
			fitScreenWarningDisplayed = true
		end
	end

	local pointerDownWarningDisplayed = false
	ui.pointerDown = function(_, _)
		if not pointerDownWarningDisplayed then
			print("⚠️ uikit.pointerDown is deprecated, no need to call it anymore!")
			pointerDownWarningDisplayed = true
		end
	end

	local pointerUpWarningDisplayed = false
	ui.pointerUp = function(_, _)
		if not pointerUpWarningDisplayed then
			print("⚠️ uikit.pointerUp is deprecated, no need to call it anymore!")
			pointerUpWarningDisplayed = true
		end
	end

	ui.shrinkToFit = function(self, text, maxWidth)
		if text.Width <= maxWidth then
			return
		end
		local charWidth
		local spaceWidth
		local emojiWidth
		local emojisPositions = {}
		local firstEmojiUTF8Code = 0x2000

		local pos = 1
		for _, code in utf8.codes(text.Text) do
			if code > firstEmojiUTF8Code then
				table.insert(emojisPositions, i)
			end
			pos = pos + 1
		end

		do
			local aChar = self:createText("a")
			charWidth = aChar.Width
			aChar:remove()
			local aStr = self:createText("aa")
			local strWidth = aStr.Width
			aStr:remove()
			spaceWidth = strWidth - 2 * charWidth
			local anEmoji = self:createText("⬅️")
			emojiWidth = anEmoji.Width
			anEmoji:remove()
		end

		local currentWidth = 0
		local nbChars = 0
		local it = 1
		for i = 1, #text.Text do
			if i == emojisPositions[it] then
				currentWidth = currentWidth + emojiWidth
				it = it + 1
			else
				currentWidth = currentWidth + charWidth
			end

			if currentWidth + charWidth > maxWidth then
				break
			end
			nbChars = nbChars + 1
			currentWidth = currentWidth + spaceWidth
		end

		text.Text = text.Text:sub(1, nbChars) .. "…"
	end

	return ui
end

-- SHARED LISTENERS (for both shared an system UIs)

currentKeyboardHeight = nil

function applyVirtualKeyboardOffset()
	if currentKeyboardHeight == nil then
		return
	end
	if focused ~= nil then
		local ui = sharedUI.systemUI(System)

		-- rootPos: absolute position of focused component
		local rootPos = focused.pos
		local parent = focused.parent

		while parent ~= nil do
			rootPos = rootPos + parent.pos
			parent = parent.parent
		end

		local toolbarHeight

		if keyboardToolbar == nil then
			keyboardToolbar = ui:createFrame(theme.modalTopBarColor)
			keyboardToolbar.onPress = function() end -- blocker

			local cutBtn = ui:createButton("✂️", { unfocuses = false })
			cutBtn:setParent(keyboardToolbar)
			cutBtn.onRelease = function()
				if focused.Text ~= nil then
					Dev:CopyToClipboard(focused.Text)
					focused.Text = ""
				end
			end

			local copyBtn = ui:createButton("📑", { unfocuses = false })
			copyBtn:setParent(keyboardToolbar)
			copyBtn.onRelease = function()
				if focused.Text ~= nil then
					Dev:CopyToClipboard(focused.Text)
				end
			end

			local pasteBtn = ui:createButton("📋", { unfocuses = false })
			pasteBtn:setParent(keyboardToolbar)
			pasteBtn.onRelease = function()
				local s = System:GetFromClipboard()
				if s ~= "" and focused.Text ~= nil then
					focused.Text = focused.Text .. s
				end
			end

			-- local undoBtn = ui:createButton("↪️", { unfocuses = false })
			-- undoBtn:setParent(keyboardToolbar)

			-- local redoBtn = ui:createButton("↩️", { unfocuses = false })
			-- redoBtn:setParent(keyboardToolbar)

			local closeBtn = ui:createButton("⬇️", { unfocuses = false })
			closeBtn:setParent(keyboardToolbar)
			closeBtn.onRelease = function()
				focus(nil)
			end

			keyboardToolbar.cutBtn = cutBtn
			keyboardToolbar.copyBtn = copyBtn
			keyboardToolbar.pasteBtn = pasteBtn
			-- keyboardToolbar.undoBtn = undoBtn
			-- keyboardToolbar.redoBtn = redoBtn
			keyboardToolbar.closeBtn = closeBtn
		end

		keyboardToolbar.Width = Screen.Width
		keyboardToolbar.Height = keyboardToolbar.cutBtn.Height + theme.paddingTiny * 2
		toolbarHeight = keyboardToolbar.Height

		local diff = 0

		local bottomLine = currentKeyboardHeight + toolbarHeight + theme.paddingBig

		if rootPos.Y < bottomLine then
			diff = bottomLine - rootPos.Y

			if systemUIRootFrame then
				ease:cancel(systemUIRootFrame)
				ease:inOutSine(systemUIRootFrame, 0.2).LocalPosition = {
					-Screen.Width * 0.5,
					-Screen.Height * 0.5 + diff,
					UI_FAR,
				}
			end

			if sharedUIRootFrame then
				ease:cancel(sharedUIRootFrame)
				ease:inOutSine(sharedUIRootFrame, 0.2).LocalPosition = {
					-Screen.Width * 0.5,
					-Screen.Height * 0.5 + diff,
					UI_FAR,
				}
			end
		end

		if keyboardToolbar ~= nil then
			keyboardToolbar.cutBtn.pos.X = Screen.SafeArea.Left + theme.padding
			keyboardToolbar.cutBtn.pos.Y = theme.paddingTiny

			keyboardToolbar.copyBtn.pos.X = keyboardToolbar.cutBtn.pos.X
				+ keyboardToolbar.cutBtn.Width
				+ theme.paddingTiny
			keyboardToolbar.copyBtn.pos.Y = theme.paddingTiny

			keyboardToolbar.pasteBtn.pos.X = keyboardToolbar.copyBtn.pos.X
				+ keyboardToolbar.copyBtn.Width
				+ theme.paddingTiny
			keyboardToolbar.pasteBtn.pos.Y = theme.paddingTiny

			-- keyboardToolbar.undoBtn.pos.X = keyboardToolbar.pasteBtn.pos.X
			-- 	+ keyboardToolbar.pasteBtn.Width
			-- 	+ theme.padding
			-- keyboardToolbar.undoBtn.pos.Y = theme.paddingTiny

			-- keyboardToolbar.redoBtn.pos.X = keyboardToolbar.undoBtn.pos.X
			-- 	+ keyboardToolbar.undoBtn.Width
			-- 	+ theme.paddingTiny
			-- keyboardToolbar.redoBtn.pos.Y = theme.paddingTiny

			keyboardToolbar.closeBtn.pos.X = Screen.Width
				- Screen.SafeArea.Right
				- keyboardToolbar.closeBtn.Width
				- theme.padding
			keyboardToolbar.closeBtn.pos.Y = theme.paddingTiny

			keyboardToolbar.pos.Z = -UI_FAR + 2
			keyboardToolbar.pos.Y = currentKeyboardHeight - diff
		end
	end
end

-- listeners to adapt ui considering virtual keyboard presence.
LocalEvent:Listen(LocalEvent.Name.VirtualKeyboardShown, function(keyboardHeight)
	currentKeyboardHeight = keyboardHeight
	applyVirtualKeyboardOffset()
end, { system = System })

LocalEvent:Listen(LocalEvent.Name.VirtualKeyboardHidden, function()
	focus(nil)
	currentKeyboardHeight = nil

	if systemUIRootFrame then
		ease:cancel(systemUIRootFrame)
		ease:inOutSine(systemUIRootFrame, 0.2).LocalPosition = {
			-Screen.Width * 0.5,
			-Screen.Height * 0.5,
			UI_FAR,
		}
	end

	if sharedUIRootFrame then
		ease:cancel(sharedUIRootFrame)
		ease:inOutSine(sharedUIRootFrame, 0.2).LocalPosition = {
			-Screen.Width * 0.5,
			-Screen.Height * 0.5,
			UI_FAR,
		}
	end

	if keyboardToolbar ~= nil then
		keyboardToolbar:remove()
		keyboardToolbar = nil
	end
end, { system = System })

-- GLOBAL FUNCTIONS USED BY ALL ENTITIES

function _parentDidResizeWrapper(node)
	if node == nil then
		return
	end
	if node.parentDidResizeSystem ~= nil then
		node:parentDidResizeSystem()
	end
	if node.parentDidResize ~= nil then
		node:parentDidResize()
	end
end

function _contentDidResizeWrapper(node)
	if node == nil then
		return
	end
	if node.contentDidResizeSystem ~= nil then
		node:contentDidResizeSystem()
	end
	if node.contentDidResize ~= nil then
		node:contentDidResize()
	end
end

function _onRemoveWrapper(node)
	if node == nil then
		return
	end
	if node.onRemoveSystem ~= nil then
		node:onRemoveSystem()
	end
	if node.onRemove ~= nil then
		node:onRemove()
	end
end

-- INIT

sharedUI = createUI()

sharedUI.systemUI = function(system)
	if system ~= System then
		error("can't access system UI", 2)
	end

	if systemUI == nil then
		systemUI = createUI(true)
		systemUI.unfocus = unfocus
	end

	return systemUI
end

return sharedUI
