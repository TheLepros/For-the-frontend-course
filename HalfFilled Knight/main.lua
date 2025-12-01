local Animation = require("animation")
local tiles = require("tiles")
local map_loader = require("map_loader")

-------------------------------------------------
-- CONFIG – movement / combat tuning
-------------------------------------------------
local CONFIG = {
    runSpeed = 300, -- horizontal speed
    jumpSpeed = 400, -- jump height
    gravity = 1100, -- affects jump height
    playerDamage = 20, -- single damage value
    playerMaxHP = 100 -- maximum HP
}

-------------------------------------------------
-- ATTACK DATA – active animation frames
-------------------------------------------------
local attackData = {
    attack = {
        activeStart = 1,
        activeEnd   = 2
    },
    runAttack = {
        activeStart = 1,
        activeEnd   = 2
    },
    jumpAttack = {
        activeStart = 1,
        activeEnd   = 2
    }
}

-------------------------------------------------
-- WORLD / PLAYER BASE SETUP
-------------------------------------------------
local SCALE = 2

local worldWidth = 4000
local worldHeight = 600

local player = {}

local camera = {
    x = 0,
    y = 0
}

local gravity = CONFIG.gravity

-- map data (from map.json)
local worldMap = nil

-- world-space tile size (pixels on screen)
local tileSizeWorld = 32 -- will be set from map (pixel size of one tile on screen)

-- collision padding (pixels) for tile checks
local COLLIDE_PAD_X = 6 -- inset left/right
local COLLIDE_PAD_Y = 2 -- inset top/bottom

-- IDs of tiles that are water / deadly
local WATER_TILES = {
    [27] = true,
    [34] = true,
    [37] = true,
    [38] = true,
    [42] = true,
    [44] = true,
    [46] = true
}

-- list of enemies (for now only skeletons)
local enemies = {}

-- unique ID for each player attack, so enemies don't take damage every frame
local attackSerial = 0

-- knockback strengths
local PLAYER_KNOCKBACK_X = 420
local PLAYER_KNOCKBACK_Y = 260
local ENEMY_KNOCKBACK_X = 360
local ENEMY_KNOCKBACK_Y = 200

-- invincibility duration after any hit
local PLAYER_INVINCIBLE_TIME = 1.0

-- sound effects
local swingSound
local hitSound

-------------------------------------------------
-- GENERIC HELPERS
-------------------------------------------------
-- simple AABB overlap
local function rectsOverlap(x1, y1, w1, h1, x2, y2, w2, h2)
    return x1 < x2 + w2 and x2 < x1 + w1 and y1 < y2 + h2 and y2 < y1 + h1
end

-- enemy hitbox in world coordinates
local function getEnemyHitbox(e)
    local x = e.x + (e.hitOffsetX or 0)
    local y = e.y + (e.hitOffsetY or 0)
    return x, y, e.hitW, e.hitH
end

-- skeleton attack hitbox (front of skeleton)
local function computeSkeletonAttackHitbox(e)
    local w = e.w * 0.6
    local h = e.h * 0.65
    local offsetX = e.w * 0.10

    local x
    if e.facing == 1 then
        x = e.x + e.w * 0.5 + offsetX
    else
        x = e.x + e.w * 0.5 - offsetX - w
    end

    local feetY = e.y + e.h
    local feetOffset = 0.05
    local y = feetY - h + e.h * feetOffset

    return x, y, w, h
end

-- change player action + start action timer
local function startAction(state, duration)
    player.action = state
    player.actionTimer = duration or 0.45
    player.anim[state]:reset()
end

-- compute hitbox for a player attack based on position + facing
local function computeAttackHitbox(state)
    local data = attackData[state]
    if not data then
        return nil
    end

    local w = player.w * 0.8
    local h = player.h * 0.7
    local offsetX = player.w * 0.1
    local feetOffset = 0.05

    local baseX = player.x
    local baseY = player.y
    local facing = player.facing

    if state == "attack" or state == "runAttack" or state == "jumpAttack" then
        baseX = player.attackOriginX or player.x
        baseY = player.attackOriginY or player.y
        facing = player.attackFacing or player.facing
    end

    local x
    if facing == 1 then
        x = baseX + player.w * 0.5 + offsetX
    else
        x = baseX + player.w * 0.5 - offsetX - w
    end

    local feetY = baseY + player.h
    local y = feetY - h + player.h * feetOffset

    return {
        x = x,
        y = y,
        w = w,
        h = h
    }
end

-------------------------------------------------
-- TILE / WATER HELPERS
-------------------------------------------------
local function getTile(tx, ty)
    if not worldMap or not worldMap.layers or not worldMap.layers[1] then
        return nil
    end
    local row = worldMap.layers[1].grid[ty]
    if not row then
        return nil
    end
    return row[tx]
end

local function isSolid(tx, ty)
    local id = getTile(tx, ty)
    if not id then
        return false
    end
    -- water tiles are not solid: you can pass through them
    if WATER_TILES[id] then
        return false
    end
    return true
end

