local json = require("json")

local map_loader = {}

function map_loader.load(path)
    local contents = love.filesystem.read(path)
    assert(contents, "Could not read map file: " .. path)

    local data = json.decode(contents)
    assert(data, "Could not decode JSON from: " .. path)

    local map = {
        tileSize = data.tileSize,
        width    = data.mapWidth,
        height   = data.mapHeight,
        layers   = {}
    }

    -- For each layer, build a grid: grid[y][x] = tileId (0-based)
    for _, layer in ipairs(data.layers) do
        local grid = {}

        -- initialize rows
        for y = 0, data.mapHeight - 1 do
            grid[y] = {}
        end

        -- fill tiles
        for _, t in ipairs(layer.tiles) do
            local x = t.x
            local y = t.y
            local id = tonumber(t.id)   -- "0" -> 0 etc.
            grid[y][x] = id
        end

        table.insert(map.layers, {
            name = layer.name,
            grid = grid
        })
    end

    return map
end

return map_loader
