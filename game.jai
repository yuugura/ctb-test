#load "util.jai";
#load "osu.jai";

CATCHER_WALK_SPEED_OSU :: 500.0;  // osu!pixels/sec, from ppy/osu Catcher.BASE_WALK_SPEED
CATCHER_DASH_SPEED_OSU :: 1000.0; // osu!pixels/sec, from ppy/osu Catcher.BASE_DASH_SPEED

// The catcher sprite includes a lot of body below the "plate" that actually
// catches fruit -- in osu!catch, that body hangs below the playfield edge.
// We sink the sprite by half its height so only the top half (plate + head)
// reads as being inside the window, rather than the whole body cluttering it.
CATCHER_SINK_FRACTION :: 0.5;

// osu!catch sizing constants (see osu.ppy.sh/wiki/en/Beatmap/Circle_size
// and ppy/osu Catcher.cs) -- Circle Size drives both catcher and fruit
// size through these, in "osu!pixels", converted to screen pixels via
// OSU_TO_SCREEN so the two stay proportional to each other like in osu.
BASE_SIZE            :: 106.75; // catcher base width, osu!pixels
ALLOWED_CATCH_RANGE  :: 0.8;
OBJECT_RADIUS        :: 64.0;
OSU_PLAYFIELD_WIDTH  :: 512.0;
OSU_PLAYFIELD_HEIGHT :: 384;
OSU_TO_SCREEN        :: SCREEN_WIDTH / OSU_PLAYFIELD_WIDTH;

osu_to_screen :: (value: float) -> float {
    return value * OSU_TO_SCREEN;
}

has_hit_object_type :: (hit_object: *Osu_Hit_Object, flag: Osu_Hit_Object_Type_Flag) -> bool {
    return (hit_object.type & xx flag) != 0;
}

MAX_FRUITS :: 48;

// osu! AR -> preempt-time formula (osu.ppy.sh/wiki/en/Beatmap/Approach_rate).
// preempt_ms is how long before a hit object's time its fruit must spawn
// so it reaches the catch line exactly on time.
approach_rate_to_preempt_ms :: (ar: float) -> float {
    if ar < 5 {
        return 1200 + 600 * (5 - ar) / 5;
    } else {
        return 1200 - 750 * (ar - 5) / 5;
    }
}

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

    // Hyperdash info, copied from the source Osu_Hit_Object at spawn time.
    is_hyper:       bool;
    hyper_target_x: float; // screen-space x of the fruit this should carry the catcher to
    hyper_speed:    float; // screen-space px/sec required to reach it in time
}

Catcher :: struct {
    position: Vector2;
    size_screen: Vector2;

    draw_scale: float;

    hyper_active:   bool;
    hyper_target_x: float; // screen-space x to reach
    hyper_speed:    float; // screen-space px/sec forced while active
}

Difficulty :: struct {
    circle_size: float = 4; // Auto: cs 4 by default cuz who tf plays cs 5
    approach_rate: float = 9.6;
}

Game :: struct {
    fruits: [MAX_FRUITS] Fruit;
    beatmap:    Osu_File;
    hit_cursor: int;
    run_time_ms: float;

    caught_count: int;
    missed_count: int;

    fruit_radius_screen: float;
    catch_half_width_screen: float;
    preempt_ms: float;        // ms of lead time a fruit needs, from beatmap AR
    fruit_fall_speed: float;  // px/sec derived from preempt_ms
    catcher: Catcher;

    difficulty: Difficulty;

    left_key, right_key, dash_key: KeyboardKey;
    input_scheme: Keybind_Scheme = Keybind_Scheme.ARROWS;

    catcher_texture: Texture2D;

    state: Game_State;
}

init_game :: (osu_path: string) -> Game {
    game: Game;
    game.catcher.position.x = cast(float) SCREEN_WIDTH / 2.0;

    game.catcher_texture = LoadTexture(get_c_string("resources/catcher.png"));

    game.beatmap = read_osu_file(osu_path);
    if game.beatmap.hit_objects.count > 0 {
        game.difficulty.circle_size = game.beatmap.difficulty_info.CircleSize;

        game.difficulty.approach_rate = game.beatmap.difficulty_info.ApproachRate;
        if game.difficulty.approach_rate <= 0 {
            // Old-format beatmaps have no ApproachRate key -- real osu falls
            // back to OverallDifficulty in that case.
            game.difficulty.approach_rate = game.beatmap.difficulty_info.OverallDifficulty;
        }
        // No upper clamp -- AR > 10 is valid (e.g. via mods in real osu) and
        // should just yield a shorter preempt via the same linear formula.
        if game.difficulty.approach_rate < 0 game.difficulty.approach_rate = 0;

        game.preempt_ms = approach_rate_to_preempt_ms(game.difficulty.approach_rate);
        // Guard against very high AR (e.g. AR > 13.3) driving preempt to zero
        // or negative in the linear formula, which would make fall speed
        // blow up or invert direction.
        if game.preempt_ms < 1 game.preempt_ms = 1;
        game.fruit_fall_speed = SCREEN_HEIGHT / (game.preempt_ms / 1000.0);

        compute_hyperdash_targets(*game);
    }

    return game;
}