-- check if a rectangle overlaps any water tile
local function rectTouchesWater(x, y, w, h)
    if not worldMap then
        return false
    end
    local ts = tileSizeWorld

    local left = math.floor(x / ts)
    local right = math.floor((x + w - 1) / ts)
    local top = math.floor(y / ts)
    local bottom = math.floor((y + h - 1) / ts)

    for ty = top, bottom do
        local row = worldMap.layers[1].grid[ty]
        if row then
            for tx = left, right do
                local id = row[tx]
                if id and WATER_TILES[id] then
                    return true
                end
            end
        end
    end

    return false
end

-- check if the tile one step ahead (at the feet) is water (for enemies)
local function enemyStepWouldEnterWater(e, dir)
    local hbX, hbY, hbW, hbH = getEnemyHitbox(e)
    local ts = tileSizeWorld

    local aheadX
    if dir > 0 then
        aheadX = hbX + hbW + ts * 0.25
    else
        aheadX = hbX - ts * 0.25
    end

    local feetY = hbY + hbH + 1
    local tx = math.floor(aheadX / ts)
    local ty = math.floor(feetY / ts)

    local id = getTile(tx, ty)
    return id and WATER_TILES[id] or false
end

-- check if the next step would make the enemy walk off an edge
local function enemyStepWouldFallOffEdge(e, dir)
    local hbX, hbY, hbW, hbH = getEnemyHitbox(e)
    local ts = tileSizeWorld

    local aheadX
    if dir > 0 then
        aheadX = hbX + hbW + ts * 0.25
    else
        aheadX = hbX - ts * 0.25
    end

    local feetY = hbY + hbH + 1
    local tx = math.floor(aheadX / ts)
    local ty = math.floor(feetY / ts)

    local id = getTile(tx, ty)
    if not id then
        return true
    end
    if not isSolid(tx, ty) then
        return true
    end
    return false
end

-- check if there is a solid wall immediately to the left/right of the enemy
local function enemyHasWallAtSide(e, dir)
    local hbX, hbY, hbW, hbH = getEnemyHitbox(e)
    local ts = tileSizeWorld

    local top = hbY + COLLIDE_PAD_Y
    local bottom = hbY + hbH - COLLIDE_PAD_Y

    local sideX
    if dir > 0 then
        -- check just to the right of the hitbox
        sideX = hbX + hbW + 1
    else
        -- check just to the left of the hitbox
        sideX = hbX - 1
    end

    local tx = math.floor(sideX / ts)
    local ty1 = math.floor(top / ts)
    local ty2 = math.floor(bottom / ts)

    return isSolid(tx, ty1) or isSolid(tx, ty2)
end

-------------------------------------------------
-- PLAYER HITBOX / KNOCKBACK / LIFE
-------------------------------------------------
-- player hitbox in world coordinates
local function getPlayerHitbox()
    local x = player.x + (player.hitOffsetX or 0)
    local y = player.y + (player.hitOffsetY or 0)
    return x, y, player.hitW, player.hitH
end

local function applyPlayerKnockbackFromEnemy(ex, ew, pX, pW)
    local pCenterX = pX + pW / 2
    local eCenterX = ex + ew / 2

    -- if player is to the right of enemy → push right, else left
    local dir = (pCenterX >= eCenterX) and 1 or -1

    player.vx = PLAYER_KNOCKBACK_X * dir
    player.vy = -PLAYER_KNOCKBACK_Y
    player.onGround = false
    player.knockbackTimer = 0.18
end

local function killPlayer()
    if player.action == "death" then
        return
    end
    player.hp = 0
    player.vx = 0
    player.vy = 0
    startAction("death", 1.0)
    player.state = "death"
    player.deathTimer = 1.0
end

-- respawn player at spawn point after death (not currently triggered)
local function respawnPlayer()
    player.x = player.spawnX or player.x
    player.y = player.spawnY or player.y
    player.vx = 0
    player.vy = 0
    player.hp = player.maxHP

    player.onGround = true
    player.action = nil
    player.state = "idle"
    player.deathTimer = 0
    player.jumpsLeft = player.maxJumps

    for _, anim in pairs(player.anim) do
        anim:reset()
    end
end

-------------------------------------------------
-- COLLISION RESOLUTION
-------------------------------------------------
local function resolveHorizontal(x, y, w, h, vx, dt)
    if vx == 0 then
        return x, vx, false
    end

    local ts = tileSizeWorld
    local newX = x + vx * dt
    local hitWall = false

    local top = y + COLLIDE_PAD_Y
    local bottom = y + h - COLLIDE_PAD_Y

    if vx > 0 then
        local right = newX + w - 1
        local tx = math.floor(right / ts)
        local ty1 = math.floor(top / ts)
        local ty2 = math.floor(bottom / ts)

        if isSolid(tx, ty1) or isSolid(tx, ty2) then
            newX = tx * ts - w
            vx = 0
            hitWall = true
        end
    else
        local left = newX + 1
        local tx = math.floor(left / ts)
        local ty1 = math.floor(top / ts)
        local ty2 = math.floor(bottom / ts)

        if isSolid(tx, ty1) or isSolid(tx, ty2) then
            newX = (tx + 1) * ts
            vx = 0
            hitWall = true
        end
    end

    return newX, vx, hitWall
end

