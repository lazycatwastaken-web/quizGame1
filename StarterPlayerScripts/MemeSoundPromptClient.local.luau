-- Local client script that plays meme sounds when panel or answer prompts are triggered.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
--local ImageIDs = require(game.ReplicatedStorage:WaitForChild("ScreenGuiPics"))

-- Generated folders that contain the synced meme panels and Sound instances.
local localPlayer = Players.LocalPlayer
local panelsFolder = workspace:WaitForChild("MemeTestPanels")
local correctImages = require(ReplicatedStorage:WaitForChild("ImgsCorrect"))
local correctStageImageEvent = ReplicatedStorage:WaitForChild("CorrectStageImageEvent")
local soundsFolder = SoundService:WaitForChild("MemeSounds")
local rng = Random.new()
local correctImageToken = 0
local correctImageLabel = nil
local correctImageFadeTween = nil

local CORRECT_IMAGE_DISPLAY_SECONDS = 2.5
local STAGE_SOUNDS_FOLDER_NAME = "StageSounds"
local CORRECT_STAGE_SOUNDS_FOLDER_NAME = "Correct"

-- Connection tracking prevents duplicate prompt listeners as objects replicate in.
local connectedPrompts = {}
local connectedStagePanels = {}
local watchedButtons = {}

-- Converts image ids from modules into a thumbnail content string that works for asset/decal ids.
local function toImageContent(assetId)
	if assetId == nil then
		return ""
	end

	local text = tostring(assetId)
	local digits = text:match("%d+")
	if not digits then
		return ""
	end

	return "rbxthumb://type=Asset&id=" .. digits .. "&w=420&h=420"
end

-- Finds the player's cloned ScreenGui.ImgForCorrect image control and caches it.
local function getCorrectImageLabel()
	if correctImageLabel and correctImageLabel.Parent then
		return correctImageLabel
	end

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local screenGui = playerGui:WaitForChild("ScreenGui", 10)
	if not screenGui then
		warn("ScreenGui was not found in PlayerGui, so the correct-answer image cannot be displayed.")
		return nil
	end

	local imageLabel = screenGui:WaitForChild("ImgForCorrect", 10)
	if not imageLabel or not (imageLabel:IsA("ImageLabel") or imageLabel:IsA("ImageButton")) then
		warn("ScreenGui.ImgForCorrect must be an ImageLabel or ImageButton.")
		return nil
	end

	correctImageLabel = imageLabel
	return correctImageLabel
end

-- Forces the correct-answer image control to behave like a full-screen overlay.
local function configureCorrectImageOverlay(imageLabel)
	imageLabel.AnchorPoint = Vector2.new(0, 0)
	imageLabel.Position = UDim2.fromScale(0, 0)
	imageLabel.Size = UDim2.fromScale(1, 1)
	imageLabel.BackgroundTransparency = 1
	imageLabel.ScaleType = Enum.ScaleType.Stretch
	imageLabel.ZIndex = 100
end

