-- Server script that fills each quiz stage with one correct meme and two decoys.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- Reuse the shared ReplicatedStorage sync so NewGenMemes stays the source of truth.
local MemePanelSync = require(ReplicatedStorage:WaitForChild("MemePanelSync"))

-- Workspace naming conventions used to find Stage# containers and their nested frame/button models.
local MEME_POOL_FOLDER_NAME = "MemeTestPanels"
local STAGE_NAME_PATTERN = "^Stage(%d+)$"
local FRAME_NAME_PATTERN = "Frame%d"
local BUTTON_NAME_PATTERN = "Button%d"
local PANEL_NAME_PATTERN = "BlackPanel%d"
local MEME_DECAL_NAME = "MemeDecal"

-- Player progress, stage spawn, and client feedback settings.
local LEADERSTATS_NAME = "leaderstats"
local STAGE_STAT_NAME = "Stage"
local HIGHEST_STAGE_STAT_NAME = "HighestStage"
local STARTING_STAGE = 1
local STAGE_SPAWNS_FOLDER_NAME = "StageSpawns"
local STAGE_SPAWN_NAME_PATTERN = "StageSpawn%d"
local STAGE_SPAWN_SIZE = Vector3.new(6, 1, 6)
local STAGE_SPAWN_X_OFFSET_FROM_BUTTON = 12
local CHARACTER_SPAWN_HEIGHT_OFFSET = 0
local CORRECT_STAGE_IMAGE_EVENT_NAME = "CorrectStageImageEvent"
local INCORRECT_STAGE_IMAGE_EVENT_NAME = "IncorrectStageImageEvent"
local STAGE_NAVIGATION_EVENT_NAME = "StageNavigationEvent"
local STAGE_NAVIGATION_COOLDOWN_SECONDS = 0.15
--local DECAL_ROTATIONS = { 0, 90, 180, 270 }

local rng = Random.new(os.time() + math.floor(os.clock() * 1000000))
local killbrickConnections = {}
local stageSpawns = {}
local playerConnections = {}
local lastStageNavigationTimes = {}

-- Creates shared server-to-client events on demand so clients can react to stage progress.
local function getOrCreateRemoteEvent(eventName)
	local event = ReplicatedStorage:FindFirstChild(eventName)
	if not event then
		event = Instance.new("RemoteEvent")
		event.Name = eventName
		event.Parent = ReplicatedStorage
	end

	return event
end

local correctStageImageEvent = getOrCreateRemoteEvent(CORRECT_STAGE_IMAGE_EVENT_NAME)
local incorrectStageImageEvent = getOrCreateRemoteEvent(INCORRECT_STAGE_IMAGE_EVENT_NAME)
local stageNavigationEvent = getOrCreateRemoteEvent(STAGE_NAVIGATION_EVENT_NAME)
local playerStageTouchLocks = {}

-- Builds the leaderboard Stage stat that tracks a player's current quiz stage for this server session.
local function getOrCreateStageStat(player)
	local leaderstats = player:FindFirstChild(LEADERSTATS_NAME)
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = LEADERSTATS_NAME
		leaderstats.Parent = player
	end

	local stageStat = leaderstats:FindFirstChild(STAGE_STAT_NAME)
	if not stageStat then
		stageStat = Instance.new("IntValue")
		stageStat.Name = STAGE_STAT_NAME
		stageStat.Value = STARTING_STAGE
		stageStat.Parent = leaderstats
	end

	return stageStat
end

-- Builds the leaderboard stat that records the furthest stage a player has unlocked.
local function getOrCreateHighestStageStat(player)
	local stageStat = getOrCreateStageStat(player)
	local leaderstats = stageStat.Parent
	local highestStageStat = leaderstats:FindFirstChild(HIGHEST_STAGE_STAT_NAME)
	if not highestStageStat then
		highestStageStat = Instance.new("IntValue")
		highestStageStat.Name = HIGHEST_STAGE_STAT_NAME
		highestStageStat.Value = math.max(STARTING_STAGE, stageStat.Value)
		highestStageStat.Parent = leaderstats
	end

	if stageStat.Value > highestStageStat.Value then
		highestStageStat.Value = stageStat.Value
	end

	return highestStageStat
