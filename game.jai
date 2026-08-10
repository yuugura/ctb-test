CATCHER_SPEED :: 400.0; // pixels per second
DASH_MULTIPLIER :: 1.8;

// The catcher sprite includes a lot of body below the "plate" that actually
// catches fruit -- in osu!catch, that body hangs below the playfield edge.
// We sink the sprite by half its height so only the top half (plate + head)
// reads as being inside the window, rather than the whole body cluttering it.
CATCHER_SINK_FRACTION :: 0.5;

// osu!catch sizing constants (see osu.ppy.sh/wiki/en/Beatmap/Circle_size
// and ppy/osu Catcher.cs) -- Circle Size drives both catcher and fruit
// size through these, in "osu!pixels", converted to screen pixels via
// OSU_TO_SCREEN so the two stay proportional to each other like in osu.
BASE_SIZE           :: 106.75; // catcher base width, osu!pixels
ALLOWED_CATCH_RANGE :: 0.8;
OBJECT_RADIUS       :: 64.0;
OSU_PLAYFIELD_WIDTH :: 512.0;
OSU_TO_SCREEN       :: SCREEN_WIDTH / OSU_PLAYFIELD_WIDTH;

MAX_FRUITS      :: 16;
FRUIT_FALL_SPEED :: 200.0; // pixels per second

Keybind_Scheme :: enum {
    ARROWS; // KEY_LEFT / KEY_RIGHT / KEY_LEFT_SHIFT
    WASD;   // KEY_A / KEY_D / KEY_RIGHT_SHIFT
}

Game_State :: enum u32 {
    Playing;
    Paused;
}

Fruit :: struct {
    x:     float;
    y:     float;
    alive: bool;
}

Fruit_Spawn :: struct {
    x_fraction: float; // 0..1 across screen width
    time:       float; // seconds since loop start
}

Catcher :: struct {
    position: Vector2;
    size_screen: Vector2;

    draw_scale: float;

}

Difficulty :: struct {
    circle_size: float = 4; // Auto: cs 4 by default cuz who tf plays cs 5
}

// Auto: temp spawn list
SPAWN_LIST :: Fruit_Spawn.[
    .{0.10, 0.0},
    .{0.50, 0.8},
    .{0.90, 1.6},
    .{0.30, 2.4},
    .{0.70, 3.2},
];

LOOP_DURATION :: 4.0; // must be > last SPAWN_LIST entry's time

Game :: struct {
    fruits: [MAX_FRUITS] Fruit;
    run_time:          float;
    previous_loop_time: float;
    spawn_cursor:       int;

    caught_count: int;
    missed_count: int;

    fruit_radius_screen: float;
    catch_half_width_screen: float;
    catcher: Catcher;

    difficulty: Difficulty;

    left_key, right_key, dash_key: KeyboardKey;
    input_scheme: Keybind_Scheme = Keybind_Scheme.ARROWS;

    catcher_texture: Texture2D;

    state: Game_State;
}

init_game :: () -> Game {
    game: Game;
    game.catcher.position.x = cast(float) SCREEN_WIDTH / 2.0;

    game.catcher_texture = LoadTexture(get_c_string("resources/catcher.png"));

    return game;
}

calculate_catcher_and_fruit_size :: (using game: *Game) {
    cs                := cast(float) difficulty.circle_size;
    fruit_radius_osu  := (54.4 - 4.48 * cs) * 1.00041;
    legacy_scale      := fruit_radius_osu / OBJECT_RADIUS;
    catcher_scale_osu := legacy_scale * 2.0;
    catch_width_osu   := BASE_SIZE * catcher_scale_osu * ALLOWED_CATCH_RANGE;

    fruit_radius_screen      = fruit_radius_osu * OSU_TO_SCREEN;
    catch_half_width_screen  = (catch_width_osu * OSU_TO_SCREEN) / 2.0;
    catcher.size_screen.x    = BASE_SIZE * catcher_scale_osu * OSU_TO_SCREEN;
    catcher.draw_scale       = catcher.size_screen.x / cast(float) catcher_texture.width;
    catcher.size_screen.y    = cast(float) catcher_texture.height * catcher.draw_scale;
    catcher.position.y       = SCREEN_HEIGHT - catcher.size_screen.y * (1.0 - CATCHER_SINK_FRACTION);
}