-- Picks one random image entry from ReplicatedStorage.ImgsCorrect.
local function getRandomCorrectImageId()
	if #correctImages == 0 then
		return ""
	end

	local selectedImage = correctImages[rng:NextInteger(1, #correctImages)]
	local assetId = selectedImage
	if type(selectedImage) == "table" then
		assetId = selectedImage.id
	end

	return toImageContent(assetId)
end

-- Finds the pool of correct-stage sounds stored under SoundService.StageSounds.Correct.
local function getCorrectStageSoundsFolder()
	local stageSounds = SoundService:FindFirstChild(STAGE_SOUNDS_FOLDER_NAME)
	if not stageSounds then
		warn("SoundService.StageSounds was not found, so the correct-stage sound cannot be played.")
		return nil
	end

	local correctSounds = stageSounds:FindFirstChild(CORRECT_STAGE_SOUNDS_FOLDER_NAME)
	if not correctSounds then
		warn("SoundService.StageSounds.Correct was not found, so the correct-stage sound cannot be played.")
		return nil
	end

	return correctSounds
end

-- Picks one playable Sound from the correct-stage sound folder.
local function getRandomCorrectStageSound()
	local correctSounds = getCorrectStageSoundsFolder()
	if not correctSounds then
		return nil
	end

	local sounds = {}
	for _, child in ipairs(correctSounds:GetChildren()) do
		if child:IsA("Sound") and child.SoundId ~= "" then
			table.insert(sounds, child)
		end
	end

	if #sounds == 0 then
		warn("SoundService.StageSounds.Correct does not contain any Sounds with SoundId set.")
		return nil
	end

	return sounds[rng:NextInteger(1, #sounds)]
end

-- Plays one correct-stage sound locally when the player advances.
local function playRandomCorrectStageSound()
	local sound = getRandomCorrectStageSound()
	if not sound then
		return
	end

	sound:Stop()
	sound.TimePosition = 0
	sound:Play()
end

-- Shows a random correct-answer image briefly when the server confirms stage progress.
local function showRandomCorrectImage()
	local imageId = getRandomCorrectImageId()
	if imageId == "" then
		return
	end

	local imageLabel = getCorrectImageLabel()
	if not imageLabel then
		return
	end

	correctImageToken += 1
	local displayToken = correctImageToken

	if correctImageFadeTween then
		correctImageFadeTween:Cancel()
		correctImageFadeTween = nil
	end

	configureCorrectImageOverlay(imageLabel)
	imageLabel.Image = imageId
	imageLabel.ImageTransparency = 0
	imageLabel.Visible = true

	correctImageFadeTween = TweenService:Create(
		imageLabel,
		TweenInfo.new(CORRECT_IMAGE_DISPLAY_SECONDS, Enum.EasingStyle.Linear),
		{ ImageTransparency = 1 }
	)

	correctImageFadeTween:Play()
	correctImageFadeTween.Completed:Connect(function()
		if correctImageToken == displayToken and imageLabel.Parent then
			imageLabel.Visible = false
			correctImageFadeTween = nil
		end
	end)
end

correctStageImageEvent.OnClientEvent:Connect(function()
	showRandomCorrectImage()
	playRandomCorrectStageSound()
end)

local function stopMemeSounds()
	for _, sound in soundsFolder:GetChildren() do
		if sound:IsA("Sound") then
			sound:Stop()
			sound.TimePosition = 0
		end
	end
end

-- Rewinds the selected sound and plays it locally.
local function playMemeSound(soundName)
	if not soundName then
		return
	end
	
	stopMemeSounds()

	local sound = soundsFolder:FindFirstChild(soundName)
	if not sound or sound.SoundId == "" then
		return
	end
	

	sound:Play()
end

local function hitBelongsToLocalCharacter(hit)
	local character = localPlayer.Character
	return character and hit and hit:IsDescendantOf(character)
end

-- Hooks one ProximityPrompt to a callback that resolves which meme sound to play.
local function connectPrompt(prompt, getSoundName)
	if not prompt or connectedPrompts[prompt] then
		return
	end
	connectedPrompts[prompt] = true

	prompt.Triggered:Connect(function()
		playMemeSound(getSoundName())
	end)
end

local function connectStagePanel(panel)
	if not panel:IsA("BasePart") or not panel.Name:match("^BlackPanel%d+$") then
		return
	end

	local stage = panel.Parent
	if not stage or not stage:IsA("Model") or not stage.Name:match("^Frame%d+$") then
		return
	end

	if connectedStagePanels[panel] then
		return
	end
	connectedStagePanels[panel] = true

	panel.Touched:Connect(function(hit)
		if hitBelongsToLocalCharacter(hit) then
			stopMemeSounds()
		end
		print("Connect Stage Panel function triggered")
	end)
end

local function connectStagePanelsIn(instance)
	if instance:IsA("BasePart") then
		connectStagePanel(instance)
		return
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		connectStagePanel(descendant)
	end
end

-- Connects generated meme test panels that carry a PlaySoundPrompt.
local function connectPanel(panel)
	if not panel:IsA("BasePart") then
		return
	end

	local prompt = panel:FindFirstChild("PlaySoundPrompt")
	if not prompt then
		return
	end

	connectPrompt(prompt, function()
		return prompt:GetAttribute("MemeSoundName")
			or panel:GetAttribute("MemeSoundName")
	end)
end

-- Connects quiz button prompts and reads the correct meme sound from their attributes.
local function connectButton(button)
	if not button:IsA("Model") or not button.Name:match("^Button%d+$") then
		return
	end

	if not watchedButtons[button] then
		watchedButtons[button] = true
		button.ChildAdded:Connect(function()
			task.defer(function()
				connectButton(button)
			end)
		end)
	end

	local press = button:FindFirstChild("Press")
	if not press then
		return
	end

	local prompt = press:FindFirstChildWhichIsA("ProximityPrompt")
	if not prompt then
		return
	end

	connectPrompt(prompt, function()
		return prompt:GetAttribute("CorrectMemeSoundName")
			or press:GetAttribute("CorrectMemeSoundName")
			or button:GetAttribute("CorrectMemeSoundName")
	end)
end

-- Initial pass over objects that already exist when the client script starts.
for _, panel in ipairs(panelsFolder:GetChildren()) do
	connectPanel(panel)
end

for _, child in ipairs(workspace:GetChildren()) do
	connectButton(child)
	connectStagePanelsIn(child)
end

-- Watch for new panels and buttons that replicate after the initial pass.
panelsFolder.ChildAdded:Connect(connectPanel)
workspace.ChildAdded:Connect(function(child)
	connectButton(child)
	connectStagePanelsIn(child)
end)

-- Catch prompts that appear under existing button models after their parent arrived.
workspace.DescendantAdded:Connect(function(descendant)
	connectStagePanel(descendant)

	if not descendant:IsA("ProximityPrompt") then
		return
	end

	local press = descendant.Parent
	local button = press and press.Parent
	if press and press.Name == "Press" and button then
		connectButton(button)
	end
end)

-- Short retry window for late-replicating button children during spawn.
task.spawn(function()
	for _ = 1, 5 do
		task.wait(1)
		for _, child in ipairs(workspace:GetChildren()) do
			connectButton(child)
			connectStagePanelsIn(child)
		end
	end
end)