local function resolveVertical(x, y, w, h, vy, dt)
    if vy == 0 then
        return y, vy, false
    end

    local ts = tileSizeWorld
    local newY = y + vy * dt
    local onGround = false

    if vy > 0 then
        -- falling: check tiles under the feet
        local bottom = newY + h
        local left = x + COLLIDE_PAD_X
        local right = x + w - COLLIDE_PAD_X

        local tx1 = math.floor(left / ts)
        local tx2 = math.floor(right / ts)
        local ty = math.floor(bottom / ts)

        if isSolid(tx1, ty) or isSolid(tx2, ty) then
            newY = ty * ts - h
            vy = 0
            onGround = true
        end
    else
        -- moving up: check tiles above the head
        local top = newY
        local left = x + COLLIDE_PAD_X
        local right = x + w - COLLIDE_PAD_X

        local tx1 = math.floor(left / ts)
        local tx2 = math.floor(right / ts)
        local ty = math.floor(top / ts)

        if isSolid(tx1, ty) or isSolid(tx2, ty) then
            newY = (ty + 1) * ts
            vy = 0
        end
    end

    return newY, vy, onGround
end

-------------------------------------------------
-- TILE MAP DRAWING
-------------------------------------------------
local function drawMap(map)
    if not map then
        return
    end

    local tileSize = map.tileSize

    for _, layer in ipairs(map.layers) do
        local grid = layer.grid
        for y, row in pairs(grid) do
            for x, id in pairs(row) do
                if id and tiles.quads[id] then
                    love.graphics.draw(tiles.image, tiles.quads[id], x * tileSize * 2, y * tileSize * 2, 0, 2, 2)
                end
            end
        end
    end
end

-------------------------------------------------
-- PLAYER SPAWN
-------------------------------------------------
-- set player spawn so their hitbox stands on top of tile (tx, ty)
local function setSpawnAtTile(tx, ty)
    local groundY = ty * tileSizeWorld

    local hbX = tx * tileSizeWorld + (tileSizeWorld - player.hitW) / 2
    local hbY = groundY - player.hitH

    player.x = hbX - player.hitOffsetX
    player.y = hbY - player.hitOffsetY

    player.spawnX = player.x
    player.spawnY = player.y
end

