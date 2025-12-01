local tiles = {}

function tiles.load()
    tiles.size  = 16                      -- tileSize from map.json
    tiles.image = love.graphics.newImage("assets/tiles/SwampTiles.png")
    tiles.quads = {}

    local iw, ih = tiles.image:getWidth(), tiles.image:getHeight()
    local id = 0                          -- 0-based to match map.json ids

    for y = 0, ih - tiles.size, tiles.size do
        for x = 0, iw - tiles.size, tiles.size do
            tiles.quads[id] = love.graphics.newQuad(
                x, y, tiles.size, tiles.size, iw, ih
            )
            id = id + 1
        end
    end
end

return tiles