end

-- Looks up the invisible spawn pad assigned to a numbered quiz stage.
local function getStageSpawn(stageNumber)
	return stageSpawns[stageNumber]
end

-- Points Roblox's normal respawn system at the spawn pad for the player's current Stage value.
local function updatePlayerRespawnLocation(player)
	local stageStat = getOrCreateStageStat(player)
	local stageSpawn = getStageSpawn(stageStat.Value)

	if stageSpawn and stageSpawn:IsA("SpawnLocation") then
		player.RespawnLocation = stageSpawn
	else
		player.RespawnLocation = nil
	end
end

-- Moves a newly spawned character onto the correct stage pad as a backup to RespawnLocation.
local function spawnCharacterAtPlayerStage(player, character)
	playerStageTouchLocks[player] = {}
	updatePlayerRespawnLocation(player)

	local stageStat = getOrCreateStageStat(player)
	local stageSpawn = getStageSpawn(stageStat.Value)
	if not stageSpawn then
		return
	end

	local rootPart = character:WaitForChild("HumanoidRootPart", 5)
	if not rootPart then
		return
	end

	character:PivotTo(stageSpawn.CFrame + Vector3.new(0, CHARACTER_SPAWN_HEIGHT_OFFSET, 0))
end

-- Initializes progress stats and keeps respawn placement synced as the player's Stage changes.
local function setupPlayerStats(player)
	local stageStat = getOrCreateStageStat(player)
	local highestStageStat = getOrCreateHighestStageStat(player)
	updatePlayerRespawnLocation(player)

	if not playerConnections[player] then
		playerConnections[player] = {
			stageStat:GetPropertyChangedSignal("Value"):Connect(function()
				playerStageTouchLocks[player] = {}
				if stageStat.Value > highestStageStat.Value then
					highestStageStat.Value = stageStat.Value
				end
				updatePlayerRespawnLocation(player)
			end),

			player.CharacterAdded:Connect(function(character)
				task.defer(spawnCharacterAtPlayerStage, player, character)
			end),
		}
	end

	if player.Character then
		task.defer(spawnCharacterAtPlayerStage, player, player.Character)
	end
end

-- Clears per-player event connections and touch locks when a player leaves the server.
local function cleanupPlayerConnections(player)
	local connections = playerConnections[player]
	if not connections then
		return
	end

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	playerConnections[player] = nil
	playerStageTouchLocks[player] = nil
	lastStageNavigationTimes[player] = nil
end

-- Copies a simple array so shuffling does not mutate the original source list.
local function copyArray(array)
	local copy = {}
	for index, value in ipairs(array) do
		copy[index] = value
	end
	return copy
end

-- Returns a shuffled copy of an array using the script's seeded Random object.
local function shuffle(array)
	local shuffled = copyArray(array)
	for index = #shuffled, 2, -1 do
		local swapIndex = rng:NextInteger(1, index)
		shuffled[index], shuffled[swapIndex] = shuffled[swapIndex], shuffled[index]
	end
	return shuffled
end

local function getMemeKey(meme)
	return meme.index or meme.sourcePanelName
end

-- Draws memes from a shuffled bag so stages get varied answers before repeats are reused.
local function createMemeDrawBag(memePool)
	local remainingMemes = {}

	local function refill(excludedKeys)
		local refillCandidates = {}
		for _, meme in ipairs(memePool) do
			if not excludedKeys or not excludedKeys[getMemeKey(meme)] then
				table.insert(refillCandidates, meme)
			end
		end

		if #refillCandidates == 0 then
			refillCandidates = copyArray(memePool)
		end

		remainingMemes = shuffle(refillCandidates)
	end

	local function draw(excludedKeys)
		if #remainingMemes == 0 then
			refill(excludedKeys)
		end

		for index = #remainingMemes, 1, -1 do
			local meme = remainingMemes[index]
			if not excludedKeys or not excludedKeys[getMemeKey(meme)] then
				table.remove(remainingMemes, index)
				return meme
			end
		end

		refill(excludedKeys)
		return table.remove(remainingMemes)
	end

	refill()

	return {
		draw = draw,
	}