// Shared by compute_hyperdash_targets and calculate_catcher_and_fruit_size so
// the Circle Size -> size math (see the "osu!catch sizing constants" comment
// above) only lives in one place.
fruit_and_catcher_scale_from_cs :: (cs: float) -> (fruit_radius_osu: float, catcher_scale_osu: float) {
    fruit_radius_osu  := (54.4 - 4.48 * cs) * 1.00041;
    legacy_scale      := fruit_radius_osu / OBJECT_RADIUS;
    catcher_scale_osu := legacy_scale * 2.0;
    return fruit_radius_osu, catcher_scale_osu;
}

// Ported from ppy/osu's CatchBeatmapProcessor.initialiseHyperDash: flags a
// Hit_Circle as a hyperdash source when even a full-speed dash can't cover
// the gap to the next Hit_Circle in time, and records the forced speed
// (Catcher.OnNewResult's velocity formula) needed to just make it. Computed
// once here from the map's own Circle Size, matching real osu -- hyperdash
// layout doesn't react to the runtime Circle Size (-/+) tweak.
compute_hyperdash_targets :: (using game: *Game) {
    cs := cast(float) difficulty.circle_size;
    _, catcher_scale_osu := fruit_and_catcher_scale_from_cs(cs);
    half_catcher_width := BASE_SIZE * catcher_scale_osu / 2.0;
    // Speed constants are in osu!px/sec, but StartTime deltas are in ms --
    // ppy/osu's BASE_DASH_SPEED is expressed directly in osu!px/ms, so
    // convert to match.
    dash_speed_per_ms := CATCHER_DASH_SPEED_OSU / 1000.0;

    last_index: int = -1; // index into beatmap.hit_objects of the previous Hit_Circle
    last_direction := 0;
    last_excess := half_catcher_width;

    for i: 0..beatmap.hit_objects.count - 1 {
        current := *beatmap.hit_objects[i];
        if !has_hit_object_type(current, .Hit_Circle) continue;

        if last_index >= 0 {
            previous := *beatmap.hit_objects[last_index];

            this_direction := ifx current.x > previous.x then 1 else -1;
            dx := cast(float) (current.x - previous.x);
            dt := cast(float) (current.time - previous.time);

            time_to_next     := dt - 1000.0 / 60.0 / 4.0;
            excess           := ifx last_direction == this_direction then last_excess else half_catcher_width;
            distance_to_next := abs(dx) - excess;
            distance_to_hyper := time_to_next * dash_speed_per_ms - distance_to_next;

            if distance_to_hyper < 0 {
                previous.is_hyperdash = true;
                previous.hyperdash_target_x = current.x;
                // px/ms -> px/sec, to match CATCHER_*_SPEED_OSU's units.
                previous.hyperdash_speed = (abs(dx) / max(1.0, dt - 1000.0 / 60.0)) * 1000.0;
                last_excess = half_catcher_width;
            } else {
                last_excess = clamp(distance_to_hyper, 0.0, half_catcher_width);
            }

            last_direction = this_direction;
        }

        last_index = i;
    }
}

calculate_catcher_and_fruit_size :: (using game: *Game) {
    cs := cast(float) difficulty.circle_size;
    fruit_radius_osu, catcher_scale_osu := fruit_and_catcher_scale_from_cs(cs);
    catch_width_osu := BASE_SIZE * catcher_scale_osu * ALLOWED_CATCH_RANGE;

    fruit_radius_screen      = osu_to_screen(fruit_radius_osu);
    catch_half_width_screen  = osu_to_screen(catch_width_osu) / 2.0;
    catcher.size_screen.x    = osu_to_screen(BASE_SIZE * catcher_scale_osu);
    catcher.draw_scale       = catcher.size_screen.x / cast(float) catcher_texture.width;
    catcher.size_screen.y    = cast(float) catcher_texture.height * catcher.draw_scale;
    catcher.position.y       = SCREEN_HEIGHT - catcher.size_screen.y * (1.0 - CATCHER_SINK_FRACTION);
}

