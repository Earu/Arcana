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

	-- Binary packing helpers (little-endian)
	local function u8(n)
		return string.char(bit.band(n or 0, 0xFF))
	end

	local function u32le(n)
		n = math.floor(tonumber(n) or 0)
		n = n % 4294967296 -- 2^32
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

	local function readGameFile(path)
		local f = file.Open(path, "rb", "MOD")
		if not f then return nil end
		local data = f:Read(f:Size())
		f:Close()

		return data
	end

	local function crc32_num(data)
		local s = util.CRC(data or "") -- returns decimal string
		local n = tonumber(s) or 0

		return n % 4294967296
	end

	-- Pure GLua GMA writer (GMAD v3 style)
	-- files: array of GAME-relative paths e.g. { "materials/my/tex.vmt", "materials/my/tex.vtf" }
	local function createGMA(files, meta)
		meta = meta or {}
		if not istable(files) or #files == 0 then return false, "no files" end
		-- Prepare entries
		local entries = {}
		local fileDatas = {}

		for i = 1, #files do
			local p = lowerFixPath(files[i])
			local data = readGameFile(p)
			if not data then return false, "missing GAME file: " .. p end
			local crc = crc32_num(data)

			entries[#entries + 1] = {
				id = i,
				path = p,
				size = #data,
				crc = crc
			}

			fileDatas[#fileDatas + 1] = data
		end

		-- Build header + directory + data in memory
		local chunks = {}
		-- Header
		chunks[#chunks + 1] = "GMAD" -- magic
		chunks[#chunks + 1] = u8(3) -- version 3
		chunks[#chunks + 1] = u64le(0, 0) -- steamid (unused)
		local t = os.time() or 0
		chunks[#chunks + 1] = u64le(t, 0) -- timestamp
		chunks[#chunks + 1] = u8(0) -- unused
		chunks[#chunks + 1] = cstr(meta.title or "shader_to_gma")
		chunks[#chunks + 1] = cstr(meta.description or "")
		chunks[#chunks + 1] = cstr(meta.author or "")
		chunks[#chunks + 1] = u32le(tonumber(meta.addon_version) or 1)

		-- Directory entries
		for _, e in ipairs(entries) do
			chunks[#chunks + 1] = u32le(e.id)
			chunks[#chunks + 1] = cstr(e.path)
			chunks[#chunks + 1] = u64le(e.size, 0)
			chunks[#chunks + 1] = u32le(e.crc)
		end

		-- End of directory
		chunks[#chunks + 1] = u32le(0)

		-- File data (in the same order)
		for _, data in ipairs(fileDatas) do
			chunks[#chunks + 1] = data
		end

		-- Final CRC32 of everything so far
		local pre = table.concat(chunks)
		local finalCrc = crc32_num(pre)
		chunks[#chunks + 1] = u32le(finalCrc)
		local blob = table.concat(chunks)

		return true, blob
	end

	util.AddNetworkString("shader_to_gma")
	local shaderFiles = {}
	local gmaData

	function resource.AddShader(shaderName)
		local path = "shaders/fxc/" .. shaderName .. ".vcs"

		if not file.Exists(path, "MOD") then
			error("Missing shader file: " .. path)
		end

		shaderFiles[shaderName] = path

		-- clean up possible broken shader references
		for existingShaderName, existingShaderPath in pairs(shaderFiles) do
			if existingShaderName == shaderName then continue end

			if not file.Exists(existingShaderPath, "MOD") then
				shaderFiles[existingShaderName] = nil
			end
		end

		local ok, res = createGMA(table.ClearKeys(shaderFiles), {
			title = "shader_to_gma"
		})

		if ok then
			gmaData = res
		end
	end

	local justSpawned = {}

	hook.Add("PlayerInitialSpawn", "shader_to_gma", function(ply)
		justSpawned[ply] = true
	end)

	local function sendGMA(ply)
		if gmaData then
			local base64 = util.Base64Encode(gmaData)
			net.Start("shader_to_gma")
			net.WriteString(base64)
			net.Send(ply)
		else
			log("Failed:", res or "unknown error")
		end
	end

	hook.Add("SetupMove", "shader_to_gma", function(ply, _, ucmd)
		if justSpawned[ply] and not ucmd:IsForced() then
			justSpawned[ply] = nil
			sendGMA(ply)
		end
	end)
end

if CLIENT then
	local materials_to_fix = {}
	net.Receive("shader_to_gma", function()
		local base64 = net.ReadString()
		local data = util.Base64Decode(base64)

		-- clear old gma files
		local files = file.Find("data/shader_to_gma_*.gma", "MOD")
		for _, f in ipairs(files) do
			file.Delete(f)
		end

		-- create new gma file
		local fileName = "shader_to_gma_" .. os.time() .. ".gma"
		file.Write(fileName, data)

		local ok, files_or_err = game.MountGMA("data/" .. fileName)
		if not ok then
			log("Failed to mount GMA:", files_or_err)
		else
			log("Mounted GMA")
			PrintTable(files_or_err)

			for _, path in ipairs(files_or_err) do
				local shader = path:match("shaders%/fxc%/(.*)%.vcs")
				if shader then
					local pixel_key = "pixel__" .. shader
					local pixel_mat = materials_to_fix[pixel_key]
					if pixel_mat then
						pixel_mat:SetString("$pixshader", shader)
						pixel_mat:Recompute()
						materials_to_fix[pixel_key] = nil
						continue
					end

					local vertex_key = "vertex__" .. shader
					local vertex_mat = materials_to_fix[vertex_key]
					if vertex_mat then
						vertex_mat:SetString("$vertexshader", shader)
						vertex_mat:Recompute()
						materials_to_fix[vertex_key] = nil
					end
				end
			end
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

	function CreateShaderMaterial(name, opts)
		local key_values = util.KeyValuesToTable(shader_mat, false, true)

		local ignored_shaders = {}
		if opts then
			for k, v in pairs(opts) do
				key_values[k] = v
			end

			-- remove $pixshader and $vertexshader if they're not mounted yet to avoid weird things happening
			local pixshader = opts["$pixshader"]
			if pixshader and not file.Exists("shaders/fxc/" .. pixshader .. ".vcs", "GAME") then
				ignored_shaders = { pixel = pixshader }
				opts["$pixshader"] = nil
			end

			local vertexshader = opts["$vertexshader"]
			if vertexshader and not file.Exists("shaders/fxc/" .. vertexshader .. ".vcs", "GAME") then
				ignored_shaders = { vertex = vertexshader }
				opts["$vertexshader"] = nil
			end
		end

		local mat = CreateMaterial(name .. "_" .. FrameNumber(), "screenspace_general", key_values)
		if ignored_shaders.pixel then
			materials_to_fix["pixel__" .. ignored_shaders.pixel] = mat
		end

		if ignored_shaders.vertex then
			materials_to_fix["vertex__" .. ignored_shaders.vertex] = mat
		end

		return mat
	end
end