end

-- Selects three unique meme choices for a single stage from the shuffled draw bag.
local function drawStageMemes(memeDrawBag)
	local stageMemes = {}
	local selectedKeys = {}

	for _ = 1, 3 do
		local meme = memeDrawBag.draw(selectedKeys)
		table.insert(stageMemes, meme)
		selectedKeys[getMemeKey(meme)] = true
	end

	return stageMemes
end

-- Refreshes generated meme panels/sounds from ReplicatedStorage.NewGenMemes before randomizing.
local function syncMemePoolFromCatalog()
	local syncedCount = MemePanelSync.sync()
	print(string.format("QuizStageRandomizer synced %d meme panels from NewGenMemes.", syncedCount))
end

-- Converts a catalog image id into the content URL used by Decal.Texture.
local function normalizeAssetId(assetId)
	if assetId == nil then
		return ""
	end

	local digits = tostring(assetId):match("%d+")
	if not digits then
		return ""
	end

	return "rbxassetid://" .. digits
end

-- Uses the image asset as the stable identity shared by generated panels and catalog rows.
-- Catalog volume is intentionally excluded because it only controls sound playback.
local function getMemeIdentity(imageAssetId, fallbackName, fallbackSoundId)
	local normalizedImageId = normalizeAssetId(imageAssetId)
	if normalizedImageId ~= "" then
		return normalizedImageId
	end

	return string.lower(tostring(fallbackName or "")) .. "|" .. normalizeAssetId(fallbackSoundId)
end

