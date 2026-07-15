--- Lua/LuaJIT FFI wrapper around image_resize.dll.
---
--- This mirrors the C ABI documented in DESIGN.md. It is a reference
--- integration, structured the same way as the prior `ffi_merge_kf` project
--- (`mwse\mods\animations\ffi_merge_kf.lua`): a single module placed at
--- `Data Files\MWSE\mods\image_resize\` alongside the built DLL.
---
--- Deployment note: copy the built `image_resize.dll`
--- (target\i686-pc-windows-msvc\release\image_resize.dll) next to this file
--- in the live MWSE install before use.
---
--- Unverified assumptions (see HANDOFF.md "Validation Still Needed"): the
--- `NiPixelData` cast layout, the correct `flip_y` value for this build, and
--- whether `pixels + offsets[0]` is right for mip level 0. Validate all three
--- in-game with `image_resize_write_png_bgra8` before relying on the async
--- path.

local ffi = require("ffi")

-- Reload guard: shutdown previous queue if module is reloaded
if package.loaded["image_resize.image_resize"] then
    pcall(package.loaded["image_resize.image_resize"].shutdown)
end

ffi.cdef([[
typedef struct {
    void* vtable;
    int32_t refCount;
    uint32_t format;
    uint32_t channelMasks[4];
    uint32_t bitsPerPixel;
    uint32_t compareBits[2];
    void* palette;
    uint8_t* pixels;
    uint32_t* widths;
    uint32_t* heights;
    uint32_t* offsets;
    uint32_t mipMapLevels;
    uint32_t bytesPerPixel;
    uint32_t revisionID;
} NiPixelData;

typedef struct {
    uint64_t job_id;
    int32_t status;
    int32_t error_code;
} ImageResizeJobResult;

uint32_t image_resize_api_version(void);
int32_t image_resize_init(uint32_t worker_count, uint32_t max_queue);
int32_t image_resize_shutdown(void);

int32_t image_resize_submit_rgba8(
    const uint8_t* pixels,
    uint32_t width,
    uint32_t height,
    uint32_t stride,
    uint32_t dst_width,
    uint32_t dst_height,
    uint32_t flip_y,
    uint32_t png_compression,
    const char* output_path,
    uint64_t* out_job_id
);

int32_t image_resize_poll_completed(ImageResizeJobResult* out_result);

int32_t image_resize_write_rgba8(
    const uint8_t* pixels,
    uint32_t width,
    uint32_t height,
    uint32_t stride,
    uint32_t dst_width,
    uint32_t dst_height,
    uint32_t flip_y,
    uint32_t png_compression,
    const char* output_path
);
]])

local EXPECTED_API_VERSION = 2
local DEFAULT_DLL_PATH = "data files\\mwse\\mods\\image_resize\\image_resize.dll"

--- Numeric error/status codes, mirrored from DESIGN.md "Error Codes".
local ERROR_MESSAGES = {
    [0] = "OK",
    [1] = "no completed job available",
    [-1] = "not initialized",
    [-2] = "already initialized",
    [-3] = "null pointer",
    [-4] = "invalid dimensions",
    [-5] = "invalid stride",
    [-6] = "invalid output path",
    [-7] = "invalid compression mode",
    [-8] = "queue full",
    [-9] = "resize failed",
    [-10] = "image encode or write failed",
    [-11] = "internal worker error",
    [-12] = "unsupported output format (expected .png, .tga, or .dds)",
}

local M = {}
M.ERROR_MESSAGES = ERROR_MESSAGES
M.PNG_COMPRESSION_FAST = 0
M.PNG_COMPRESSION_BALANCED = 1
M.PNG_COMPRESSION_BEST = 2

local lib = nil
local initialized = false

function M.errorMessage(code)
    return ERROR_MESSAGES[code] or ("unknown image_resize error code " .. tostring(code))
end


--- Loads the DLL and checks its ABI version. Safe to call more than once;
--- subsequent calls return the already-loaded library.
--- @param dllPath string|nil Overrides the default MWSE mod install path.
function M.load(dllPath)
    if lib then
        return lib
    end
    lib = ffi.load(dllPath or DEFAULT_DLL_PATH)
    local version = lib.image_resize_api_version()
    if version ~= EXPECTED_API_VERSION then
        lib = nil
        error(string.format(
            "image_resize.dll API version mismatch: expected %d, got %d",
            EXPECTED_API_VERSION, version
        ))
    end
    return lib
end


--- Starts the async worker pool.
--- @param workerCount number|nil 0 (or nil) means auto.
--- @param maxQueue number Max submitted-but-not-completed jobs. Should
---   usually match or stay below the size of your pixel pool.
function M.init(workerCount, maxQueue)
    assert(lib, "call image_resize.load() first")
    assert(not initialized, "image_resize already initialized")
    local rc = lib.image_resize_init(workerCount or 0, maxQueue)
    if rc ~= 0 and rc ~= -2 then
        error("image_resize_init failed: " .. M.errorMessage(rc))
    end
    initialized = true
end


--- Drains in-flight work and joins worker threads. After this returns it is
--- safe to release/reuse all pool slots that were marked busy.
function M.shutdown()
    assert(lib, "call image_resize.load() first")
    local rc = lib.image_resize_shutdown()
    if rc ~= 0 then
        error("image_resize_shutdown failed: " .. M.errorMessage(rc))
    end
    initialized = false
end


--- Casts an MWSE `niPixelData` userdata into the native `NiPixelData` layout
--- and fails fast if the readback format isn't native BGRA8, matching the
--- validation DESIGN.md calls for before submitting a slot.
--- @param pixelDataObject niPixelData
function M.castPixelData(pixelDataObject)
    ---@diagnostic disable-next-line: undefined-field
    local address = mwse.memory.addressOf(pixelDataObject)
    local pixelData = ffi.cast("NiPixelData*", address)[0]
    assert(pixelData.bitsPerPixel == 32,
        "expected 32 bits per pixel, got " .. tostring(pixelData.bitsPerPixel))
    assert(pixelData.bytesPerPixel == 4,
        "expected 4 bytes per pixel, got " .. tostring(pixelData.bytesPerPixel))
    return pixelData
end


--- Synchronous resize/write, run on the calling thread. The output format is
--- selected from `outputPath`: `.png`, `.tga`, or `.dds`. TGA and DDS are
--- always uncompressed and contain no mipmaps; `pngCompression` is ignored for
--- those formats.
function M.writeSync(pixelDataObject, width, height, dstWidth, dstHeight, flipY, outputPath, pngCompression)
    assert(lib, "call image_resize.load() first")
    local pixelData = M.castPixelData(pixelDataObject)
    local stride = width * pixelData.bytesPerPixel
    local pixelsPtr = pixelData.pixels + pixelData.offsets[0]

    local rc = lib.image_resize_write_rgba8(
        pixelsPtr, width, height, stride,
        dstWidth, dstHeight,
        flipY and 1 or 0, pngCompression or M.PNG_COMPRESSION_BALANCED,
        outputPath
    )
    if rc ~= 0 then
        error("image_resize_write_rgba8 failed: " .. M.errorMessage(rc))
    end
end


--- Fixed-size pool of `niPixelData` slots, following DESIGN.md's ownership
--- model: Lua holds strong references and tracks busy/free state; Rust only
--- borrows the raw pointer while a job is in flight and never
--- retains/frees/mutates it. Reuse a slot only after `pollCompleted` reports
--- its job done.
local Pool = {}
Pool.__index = Pool
M.Pool = Pool

--- @param size number Number of pool slots (should be >= max_queue passed to M.init).
--- @param resolution number Width/height of each pooled niPixelData.
function M.newPool(size, resolution)
    local self = setmetatable({}, Pool)
    self.slots = {}
    self.busy = {}
    self.jobToSlot = {}
    for i = 1, size do
        self.slots[i] = niPixelData.new(resolution, resolution)
        self.busy[i] = false
    end
    return self
end


--- Returns the index and object of a free slot, or nil if all slots are busy.
function Pool:acquire()
    for i, busy in ipairs(self.busy) do
        if not busy then
            return i, self.slots[i]
        end
    end
    return nil
end


--- Submits a slot's pixels for async resize+write and marks it busy. The
--- extension of `outputPath` selects PNG, uncompressed TGA, or uncompressed
--- legacy-header DDS. Caller is responsible for having rendered/read back
--- into the slot first.
--- @return number|nil jobId, number|nil errorCode
function Pool:submit(slotIndex, width, height, dstWidth, dstHeight, flipY, pngCompression, outputPath)
    assert(lib, "call image_resize.load() first")
    local pixelData = M.castPixelData(self.slots[slotIndex])
    local stride = width * pixelData.bytesPerPixel
    local pixelsPtr = pixelData.pixels + pixelData.offsets[0]

    local jobId = ffi.new("uint64_t[1]")
    local rc = lib.image_resize_submit_rgba8(
        pixelsPtr, width, height, stride,
        dstWidth, dstHeight,
        flipY and 1 or 0, pngCompression or M.PNG_COMPRESSION_BALANCED,
        outputPath, jobId
    )
    if rc ~= 0 then
        return nil, rc
    end

    self.busy[slotIndex] = true
    self.jobToSlot[tostring(jobId[0])] = slotIndex
    return jobId[0]
end


--- Polls one completed job, if any, and frees its pool slot for reuse.
--- @return table|nil result `{ job_id, status, error_code }`, or nil if none are ready.
function Pool:pollCompleted()
    assert(lib, "call image_resize.load() first")
    local result = ffi.new("ImageResizeJobResult")
    local rc = lib.image_resize_poll_completed(result)
    if rc == 1 then
        return nil -- no completed job available yet
    elseif rc ~= 0 then
        error("image_resize_poll_completed failed: " .. M.errorMessage(rc))
    end

    ---@diagnostic disable-next-line: undefined-field
    local key = tostring(result.job_id)
    local slotIndex = self.jobToSlot[key]
    if slotIndex then
        self.busy[slotIndex] = false
        self.jobToSlot[key] = nil
    end

    ---@diagnostic disable-next-line: undefined-field
    return { job_id = result.job_id, status = result.status, error_code = result.error_code }
end


return M
