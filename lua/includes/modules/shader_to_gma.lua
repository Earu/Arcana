AddCSLuaFile()

local function log(...)
	Msg("[ShaderToGMA] ")
	print(...)
end

local function toglName(name)
	local base, suffix = string.match(name, "^(.+)(_[pv]s%w+)$")
	if not base then return name .. "_togl" end

	return base .. "_togl" .. suffix
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

	local BLOCK_END = 0xFFFFFFFF
	local BLOCK_RAW = 0x80000000
	local BLOCK_LZMA = 0x40000000
	local BLOCK_SIZE_MASK = 0x3FFFFFFF

	local OP_MOV, OP_DCL, OP_TEXLD, OP_CMP, OP_TEXLDD, OP_TEXLDL = 0x01, 0x1F, 0x42, 0x58, 0x5D, 0x5F
	local OP_COMMENT, OP_END = 0xFFFE, 0xFFFF
	local LITERALS = { [0x1F] = true, [0x2F] = true, [0x30] = true, [0x51] = true }
	local REG_TEMP, REG_DEPTHOUT, REG_SAMPLER, SAMPLER_2D, SAMPLER_VOLUME = 0, 9, 10, 2, 4
	local MAX_TEMPS = 32
	local RESULT_MODIFIER = 0x00F00000
	local PREDICATED = 0x10000000
	local TOGL_REJECTED = {
		[20] = true, [21] = true, [22] = true, [23] = true, [24] = true,
		[25] = true, [26] = true, [27] = true, [28] = true, [29] = true, [30] = true,
		[34] = true, [44] = true, [80] = true, [89] = true, [94] = true, [96] = true,
		[OP_TEXLDD] = true,
	}

	local function u32at(s, offset)
		local a, b, c, d = string.byte(s, offset + 1, offset + 4)
		if not d then return nil end

		return a + b * 0x100 + c * 0x10000 + d * 0x1000000
	end

	local function registerType(token)
		return bit.bor(bit.band(bit.rshift(token, 28), 0x7), bit.band(bit.rshift(token, 8), 0x18))
	end

	local function highestTemp(code, i, length, highest)
		for k = 1, length do
			local operand = u32at(code, (i + k) * 4)
			if registerType(operand) == REG_TEMP then highest = math.max(highest, bit.band(operand, 0x7FF)) end
		end

		return highest
	end

	local function patchBytecode(code)
		local count = math.floor(#code / 4)
		local vertex = bit.rshift(u32at(code, 0), 16) == 0xFFFE
		local samplers, patches, depthWrites = {}, {}, {}
		local supported, highest = true, -1
		local i = 1
		while i < count do
			local token = u32at(code, i * 4)
			local op = bit.band(token, 0xFFFF)
			if op == OP_END then break end

			if op == OP_COMMENT then
				i = i + 1 + bit.band(bit.rshift(token, 16), 0x7FFF)
			else
				local length = bit.band(bit.rshift(token, 24), 0xF)
				if not LITERALS[op] then highest = highestTemp(code, i, length, highest) end

				if bit.band(token, PREDICATED) ~= 0 or TOGL_REJECTED[op] or (vertex and (op == OP_TEXLD or op == OP_TEXLDL)) then
					supported = false
				elseif op == OP_DCL then
					local dst = u32at(code, (i + 2) * 4)
					if registerType(dst) == REG_SAMPLER then
						samplers[bit.band(dst, 0x7FF)] = bit.band(bit.rshift(u32at(code, (i + 1) * 4), 27), 0xF)
					end
				elseif op == OP_TEXLDL then
					local kind = samplers[bit.band(u32at(code, (i + 3) * 4), 0x7FF)]
					if kind == SAMPLER_VOLUME then
						patches[#patches + 1] = { i, 1, u32le(bit.bor(bit.band(token, 0xFFFF0000), OP_TEXLD)) }
					elseif kind ~= SAMPLER_2D then
						supported = false
					end
				elseif op == OP_CMP and registerType(u32at(code, (i + 1) * 4)) == REG_DEPTHOUT then
					depthWrites[#depthWrites + 1] = { i, length }
				end

				i = i + 1 + length
			end
		end

		local temp = highest + 1
		if #depthWrites > 0 and temp >= MAX_TEMPS then supported = false end

		for _, write in ipairs(depthWrites) do
			local at, length = write[1], write[2]
			local dst = u32at(code, (at + 1) * 4)
			patches[#patches + 1] = { at + 1, length, u32le(bit.bor(0x80010000, bit.band(dst, RESULT_MODIFIER), temp))
				.. string.sub(code, (at + 2) * 4 + 1, (at + 1 + length) * 4)
				.. u32le(bit.bor(0x02000000, OP_MOV)) .. u32le(bit.band(dst, bit.bnot(RESULT_MODIFIER))) .. u32le(bit.bor(0x80000000, temp)) }
		end

		if #patches == 0 then return code, 0, supported end

		table.sort(patches, function(a, b) return a[1] < b[1] end)

		local parts, last = {}, 0
		for _, patch in ipairs(patches) do
			parts[#parts + 1] = string.sub(code, last + 1, patch[1] * 4)
			parts[#parts + 1] = patch[3]
			last = (patch[1] + patch[2]) * 4
		end
		parts[#parts + 1] = string.sub(code, last + 1)

		return table.concat(parts), #patches, supported
	end

	local function decodeBlock(header, block)
		if bit.band(header, BLOCK_RAW) ~= 0 then return block end
		if bit.band(header, BLOCK_LZMA) == 0 or string.sub(block, 1, 4) ~= "LZMA" then return nil end

		local actual, size = u32at(block, 4), u32at(block, 8)
		local data = util.Decompress(string.sub(block, 13, 17) .. string.sub(block, 5, 8) .. "\0\0\0\0" .. string.sub(block, 18, 17 + size))
		if not data or #data ~= actual then return nil end

		return data
	end

	local function patchCombos(data)
		local parts, changed, supported, offset = {}, 0, true, 0
		while offset + 8 <= #data do
			local size = u32at(data, offset + 4)
			local code, count, ok = patchBytecode(string.sub(data, offset + 9, offset + 8 + size))
			parts[#parts + 1] = string.sub(data, offset + 1, offset + 4) .. u32le(#code) .. code
			changed = changed + count
			supported = supported and ok
			offset = offset + 8 + size
		end

		return table.concat(parts), changed, supported
	end

	local function toglVariant(data)
		if u32at(data, 0) ~= 6 then return nil, false end

		local records = u32at(data, 20)
		local tableEnd = 28 + records * 8
		local prefixEnd = tableEnd + 4 + u32at(data, tableEnd) * 8
		local ids, bodies = {}, {}
		local changed, supported = 0, true
		for r = 1, records do
			local offset = u32at(data, 24 + r * 8)
			ids[r] = u32at(data, 20 + r * 8)
			if ids[r] ~= BLOCK_END then
				local body = {}
				while true do
					local header = u32at(data, offset)
					if not header then return nil, false end
					if header == BLOCK_END then break end

					local size = bit.band(header, BLOCK_SIZE_MASK)
					local decoded = decodeBlock(header, string.sub(data, offset + 5, offset + 4 + size))
					if not decoded then return nil, false end

					local combos, count, ok = patchCombos(decoded)
					body[#body + 1] = u32le(BLOCK_RAW + #combos) .. combos
					changed = changed + count
					supported = supported and ok
					offset = offset + 4 + size
				end

				body[#body + 1] = u32le(BLOCK_END)
				bodies[r] = table.concat(body)
			end
		end

		if not supported then return nil, false end
		if changed == 0 then return nil, true end

		local offsets, position = {}, prefixEnd
		for r = 1, records do
			if bodies[r] then
				offsets[r] = position
				position = position + #bodies[r]
			end
		end

		local out = { string.sub(data, 1, 28) }
		for r = 1, records do
			out[#out + 1] = u32le(ids[r]) .. u32le(offsets[r] or position)
		end
		out[#out + 1] = string.sub(data, tableEnd + 1, prefixEnd)
		for r = 1, records do
			if bodies[r] then out[#out + 1] = bodies[r] end
		end

		return table.concat(out), true
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

	SHADER_TO_GMA = SHADER_TO_GMA or { files = {}, names = {}, chunks = {}, spawning = {}, ready = {} }
	local state = SHADER_TO_GMA
	state.dirty = true

	local function hashedName(name, data)
		local hash = string.sub(util.SHA256(data), 1, 8)
		local base, suffix = string.match(name, "^(.+)(_[pv]s%w+)$")
		if not base then return name .. "_" .. hash end

		return base .. "_" .. hash .. suffix
	end

	local function sameNames(a, b)
		for k, v in pairs(a) do
			if b[k] ~= v then return false end
		end

		for k in pairs(b) do
			if a[k] == nil then return false end
		end

		return true
	end

	local function buildGMA()
		local names, files = {}, {}
		for name, src in SortedPairs(state.files) do
			local data = readGameFile(src.path, src.realm)
			if not data then
				state.files[name] = nil
			else
				local hashed = hashedName(name, data)
				names[name] = hashed
				files[#files + 1] = { path = "shaders/fxc/" .. hashed .. ".vcs", data = data }

				local variant, supported = toglVariant(data)
				local togl = toglName(name)
				if not supported then
					names[togl] = ""
				elseif variant then
					local hashedTogl = hashedName(togl, variant)
					names[togl] = hashedTogl
					files[#files + 1] = { path = "shaders/fxc/" .. hashedTogl .. ".vcs", data = variant }
				end
			end
		end

		local changed = not sameNames(names, state.names)
		if not changed and not state.dirty then return false end

		state.dirty = false
		state.names = names
		state.chunks = {}
		if #files == 0 then return changed end

		local ok, res = createGMA(files, {
			title = "shader_to_gma"
		})

		if not ok then
			log("Failed to build GMA:", res)
			return changed
		end

		local compressed = util.Compress(res)
		for i = 1, #compressed, CHUNK_SIZE do
			state.chunks[#state.chunks + 1] = string.sub(compressed, i, i + CHUNK_SIZE - 1)
		end

		return changed
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

		state.files[shaderName] = { path = path, realm = realm }
		state.dirty = true
	end

	hook.Add("PlayerInitialSpawn", "shader_to_gma", function(ply)
		state.spawning[ply] = true
	end)

	hook.Add("PlayerDisconnected", "shader_to_gma", function(ply)
		state.spawning[ply] = nil
		state.ready[ply] = nil
	end)

	local function sendGMA(ply)
		if state.dirty then buildGMA() end

		local chunks = state.chunks
		local names = state.names
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
		if state.spawning[ply] and not ucmd:IsForced() then
			state.spawning[ply] = nil
			state.ready[ply] = true
			sendGMA(ply)
		end
	end)

	hook.Add("OnRefreshLua", "shader_to_gma", function()
		if not buildGMA() then return end

		for ply in pairs(state.ready) do
			if IsValid(ply) then sendGMA(ply) end
		end
	end)
end

if CLIENT then
	SHADER_MOUNTED = _G.SHADER_MOUNTED or false
	SHADER_NAMES = _G.SHADER_NAMES or {}
	SHADER_TO_GMA = SHADER_TO_GMA or { materials = setmetatable({}, { __mode = "k" }) }
	local materials = SHADER_TO_GMA.materials

	local TOGL = not system.IsWindows()

	local function resolveShaderName(name)
		if TOGL then
			local togl = SHADER_NAMES[toglName(name)]
			if togl then return togl end
		end

		return SHADER_NAMES[name] or name
	end

	local function retargetMaterials()
		for mat, entry in pairs(materials) do
			local changed = false
			for key, shaderName in pairs(entry.names) do
				local resolved = resolveShaderName(shaderName)
				if entry.resolved[key] ~= resolved then
					entry.resolved[key] = resolved
					mat:SetString(key, resolved)
					changed = true
				end
			end

			if changed then mat:Recompute() end
		end
	end

	local function shaderPath(name)
		return "shaders/fxc/" .. resolveShaderName(name) .. ".vcs"
	end

	function ShaderExists(name)
		return SHADER_NAMES[name] ~= nil and resolveShaderName(name) ~= "" and file.Exists(shaderPath(name), "GAME")
	end

	local function saltName(name, salt)
		local base, suffix = string.match(name, "^(.+)(_[pv]s%w+)$")
		if not base then return name .. "_" .. salt end

		return base .. "_" .. salt .. suffix
	end

	local function u32le(n)
		return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
	end

	local function saltGMA(data, salt)
		local pos = 22
		while true do
			local stop = string.find(data, "\0", pos, true)
			local required = string.sub(data, pos, stop - 1)
			pos = stop + 1
			if required == "" then break end
		end

		for _ = 1, 3 do
			pos = string.find(data, "\0", pos, true) + 1
		end
		pos = pos + 4

		local out = { string.sub(data, 1, pos - 1) }
		while true do
			local id = string.sub(data, pos, pos + 3)
			out[#out + 1] = id
			pos = pos + 4
			if id == "\0\0\0\0" then break end

			local stop = string.find(data, "\0", pos, true)
			local path = string.sub(data, pos, stop - 1)
			local dir, stem, ext = string.match(path, "^(shaders/fxc/)(.+)(%.vcs)$")
			if dir then path = dir .. saltName(stem, salt) .. ext end
			out[#out + 1] = path .. "\0" .. string.sub(data, stop + 1, stop + 12)
			pos = stop + 13
		end

		out[#out + 1] = string.sub(data, pos, #data - 4)
		local body = table.concat(out)

		return body .. u32le(tonumber(util.CRC(body)) or 0)
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

		if TOGL then
			local salt = string.format("%x", os.time())
			data = saltGMA(data, salt)
			for name, hashed in pairs(pendingNames) do
				if hashed ~= "" then pendingNames[name] = saltName(hashed, salt) end
			end
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
			retargetMaterials()
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

		local entry = { names = {}, resolved = {} }
		for _, key in ipairs({ "$pixshader", "$vertexshader" }) do
			local shaderName = key_values[key]
			if isstring(shaderName) and shaderName ~= "" then
				entry.names[key] = shaderName
				entry.resolved[key] = resolveShaderName(shaderName)
				key_values[key] = entry.resolved[key]
			end
		end

		local shaders = tostring(key_values["$pixshader"]) .. tostring(key_values["$vertexshader"])
		local mat = CreateMaterial(name .. "_" .. util.CRC(shaders), shader or "screenspace_general", key_values)
		materials[mat] = entry

		return mat
	end

	local internalHookIndex = 0
	function WaitForShaderMounted(shaderNames, callback)
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
