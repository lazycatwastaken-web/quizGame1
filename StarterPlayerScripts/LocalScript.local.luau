local player = game.Players.LocalPlayer

player.CharacterAdded:Connect(function()
	local humanoid = player.Character:WaitForChild("Humanoid")
	humanoid.WalkSpeed = 40
end)