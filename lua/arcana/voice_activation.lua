if not CLIENT then return end
if not system.IsWindows() then return end
if not util.IsBinaryModuleInstalled("speech") then return end

require("speech")

local SPEECH
local BASE_GRAMMAR = [[
<grammar langid="409">
  <rule name="arcana_spells" toplevel="active">
    <o>...</o>
    <list>
		%s
    </list>
    <o>...</o>
  </rule>
</grammar>
]]

local triggerPhrases = {}
local function normalize(phrase)
	-- Robust normalization for voice command phrases
	if phrase == nil then return "" end

	-- Ensure string and lowercase
	phrase = tostring(phrase)
	phrase = string.lower(phrase)

	-- Replace common separators with spaces
	phrase = phrase:gsub("[-_/]+", " ")

	-- Remove all punctuation except spaces and alphanumerics
	phrase = phrase:gsub("[^%a%d%s]", " ")

	-- Collapse multiple whitespace to a single space
	phrase = phrase:gsub("%s+", " ")

	-- Trim leading/trailing spaces
	phrase = phrase:gsub("^%s+", ""):gsub("%s+$", "")

	return phrase
end

local function buildGrammar()
	local xmlPhrases = {}
	for phrase, _ in pairs(triggerPhrases) do
		table.insert(xmlPhrases, string.format("<phrase>%s</phrase>", phrase))
	end

	local grammar = BASE_GRAMMAR:format(table.concat(xmlPhrases, "\n"))
	file.Write("arcana_spells.xml", grammar)

	SPEECH = speech.create("HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Speech\\Recognizers\\Tokens\\MS-1033-80-DESK")
	SPEECH:interest(38)
	if SPEECH:grammar("arcana_spells.xml") then
		SPEECH:grammar_state("enabled")
		SPEECH:rule_state(nil, "active")
		Arcane:Print("Added", table.Count(triggerPhrases), "trigger phrases to voice activation")
	end
end

function Arcane:AddTriggerPhrase(phrase, spell_id)
	triggerPhrases[normalize(phrase)] = spell_id
	timer.Create("Arcana_VoiceActivation_BuildGrammar", 1, 1, buildGrammar)
end

function Arcane:RemoveTriggerPhrase(phrase)
	triggerPhrases[normalize(phrase)] = nil
	timer.Create("Arcana_VoiceActivation_BuildGrammar", 1, 1, buildGrammar)
end

hook.Add("PlayerStartVoice", "Arcana_VoiceActivation", function(ply)
	if not SPEECH then return end
	if ply ~= LocalPlayer() then return end

	SPEECH:reco_state("active")
end)

hook.Add("PlayerEndVoice", "Arcana_VoiceActivation", function(ply)
	if not SPEECH then return end
	if ply ~= LocalPlayer() then return end

	SPEECH:reco_state("inactive")
end)

local function holdingGrimoire()
	local ply = LocalPlayer()
	if not IsValid(ply) then return false end

	local wep = ply:GetActiveWeapon()
	if not IsValid(wep) then return false end

	return wep:GetClass() == "grimoire"
end

hook.Add("Think", "Arcana_VoiceActivation", function()
	if not SPEECH then return end

	local num, events, err = SPEECH:events(10)
	if num == nil then
		Arcane:Print("ERROR", err)
		return
	end

	if num == 0 then return end
	if not holdingGrimoire() then return end

	for _, event in pairs(events) do
		local spell_id = event.text and triggerPhrases[event.text]
		if spell_id then
			RunConsoleCommand("arcana", spell_id)
		end
	end
end)