update_catcher :: (using game: *Game, dt: float) {
    speed := CATCHER_SPEED;
    if IsKeyDown(dash_key) speed *= DASH_MULTIPLIER;

    if IsKeyDown(left_key)  catcher.position.x -= speed * dt;
    if IsKeyDown(right_key) catcher.position.x += speed * dt;

    min_x := 0.0;
    max_x := SCREEN_WIDTH - catcher.size_screen.x;
    if catcher.position.x < min_x catcher.position.x = min_x;
    if catcher.position.x > max_x catcher.position.x = max_x;
}

update_fruits :: (using game: *Game, dt: float)
{
    // 4. Spawn-timer update (hardcoded, looping spawn list)
    run_time += dt;
    loop_time := fmod_cycling(run_time, LOOP_DURATION);

    if spawn_cursor < SPAWN_LIST.count && loop_time >= SPAWN_LIST[spawn_cursor].time {
        spawn_fruit_at(*fruits, SPAWN_LIST[spawn_cursor].x_fraction * SCREEN_WIDTH, fruit_radius_screen);
        spawn_cursor += 1;
    }
    if loop_time < previous_loop_time {
        spawn_cursor = 0;
    }
    previous_loop_time = loop_time;

    // 5. Fruit physics
    for * fruit: fruits {
        if fruit.alive fruit.y += FRUIT_FALL_SPEED * dt;
    }
}

catching_fruits :: (using game: *Game) {
    catcher_center_x := catcher.position.x + catcher.size_screen.x / 2.0;
    catch_min_x := catcher_center_x - catch_half_width_screen;
    catch_max_x := catcher_center_x + catch_half_width_screen;
    // Only the visible (unsunk) portion of the sprite -- the "plate" --
    // should register catches; the sunk lower half is off-screen.
    catcher_top := catcher.position.y;
    catcher_bottom := catcher.position.y + catcher.size_screen.y * CATCHER_SINK_FRACTION;

    for * fruit: fruits {
        if !fruit.alive continue;

        fruit_top    := fruit.y - fruit_radius_screen;
        fruit_bottom := fruit.y + fruit_radius_screen;

        vertical_overlap   := fruit_bottom >= catcher_top && fruit_top <= catcher_bottom;
        horizontal_overlap := fruit.x >= catch_min_x && fruit.x <= catch_max_x;

        if vertical_overlap && horizontal_overlap {
            fruit.alive = false;
            caught_count += 1;
        } else if fruit.y - fruit_radius_screen > SCREEN_HEIGHT {
            fruit.alive = false;
            missed_count += 1;
        }
    }
}

spawn_fruit_at :: (fruits: *[MAX_FRUITS] Fruit, x: float, radius: float) {
    for * fruit: fruits.* {
        if fruit.alive continue;
        fruit.x = x;
        fruit.y = -radius;
        fruit.alive = true;
        return;
    }
}

update_game :: (using game: *Game) { 
    if IsKeyPressed(.KEY_ESCAPE) {
        game.state = .Paused;
        return;
    }
    dt := GetFrameTime();

    // 1. Settings input (edge-triggered so holding doesn't spam-change)
    if IsKeyPressed(.KEY_MINUS) difficulty.circle_size -= 1;
    if IsKeyPressed(.KEY_EQUAL) difficulty.circle_size += 1;
    if difficulty.circle_size < 0  difficulty.circle_size = 0;
    if difficulty.circle_size > 10 difficulty.circle_size = 10;

    if IsKeyPressed(.KEY_TAB) {
        if input_scheme == .ARROWS {
            input_scheme = .WASD;
        } else {
            input_scheme = .ARROWS;
        }
    }

    // 2. Recompute Circle Size-derived sizes every frame
    calculate_catcher_and_fruit_size(game);

    // 3. Movement input using the active keybind scheme
    if input_scheme == .ARROWS {
        left_key = .KEY_LEFT; right_key = .KEY_RIGHT; dash_key = .KEY_LEFT_SHIFT;
    } else {
        left_key = .KEY_A; right_key = .KEY_D; dash_key = .KEY_RIGHT_SHIFT;
    }

    update_catcher(game, dt);

    update_fruits(game, dt);

    // 6. Catch / miss detection
    catching_fruits(game);
}

render_game :: (using game: *Game) {
    DrawTextureEx(catcher_texture, Vector2.{ catcher.position.x, catcher.position.y }, 0, catcher.draw_scale, WHITE);

    for fruit: fruits {
        if fruit.alive DrawCircleV(Vector2.{ fruit.x, fruit.y }, fruit_radius_screen, ORANGE);
    }
}