-------------------------------------------------
-- LOVE.LOAD – resource loading and initialization
-------------------------------------------------
function love.load()
    love.graphics.setDefaultFilter("nearest", "nearest")
    love.graphics.setBackgroundColor(0.1, 0.1, 0.12)

    tiles.load()
    worldMap = map_loader.load("maps/map.json")

    if worldMap then
        tileSizeWorld = worldMap.tileSize * 2 -- 16px tiles drawn at scale 2 = 32px
        worldWidth = worldMap.width * tileSizeWorld
        worldHeight = worldMap.height * tileSizeWorld
    end

    enemies = {}
    attackSerial = 0

    -- player sprites
    local base = "assets/sprites/Player/Sword/"
    local idleImg = love.graphics.newImage(base .. "Idle.png")
    local walkImg = love.graphics.newImage(base .. "Walk.png")
    local runImg = love.graphics.newImage(base .. "Run.png")
    local jumpImg = love.graphics.newImage(base .. "Jump.png")

    local attack2Img = love.graphics.newImage(base .. "Attack2.png")
    local runAtk2Img = love.graphics.newImage(base .. "RunAttack2.png")
    local hurtImg = love.graphics.newImage(base .. "Hurt.png")
    local deathImg = love.graphics.newImage(base .. "Death.png")

    -- player sounds
    swingSound = love.audio.newSource("assets/sounds/Player/sword_swing1.mp3", "static")
    swingSound:setVolume(0.1)
    hitSound = love.audio.newSource("assets/sounds/Player/sword_hit1.mp3", "static")
    hitSound:setVolume(0.2)

    player.anim = {
        idle = Animation.new(idleImg, 0.12, SCALE),
        run = Animation.new(runImg, 0.08, SCALE),
        jump = Animation.new(jumpImg, 0.10, SCALE, 5),
        attack = Animation.new(attack2Img, 0.045, SCALE, nil, nil, false),
        runAttack = Animation.new(runAtk2Img, 0.045, SCALE, nil, nil, false),
        jumpAttack = Animation.new(attack2Img, 0.045, SCALE, nil, nil, false),
        hurt = Animation.new(hurtImg, 0.10, SCALE),
        death = Animation.new(deathImg, 0.15, SCALE)
    }

    player.state = "idle"
    player.facing = 1

    local baseSize = idleImg:getHeight() * SCALE
    player.w = baseSize
    player.h = baseSize

    -------------------------------------------------
    -- PLAYER PHYSICS HITBOX
    -------------------------------------------------
    player.hitW = 32
    player.hitH = 50

    player.hitOffsetX = (player.w - player.hitW) / 2
    player.hitOffsetY = player.h - player.hitH

    setSpawnAtTile(1, 35)

    player.vx = 0
    player.vy = 0

    player.runSpeed = CONFIG.runSpeed
    player.jumpSpeed = CONFIG.jumpSpeed

    player.damage = CONFIG.playerDamage

    player.maxHP = CONFIG.playerMaxHP
    player.hp = CONFIG.playerMaxHP

    player.invincibleTimer = 0

    player.maxJumps = 2
    player.jumpsLeft = player.maxJumps

    player.onGround = true
    player.action = nil
    player.actionTimer = 0
    player.attackCooldown = 0.5
    player.attackCooldownTimer = 0
    player.deathTimer = 0

    player.attackFacing = player.facing
    player.attackOriginX = player.x
    player.attackOriginY = player.y

    player.hitbox = nil
    player.knockbackTimer = 0

    -- per-swing flag: did this attack hit at least one enemy?
    player.didHitEnemyThisSwing = false

    -- per-swing flag: did we already play the air-swing sound?
    player.airSwingPlayed = false

    -- hitbox on the very first frame of the swing
    player.instantAttack = false   

    -------------------------------------------------
    -- SKELETON ENEMY SETUP
    -------------------------------------------------
    local skelBase = "assets/sprites/Skeleton/"
    local skelIdle = love.graphics.newImage(skelBase .. "Idle.png")
    local skelWalk = love.graphics.newImage(skelBase .. "Walk.png")
    local skelRun = love.graphics.newImage(skelBase .. "Run.png")
    local skelJump = love.graphics.newImage(skelBase .. "Jump.png")
    local skelAttack = love.graphics.newImage(skelBase .. "Attack_2.png")
    local skelHurt = love.graphics.newImage(skelBase .. "Hurt.png")
    local skelDead = love.graphics.newImage(skelBase .. "Dead.png")

    local skeletonScale = 1.5 * (idleImg:getHeight() * SCALE) / skelIdle:getHeight()

    local function createSkeleton(tileX, tileY)
        local skeleton = {}

        skeleton.type = "skeleton"

        skeleton.anim = {
            idle = Animation.new(skelIdle, 0.15, skeletonScale),
            walk = Animation.new(skelWalk, 0.12, skeletonScale),
            run = Animation.new(skelRun, 0.08, skeletonScale),
            jump = Animation.new(skelJump, 0.10, skeletonScale),
            attack = Animation.new(skelAttack, 0.08, skeletonScale, nil, nil, false),
            hurt = Animation.new(skelHurt, 0.10, skeletonScale),
            death = Animation.new(skelDead, 0.15, skeletonScale, nil, nil, false)
        }

        skeleton.state = "idle"
        skeleton.facing = 1

        local skelBaseSize = skelIdle:getHeight() * skeletonScale
        skeleton.w = skelBaseSize
        skeleton.h = skelBaseSize

        skeleton.hitW = 32
        skeleton.hitH = 50
        skeleton.hitOffsetX = (skeleton.w - skeleton.hitW) / 2
        skeleton.hitOffsetY = skeleton.h - skeleton.hitH

        local skelGroundY = tileY * tileSizeWorld
        local skelHbX = tileX * tileSizeWorld + (tileSizeWorld - skeleton.hitW) / 2
        local skelHbY = skelGroundY - skeleton.hitH

        skeleton.x = skelHbX - skeleton.hitOffsetX
        skeleton.y = skelHbY - skeleton.hitOffsetY

        skeleton.spawnX = skeleton.x
        skeleton.spawnY = skeleton.y

        skeleton.patrolMinX = skeleton.spawnX - 6 * tileSizeWorld
        skeleton.patrolMaxX = skeleton.spawnX + 6 * tileSizeWorld
        skeleton.patrolDir = 1

        skeleton.vx = 0
        skeleton.vy = 0
        skeleton.onGround = true

        skeleton.maxHP = 60
        skeleton.hp = 60
        skeleton.dead = false

        skeleton.attackCooldown = 0
        skeleton.attackDamage = 15
        skeleton.contactDamage = 8
        skeleton.attackMinTiles = 1.0
        skeleton.attackMaxTiles = 2.5
        skeleton.detectRangeTiles = 6

        skeleton.hasSeenPlayer = false
        skeleton.lockedInAttack = false
        skeleton.attackHitTimer = 0
        skeleton.attackHitActive = false
        skeleton.preAttackTimer = 0
        skeleton.isPreAttacking = false
        skeleton.attackStateTimer = 0
        skeleton.wasHitThisSwingId = nil
        skeleton.hurtTimer = 0
        skeleton.deathTimer = 0

        skeleton.walkSpeed = 80
        skeleton.runSpeed = 140
        skeleton.jumpSpeed = player.jumpSpeed * 1.0

        table.insert(enemies, skeleton)
    end

    -- spawn skeletons
    createSkeleton(20, 35)
    createSkeleton(34, 25)
    createSkeleton(56, 34)
    createSkeleton(65, 10)
    createSkeleton(69, 10)
    createSkeleton(70, 7)
    createSkeleton(22, 10)
    createSkeleton(28, 10)
    createSkeleton(25, 10)
    createSkeleton(25, 5)
    createSkeleton(28, 5)
end

