-- Shared module that builds the test meme panels and matching sounds from NewGenMemes.
 local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local MemePanelSync = {}

-- Object names and layout defaults used when creating or updating panels.
local PANELS_FOLDER_NAME = "MemeTestPanels"
local SOUNDS_FOLDER_NAME = "MemeSounds"
local DECAL_NAME = "MemeDecal"
local PROMPT_NAME = "PlaySoundPrompt"
local PANEL_NAME_FORMAT = "MemePanel_%02d"
local PANEL_GAP = 1
local DEFAULT_PANEL_SIZE = Vector3.new(1.5, 10, 10)
local DEFAULT_PANEL_CFRAME = CFrame.new(0, 10, 0)

-- Converts numbers or asset strings into a Roblox rbxassetid URL.
local function normalizeAssetId(assetId)
	if assetId == nil then
		return ""
	end

	local text = tostring(assetId)
	local digits = text:match("%d+")
	if not digits then
		return ""
	end

	return "rbxassetid://" .. digits
end

-- Keeps generated panel names consistent and sortable.
local function panelNameForIndex(index)
	return string.format(PANEL_NAME_FORMAT, index)
end

-- Formats meme answer words so sound instances get readable names.
local function titleCaseWord(word)
	return word:sub(1, 1):upper() .. word:sub(2):lower()
end

-- Derives stable sound names from the current catalog so stale panel attributes cannot drift.
local function soundNameFromMeme(index, meme, usedNames)
	local parts = {}
	for part in tostring(meme.name or ""):gmatch("%w+") do
		table.insert(parts, titleCaseWord(part))
	end

	local baseName = table.concat(parts, "")
	if baseName == "" then
		baseName = string.format("MemeSound_%02d", index)
	end

	local soundName = baseName
	local suffix = 2
	while usedNames[soundName] do
		soundName = baseName .. tostring(suffix)
		suffix += 1
	end

	usedNames[soundName] = true
	return soundName
end

-- Finds a folder or creates it when the sync target is missing.
local function getOrCreateFolder(parent, folderName)
	local folder = parent:FindFirstChild(folderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = folderName
		folder.Parent = parent
	end
	return folder
end

-- Chooses the first panel as the layout template, creating one if needed.
local function getTemplatePanel(panelsFolder)
	local template = panelsFolder:FindFirstChild(panelNameForIndex(1))
	if template and template:IsA("BasePart") then
		return template
	end

	for _, child in ipairs(panelsFolder:GetChildren()) do
		if child:IsA("BasePart") then
			return child
		end
	end

	local panel = Instance.new("Part")
	panel.Name = panelNameForIndex(1)
	panel.Size = DEFAULT_PANEL_SIZE
	panel.CFrame = DEFAULT_PANEL_CFRAME
	panel.Anchored = true
	panel.Parent = panelsFolder
	return panel
end

-- Ensures the panel for a meme exists and is a BasePart clone of the template.
local function getOrCreatePanel(panelsFolder, templatePanel, index)
	local panelName = panelNameForIndex(index)
	local panel = panelsFolder:FindFirstChild(panelName)

	if not panel or not panel:IsA("BasePart") then
		if panel then
			panel:Destroy()
		end

		panel = templatePanel:Clone()
		panel.Name = panelName
		panel.Parent = panelsFolder
	end

	return panel
end

-- Applies size, position, decal, prompt, and metadata for one meme panel.
local function configurePanel(panel, templatePanel, baseCFrame, index, meme, soundName, soundId)
	local stepDistance = templatePanel.Size.Z + PANEL_GAP
	panel.Size = templatePanel.Size
	panel.CFrame = baseCFrame * CFrame.new(0, 0, -stepDistance * (index - 1))
	panel.Anchored = true
	panel:SetAttribute("MemeIndex", index)
	panel:SetAttribute("MemeName", meme.name or "")
	panel:SetAttribute("MemeSoundName", soundName)

	local decal = panel:FindFirstChild(DECAL_NAME)
	if not decal then
		decal = Instance.new("Decal")
		decal.Name = DECAL_NAME
		decal.Parent = panel
	end
	decal.Face = Enum.NormalId.Right
	decal.Texture = normalizeAssetId(meme.id)

	local prompt = panel:FindFirstChild(PROMPT_NAME)
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = PROMPT_NAME
		prompt.Parent = panel
	end
	prompt.ActionText = "Play Sound"
	prompt.ObjectText = meme.name or "Meme"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Enabled = soundId ~= ""
	prompt:SetAttribute("MemeSoundName", soundName)
end

-- Creates or updates the Sound instance that belongs to one meme.
local function configureSound(soundsFolder, index, meme, soundName, soundId)
	local sound = soundsFolder:FindFirstChild(soundName)
	if not sound then
		sound = Instance.new("Sound")
		sound.Name = soundName
		sound.Volume = 0.5
		sound.Parent = soundsFolder
	end

	sound.SoundId = soundId
	if typeof(meme.volume) == "number" then
		sound.Volume = meme.volume
	end
	sound:SetAttribute("MemeIndex", index)
	sound:SetAttribute("MemeName", meme.name or "")
	return sound
end

-- Removes generated panels that no longer have a meme entry.
local function removeExtraPanels(panelsFolder, memeCount)
	for _, child in ipairs(panelsFolder:GetChildren()) do
		local indexText = child.Name:match("^MemePanel_(%d+)$")
		local index = indexText and tonumber(indexText)
		if index and index > memeCount then
			child:Destroy()
		end
	end
end

-- Removes managed sounds that are past the list length or no longer referenced.
local function removeExtraManagedSounds(soundsFolder, memeCount, usedSoundNames)
	for _, child in ipairs(soundsFolder:GetChildren()) do
		if child:IsA("Sound") then
			local index = child:GetAttribute("MemeIndex")
			if typeof(index) == "number" and (index > memeCount or not usedSoundNames[child.Name]) then
				child:Destroy()
			end
		end
	end
end


-- Main entry point: syncs the meme catalog into Workspace panels and SoundService sounds.
function MemePanelSync.sync()
	local memes = require(ReplicatedStorage:WaitForChild("NewGenMemes"))
	local panelsFolder = getOrCreateFolder(Workspace, PANELS_FOLDER_NAME)
	local soundsFolder = getOrCreateFolder(SoundService, SOUNDS_FOLDER_NAME)
	local templatePanel = getTemplatePanel(panelsFolder)
	local baseCFrame = templatePanel.CFrame
	local usedSoundNames = {}

	for index, meme in ipairs(memes) do
		local soundId = normalizeAssetId(meme.sound)
		local soundName = soundNameFromMeme(index, meme, usedSoundNames)
		local panel = getOrCreatePanel(panelsFolder, templatePanel, index)
		configurePanel(panel, templatePanel, baseCFrame, index, meme, soundName, soundId)
		configureSound(soundsFolder, index, meme, soundName, soundId)
	end

	removeExtraPanels(panelsFolder, #memes)
	removeExtraManagedSounds(soundsFolder, #memes, usedSoundNames)

	return #memes
end

return MemePanelSync
