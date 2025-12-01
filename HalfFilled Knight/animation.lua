-- animation.lua
local Animation = {}
Animation.__index = Animation

-- firstFrame / lastFrame are optional (1-based indices)
-- loop is optional, defaults to true
function Animation.new(image, frameTime, scale, firstFrame, lastFrame, loop)
    local self = setmetatable({}, Animation)

    self.image = image
    self.frameTime = frameTime or 0.08
    self.currentTime = 0
    self.currentFrame = 1

    self.frameHeight = image:getHeight()
    self.frameWidth  = self.frameHeight
    local imageWidth = image:getWidth()
    local totalFrames = imageWidth / self.frameWidth

    self.scale = scale or 1

    firstFrame = firstFrame or 1
    lastFrame  = lastFrame or totalFrames
    if firstFrame < 1 then firstFrame = 1 end
    if lastFrame > totalFrames then lastFrame = totalFrames end

    self.firstFrame = firstFrame
    self.lastFrame  = lastFrame
    self.frameCount = lastFrame - firstFrame + 1

    self.quads = {}
    local idx = 1
    for i = firstFrame - 1, lastFrame - 1 do
        self.quads[idx] = love.graphics.newQuad(
            i * self.frameWidth, 0,
            self.frameWidth, self.frameHeight,
            imageWidth, self.frameHeight
        )
        idx = idx + 1
    end

    -- looping flag (true by default)
    if loop == nil then
        loop = true
    end
    self.loop = loop

    return self
end

function Animation:update(dt)
    self.currentTime = self.currentTime + dt
    while self.currentTime >= self.frameTime do
        self.currentTime = self.currentTime - self.frameTime
        self.currentFrame = self.currentFrame + 1
        if self.currentFrame > self.frameCount then
            if self.loop then
                -- loop back to first frame
                self.currentFrame = 1
            else
                -- stay on last frame (one-shot animation)
                self.currentFrame = self.frameCount
            end
        end
    end
end

function Animation:reset()
    self.currentFrame = 1
    self.currentTime = 0
end

-- expose current frame index
function Animation:getFrame()
    return self.currentFrame
end

-- x, y are the PLAYER'S FEET CENTER in world space
-- x, y are the PLAYER'S FEET CENTER in world space
function Animation:draw(x, y, facing)
    facing = facing or 1
    local quad = self.quads[self.currentFrame]

    local sx = self.scale * facing
    local sy = self.scale

    -- Frames are 42 px wide; the body center is about 5 px LEFT of the frame center.
    -- So instead of frameWidth/2, we subtract 5.
    local pivotX = self.frameWidth / 2 - 5

    -- pivot at (body center, feet)
    local ox = pivotX
    local oy = self.frameHeight

    love.graphics.draw(self.image, quad, x, y, 0, sx, sy, ox, oy)
end

return Animation