-------------------------------------------------
-- ENEMY UPDATE / AI
-------------------------------------------------
local function updateEnemies(dt)
    for _, e in ipairs(enemies) do
        if e.type == "skeleton" then
            if not e.dead then
                -- cooldown timers
                if e.attackCooldown > 0 then
                    e.attackCooldown = e.attackCooldown - dt
                    if e.attackCooldown < 0 then
                        e.attackCooldown = 0
                    end
                end

                if e.hurtTimer > 0 then
                    e.hurtTimer = e.hurtTimer - dt
                    if e.hurtTimer < 0 then
                        e.hurtTimer = 0
                    end
                end

                -- time-based attack hitbox countdown
                if e.attackHitActive then
                    e.attackHitTimer = e.attackHitTimer - dt
                    if e.attackHitTimer <= 0 then
                        e.attackHitActive = false
                    end
                end

                -- pre-attack delay countdown → start real attack
                if e.isPreAttacking then
                    e.preAttackTimer = e.preAttackTimer - dt
                    if e.preAttackTimer <= 0 then
                        e.isPreAttacking = false

                        e.vx = 0
                        e.state = "attack"
                        e.anim.attack:reset()

                        e.attackCooldown = 1.0
                        e.attackHitTimer = 0.4
                        e.attackHitActive = true
                        e.currentAttackId = (e.currentAttackId or 0) + 1
                        e.alreadyHitThisSwing = false

                        e.lockedInAttack = true
                        e.attackStateTimer = 0.5

                        local hbX, hbY, hbW, hbH = getEnemyHitbox(e)
                        local pX, pY, pW, pH = getPlayerHitbox()
                        local pCenterX = pX + pW / 2
                        local eCenterX = hbX + hbW / 2
                        e.facing = (pCenterX >= eCenterX) and 1 or -1
                    end
                end

                -- gravity
                e.vy = e.vy + gravity * dt

                -- if attack locked, just tick timer
                if e.lockedInAttack then
                    e.vx = 0
                    e.attackStateTimer = e.attackStateTimer - dt
                    if e.attackStateTimer <= 0 then
                        e.lockedInAttack = false
                    end
                else
                    -- AI decision
                    local hbX, hbY, hbW, hbH = getEnemyHitbox(e)
                    local centerX = hbX + hbW / 2

                    local pHbX, pHbY, pHbW, pHbH = getPlayerHitbox()
                    local pCenterX = pHbX + pHbW / 2
                    local pCenterY = pHbY + pHbH / 2
                    local dy = pCenterY - (hbY + hbH / 2)
                    local dx = pCenterX - centerX

                    local distTilesX = math.abs(dx) / tileSizeWorld
                    local distTilesY = math.abs(dy) / tileSizeWorld

                    local targetDir = 0
                    local mode = "patrol"

                    if player.hp > 0 then
                        local minR = e.attackMinTiles or 1.0
                        local maxR = e.attackMaxTiles or 2.5

                        if distTilesX <= e.detectRangeTiles and distTilesY <= 2.5 then
                            e.hasSeenPlayer = true
                        end

                        if e.hasSeenPlayer then
                            if distTilesX >= minR and distTilesX <= maxR and distTilesY <= 1.2 then
                                mode = "attack"
                            else
                                mode = "chase"
                            end
                        end
                    end

                    if mode == "patrol" then
                        targetDir = e.patrolDir
                        e.vx = targetDir * e.walkSpeed

                        if centerX < e.patrolMinX then
                            e.patrolDir = 1
                        elseif centerX > e.patrolMaxX then
                            e.patrolDir = -1
                        end

                        targetDir = e.patrolDir
                        e.vx = targetDir * e.walkSpeed

                        if enemyStepWouldEnterWater(e, targetDir) or enemyStepWouldFallOffEdge(e, targetDir) then
                            e.patrolDir = -targetDir
                            targetDir = e.patrolDir
                            e.vx = targetDir * e.walkSpeed
                        end

                        if math.abs(e.vx) < 1 then
                            e.vx = 0
                            e.state = "idle"
                        else
                            e.state = "walk"
                            e.facing = targetDir
                        end

                    elseif mode == "chase" then
                        local closeHoriz = math.abs(dx) < (e.hitW * 0.3)

                        if closeHoriz then
                            -- player is almost directly above/below → stand still
                            e.vx = 0
                            e.state = "idle"
                        else
                            targetDir = (dx > 0) and 1 or -1

                            -- if there is a wall right next to us in chase direction → idle, don't spam run
                            if enemyHasWallAtSide(e, targetDir) then
                                e.vx = 0
                                e.state = "idle"
                                -- otherwise, chase as usual (avoid water / edges)
                            elseif enemyStepWouldEnterWater(e, targetDir) or enemyStepWouldFallOffEdge(e, targetDir) then
                                e.vx = 0
                                e.state = "idle"
                            else
                                e.vx = targetDir * e.runSpeed
                                e.facing = targetDir
                                e.state = "run"
                            end
                        end

                    elseif mode == "attack" and e.attackCooldown == 0 and not e.isPreAttacking then
                        -- start pre-attack wind-up
                        e.isPreAttacking = true
                        e.preAttackTimer = 0.2
                        e.vx = 0
                        e.state = "idle"
                    end

                    e.aiMode = mode
                end

                -- horizontal / vertical collision
                local hbX, hbY, hbW, hbH = getEnemyHitbox(e)
                hbX, e.vx, e.hitWallX = resolveHorizontal(hbX, hbY, hbW, hbH, e.vx, dt)
                e.x = hbX - e.hitOffsetX

                if not e.lockedInAttack and e.hitWallX and (e.state == "walk" or e.state == "run") then
                    if e.aiMode == "patrol" then
                        local newDir = -(e.patrolDir or e.facing or 1)
                        e.patrolDir = newDir
                        e.facing = newDir

                        if e.state == "run" then
                            e.vx = newDir * e.runSpeed
                        else
                            e.vx = newDir * e.walkSpeed
                        end

                        e.state = "walk"
                    elseif e.aiMode == "chase" then
                        e.vx = 0
                        e.state = "idle"
                    end
                end

                if math.abs(e.vx) < 1 and (e.state == "walk" or e.state == "run") then
                    e.vx = 0
                    e.state = "idle"
                    if e.anim and e.anim.idle then
                        e.anim.idle:reset()
                    end
                end

                hbX, hbY, hbW, hbH = getEnemyHitbox(e)
                hbY, e.vy, e.onGround = resolveVertical(hbX, hbY, hbW, hbH, e.vy, dt)
                e.y = hbY - e.hitOffsetY

                hbX, hbY, hbW, hbH = getEnemyHitbox(e)
                if rectTouchesWater(hbX, hbY, hbW, hbH) then
                    e.hp = 0
                end

                -------------------------------------------------
                -- ENEMY ATTACK → damages player
                -------------------------------------------------
                if e.state == "attack" and player.hp > 0 then
                    e.anim.attack:update(dt)

                    if e.attackHitActive and not e.alreadyHitThisSwing then
                        local ax, ay, aw, ah = computeSkeletonAttackHitbox(e)
                        local pX, pY, pW, pH = getPlayerHitbox()
                        if rectsOverlap(ax, ay, aw, ah, pX, pY, pW, pH) then
                            if player.hp > 0 and player.invincibleTimer <= 0 then
                                local pCenterX = pX + pW / 2
                                local eCenterX = hbX + hbW / 2
                                local dir = (pCenterX >= eCenterX) and 1 or -1

                                player.hp = player.hp - e.attackDamage
                                if player.hp <= 0 then
                                    killPlayer()
                                else
                                    startAction("hurt", 0.4)
                                    player.invincibleTimer = PLAYER_INVINCIBLE_TIME
                                end

                                player.vx = PLAYER_KNOCKBACK_X * dir
                                player.vy = -PLAYER_KNOCKBACK_Y
                            end

                            e.alreadyHitThisSwing = true
                        end
                    end
                else
                    e.anim[e.state]:update(dt)
                end

                -------------------------------------------------
                -- ENEMY DEATH STATE
                -------------------------------------------------
                if e.hp <= 0 and not e.dead then
                    e.dead = true
                    e.state = "death"
                    e.vx = 0
                    e.vy = 0
                    e.anim.death:reset()
                    e.deathTimer = 0.8
                end
            else
                if e.deathTimer and e.deathTimer > 0 then
                    e.deathTimer = e.deathTimer - dt
                    e.anim.death:update(dt)
                end
            end
        end
    end