-- Combines Workspace panels with only the NewGenMemes entries not already represented there.
local function getMemePool()
	local memePoolFolder = Workspace:WaitForChild(MEME_POOL_FOLDER_NAME)
	local memes = {}
	local seenMemeIdentities = {}

	for _, panel in ipairs(memePoolFolder:GetChildren()) do
		if panel:IsA("BasePart") then
			local decal = panel:FindFirstChild(MEME_DECAL_NAME)
			if decal and decal:IsA("Decal") and decal.Texture ~= "" then
				local memeIdentity = getMemeIdentity(
					decal.Texture,
					panel:GetAttribute("MemeName"),
					panel:GetAttribute("MemeSoundName")
				)
				if not seenMemeIdentities[memeIdentity] then
					seenMemeIdentities[memeIdentity] = true
					table.insert(memes, {
						decal = decal,
						index = panel:GetAttribute("MemeIndex"),
						name = panel:GetAttribute("MemeName") or panel.Name,
						soundName = panel:GetAttribute("MemeSoundName"),
						sourcePanelName = panel.Name,
					})
				end
			end
		end
	end

	local newGenMemes = require(ReplicatedStorage:WaitForChild("NewGenMemes"))
	for index, catalogMeme in ipairs(newGenMemes) do
		local texture = normalizeAssetId(catalogMeme.id)
		local memeIdentity = getMemeIdentity(catalogMeme.id, catalogMeme.name, catalogMeme.sound)
		if texture ~= "" and not seenMemeIdentities[memeIdentity] then
			local syncedPanelName = string.format("MemePanel_%02d", index)
			local syncedPanel = memePoolFolder:FindFirstChild(syncedPanelName)
			local syncedDecal = syncedPanel and syncedPanel:FindFirstChild(MEME_DECAL_NAME)
			local catalogDecal = syncedDecal

			if not (catalogDecal and catalogDecal:IsA("Decal")) then
				catalogDecal = Instance.new("Decal")
				catalogDecal.Name = MEME_DECAL_NAME
				catalogDecal.Face = Enum.NormalId.Right
				catalogDecal.Texture = texture
			end

			seenMemeIdentities[memeIdentity] = true
			-- catalogMeme.volume is deliberately ignored when constructing quiz records.
			table.insert(memes, {
				decal = catalogDecal,
				index = index,
				name = catalogMeme.name or string.format("Meme %d", index),
				soundName = syncedPanel and syncedPanel:GetAttribute("MemeSoundName") or nil,
				sourcePanelName = syncedPanelName,
			})
		end
	end

	table.sort(memes, function(left, right)
		local leftIndex = left.index or math.huge
		local rightIndex = right.index or math.huge
		if leftIndex == rightIndex then
			return left.sourcePanelName < right.sourcePanelName
		end
		return leftIndex < rightIndex
	end)

	assert(#memes >= 3, "QuizStageRandomizer needs at least 3 unique memes across Workspace.MemeTestPanels and ReplicatedStorage.NewGenMemes")
	return memes
end

-- Finds the three answer display panels inside a stage model.
local function getStagePanels(stage)
	local panels = {}

	for optionNumber = 1, 3 do
		local panel = stage:FindFirstChild(string.format(PANEL_NAME_PATTERN, optionNumber))
		if not panel or not panel:IsA("BasePart") then
			return nil
		end

		table.insert(panels, {
			part = panel,
			optionNumber = optionNumber,
		})
	end

	return panels
end

-- Discovers valid Stage# containers and resolves each one's nested Frame# and Button# models.
local function getStages()
	local stages = {}

	for _, stageModel in ipairs(Workspace:GetChildren()) do
		local stageNumber = tonumber(stageModel.Name:match(STAGE_NAME_PATTERN))
		if stageNumber and stageModel:IsA("Model") then
			local frameName = string.format(FRAME_NAME_PATTERN, stageNumber)
			local buttonName = string.format(BUTTON_NAME_PATTERN, stageNumber)
			local frame = stageModel:FindFirstChild(frameName)
			local button = stageModel:FindFirstChild(buttonName)

			if not (frame and frame:IsA("Model")) then
				warn(string.format("%s was skipped because it does not contain %s", stageModel.Name, frameName))
			elseif not button then
				warn(string.format("%s was skipped because it does not contain %s", stageModel.Name, buttonName))
			else
				local panels = getStagePanels(frame)
				if panels then
					table.insert(stages, {
						model = stageModel,
						frame = frame,
						button = button,
						number = stageNumber,
						panels = panels,
					})
				else
					warn(string.format("%s was skipped because %s does not have BlackPanel1, BlackPanel2, and BlackPanel3", stageModel.Name, frameName))
				end
			end
		end
	end

	table.sort(stages, function(left, right)
		return left.number < right.number
	end)

	return stages
end

-- Keeps all generated spawn pads together under Workspace.StageSpawns.
local function getOrCreateStageSpawnsFolder()
	local folder = Workspace:FindFirstChild(STAGE_SPAWNS_FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = STAGE_SPAWNS_FOLDER_NAME
		folder.Parent = Workspace
	end

	return folder
end

-- Reuses an existing StageSpawn# when present, whether it was generated or placed manually.
local function findStageSpawn(stage, spawnsFolder)
	local spawnName = string.format(STAGE_SPAWN_NAME_PATTERN, stage.number)
	local existingSpawn = spawnsFolder:FindFirstChild(spawnName)
	if existingSpawn and existingSpawn:IsA("BasePart") then
		return existingSpawn
	end

	existingSpawn = stage.model:FindFirstChild(spawnName, true)
	if existingSpawn and existingSpawn:IsA("BasePart") then
		return existingSpawn
	end

	existingSpawn = Workspace:FindFirstChild(spawnName)
	if existingSpawn and existingSpawn:IsA("BasePart") then
		return existingSpawn
	end

	return nil
end

-- Finds the nested Button# model/part that marks where a stage's prompt area begins.
local function getButtonForStage(stage)
	return stage.button or stage.model:FindFirstChild(string.format(BUTTON_NAME_PATTERN, stage.number))
end

-- Resolves the button's world position from either the button part, Press part, or model pivot.
local function getButtonCFrame(button)
	if button:IsA("BasePart") then
		return button.CFrame
	end

	local press = button:FindFirstChild("Press", true)
	if press and press:IsA("BasePart") then
		return press.CFrame
	end

	if button:IsA("Model") then
		return button:GetPivot()
	end

	return nil
end

-- Drops the spawn pad onto the nearest surface under the desired X-offset position.
local function raycastStageSpawnHeight(position, ignoredInstances)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = ignoredInstances

	local rayOrigin = position + Vector3.new(0, 30, 0)
	local rayResult = Workspace:Raycast(rayOrigin, Vector3.new(0, -80, 0), raycastParams)
	if rayResult then
		return rayResult.Position.Y + (STAGE_SPAWN_SIZE.Y / 2)
	end

	return position.Y
end

-- Calculates a spawn pad CFrame at a fair X-axis distance before the stage button.
local function getStageSpawnCFrame(stage, spawnsFolder)
	local button = getButtonForStage(stage)
	if not button then
		warn(string.format("Stage %d does not have %s, so no spawn point was created.", stage.number, string.format(BUTTON_NAME_PATTERN, stage.number)))
		return nil
	end

	local buttonCFrame = getButtonCFrame(button)
	if not buttonCFrame then
		warn(string.format("%s does not have a usable BasePart or pivot for spawn placement.", button.Name))
		return nil
	end

	local buttonPosition = buttonCFrame.Position
	local spawnPosition = buttonPosition + Vector3.new(STAGE_SPAWN_X_OFFSET_FROM_BUTTON, 0, 0)
	local ignoredInstances = { button, spawnsFolder }
	spawnPosition = Vector3.new(
		spawnPosition.X,
		raycastStageSpawnHeight(spawnPosition, ignoredInstances),
		spawnPosition.Z
	)

	return CFrame.lookAt(spawnPosition, Vector3.new(buttonPosition.X, spawnPosition.Y, buttonPosition.Z))
end

-- Creates or updates one invisible, non-colliding SpawnLocation for a stage.
local function configureStageSpawn(stage, spawnsFolder)
	local stageSpawn = findStageSpawn(stage, spawnsFolder)
	local spawnCFrame = getStageSpawnCFrame(stage, spawnsFolder)
	if not spawnCFrame then
		return nil
	end

	if not stageSpawn then
		stageSpawn = Instance.new("SpawnLocation")
		stageSpawn.Name = string.format(STAGE_SPAWN_NAME_PATTERN, stage.number)
		stageSpawn.Anchored = true
		stageSpawn.Enabled = true
		stageSpawn.Neutral = true
		stageSpawn.AllowTeamChangeOnTouch = false
		stageSpawn.Duration = 0
		stageSpawn.Parent = spawnsFolder
	end

	stageSpawn.CanCollide = false
	stageSpawn.Size = STAGE_SPAWN_SIZE
	stageSpawn.Transparency = 1
	stageSpawn.CFrame = spawnCFrame
	stageSpawn:SetAttribute("QuizStageNumber", stage.number)
	stageSpawns[stage.number] = stageSpawn
	return stageSpawn
end

-- Builds the full StageSpawn# lookup table used by player respawns.
local function configureStageSpawns(stages)
	local spawnsFolder = getOrCreateStageSpawnsFolder()
	for _, stage in ipairs(stages) do
		configureStageSpawn(stage, spawnsFolder)
	end
end

-- Validates a GUI navigation request, updates Stage on the server, and teleports immediately.
local function navigatePlayerByStageDelta(player, stageDelta)
	if typeof(stageDelta) ~= "number" or stageDelta % 1 ~= 0 or math.abs(stageDelta) ~= 1 then
		return
	end

	local stageStat = getOrCreateStageStat(player)
	local highestStageStat = getOrCreateHighestStageStat(player)
	local targetStage = stageStat.Value + stageDelta
	if targetStage > highestStageStat.Value then
		return
	end

	local targetSpawn = getStageSpawn(targetStage)
	if not targetSpawn then
		return
	end

	local now = os.clock()
	local lastNavigationTime = lastStageNavigationTimes[player]
	if lastNavigationTime and now - lastNavigationTime < STAGE_NAVIGATION_COOLDOWN_SECONDS then
		return
	end
	lastStageNavigationTimes[player] = now

	stageStat.Value = targetStage
	updatePlayerRespawnLocation(player)

	local character = player.Character
	if character and character.Parent then
		character:PivotTo(targetSpawn.CFrame + Vector3.new(0, CHARACTER_SPAWN_HEIGHT_OFFSET, 0))
	end
end

-- Removes old decals before a new meme image is applied to an answer panel.
local function clearPanelDecals(panel)
	for _, child in ipairs(panel:GetChildren()) do
		if child:IsA("Decal") then
			child:Destroy()
		end
	end
end

local function getHumanoidFromHit(hit)
	local character = hit and hit:FindFirstAncestorWhichIsA("Model")
	if not character then
		return nil
	end

	return character:FindFirstChildWhichIsA("Humanoid")
end

local function getPlayerFromHit(hit)
	local character = hit and hit:FindFirstAncestorWhichIsA("Model")
	if not character then
		return nil
	end

	return Players:GetPlayerFromCharacter(character)
end

-- Advances the player's Stage only when they touch the correct panel for their current stage.
local function advancePlayerStageFromPanel(player, panel)
	local stageNumber = panel:GetAttribute("QuizStageNumber")
	if typeof(stageNumber) ~= "number" then
		return
	end

	local stageStat = getOrCreateStageStat(player)
	if stageStat.Value == stageNumber then
		local nextStage = stageStat.Value + 1
		local highestStageStat = getOrCreateHighestStageStat(player)
		if nextStage > highestStageStat.Value then
			highestStageStat.Value = nextStage
		end
		stageStat.Value = nextStage
		updatePlayerRespawnLocation(player)
		correctStageImageEvent:FireClient(player, stageStat.Value)
	end
end

-- Handles a panel touch once per stage so repeated body-part touches do not duplicate progress or deaths.
local function resolvePlayerStageTouch(player, panel, humanoid)
	local stageNumber = panel:GetAttribute("QuizStageNumber")
	if typeof(stageNumber) ~= "number" then
		return
	end

	local stageStat = getOrCreateStageStat(player)
	if stageStat.Value ~= stageNumber then
		return
	end

	local touchLocks = playerStageTouchLocks[player]
	if not touchLocks then
		touchLocks = {}
		playerStageTouchLocks[player] = touchLocks
	end

	if touchLocks[stageNumber] then
		return
	end
	touchLocks[stageNumber] = true

	if panel:GetAttribute("IsKillbrick") == true then
		if humanoid and humanoid.Health > 0 then
			incorrectStageImageEvent:FireClient(player, stageNumber)
			humanoid.Health = 0
		end
	else
		advancePlayerStageFromPanel(player, panel)
	end
end

local function configurePanelCollisionAndHazard(panel, isCorrect)
	panel.CanCollide = false
	panel.CanTouch = true
	panel:SetAttribute("IsKillbrick", not isCorrect)

	if killbrickConnections[panel] then
		return
	end

	killbrickConnections[panel] = panel.Touched:Connect(function(hit)
		local player = getPlayerFromHit(hit)
		local humanoid = getHumanoidFromHit(hit)
		if player and humanoid then
			resolvePlayerStageTouch(player, panel, humanoid)
		end
	end)
end

-- Stores quiz metadata on panels, decals, buttons, and prompts for other scripts.
local function setMemeAttributes(instance, meme, isCorrect, stageNumber, optionNumber)
	instance:SetAttribute("QuizStageNumber", stageNumber)
	instance:SetAttribute("QuizOptionNumber", optionNumber)
	instance:SetAttribute("MemeName", meme.name)
	instance:SetAttribute("MemeIndex", meme.index)
	instance:SetAttribute("MemeSoundName", meme.soundName)
	instance:SetAttribute("SourceMemePanelName", meme.sourcePanelName)
	instance:SetAttribute("IsCorrectMeme", isCorrect)
end

-- Clones one meme decal onto an answer panel and labels it as correct or decoy.
local function applyMemeToPanel(panelInfo, meme, isCorrect, stageNumber)
	local panel = panelInfo.part
	clearPanelDecals(panel)
	configurePanelCollisionAndHazard(panel, isCorrect)

	local decal = meme.decal:Clone()

	decal.Name = MEME_DECAL_NAME
	decal.Parent = panel

	setMemeAttributes(panel, meme, isCorrect, stageNumber, panelInfo.optionNumber)
	setMemeAttributes(decal, meme, isCorrect, stageNumber, panelInfo.optionNumber)
end

-- Writes stage numbering and correct-answer details onto the Stage#, Frame#, Button#, and Press instances.
local function setStageAttributes(stage, correctMeme, correctPanelInfo)
	local function applyCorrectAnswerAttributes(instance)
		instance:SetAttribute("Stage", stage.number)
		instance:SetAttribute("QuizStageNumber", stage.number)
		instance:SetAttribute("CorrectMemeName", correctMeme.name)
		instance:SetAttribute("CorrectMemeIndex", correctMeme.index)
		instance:SetAttribute("CorrectMemeSoundName", correctMeme.soundName)
		instance:SetAttribute("CorrectPanelName", correctPanelInfo.part.Name)
		instance:SetAttribute("CorrectOptionNumber", correctPanelInfo.optionNumber)
		instance:SetAttribute("CorrectSourceMemePanelName", correctMeme.sourcePanelName)
	end

	applyCorrectAnswerAttributes(stage.model)
	applyCorrectAnswerAttributes(stage.frame)

	local button = getButtonForStage(stage)
	if not button then
		return
	end

	applyCorrectAnswerAttributes(button)

	local press = button:FindFirstChild("Press")
	if press then
		applyCorrectAnswerAttributes(press)
	end
end

-- Picks three memes for a stage, shuffles their panel positions, and records the answer.
local function configureStage(stage, memeDrawBag)
	local stageMemes = drawStageMemes(memeDrawBag)
	local correctMeme = stageMemes[1]
	local shuffledPanels = shuffle(stage.panels)
	local correctPanelInfo = nil

	for index, panelInfo in ipairs(shuffledPanels) do
		local meme = stageMemes[index]
		local isCorrect = meme == correctMeme
		if isCorrect then
			correctPanelInfo = panelInfo
		end

		applyMemeToPanel(panelInfo, meme, isCorrect, stage.number)
	end

	setStageAttributes(stage, correctMeme, correctPanelInfo)
end

-- Build the source meme list, randomize every discovered stage, and log the result.
Players.PlayerAdded:Connect(setupPlayerStats)
Players.PlayerRemoving:Connect(cleanupPlayerConnections)

syncMemePoolFromCatalog()

local memePool = getMemePool()
local stages = getStages()
local memeDrawBag = createMemeDrawBag(memePool)

for _, stage in ipairs(stages) do
	configureStage(stage, memeDrawBag)
end

configureStageSpawns(stages)
stageNavigationEvent.OnServerEvent:Connect(navigatePlayerByStageDelta)

for _, player in ipairs(Players:GetPlayers()) do
	setupPlayerStats(player)
end

print(string.format("QuizStageRandomizer configured %d stages with %d memes.", #stages, #memePool))