update_catcher :: (using game: *Game, dt: float) {
    speed := osu_to_screen(ifx IsKeyDown(dash_key) then CATCHER_DASH_SPEED_OSU else CATCHER_WALK_SPEED_OSU);
    if catcher.hyper_active speed = max(speed, catcher.hyper_speed);

    center_before_x := catcher.position.x + catcher.size_screen.x / 2.0;

    if IsKeyDown(left_key)  catcher.position.x -= speed * dt;
    if IsKeyDown(right_key) catcher.position.x += speed * dt;

    min_x := 0.0;
    max_x := SCREEN_WIDTH - catcher.size_screen.x;
    if catcher.position.x < min_x catcher.position.x = min_x;
    if catcher.position.x > max_x catcher.position.x = max_x;

    if catcher.hyper_active {
        catcher_center_x := catcher.position.x + catcher.size_screen.x / 2.0;
        // reached: landed within catch range of the target this frame.
        // crossed: moved fast enough that the target's x fell between last
        // frame's and this frame's center without ever landing inside the
        // catch-range window -- without this, a high enough hyper_speed can
        // jump clean over the window in one frame and hyper_active would
        // never clear.
        reached := abs(catcher_center_x - catcher.hyper_target_x) <= catch_half_width_screen;
        crossed := (center_before_x - catcher.hyper_target_x) * (catcher_center_x - catcher.hyper_target_x) <= 0;
        if reached || crossed {
            catcher.hyper_active = false;
        }
    }
}

update_fruits :: (using game: *Game, dt: float)
{
    // 4. Spawn-timer update -- walk the beatmap's hit objects in time order,
    // spawning each fruit `preempt_ms` (from beatmap AR) before its hit time
    // so it falls into place exactly on time. Sliders and spinners are
    // skipped for now (no droplet-stream simulation yet).
    run_time_ms += dt * 1000.0;

    while hit_cursor < beatmap.hit_objects.count &&
          cast(float) beatmap.hit_objects[hit_cursor].time - preempt_ms <= run_time_ms {
        hit_object := *beatmap.hit_objects[hit_cursor];
        if has_hit_object_type(hit_object, .Hit_Circle) {
            spawn_time_ms := cast(float) hit_object.time - preempt_ms;
            // Usually 0 -- only nonzero for early notes whose ideal spawn
            // time already passed before this frame (e.g. within the first
            // preempt_ms of the map), so they start partway down instead of
            // spawning fresh at the top and arriving late.
            elapsed_ms := run_time_ms - spawn_time_ms;
            initial_y  := -fruit_radius_screen + fruit_fall_speed * (elapsed_ms / 1000.0);

            hyper_target_x_screen := osu_to_screen(cast(float) hit_object.hyperdash_target_x);
            hyper_speed_screen    := osu_to_screen(hit_object.hyperdash_speed);

            if !spawn_fruit_at(*fruits, osu_to_screen(cast(float) hit_object.x), initial_y, hit_object.is_hyperdash, hyper_target_x_screen, hyper_speed_screen) {
                // Pool was full -- count it as a miss instead of silently losing the note.
                missed_count += 1;
            }
        }
        hit_cursor += 1;
    }

    // 5. Fruit physics
    for * fruit: fruits {
        if fruit.alive fruit.y += fruit_fall_speed * dt;
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
            if fruit.is_hyper {
                catcher.hyper_active = true;
                catcher.hyper_target_x = fruit.hyper_target_x;
                catcher.hyper_speed = fruit.hyper_speed;
            }
        } else if fruit.y - fruit_radius_screen > SCREEN_HEIGHT {
            fruit.alive = false;
            missed_count += 1;
        }
    }
}

spawn_fruit_at :: (fruits: *[MAX_FRUITS] Fruit, x: float, y: float, is_hyper: bool, hyper_target_x: float, hyper_speed: float) -> bool {
    for * fruit: fruits.* {
        if fruit.alive continue;
        fruit.x = x;
        fruit.y = y;
        fruit.alive = true;
        fruit.is_hyper = is_hyper;
        fruit.hyper_target_x = hyper_target_x;
        fruit.hyper_speed = hyper_speed;
        return true;
    }
    return false;
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

    HYPER_RING_THICKNESS_FRACTION :: 0.3; // fraction of fruit_radius_screen

    for fruit: fruits {
        if !fruit.alive continue;
        DrawCircleV(Vector2.{ fruit.x, fruit.y }, fruit_radius_screen, WHITE);
        if fruit.is_hyper {
            thickness := fruit_radius_screen * HYPER_RING_THICKNESS_FRACTION;
            DrawRing(Vector2.{ fruit.x, fruit.y }, fruit_radius_screen - thickness / 2.0, fruit_radius_screen + thickness / 2.0, 0, 360, 36, RED);
        }
    }
}