end

-------------------------------------------------
-- LOVE.UPDATE – player movement / combat / AI
-------------------------------------------------
function love.update(dt)
    -- handle death animation + level restart
    if player.action == "death" then
        if player.deathTimer and player.deathTimer > 0 then
            player.deathTimer = player.deathTimer - dt
            if player.deathTimer <= 0 then
                love.load()
                return
            end
        end

        if player.anim and player.anim.death then
            player.anim.death:update(dt)
        end

        return
    end

    local wasOnGround = player.onGround

    -- knockback timer
    if player.knockbackTimer and player.knockbackTimer > 0 then
        player.knockbackTimer = player.knockbackTimer - dt
        if player.knockbackTimer < 0 then
            player.knockbackTimer = 0
        end
    end

    local left = love.keyboard.isDown("left")
    local right = love.keyboard.isDown("right")

    if player.action == "death" then
        left, right = false, false
    end

    local speed = player.runSpeed

    if not (player.knockbackTimer and player.knockbackTimer > 0) then
        player.vx = 0
        if left then
            player.vx = -speed
            player.facing = -1
        elseif right then
            player.vx = speed
            player.facing = 1
        end
    end

    -- gravity
    player.vy = player.vy + gravity * dt

    -- horizontal vs tiles (using hitbox)
    local hbX, hbY, hbW, hbH = getPlayerHitbox()
    hbX, player.vx = resolveHorizontal(hbX, hbY, hbW, hbH, player.vx, dt)
    player.x = hbX - player.hitOffsetX

    -- vertical vs tiles (using hitbox)
    hbX, hbY, hbW, hbH = getPlayerHitbox()
    hbY, player.vy, player.onGround = resolveVertical(hbX, hbY, hbW, hbH, player.vy, dt)
    player.y = hbY - player.hitOffsetY

    -- auto-consume one jump when walking off edges
    if wasOnGround and not player.onGround and player.vy > 0 then
        if player.jumpsLeft == player.maxJumps then
            player.jumpsLeft = player.maxJumps - 1
        end
    end

    -- world bounds
    if player.x < 0 then
        player.x = 0
    end
    if player.x > worldWidth - player.w then
        player.x = worldWidth - player.w
    end
    if player.y < 0 then
        player.y = 0
    end
    if player.y > worldHeight - player.h then
        player.y = worldHeight - player.h
    end

    -- reset jumps whenever we're on the ground
    if player.onGround then
        player.jumpsLeft = player.maxJumps
    end

    -- deadly water tiles
    hbX, hbY, hbW, hbH = getPlayerHitbox()
    if player.hp > 0 and rectTouchesWater(hbX, hbY, hbW, hbH) then
        killPlayer()
    end

    if player.actionTimer > 0 then
        player.actionTimer = player.actionTimer - dt
        if player.actionTimer <= 0 and player.action ~= "death" then
            player.action = nil
        end
    end

    if player.attackCooldownTimer > 0 then
        player.attackCooldownTimer = player.attackCooldownTimer - dt
        if player.attackCooldownTimer < 0 then
            player.attackCooldownTimer = 0
        end
    end

    if player.invincibleTimer and player.invincibleTimer > 0 then
        player.invincibleTimer = player.invincibleTimer - dt
        if player.invincibleTimer < 0 then
            player.invincibleTimer = 0
        end
    end

    local state
    if player.action then
        state = player.action
    else
        if not player.onGround then
            state = "jump"
        elseif math.abs(player.vx) > 1 then
            state = "run"
        else
            state = "idle"
        end
    end

    if state ~= player.state then
        player.anim[state]:reset()
        player.state = state
    end

    player.anim[player.state]:update(dt)

    -------------------------------------------------
    -- PLAYER ATTACK HITBOX
    -------------------------------------------------
    player.hitbox = nil

    if player.action == "attack" or player.action == "runAttack" or player.action == "jumpAttack" then
        local anim = player.anim[player.action]
        local frame = anim:getFrame()
        local data = attackData[player.action]

        if player.instantAttack then
            -- first frame after pressing X: force hitbox
            player.hitbox = computeAttackHitbox(player.action)
            player.instantAttack = false
        elseif data and frame >= data.activeStart and frame <= data.activeEnd then
            -- normal active frames
            player.hitbox = computeAttackHitbox(player.action)
        end
    end

    -------------------------------------------------
    -- ENEMY UPDATE (movement, AI, damage to player)
    -------------------------------------------------
    updateEnemies(dt)

    -------------------------------------------------
    -- PLAYER ATTACK HITS ENEMIES
    -------------------------------------------------
    if player.hitbox then
        for _, e in ipairs(enemies) do
            if not e.dead then
                local ex, ey, ew, eh = getEnemyHitbox(e)
                if rectsOverlap(player.hitbox.x, player.hitbox.y, player.hitbox.w, player.hitbox.h, ex, ey, ew, eh) then
                    if e.lastHitAttackId ~= player.currentAttackId then
                        -- damage
                        e.hp = e.hp - player.damage
                        e.lastHitAttackId = player.currentAttackId

                        -- mark that this swing actually hit something
                        player.didHitEnemyThisSwing = true

                        -- play HIT sound (always on hit)
                        if hitSound then
                            hitSound:stop()
                            hitSound:play()
                        end

                        if e.hp > 0 then
                            local pX, pY, pW, pH = getPlayerHitbox()
                            local pCenterX = pX + pW / 2
                            local eCenterX = ex + ew / 2
                            local dir = (eCenterX >= pCenterX) and 1 or -1

                            e.vx = ENEMY_KNOCKBACK_X * dir
                            e.vy = -ENEMY_KNOCKBACK_Y

                            player.vx = player.vx - PLAYER_KNOCKBACK_X * dir * 0.2

                            if not e.lockedInAttack and e.state ~= "attack" then
                                e.state = "hurt"
                                e.hurtTimer = 0.15
                                e.anim.hurt:reset()
                            end
                        end
                    end
                end
            end
        end
    end

    -------------------------------------------------
    -- SWING SOUND – plays when attack becomes active
    -------------------------------------------------
    if (player.action == "attack" or player.action == "runAttack" or player.action == "jumpAttack")
    and not player.airSwingPlayed then

        local anim = player.anim[player.action]
        local data = attackData[player.action]
        if anim and data then
            local frame = anim:getFrame()

            -- as soon as we ENTER the active frames (hit or miss)
            if frame >= data.activeStart then
                if swingSound then
                    swingSound:stop()
                    swingSound:play()
                end
                player.airSwingPlayed = true
            end
        end
    end

    -------------------------------------------------
    -- CONTACT DAMAGE (touching enemy hurts player)
    -------------------------------------------------
    do
        local pX, pY, pW, pH = getPlayerHitbox()
        if player.hp > 0 and player.invincibleTimer <= 0 then
            for _, e in ipairs(enemies) do
                if not e.dead then
                    local ex, ey, ew, eh = getEnemyHitbox(e)
                    if rectsOverlap(pX, pY, pW, pH, ex, ey, ew, eh) then
                        local dmg = e.contactDamage or math.floor((e.attackDamage or 10) * 0.6)
                        player.hp = player.hp - dmg
                        if player.hp <= 0 then
                            killPlayer()
                        else
                            startAction("hurt", 0.35)
                            player.invincibleTimer = PLAYER_INVINCIBLE_TIME
                        end

                        applyPlayerKnockbackFromEnemy(ex, ew, pX, pW)

                        local pCenterX = pX + pW / 2
                        local eCenterX = ex + ew / 2
                        local dir = (pCenterX >= eCenterX) and 1 or -1

                        e.vx = -ENEMY_KNOCKBACK_X * dir * 0.5
                        e.vy = -ENEMY_KNOCKBACK_Y * 0.3

                        break
                    end
                end
            end
        end
    end

    -------------------------------------------------
    -- CAMERA FOLLOW
    -------------------------------------------------
    local sw, sh = love.graphics.getWidth(), love.graphics.getHeight()
    camera.x = player.x + player.w / 2 - sw / 2
    camera.y = player.y + player.h / 2 - sh / 2

    if camera.x < 0 then
        camera.x = 0
    end
    if camera.y < 0 then
        camera.y = 0
    end
    if camera.x > worldWidth - sw then
        camera.x = worldWidth - sw
    end
    if camera.y > worldHeight - sh then
        camera.y = worldHeight - sh
    end
