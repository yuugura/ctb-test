#import "Basic";
#import "raylib";
#import "Math";

SCREEN_WIDTH  :: 800;
SCREEN_HEIGHT :: 450;
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

Fruit :: struct {
    x:     float;
    y:     float;
    alive: bool;
}

Fruit_Spawn :: struct {
    x_fraction: float; // 0..1 across screen width
    time:       float; // seconds since loop start
}

SPAWN_LIST :: Fruit_Spawn.[
    .{0.10, 0.0},
    .{0.50, 0.8},
    .{0.90, 1.6},
    .{0.30, 2.4},
    .{0.70, 3.2},
];
LOOP_DURATION :: 4.0; // must be > last SPAWN_LIST entry's time

spawn_fruit_at :: (fruits: *[MAX_FRUITS] Fruit, x: float, radius: float) {
    for * fruit: fruits.* {
        if fruit.alive continue;
        fruit.x = x;
        fruit.y = -radius;
        fruit.alive = true;
        return;
    }
}

main :: () {
    InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, get_c_string("osu!Catch - Catcher"));
    defer CloseWindow();

    SetTargetFPS(60);

    catcher_texture := LoadTexture(get_c_string("resources/catcher.png"));
    defer UnloadTexture(catcher_texture);

    circle_size := 5;
    scheme      := Keybind_Scheme.ARROWS;

    catcher_x := cast(float) SCREEN_WIDTH / 2.0;

    fruits: [MAX_FRUITS] Fruit;
    run_time:          float;
    previous_loop_time: float;
    spawn_cursor:       int;

    caught_count: int;
    missed_count: int;

    while !WindowShouldClose() {
        dt := GetFrameTime();

        // 1. Settings input (edge-triggered so holding doesn't spam-change)
        if IsKeyPressed(.KEY_MINUS) circle_size -= 1;
        if IsKeyPressed(.KEY_EQUAL) circle_size += 1;
        if circle_size < 0  circle_size = 0;
        if circle_size > 10 circle_size = 10;

        if IsKeyPressed(.KEY_TAB) {
            if scheme == .ARROWS {
                scheme = .WASD;
            } else {
                scheme = .ARROWS;
            }
        }

        // 2. Recompute Circle Size-derived sizes every frame
        cs                := cast(float) circle_size;
        fruit_radius_osu  := (54.4 - 4.48 * cs) * 1.00041;
        legacy_scale      := fruit_radius_osu / OBJECT_RADIUS;
        catcher_scale_osu := legacy_scale * 2.0;
        catch_width_osu   := BASE_SIZE * catcher_scale_osu * ALLOWED_CATCH_RANGE;

        fruit_radius_screen     := fruit_radius_osu * OSU_TO_SCREEN;
        catch_half_width_screen := (catch_width_osu * OSU_TO_SCREEN) / 2.0;
        catcher_width_screen    := BASE_SIZE * catcher_scale_osu * OSU_TO_SCREEN;
        catcher_draw_scale      := catcher_width_screen / cast(float) catcher_texture.width;
        catcher_height_screen   := cast(float) catcher_texture.height * catcher_draw_scale;
        catcher_y := SCREEN_HEIGHT - catcher_height_screen * (1.0 - CATCHER_SINK_FRACTION);

        // 3. Movement input using the active keybind scheme
        left_key, right_key, dash_key: KeyboardKey;
        if scheme == .ARROWS {
            left_key = .KEY_LEFT; right_key = .KEY_RIGHT; dash_key = .KEY_LEFT_SHIFT;
        } else {
            left_key = .KEY_A; right_key = .KEY_D; dash_key = .KEY_RIGHT_SHIFT;
        }

        speed := CATCHER_SPEED;
        if IsKeyDown(dash_key) speed *= DASH_MULTIPLIER;

        if IsKeyDown(left_key)  catcher_x -= speed * dt;
        if IsKeyDown(right_key) catcher_x += speed * dt;

        min_x := 0.0;
        max_x := SCREEN_WIDTH - catcher_width_screen;
        if catcher_x < min_x catcher_x = min_x;
        if catcher_x > max_x catcher_x = max_x;

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

        // 6. Catch / miss detection
        catcher_center_x := catcher_x + catcher_width_screen / 2.0;
        catch_min_x := catcher_center_x - catch_half_width_screen;
        catch_max_x := catcher_center_x + catch_half_width_screen;
        // Only the visible (unsunk) portion of the sprite -- the "plate" --
        // should register catches; the sunk lower half is off-screen.
        catcher_top := catcher_y;
        catcher_bottom := catcher_y + catcher_height_screen * CATCHER_SINK_FRACTION;

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

        // 7. Draw
        PushDrawing();

        ClearBackground(RAYWHITE);
        DrawTextureEx(catcher_texture, Vector2.{ catcher_x, catcher_y }, 0, catcher_draw_scale, WHITE);

        for fruit: fruits {
            if fruit.alive DrawCircleV(Vector2.{ fruit.x, fruit.y }, fruit_radius_screen, ORANGE);
        }

        scheme_name := "Arrows + LShift";
        if scheme == .WASD scheme_name = "A/D + RShift";

        DrawText(get_c_string(tprint("Circle Size: % (- / +)", circle_size)), 10, 10, 20, BLACK);
        DrawText(get_c_string(tprint("Keybinds: % (Tab to switch)", scheme_name)), 10, 30, 20, BLACK);
        DrawText(get_c_string(tprint("Caught: %   Missed: %", caught_count, missed_count)), 10, 50, 20, BLACK);
    }
}
