AddCSLuaFile()

local function log(...)
	Msg("[ShaderToGMA] ")
	print(...)
end

if SERVER then
	local function lowerFixPath(p)
		p = string.gsub(p, "\\", "/")
		p = string.TrimLeft(p, "/")

		return string.lower(p)
	end

	local function u8(n)
		return string.char(bit.band(n or 0, 0xFF))
	end

	local function u32le(n)
		n = math.floor(tonumber(n) or 0)
		n = n % 4294967296
		local b1 = bit.band(n, 0xFF)
		local b2 = bit.band(bit.rshift(n, 8), 0xFF)
		local b3 = bit.band(bit.rshift(n, 16), 0xFF)
		local b4 = bit.band(bit.rshift(n, 24), 0xFF)

		return string.char(b1, b2, b3, b4)
	end

	local function u64le(low32, high32)
		low32 = math.floor(tonumber(low32) or 0) % 4294967296
		high32 = math.floor(tonumber(high32) or 0) % 4294967296

		return u32le(low32) .. u32le(high32)
	end

	local function cstr(s)
		return (s or "") .. "\0"
	end

	local function readGameFile(path, realm)
		local f = file.Open(path, "rb", realm)
		if not f then return nil end
		local data = f:Read(f:Size())
		f:Close()

		return data
	end

	local function crc32_num(data)
		local s = util.CRC(data or "")
		local n = tonumber(s) or 0

		return n % 4294967296
	end

	local function createGMA(files, meta)
		meta = meta or {}
		if not istable(files) or #files == 0 then return false, "no files" end

		local entries = {}
		local fileDatas = {}

		for i = 1, #files do
			local p = lowerFixPath(files[i].path)
			local data = files[i].data
			local crc = crc32_num(data)
			entries[#entries + 1] = {
				id = i,
				path = p,
				size = #data,
				crc = crc
			}

			fileDatas[#fileDatas + 1] = data
		end

		local chunks = {}

		chunks[#chunks + 1] = "GMAD"
		chunks[#chunks + 1] = u8(3)
		chunks[#chunks + 1] = u64le(0, 0)
		local t = os.time() or 0
		chunks[#chunks + 1] = u64le(t, 0)
		chunks[#chunks + 1] = u8(0)
		chunks[#chunks + 1] = cstr(meta.title or "shader_to_gma")
		chunks[#chunks + 1] = cstr(meta.description or "")
		chunks[#chunks + 1] = cstr(meta.author or "")
		chunks[#chunks + 1] = u32le(tonumber(meta.addon_version) or 1)

		for _, e in ipairs(entries) do
			chunks[#chunks + 1] = u32le(e.id)
			chunks[#chunks + 1] = cstr(e.path)
			chunks[#chunks + 1] = u64le(e.size, 0)
			chunks[#chunks + 1] = u32le(e.crc)
		end

		chunks[#chunks + 1] = u32le(0)

		for _, data in ipairs(fileDatas) do
			chunks[#chunks + 1] = data
		end

		local pre = table.concat(chunks)
		local finalCrc = crc32_num(pre)
		chunks[#chunks + 1] = u32le(finalCrc)
		local blob = table.concat(chunks)

		return true, blob
	end

	util.AddNetworkString("shader_to_gma")
	local CHUNK_SIZE = 60000
	local shaderFiles = {}
	local shaderNames = {}
	local gmaChunks = {}
	local dirty = false

	local function hashedName(name, data)
		local hash = string.sub(util.SHA256(data), 1, 8)
		local base, suffix = string.match(name, "^(.+)(_[pv]s%w+)$")
		if not base then return name .. "_" .. hash end

		return base .. "_" .. hash .. suffix
	end

	local function buildGMA()
		dirty = false
		gmaChunks = {}
		shaderNames = {}

		local files = {}
		for name, src in SortedPairs(shaderFiles) do
			local data = readGameFile(src.path, src.realm)
			if not data then
				shaderFiles[name] = nil
			else
				local hashed = hashedName(name, data)
				shaderNames[name] = hashed
				files[#files + 1] = { path = "shaders/fxc/" .. hashed .. ".vcs", data = data }
			end
		end

		local ok, res = createGMA(files, {
			title = "shader_to_gma"
		})

		if not ok then
			log("Failed to build GMA:", res)
			return
		end

		local compressed = util.Compress(res)
		for i = 1, #compressed, CHUNK_SIZE do
			gmaChunks[#gmaChunks + 1] = string.sub(compressed, i, i + CHUNK_SIZE - 1)
		end
	end

	function resource.AddShader(shaderName)
		local path = "shaders/fxc/" .. shaderName .. ".vcs"
		local realm = "MOD"
		if not file.Exists(path, "MOD") then
			if not file.Exists(path, "GAME") then
				ErrorNoHalt("Missing shader file: " .. path .. " (MOD and GAME)\n")
				return
			else
				realm = "GAME"
			end
		end

		shaderFiles[shaderName] = { path = path, realm = realm }
		dirty = true
	end

	local justSpawned = {}
	hook.Add("PlayerInitialSpawn", "shader_to_gma", function(ply)
		justSpawned[ply] = true
	end)

	local function sendGMA(ply)
		if dirty then buildGMA() end

		local chunks = gmaChunks
		local names = shaderNames
		local total = #chunks
		if total == 0 then
			net.Start("shader_to_gma")
			net.WriteUInt(0, 16)
			net.WriteUInt(0, 16)
			net.Send(ply)
			return
		end

		local timerName = "shader_to_gma_" .. ply:UserID()
		local index = 0
		timer.Create(timerName, 1, total, function()
			if not IsValid(ply) then
				timer.Remove(timerName)
				return
			end

			index = index + 1
			local chunk = chunks[index]
			net.Start("shader_to_gma")
			net.WriteUInt(index, 16)
			net.WriteUInt(total, 16)
			if index == 1 then
				net.WriteUInt(table.Count(names), 16)
				for name, hashed in pairs(names) do
					net.WriteString(name)
					net.WriteString(hashed)
				end
			end
			net.WriteUInt(#chunk, 16)
			net.WriteData(chunk, #chunk)
			net.Send(ply)
		end)
	end

	hook.Add("SetupMove", "shader_to_gma", function(ply, _, ucmd)
		if justSpawned[ply] and not ucmd:IsForced() then
			justSpawned[ply] = nil
			sendGMA(ply)
		end
	end)
end

if CLIENT then
	SHADER_MOUNTED = _G.SHADER_MOUNTED or false
	SHADER_NAMES = _G.SHADER_NAMES or {}

	local function resolveShaderName(name)
		return SHADER_NAMES[name] or name
	end

	local function shaderPath(name)
		return "shaders/fxc/" .. resolveShaderName(name) .. ".vcs"
	end

	function ShaderExists(name)
		return SHADER_NAMES[name] ~= nil and file.Exists(shaderPath(name), "GAME")
	end

	local receivedChunks = {}
	local pendingNames = {}
	net.Receive("shader_to_gma", function()
		local index = net.ReadUInt(16)
		local total = net.ReadUInt(16)
		if index > 0 then
			if index == 1 then
				receivedChunks = {}
				pendingNames = {}
				for _ = 1, net.ReadUInt(16) do
					local name = net.ReadString()
					local hashed = net.ReadString()
					pendingNames[name] = hashed
				end
			end
			receivedChunks[index] = net.ReadData(net.ReadUInt(16))
			if index < total then return end
		end

		local compressed = table.concat(receivedChunks, "", 1, total)
		receivedChunks = {}

		local data, reason
		if total == 0 then
			reason = "Nothing to mount"
		elseif not system.IsWindows() then
			reason = "Shaders not supported on this platform"
		else
			data = util.Decompress(compressed)
			if not data then reason = "Failed to decompress GMA" end
		end

		if reason then
			log(reason)
			SHADER_MOUNTED = true
			hook.Run("ShaderMounted", reason)
			return
		end

		local files = file.Find("data/shader_to_gma_*.gma", "MOD")
		for _, f in ipairs(files) do
			file.Delete(f)
		end

		local fileName = "shader_to_gma_" .. os.time() .. ".gma"
		file.Write(fileName, data)

		local ok, filesOrErr = game.MountGMA("data/" .. fileName)
		if not ok then
			log("Failed to mount GMA:", filesOrErr)
		else
			log("Mounted GMA")
			PrintTable(filesOrErr)
			SHADER_NAMES = pendingNames
			hook.Run("ShaderMounted", filesOrErr)
			SHADER_MOUNTED = true
		end
	end)

	local shader_mat = [==[
		screenspace_general
		{
			$pixshader ""
			$vertexshader ""

			$basetexture ""
			$texture1    ""
			$texture2    ""
			$texture3    ""

			// Mandatory, don't touch
			$ignorez            1
			$vertexcolor        1
			$vertextransform    1
			"<dx90"
			{
				$no_draw 1
			}

			$copyalpha                 0
			$alpha_blend_color_overlay 0
			$alpha_blend               1
			$linearwrite               1
			$linearread_basetexture    1
		}
	]==]

	function CreateShaderMaterial(name, opts, shader)
		local key_values = {}
		for k, v in pairs(util.KeyValuesToTable(shader_mat, false, true)) do
			key_values[k:lower()] = v
		end

		if opts then
			for k, v in pairs(opts) do
				key_values[k:lower()] = v
			end
		end

		for _, key in ipairs({ "$pixshader", "$vertexshader" }) do
			if isstring(key_values[key]) and key_values[key] ~= "" then
				key_values[key] = resolveShaderName(key_values[key])
			end
		end

		local shaders = tostring(key_values["$pixshader"]) .. tostring(key_values["$vertexshader"])

		return CreateMaterial(name .. "_" .. util.CRC(shaders), shader or "screenspace_general", key_values)
	end

	local internalHookIndex = 0
	function WaitForShaderMounted(shaderNames, callback)
		if not system.IsWindows() then
			callback(false)
			return
		end

		if not istable(shaderNames) and isstring(shaderNames) then shaderNames = { shaderNames } end

		local allAvailable = true
		for _, shaderName in pairs(shaderNames) do
			if not ShaderExists(shaderName) then
				allAvailable = false
				break
			end
		end

		if allAvailable then
			callback(true)
			return
		end

		if not SHADER_MOUNTED then
			local hookName = "shader_to_gma_WaitForShaderMounted_" .. internalHookIndex
			internalHookIndex = internalHookIndex + 1

			hook.Add("ShaderMounted", hookName, function(filesOrErr)
				if not istable(filesOrErr) then
					hook.Remove("ShaderMounted", hookName)
					callback(false)
					return
				end

				allAvailable = true
				for _, shaderName in pairs(shaderNames) do
					if not table.HasValue(filesOrErr, shaderPath(shaderName)) then
						allAvailable = false
						break
					end
				end

				hook.Remove("ShaderMounted", hookName)
				callback(allAvailable)
			end)
		else
			callback(false)
		end
	end
end