end

-------------------------------------------------
-- INPUT HANDLING
-------------------------------------------------
function love.keypressed(key)
    if player.action == "death" then
        return
    end

    -- jump / double jump: Z
    if key == "z" and player.jumpsLeft and player.jumpsLeft > 0 then
        player.vy = -player.jumpSpeed
        player.onGround = false
        player.jumpsLeft = player.jumpsLeft - 1
    end

    -- sword attacks
    if key == "x" and player.attackCooldownTimer == 0 then
        attackSerial = attackSerial + 1
        player.currentAttackId = attackSerial

        local movingFast = math.abs(player.vx) > player.runSpeed * 0.3

        player.attackFacing  = player.facing
        player.attackOriginX = player.x
        player.attackOriginY = player.y

        -- reset hit / air-swing flags for this swing
        player.didHitEnemyThisSwing = false
        player.airSwingPlayed      = false

        if not player.onGround then
            startAction("jumpAttack", 0.4)
        elseif movingFast then
            startAction("runAttack", 0.4)
        else
            startAction("attack", 0.4)
        end

        player.attackCooldownTimer = player.attackCooldown

        -- NEW: create hitbox immediately on swing start
        player.instantAttack = true
    end
end

-------------------------------------------------
-- ENEMY DRAW
-------------------------------------------------
local function drawEnemies()
    for _, e in ipairs(enemies) do
        if e.dead and e.deathTimer and e.deathTimer <= 0 then
            -- corpse finished: do not draw
        elseif e.anim and e.anim[e.state] then
            local ex, ey, ew, eh = getEnemyHitbox(e)
            local cx = ex + ew / 2
            local cy = ey + eh

            love.graphics.setColor(1, 1, 1, 1)
            e.anim[e.state]:draw(math.floor(cx + 0.5), math.floor(cy + 0.5), e.facing or 1)

            -- DEBUG: enemy collision hitbox (yellow)
            love.graphics.setColor(1, 1, 0, 0.6)
            love.graphics.rectangle("line", math.floor(ex), math.floor(ey), ew, eh)
            love.graphics.setColor(1, 1, 1, 1)

            -- DEBUG: skeleton attack hitbox (red) while active
            if e.state == "attack" and e.attackHitActive then
                local ax, ay, aw, ah = computeSkeletonAttackHitbox(e)
                love.graphics.setColor(1, 0, 0, 0.6)
                love.graphics.rectangle("line", math.floor(ax), math.floor(ay), aw, ah)
                love.graphics.setColor(1, 1, 1, 1)
            end
        end
    end
