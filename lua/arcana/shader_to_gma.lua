local function log(...)
	MsgC(Color(0, 200, 255), "[ShaderToGMA] ", color_white, table.concat({ ... }, " "), "\n")
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
		if not istable(files) or #files == 0 then
			return false, "no files"
		end

		-- Prepare entries
		local entries = {}
		local fileDatas = {}
		for i = 1, #files do
			local p = lowerFixPath(files[i])
			local data = readGameFile(p)
			if not data then
				return false, "missing GAME file: " .. p
			end
			local crc = crc32_num(data)
			entries[#entries + 1] = { id = i, path = p, size = #data, crc = crc }
			fileDatas[#fileDatas + 1] = data
		end

		-- Build header + directory + data in memory
		local chunks = {}
		-- Header
		chunks[#chunks + 1] = "GMAD"                 -- magic
		chunks[#chunks + 1] = u8(3)                  -- version 3
		chunks[#chunks + 1] = u64le(0, 0)            -- steamid (unused)
		local t = os.time() or 0
		chunks[#chunks + 1] = u64le(t, 0)            -- timestamp
		chunks[#chunks + 1] = u8(0)                  -- unused
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

	function ShaderToGMA(shaderNames)
		if not istable(shaderNames) or #shaderNames == 0 then
			error("No shader names provided")
		end

		local files = {}
		for _, shaderName in ipairs(shaderNames) do
			local path = "shaders/fxc/" .. shaderName .. ".vcs"
			if not file.Exists(path, "GAME") then
				log("Missing shader file:", path)
				continue
			end

			table.insert(files, path)
		end

		local ok, res = createGMA(files, { title = "shader_to_gma" })
		if ok then
			log("OK:")
			PrintTable(files)

			local base64 = util.Base64Encode(res)
			net.Start("shader_to_gma")
			net.WriteString(base64)
			net.Broadcast()
		else
			log("Failed:", res or "unknown error")
		end
	end
end

if CLIENT then
	net.Receive("shader_to_gma", function()
		local base64 = net.ReadString()
		local data = util.Base64Decode(base64)
		local fileName = "shader_to_gma_" .. os.time() .. ".gma"

		file.Write(fileName, data)

		local ok, err = game.MountGMA("data/" .. fileName)
		if not ok then
			log("Failed to mount GMA:", err)
		else
			log("Mounted GMA")
			PrintTable(err)
		end

		file.Delete(fileName)
	end)
end