end

-------------------------------------------------
-- LOVE.DRAW – world, player, debug, UI
-------------------------------------------------
function love.draw()
    love.graphics.push()
    love.graphics.translate(-math.floor(camera.x), -math.floor(camera.y))

    -- map
    love.graphics.setColor(1, 1, 1, 1)
    drawMap(worldMap)

    -- enemies
    drawEnemies()

    -- player sprite (anchored at hitbox feet center)
    local hbX, hbY, hbW, hbH = getPlayerHitbox()
    local cx = hbX + hbW / 2
    local cy = hbY + hbH

    local animToDraw = player.anim[player.state]
    if player.action == "death" and player.anim.death then
        animToDraw = player.anim.death
    end
    animToDraw:draw(math.floor(cx + 0.5), math.floor(cy + 0.5), player.facing)

    -- DEBUG: player attack hitbox (red)
    if player.hitbox then
        love.graphics.setColor(1, 0, 0, 0.5)
        love.graphics.rectangle("line", player.hitbox.x, player.hitbox.y, player.hitbox.w, player.hitbox.h)
        love.graphics.setColor(1, 1, 1, 1)
    end

    -- DEBUG: player collision box (green)
    hbX, hbY, hbW, hbH = getPlayerHitbox()
    love.graphics.setColor(0, 1, 0, 0.6)
    love.graphics.rectangle("line", math.floor(hbX), math.floor(hbY), hbW, hbH)
    love.graphics.setColor(1, 1, 1, 1)

    love.graphics.pop()

    -- DEBUG: tile under player's feet
    local ts = tileSizeWorld
    local feetX = hbX + hbW / 2
    local feetY = hbY + hbH + 1
    local tx = math.floor(feetX / ts)
    local ty = math.floor(feetY / ts)
    local id = getTile(tx, ty)

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print("Feet tile: tx=" .. tx .. " ty=" .. ty .. " id=" .. tostring(id), 10, 40)

    -- UI
    local cd = string.format("Cooldown: %.2f", player.attackCooldownTimer)
    local hp = string.format("HP: %d/%d", player.hp, player.maxHP)

    love.graphics.print("←/→ run | Z jump/double jump | X attack | " .. hp, 10, 10)
    love.graphics.print("CD: " .. cd, 10, 25)
end
